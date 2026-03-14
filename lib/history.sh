#!/usr/bin/env bash
# Rolling compaction, persistent history, and session recall
# Compatible with bash 3.2+ (macOS default)

# ── Session metadata (set by history_init) ────────────
SESSION_ID=""
SESSION_START=""
SESSION_TURNS=0
SESSION_FILES_TOUCHED=""

# ── Initialize history infrastructure ─────────────────

history_init() {
    mkdir -p "$LANA_HISTORY_DIR"

    # Generate unique session ID: YYYYMMDD_HHMMSS_<8 random hex chars>
    local rand_hex
    rand_hex=$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')
    SESSION_ID="$(date +%Y%m%d_%H%M%S)_${rand_hex}"
    SESSION_START="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    SESSION_TURNS=0
    SESSION_FILES_TOUCHED=""
}

# ── Rolling compaction: incremental summary ──────────
# Instead of one big compaction at a threshold, compact incrementally
# every N turns. Each compaction summarizes only the oldest turn-pairs
# and APPENDS to the existing warm summary.

history_compact_rolling() {
    local messages
    messages=$(cat "$MESSAGES_FILE")

    local msg_count
    msg_count=$(echo "$messages" | jq 'length')

    # Calculate how many messages to keep hot
    # Each turn-pair is roughly: user + assistant(+tool_calls) + tool_results
    # We keep COMPACT_KEEP_TURNS worth of turn-pairs + system + warm summary
    local keep_messages=$((COMPACT_KEEP_TURNS * 4 + 2))  # rough: 4 msgs per turn-pair
    if (( keep_messages > msg_count )); then
        keep_messages=$((msg_count))
    fi

    # Find the boundary: everything before the keep window gets compacted
    local start_idx=1
    local end_idx=$((msg_count - keep_messages + 2))  # +2 for system+summary

    # Check if index 1 is an existing warm summary
    local idx1_content
    idx1_content=$(echo "$messages" | jq -r '.[1].content // ""' | head -1)
    local existing_summary=""
    if [[ "$idx1_content" == "[Conversation Summary]"* ]]; then
        existing_summary=$(echo "$messages" | jq -r '.[1].content // ""')
        start_idx=2
    fi

    if (( end_idx <= start_idx )); then
        ui_debug "Nothing to compact (end=$end_idx <= start=$start_idx)"
        return 1
    fi

    # Walk backward from end_idx to avoid splitting tool_call/tool pairs
    local check_role
    check_role=$(echo "$messages" | jq -r ".[$end_idx].role // \"\"")
    while [[ "$check_role" == "tool" && $end_idx -gt $start_idx ]]; do
        end_idx=$((end_idx - 1))
        check_role=$(echo "$messages" | jq -r ".[$end_idx].role // \"\"")
    done

    if (( end_idx <= start_idx )); then
        return 1
    fi

    # Extract messages to compact
    local to_compact
    to_compact=$(echo "$messages" | jq --argjson s "$start_idx" --argjson e "$end_idx" '.[$s:$e]')

    local compact_count
    compact_count=$(echo "$to_compact" | jq 'length')

    if (( compact_count < 2 )); then
        return 1
    fi

    # Generate incremental summary
    spinner_start "compacting"
    local new_summary
    new_summary=$(_compact_incremental_summary "$to_compact" "$existing_summary")
    spinner_stop

    if [[ -z "$new_summary" ]]; then
        ui_warn "Compaction summary failed."
        return 1
    fi

    local warm_msg="[Conversation Summary]
${new_summary}"

    local tokens_before
    tokens_before=$(state_estimate_tokens)

    # Rebuild: [system] + [warm_summary] + [kept_recent]
    local tmp="$SESSION_DIR/tmp_compact.json"
    echo "$messages" | jq \
        --arg summary "$warm_msg" \
        --argjson end_idx "$end_idx" \
        '[.[0]] + [{"role": "user", "content": $summary}] + .[$end_idx:]' \
        > "$tmp" && mv "$tmp" "$MESSAGES_FILE"

    local tokens_after
    tokens_after=$(state_estimate_tokens)

    ui_dim "Compacted: ~${tokens_before} -> ~${tokens_after} tokens (${compact_count} messages summarized)."

    _history_record_compaction "$compact_count" "$tokens_before" "$tokens_after" "$new_summary"

    return 0
}

# ── Incremental summary: append to existing ──────────

_compact_incremental_summary() {
    local messages_to_compact="$1"
    local existing_summary="$2"

    # Format messages for summarizer
    local formatted
    formatted=$(echo "$messages_to_compact" | jq -r '
        .[] |
        if .role == "tool" then
            "tool_result (\(.name // "unknown")): \(.content | tostring | .[0:150])"
        elif .role == "assistant" and .tool_calls then
            "assistant: [called: \([.tool_calls[].function.name] | join(", "))]" +
            if .content and .content != "null" and .content != "" then
                " — " + (.content | tostring | .[0:200])
            else "" end
        elif .role == "system" then
            empty
        else
            "\(.role): \(.content | tostring | .[0:300])"
        end
    ' 2>/dev/null)

    if [[ -z "$formatted" ]]; then
        return 1
    fi

    local prompt
    if [[ -n "$existing_summary" ]]; then
        prompt="You are updating a running conversation summary for a coding session in: ${WORK_DIR}

EXISTING SUMMARY:
${existing_summary}

NEW MESSAGES TO INCORPORATE:
${formatted}

Update the summary to include the new information. Keep it structured:
1. GOALS: What the user is trying to accomplish
2. FILES: All files read/created/modified (paths)
3. PROGRESS: What has been done, key decisions made
4. STATE: Current status, what remains

Be concise but preserve all technical details needed to continue the work. Max 400 tokens."
    else
        prompt="Summarize this coding assistant conversation in: ${WORK_DIR}

${formatted}

Structure your summary as:
1. GOALS: What the user is trying to accomplish
2. FILES: All files read/created/modified (paths)
3. PROGRESS: What has been done, key decisions made
4. STATE: Current status, what remains

Be concise but preserve all technical details. Max 400 tokens."
    fi

    local payload
    payload=$(jq -n \
        --arg prompt "$prompt" \
        --argjson max_tokens "$COMPACT_SUMMARY_MAX_TOKENS" \
        --argjson temperature "$COMPACT_TEMPERATURE" \
        --arg model_name "$API_MODEL" \
        '{
            "model": $model_name,
            "messages": [{"role": "user", "content": $prompt}],
            "max_tokens": $max_tokens,
            "temperature": $temperature
        }')

    local response
    response=$(curl -s \
        -X POST "${API_URL}/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        --max-time 30 2>/dev/null)

    local summary
    summary=$(echo "$response" | jq -r '.choices[0].message.content // ""' 2>/dev/null)

    # Strip thinking tags
    summary=$(printf '%s' "$summary" | perl -0777 -pe 's/<think>.*?<\/think>//gs' 2>/dev/null) || true

    echo "$summary"
}

# ── Percentage-based compaction check ────────────────
# Called at the end of each turn. Compacts when context usage
# exceeds COMPACT_TRIGGER_PCT, keeping recent turns hot.

state_compact_if_needed() {
    local est_tokens
    est_tokens=$(state_estimate_tokens)
    local context_pct=$((est_tokens * 100 / CONTEXT_SIZE))

    # 1. Normal compaction: when context exceeds trigger threshold
    if (( context_pct >= COMPACT_TRIGGER_PCT )); then
        local msg_count
        msg_count=$(jq 'length' "$MESSAGES_FILE")
        local min_for_compact=$((COMPACT_KEEP_TURNS * 3 + 4))

        if (( msg_count > min_for_compact )); then
            ui_debug "Compaction triggered at ${context_pct}% context usage (~${est_tokens} tokens)"
            history_compact_rolling || true
            est_tokens=$(state_estimate_tokens)
        fi
    fi

    # 2. Emergency trim: hard threshold — if compaction wasn't enough
    local emergency_threshold=$((CONTEXT_SIZE * COMPACT_EMERGENCY_PCT / 100))
    if (( est_tokens > emergency_threshold )); then
        ui_warn "Context still at ~${est_tokens} tokens after compaction. Emergency trim..."
        state_trim_if_needed
    fi
}

# ── Legacy compat: history_compact calls rolling ─────

history_compact() {
    history_compact_rolling
}

# ── Save session to persistent history ────────────────

history_save_session() {
    if (( SESSION_TURNS < 1 )); then
        return 0
    fi

    [[ -z "$SESSION_ID" ]] && return 0
    [[ ! -f "$MESSAGES_FILE" ]] && return 0

    local messages
    messages=$(cat "$MESSAGES_FILE" 2>/dev/null) || return 0
    local msg_count
    msg_count=$(echo "$messages" | jq 'length' 2>/dev/null) || return 0

    if (( msg_count < 3 )); then
        return 0
    fi

    # Use the warm summary if available, otherwise generate one
    local final_summary=""
    local idx1_content
    idx1_content=$(echo "$messages" | jq -r '.[1].content // ""' | head -1)
    if [[ "$idx1_content" == "[Conversation Summary]"* ]]; then
        final_summary=$(echo "$messages" | jq -r '.[1].content // ""')
        final_summary="${final_summary#\[Conversation Summary\]}"
    elif api_health_check 2>/dev/null; then
        spinner_start "saving session summary"
        final_summary=$(_compact_incremental_summary "$messages" "")  || true
        spinner_stop
    fi

    # Build files_touched array
    local files_json="[]"
    if [[ -n "$SESSION_FILES_TOUCHED" ]]; then
        files_json=$(printf '%s' "$SESSION_FILES_TOUCHED" | tr '|' '\n' | sort -u | jq -R . | jq -s '.')
    fi

    # Write session file
    local session_file="$LANA_HISTORY_DIR/${SESSION_ID}.json"
    local session_end
    session_end="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    jq -n \
        --arg id "$SESSION_ID" \
        --argjson version 2 \
        --arg start "$SESSION_START" \
        --arg end "$session_end" \
        --arg work_dir "$WORK_DIR" \
        --arg model "$CURRENT_MODEL" \
        --argjson turns "$SESSION_TURNS" \
        --argjson files "$files_json" \
        --arg final_summary "${final_summary:-}" \
        '{
            id: $id,
            version: $version,
            start: $start,
            end: $end,
            work_dir: $work_dir,
            model: $model,
            turns: $turns,
            files_touched: $files,
            compactions: [],
            final_summary: $final_summary
        }' > "$session_file" 2>/dev/null || return 0

    # Merge compaction records
    if [[ -f "$SESSION_DIR/compactions.json" ]]; then
        local tmp_sess="$SESSION_DIR/tmp_session.json"
        jq --slurpfile compactions "$SESSION_DIR/compactions.json" \
            '.compactions = ($compactions | .[0] // [])' \
            "$session_file" > "$tmp_sess" 2>/dev/null && mv "$tmp_sess" "$session_file"
    fi

    _history_update_index "$session_file"
}

# ── List sessions from history ────────────────────────

history_list() {
    local search="${1:-}"
    local index_file="$LANA_HISTORY_DIR/index.json"

    if [[ ! -f "$index_file" ]]; then
        ui_info "No history found. Sessions are saved automatically on exit."
        return 0
    fi

    local entries
    if [[ -n "$search" ]]; then
        entries=$(jq --arg q "$search" '[.[] | select(
            (.summary | test($q; "i")) or
            (.work_dir | test($q; "i")) or
            (.id | test($q; "i"))
        )]' "$index_file" 2>/dev/null) || entries="[]"
    else
        entries=$(jq '.[-20:]' "$index_file" 2>/dev/null) || entries="[]"
    fi

    local count
    count=$(echo "$entries" | jq 'length')

    if (( count == 0 )); then
        if [[ -n "$search" ]]; then
            ui_info "No sessions matching: $search"
        else
            ui_info "No history found."
        fi
        return 0
    fi

    printf "\n${C_BOLD}Session History${C_RESET}"
    [[ -n "$search" ]] && printf " ${C_DIM}(matching: %s)${C_RESET}" "$search"
    printf "\n\n"

    echo "$entries" | jq -r '.[] |
        "  \u001b[1m\(.id)\u001b[0m  \(.start | .[0:10])  \(.model)  \(.turns) turns\n  \u001b[2m\(.work_dir)\u001b[0m\n  \(.summary | .[0:120])\n"
    '
}

# ── Recall a session's context ────────────────────────

history_recall() {
    local query="$1"
    local index_file="$LANA_HISTORY_DIR/index.json"

    if [[ ! -f "$index_file" ]]; then
        ui_error "No history found."
        return 1
    fi

    # Try exact ID prefix match first
    local session_id=""
    session_id=$(jq -r --arg q "$query" '.[] | select(.id | startswith($q)) | .id' "$index_file" 2>/dev/null | head -1)

    # Fall back to content search
    if [[ -z "$session_id" ]]; then
        session_id=$(jq -r --arg q "$query" '.[] | select(
            (.summary | test($q; "i")) or (.work_dir | test($q; "i"))
        ) | .id' "$index_file" 2>/dev/null | tail -1)
    fi

    if [[ -z "$session_id" ]]; then
        ui_error "No session found matching: $query"
        return 1
    fi

    local session_file="$LANA_HISTORY_DIR/${session_id}.json"
    if [[ ! -f "$session_file" ]]; then
        ui_error "Session file missing: $session_file"
        return 1
    fi

    local recall_text
    recall_text=$(jq -r '
        if (.final_summary // "") != "" then
            .final_summary
        elif (.compactions | length) > 0 then
            .compactions[-1].summary
        else
            "No summary available for this session."
        end
    ' "$session_file")

    local recall_meta
    recall_meta=$(jq -r '"Session \(.id) (\(.start | .[0:10])) in \(.work_dir) using \(.model)"' "$session_file")

    local files_list
    files_list=$(jq -r 'if (.files_touched | length) > 0 then "Files touched: " + (.files_touched | join(", ")) else "" end' "$session_file")

    local recall_msg="[Previous Session Context]
${recall_meta}
${files_list}

${recall_text}"

    state_add_message "user" "$recall_msg"

    ui_success "Recalled session: $session_id"
    ui_dim "  $recall_meta"
    [[ -n "$files_list" ]] && ui_dim "  $files_list"
}

# ── Track files touched during session ────────────────

history_track_file() {
    local tool_name="$1" args_json="$2"
    local path=""

    case "$tool_name" in
        read_file|write_file|edit_file)
            path=$(echo "$args_json" | jq -r '.path // empty' 2>/dev/null)
            ;;
    esac

    if [[ -n "$path" ]]; then
        [[ "$path" == "$WORK_DIR/"* ]] && path="${path#$WORK_DIR/}"

        if [[ -z "$SESSION_FILES_TOUCHED" ]]; then
            SESSION_FILES_TOUCHED="$path"
        elif [[ "$SESSION_FILES_TOUCHED" != *"$path"* ]]; then
            SESSION_FILES_TOUCHED="${SESSION_FILES_TOUCHED}|${path}"
        fi
    fi
}

# ── Internal: update index catalog ────────────────────

_history_update_index() {
    local session_file="$1"
    local index_file="$LANA_HISTORY_DIR/index.json"

    [[ ! -f "$index_file" ]] && echo '[]' > "$index_file"

    local entry
    entry=$(jq '{
        id: .id,
        start: .start,
        work_dir: .work_dir,
        model: .model,
        turns: .turns,
        summary: (.final_summary | .[0:200])
    }' "$session_file" 2>/dev/null) || return 0

    local tmp="$LANA_HISTORY_DIR/tmp_index.json"
    jq --argjson entry "$entry" \
        '[.[] | select(.id != $entry.id)] + [$entry]' \
        "$index_file" > "$tmp" 2>/dev/null && mv "$tmp" "$index_file"
}

# ── Internal: record compaction event ─────────────────

_history_record_compaction() {
    local count="$1" tokens_before="$2" tokens_after="$3" summary="$4"
    local compactions_file="$SESSION_DIR/compactions.json"

    [[ ! -f "$compactions_file" ]] && echo '[]' > "$compactions_file"

    local tmp="$SESSION_DIR/tmp_compactions.json"
    jq --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson count "$count" \
        --argjson before "$tokens_before" \
        --argjson after "$tokens_after" \
        --arg summary "$summary" \
        '. + [{
            at: $at,
            messages_compacted: $count,
            tokens_before: $before,
            tokens_after: $after,
            summary: $summary
        }]' "$compactions_file" > "$tmp" 2>/dev/null && mv "$tmp" "$compactions_file"
}

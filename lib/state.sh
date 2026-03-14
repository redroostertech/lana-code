#!/usr/bin/env bash
# Conversation state management with tiered context
# Compatible with bash 3.2+
#
# Three tiers:
#   HOT  - Current messages in messages.json (last N turn-pairs)
#   WARM - Rolling conversation summary at messages[1]
#   COLD - Full archived turn data in $SESSION_DIR/turns/

# ── Initialize session ────────────────────────────────

state_init() {
    mkdir -p "$SESSION_DIR"
    mkdir -p "$SESSION_DIR/turns"
    MESSAGES_FILE="$SESSION_DIR/messages.json"
    echo '[]' > "$MESSAGES_FILE"
    COLD_TURN_COUNTER=0
}

COLD_TURN_COUNTER=0

# ── Message operations ─────────────────────────────────

state_add_message() {
    local role="$1" content="$2"
    local tmp="$SESSION_DIR/tmp_msg.json"
    jq --arg role "$role" --arg content "$content" \
        '. + [{"role": $role, "content": $content}]' \
        "$MESSAGES_FILE" > "$tmp" && mv "$tmp" "$MESSAGES_FILE"
}

state_add_system() {
    local content="$1"
    local tmp="$SESSION_DIR/tmp_msg.json"
    # System message always goes first, replace if exists
    jq --arg content "$content" '
        if (.[0].role // "") == "system" then
            .[0].content = $content
        else
            [{"role": "system", "content": $content}] + .
        end
    ' "$MESSAGES_FILE" > "$tmp" && mv "$tmp" "$MESSAGES_FILE"
}

# Add assistant message with tool calls (and optional content alongside)
state_add_assistant_tool_calls() {
    local tool_calls_json="$1"
    local content="${2:-}"
    local tmp="$SESSION_DIR/tmp_msg.json"

    if [[ -n "$content" && "$content" != "null" ]]; then
        jq --argjson tc "$tool_calls_json" --arg content "$content" \
            '. + [{"role": "assistant", "content": $content, "tool_calls": $tc}]' \
            "$MESSAGES_FILE" > "$tmp" && mv "$tmp" "$MESSAGES_FILE"
    else
        jq --argjson tc "$tool_calls_json" \
            '. + [{"role": "assistant", "content": null, "tool_calls": $tc}]' \
            "$MESSAGES_FILE" > "$tmp" && mv "$tmp" "$MESSAGES_FILE"
    fi
}

# ── Tool result with per-result compression + cold archive ──

state_add_tool_result() {
    local tool_call_id="$1" name="$2" content="$3"
    local tmp="$SESSION_DIR/tmp_msg.json"

    # Archive full result to cold storage before any compression
    if [[ "${COLD_STORAGE_ENABLED:-true}" == "true" ]]; then
        _cold_archive_result "$tool_call_id" "$name" "$content"
    fi

    # Compress the result for hot context
    content=$(_compress_tool_result "$name" "$content")

    jq --arg id "$tool_call_id" --arg name "$name" --arg content "$content" \
        '. + [{"role": "tool", "tool_call_id": $id, "name": $name, "content": $content}]' \
        "$MESSAGES_FILE" > "$tmp" && mv "$tmp" "$MESSAGES_FILE"
}

# ── Per-result compression (immediate, no LLM needed) ──

_compress_tool_result() {
    local tool_name="$1" content="$2"

    # Hard truncate safety net
    local max_result_chars=8000
    if (( ${#content} > max_result_chars )); then
        content="${content:0:$max_result_chars}
... [truncated: ${#content} chars total, full result in turn archive]"
    fi

    # Count lines
    local line_count
    line_count=$(printf '%s' "$content" | wc -l | tr -d ' ')

    # Short results: keep as-is
    if (( line_count <= TOOL_RESULT_MAX_LINES )); then
        printf '%s' "$content"
        return 0
    fi

    # Compress based on tool type
    case "$tool_name" in
        read_file)
            # Keep head + tail + note about archived full content
            local head_part tail_part
            head_part=$(printf '%s' "$content" | head -n "$TOOL_RESULT_KEEP_HEAD")
            tail_part=$(printf '%s' "$content" | tail -n "$TOOL_RESULT_KEEP_TAIL")
            printf '%s\n... [%s lines total — showing first %s + last %s. Use recall_turn for full content]\n%s' \
                "$head_part" "$line_count" "$TOOL_RESULT_KEEP_HEAD" "$TOOL_RESULT_KEEP_TAIL" "$tail_part"
            ;;
        grep_search)
            # Keep first N matches
            local kept
            kept=$(printf '%s' "$content" | head -n 15)
            printf '%s\n... [%s total lines — showing first 15. Use recall_turn for full results]' \
                "$kept" "$line_count"
            ;;
        bash)
            # Keep head + error lines + exit code
            local head_part error_lines
            head_part=$(printf '%s' "$content" | head -n "$TOOL_RESULT_KEEP_HEAD")
            # Extract lines with error/warning/fail keywords
            error_lines=$(printf '%s' "$content" | grep -i -E 'error|warning|fail|fatal|exception|traceback|panic' | head -10) || true
            if [[ -n "$error_lines" ]]; then
                printf '%s\n... [%s lines total]\n── errors/warnings ──\n%s' \
                    "$head_part" "$line_count" "$error_lines"
            else
                local tail_part
                tail_part=$(printf '%s' "$content" | tail -n "$TOOL_RESULT_KEEP_TAIL")
                printf '%s\n... [%s lines total — full output in turn archive]\n%s' \
                    "$head_part" "$line_count" "$tail_part"
            fi
            ;;
        glob_find|file_tree)
            # Keep first chunk + count
            local kept
            kept=$(printf '%s' "$content" | head -n 20)
            printf '%s\n... [%s total lines — use recall_turn for full list]' \
                "$kept" "$line_count"
            ;;
        *)
            # Generic: head + tail
            local head_part tail_part
            head_part=$(printf '%s' "$content" | head -n "$TOOL_RESULT_KEEP_HEAD")
            tail_part=$(printf '%s' "$content" | tail -n "$TOOL_RESULT_KEEP_TAIL")
            printf '%s\n... [%s lines total — compressed for context]\n%s' \
                "$head_part" "$line_count" "$tail_part"
            ;;
    esac
}

# ── Cold storage: archive full tool results to disk ──

_cold_archive_result() {
    local tool_call_id="$1" name="$2" content="$3"
    local turns_dir="$SESSION_DIR/turns"

    COLD_TURN_COUNTER=$((COLD_TURN_COUNTER + 1))
    local turn_file="$turns_dir/$(printf '%03d' $COLD_TURN_COUNTER)_${name}.json"

    # Extract key metadata for searchability
    local file_path=""
    local keywords=""

    case "$name" in
        read_file|write_file|edit_file)
            # Will be set by caller context — extract from recent state
            file_path="(see tool args)"
            ;;
    esac

    # Extract keywords from content (simple word extraction)
    keywords=$(printf '%s' "$content" | tr -cs '[:alnum:]_./\-' '\n' | sort -u | head -50 | tr '\n' ' ')

    jq -n \
        --arg id "$tool_call_id" \
        --arg tool "$name" \
        --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg turn "$COLD_TURN_COUNTER" \
        --arg content "$content" \
        --arg keywords "$keywords" \
        '{
            id: $id,
            tool: $tool,
            turn: ($turn | tonumber),
            timestamp: $timestamp,
            content: $content,
            keywords: $keywords
        }' > "$turn_file" 2>/dev/null || true
}

# ── Recall from cold storage (keyword search) ────────

state_recall_turn() {
    local query="$1"
    local turns_dir="$SESSION_DIR/turns"

    if [[ ! -d "$turns_dir" ]] || [[ -z "$(ls "$turns_dir"/*.json 2>/dev/null)" ]]; then
        echo "No archived turns available."
        return 0
    fi

    local results=""
    local match_count=0

    local turn_file
    for turn_file in "$turns_dir"/*.json; do
        [[ ! -f "$turn_file" ]] && continue

        # Check if query matches keywords or tool name
        local keywords tool_name
        keywords=$(jq -r '.keywords // ""' "$turn_file" 2>/dev/null)
        tool_name=$(jq -r '.tool // ""' "$turn_file" 2>/dev/null)

        local matched=false
        local word
        for word in $query; do
            if echo "$keywords $tool_name" | grep -qi "$word"; then
                matched=true
                break
            fi
        done

        if $matched; then
            match_count=$((match_count + 1))
            local turn_num content_preview
            turn_num=$(jq -r '.turn // "?"' "$turn_file" 2>/dev/null)
            # Return full content for matched turns (up to 2 matches)
            if (( match_count <= 2 )); then
                local full_content
                full_content=$(jq -r '.content // ""' "$turn_file" 2>/dev/null)
                results="${results}
── Turn $turn_num ($tool_name) ──
${full_content}
"
            else
                content_preview=$(jq -r '.content // "" | .[0:200]' "$turn_file" 2>/dev/null)
                results="${results}
── Turn $turn_num ($tool_name) ── [preview]
${content_preview}...
"
            fi
        fi
    done

    if (( match_count == 0 )); then
        echo "No archived turns matching: $query"
        echo "Available archives:"
        for turn_file in "$turns_dir"/*.json; do
            [[ ! -f "$turn_file" ]] && continue
            local tn tt
            tn=$(jq -r '.tool // "?"' "$turn_file" 2>/dev/null)
            tt=$(jq -r '.turn // "?"' "$turn_file" 2>/dev/null)
            echo "  Turn $tt: $tn"
        done
    else
        echo "Found $match_count archived turn(s) matching '$query':$results"
    fi
}

# ── Basic state operations ────────────────────────────

state_get_messages() {
    cat "$MESSAGES_FILE"
}

state_clear() {
    echo '[]' > "$MESSAGES_FILE"
    COLD_TURN_COUNTER=0
    # Clear cold storage too
    rm -f "$SESSION_DIR/turns"/*.json 2>/dev/null
    ui_info "Conversation cleared."
}

state_message_count() {
    jq 'length' "$MESSAGES_FILE"
}

# ── Context management ─────────────────────────────────

state_estimate_tokens() {
    # Rough estimate: 1 token ≈ 4 characters
    local chars
    chars=$(wc -c < "$MESSAGES_FILE")
    echo $(( chars / 4 ))
}

# Emergency trim — last resort fallback
state_trim_if_needed() {
    local est_tokens
    est_tokens=$(state_estimate_tokens)
    local threshold=$(( CONTEXT_SIZE * COMPACT_EMERGENCY_PCT / 100 ))

    if (( est_tokens > threshold )); then
        ui_warn "Context critical (~${est_tokens} tokens). Emergency trim..."
        local tmp="$SESSION_DIR/tmp_msg.json"
        local msg_count
        msg_count=$(jq 'length' "$MESSAGES_FILE")

        if (( msg_count > 12 )); then
            # Keep system message (index 0), warm summary (index 1 if exists), and last 8 messages
            jq '[.[0]] + (if .[1].content and (.[1].content | startswith("[Conversation Summary]")) then [.[1]] else [] end) + .[-8:]' \
                "$MESSAGES_FILE" > "$tmp" && mv "$tmp" "$MESSAGES_FILE"
            local new_tokens
            new_tokens=$(state_estimate_tokens)
            ui_dim "Emergency trim: ~${est_tokens} -> ~${new_tokens} tokens."
        fi
    fi
}

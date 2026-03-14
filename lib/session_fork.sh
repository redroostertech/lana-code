#!/usr/bin/env bash
# Session forking and resume capabilities
# Compatible with bash 3.2+

# ── Fork current session ─────────────────────────────
# Creates a snapshot of the current conversation state that can be resumed later
session_fork() {
    local fork_name="${1:-}"

    # Generate fork ID
    local rand_hex
    rand_hex=$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')
    local fork_id="fork_$(date +%Y%m%d_%H%M%S)_${rand_hex}"

    if [[ -n "$fork_name" ]]; then
        fork_id="fork_${fork_name}_$(date +%Y%m%d_%H%M%S)"
    fi

    local fork_dir="$LANA_HISTORY_DIR/forks"
    mkdir -p "$fork_dir"

    local fork_file="$fork_dir/${fork_id}.json"

    # Save current conversation state + metadata
    local messages
    messages=$(cat "$MESSAGES_FILE" 2>/dev/null) || messages="[]"

    jq -n \
        --arg id "$fork_id" \
        --arg parent_session "$SESSION_ID" \
        --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg work_dir "$WORK_DIR" \
        --arg model "$CURRENT_MODEL" \
        --argjson turns "$SESSION_TURNS" \
        --argjson messages "$messages" \
        --arg accept_mode "$ACCEPT_MODE" \
        '{
            id: $id,
            parent_session: $parent_session,
            created: $created,
            work_dir: $work_dir,
            model: $model,
            turns: $turns,
            messages: $messages,
            accept_mode: $accept_mode
        }' > "$fork_file" 2>/dev/null

    if [[ -f "$fork_file" ]]; then
        ui_success "Session forked: $fork_id"
        ui_dim "  Resume with: lana-code --continue $fork_id"
        ui_dim "  Or in-session: /fork list | /fork load <id>"
    else
        ui_error "Failed to fork session."
        return 1
    fi
}

# ── List available forks ─────────────────────────────
session_fork_list() {
    local fork_dir="$LANA_HISTORY_DIR/forks"

    if [[ ! -d "$fork_dir" ]]; then
        ui_info "No forks found."
        return 0
    fi

    local count=0
    printf "\n${C_BOLD}Session Forks${C_RESET}\n\n"

    local fork_file
    for fork_file in "$fork_dir"/fork_*.json; do
        [[ ! -f "$fork_file" ]] && continue
        count=$((count + 1))

        local fid fcreated fdir fmodel fturns
        fid=$(jq -r '.id // empty' "$fork_file" 2>/dev/null)
        fcreated=$(jq -r '.created // empty' "$fork_file" 2>/dev/null)
        fdir=$(jq -r '.work_dir // empty' "$fork_file" 2>/dev/null)
        fmodel=$(jq -r '.model // empty' "$fork_file" 2>/dev/null)
        fturns=$(jq -r '.turns // 0' "$fork_file" 2>/dev/null)

        local short_dir
        short_dir=$(echo "$fdir" | sed "s|^$HOME|~|")

        printf "  ${C_BOLD}%s${C_RESET}\n" "$fid"
        printf "  ${C_DIM}%s  %s  %s turns  %s${C_RESET}\n\n" \
            "${fcreated:-?}" "$fmodel" "$fturns" "$short_dir"
    done

    if (( count == 0 )); then
        ui_info "No forks found."
    fi
}

# ── Load a fork into current session ─────────────────
session_fork_load() {
    local fork_id="$1"

    if [[ -z "$fork_id" ]]; then
        ui_error "Usage: /fork load <fork-id>"
        return 1
    fi

    local fork_dir="$LANA_HISTORY_DIR/forks"

    # Try exact match first, then prefix match
    local fork_file=""
    if [[ -f "$fork_dir/${fork_id}.json" ]]; then
        fork_file="$fork_dir/${fork_id}.json"
    else
        # Prefix match
        local match
        for match in "$fork_dir"/${fork_id}*.json; do
            if [[ -f "$match" ]]; then
                fork_file="$match"
                break
            fi
        done
    fi

    if [[ -z "$fork_file" || ! -f "$fork_file" ]]; then
        ui_error "Fork not found: $fork_id"
        return 1
    fi

    # Restore conversation state
    local messages
    messages=$(jq '.messages' "$fork_file" 2>/dev/null)

    if [[ -z "$messages" || "$messages" == "null" ]]; then
        ui_error "Fork has no messages."
        return 1
    fi

    # Replace current messages
    echo "$messages" > "$MESSAGES_FILE"

    # Restore metadata
    local fork_model fork_mode fork_turns
    fork_model=$(jq -r '.model // empty' "$fork_file" 2>/dev/null)
    fork_mode=$(jq -r '.accept_mode // "confirm"' "$fork_file" 2>/dev/null)
    fork_turns=$(jq -r '.turns // 0' "$fork_file" 2>/dev/null)

    if [[ -n "$fork_model" ]]; then
        CURRENT_MODEL="$fork_model"
    fi
    ACCEPT_MODE="$fork_mode"
    SESSION_TURNS=$fork_turns

    local fid
    fid=$(jq -r '.id // empty' "$fork_file" 2>/dev/null)
    ui_success "Loaded fork: $fid"
    ui_dim "  Conversation restored with $fork_turns turns."
}

# ── Resume last session (for --continue CLI flag) ────
session_resume() {
    local query="${1:-}"

    if [[ -z "$query" ]]; then
        # Resume the most recent session
        local index_file="$LANA_HISTORY_DIR/index.json"
        if [[ ! -f "$index_file" ]]; then
            ui_error "No sessions to resume."
            return 1
        fi

        local last_id
        last_id=$(jq -r '.[-1].id // empty' "$index_file" 2>/dev/null)

        if [[ -z "$last_id" ]]; then
            ui_error "No sessions found."
            return 1
        fi

        # Check for fork first
        if [[ -f "$LANA_HISTORY_DIR/forks/${query}.json" ]]; then
            session_fork_load "$query"
            return $?
        fi

        # Load last session's summary into context
        history_recall "$last_id"
        return $?
    fi

    # Check if it's a fork ID
    if [[ "$query" == fork_* ]] && [[ -f "$LANA_HISTORY_DIR/forks/${query}.json" ]]; then
        session_fork_load "$query"
        return $?
    fi

    # Try as a session recall
    history_recall "$query"
}

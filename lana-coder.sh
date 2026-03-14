#!/usr/bin/env bash
# LANA CODE — main REPL and agentic tool loop
# Note: no `set -e` — interactive REPLs must handle errors explicitly

set -uo pipefail 2>/dev/null || true

# ── Resolve script directory ──────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Load modules ──────────────────────────────────────
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/lib/ui.sh"
source "$SCRIPT_DIR/lib/state.sh"
source "$SCRIPT_DIR/lib/api.sh"
source "$SCRIPT_DIR/lib/tools.sh"
source "$SCRIPT_DIR/lib/tools_awareness.sh"
source "$SCRIPT_DIR/lib/tools_execution.sh"
source "$SCRIPT_DIR/lib/tools_intelligence.sh"
source "$SCRIPT_DIR/lib/tools_fileops.sh"
source "$SCRIPT_DIR/lib/project.sh"
source "$SCRIPT_DIR/lib/history.sh"
source "$SCRIPT_DIR/lib/plan_mode.sh"
source "$SCRIPT_DIR/lib/permissions.sh"
source "$SCRIPT_DIR/lib/session_fork.sh"
source "$SCRIPT_DIR/lib/hooks.sh"
source "$SCRIPT_DIR/lib/subagents.sh"
source "$SCRIPT_DIR/lib/mcp.sh"
source "$SCRIPT_DIR/setup.sh"

# ── Globals ───────────────────────────────────────────
WORK_DIR="$(pwd)"
CURRENT_MODEL="${LANA_MODEL:-$DEFAULT_MODEL}"
AGENT_INTERRUPTED=false

# Token tracking
SESSION_PROMPT_TOKENS=0
SESSION_COMPLETION_TOKENS=0
TURN_PROMPT_TOKENS=0
TURN_COMPLETION_TOKENS=0

# ── Discover installed system tools ──────────────────
_discover_system_tools() {
    local tools_found=""

    # Check common development tools
    local dev_tools="git swift xcodebuild python3 python node npm npx cargo rustc go \
make gcc g++ clang cmake docker brew pip3 ruby gem pod java javac kotlin dotnet php perl lua zig"

    for tool in $dev_tools; do
        if command -v "$tool" >/dev/null 2>&1; then
            tools_found="$tools_found $tool"
        fi
    done

    # Xcode-specific detection
    local xcode_info=""
    if command -v xcodebuild >/dev/null 2>&1; then
        local xcode_version
        xcode_version=$(xcodebuild -version 2>/dev/null | head -1) || true
        xcode_info="- Xcode: ${xcode_version:-installed}
- Create Swift packages: swift package init --type executable
- Build Xcode projects: xcodebuild -project Foo.xcodeproj -scheme Foo build
- For Swift packages: swift build, swift test, swift run
- Do NOT use xcode-create or other non-existent commands"
    fi

    # Trim leading space
    tools_found="${tools_found# }"

    echo "- Installed CLI tools: ${tools_found}"
    [[ -n "$xcode_info" ]] && echo "$xcode_info"
}

# ── Build system prompt with environment context ──────
_build_system_prompt() {
    local base_prompt
    base_prompt=$(cat "$SCRIPT_DIR/prompts/system.txt")

    local git_info=""
    if [[ -d "$WORK_DIR/.git" ]]; then
        local branch
        branch=$(cd "$WORK_DIR" && git rev-parse --abbrev-ref HEAD 2>/dev/null) || true
        [[ -n "$branch" ]] && git_info="- Git branch: $branch"
    fi

    # Discover installed CLI tools
    local system_tools
    system_tools=$(_discover_system_tools)

    # Auto-discover LANA.md project instructions
    local project_instructions=""
    local lana_md=""
    for candidate in "$WORK_DIR/LANA.md" "$WORK_DIR/.lana.md" "$WORK_DIR/lana.md"; do
        if [[ -f "$candidate" ]]; then
            lana_md="$candidate"
            break
        fi
    done
    if [[ -n "$lana_md" ]]; then
        project_instructions="

## Project Instructions (from $(basename "$lana_md"))

$(cat "$lana_md")"
        ui_dim "  loaded: $(basename "$lana_md")"
    fi

    cat <<EOF
${base_prompt}

## Environment
- Working directory: $WORK_DIR
- Platform: $(uname -s) $(uname -m)
- Shell: ${SHELL:-/bin/bash}
- Date: $(date +%Y-%m-%d)
${git_info}
${system_tools}

IMPORTANT: Only use commands from the installed CLI tools listed above. If a tool is not listed, it is NOT installed — tell the user and suggest how to install it (e.g., "brew install foo").${project_instructions}
EOF
}

_update_system_prompt() {
    local prompt
    prompt=$(_build_system_prompt)
    state_add_system "$prompt"
}

# Pre-seed the conversation with a working tool-use example.
# This teaches the model the exact flow: user asks → tool call → result → respond.
# Most effective technique for ensuring smaller models use tools correctly.
# Pre-seed with a single tool-use round-trip to teach the model the pattern.
# Minimized to 4 messages (~400 tokens) instead of 8 (~800 tokens).
_seed_tool_example() {
    local tmp="$SESSION_DIR/tmp_msg.json"

    jq '. + [
        {"role": "user", "content": "What directory am I in?"},
        {"role": "assistant", "content": null, "tool_calls": [
            {"id": "call_seed_1", "type": "function", "function": {"name": "bash", "arguments": "{\"command\": \"pwd\"}"}}
        ]},
        {"role": "tool", "tool_call_id": "call_seed_1", "name": "bash", "content": "'"$WORK_DIR"'"},
        {"role": "assistant", "content": "You are in `'"$WORK_DIR"'`."}
    ]' "$MESSAGES_FILE" > "$tmp" && mv "$tmp" "$MESSAGES_FILE"
}

# ── Cleanup on exit ───────────────────────────────────
cleanup() {
    spinner_stop 2>/dev/null
    hooks_session_end 2>/dev/null
    history_save_session 2>/dev/null
    # Only stop the server if we started it (not in proxy mode)
    [[ "$USE_PROXY" != "true" ]] && server_stop 2>/dev/null
    rm -rf "$SESSION_DIR" 2>/dev/null
    printf "\n${C_DIM}goodbye.${C_RESET}\n"
}
trap cleanup EXIT

# Handle Ctrl+C — interrupt the current operation, not the whole script
_handle_interrupt() {
    AGENT_INTERRUPTED=true
    spinner_stop 2>/dev/null
    printf "\n" >/dev/tty
    ui_warn "Interrupted."
}
trap _handle_interrupt INT

# ── /status command ────────────────────────────────────
_cmd_status() {
    ui_status_dashboard "$WORK_DIR" "$CURRENT_MODEL" "$SESSION_TURNS"
}

# ── /memory command ───────────────────────────────────
_cmd_memory() {
    local arg="$1"
    local memory_file="$WORK_DIR/.lana/memory.json"

    # Parse subcommand
    local subcmd="" key="" value=""
    if [[ -z "$arg" ]]; then
        subcmd="show"
    else
        subcmd="${arg%% *}"
        local rest="${arg#* }"
        [[ "$subcmd" == "$rest" ]] && rest=""

        case "$subcmd" in
            set)
                key="${rest%% *}"
                value="${rest#* }"
                [[ "$key" == "$value" ]] && value=""
                ;;
            del|delete)
                key="$rest"
                subcmd="del"
                ;;
            *)
                # Treat as key lookup
                key="$subcmd"
                subcmd="get"
                ;;
        esac
    fi

    case "$subcmd" in
        show)
            if [[ ! -f "$memory_file" ]]; then
                ui_info "No memories stored. Use: /memory set <key> <value>"
                return 0
            fi
            local count
            count=$(jq 'length' "$memory_file" 2>/dev/null) || count=0
            if [[ "$count" -eq 0 ]]; then
                ui_info "No memories stored."
                return 0
            fi
            printf "\n  ${C_BOLD}Project Memories${C_RESET} ${C_DIM}(%s entries)${C_RESET}\n" "$count"
            printf "  ${C_DIM}%s${C_RESET}\n" "─────────────────────────"
            local keys_list
            keys_list=$(jq -r 'keys[]' "$memory_file" 2>/dev/null) || true
            while IFS= read -r k; do
                [[ -z "$k" ]] && continue
                local v
                v=$(jq -r --arg k "$k" '.[$k]' "$memory_file" 2>/dev/null) || true
                printf "  ${C_CYAN}%s:${C_RESET} %s\n" "$k" "$v"
            done <<< "$keys_list"
            printf "\n"
            ;;
        get)
            if [[ ! -f "$memory_file" ]]; then
                ui_error "No memories stored."
                return 0
            fi
            local v
            v=$(jq -r --arg k "$key" '.[$k] // empty' "$memory_file" 2>/dev/null) || true
            if [[ -n "$v" ]]; then
                printf "  ${C_CYAN}%s:${C_RESET} %s\n" "$key" "$v"
            else
                ui_error "Memory not found: $key"
            fi
            ;;
        set)
            if [[ -z "$key" || -z "$value" ]]; then
                ui_error "Usage: /memory set <key> <value>"
                return 0
            fi
            mkdir -p "$WORK_DIR/.lana"
            if [[ ! -f "$memory_file" ]]; then
                echo '{}' > "$memory_file"
            fi
            local tmp="${memory_file}.tmp"
            jq --arg k "$key" --arg v "$value" '.[$k] = $v' "$memory_file" > "$tmp" 2>/dev/null
            if [[ -s "$tmp" ]]; then
                mv "$tmp" "$memory_file"
                ui_success "Memory saved: $key = \"$value\""
            else
                rm -f "$tmp"
                ui_error "Failed to save memory."
            fi
            ;;
        del)
            if [[ -z "$key" ]]; then
                ui_error "Usage: /memory del <key>"
                return 0
            fi
            if [[ ! -f "$memory_file" ]]; then
                ui_error "No memories stored."
                return 0
            fi
            local tmp="${memory_file}.tmp"
            jq --arg k "$key" 'del(.[$k])' "$memory_file" > "$tmp" 2>/dev/null
            if [[ -s "$tmp" ]]; then
                mv "$tmp" "$memory_file"
                ui_success "Memory deleted: $key"
            else
                rm -f "$tmp"
                ui_error "Failed to delete memory."
            fi
            ;;
    esac
}

# ── Handle CLI commands ───────────────────────────────
handle_command() {
    local input="$1"
    local cmd="${input%% *}"
    local arg="${input#* }"
    [[ "$cmd" == "$arg" ]] && arg=""

    case "$cmd" in
        /quit|/exit|/q)
            exit 0
            ;;
        /clear|/c)
            state_clear
            _update_system_prompt
            return 0
            ;;
        /model|/m)
            if [[ -z "$arg" ]]; then
                # Interactive model selector
                ui_info "Current: $CURRENT_MODEL"
                local model_choice
                model_choice=$(ui_select "Switch model" $MODEL_NAMES) || { return 0; }
                if [[ -n "$model_choice" ]]; then
                    arg="$model_choice"
                else
                    return 0
                fi
            fi
            if [[ "$USE_PROXY" == "true" ]]; then
                # In proxy mode, update the model name — proxy handles routing
                CURRENT_MODEL="$arg"
                API_MODEL="$arg"
                export LANA_API_MODEL="$API_MODEL"
                ui_success "Model set to: $arg (routed via lana-proxy)"
                state_clear
                _update_system_prompt
            else
                server_switch_model "$arg"
                state_clear
                _update_system_prompt
            fi
            return 0
            ;;
        /load|/l)
            local dir="${arg:-$WORK_DIR}"
            [[ "$dir" != /* ]] && dir="$WORK_DIR/$dir"
            local project_context
            project_context=$(project_load "$dir")
            local system_prompt
            system_prompt=$(_build_system_prompt)
            system_prompt="${system_prompt}\n\n## Loaded Project Context\n\n${project_context}"
            state_add_system "$system_prompt"
            ui_success "Project loaded into context."
            return 0
            ;;
        /cd)
            if [[ -z "$arg" ]]; then
                ui_info "Working directory: $WORK_DIR"
            elif [[ -d "$arg" ]]; then
                [[ "$arg" != /* ]] && arg="$WORK_DIR/$arg"
                WORK_DIR="$arg"
                _update_system_prompt
                permissions_reload
                hooks_reload
                mcp_reload
                ui_info "Working directory: $WORK_DIR"
            else
                ui_error "Not a directory: $arg"
            fi
            return 0
            ;;
        /index|/i)
            local dir="${arg:-$WORK_DIR}"
            [[ "$dir" != /* ]] && dir="$WORK_DIR/$dir"
            project_index "$dir"
            return 0
            ;;
        /status|/s)
            _cmd_status
            return 0
            ;;
        /search)
            if [[ -z "$arg" ]]; then
                ui_error "Usage: /search <query>"
            else
                project_index_search "$WORK_DIR" "$arg"
            fi
            return 0
            ;;
        /memory|/mem)
            _cmd_memory "$arg"
            return 0
            ;;
        /history|/hs)
            if [[ -n "$arg" ]]; then
                history_list "$arg"
            else
                # Interactive history browser
                local index_file="$LANA_HISTORY_DIR/index.json"
                if [[ ! -f "$index_file" ]]; then
                    ui_info "No history found."
                    return 0
                fi
                local session_labels=()
                local session_ids=()
                while IFS='|' read -r sid slabel; do
                    session_ids+=("$sid")
                    session_labels+=("$slabel")
                done < <(jq -r '.[-20:] | reverse | .[] | "\(.id)|\(.start | .[0:10])  \(.model)  \(.turns)t  \(.summary | .[0:60])"' "$index_file" 2>/dev/null)
                if (( ${#session_labels[@]} == 0 )); then
                    ui_info "No history found."
                    return 0
                fi
                local choice
                choice=$(ui_search_select "Session History" "${session_labels[@]}") || { return 0; }
                if [[ -n "$choice" ]]; then
                    # Find matching session ID
                    local idx=0
                    for lbl in "${session_labels[@]}"; do
                        if [[ "$lbl" == "$choice" ]]; then
                            history_recall "${session_ids[$idx]}"
                            break
                        fi
                        idx=$((idx + 1))
                    done
                fi
            fi
            return 0
            ;;
        /recall|/rc)
            if [[ -z "$arg" ]]; then
                ui_error "Usage: /recall <session-id or search term>"
            else
                history_recall "$arg"
            fi
            return 0
            ;;
        /compact|/cc)
            if history_compact; then
                ui_success "Conversation compacted."
            else
                ui_info "Nothing to compact."
            fi
            return 0
            ;;
        /accept|/a)
            case "$arg" in
                auto-edit|auto)
                    ACCEPT_MODE="auto-edit"
                    ui_info "Accept mode: auto-edit (file changes auto-accepted, bash still confirms)"
                    ;;
                yolo)
                    ACCEPT_MODE="yolo"
                    ui_warn "Accept mode: yolo (ALL actions auto-accepted — be careful!)"
                    ;;
                confirm|"")
                    ACCEPT_MODE="confirm"
                    ui_info "Accept mode: confirm (all mutations require confirmation)"
                    ;;
                *)
                    ui_error "Unknown mode: $arg (options: confirm, auto-edit, yolo)"
                    ;;
            esac
            return 0
            ;;
        /fork)
            case "$arg" in
                list|ls)
                    session_fork_list
                    ;;
                load)
                    # Need to re-parse to get the ID after "load"
                    local fork_rest="${input#*/fork load }"
                    if [[ "$fork_rest" == "$input" ]]; then
                        ui_error "Usage: /fork load <fork-id>"
                    else
                        session_fork_load "$fork_rest"
                    fi
                    ;;
                "")
                    session_fork
                    ;;
                *)
                    session_fork "$arg"
                    ;;
            esac
            return 0
            ;;
        /plan|/p)
            case "$arg" in
                execute|exec)
                    plan_mode_execute
                    # Trigger agent turn to execute the plan
                    run_agent_turn || true
                    ;;
                exit|quit)
                    plan_mode_exit
                    ;;
                "")
                    if [[ "$PLAN_MODE" == "true" ]]; then
                        ui_info "Already in plan mode. Use /plan execute or /plan exit."
                    else
                        plan_mode_enter
                    fi
                    ;;
                *)
                    ui_error "Usage: /plan [execute|exit]"
                    ;;
            esac
            return 0
            ;;
        /undo|/u)
            local stack_file="$SESSION_DIR/undo_stack.txt"
            if [[ ! -f "$stack_file" || ! -s "$stack_file" ]]; then
                ui_info "Nothing to undo."
                return 0
            fi
            # Get the last entry
            local last_entry
            last_entry=$(tail -1 "$stack_file")
            local undo_path="${last_entry%%|*}"
            local undo_backup="${last_entry#*|}"
            if [[ -f "$undo_backup" ]]; then
                cp "$undo_backup" "$undo_path"
                # Remove last line from stack
                local tmp_stack="$SESSION_DIR/undo_tmp_$$"
                sed '$d' "$stack_file" > "$tmp_stack" 2>/dev/null || true
                mv "$tmp_stack" "$stack_file"
                ui_info "Reverted: $(basename "$undo_path")"
                printf "  ${C_DIM}%s${C_RESET}\n" "$undo_path"
            else
                ui_error "Backup file missing: $undo_backup"
            fi
            return 0
            ;;
        /debug|/d)
            if [[ "${LANA_DEBUG:-false}" == "true" || "${LANA_DEBUG:-0}" == "1" ]]; then
                LANA_DEBUG=false
                ui_info "Debug mode: OFF"
            else
                LANA_DEBUG=true
                ui_info "Debug mode: ON"
            fi
            return 0
            ;;
        /version|/v)
            printf "  ${C_BOLD}LANA CODE${C_RESET} v0.3.0\n"
            printf "  ${C_DIM}Model: %s${C_RESET}\n" "$(basename "$(get_model_path "$CURRENT_MODEL")" .gguf)"
            printf "  ${C_DIM}Server: %s${C_RESET}\n" "$API_URL"
            return 0
            ;;
        /help|/h)
            ui_help
            return 0
            ;;
        /subagent|/sa)
            if [[ -z "$arg" ]]; then
                printf "\n  ${C_BOLD}Usage:${C_RESET} /subagent <type> <task>\n"
                printf "  ${C_DIM}Types: research, plan, execute${C_RESET}\n\n"
                printf "  ${C_BOLD}Examples:${C_RESET}\n"
                printf "  ${C_DIM}/sa research Explore lib/ and summarize each module${C_RESET}\n"
                printf "  ${C_DIM}/sa plan How to add WebSocket support${C_RESET}\n"
                printf "  ${C_DIM}/sa execute Refactor the error handling in api.sh${C_RESET}\n\n"
                return 0
            fi
            local sa_type="${arg%% *}"
            local sa_task="${arg#* }"
            [[ "$sa_type" == "$sa_task" ]] && sa_task=""
            # Validate type
            case "$sa_type" in
                research|plan|execute) ;;
                r) sa_type="research" ;;
                p) sa_type="plan" ;;
                e) sa_type="execute" ;;
                *)
                    # No type given — treat entire arg as task, default to research
                    sa_task="$arg"
                    sa_type="research"
                    ;;
            esac
            if [[ -z "$sa_task" ]]; then
                ui_error "Task is required. Usage: /subagent <type> <task>"
                return 0
            fi
            # Build tool args and run
            local sa_args
            sa_args=$(jq -n --arg task "$sa_task" --arg type "$sa_type" '{task: $task, type: $type}')
            local sa_result
            sa_result=$(tool_subagent "$sa_args" 2>&1) || true
            # Inject result into conversation so the main agent has context
            if [[ -n "$sa_result" ]]; then
                state_add_message "user" "[User ran /subagent $sa_type] Task: $sa_task"
                state_add_message "assistant" "$sa_result"
                SESSION_TURNS=$((SESSION_TURNS + 1))
                # Print the result (subagent already showed progress, just show the summary)
                printf "\n${C_BBLUE}subagent result${C_RESET}\n" >/dev/tty
                printf '%s\n' "$sa_result" | while IFS= read -r _line; do
                    printf "  %s\n" "$_line" >/dev/tty
                done
                printf "\n" >/dev/tty
            fi
            return 0
            ;;
        /*)
            ui_error "Unknown command: $cmd (type /help for commands)"
            return 0
            ;;
    esac
    return 1  # not a command, treat as chat input
}

# ── Detect when model describes commands instead of calling tools ──
_should_nudge() {
    local content="$1"

    # Pattern 1: Code blocks with shell language tags
    if echo "$content" | grep -qE '```(bash|sh|shell|zsh|terminal|console)?$'; then
        return 0
    fi

    # Pattern 2: Phrases indicating model is telling user to run something
    if echo "$content" | grep -qiE \
        'run (this|the|these) command|you (can|should|need to|could) run|execute (this|the)|paste (this|the)|try running|you.ll need to|I cannot (run|execute)|I can.t (run|execute)|please run|copy and (paste|run)'; then
        return 0
    fi

    # Pattern 3: Inline code that looks like a command
    if echo "$content" | grep -qE '`(sudo |brew |npm |pip |git |swift |xcodebuild |make |cargo |docker |cd |mkdir |cp |mv |rm |curl |wget )'; then
        return 0
    fi

    # Pattern 4: Model says it WILL do something next — regardless of response length
    # Catches: "Let's search...", "I'll read...", "Next, I'll...", "I'm going to..."
    if echo "$content" | grep -qiE "(let'?s (start|proceed|search|check|look|read|find|try|examine|open)|I('ll| will| am going to|'m going to) (search|read|check|look|find|open|examine|try|run|execute|create|build)|next.*(search|read|check|look|step)|proceed (with|to)|let me (search|read|check|look|find))"; then
        return 0
    fi

    # Pattern 5: Short response that looks like planning without executing
    local line_count
    line_count=$(echo "$content" | wc -l | tr -d ' ')
    if (( line_count < 4 )); then
        if echo "$content" | grep -qiE "(first|step [0-9]|check if|install|create|build|set up|run |execute)"; then
            return 0
        fi
    fi

    # Pattern 6: Model offers to do something or asks user to decide instead of just doing it
    if echo "$content" | grep -qiE "(would you like (me to|to proceed|to explore|to continue)|shall I|want me to|I can (also |help )?do|if you.d like|I could|do you want me|would you prefer|which .* would you)"; then
        return 0
    fi

    return 1
}

# ── Agentic tool loop ─────────────────────────────────

run_agent_turn() {
    local loop_count=0
    local _nudge_attempted=false
    local _nudge_count=0
    AGENT_INTERRUPTED=false
    TURN_PROMPT_TOKENS=0
    TURN_COMPLETION_TOKENS=0

    # Loop detection: track recent tool calls as "name:args_hash"
    local _recent_calls=""
    local _consecutive_failures=0
    local _total_tool_calls=0
    local _task_complete=false

    # Outer loop: replaces recursive self-call at MAX_TOOL_LOOPS checkpoint
    while true; do

    while [ "$loop_count" -lt "$MAX_TOOL_LOOPS" ]; do
        loop_count=$((loop_count + 1))

        # Check for interrupt
        if $AGENT_INTERRUPTED; then
            AGENT_INTERRUPTED=false
            ui_warn "Agent turn interrupted."
            return 0
        fi

        # Get current messages
        local messages
        messages=$(state_get_messages)

        # Inject session progress context (ephemeral — not stored in state)
        local _est_tokens _ctx_pct _progress_msg
        _est_tokens=$(state_estimate_tokens)
        _ctx_pct=$((_est_tokens * 100 / CONTEXT_SIZE))
        _progress_msg="[Session: turn ${SESSION_TURNS}, loop ${loop_count}/${MAX_TOOL_LOOPS}, context ${_ctx_pct}% used (~${_est_tokens}/${CONTEXT_SIZE} tokens)]"
        if (( _ctx_pct >= 50 )); then
            _progress_msg="${_progress_msg} Warning: context filling up. Be concise, compress outputs, avoid unnecessary tool calls."
        fi
        messages=$(echo "$messages" | jq --arg msg "$_progress_msg" '. + [{"role": "user", "content": $msg}]')

        # Check server health before API call
        if ! api_health_check 2>/dev/null; then
            if [[ "$USE_PROXY" == "true" ]]; then
                ui_error "lana-proxy not responding at ${API_URL}"
                return 1
            fi
            ui_warn "Server not responding. Restarting..."
            local model_path
            model_path=$(get_model_path "$CURRENT_MODEL")
            if ! server_start "$model_path"; then
                ui_error "Server restart failed."
                return 1
            fi
        fi

        # Call the API (streaming prints text to terminal in real-time)
        # The perl streaming script handles its own animated thinking spinner
        local response
        response=$(api_chat_completion_stream "$messages") || true

        # Check for interrupt during API call
        if $AGENT_INTERRUPTED; then
            AGENT_INTERRUPTED=false
            return 0
        fi

        # Retry once if response is empty (server may have just restarted)
        if [[ -z "$response" ]]; then
            ui_warn "Empty response — checking server..."
            if ! api_health_check 2>/dev/null; then
                if [[ "$USE_PROXY" == "true" ]]; then
                    ui_error "lana-proxy not responding at ${API_URL}"
                else
                    ui_warn "Server crashed. Restarting..."
                    local model_path
                    model_path=$(get_model_path "$CURRENT_MODEL")
                    if server_start "$model_path"; then
                        ui_info "Server restarted. Retrying..."
                        response=$(api_chat_completion_stream "$messages") || true
                    fi
                fi
            fi
            if [[ -z "$response" ]]; then
                ui_error "Empty response from server. Try again or /clear to reset."
                return 1
            fi
        fi

        # Check for errors
        local error
        error=$(echo "$response" | jq -r '.error // empty' 2>/dev/null) || true
        if [[ -n "$error" ]]; then
            ui_error "$error"
            return 1
        fi

        # Track token usage
        local usage
        usage=$(api_get_usage "$response")
        local pt ct
        pt=$(echo "$usage" | jq -r '.prompt_tokens')
        ct=$(echo "$usage" | jq -r '.completion_tokens')
        TURN_PROMPT_TOKENS=$((TURN_PROMPT_TOKENS + pt))
        TURN_COMPLETION_TOKENS=$((TURN_COMPLETION_TOKENS + ct))

        # Validate response is actually JSON before proceeding
        if ! echo "$response" | jq empty 2>/dev/null; then
            printf "\n${C_YELLOW}  ${IC_WARN} invalid response from server (not JSON) — retrying${C_RESET}\n" >/dev/tty
            ui_debug "Raw response (first 200 chars): $(echo "$response" | head -c 200)"
            continue
        fi

        # Get content
        local content
        content=$(api_get_content "$response")

        # Check finish reason — if "length", model hit max_tokens
        local finish_reason
        finish_reason=$(api_get_finish_reason "$response")

        # Debug: always show path taken for text-only responses (temporary diagnostic)
        ui_debug "finish_reason=$finish_reason content_len=${#content} has_tool_calls=$(echo "$response" | jq -r '.choices[0].message.tool_calls | length // 0' 2>/dev/null)"

        # Strip thinking blocks (Qwen3 models)
        if [[ -n "$content" && "$content" != "null" ]]; then
            content=$(api_strip_thinking "$content")
        fi

        # If model hit max_tokens mid-response, treat as text-only
        # (any partial tool calls are garbage and should be discarded)
        if [[ "$finish_reason" == "length" ]]; then
            ui_debug "finish_reason=length — model hit max_tokens, discarding partial tool calls"
            # Content was already streamed — just handle as text-only
            if [[ -n "$content" && "$content" != "null" ]]; then
                state_add_message "assistant" "$content"
                state_add_message "user" "[SYSTEM] Your response was cut off by the token limit. You were about to call a tool. Call that tool now — do not repeat the text you already wrote."
                printf "\n${C_DIM}  ${IC_WARN} response truncated (max_tokens) — pushing to continue${C_RESET}\n" >/dev/tty
                continue
            fi
        fi

        # Check if the response has structured tool calls
        local has_tools=false
        local tool_calls="[]"

        if api_has_tool_calls "$response"; then
            has_tools=true
            tool_calls=$(api_get_tool_calls "$response")
            ui_debug "Structured tool_calls detected: $(echo "$tool_calls" | jq -c '.[].function.name' 2>/dev/null)"
        elif [[ -n "$content" && "$content" != "null" ]]; then
            # Fallback 1: check if content contains <tool_call> tags
            local parsed_tc
            parsed_tc=$(api_parse_text_tool_calls "$content") || true
            if [[ -n "$parsed_tc" && "$parsed_tc" != "[]" ]]; then
                has_tools=true
                tool_calls="$parsed_tc"
                content=$(api_strip_tool_call_tags "$content")
                ui_debug "Text-based tool_calls parsed from content"
            else
                # Fallback 2 & 3: only use when the model hasn't been making
                # structured tool calls. If the model already used tools this turn,
                # code blocks and NL descriptions are likely documentation/examples.
                if (( _total_tool_calls == 0 )); then
                    # Fallback 2: check for ```sh/```bash code blocks → auto-execute
                    local parsed_blocks
                    parsed_blocks=$(api_parse_shell_code_blocks "$content") || true
                    if [[ -n "$parsed_blocks" && "$parsed_blocks" != "[]" ]]; then
                        has_tools=true
                        tool_calls="$parsed_blocks"
                        content=$(api_strip_shell_code_blocks "$content")
                        ui_debug "Shell code blocks converted to bash tool calls"
                    else
                        # Fallback 3: parse natural language tool intentions
                        # "I'll use file_tree", "Let me read the README", etc.
                        local parsed_nl
                        parsed_nl=$(api_parse_nl_tool_intentions "$content" "$WORK_DIR") || true
                        if [[ -n "$parsed_nl" && "$parsed_nl" != "[]" ]]; then
                            has_tools=true
                            tool_calls="$parsed_nl"
                            ui_debug "Natural language tool intentions parsed from content"
                            printf "\n${C_DIM}  ${IC_INFO} auto-executing tools the model described...${C_RESET}\n" >/dev/tty
                        fi
                    fi
                fi
            fi
        fi

        if $has_tools; then
            # Content was already streamed to terminal — just add to state
            state_add_assistant_tool_calls "$tool_calls" "$content"

            # Execute each tool call
            local num_tools
            num_tools=$(echo "$tool_calls" | jq 'length')

            local i=0
            while [ "$i" -lt "$num_tools" ]; do
                # Check for interrupt
                if $AGENT_INTERRUPTED; then
                    AGENT_INTERRUPTED=false
                    ui_warn "Tool execution interrupted."
                    return 0
                fi

                local tc
                tc=$(echo "$tool_calls" | jq -c ".[$i]")
                local tc_id tc_name tc_args
                tc_id=$(echo "$tc" | jq -r '.id')
                tc_name=$(echo "$tc" | jq -r '.function.name')
                tc_args=$(echo "$tc" | jq -r '.function.arguments')

                # Parse arguments — handle both JSON objects and stringified JSON
                if ! echo "$tc_args" | jq empty 2>/dev/null; then
                    tc_args=$(echo "$tc_args" | jq -R 'fromjson' 2>/dev/null || echo '{}')
                fi

                ui_debug "Tool call: $tc_name args=$tc_args"

                # Skip broken/partial tool calls (e.g. from max_tokens truncation)
                if [[ -z "$tc_name" || "$tc_name" == "null" ]]; then
                    printf "${C_DIM}  ${BOX_V}${C_RESET} ${C_YELLOW}${IC_WARN} skipped broken tool call (empty name)${C_RESET}\n" >/dev/tty
                    # Must add a dummy tool result to keep conversation state valid
                    state_add_tool_result "$tc_id" "unknown" "Error: malformed tool call (empty name) — likely truncated by max_tokens."
                    i=$((i + 1))
                    continue
                fi

                # Plan mode: block non-read-only tools
                if ! plan_mode_allows_tool "$tc_name"; then
                    printf "${C_DIM}  ${BOX_V}${C_RESET} ${C_YELLOW}${IC_LOCK} blocked: %s ${C_DIM}(plan mode)${C_RESET}\n" "$tc_name" >/dev/tty
                    state_add_tool_result "$tc_id" "$tc_name" "Error: Tool '$tc_name' is not available in plan mode. Only read-only tools can be used. Create a plan describing the changes you would make, then the user will run /plan execute."
                    i=$((i + 1))
                    continue
                fi

                # Fine-grained permission check
                local perm_decision
                perm_decision=$(permissions_check "$tc_name" "$tc_args")
                if [[ "$perm_decision" == "deny" ]]; then
                    printf "${C_DIM}  ${BOX_V}${C_RESET} ${C_RED}${IC_LOCK} denied: %s ${C_DIM}(permission rule)${C_RESET}\n" "$tc_name" >/dev/tty
                    state_add_tool_result "$tc_id" "$tc_name" "Error: Tool '$tc_name' denied by permission rules in .lana/permissions.json."
                    i=$((i + 1))
                    continue
                fi

                # Show tool call (read-only tools show automatically)
                local is_readonly=false
                case "$tc_name" in
                    read_file|grep_search|glob_find|search_index|project_detect|git_smart|context_compress|web_fetch|tree_parse|lsp_query|file_tree|recall_turn|task_complete) is_readonly=true ;;
                esac

                if $is_readonly && $AUTO_CONFIRM_READ; then
                    local display_args
                    display_args=$(echo "$tc_args" | jq -r 'to_entries | map(.value) | join(" ")' 2>/dev/null) || true
                    ui_tool_call "$tc_name" "$display_args"
                fi

                # Pre-tool hook
                hooks_pre_tool "$tc_name" "$tc_args"

                # Execute the tool (pass permission decision as override)
                export _PERM_OVERRIDE="$perm_decision"
                local result
                result=$(execute_tool "$tc_name" "$tc_args" 2>&1) || true
                unset _PERM_OVERRIDE

                # Post-tool hook
                hooks_post_tool "$tc_name" "$tc_args" "$result"

                # Auto-verify file mutations: syntax-check written/edited files
                if [[ "$tc_name" == "write_file" || "$tc_name" == "edit_file" ]]; then
                    local _verify_path
                    _verify_path=$(echo "$tc_args" | jq -r '.path // .file_path // empty' 2>/dev/null)
                    if [[ -n "$_verify_path" && -f "$_verify_path" ]]; then
                        local _verify_result=""
                        local _ext="${_verify_path##*.}"
                        case "$_ext" in
                            sh|bash)
                                _verify_result=$(bash -n "$_verify_path" 2>&1) || true ;;
                            py)
                                _verify_result=$(python3 -c "import py_compile; py_compile.compile('$_verify_path', doraise=True)" 2>&1) || true ;;
                            js|jsx)
                                if command -v node >/dev/null 2>&1; then
                                    _verify_result=$(node --check "$_verify_path" 2>&1) || true
                                fi ;;
                            ts|tsx)
                                if command -v npx >/dev/null 2>&1; then
                                    _verify_result=$(npx --yes tsc --noEmit "$_verify_path" 2>&1) || true
                                fi ;;
                            json)
                                _verify_result=$(jq empty "$_verify_path" 2>&1) || true ;;
                            rb)
                                if command -v ruby >/dev/null 2>&1; then
                                    _verify_result=$(ruby -c "$_verify_path" 2>&1) || true
                                fi ;;
                            swift)
                                if command -v swiftc >/dev/null 2>&1; then
                                    _verify_result=$(swiftc -parse "$_verify_path" 2>&1) || true
                                fi ;;
                        esac
                        if [[ -n "$_verify_result" ]]; then
                            # Non-empty means errors (successful checks are silent or say "Syntax OK")
                            case "$_verify_result" in
                                *"Syntax OK"*|*"ok"*) ;; # clean
                                *)
                                    result="${result}

[AUTO-VERIFY] Syntax check failed for ${_verify_path##*/}:
${_verify_result}
Please fix the syntax errors before proceeding."
                                    printf "${C_DIM}  ${BOX_V}${C_RESET} ${C_RED}${IC_ERR} syntax error in %s${C_RESET}\n" "${_verify_path##*/}" >/dev/tty
                                    ;;
                            esac
                        fi
                    fi
                fi

                # Show abbreviated result for read-only tools
                if $is_readonly && $AUTO_CONFIRM_READ; then
                    ui_tool_result "$result" "$tc_name"
                fi

                # Track file access for session history
                history_track_file "$tc_name" "$tc_args"

                # Add tool result to conversation
                state_add_tool_result "$tc_id" "$tc_name" "$result"

                # ── Loop detection ──
                # Hash the call signature (name + first 80 chars of args)
                local _call_sig="${tc_name}:$(printf '%s' "$tc_args" | head -c 80 | cksum | cut -d' ' -f1)"
                local _is_error=false
                case "$result" in
                    Error:*|error:*|*"No such file"*|*"command not found"*|*"Permission denied"*) _is_error=true ;;
                esac

                # Check if this exact call was made recently
                case "$_recent_calls" in
                    *"$_call_sig"*)
                        # Duplicate call detected
                        if $_is_error; then
                            _consecutive_failures=$((_consecutive_failures + 1))
                        fi
                        if (( _consecutive_failures >= 2 )); then
                            # Inject escalation: tell model to change approach
                            state_add_message "user" "[SYSTEM] You have called '$tc_name' with identical arguments multiple times and it keeps failing. Stop retrying the same approach. Instead: 1) Read error messages carefully, 2) Try a fundamentally different approach, 3) If stuck, explain the problem to the user."
                            printf "${C_DIM}  ${BOX_V}${C_RESET} ${C_YELLOW}${IC_WARN} loop detected: %s (%s failures) — escalating${C_RESET}\n" "$tc_name" "$_consecutive_failures" >/dev/tty
                            _consecutive_failures=0
                            _recent_calls=""
                        fi
                        ;;
                    *)
                        # New call — add to recent history (keep last 10)
                        _recent_calls="${_recent_calls} ${_call_sig}"
                        local _call_count
                        _call_count=$(echo "$_recent_calls" | wc -w)
                        if (( _call_count > 10 )); then
                            _recent_calls=$(echo "$_recent_calls" | tr ' ' '\n' | tail -10 | tr '\n' ' ')
                        fi
                        # Reset failure counter on successful new call
                        if ! $_is_error; then
                            _consecutive_failures=0
                        fi
                        ;;
                esac

                # Detect task_complete signal
                if [[ "$tc_name" == "task_complete" ]]; then
                    _task_complete=true
                fi

                _total_tool_calls=$((_total_tool_calls + 1))
                i=$((i + 1))
            done

            # If task_complete was called, end the turn
            if $_task_complete; then
                break
            fi

            # Mid-turn compaction: check context between tool iterations
            # This prevents context from ballooning during multi-tool turns
            local mid_turn_tokens
            mid_turn_tokens=$(state_estimate_tokens)
            local mid_turn_pct=$((mid_turn_tokens * 100 / CONTEXT_SIZE))
            if (( mid_turn_pct >= COMPACT_TRIGGER_PCT )); then
                printf "${C_DIM}  ${BOX_V} ${IC_WARN} context at %s%% — compacting...${C_RESET}\n" "$mid_turn_pct" >/dev/tty
                history_compact_rolling 2>/dev/null || true
            fi

            # Continue the loop — model may want to call more tools
            continue
        fi

        # No tool calls — this is a text-only response
        if [[ -n "$content" && "$content" != "null" ]]; then
            state_add_message "assistant" "$content"
            _nudge_count=$((_nudge_count + 1))

            # ── Always checkpoint with the user on text-only responses ──
            # The model stopped using tools. Let the user decide what to do.

            # Determine situation for context
            local _situation=""
            if (( _total_tool_calls < 3 )); then
                _situation="few tool calls so far"
            elif (( _nudge_count >= 3 )); then
                _situation="multiple text responses without tools"
            elif echo "$content" | grep -qiE "(next steps|to further|let.s (start|continue|proceed)|I.ll (now|next)|moving (on|forward))"; then
                _situation="model wants to continue"
            else
                _situation="model may be done"
            fi

            printf "\n${C_BCYAN}  text-only response${C_RESET} ${C_DIM}(%s, %d tool calls)${C_RESET}\n" "$_situation" "$_total_tool_calls" >/dev/tty
            printf "${C_DIM}  [Enter] push to use tools  [d]one  [r]edirect  [a]ccept as answer${C_RESET} " >/dev/tty

            local _checkpoint=""
            IFS= read -r _checkpoint </dev/tty 2>/dev/null || true

            case "$_checkpoint" in
                d|done|q|quit|stop|n|no)
                    break  # User is satisfied
                    ;;
                a|accept)
                    break  # Accept current text as answer
                    ;;
                r|redirect)
                    printf "${C_BCYAN}  new direction:${C_RESET} " >/dev/tty
                    local _redirect=""
                    IFS= read -r _redirect </dev/tty 2>/dev/null || true
                    if [[ -n "$_redirect" ]]; then
                        state_add_message "user" "$_redirect"
                    fi
                    _nudge_count=0
                    continue
                    ;;
                "")
                    # Enter = push model to use tools
                    if (( _total_tool_calls < 3 )); then
                        state_add_message "user" "You described what you want to do but haven't done enough exploration. Use your tools NOW — call read_file, grep_search, file_tree, etc. Do not describe actions, execute them."
                    else
                        state_add_message "user" "Continue with your next steps. Use your tools — do not just describe what you'll do. If you're done, summarize your findings."
                    fi
                    printf "${C_DIM}  ${IC_INFO} pushing model to use tools...${C_RESET}\n" >/dev/tty
                    _nudge_count=0
                    continue
                    ;;
                *)
                    # Typed something — inject as user message
                    state_add_message "user" "$_checkpoint"
                    _nudge_count=0
                    continue
                    ;;
            esac
        fi

        # Empty response — ask user instead of silently breaking
        printf "\n${C_YELLOW}  empty response from model${C_RESET}\n" >/dev/tty
        printf "${C_DIM}  [Enter] retry  [d]one${C_RESET} " >/dev/tty
        local _empty_input=""
        IFS= read -r _empty_input </dev/tty 2>/dev/null || true
        case "$_empty_input" in
            d|done|q|quit|stop)
                break
                ;;
            *)
                state_add_message "user" "Continue with the task. Use your tools."
                continue
                ;;
        esac
    done

    # If we hit the loop limit without task_complete, ask model to summarize
    # then let the user decide whether to continue
    if ! $_task_complete && (( loop_count >= MAX_TOOL_LOOPS )); then
        printf "\n${C_BYELLOW}  ${IC_WARN} Reached %d tool calls — pausing for checkpoint.${C_RESET}\n" "$MAX_TOOL_LOOPS" >/dev/tty

        # Ask the model to summarize progress and remaining work
        state_add_message "user" "[SYSTEM] You have reached the tool call limit for this turn. Do NOT call any more tools. Instead, provide: 1) A summary of what you accomplished so far, 2) A list of what remains to be done, 3) Your recommended next steps. Be specific about files read, changes made, and what still needs investigation."
        local summary_response
        summary_response=$(api_chat_completion_stream "$(state_get_messages)") || true
        local summary_content
        summary_content=$(api_get_content "$summary_response")
        if [[ -n "$summary_content" && "$summary_content" != "null" ]]; then
            summary_content=$(api_strip_thinking "$summary_content")
            state_add_message "assistant" "$summary_content"
        fi

        # Track tokens from summary call
        local su_pt su_ct
        su_pt=$(echo "$summary_response" | jq -r '.usage.prompt_tokens // 0' 2>/dev/null) || su_pt=0
        su_ct=$(echo "$summary_response" | jq -r '.usage.completion_tokens // 0' 2>/dev/null) || su_ct=0
        TURN_PROMPT_TOKENS=$((TURN_PROMPT_TOKENS + su_pt))
        TURN_COMPLETION_TOKENS=$((TURN_COMPLETION_TOKENS + su_ct))

        # Ask user whether to continue
        printf "\n${C_BCYAN}  Continue this exploration?${C_RESET}\n" >/dev/tty
        printf "${C_DIM}  Press Enter to continue, type a message to redirect, or 'q' to stop:${C_RESET} " >/dev/tty
        local _continue_input=""
        IFS= read -r _continue_input </dev/tty 2>/dev/null || true

        if [[ "$_continue_input" != "q" && "$_continue_input" != "quit" && "$_continue_input" != "stop" && "$_continue_input" != "done" && "$_continue_input" != "d" && "$_continue_input" != "n" && "$_continue_input" != "no" ]]; then
            # User wants to continue — inject continuation message and loop
            if [[ -n "$_continue_input" ]]; then
                state_add_message "user" "$_continue_input"
            else
                state_add_message "user" "Continue where you left off. Pick up from your remaining work items and keep going. Use your tools — do not just describe what you'll do."
            fi
            # Reset loop variables and continue the outer loop (no recursion)
            loop_count=0
            _nudge_attempted=false
            _nudge_count=0
            _recent_calls=""
            _consecutive_failures=0
            _total_tool_calls=0
            _task_complete=false
            AGENT_INTERRUPTED=false
            continue
        fi
    fi

    # Inner while loop done — break out of outer loop
    break
    done
    # ── end outer loop ──

    # Show token/context usage with visual progress bar
    SESSION_PROMPT_TOKENS=$((SESSION_PROMPT_TOKENS + TURN_PROMPT_TOKENS))
    SESSION_COMPLETION_TOKENS=$((SESSION_COMPLETION_TOKENS + TURN_COMPLETION_TOKENS))
    local est_tokens
    est_tokens=$(state_estimate_tokens)
    ui_turn_footer "$SESSION_TURNS" "$est_tokens" "$CONTEXT_SIZE" "$TURN_PROMPT_TOKENS" "$TURN_COMPLETION_TOKENS"

    # Check context size — compact if needed
    state_compact_if_needed || true

    return 0
}

# ── Auto-init: detect project, load memories, check plans ──
_auto_init() {
    local init_context=""

    # Run project detection
    local project_info
    project_info=$(tool_project_detect "$(jq -n --arg path "$WORK_DIR" '{"path": $path}')" 2>/dev/null) || true
    if [[ -n "$project_info" && "$project_info" != *"Error"* ]]; then
        init_context="## Auto-Detected Project Info\n${project_info}\n"
        # Build a brief summary: "project detected (language, name)"
        local _pd_name _pd_lang _pd_detail
        _pd_name=$(echo "$project_info" | sed -n 's/^Project: *//p' | head -1)
        _pd_lang=$(echo "$project_info" | sed -n 's/^Language: *//p' | head -1)
        _pd_lang=$(echo "$_pd_lang" | tr '[:upper:]' '[:lower:]')
        _pd_detail=""
        if [[ -n "$_pd_lang" && -n "$_pd_name" ]]; then
            _pd_detail=" (${_pd_lang}, ${_pd_name})"
        elif [[ -n "$_pd_name" ]]; then
            _pd_detail=" (${_pd_name})"
        fi
        ui_dim "  project detected${_pd_detail}"
    fi

    # Load persistent memories
    local memories
    memories=$(tool_memory '{"action": "read"}' 2>/dev/null) || true
    if [[ -n "$memories" && "$memories" != *"No memories"* ]]; then
        init_context="${init_context}\n## Project Memories\n${memories}\n"
        ui_dim "  memories loaded"
    fi

    # Check for existing task plan
    local plan
    plan=$(tool_task_plan '{"action": "status"}' 2>/dev/null) || true
    if [[ -n "$plan" && "$plan" != *"No active plan"* && "$plan" != *"Error"* ]]; then
        init_context="${init_context}\n## Active Task Plan\n${plan}\n"
        ui_dim "  active plan found"
    fi

    # Inject into system prompt
    if [[ -n "$init_context" ]]; then
        local current_prompt
        current_prompt=$(_build_system_prompt)
        state_add_system "${current_prompt}\n\n${init_context}"
    fi
}

# ── Main ──────────────────────────────────────────────
main() {
    # Check dependencies
    if ! check_deps; then
        exit 1
    fi

    # Initialize session
    state_init
    history_init

    # Load system prompt with environment context
    _update_system_prompt

    # Pre-seed conversation with a tool-use example so the model learns the pattern
    _seed_tool_example

    # Start server (skip in proxy mode — lana-proxy manages the backend)
    if [[ "$USE_PROXY" == "true" ]]; then
        ui_info "Proxy mode: routing through ${API_URL}"
        if ! api_health_check 2>/dev/null; then
            ui_error "lana-proxy not responding at ${API_URL}. Start it with: lana-proxy"
            exit 1
        fi
        ui_success "Proxy connected"
    else
        local model_path
        model_path=$(get_model_path "$CURRENT_MODEL")
        if ! server_start "$model_path"; then
            exit 1
        fi
    fi

    # Set up readline (input history + tab completion)
    ui_setup_readline

    # Show banner
    ui_banner "$(basename "$(get_model_path "$CURRENT_MODEL")")"

    # Auto-detect project and load memories
    _auto_init

    # Session start hooks
    hooks_session_start

    # Resume session if --continue was specified
    if [[ -n "${LANA_CONTINUE:-}" ]]; then
        if [[ "$LANA_CONTINUE" == "latest" ]]; then
            session_resume ""
        else
            session_resume "$LANA_CONTINUE"
        fi
        unset LANA_CONTINUE
    fi

    # ── Input reader (Node.js readline) ─────────────────
    # Sets _READER_OUT to protocol result:
    #   LINE:<text>   Normal input
    #   @             Bare @ (file picker)
    #   @MID:<text>   Text ending with " @" (mid-line file picker)
    #   EOF           Ctrl+D
    #   INT           Ctrl+C
    LANA_NODE_READER="$SCRIPT_DIR/lib/input_reader.mjs"
    _READER_OUT=""
    _read_input() {
        local prompt="$1"
        _READER_OUT=""
        local tmpfile="${SESSION_DIR}/.reader_result"
        : > "$tmpfile"

        # Ensure terminal is in a clean state (file picker / raw mode may have
        # left it in -icanon -echo mode which breaks Node readline)
        stty sane </dev/tty 2>/dev/null || true

        # Redirect stdin/stdout to /dev/tty so Node sees real TTY streams
        # (process.stdin.isTTY will be true, enabling raw mode for arrow keys)
        node "$LANA_NODE_READER" \
            "$prompt" "$LANA_INPUT_HISTORY" "$LANA_INPUT_HISTORY_SIZE" \
            </dev/tty >/dev/tty 3>"$tmpfile" || true

        # Restore terminal after Node readline
        stty sane </dev/tty 2>/dev/null || true

        _READER_OUT=$(cat "$tmpfile" 2>/dev/null) || true
        _READER_OUT="${_READER_OUT%$'\n'}"
    }

    # REPL loop
    while true; do
        AGENT_INTERRUPTED=false

        local user_input=""

        # Read input with readline (arrow keys, history, line editing)
        printf '\n'
        _read_input "$RL_PROMPT_PLAIN"

        case "$_READER_OUT" in
            EOF)
                exit 0
                ;;
            INT)
                continue
                ;;
            @)
                # Bare @ — launch file picker (Python has fully exited, terminal is clean)
                local picked_file
                picked_file=$(ui_file_picker "$WORK_DIR") || true
                if [[ -n "$picked_file" && -f "$picked_file" ]]; then
                    local _rel="${picked_file#$WORK_DIR/}"
                    ui_dim "  attached: $_rel"
                    printf "${C_DIM}  what would you like to do with this file?${C_RESET}\n"
                    # Follow-up prompt (also via prompt_toolkit)
                    _read_input "$RL_PROMPT_PLAIN"
                    case "$_READER_OUT" in
                        LINE:*) user_input="${_READER_OUT#LINE:} @${picked_file}" ;;
                        *)      user_input="Describe this file. @${picked_file}" ;;
                    esac
                else
                    continue
                fi
                ;;
            @MID:*)
                # @ typed mid-line — launch file picker and splice result
                local _prefix="${_READER_OUT#@MID:}"
                local picked_file
                picked_file=$(ui_file_picker "$WORK_DIR") || true
                if [[ -n "$picked_file" && -f "$picked_file" ]]; then
                    user_input="${_prefix}@${picked_file}"
                else
                    user_input="$_prefix"
                fi
                ;;
            LINE:*)
                user_input="${_READER_OUT#LINE:}"
                ;;
            "")
                # Empty result — input reader failed; loop back but don't flood
                sleep 0.2
                continue
                ;;
            *)
                # Unexpected protocol value — treat as input
                ui_debug "Unexpected reader output: $_READER_OUT"
                continue
                ;;
        esac

        # Support multi-line: lines ending with \ continue
        while [[ "$user_input" == *\\ ]]; do
            user_input="${user_input%\\}"$'\n'
            _read_input "$RL_PROMPT_CONT_PLAIN"
            case "$_READER_OUT" in
                LINE:*) user_input="${user_input}${_READER_OUT#LINE:}" ;;
                *)      break ;;
            esac
        done

        # Skip empty input
        [[ -z "$user_input" ]] && continue

        # Handle bare / — show command list
        if [[ "$user_input" == "/" ]]; then
            ui_show_commands
            continue
        fi

        # Check for commands (/ prefix)
        if [[ "$user_input" == /* ]]; then
            if handle_command "$user_input"; then
                continue
            fi
        fi

        # Expand @file references
        user_input=$(expand_file_refs "$user_input") || true

        # Add user message to state
        state_add_message "user" "$user_input"
        SESSION_TURNS=$((SESSION_TURNS + 1))

        # Run the agentic turn
        if ! run_agent_turn; then
            ui_error "Turn failed. Try again, /compact to free context, or /clear to reset."
        fi
    done
}

main "$@"

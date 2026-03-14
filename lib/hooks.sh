#!/usr/bin/env bash
# Hooks system: pre/post tool event hooks
# Compatible with bash 3.2+
#
# Hooks are loaded from .lana/hooks.json in the working directory.
# Format:
# {
#   "pre_tool": [
#     {"event": "edit_file", "command": "echo 'About to edit: $LANA_HOOK_PATH'"},
#     {"event": "bash", "command": "echo 'Running: $LANA_HOOK_COMMAND'"}
#   ],
#   "post_tool": [
#     {"event": "edit_file", "command": "prettier --write \"$LANA_HOOK_PATH\" 2>/dev/null || true"},
#     {"event": "write_file", "command": "prettier --write \"$LANA_HOOK_PATH\" 2>/dev/null || true"}
#   ],
#   "session_start": [
#     {"command": "echo 'LANA session started in $LANA_HOOK_WORK_DIR'"}
#   ],
#   "session_end": [
#     {"command": "echo 'Session ended'"}
#   ],
#   "pre_commit": [
#     {"command": "npm run lint 2>/dev/null || true"}
#   ]
# }
#
# Environment variables available to hooks:
#   LANA_HOOK_EVENT     - The event name (pre_tool, post_tool, etc.)
#   LANA_HOOK_TOOL      - Tool name (for tool events)
#   LANA_HOOK_PATH      - File path (for file-related tools)
#   LANA_HOOK_COMMAND   - Command string (for bash tool)
#   LANA_HOOK_WORK_DIR  - Current working directory
#   LANA_HOOK_RESULT    - Tool result (for post_tool, truncated to 1000 chars)

# ── Cached hooks ─────────────────────────────────────
HOOKS_LOADED=false
HOOKS_CONFIG=""

# ── Load hooks from project config ───────────────────
hooks_load() {
    local hooks_file="$WORK_DIR/.lana/hooks.json"

    if [[ -f "$hooks_file" ]]; then
        HOOKS_CONFIG=$(cat "$hooks_file" 2>/dev/null) || HOOKS_CONFIG="{}"
        HOOKS_LOADED=true
        local hook_count
        hook_count=$(echo "$HOOKS_CONFIG" | jq '[.[] | length] | add // 0' 2>/dev/null) || hook_count=0
        ui_debug "Hooks loaded: $hook_count total"
    else
        HOOKS_CONFIG="{}"
        HOOKS_LOADED=true
    fi
}

# ── Run hooks for an event ───────────────────────────
# hooks_run EVENT [TOOL_NAME] [TOOL_ARGS_JSON] [TOOL_RESULT]
hooks_run() {
    local event="$1"
    local tool_name="${2:-}"
    local tool_args="${3:-}"
    local tool_result="${4:-}"

    # Lazy-load hooks
    if [[ "$HOOKS_LOADED" != "true" ]]; then
        hooks_load
    fi

    # Check if any hooks exist for this event
    local hooks_list
    hooks_list=$(echo "$HOOKS_CONFIG" | jq -c --arg event "$event" '.[$event] // []' 2>/dev/null) || hooks_list="[]"

    local hook_count
    hook_count=$(echo "$hooks_list" | jq 'length' 2>/dev/null) || hook_count=0

    if (( hook_count == 0 )); then
        return 0
    fi

    # Extract file path and command from tool args
    local hook_path=""
    local hook_command=""
    if [[ -n "$tool_args" ]]; then
        hook_path=$(echo "$tool_args" | jq -r '.path // empty' 2>/dev/null) || true
        hook_command=$(echo "$tool_args" | jq -r '.command // empty' 2>/dev/null) || true
    fi

    # Truncate result for environment variable
    local hook_result_short=""
    if [[ -n "$tool_result" ]]; then
        hook_result_short="${tool_result:0:1000}"
    fi

    # Run each matching hook
    local i=0
    while (( i < hook_count )); do
        local hook_event hook_cmd
        hook_event=$(echo "$hooks_list" | jq -r ".[$i].event // empty")
        hook_cmd=$(echo "$hooks_list" | jq -r ".[$i].command // empty")

        i=$((i + 1))

        # Skip if hook has an event filter that doesn't match the tool
        if [[ -n "$hook_event" && -n "$tool_name" && "$hook_event" != "$tool_name" && "$hook_event" != "*" ]]; then
            continue
        fi

        # Skip if no command
        if [[ -z "$hook_cmd" ]]; then
            continue
        fi

        ui_debug "Running hook: $event${tool_name:+ ($tool_name)}: $hook_cmd"

        # Execute the hook command with environment variables
        (
            export LANA_HOOK_EVENT="$event"
            export LANA_HOOK_TOOL="$tool_name"
            export LANA_HOOK_PATH="$hook_path"
            export LANA_HOOK_COMMAND="$hook_command"
            export LANA_HOOK_WORK_DIR="$WORK_DIR"
            export LANA_HOOK_RESULT="$hook_result_short"

            cd "$WORK_DIR" && eval "$hook_cmd"
        ) >/dev/null 2>&1 &

        # Wait briefly for fast hooks, but don't block on slow ones
        local hook_pid=$!
        local waited=0
        while kill -0 "$hook_pid" 2>/dev/null && (( waited < 5 )); do
            sleep 0.1
            waited=$((waited + 1))
        done

        # If still running after 0.5s, let it continue in background
        if kill -0 "$hook_pid" 2>/dev/null; then
            ui_debug "Hook still running in background (PID $hook_pid)"
        fi
    done
}

# ── Convenience functions for common events ──────────

hooks_pre_tool() {
    local tool_name="$1" tool_args="${2:-}"
    hooks_run "pre_tool" "$tool_name" "$tool_args"
}

hooks_post_tool() {
    local tool_name="$1" tool_args="${2:-}" tool_result="${3:-}"
    hooks_run "post_tool" "$tool_name" "$tool_args" "$tool_result"
}

hooks_session_start() {
    hooks_run "session_start"
}

hooks_session_end() {
    hooks_run "session_end"
}

# ── Reload hooks (called when WORK_DIR changes) ─────
hooks_reload() {
    HOOKS_LOADED=false
    hooks_load
}

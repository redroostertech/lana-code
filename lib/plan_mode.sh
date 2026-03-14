#!/usr/bin/env bash
# Plan mode: read-only exploration before committing to changes
# Compatible with bash 3.2+

# ── Plan mode state ──────────────────────────────────
PLAN_MODE=false

# Read-only tools allowed in plan mode
PLAN_MODE_TOOLS="read_file grep_search glob_find search_index project_detect git_smart file_tree tree_parse lsp_query context_compress web_fetch memory scaffold_search"

# ── Check if a tool is allowed in plan mode ──────────
plan_mode_allows_tool() {
    local tool_name="$1"

    if [[ "$PLAN_MODE" != "true" ]]; then
        return 0  # not in plan mode, everything allowed
    fi

    # Check if tool is in the allowed list
    local allowed
    for allowed in $PLAN_MODE_TOOLS; do
        if [[ "$tool_name" == "$allowed" ]]; then
            return 0
        fi
    done

    return 1  # blocked
}

# ── Enter plan mode ──────────────────────────────────
plan_mode_enter() {
    PLAN_MODE=true
    printf "\n${C_BOLD}${C_CYAN}  PLAN MODE${C_RESET}\n"
    printf "${C_DIM}  Read-only exploration. No file writes or commands will execute.${C_RESET}\n"
    printf "${C_DIM}  Use /plan execute to exit and begin execution.${C_RESET}\n"
    printf "${C_DIM}  Use /plan exit to leave without executing.${C_RESET}\n\n"

    # Inject plan mode context into conversation
    state_add_message "user" "[System: You are now in PLAN MODE. You can only use read-only tools (read_file, grep_search, glob_find, search_index, file_tree, tree_parse, git_smart, lsp_query, web_fetch, project_detect, memory, scaffold_search). Do NOT attempt to write files, edit files, or run bash commands. Instead, create a detailed plan of what changes you would make. List each file to modify and the specific changes. When done planning, tell the user to run /plan execute to begin.]"
}

# ── Exit plan mode ───────────────────────────────────
plan_mode_exit() {
    if [[ "$PLAN_MODE" != "true" ]]; then
        ui_info "Not in plan mode."
        return 0
    fi
    PLAN_MODE=false
    printf "${C_DIM}  Exited plan mode.${C_RESET}\n"
}

# ── Exit plan mode and begin execution ───────────────
plan_mode_execute() {
    if [[ "$PLAN_MODE" != "true" ]]; then
        ui_info "Not in plan mode."
        return 0
    fi
    PLAN_MODE=false
    printf "\n${C_GREEN}${C_BOLD}  EXECUTING PLAN${C_RESET}\n"
    printf "${C_DIM}  All tools now available. Proceeding with planned changes.${C_RESET}\n\n"

    # Tell the model to execute the plan it created
    state_add_message "user" "[System: Plan mode ended. You now have full tool access. Execute the plan you created above. Proceed step by step, calling tools to make the changes you planned.]"
}

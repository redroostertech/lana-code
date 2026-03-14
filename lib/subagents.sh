#!/usr/bin/env bash
# Subagents: isolated agent conversations with full lifecycle management
# Compatible with bash 3.2+
#
# Subagent types:
#   research  - Read-only tools, returns findings summary
#   execute   - Full tool access, respects permission rules
#   plan      - Read-only, returns a detailed plan
#
# Features:
#   - Isolated context (own message history, won't pollute main conversation)
#   - Interrupt handling (Ctrl+C stops subagent cleanly)
#   - Token tracking (reported back to main turn counters)
#   - Context budget (stops before blowing context window)
#   - User checkpoints (asks user every N loops whether to continue)
#   - Progress visibility (shows tool calls + brief result summaries)
#   - Loop detection (prevents identical failing calls)

# ── Configuration ──────────────────────────────────────
SUBAGENT_MAX_LOOPS=30             # max tool iterations before forced summary
SUBAGENT_CHECKPOINT_INTERVAL=8    # ask user every N tool calls
SUBAGENT_CONTEXT_BUDGET_PCT=70    # stop when subagent context hits this %
SUBAGENT_RESULT_TRUNCATE=4000     # truncate individual tool results at this many chars
SUBAGENT_SUMMARY_TRUNCATE=8000    # truncate final summary returned to main agent

# Token tracking — accumulated by subagent, read by main loop
SUBAGENT_PROMPT_TOKENS=0
SUBAGENT_COMPLETION_TOKENS=0

# ── Subagent tool definition ─────────────────────────

get_subagent_tool_definitions() {
    cat << 'SUBAGENT_TOOLS_EOF'
[
  {
    "type": "function",
    "function": {
      "name": "subagent",
      "description": "Spawn an isolated sub-agent to handle a task in its own context window. The sub-agent gets separate conversation history and tool access, so large outputs won't pollute your main context. Use this for: (1) research tasks that read many files, (2) exploring multiple approaches without context bloat, (3) delegating independent subtasks. Returns a concise summary of findings/actions. The sub-agent loops autonomously until done — it will NOT stop after a few steps.",
      "parameters": {
        "type": "object",
        "properties": {
          "task": {
            "type": "string",
            "description": "Clear, detailed description of what the sub-agent should do. Be specific about what files to examine, what to look for, and what output format you expect."
          },
          "type": {
            "type": "string",
            "enum": ["research", "execute", "plan"],
            "description": "Sub-agent type: 'research' (read-only, explores codebase), 'execute' (full tools, makes changes — confirms with user), 'plan' (read-only, creates detailed plan)"
          },
          "context": {
            "type": "string",
            "description": "Optional additional context to provide to the sub-agent (e.g., file contents, previous findings)"
          }
        },
        "required": ["task", "type"]
      }
    }
  }
]
SUBAGENT_TOOLS_EOF
}

# ── Read-only tool definitions for research/plan subagents ──

_subagent_readonly_tools() {
    local all_tools
    all_tools=$(get_tool_definitions)
    echo "$all_tools" | jq '[.[] | select(.function.name as $n |
        $n == "read_file" or $n == "grep_search" or $n == "glob_find" or
        $n == "search_index" or $n == "file_tree" or $n == "tree_parse" or
        $n == "git_smart" or $n == "project_detect" or $n == "lsp_query" or
        $n == "web_fetch" or $n == "context_compress" or $n == "scaffold_search" or
        $n == "recall_turn" or $n == "task_complete"
    )]'
}

# ── Estimate subagent context usage ──────────────────

_subagent_estimate_tokens() {
    local messages_file="$1"
    local chars
    chars=$(wc -c < "$messages_file" 2>/dev/null) || chars=0
    echo $(( chars / 4 ))
}

# ── Build subagent system prompt ─────────────────────

_subagent_build_prompt() {
    local type="$1"
    local work_dir="$2"

    local base_instructions="Working directory: $work_dir
Date: $(date +%Y-%m-%d)

CRITICAL RULES:
1. Use your tools to actually DO the work. Do NOT just describe what you would do.
2. When you call a tool, wait for the result before deciding your next step.
3. Keep going until the task is FULLY complete. Do not stop after a few steps.
4. If a search returns no results, try different patterns or approaches.
5. When done, call the task_complete tool with a thorough summary of your findings.
6. Be concise in your reasoning — save context for tool results."

    case "$type" in
        research)
            echo "You are a RESEARCH sub-agent. Your job is to explore the codebase and gather information thoroughly.

You have READ-ONLY tools: read_file, grep_search, glob_find, file_tree, search_index, git_smart, etc.

Strategy:
- Start broad (file_tree, glob_find) then go deep (read_file, grep_search)
- When you find something interesting, follow the thread — read imports, check callers, trace data flow
- If one search pattern fails, try synonyms, abbreviations, or broader patterns
- Read ENTIRE files when they're relevant, not just snippets

When your research is complete, call task_complete with a detailed summary including:
- What you found (with file paths and line numbers)
- Key code patterns and relationships
- Any issues, warnings, or notable findings

$base_instructions"
            ;;
        plan)
            echo "You are a PLANNING sub-agent. Your job is to analyze the codebase and create a detailed implementation plan.

You have READ-ONLY tools: read_file, grep_search, glob_find, file_tree, search_index, git_smart, etc.

Strategy:
- First understand the existing code structure and patterns
- Identify all files that need to change
- Map out dependencies between changes
- Consider edge cases and potential issues

When your analysis is complete, call task_complete with a plan that includes:
- Ordered list of changes (which files, what modifications)
- Exact code locations (file:line) for each change
- Dependencies between changes
- Potential risks or complications
- Testing approach

$base_instructions"
            ;;
        execute)
            echo "You are an EXECUTION sub-agent. You have full tool access and can make changes to files.

Strategy:
- Read before you write — understand existing code before modifying
- Make changes incrementally and verify each step
- If a change fails syntax check, fix it immediately
- Test your changes when possible

IMPORTANT: Write operations will be confirmed with the user. Be deliberate about what you change.

When done, call task_complete with a summary of:
- What changes you made (files and descriptions)
- What you verified
- Any issues encountered

$base_instructions"
            ;;
        *)
            echo "Unknown subagent type: $type"
            return 1
            ;;
    esac
}

# ── Brief result summary for progress display ────────

_subagent_brief_result() {
    local tool_name="$1" result="$2"
    local brief=""
    local result_lines
    result_lines=$(printf '%s' "$result" | wc -l | tr -d ' ')

    case "$tool_name" in
        read_file)
            brief="${result_lines} lines"
            ;;
        grep_search)
            local match_count
            match_count=$(printf '%s' "$result" | grep -c ':' 2>/dev/null) || match_count=0
            if echo "$result" | grep -qi "no matches"; then
                brief="no matches"
            else
                brief="${match_count} matches"
            fi
            ;;
        glob_find)
            local file_count
            file_count=$(printf '%s' "$result" | grep -c '.' 2>/dev/null) || file_count=0
            brief="${file_count} files"
            ;;
        file_tree)
            brief="${result_lines} entries"
            ;;
        bash)
            if echo "$result" | grep -qiE 'error|failed|fatal'; then
                brief="errors found"
            else
                brief="${result_lines} lines"
            fi
            ;;
        write_file|edit_file)
            if echo "$result" | grep -qi "error"; then
                brief="FAILED"
            else
                brief="ok"
            fi
            ;;
        task_complete)
            brief="done"
            ;;
        *)
            if (( result_lines > 3 )); then
                brief="${result_lines} lines"
            else
                brief=$(printf '%s' "$result" | head -1 | cut -c1-60)
            fi
            ;;
    esac

    echo "$brief"
}

# ── Execute a subagent ───────────────────────────────

tool_subagent() {
    local args="$1"
    local task type context
    task=$(echo "$args" | jq -r '.task // empty')
    type=$(echo "$args" | jq -r '.type // "research"')
    context=$(echo "$args" | jq -r '.context // empty')

    if [[ -z "$task" ]]; then
        echo "Error: task is required"
        return 1
    fi

    # Reset token tracking
    SUBAGENT_PROMPT_TOKENS=0
    SUBAGENT_COMPLETION_TOKENS=0

    ui_tool_call "subagent" "$type: $(echo "$task" | head -c 80)"

    # Build subagent system prompt
    local subagent_system
    subagent_system=$(_subagent_build_prompt "$type" "$WORK_DIR")
    if [[ $? -ne 0 ]]; then
        echo "Error: $subagent_system"
        return 1
    fi

    # Select tool set based on type
    local tools_json
    if [[ "$type" == "execute" ]]; then
        # Full tools but exclude subagent (no recursive spawning)
        tools_json=$(get_tool_definitions | jq '[.[] | select(.function.name != "subagent")]')
    else
        tools_json=$(_subagent_readonly_tools)
    fi

    # Build initial prompt with task and optional context
    local user_prompt="$task"
    if [[ -n "$context" ]]; then
        user_prompt="${task}

## Additional Context
${context}"
    fi

    # Create isolated message state
    local subagent_id="sa_$$_$(date +%s)"
    local subagent_dir="$SESSION_DIR/$subagent_id"
    mkdir -p "$subagent_dir"
    local subagent_messages="$subagent_dir/messages.json"

    # Initialize with system + user message
    jq -n \
        --arg system "$subagent_system" \
        --arg user "$user_prompt" \
        '[{"role": "system", "content": $system}, {"role": "user", "content": $user}]' \
        > "$subagent_messages"

    # ── Subagent loop ────────────────────────────────
    local loop_count=0
    local total_tool_calls=0
    local final_content=""
    local task_completed=false
    local consecutive_text_only=0

    # Loop detection
    local recent_calls=""
    local consecutive_failures=0

    printf "\n${C_DIM}  ╭─ subagent (%s) ──────────────────────${C_RESET}\n" "$type" >/dev/tty

    # Outer loop: allows continuing after system limits (context budget, max loops)
    while true; do

    while (( loop_count < SUBAGENT_MAX_LOOPS )); do
        loop_count=$((loop_count + 1))

        # ── Check for interrupt ──
        if $AGENT_INTERRUPTED; then
            printf "${C_DIM}  │${C_RESET} ${C_YELLOW}interrupted${C_RESET}\n" >/dev/tty
            final_content="Subagent interrupted by user after $total_tool_calls tool calls."
            break 2  # exit both loops
        fi

        # ── Check context budget ──
        local est_tokens
        est_tokens=$(_subagent_estimate_tokens "$subagent_messages")
        local ctx_pct=$(( est_tokens * 100 / CONTEXT_SIZE ))

        if (( ctx_pct >= SUBAGENT_CONTEXT_BUDGET_PCT )); then
            # Get a progress summary from the model before compacting
            printf "${C_DIM}  │${C_RESET} ${C_YELLOW}context at %s%% — pausing for checkpoint${C_RESET}\n" "$ctx_pct" >/dev/tty

            local tmp="$subagent_dir/tmp_msg.json"
            jq --arg msg "[SYSTEM] You have used $ctx_pct% of available context. Provide: 1) A summary of what you've found/done so far, 2) A list of what REMAINS to be done. Do NOT call tools. Output text only." \
                '. + [{"role": "user", "content": $msg}]' \
                "$subagent_messages" > "$tmp" && mv "$tmp" "$subagent_messages"

            # Get the summary (one API call, no tools)
            local ctx_summary_payload
            ctx_summary_payload=$(jq -n \
                --arg model_name "$API_MODEL" \
                --argjson messages "$(cat "$subagent_messages")" \
                --argjson temperature "$TEMPERATURE" \
                --argjson max_tokens "$MAX_TOKENS" \
                '{
                    "model": $model_name,
                    "messages": $messages,
                    "temperature": $temperature,
                    "max_tokens": $max_tokens,
                    "stream": false
                }')

            local ctx_summary_resp
            ctx_summary_resp=$(curl -s \
                -X POST "${API_URL}/v1/chat/completions" \
                -H "Content-Type: application/json" \
                -d "$ctx_summary_payload" \
                --max-time 120 2>/dev/null)

            local ctx_summary_text
            ctx_summary_text=$(echo "$ctx_summary_resp" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
            ctx_summary_text=$(printf '%s' "$ctx_summary_text" | perl -0777 -pe 's/<think>.*?<\/think>//gs' 2>/dev/null) || true

            # Track tokens
            local cspt csct
            cspt=$(echo "$ctx_summary_resp" | jq -r '.usage.prompt_tokens // 0' 2>/dev/null) || cspt=0
            csct=$(echo "$ctx_summary_resp" | jq -r '.usage.completion_tokens // 0' 2>/dev/null) || csct=0
            SUBAGENT_PROMPT_TOKENS=$((SUBAGENT_PROMPT_TOKENS + cspt))
            SUBAGENT_COMPLETION_TOKENS=$((SUBAGENT_COMPLETION_TOKENS + csct))

            # Show the summary to the user
            if [[ -n "$ctx_summary_text" && "$ctx_summary_text" != "null" ]]; then
                printf "${C_DIM}  │${C_RESET}\n" >/dev/tty
                printf "${C_DIM}  │${C_RESET} ${C_BOLD}progress so far:${C_RESET}\n" >/dev/tty
                printf '%s\n' "$ctx_summary_text" | head -20 | while IFS= read -r _line; do
                    printf "${C_DIM}  │${C_RESET}   %s\n" "$_line" >/dev/tty
                done
            fi

            # Let the user decide
            printf "${C_DIM}  │${C_RESET}\n" >/dev/tty
            printf "${C_DIM}  │${C_RESET} ${C_BCYAN}context limit${C_RESET} ${C_DIM}— %d tool calls, context %d%%${C_RESET}\n" "$total_tool_calls" "$ctx_pct" >/dev/tty
            printf "${C_DIM}  │${C_RESET} ${C_DIM}[Enter] compact & continue  [d]one  [r]edirect${C_RESET} " >/dev/tty

            local ctx_input=""
            IFS= read -r ctx_input </dev/tty 2>/dev/null || true

            case "$ctx_input" in
                d|done|q|quit|stop|n|no)
                    if [[ -n "$ctx_summary_text" ]]; then
                        final_content="$ctx_summary_text"
                    else
                        final_content="Subagent stopped at context limit ($total_tool_calls tool calls)."
                    fi
                    break 2  # exit both loops
                    ;;
                r|redirect)
                    printf "${C_DIM}  │${C_RESET} ${C_BCYAN}new direction:${C_RESET} " >/dev/tty
                    local ctx_redirect=""
                    IFS= read -r ctx_redirect </dev/tty 2>/dev/null || true
                    # Compact: keep system prompt + summary + new direction
                    local compact_summary="${ctx_summary_text:-No summary available.}"
                    jq -n \
                        --arg system "$subagent_system" \
                        --arg summary "[Previous work summary — $total_tool_calls tool calls completed]\n\n$compact_summary" \
                        --arg redirect "${ctx_redirect:-Continue where you left off.}" \
                        '[{"role": "system", "content": $system}, {"role": "user", "content": $summary}, {"role": "assistant", "content": "Understood. I have the context from my previous work."}, {"role": "user", "content": $redirect}]' \
                        > "$subagent_messages"
                    printf "${C_DIM}  │${C_RESET} ${C_DIM}compacted & redirected${C_RESET}\n" >/dev/tty
                    ;;
                *)
                    # Compact and continue with summary as warm context
                    local compact_summary="${ctx_summary_text:-No summary available.}"
                    local continue_msg="${ctx_input:-Continue where you left off. Pick up from the remaining work items. Use your tools.}"
                    jq -n \
                        --arg system "$subagent_system" \
                        --arg summary "[Previous work summary — $total_tool_calls tool calls completed]\n\n$compact_summary" \
                        --arg cont "$continue_msg" \
                        '[{"role": "system", "content": $system}, {"role": "user", "content": $summary}, {"role": "assistant", "content": "Understood. I will continue from where I left off."}, {"role": "user", "content": $cont}]' \
                        > "$subagent_messages"
                    printf "${C_DIM}  │${C_RESET} ${C_DIM}context compacted — continuing${C_RESET}\n" >/dev/tty
                    ;;
            esac

            # Don't reset loop_count — context budget continues to apply
            continue
        fi

        # ── Inject progress context ──
        local messages
        messages=$(cat "$subagent_messages")

        # Add ephemeral progress note (not persisted)
        messages=$(echo "$messages" | jq --arg msg "[Progress: loop $loop_count/$SUBAGENT_MAX_LOOPS, $total_tool_calls tool calls, context ${ctx_pct}%]" \
            '. + [{"role": "user", "content": $msg}]')

        # ── API call ──
        local payload
        payload=$(jq -n \
            --arg model_name "$API_MODEL" \
            --argjson messages "$messages" \
            --argjson tools "$tools_json" \
            --argjson temperature "$TEMPERATURE" \
            --argjson max_tokens "$MAX_TOKENS" \
            '{
                "model": $model_name,
                "messages": $messages,
                "tools": $tools,
                "tool_choice": "auto",
                "temperature": $temperature,
                "max_tokens": $max_tokens,
                "stream": false
            }')

        local response
        response=$(curl -s \
            -X POST "${API_URL}/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d "$payload" \
            --max-time 180 2>/dev/null)

        # ── Check interrupt after API call ──
        if $AGENT_INTERRUPTED; then
            printf "${C_DIM}  │${C_RESET} ${C_YELLOW}interrupted${C_RESET}\n" >/dev/tty
            printf "${C_DIM}  ╰──────────────────────────────────────${C_RESET}\n" >/dev/tty
            final_content="Subagent interrupted by user after $total_tool_calls tool calls."
            break
        fi

        if [[ -z "$response" ]]; then
            printf "${C_DIM}  │${C_RESET} ${C_RED}empty response — retrying${C_RESET}\n" >/dev/tty
            # One retry
            response=$(curl -s \
                -X POST "${API_URL}/v1/chat/completions" \
                -H "Content-Type: application/json" \
                -d "$payload" \
                --max-time 180 2>/dev/null)
            if [[ -z "$response" ]]; then
                printf "${C_DIM}  │${C_RESET} ${C_RED}still empty — aborting${C_RESET}\n" >/dev/tty
                final_content="Subagent aborted: server returned empty response after $total_tool_calls tool calls."
                break
            fi
        fi

        # ── Check for API errors ──
        local error
        error=$(echo "$response" | jq -r '.error // .error.message // empty' 2>/dev/null) || true
        if [[ -n "$error" ]]; then
            printf "${C_DIM}  │${C_RESET} ${C_RED}API error: %s${C_RESET}\n" "$(echo "$error" | head -c 80)" >/dev/tty
            final_content="Subagent aborted due to API error: $error"
            break
        fi

        # ── Track tokens ──
        local pt ct
        pt=$(echo "$response" | jq -r '.usage.prompt_tokens // 0' 2>/dev/null) || pt=0
        ct=$(echo "$response" | jq -r '.usage.completion_tokens // 0' 2>/dev/null) || ct=0
        SUBAGENT_PROMPT_TOKENS=$((SUBAGENT_PROMPT_TOKENS + pt))
        SUBAGENT_COMPLETION_TOKENS=$((SUBAGENT_COMPLETION_TOKENS + ct))

        # ── Extract content and tool calls ──
        local content
        content=$(echo "$response" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
        # Strip thinking blocks
        content=$(printf '%s' "$content" | perl -0777 -pe 's/<think>.*?<\/think>//gs' 2>/dev/null) || true

        local has_tools=false
        local tool_calls="[]"
        local tc_check
        tc_check=$(echo "$response" | jq -r '.choices[0].message.tool_calls // empty' 2>/dev/null)

        if [[ -n "$tc_check" && "$tc_check" != "null" && "$tc_check" != "[]" ]]; then
            has_tools=true
            tool_calls=$(echo "$response" | jq -c '.choices[0].message.tool_calls // []')
        fi

        # ── Also check for text-based tool calls (fallback for weak models) ──
        if ! $has_tools && [[ -n "$content" && "$content" != "null" ]]; then
            # Check <tool_call> tags
            local parsed_tc
            parsed_tc=$(api_parse_text_tool_calls "$content") || true
            if [[ -n "$parsed_tc" && "$parsed_tc" != "[]" ]]; then
                has_tools=true
                tool_calls="$parsed_tc"
                content=$(api_strip_tool_call_tags "$content")
            fi
        fi

        if $has_tools; then
            consecutive_text_only=0

            # Add assistant message with tool calls to subagent state
            local tmp="$subagent_dir/tmp_msg.json"
            if [[ -n "$content" && "$content" != "null" ]]; then
                jq --argjson tc "$tool_calls" --arg content "$content" \
                    '. + [{"role": "assistant", "content": $content, "tool_calls": $tc}]' \
                    "$subagent_messages" > "$tmp" && mv "$tmp" "$subagent_messages"
            else
                jq --argjson tc "$tool_calls" \
                    '. + [{"role": "assistant", "content": null, "tool_calls": $tc}]' \
                    "$subagent_messages" > "$tmp" && mv "$tmp" "$subagent_messages"
            fi

            # Execute each tool call
            local num_tools
            num_tools=$(echo "$tool_calls" | jq 'length')

            local ti=0
            while (( ti < num_tools )); do
                # Check for interrupt between tool calls
                if $AGENT_INTERRUPTED; then
                    printf "${C_DIM}  │${C_RESET} ${C_YELLOW}interrupted during tool execution${C_RESET}\n" >/dev/tty
                    break 2  # break out of both loops
                fi

                local tc
                tc=$(echo "$tool_calls" | jq -c ".[$ti]")
                local tc_id tc_name tc_args
                tc_id=$(echo "$tc" | jq -r '.id')
                tc_name=$(echo "$tc" | jq -r '.function.name')
                tc_args=$(echo "$tc" | jq -r '.function.arguments')

                # Parse arguments
                if ! echo "$tc_args" | jq empty 2>/dev/null; then
                    tc_args=$(echo "$tc_args" | jq -R 'fromjson' 2>/dev/null || echo '{}')
                fi

                # ── Permission enforcement ──
                local allowed=true
                if [[ "$type" != "execute" ]]; then
                    # Research/plan: block all write tools
                    case "$tc_name" in
                        write_file|edit_file|bash|batch_edit|diff_apply|run_background|test_run|undo)
                            allowed=false
                            ;;
                    esac
                else
                    # Execute subagents: check permission rules like the main loop
                    local perm_decision
                    perm_decision=$(permissions_check "$tc_name" "$tc_args")
                    if [[ "$perm_decision" == "deny" ]]; then
                        allowed=false
                    fi
                    # For execute subagents, use auto-edit mode (auto-accept file edits, confirm bash)
                    if $allowed; then
                        export _PERM_OVERRIDE=""
                        case "$tc_name" in
                            read_file|grep_search|glob_find|search_index|file_tree|tree_parse|git_smart|project_detect|lsp_query|web_fetch|context_compress|recall_turn|task_complete)
                                export _PERM_OVERRIDE="allow"
                                ;;
                            write_file|edit_file|batch_edit|diff_apply)
                                # Auto-accept file mutations (user can still see what changed)
                                export _PERM_OVERRIDE="allow"
                                ;;
                            bash|run_background|test_run)
                                # Confirm bash commands with user
                                # _PERM_OVERRIDE stays empty — ui_confirm will prompt
                                ;;
                        esac
                    fi
                fi

                local result
                if $allowed; then
                    # Display tool call
                    local display_arg
                    display_arg=$(echo "$tc_args" | jq -r 'to_entries | map(.value) | join(" ")' 2>/dev/null | head -c 80) || display_arg=""
                    printf "${C_DIM}  │${C_RESET} ${C_CYAN}%s${C_RESET} ${C_DIM}%s${C_RESET}" "$tc_name" "$display_arg" >/dev/tty

                    # Execute the tool
                    if [[ "$type" != "execute" ]]; then
                        export _PERM_OVERRIDE="allow"
                    fi
                    result=$(execute_tool "$tc_name" "$tc_args" 2>&1) || true
                    unset _PERM_OVERRIDE

                    # Show brief result
                    local brief
                    brief=$(_subagent_brief_result "$tc_name" "$result")
                    printf " ${C_DIM}→ %s${C_RESET}\n" "$brief" >/dev/tty
                else
                    result="Error: Tool '$tc_name' is not available for $type subagent."
                    printf "${C_DIM}  │${C_RESET} ${C_YELLOW}blocked: %s${C_RESET}\n" "$tc_name" >/dev/tty
                fi

                # Detect task_complete
                if [[ "$tc_name" == "task_complete" ]]; then
                    task_completed=true
                    local summary
                    summary=$(echo "$tc_args" | jq -r '.summary // empty')
                    if [[ -n "$summary" ]]; then
                        final_content="$summary"
                    else
                        final_content="$result"
                    fi
                fi

                # Truncate long results for subagent context
                if (( ${#result} > SUBAGENT_RESULT_TRUNCATE )); then
                    result="${result:0:$SUBAGENT_RESULT_TRUNCATE}
... [truncated: ${#result} chars]"
                fi

                # Add tool result to subagent state
                jq --arg id "$tc_id" --arg name "$tc_name" --arg content "$result" \
                    '. + [{"role": "tool", "tool_call_id": $id, "name": $name, "content": $content}]' \
                    "$subagent_messages" > "$tmp" && mv "$tmp" "$subagent_messages"

                # ── Loop detection ──
                local call_sig="${tc_name}:$(printf '%s' "$tc_args" | head -c 80 | cksum | cut -d' ' -f1)"
                local is_error=false
                case "$result" in
                    Error:*|error:*|*"No such file"*|*"command not found"*|*"Permission denied"*|*"No matches"*) is_error=true ;;
                esac

                case "$recent_calls" in
                    *"$call_sig"*)
                        if $is_error; then
                            consecutive_failures=$((consecutive_failures + 1))
                        fi
                        if (( consecutive_failures >= 3 )); then
                            jq --arg msg "[SYSTEM] You have called '$tc_name' with identical arguments multiple times and it keeps failing. Try a DIFFERENT approach: different search patterns, different files, different tools. If truly stuck, call task_complete with what you have so far." \
                                '. + [{"role": "user", "content": $msg}]' \
                                "$subagent_messages" > "$tmp" && mv "$tmp" "$subagent_messages"
                            printf "${C_DIM}  │${C_RESET} ${C_YELLOW}loop detected — nudging${C_RESET}\n" >/dev/tty
                            consecutive_failures=0
                            recent_calls=""
                        fi
                        ;;
                    *)
                        recent_calls="${recent_calls} ${call_sig}"
                        local call_count
                        call_count=$(echo "$recent_calls" | wc -w)
                        if (( call_count > 15 )); then
                            recent_calls=$(echo "$recent_calls" | tr ' ' '\n' | tail -15 | tr '\n' ' ')
                        fi
                        if ! $is_error; then
                            consecutive_failures=0
                        fi
                        ;;
                esac

                total_tool_calls=$((total_tool_calls + 1))
                ti=$((ti + 1))
            done

            # If task_complete was called, we're done
            if $task_completed; then
                break
            fi

            # ── User checkpoint ──
            if (( total_tool_calls > 0 && total_tool_calls % SUBAGENT_CHECKPOINT_INTERVAL == 0 )); then
                local cp_tokens
                cp_tokens=$(_subagent_estimate_tokens "$subagent_messages")
                local cp_pct=$(( cp_tokens * 100 / CONTEXT_SIZE ))

                printf "${C_DIM}  │${C_RESET}\n" >/dev/tty
                printf "${C_DIM}  │${C_RESET} ${C_BCYAN}checkpoint${C_RESET} ${C_DIM}— %d tool calls, context %d%%${C_RESET}\n" "$total_tool_calls" "$cp_pct" >/dev/tty
                printf "${C_DIM}  │${C_RESET} ${C_DIM}[Enter] continue  [d]one  [r]edirect  [s]ummarize now${C_RESET} " >/dev/tty

                local checkpoint_input=""
                IFS= read -r checkpoint_input </dev/tty 2>/dev/null || true

                case "$checkpoint_input" in
                    d|done|q|quit|stop|n|no)
                        # User wants to stop — ask for summary
                        printf "${C_DIM}  │${C_RESET} ${C_DIM}requesting summary...${C_RESET}\n" >/dev/tty
                        local tmp="$subagent_dir/tmp_msg.json"
                        jq --arg msg "[SYSTEM] The user has asked you to stop. Call task_complete NOW with a thorough summary of everything you have found so far." \
                            '. + [{"role": "user", "content": $msg}]' \
                            "$subagent_messages" > "$tmp" && mv "$tmp" "$subagent_messages"
                        # Let one more loop iteration happen to get the summary
                        ;;
                    s|summarize|summary)
                        # Summarize what we have so far but keep going
                        printf "${C_DIM}  │${C_RESET} ${C_DIM}requesting interim summary...${C_RESET}\n" >/dev/tty
                        local tmp="$subagent_dir/tmp_msg.json"
                        jq --arg msg "[SYSTEM] Provide a brief interim summary of your progress so far, then continue working on the task. Do NOT call task_complete yet." \
                            '. + [{"role": "user", "content": $msg}]' \
                            "$subagent_messages" > "$tmp" && mv "$tmp" "$subagent_messages"
                        ;;
                    r|redirect)
                        # User wants to redirect
                        printf "${C_DIM}  │${C_RESET} ${C_BCYAN}new direction:${C_RESET} " >/dev/tty
                        local redirect_input=""
                        IFS= read -r redirect_input </dev/tty 2>/dev/null || true
                        if [[ -n "$redirect_input" ]]; then
                            local tmp="$subagent_dir/tmp_msg.json"
                            jq --arg msg "$redirect_input" \
                                '. + [{"role": "user", "content": $msg}]' \
                                "$subagent_messages" > "$tmp" && mv "$tmp" "$subagent_messages"
                            printf "${C_DIM}  │${C_RESET} ${C_DIM}redirected${C_RESET}\n" >/dev/tty
                        fi
                        ;;
                    "")
                        # Enter = continue
                        printf "${C_DIM}  │${C_RESET} ${C_DIM}continuing...${C_RESET}\n" >/dev/tty
                        ;;
                    *)
                        # Treat as redirect message
                        local tmp="$subagent_dir/tmp_msg.json"
                        jq --arg msg "$checkpoint_input" \
                            '. + [{"role": "user", "content": $msg}]' \
                            "$subagent_messages" > "$tmp" && mv "$tmp" "$subagent_messages"
                        printf "${C_DIM}  │${C_RESET} ${C_DIM}injected: %s${C_RESET}\n" "$(echo "$checkpoint_input" | head -c 60)" >/dev/tty
                        ;;
                esac
            fi

            continue
        fi

        # ── No tool calls — text-only response ──
        if [[ -n "$content" && "$content" != "null" ]]; then
            consecutive_text_only=$((consecutive_text_only + 1))

            # Add to subagent state
            local tmp="$subagent_dir/tmp_msg.json"
            jq --arg content "$content" \
                '. + [{"role": "assistant", "content": $content}]' \
                "$subagent_messages" > "$tmp" && mv "$tmp" "$subagent_messages"

            # Show a preview of what the model said
            local preview
            preview=$(printf '%s' "$content" | head -2 | head -c 100)
            printf "${C_DIM}  │${C_RESET} ${C_DIM}text: %s${C_RESET}\n" "$preview" >/dev/tty

            # Determine situation for the prompt
            local situation=""
            if (( total_tool_calls < 3 )); then
                situation="model hasn't used many tools yet"
            elif (( consecutive_text_only >= 3 )); then
                situation="3 text-only responses in a row"
            elif echo "$content" | grep -qiE "(next.*(step|I'll)|let me|let's|I'll now|I will now|moving on|proceed)"; then
                situation="model wants to continue"
            else
                situation="model may be done"
            fi

            # Always ask the user — never silently exit
            printf "${C_DIM}  │${C_RESET}\n" >/dev/tty
            printf "${C_DIM}  │${C_RESET} ${C_BCYAN}text-only response${C_RESET} ${C_DIM}(%s, %d tool calls so far)${C_RESET}\n" "$situation" "$total_tool_calls" >/dev/tty
            printf "${C_DIM}  │${C_RESET} ${C_DIM}[Enter] push to use tools  [d]one  [r]edirect  [a]ccept as answer${C_RESET} " >/dev/tty

            local text_input=""
            IFS= read -r text_input </dev/tty 2>/dev/null || true

            case "$text_input" in
                d|done|q|quit|stop|n|no)
                    # User wants to stop — request summary
                    printf "${C_DIM}  │${C_RESET} ${C_DIM}requesting summary...${C_RESET}\n" >/dev/tty
                    jq --arg msg "[SYSTEM] The user has asked you to stop. Call task_complete NOW with a thorough summary of everything you have found so far." \
                        '. + [{"role": "user", "content": $msg}]' \
                        "$subagent_messages" > "$tmp" && mv "$tmp" "$subagent_messages"
                    ;;
                a|accept)
                    # Accept current text as the answer
                    final_content="$content"
                    break
                    ;;
                r|redirect)
                    # User wants to redirect
                    printf "${C_DIM}  │${C_RESET} ${C_BCYAN}new direction:${C_RESET} " >/dev/tty
                    local redirect_input=""
                    IFS= read -r redirect_input </dev/tty 2>/dev/null || true
                    if [[ -n "$redirect_input" ]]; then
                        jq --arg msg "$redirect_input" \
                            '. + [{"role": "user", "content": $msg}]' \
                            "$subagent_messages" > "$tmp" && mv "$tmp" "$subagent_messages"
                        printf "${C_DIM}  │${C_RESET} ${C_DIM}redirected${C_RESET}\n" >/dev/tty
                    fi
                    consecutive_text_only=0
                    ;;
                "")
                    # Enter = push model to use tools
                    if (( total_tool_calls < 3 )); then
                        local nudge="You described what you want to do but didn't use any tools. Use your tools NOW — call read_file, grep_search, file_tree, etc. Do not describe actions, execute them."
                        jq --arg msg "$nudge" \
                            '. + [{"role": "user", "content": $msg}]' \
                            "$subagent_messages" > "$tmp" && mv "$tmp" "$subagent_messages"
                        printf "${C_DIM}  │${C_RESET} ${C_DIM}nudging to use tools...${C_RESET}\n" >/dev/tty
                    else
                        local nudge="Continue with your next steps. Use tools — don't just describe what you'll do. If you're done, call task_complete with your findings."
                        jq --arg msg "$nudge" \
                            '. + [{"role": "user", "content": $msg}]' \
                            "$subagent_messages" > "$tmp" && mv "$tmp" "$subagent_messages"
                        printf "${C_DIM}  │${C_RESET} ${C_DIM}pushing to continue...${C_RESET}\n" >/dev/tty
                    fi
                    ;;
                *)
                    # Typed something — inject as message
                    jq --arg msg "$text_input" \
                        '. + [{"role": "user", "content": $msg}]' \
                        "$subagent_messages" > "$tmp" && mv "$tmp" "$subagent_messages"
                    printf "${C_DIM}  │${C_RESET} ${C_DIM}injected: %s${C_RESET}\n" "$(echo "$text_input" | head -c 60)" >/dev/tty
                    consecutive_text_only=0
                    ;;
            esac

            continue
        fi

        # Empty response — still ask user
        printf "${C_DIM}  │${C_RESET} ${C_YELLOW}empty response from model${C_RESET}\n" >/dev/tty
        printf "${C_DIM}  │${C_RESET} ${C_DIM}[Enter] retry  [d]one${C_RESET} " >/dev/tty
        local empty_input=""
        IFS= read -r empty_input </dev/tty 2>/dev/null || true
        case "$empty_input" in
            d|done|q|quit|stop)
                final_content="Subagent stopped by user after empty response ($total_tool_calls tool calls)."
                break
                ;;
            *)
                # Retry — inject a nudge
                local tmp="$subagent_dir/tmp_msg.json"
                jq --arg msg "Continue with the task. Use your tools." \
                    '. + [{"role": "user", "content": $msg}]' \
                    "$subagent_messages" > "$tmp" && mv "$tmp" "$subagent_messages"
                continue
                ;;
        esac
    done
    # ── end inner while ──

    # If we already have a final answer or task was completed, exit outer loop
    if $task_completed || [[ -n "$final_content" ]]; then
        break
    fi

    # ── Hit loop limit without task_complete — checkpoint with user ──
    if (( loop_count >= SUBAGENT_MAX_LOOPS )); then
        printf "${C_DIM}  │${C_RESET}\n" >/dev/tty
        printf "${C_DIM}  │${C_RESET} ${C_BYELLOW}reached %d iterations — pausing${C_RESET}\n" "$SUBAGENT_MAX_LOOPS" >/dev/tty

        # Get a progress + remaining work summary
        local tmp="$subagent_dir/tmp_msg.json"
        jq --arg msg "[SYSTEM] You have reached the iteration limit. Do NOT call any more tools. Provide: 1) A summary of what you accomplished so far (with file paths and specifics), 2) A numbered list of what REMAINS to be done. Be thorough." \
            '. + [{"role": "user", "content": $msg}]' \
            "$subagent_messages" > "$tmp" && mv "$tmp" "$subagent_messages"

        local summary_payload
        summary_payload=$(jq -n \
            --arg model_name "$API_MODEL" \
            --argjson messages "$(cat "$subagent_messages")" \
            --argjson temperature "$TEMPERATURE" \
            --argjson max_tokens "$MAX_TOKENS" \
            '{
                "model": $model_name,
                "messages": $messages,
                "temperature": $temperature,
                "max_tokens": $max_tokens,
                "stream": false
            }')

        local summary_response
        summary_response=$(curl -s \
            -X POST "${API_URL}/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d "$summary_payload" \
            --max-time 120 2>/dev/null)

        # Track tokens
        local spt sct
        spt=$(echo "$summary_response" | jq -r '.usage.prompt_tokens // 0' 2>/dev/null) || spt=0
        sct=$(echo "$summary_response" | jq -r '.usage.completion_tokens // 0' 2>/dev/null) || sct=0
        SUBAGENT_PROMPT_TOKENS=$((SUBAGENT_PROMPT_TOKENS + spt))
        SUBAGENT_COMPLETION_TOKENS=$((SUBAGENT_COMPLETION_TOKENS + sct))

        local summary_content
        summary_content=$(echo "$summary_response" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
        summary_content=$(printf '%s' "$summary_content" | perl -0777 -pe 's/<think>.*?<\/think>//gs' 2>/dev/null) || true

        # Also check if it called task_complete via tool call
        local summary_tc
        summary_tc=$(echo "$summary_response" | jq -r '.choices[0].message.tool_calls // empty' 2>/dev/null)
        if [[ -n "$summary_tc" && "$summary_tc" != "null" && "$summary_tc" != "[]" ]]; then
            local tc_summary
            tc_summary=$(echo "$summary_tc" | jq -r '.[0].function.arguments' 2>/dev/null)
            if echo "$tc_summary" | jq empty 2>/dev/null; then
                local tc_sum_text
                tc_sum_text=$(echo "$tc_summary" | jq -r '.summary // empty' 2>/dev/null)
                [[ -n "$tc_sum_text" ]] && summary_content="$tc_sum_text"
            fi
        fi

        # Show progress to user
        if [[ -n "$summary_content" && "$summary_content" != "null" ]]; then
            printf "${C_DIM}  │${C_RESET}\n" >/dev/tty
            printf "${C_DIM}  │${C_RESET} ${C_BOLD}progress & remaining:${C_RESET}\n" >/dev/tty
            printf '%s\n' "$summary_content" | head -30 | while IFS= read -r _line; do
                printf "${C_DIM}  │${C_RESET}   %s\n" "$_line" >/dev/tty
            done
        fi

        # Let the user decide
        local lim_tokens
        lim_tokens=$(_subagent_estimate_tokens "$subagent_messages")
        local lim_pct=$(( lim_tokens * 100 / CONTEXT_SIZE ))

        printf "${C_DIM}  │${C_RESET}\n" >/dev/tty
        printf "${C_DIM}  │${C_RESET} ${C_BCYAN}iteration limit${C_RESET} ${C_DIM}— %d tool calls, context %d%%${C_RESET}\n" "$total_tool_calls" "$lim_pct" >/dev/tty
        printf "${C_DIM}  │${C_RESET} ${C_DIM}[Enter] continue  [d]one  [r]edirect  [c]ompact & continue${C_RESET} " >/dev/tty

        local lim_input=""
        IFS= read -r lim_input </dev/tty 2>/dev/null || true

        case "$lim_input" in
            d|done|q|quit|stop|n|no)
                if [[ -n "$summary_content" && "$summary_content" != "null" ]]; then
                    final_content="$summary_content"
                else
                    final_content="Subagent stopped at iteration limit ($total_tool_calls tool calls)."
                fi
                break  # exit outer loop
                ;;
            c|compact)
                # Compact context and continue
                local compact_summary="${summary_content:-No summary available.}"
                jq -n \
                    --arg system "$subagent_system" \
                    --arg summary "[Previous work — $total_tool_calls tool calls completed]\n\n$compact_summary" \
                    --arg cont "Continue where you left off. Work through the remaining items. Use your tools." \
                    '[{"role": "system", "content": $system}, {"role": "user", "content": $summary}, {"role": "assistant", "content": "Understood. Continuing from where I left off."}, {"role": "user", "content": $cont}]' \
                    > "$subagent_messages"
                printf "${C_DIM}  │${C_RESET} ${C_DIM}context compacted — continuing${C_RESET}\n" >/dev/tty
                # Reset loop counter, keep tool call count for stats
                loop_count=0
                consecutive_text_only=0
                recent_calls=""
                consecutive_failures=0
                continue  # continue outer loop
                ;;
            r|redirect)
                printf "${C_DIM}  │${C_RESET} ${C_BCYAN}new direction:${C_RESET} " >/dev/tty
                local lim_redirect=""
                IFS= read -r lim_redirect </dev/tty 2>/dev/null || true
                local compact_summary="${summary_content:-No summary available.}"
                jq -n \
                    --arg system "$subagent_system" \
                    --arg summary "[Previous work — $total_tool_calls tool calls completed]\n\n$compact_summary" \
                    --arg redirect "${lim_redirect:-Continue where you left off.}" \
                    '[{"role": "system", "content": $system}, {"role": "user", "content": $summary}, {"role": "assistant", "content": "Understood. I have the context from my previous work."}, {"role": "user", "content": $redirect}]' \
                    > "$subagent_messages"
                printf "${C_DIM}  │${C_RESET} ${C_DIM}compacted & redirected${C_RESET}\n" >/dev/tty
                loop_count=0
                consecutive_text_only=0
                recent_calls=""
                consecutive_failures=0
                continue  # continue outer loop
                ;;
            *)
                # Just continue — add user message if they typed something
                if [[ -n "$lim_input" ]]; then
                    jq --arg msg "$lim_input" \
                        '. + [{"role": "user", "content": $msg}]' \
                        "$subagent_messages" > "$tmp" && mv "$tmp" "$subagent_messages"
                else
                    jq --arg msg "Continue where you left off. Work through the remaining items you listed. Use your tools — do not just describe what you'll do." \
                        '. + [{"role": "user", "content": $msg}]' \
                        "$subagent_messages" > "$tmp" && mv "$tmp" "$subagent_messages"
                fi
                # Reset loop counter, keep everything else
                loop_count=0
                consecutive_text_only=0
                printf "${C_DIM}  │${C_RESET} ${C_DIM}continuing...${C_RESET}\n" >/dev/tty
                continue  # continue outer loop
                ;;
        esac
    fi

    # Inner loop ended without hitting max — break outer
    break

    done
    # ── end outer while ──

    # ── Footer ──
    local final_tokens=$((SUBAGENT_PROMPT_TOKENS + SUBAGENT_COMPLETION_TOKENS))
    printf "${C_DIM}  │${C_RESET}\n" >/dev/tty
    printf "${C_DIM}  │${C_RESET} ${C_DIM}%d tool calls, %d loops, ~%d tokens${C_RESET}\n" \
        "$total_tool_calls" "$loop_count" "$final_tokens" >/dev/tty
    printf "${C_DIM}  ╰──────────────────────────────────────${C_RESET}\n\n" >/dev/tty

    # Clean up
    rm -rf "$subagent_dir"

    # Report tokens back to main turn counters
    TURN_PROMPT_TOKENS=$((TURN_PROMPT_TOKENS + SUBAGENT_PROMPT_TOKENS))
    TURN_COMPLETION_TOKENS=$((TURN_COMPLETION_TOKENS + SUBAGENT_COMPLETION_TOKENS))

    # Truncate final summary if needed
    if [[ -z "$final_content" ]]; then
        echo "Subagent ($type) completed $total_tool_calls tool calls but produced no summary."
        return 0
    fi

    if (( ${#final_content} > SUBAGENT_SUMMARY_TRUNCATE )); then
        final_content="${final_content:0:$SUBAGENT_SUMMARY_TRUNCATE}
... [summary truncated at $SUBAGENT_SUMMARY_TRUNCATE chars]"
    fi

    echo "$final_content"
}

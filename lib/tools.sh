#!/usr/bin/env bash
# Tool implementations and definitions

# ── Tool definitions JSON (sent to API) ────────────────

get_tool_definitions() {
    # Merge all tool categories into a single JSON array
    local core_defs awareness_defs execution_defs intelligence_defs fileops_defs subagent_defs mcp_defs
    core_defs=$(_get_core_tool_definitions)
    awareness_defs=$(get_awareness_tool_definitions)
    execution_defs=$(get_execution_tool_definitions)
    intelligence_defs=$(get_intelligence_tool_definitions)
    fileops_defs=$(get_fileops_tool_definitions)
    subagent_defs=$(get_subagent_tool_definitions 2>/dev/null) || subagent_defs="[]"
    mcp_defs=$(mcp_get_tool_definitions 2>/dev/null) || mcp_defs="[]"
    jq -s '.[0] + .[1] + .[2] + .[3] + .[4] + .[5] + .[6]' <<< "$core_defs
$awareness_defs
$execution_defs
$intelligence_defs
$fileops_defs
$subagent_defs
$mcp_defs"
}

_get_core_tool_definitions() {
    cat << 'TOOLS_EOF'
[
  {
    "type": "function",
    "function": {
      "name": "read_file",
      "description": "Read the contents of a file. Returns the file content with line numbers. Use this to understand existing code before making changes.",
      "parameters": {
        "type": "object",
        "properties": {
          "path": {
            "type": "string",
            "description": "Path to the file to read (absolute or relative to working directory)"
          }
        },
        "required": ["path"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "write_file",
      "description": "Create a new file or completely overwrite an existing file with new content. Use for creating new files. For modifying existing files, prefer edit_file.",
      "parameters": {
        "type": "object",
        "properties": {
          "path": {
            "type": "string",
            "description": "Path to the file to write"
          },
          "content": {
            "type": "string",
            "description": "The complete content to write to the file"
          }
        },
        "required": ["path", "content"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "edit_file",
      "description": "Replace a specific string in a file with new content. The old_string must match exactly (including whitespace and indentation). Use this for targeted edits to existing files.",
      "parameters": {
        "type": "object",
        "properties": {
          "path": {
            "type": "string",
            "description": "Path to the file to edit"
          },
          "old_string": {
            "type": "string",
            "description": "The exact string to find and replace (must be unique in the file)"
          },
          "new_string": {
            "type": "string",
            "description": "The string to replace it with"
          }
        },
        "required": ["path", "old_string", "new_string"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "bash",
      "description": "Execute a bash command on the local system and return its output (stdout + stderr). You have FULL system access. Use this for ALL shell operations: builds (xcodebuild, swift build, make, cargo), tests, git, package management (brew, npm, pip), file operations, and any CLI tool. You MUST call this tool to run commands — NEVER tell the user to run commands themselves.",
      "parameters": {
        "type": "object",
        "properties": {
          "command": {
            "type": "string",
            "description": "The bash command to execute"
          }
        },
        "required": ["command"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "grep_search",
      "description": "Search file contents using grep. Returns matching lines with file paths and line numbers. Use to find where something is defined or used in the codebase.",
      "parameters": {
        "type": "object",
        "properties": {
          "pattern": {
            "type": "string",
            "description": "The search pattern (supports regex)"
          },
          "path": {
            "type": "string",
            "description": "Directory or file to search in (defaults to current directory)"
          },
          "include": {
            "type": "string",
            "description": "File glob pattern to filter (e.g., '*.py', '*.js')"
          }
        },
        "required": ["pattern"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "glob_find",
      "description": "Find files matching a glob pattern. Returns a list of file paths. Use to discover files in the project.",
      "parameters": {
        "type": "object",
        "properties": {
          "pattern": {
            "type": "string",
            "description": "Glob pattern to match (e.g., '**/*.py', 'src/**/*.ts', '*.json')"
          },
          "path": {
            "type": "string",
            "description": "Base directory to search from (defaults to current directory)"
          }
        },
        "required": ["pattern"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "search_index",
      "description": "Search the project index for files, symbols, and semantic summaries. Matches against file paths, function/class names, AND LLM-generated summaries of what each file does. Also shows dependency relationships. Much faster than grep for understanding project structure. Only works if the user has run \\index.",
      "parameters": {
        "type": "object",
        "properties": {
          "query": {
            "type": "string",
            "description": "Search query to match against symbol names, file paths, and file summaries (case-insensitive regex)"
          }
        },
        "required": ["query"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "scaffold_search",
      "description": "Search the knowledge base for project scaffolds/templates. Returns matching scaffold names and descriptions. When you need to create a new project (Xcode, npm, cargo, etc.), ALWAYS search scaffolds first. If a matching scaffold exists, use read_file to read its files and adapt them to the user's requirements.",
      "parameters": {
        "type": "object",
        "properties": {
          "query": {
            "type": "string",
            "description": "Search query to match against scaffold names, tags, and descriptions (e.g., 'ios swiftui', 'react typescript', 'python cli')"
          }
        },
        "required": ["query"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "task_complete",
      "description": "Signal that you have finished the current task. You MUST call this tool when you are done — do NOT just write a text response and stop. If you have more work to do, keep calling other tools instead. Only call this when you have genuinely completed everything the user asked for.",
      "parameters": {
        "type": "object",
        "properties": {
          "summary": {
            "type": "string",
            "description": "Brief summary of what was accomplished"
          }
        },
        "required": ["summary"]
      }
    }
  }
]
TOOLS_EOF
}

# ── Tool execution ─────────────────────────────────────

# Validate tool arguments: check required params exist and are non-empty
# Returns error string if invalid, empty if valid
_validate_tool_args() {
    local name="$1" args="$2"

    # Map tool name -> required params (space-separated)
    local required=""
    case "$name" in
        read_file)       required="path" ;;
        write_file)      required="path content" ;;
        edit_file)       required="path old_string new_string" ;;
        bash)            required="command" ;;
        grep_search)     required="pattern" ;;
        glob_find)       required="pattern" ;;
        search_index)    required="query" ;;
        scaffold_search) required="query" ;;
        memory)          required="action" ;;
        git_smart)       required="action" ;;
        task_plan)       required="action" ;;
        context_compress) required="text mode" ;;
        subagent)        required="type task" ;;
        recall_turn)     required="query" ;;
        diff_apply)      required="patch" ;;
        web_fetch)       required="url" ;;
        tree_parse)      required="path" ;;
        lsp_query)       required="action" ;;
        batch_edit)      required="find replace" ;;
        run_background)  required="action" ;;
        task_complete)   required="summary" ;;
        *)               return 0 ;; # no validation for unknown/mcp/no-required-param tools
    esac

    # Check each required param
    local param missing=""
    for param in $required; do
        local val
        val=$(echo "$args" | jq -r ".$param // empty" 2>/dev/null)
        if [[ -z "$val" ]]; then
            missing="${missing:+$missing, }$param"
        fi
    done

    if [[ -n "$missing" ]]; then
        echo "Error: Missing required argument(s) for '$name': $missing. Provide all required parameters and try again."
        return 1
    fi
    return 0
}

execute_tool() {
    local name="$1" args_json="$2"
    local result=""
    local exit_code=0

    # Validate args before dispatch
    local validation_error
    validation_error=$(_validate_tool_args "$name" "$args_json") || true
    if [[ -n "$validation_error" ]]; then
        echo "$validation_error"
        return 1
    fi

    case "$name" in
        read_file)
            tool_read_file "$args_json"
            ;;
        write_file)
            tool_write_file "$args_json"
            ;;
        edit_file)
            tool_edit_file "$args_json"
            ;;
        bash)
            tool_bash "$args_json"
            ;;
        grep_search)
            tool_grep_search "$args_json"
            ;;
        glob_find)
            tool_glob_find "$args_json"
            ;;
        search_index)
            tool_search_index "$args_json"
            ;;
        scaffold_search)
            tool_scaffold_search "$args_json"
            ;;
        project_detect)
            tool_project_detect "$args_json"
            ;;
        memory)
            tool_memory "$args_json"
            ;;
        git_smart)
            tool_git_smart "$args_json"
            ;;
        task_plan)
            tool_task_plan "$args_json"
            ;;
        context_compress)
            tool_context_compress "$args_json"
            ;;
        test_run)
            tool_test_run "$args_json"
            ;;
        diff_apply)
            tool_diff_apply "$args_json"
            ;;
        web_fetch)
            tool_web_fetch "$args_json"
            ;;
        tree_parse)
            tool_tree_parse "$args_json"
            ;;
        lsp_query)
            tool_lsp_query "$args_json"
            ;;
        file_tree)
            tool_file_tree "$args_json"
            ;;
        undo)
            tool_undo "$args_json"
            ;;
        batch_edit)
            tool_batch_edit "$args_json"
            ;;
        run_background)
            tool_run_background "$args_json"
            ;;
        subagent)
            tool_subagent "$args_json"
            ;;
        recall_turn)
            tool_recall_turn "$args_json"
            ;;
        task_complete)
            # Handled specially by the agentic loop — just return the summary
            local summary
            summary=$(echo "$args_json" | jq -r '.summary // "Task complete."')
            echo "$summary"
            ;;
        mcp_*)
            # MCP tool calls are prefixed with mcp_<server>_<tool>
            mcp_execute_tool "$name" "$args_json"
            ;;
        *)
            echo "Unknown tool: $name"
            return 1
            ;;
    esac
}

# ── Individual tool implementations ────────────────────

tool_read_file() {
    local args="$1"
    local path
    path=$(echo "$args" | jq -r '.path // empty')

    if [[ -z "$path" ]]; then
        echo "Error: path is required"
        return 1
    fi

    # Resolve relative paths
    [[ "$path" != /* ]] && path="$WORK_DIR/$path"

    if [[ ! -f "$path" ]]; then
        local _dir _suggestions
        _dir=$(dirname "$path")
        _suggestions=""
        if [[ -d "$_dir" ]]; then
            _suggestions=$(ls "$_dir" 2>/dev/null | head -10 | tr '\n' ', ')
        fi
        echo "Error: file not found: $path"
        if [[ -n "$_suggestions" ]]; then
            echo "Files in $(basename "$_dir")/: ${_suggestions%, }"
        fi
        echo "Action: Use glob_find to locate the correct path."
        return 1
    fi

    local size
    size=$(wc -c < "$path")
    if (( size > FILE_SIZE_LIMIT )); then
        echo "Warning: file is large (${size} bytes). Showing first ${FILE_SIZE_LIMIT} characters."
        head -c "$FILE_SIZE_LIMIT" "$path" | cat -n
        echo "... (truncated)"
    else
        cat -n "$path"
    fi
}

tool_write_file() {
    local args="$1"
    local path content
    path=$(echo "$args" | jq -r '.path // empty')
    content=$(echo "$args" | jq -r '.content // empty')

    if [[ -z "$path" ]]; then
        echo "Error: path is required"
        return 1
    fi

    # Fix model sending literal \n instead of actual newlines
    # If content has literal \n but no actual newlines, unescape them
    local actual_lines
    actual_lines=$(printf '%s' "$content" | wc -l | tr -d ' ')
    if (( actual_lines <= 1 )) && [[ "$content" == *'\\n'* || "$content" == *'\n'* ]]; then
        content=$(printf '%s' "$content" | sed 's/\\n/\
/g; s/\\t/\t/g')
    fi

    [[ "$path" != /* ]] && path="$WORK_DIR/$path"

    # Rich confirmation
    local _write_action="Create new file"
    [[ -f "$path" ]] && _write_action="Overwrite existing file"
    local _content_preview
    _content_preview=$(echo "$content" | head -8)
    local _content_lines
    _content_lines=$(echo "$content" | wc -l | tr -d ' ')

    if ! ui_tool_confirm "Write file" "$path" "${_write_action} (${_content_lines} lines)" "" "mutation"; then
        echo "Write cancelled by user."
        return 1
    fi

    # Backup existing file for undo
    if [[ -f "$path" ]]; then
        local backup_dir="$SESSION_DIR/backups"
        mkdir -p "$backup_dir"
        local backup_name
        backup_name=$(echo "$path" | tr '/' '_')
        local backup_path="$backup_dir/${backup_name}.$(date +%s)"
        cp "$path" "$backup_path"
        # Record in undo stack
        echo "$path|$backup_path" >> "$SESSION_DIR/undo_stack.txt"
    fi

    # Create parent directories if needed
    mkdir -p "$(dirname "$path")"
    printf '%s' "$content" > "$path"
    echo "File written: $path ($(wc -c < "$path") bytes)"
}

tool_edit_file() {
    local args="$1"
    local path old_string new_string
    path=$(echo "$args" | jq -r '.path // empty')
    old_string=$(echo "$args" | jq -r '.old_string // empty')
    new_string=$(echo "$args" | jq -r '.new_string // empty')

    if [[ -z "$path" || -z "$old_string" ]]; then
        echo "Error: path and old_string are required"
        return 1
    fi

    # Fix model sending literal \n instead of actual newlines
    local _old_lines _new_lines
    _old_lines=$(printf '%s' "$old_string" | wc -l | tr -d ' ')
    if (( _old_lines <= 1 )) && [[ "$old_string" == *'\\n'* || "$old_string" == *'\n'* ]]; then
        old_string=$(printf '%s' "$old_string" | sed 's/\\n/\
/g; s/\\t/\t/g')
    fi
    _new_lines=$(printf '%s' "$new_string" | wc -l | tr -d ' ')
    if (( _new_lines <= 1 )) && [[ "$new_string" == *'\\n'* || "$new_string" == *'\n'* ]]; then
        new_string=$(printf '%s' "$new_string" | sed 's/\\n/\
/g; s/\\t/\t/g')
    fi

    [[ "$path" != /* ]] && path="$WORK_DIR/$path"

    if [[ ! -f "$path" ]]; then
        # Suggest similar files if possible
        local _dir _base _suggestions
        _dir=$(dirname "$path")
        _base=$(basename "$path")
        _suggestions=""
        if [[ -d "$_dir" ]]; then
            _suggestions=$(ls "$_dir" 2>/dev/null | head -10 | tr '\n' ', ')
        fi
        echo "Error: file not found: $path"
        if [[ -n "$_suggestions" ]]; then
            echo "Files in $(basename "$_dir")/: ${_suggestions%, }"
        fi
        echo "Action: Use glob_find to locate the correct file path."
        return 1
    fi

    # Check that old_string exists in file
    if ! grep -qF "$old_string" "$path"; then
        # Show nearby lines to help the model find the right content
        local _first_line _context_lines
        _first_line=$(echo "$old_string" | head -1)
        echo "Error: old_string not found in $path."
        echo "First line searched: $(echo "$_first_line" | head -c 100)"
        # Try a fuzzy search for the first line
        _context_lines=$(grep -n -F "$(echo "$_first_line" | sed 's/^[[:space:]]*//' | head -c 40)" "$path" 2>/dev/null | head -3) || true
        if [[ -n "$_context_lines" ]]; then
            echo "Similar lines found:"
            echo "$_context_lines"
            echo "Action: Read the file first to get the exact current content, including whitespace and indentation."
        else
            echo "No similar content found. The file may have changed since you last read it."
            echo "Action: Use read_file to see the current contents of $path."
        fi
        return 1
    fi

    # Check uniqueness
    local match_count
    match_count=$(grep -cF "$old_string" "$path")
    if (( match_count > 1 )); then
        echo "Error: old_string matches $match_count locations in $path. Provide more surrounding context lines to make the match unique."
        echo "Action: Include additional lines before/after your target to create a unique match."
        return 1
    fi

    # Perform the replacement using perl (reliable multiline support on macOS)
    local tmp="$SESSION_DIR/edit_tmp_$$"
    local old_file="$SESSION_DIR/edit_old_$$"
    local new_file="$SESSION_DIR/edit_new_$$"

    # Write old/new strings to temp files for diff and replacement
    printf '%s\n' "$old_string" > "$old_file"
    printf '%s\n' "$new_string" > "$new_file"

    # Show unified diff preview (write to /dev/tty — visible inside subshells)
    printf "${C_DIM}  ╭── edit: %s ──${C_RESET}\n" "$(basename "$path")" >/dev/tty
    local diff_output
    diff_output=$(diff -u "$old_file" "$new_file" 2>/dev/null | tail -n +3) || true
    if [[ -n "$diff_output" ]]; then
        local line_count=0
        while IFS= read -r dline; do
            line_count=$((line_count + 1))
            if (( line_count > 30 )); then
                printf "${C_DIM}  │ ... (diff truncated)${C_RESET}\n" >/dev/tty
                break
            fi
            if [[ "$dline" == +* ]]; then
                printf "  ${C_DIM}│${C_RESET} ${C_GREEN}%s${C_RESET}\n" "$dline" >/dev/tty
            elif [[ "$dline" == -* ]]; then
                printf "  ${C_DIM}│${C_RESET} ${C_RED}%s${C_RESET}\n" "$dline" >/dev/tty
            elif [[ "$dline" == @@* ]]; then
                printf "  ${C_DIM}│${C_RESET} ${C_CYAN}%s${C_RESET}\n" "$dline" >/dev/tty
            else
                printf "  ${C_DIM}│ %s${C_RESET}\n" "$dline" >/dev/tty
            fi
        done <<< "$diff_output"
    fi
    printf "${C_DIM}  ╰────────${C_RESET}\n" >/dev/tty

    if ! ui_tool_confirm "Edit file" "$(basename "$path")" "Apply changes shown above" "" "mutation"; then
        rm -f "$old_file" "$new_file"
        echo "Edit cancelled by user."
        return 1
    fi

    # Backup existing file for undo
    if [[ -f "$path" ]]; then
        local backup_dir="$SESSION_DIR/backups"
        mkdir -p "$backup_dir"
        local backup_name
        backup_name=$(echo "$path" | tr '/' '_')
        local backup_path="$backup_dir/${backup_name}.$(date +%s)"
        cp "$path" "$backup_path"
        # Record in undo stack
        echo "$path|$backup_path" >> "$SESSION_DIR/undo_stack.txt"
    fi

    # Rewrite old/new without trailing newline for accurate replacement
    printf '%s' "$old_string" > "$old_file"
    printf '%s' "$new_string" > "$new_file"

    perl -0777 -e '
        open(my $of, "<", $ARGV[0]) or die;
        my $old = do { local $/; <$of> }; close($of);
        open(my $nf, "<", $ARGV[1]) or die;
        my $new = do { local $/; <$nf> }; close($nf);
        open(my $sf, "<", $ARGV[2]) or die;
        my $src = do { local $/; <$sf> }; close($sf);
        my $idx = index($src, $old);
        if ($idx >= 0) {
            substr($src, $idx, length($old), $new);
        }
        print $src;
    ' "$old_file" "$new_file" "$path" > "$tmp" 2>/dev/null

    rm -f "$old_file" "$new_file"

    if [[ ! -s "$tmp" ]]; then
        echo "Error: replacement failed"
        rm -f "$tmp"
        return 1
    fi

    mv "$tmp" "$path"
    echo "File edited: $path"
}

# Track commands that failed with "not found" — prevents retry loops
FAILED_COMMANDS=""

tool_bash() {
    local args="$1"
    local command
    command=$(echo "$args" | jq -r '.command // empty')

    if [[ -z "$command" ]]; then
        echo "Error: command is required"
        return 1
    fi

    # Extract the primary command name (first word, skip env vars and sudo)
    local primary_cmd
    primary_cmd=$(echo "$command" | sed 's/^[A-Z_]*=[^ ]* //' | sed 's/^sudo //' | awk '{print $1}')

    # Check if this command previously failed with "not found"
    if [[ -n "$primary_cmd" && " $FAILED_COMMANDS " == *" $primary_cmd "* ]]; then
        echo "Error: '$primary_cmd' is not installed on this system (previously failed). Try a different approach. Do NOT retry this command."
        return 1
    fi

    # Pre-validate: check if the primary command exists before running
    if [[ -n "$primary_cmd" && "$primary_cmd" != "." && "$primary_cmd" != "source" ]]; then
        # Skip validation for shell builtins, paths, and compound commands
        if [[ "$primary_cmd" != /* && "$primary_cmd" != *"/"* ]]; then
            if ! command -v "$primary_cmd" >/dev/null 2>&1 && ! type "$primary_cmd" >/dev/null 2>&1; then
                FAILED_COMMANDS="$FAILED_COMMANDS $primary_cmd"
                echo "Error: '$primary_cmd' is not installed on this system. This command does not exist. You must use a different approach or suggest the user install it."
                return 1
            fi
        fi
    fi

    # ── Dangerous command detection ──
    # Block commands that could cause irreversible damage
    local danger_pattern=""
    local danger_msg=""

    # rm -rf / or rm -rf ~ or rm -rf $HOME  (catastrophic deletion)
    if echo "$command" | grep -qE 'rm\s+(-[a-zA-Z]*r[a-zA-Z]*f|--recursive)\s+(\/|~|\$HOME|\${HOME})\s*$'; then
        danger_pattern="recursive delete of root/home"
        danger_msg="This command would recursively delete critical system/user directories."
    fi

    # dd writing to disk devices
    if echo "$command" | grep -qE 'dd\s+.*of=/dev/(sd|disk|nvme|hd)'; then
        danger_pattern="raw disk write"
        danger_msg="This command writes raw data to a disk device."
    fi

    # chmod/chown -R on root
    if echo "$command" | grep -qE '(chmod|chown)\s+.*-R\s+.*\s+/\s*$'; then
        danger_pattern="recursive permission change on /"
        danger_msg="This command would change permissions/ownership of the entire filesystem."
    fi

    # Fork bombs
    if echo "$command" | grep -qE ':\(\)\{.*\|.*\};:'; then
        danger_pattern="fork bomb"
        danger_msg="This command is a fork bomb that would crash the system."
    fi

    # mkfs (format filesystem)
    if echo "$command" | grep -qE 'mkfs'; then
        danger_pattern="filesystem format"
        danger_msg="This command formats a filesystem, destroying all data on it."
    fi

    if [[ -n "$danger_pattern" ]]; then
        ui_tool_call "bash" "$command"
        printf "${C_RED}${C_BOLD}  BLOCKED: ${C_RESET}${C_RED}%s${C_RESET}\n" "$danger_msg" >/dev/tty
        echo "Error: Dangerous command blocked ($danger_pattern). This command could cause irreversible damage and has been prevented."
        return 1
    fi

    # Rich confirmation with command preview, warnings, and amend support
    if ! ui_tool_confirm "Bash command" "$command" "" "" "execute"; then
        echo "Command cancelled by user."
        return 1
    fi

    # If user amended the command via Tab, use the amended version
    if [[ -n "$_UI_AMENDED_CMD" ]]; then
        command="$_UI_AMENDED_CMD"
        _UI_AMENDED_CMD=""
    fi

    # Execute command with output visible on terminal in real-time
    # Uses tee to capture output while displaying it (supports interactive commands)
    local exit_code=0
    local timeout_cmd=""
    command -v gtimeout >/dev/null 2>&1 && timeout_cmd="gtimeout 120"
    command -v timeout >/dev/null 2>&1 && timeout_cmd="timeout 120"

    local output_file="$SESSION_DIR/bash_output_$$"

    # Run with stdin from /dev/tty (interactive prompts work)
    # Output streams to terminal via tee AND is captured to file
    printf "${C_DIM}" >/dev/tty
    (cd "$WORK_DIR" && $timeout_cmd bash -c "$command" </dev/tty 2>&1) | tee "$output_file" >/dev/tty
    exit_code=${PIPESTATUS[0]}
    printf "${C_RESET}" >/dev/tty

    local output
    output=$(head -c "$FILE_SIZE_LIMIT" "$output_file" 2>/dev/null) || true
    rm -f "$output_file"

    if (( exit_code == 124 || exit_code == 137 )); then
        echo "$output"
        echo "[Command timed out after 120 seconds. Action: Break the command into smaller steps, or use a more targeted approach.]"
    elif (( exit_code != 0 )); then
        echo "$output"
        # Provide actionable context based on common error patterns
        local _err_hint=""
        case "$output" in
            *"command not found"*)
                local _missing_cmd
                _missing_cmd=$(echo "$output" | grep -o '[^ ]*: command not found' | head -1 | cut -d: -f1)
                FAILED_COMMANDS="$FAILED_COMMANDS $_missing_cmd"
                _err_hint="'$_missing_cmd' is not installed. Do NOT retry. Use a different tool or approach." ;;
            *"No such file or directory"*)
                _err_hint="A path does not exist. Use glob_find or read_file to verify paths before using them." ;;
            *"Permission denied"*)
                _err_hint="Permission denied. Check if the file is read-only or if sudo is needed." ;;
            *"syntax error"*)
                _err_hint="The script has a syntax error. Read the error message carefully to identify the line and fix." ;;
        esac
        if [[ -n "$_err_hint" ]]; then
            echo "[Exit code: $exit_code — $_err_hint]"
        else
            echo "[Exit code: $exit_code]"
        fi
    else
        echo "$output"
    fi
}

tool_grep_search() {
    local args="$1"
    local pattern path include
    pattern=$(echo "$args" | jq -r '.pattern // empty')
    path=$(echo "$args" | jq -r '.path // empty')
    include=$(echo "$args" | jq -r '.include // empty')

    if [[ -z "$pattern" ]]; then
        echo "Error: pattern is required"
        return 1
    fi

    [[ -z "$path" ]] && path="$WORK_DIR"
    [[ "$path" != /* ]] && path="$WORK_DIR/$path"

    # Build grep arguments as an array (avoids eval)
    local grep_args=(-rn)
    [[ -n "$include" ]] && grep_args+=(--include="$include")
    grep_args+=(--exclude-dir=.git --exclude-dir=node_modules --exclude-dir=__pycache__ --exclude-dir=.venv --exclude-dir=venv)

    local output
    output=$(grep "${grep_args[@]}" -- "$pattern" "$path" 2>/dev/null | head -100)

    if [[ -z "$output" ]]; then
        echo "No matches found for pattern: $pattern in ${path#$WORK_DIR/}"
        echo "Suggestions: Try a broader pattern, check spelling, or use glob_find to verify file locations."
    else
        echo "$output"
        local total
        total=$(grep "${grep_args[@]}" -c -- "$pattern" "$path" 2>/dev/null | awk -F: '{s+=$NF}END{print s+0}')
        (( total > 100 )) && echo "... (showing first 100 of $total matches)"
    fi
}

tool_glob_find() {
    local args="$1"
    local pattern path
    pattern=$(echo "$args" | jq -r '.pattern // empty')
    path=$(echo "$args" | jq -r '.path // empty')

    if [[ -z "$pattern" ]]; then
        echo "Error: pattern is required"
        return 1
    fi

    [[ -z "$path" ]] && path="$WORK_DIR"
    [[ "$path" != /* ]] && path="$WORK_DIR/$path"

    # Handle glob patterns like **/*.py, src/**/*.ts, *.json
    # Extract directory prefix and filename pattern for find
    local find_path="$path"
    local find_pattern="$pattern"

    # Strip leading **/ (recursive glob prefix)
    find_pattern="${find_pattern##\*\*/}"

    # If pattern has a directory component like src/**/*.ts, combine with base path
    if [[ "$pattern" == *"/"* && "$pattern" != "**/"* ]]; then
        local dir_part="${pattern%%/\*\**}"
        dir_part="${dir_part%%/\**}"
        if [[ -n "$dir_part" && "$dir_part" != "$pattern" ]]; then
            find_path="$path/$dir_part"
            find_pattern="${pattern##*/}"
        fi
    fi

    local output
    output=$(find "$find_path" -name "$find_pattern" \
        -not -path '*/.git/*' \
        -not -path '*/node_modules/*' \
        -not -path '*/__pycache__/*' \
        -not -path '*/.venv/*' \
        -not -path '*/.next/*' \
        -not -path '*/dist/*' \
        -not -path '*/build/*' \
        2>/dev/null | head -200 | sort)

    if [[ -z "$output" ]]; then
        echo "No files found matching: $pattern"
    else
        echo "$output"
        local total
        total=$(find "$find_path" -name "$find_pattern" \
            -not -path '*/.git/*' \
            -not -path '*/node_modules/*' \
            -not -path '*/__pycache__/*' \
            -not -path '*/.venv/*' \
            2>/dev/null | wc -l | tr -d ' ')
        (( total > 200 )) && echo "... (showing first 200 of $total files)"
    fi
}

tool_search_index() {
    local args="$1"
    local query
    query=$(echo "$args" | jq -r '.query // empty')

    if [[ -z "$query" ]]; then
        echo "Error: query is required"
        return 1
    fi

    project_index_search "$WORK_DIR" "$query"
}

tool_scaffold_search() {
    local args="$1"
    local query
    query=$(echo "$args" | jq -r '.query // empty')

    if [[ -z "$query" ]]; then
        echo "Error: query is required"
        return 1
    fi

    local scaffold_dir
    scaffold_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/knowledge/scaffolds"

    if [[ ! -d "$scaffold_dir" ]]; then
        echo "No scaffold knowledge base found."
        return 1
    fi

    # Search all manifest.json files for matching scaffolds
    local results=""
    local count=0
    local manifest

    while IFS= read -r manifest; do
        local name display desc tags category files_list scaffold_path
        name=$(jq -r '.name // empty' "$manifest" 2>/dev/null)
        display=$(jq -r '.display_name // empty' "$manifest" 2>/dev/null)
        desc=$(jq -r '.description // empty' "$manifest" 2>/dev/null)
        tags=$(jq -r '.tags // [] | join(" ")' "$manifest" 2>/dev/null)
        category=$(jq -r '.category // empty' "$manifest" 2>/dev/null)
        scaffold_path=$(dirname "$manifest")

        # Match query against name, display, description, tags, category
        local searchable="$name $display $desc $tags $category"
        local match=0

        # Check each query word (case-insensitive)
        local all_match=1
        local word
        for word in $query; do
            if ! echo "$searchable" | grep -qi "$word"; then
                all_match=0
                break
            fi
        done

        if [[ "$all_match" -eq 1 ]]; then
            count=$((count + 1))

            # List the files in the scaffold
            files_list=$(jq -r '.files[]' "$manifest" 2>/dev/null | head -20)

            results="${results}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[$category] $display
  Name: $name
  Path: $scaffold_path
  Description: $desc
  Tags: $tags
  Files:
$(echo "$files_list" | sed 's/^/    /')
"
        fi
    done < <(find "$scaffold_dir" -name "manifest.json" -type f 2>/dev/null)

    if [[ "$count" -eq 0 ]]; then
        echo "No scaffolds found matching: $query"
        echo ""
        echo "Available categories: mobile, web-frontend, web-backend, cli, libraries, desktop, devops"
        echo "Try broader terms like 'ios', 'react', 'python', 'rust'"
    else
        echo "Found $count scaffold(s) matching '$query':$results"
        echo ""
        echo "To use a scaffold: read its files with read_file, then adapt the content to the user's project name and requirements."
    fi
}

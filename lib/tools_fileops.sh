#!/usr/bin/env bash
# File operation tools: file_tree, undo, batch_edit, run_background
# Bash 3.2 compatible — NO associative arrays, NO read -a, NO readarray

# ── File ops tool definitions JSON ───────────────────

get_fileops_tool_definitions() {
    cat << 'FILEOPS_TOOLS_EOF'
[
  {
    "type": "function",
    "function": {
      "name": "file_tree",
      "description": "Show a visual directory tree of the project. Shows files and folders in a tree structure, great for understanding project layout. Skips common non-source directories (.git, node_modules, etc.).",
      "parameters": {
        "type": "object",
        "properties": {
          "path": {
            "type": "string",
            "description": "Directory to show tree for (defaults to working directory)"
          },
          "depth": {
            "type": "integer",
            "description": "Max depth to recurse (default 3)"
          },
          "show_hidden": {
            "type": "boolean",
            "description": "Show hidden files/directories (default false)"
          }
        },
        "required": []
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "undo",
      "description": "Undo the last file modification (write_file or edit_file). Shows what will be reverted and asks for confirmation. Can undo multiple times to walk back through changes.",
      "parameters": {
        "type": "object",
        "properties": {
          "count": {
            "type": "integer",
            "description": "Number of operations to undo (default 1)"
          },
          "list": {
            "type": "boolean",
            "description": "If true, just list the undo stack without reverting"
          }
        },
        "required": []
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "batch_edit",
      "description": "Find and replace text across multiple files. Shows a preview of all changes before applying. Great for renaming variables, updating imports, or fixing patterns across the codebase.",
      "parameters": {
        "type": "object",
        "properties": {
          "find": {
            "type": "string",
            "description": "Text or regex pattern to find"
          },
          "replace": {
            "type": "string",
            "description": "Replacement text"
          },
          "path": {
            "type": "string",
            "description": "Directory or file glob to search in (defaults to working directory)"
          },
          "include": {
            "type": "string",
            "description": "File glob pattern to filter (e.g., '*.py', '*.ts')"
          },
          "regex": {
            "type": "boolean",
            "description": "Treat 'find' as a regex pattern (default false, uses literal match)"
          },
          "dry_run": {
            "type": "boolean",
            "description": "Preview changes without applying (default false)"
          }
        },
        "required": ["find", "replace"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "run_background",
      "description": "Run a command in the background. Returns immediately with a job ID. Use with action='check' to see if it's still running and get output. Good for long builds, test suites, or server starts.",
      "parameters": {
        "type": "object",
        "properties": {
          "action": {
            "type": "string",
            "enum": ["start", "check", "list", "stop"],
            "description": "Action: start a new background job, check a job's status/output, list all jobs, or stop a job"
          },
          "command": {
            "type": "string",
            "description": "Command to run (required for 'start')"
          },
          "job_id": {
            "type": "string",
            "description": "Job ID to check or stop (required for 'check' and 'stop')"
          }
        },
        "required": ["action"]
      }
    }
  }
]
FILEOPS_TOOLS_EOF
}


# ══════════════════════════════════════════════════════════
# Tool 1: file_tree
# ══════════════════════════════════════════════════════════

tool_file_tree() {
    local args="$1"
    local path depth show_hidden
    path=$(printf '%s' "$args" | jq -r '.path // empty')
    depth=$(printf '%s' "$args" | jq -r '.depth // empty')
    show_hidden=$(printf '%s' "$args" | jq -r '.show_hidden // empty')

    # Defaults
    [[ -z "$path" || "$path" == "null" || "$path" == "." ]] && path="$WORK_DIR"
    [[ "$path" != /* ]] && path="$WORK_DIR/$path"
    # Normalize: strip trailing /. and resolve .. to prevent find -name '.*' from pruning root
    path="${path%/.}"
    path="${path%/}"
    [[ -z "$depth" || "$depth" == "null" ]] && depth=3
    [[ -z "$show_hidden" || "$show_hidden" == "null" ]] && show_hidden="false"

    if [[ ! -d "$path" ]]; then
        echo "Error: directory not found: $path"
        return 1
    fi

    # Directories to skip (prune from find)
    local skip_dirs=".git node_modules __pycache__ .venv .next dist build .cache target vendor"

    # Build find prune arguments
    local prune_expr=""
    local dir
    for dir in $skip_dirs; do
        if [[ -n "$prune_expr" ]]; then
            prune_expr="$prune_expr -o"
        fi
        prune_expr="$prune_expr -name $dir -type d"
    done

    # Collect entries using find
    local tmp_entries="$SESSION_DIR/tree_entries_$$"
    local max_entries=200
    local find_depth_arg="-maxdepth $depth"

    if [[ "$show_hidden" == "true" ]]; then
        find "$path" $find_depth_arg \( $prune_expr \) -prune -o -print 2>/dev/null | \
            head -n $((max_entries + 1)) > "$tmp_entries"
    else
        find "$path" $find_depth_arg \( $prune_expr \) -prune -o \( -name '.*' -prune \) -o -print 2>/dev/null | \
            head -n $((max_entries + 1)) > "$tmp_entries"
    fi

    local total_found
    total_found=$(wc -l < "$tmp_entries" | tr -d ' ')

    local truncated=false
    if (( total_found > max_entries )); then
        truncated=true
        # Re-read only first max_entries lines
        local tmp_trunc="$SESSION_DIR/tree_trunc_$$"
        head -n "$max_entries" "$tmp_entries" > "$tmp_trunc"
        mv "$tmp_trunc" "$tmp_entries"
    fi

    # Sort entries: directories first, then files, alphabetically within each group
    local tmp_sorted="$SESSION_DIR/tree_sorted_$$"
    local tmp_dirs_list="$SESSION_DIR/tree_dirs_$$"
    local tmp_files_list="$SESSION_DIR/tree_files_$$"

    # Separate directories and files, sort each group
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        # Skip the root path itself
        [[ "$entry" == "$path" ]] && continue
        if [[ -d "$entry" ]]; then
            printf '%s\n' "$entry"
        fi
    done < "$tmp_entries" | sort > "$tmp_dirs_list"

    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        [[ "$entry" == "$path" ]] && continue
        if [[ ! -d "$entry" ]]; then
            printf '%s\n' "$entry"
        fi
    done < "$tmp_entries" | sort > "$tmp_files_list"

    # Merge: all entries sorted with dirs and files interleaved at each level
    cat "$tmp_dirs_list" "$tmp_files_list" | sort > "$tmp_sorted"

    # Count dirs and files
    local dir_count file_count
    dir_count=$(wc -l < "$tmp_dirs_list" | tr -d ' ')
    file_count=$(wc -l < "$tmp_files_list" | tr -d ' ')

    # Build the tree output
    local base_name
    base_name=$(basename "$path")
    local result="${base_name}/
"

    # Group entries by parent directory for proper tree drawing
    # Strategy: for each entry, determine its depth relative to root,
    # determine if it's the last entry in its parent, and draw accordingly.

    # Collect all entries in order (dirs first at each level)
    local tmp_tree_input="$SESSION_DIR/tree_input_$$"
    _tree_sort_entries "$path" "$tmp_sorted" > "$tmp_tree_input"

    # Now draw the tree
    local total_entries
    total_entries=$(wc -l < "$tmp_tree_input" | tr -d ' ')
    local entry_num=0

    # For each entry, we need to know if it's the last child of its parent.
    # We precompute this by checking if the next sibling (same parent, same depth) exists.
    local prev_depth=0
    local line_num=0

    # Build an array of entries (bash 3.2: use temp file with line numbers)
    local tmp_indexed="$SESSION_DIR/tree_indexed_$$"
    cat -n "$tmp_tree_input" > "$tmp_indexed"

    # Simple approach: read all entries, compute tree lines
    local entries_data=""
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        entries_data="${entries_data}${entry}
"
    done < "$tmp_tree_input"

    # Use a simpler tree rendering approach
    result=$(_render_tree "$path" "$tmp_tree_input")

    # Footer
    local footer="${dir_count} directories, ${file_count} files"
    if $truncated; then
        footer="${footer} (truncated at ${max_entries} entries)"
    fi

    # Cleanup
    rm -f "$tmp_entries" "$tmp_sorted" "$tmp_dirs_list" "$tmp_files_list" "$tmp_tree_input" "$tmp_indexed"

    printf '%s\n\n%s\n' "$result" "$footer"
}

# Sort entries for tree display: at each directory level, dirs first then files
_tree_sort_entries() {
    local root="$1"
    local entries_file="$2"

    # Group by parent dir, within each group: dirs first then files, sorted
    local tmp_parent="$SESSION_DIR/tree_parent_$$"

    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        local parent
        parent=$(dirname "$entry")
        local name
        name=$(basename "$entry")
        local is_dir=0
        [[ -d "$entry" ]] && is_dir=1
        # Output: parent|is_dir|name|full_path
        # Sort: by parent, then is_dir descending (dirs=1 first), then name
        printf '%s|%s|%s|%s\n' "$parent" "$is_dir" "$name" "$entry"
    done < "$entries_file" | sort -t'|' -k1,1 -k2,2r -k3,3 > "$tmp_parent"

    # Output just the full paths in sorted order
    while IFS='|' read -r _p _d _n full; do
        printf '%s\n' "$full"
    done < "$tmp_parent"

    rm -f "$tmp_parent"
}

# Render tree with box-drawing characters
_render_tree() {
    local root="$1"
    local entries_file="$2"
    local root_name
    root_name=$(basename "$root")

    # Read all entries into a temporary numbered file for lookahead
    local tmp_numbered="$SESSION_DIR/tree_num_$$"
    cat -n "$entries_file" > "$tmp_numbered"

    local total
    total=$(wc -l < "$entries_file" | tr -d ' ')

    printf '%s/\n' "$root_name"

    # For the tree, we need to know whether each entry is the last child of its parent
    # at each depth level. We track active branch lines with a "prefix stack".

    local root_len=${#root}
    local line_idx=0

    # Read all entries into a temp file with metadata
    local tmp_meta="$SESSION_DIR/tree_meta_$$"
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        line_idx=$((line_idx + 1))
        # Strip root prefix to get relative path
        local rel="${entry#$root/}"
        # Compute depth by counting slashes
        local depth
        depth=$(printf '%s' "$rel" | tr -cd '/' | wc -c | tr -d ' ')
        local name
        name=$(basename "$entry")
        local is_dir=0
        [[ -d "$entry" ]] && is_dir=1
        local parent
        parent=$(dirname "$entry")
        printf '%s|%s|%s|%s|%s\n' "$line_idx" "$depth" "$is_dir" "$name" "$parent"
    done < "$entries_file" > "$tmp_meta"

    # For each entry, determine if it's the last sibling (same parent)
    # by checking if any later entry shares the same parent
    local tmp_with_last="$SESSION_DIR/tree_last_$$"
    while IFS='|' read -r idx dep is_d nm par; do
        local is_last=1
        # Check if any subsequent entry has the same parent
        local found_later=false
        while IFS='|' read -r idx2 dep2 is_d2 nm2 par2; do
            if (( idx2 > idx )) && [[ "$par2" == "$par" ]]; then
                found_later=true
                break
            fi
        done < "$tmp_meta"
        if $found_later; then
            is_last=0
        fi
        printf '%s|%s|%s|%s|%s|%s\n' "$idx" "$dep" "$is_d" "$nm" "$par" "$is_last"
    done < "$tmp_meta" > "$tmp_with_last"

    # Now render each line
    # We track which depth levels have continuing branches
    # Using a simple string where char at position N = '1' (has branch) or '0' (no branch)
    local branch_active=""
    # Initialize with enough zeros
    local max_d=0
    while IFS='|' read -r idx dep is_d nm par is_last; do
        (( dep > max_d )) && max_d=$dep
    done < "$tmp_with_last"

    local i=0
    while (( i <= max_d )); do
        branch_active="${branch_active}0"
        i=$((i + 1))
    done

    while IFS='|' read -r idx dep is_d nm par is_last; do
        local prefix=""
        # Build prefix from depth 0 to dep-1
        local d=0
        while (( d < dep )); do
            local branch_char
            branch_char=$(printf '%s' "$branch_active" | cut -c$((d + 1)))
            if [[ "$branch_char" == "1" ]]; then
                prefix="${prefix}│   "
            else
                prefix="${prefix}    "
            fi
            d=$((d + 1))
        done

        # Connector for this entry
        local connector
        if [[ "$is_last" == "1" ]]; then
            connector="└── "
            # Turn off branch at this depth
            local before after
            before=$(printf '%s' "$branch_active" | cut -c1-$dep 2>/dev/null) || before=""
            after=$(printf '%s' "$branch_active" | cut -c$((dep + 2))- 2>/dev/null) || after=""
            branch_active="${before}0${after}"
        else
            connector="├── "
            # Turn on branch at this depth
            local before after
            before=$(printf '%s' "$branch_active" | cut -c1-$dep 2>/dev/null) || before=""
            after=$(printf '%s' "$branch_active" | cut -c$((dep + 2))- 2>/dev/null) || after=""
            branch_active="${before}1${after}"
        fi

        # Display name
        local display_name="$nm"
        if [[ "$is_d" == "1" ]]; then
            display_name="${nm}/"
        fi

        printf '%s%s%s\n' "$prefix" "$connector" "$display_name"
    done < "$tmp_with_last"

    rm -f "$tmp_numbered" "$tmp_meta" "$tmp_with_last"
}


# ══════════════════════════════════════════════════════════
# Tool 2: undo
# ══════════════════════════════════════════════════════════

tool_undo() {
    local args="$1"
    local count list_mode
    count=$(printf '%s' "$args" | jq -r '.count // empty')
    list_mode=$(printf '%s' "$args" | jq -r '.list // empty')

    # Defaults
    [[ -z "$count" || "$count" == "null" ]] && count=1
    [[ -z "$list_mode" || "$list_mode" == "null" ]] && list_mode="false"

    local stack_file="$SESSION_DIR/undo_stack.txt"

    # Check if undo stack exists and is non-empty
    if [[ ! -f "$stack_file" ]] || [[ ! -s "$stack_file" ]]; then
        echo "Undo stack is empty. No file modifications to undo."
        return 0
    fi

    local stack_lines
    stack_lines=$(wc -l < "$stack_file" | tr -d ' ')

    # ── List mode ──
    if [[ "$list_mode" == "true" ]]; then
        printf 'Undo stack (%s entries):\n' "$stack_lines"

        local now
        now=$(date +%s)
        local entry_num=0

        # Read from bottom (most recent) to top
        local tmp_reversed="$SESSION_DIR/undo_reversed_$$"
        tail -r "$stack_file" 2>/dev/null > "$tmp_reversed" || \
            tac "$stack_file" 2>/dev/null > "$tmp_reversed" || \
            awk '{a[NR]=$0} END{for(i=NR;i>=1;i--) print a[i]}' "$stack_file" > "$tmp_reversed"

        while IFS='|' read -r orig_path backup_path; do
            [[ -z "$orig_path" ]] && continue
            entry_num=$((entry_num + 1))

            # Get timestamp from backup filename (last component after last dot)
            local backup_ts
            backup_ts=$(printf '%s' "$backup_path" | grep -oE '[0-9]+$') || backup_ts=0

            # Calculate age
            local age_desc="unknown"
            if [[ -n "$backup_ts" ]] && (( backup_ts > 0 )); then
                local age_secs=$((now - backup_ts))
                if (( age_secs < 60 )); then
                    age_desc="${age_secs}s ago"
                elif (( age_secs < 3600 )); then
                    age_desc="$((age_secs / 60))m ago"
                else
                    age_desc="$((age_secs / 3600))h ago"
                fi
            fi

            # Determine operation type from context
            local op_type="modified"
            local rel_path="${orig_path#$WORK_DIR/}"

            printf '  %d. %s (%s %s)\n' "$entry_num" "$rel_path" "$op_type" "$age_desc"
        done < "$tmp_reversed"

        rm -f "$tmp_reversed"
        return 0
    fi

    # ── Undo mode ──

    if (( count > stack_lines )); then
        echo "Warning: only $stack_lines entries in undo stack, will undo all."
        count=$stack_lines
    fi

    # Read the last N entries (most recent)
    local tmp_to_undo="$SESSION_DIR/undo_todo_$$"
    tail -n "$count" "$stack_file" > "$tmp_to_undo"

    # Reverse so most recent is first
    local tmp_reversed="$SESSION_DIR/undo_rev_$$"
    tail -r "$tmp_to_undo" 2>/dev/null > "$tmp_reversed" || \
        tac "$tmp_to_undo" 2>/dev/null > "$tmp_reversed" || \
        awk '{a[NR]=$0} END{for(i=NR;i>=1;i--) print a[i]}' "$tmp_to_undo" > "$tmp_reversed"

    # Show what will be reverted
    printf 'Will undo %d operation(s):\n\n' "$count"

    local undo_num=0
    local all_valid=true

    while IFS='|' read -r orig_path backup_path; do
        [[ -z "$orig_path" ]] && continue
        undo_num=$((undo_num + 1))

        local rel_path="${orig_path#$WORK_DIR/}"

        if [[ ! -f "$backup_path" ]]; then
            printf '  %d. %s — backup file missing!\n' "$undo_num" "$rel_path"
            all_valid=false
            continue
        fi

        printf '  %d. %s\n' "$undo_num" "$rel_path"

        # Show diff between current file and backup
        if [[ -f "$orig_path" ]]; then
            local diff_out
            diff_out=$(diff -u "$orig_path" "$backup_path" 2>/dev/null | head -20) || true
            if [[ -n "$diff_out" ]]; then
                local dline
                while IFS= read -r dline; do
                    if [[ "$dline" == ---* || "$dline" == +++* ]]; then
                        continue
                    elif [[ "$dline" == @@* ]]; then
                        printf "${C_CYAN}     %s${C_RESET}\n" "$dline" >/dev/tty
                    elif [[ "$dline" == +* ]]; then
                        printf "${C_GREEN}     %s${C_RESET}\n" "$dline" >/dev/tty
                    elif [[ "$dline" == -* ]]; then
                        printf "${C_RED}     %s${C_RESET}\n" "$dline" >/dev/tty
                    fi
                done <<< "$diff_out"
            fi
        else
            printf '     (file was deleted — will restore from backup)\n' >/dev/tty
        fi
    done < "$tmp_reversed"

    printf '\n'

    # Confirm
    ui_tool_call "undo" "$count operation(s)"

    if ! ui_confirm "Revert these changes?" "n" "mutation"; then
        rm -f "$tmp_to_undo" "$tmp_reversed"
        echo "Undo cancelled."
        return 1
    fi

    # Perform the undo
    local restored=0
    local failed=0

    while IFS='|' read -r orig_path backup_path; do
        [[ -z "$orig_path" ]] && continue

        if [[ ! -f "$backup_path" ]]; then
            printf 'Skipped: %s (backup missing)\n' "${orig_path#$WORK_DIR/}"
            failed=$((failed + 1))
            continue
        fi

        # Restore the backup
        mkdir -p "$(dirname "$orig_path")"
        cp "$backup_path" "$orig_path"
        restored=$((restored + 1))
        printf 'Restored: %s\n' "${orig_path#$WORK_DIR/}"
    done < "$tmp_reversed"

    # Remove undone entries from the stack
    local remaining=$((stack_lines - count))
    if (( remaining <= 0 )); then
        : > "$stack_file"
    else
        local tmp_new_stack="$SESSION_DIR/undo_new_$$"
        head -n "$remaining" "$stack_file" > "$tmp_new_stack"
        mv "$tmp_new_stack" "$stack_file"
    fi

    rm -f "$tmp_to_undo" "$tmp_reversed"

    printf '\nUndo complete: %d restored, %d failed\n' "$restored" "$failed"
}


# ══════════════════════════════════════════════════════════
# Tool 3: batch_edit
# ══════════════════════════════════════════════════════════

tool_batch_edit() {
    local args="$1"
    local find_str replace_str path include use_regex dry_run
    find_str=$(printf '%s' "$args" | jq -r '.find // empty')
    replace_str=$(printf '%s' "$args" | jq -r '.replace // empty')
    path=$(printf '%s' "$args" | jq -r '.path // empty')
    include=$(printf '%s' "$args" | jq -r '.include // empty')
    use_regex=$(printf '%s' "$args" | jq -r '.regex // empty')
    dry_run=$(printf '%s' "$args" | jq -r '.dry_run // empty')

    if [[ -z "$find_str" ]]; then
        echo "Error: find is required"
        return 1
    fi

    # Defaults
    [[ -z "$path" || "$path" == "null" ]] && path="$WORK_DIR"
    [[ "$path" != /* ]] && path="$WORK_DIR/$path"
    [[ -z "$use_regex" || "$use_regex" == "null" ]] && use_regex="false"
    [[ -z "$dry_run" || "$dry_run" == "null" ]] && dry_run="false"

    if [[ ! -e "$path" ]]; then
        echo "Error: path not found: $path"
        return 1
    fi

    # Build grep arguments
    local grep_flag="-F"
    [[ "$use_regex" == "true" ]] && grep_flag="-E"

    local grep_args=(-rn "$grep_flag" --exclude-dir=.git --exclude-dir=node_modules \
        --exclude-dir=__pycache__ --exclude-dir=.venv --exclude-dir=.next \
        --exclude-dir=dist --exclude-dir=build --exclude-dir=.cache \
        --exclude-dir=target --exclude-dir=vendor)

    [[ -n "$include" && "$include" != "null" ]] && grep_args+=(--include="$include")

    # Find all matching files
    local tmp_matches="$SESSION_DIR/batch_matches_$$"
    grep "${grep_args[@]}" -- "$find_str" "$path" 2>/dev/null > "$tmp_matches" || true

    if [[ ! -s "$tmp_matches" ]]; then
        rm -f "$tmp_matches"
        echo "No matches found for: $find_str"
        return 0
    fi

    # Build preview output, grouped by file
    local preview=""
    local current_file=""
    local file_match_count=0
    local total_matches=0
    local total_files=0
    local file_list=""

    # Escape special characters in find_str for display
    local display_find="$find_str"
    local display_replace="$replace_str"

    preview="Batch edit: \"${display_find}\" -> \"${display_replace}\"

"

    while IFS= read -r match_line; do
        [[ -z "$match_line" ]] && continue

        # Parse grep output: file:linenum:content
        local file_path line_num content
        file_path=$(printf '%s' "$match_line" | cut -d: -f1)
        line_num=$(printf '%s' "$match_line" | cut -d: -f2)
        content=$(printf '%s' "$match_line" | cut -d: -f3-)

        # Make path relative for display
        local rel_file="${file_path#$WORK_DIR/}"

        if [[ "$file_path" != "$current_file" ]]; then
            # New file — count matches for previous file
            if [[ -n "$current_file" ]]; then
                preview="${preview}
"
            fi
            current_file="$file_path"
            total_files=$((total_files + 1))
            file_list="${file_list}${file_path}
"

            # Count matches in this file
            local fcount
            fcount=$(grep -c "${grep_args[@]:1}" -- "$find_str" "$file_path" 2>/dev/null) || fcount=0
            preview="${preview}${rel_file} (${fcount} match$([ "$fcount" -ne 1 ] && echo 'es')):
"
        fi

        total_matches=$((total_matches + 1))

        # Show before -> after for this line (truncate long lines)
        local truncated_content
        if (( ${#content} > 120 )); then
            truncated_content="${content:0:120}..."
        else
            truncated_content="$content"
        fi

        preview="${preview}  L${line_num}: ${truncated_content}
"

        # Cap preview at 50 matches
        if (( total_matches >= 50 )); then
            preview="${preview}  ... (more matches not shown)
"
            break
        fi
    done < "$tmp_matches"

    # Recount total matches (could be more than 50)
    total_matches=$(wc -l < "$tmp_matches" | tr -d ' ')

    preview="${preview}
Total: ${total_matches} replacement(s) across ${total_files} file(s)
"

    # Show preview to user
    printf '%s\n' "$preview" >/dev/tty

    rm -f "$tmp_matches"

    # Dry run — just return the preview
    if [[ "$dry_run" == "true" ]]; then
        printf '%s\n(dry run — no changes applied)' "$preview"
        return 0
    fi

    # Confirm
    ui_tool_call "batch_edit" "${total_matches} replacements across ${total_files} files"

    if ! ui_confirm "Apply these changes?" "n" "mutation"; then
        echo "Batch edit cancelled."
        return 1
    fi

    # Apply replacements file by file
    local applied_files=0
    local applied_matches=0

    local file_path
    while IFS= read -r file_path; do
        [[ -z "$file_path" ]] && continue
        [[ ! -f "$file_path" ]] && continue

        # Backup file for undo
        local backup_dir="$SESSION_DIR/backups"
        mkdir -p "$backup_dir"
        local backup_name
        backup_name=$(echo "$file_path" | tr '/' '_')
        local backup_path="$backup_dir/${backup_name}.$(date +%s)"
        cp "$file_path" "$backup_path"
        echo "$file_path|$backup_path" >> "$SESSION_DIR/undo_stack.txt"

        # Count matches in this file before replacement
        local fcount
        fcount=$(grep -c "$grep_flag" -- "$find_str" "$file_path" 2>/dev/null) || fcount=0

        # Perform replacement
        if [[ "$use_regex" == "true" ]]; then
            # Use perl for regex replacement
            perl -pi -e "
                BEGIN { \$find = shift; \$repl = shift; }
                s/\$find/\$repl/g;
            " "$find_str" "$replace_str" "$file_path"
        else
            # Use perl for literal replacement (escape regex metacharacters)
            perl -pi -e '
                BEGIN {
                    $find = shift;
                    $repl = shift;
                    $find = quotemeta($find);
                }
                s/$find/$repl/g;
            ' "$find_str" "$replace_str" "$file_path"
        fi

        applied_files=$((applied_files + 1))
        applied_matches=$((applied_matches + fcount))
    done <<< "$file_list"

    printf 'Applied %d replacement(s) across %d file(s)\n' "$applied_matches" "$applied_files"
}


# ══════════════════════════════════════════════════════════
# Tool 4: run_background
# ══════════════════════════════════════════════════════════

# Job counter file
_bg_counter_file() {
    echo "$SESSION_DIR/jobs/counter"
}

_bg_next_job_id() {
    local counter_file
    counter_file=$(_bg_counter_file)
    mkdir -p "$(dirname "$counter_file")"
    local current=0
    [[ -f "$counter_file" ]] && current=$(cat "$counter_file" 2>/dev/null) || current=0
    current=$((current + 1))
    printf '%s' "$current" > "$counter_file"
    printf 'bg_%s' "$current"
}

tool_run_background() {
    local args="$1"
    local action command job_id
    action=$(printf '%s' "$args" | jq -r '.action // empty')
    command=$(printf '%s' "$args" | jq -r '.command // empty')
    job_id=$(printf '%s' "$args" | jq -r '.job_id // empty')

    if [[ -z "$action" ]]; then
        echo "Error: action is required (start, check, list, stop)"
        return 1
    fi

    local jobs_dir="$SESSION_DIR/jobs"
    mkdir -p "$jobs_dir"

    case "$action" in
        start)
            _bg_start "$command" "$jobs_dir"
            ;;
        check)
            _bg_check "$job_id" "$jobs_dir"
            ;;
        list)
            _bg_list "$jobs_dir"
            ;;
        stop)
            _bg_stop "$job_id" "$jobs_dir"
            ;;
        *)
            echo "Error: unknown action '$action'. Use: start, check, list, stop"
            return 1
            ;;
    esac
}

_bg_start() {
    local command="$1"
    local jobs_dir="$2"

    if [[ -z "$command" ]]; then
        echo "Error: command is required for 'start' action"
        return 1
    fi

    ui_tool_call "run_background" "start: $command"

    if ! ui_confirm "Run in background?" "n" "execute"; then
        echo "Background job cancelled."
        return 1
    fi

    local job_id
    job_id=$(_bg_next_job_id)

    local log_file="$jobs_dir/${job_id}.log"
    local pid_file="$jobs_dir/${job_id}.pid"
    local cmd_file="$jobs_dir/${job_id}.cmd"
    local start_file="$jobs_dir/${job_id}.start"

    # Store command and start time
    printf '%s' "$command" > "$cmd_file"
    date +%s > "$start_file"

    # Run in background
    (cd "$WORK_DIR" && bash -c "$command" > "$log_file" 2>&1; echo $? > "$jobs_dir/${job_id}.exit") &
    local pid=$!
    printf '%s' "$pid" > "$pid_file"
    disown "$pid" 2>/dev/null

    printf 'Started background job %s: %s (PID: %s)\n' "$job_id" "$command" "$pid"
}

_bg_check() {
    local job_id="$1"
    local jobs_dir="$2"

    if [[ -z "$job_id" || "$job_id" == "null" ]]; then
        echo "Error: job_id is required for 'check' action"
        return 1
    fi

    local pid_file="$jobs_dir/${job_id}.pid"
    local log_file="$jobs_dir/${job_id}.log"
    local exit_file="$jobs_dir/${job_id}.exit"
    local cmd_file="$jobs_dir/${job_id}.cmd"

    if [[ ! -f "$pid_file" ]]; then
        echo "Error: job not found: $job_id"
        return 1
    fi

    local pid
    pid=$(cat "$pid_file" 2>/dev/null) || pid=""
    local cmd_str=""
    [[ -f "$cmd_file" ]] && cmd_str=$(cat "$cmd_file" 2>/dev/null) || cmd_str="unknown"

    # Check if process is still running
    local is_running=false
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        is_running=true
    fi

    if $is_running; then
        printf 'Job %s: RUNNING (PID: %s)\n' "$job_id" "$pid"
        printf 'Command: %s\n\n' "$cmd_str"
        printf '--- Last 20 lines of output ---\n'
        if [[ -f "$log_file" ]]; then
            tail -20 "$log_file" 2>/dev/null || echo "(no output yet)"
        else
            echo "(no output yet)"
        fi
        printf '\n(still running...)\n'
    else
        local exit_code="unknown"
        [[ -f "$exit_file" ]] && exit_code=$(cat "$exit_file" 2>/dev/null) || exit_code="unknown"

        local status="DONE"
        if [[ "$exit_code" != "0" && "$exit_code" != "unknown" ]]; then
            status="FAILED"
        fi

        printf 'Job %s: %s (exit code: %s)\n' "$job_id" "$status" "$exit_code"
        printf 'Command: %s\n\n' "$cmd_str"
        printf '--- Last 50 lines of output ---\n'
        if [[ -f "$log_file" ]]; then
            tail -50 "$log_file" 2>/dev/null || echo "(no output)"
        else
            echo "(no output)"
        fi
    fi
}

_bg_list() {
    local jobs_dir="$1"

    # Find all job pid files
    local found=0
    local now
    now=$(date +%s)

    printf 'Background jobs:\n'

    local pid_file
    for pid_file in "$jobs_dir"/bg_*.pid; do
        [[ -f "$pid_file" ]] || continue
        found=$((found + 1))

        local job_id
        job_id=$(basename "$pid_file" .pid)
        local pid
        pid=$(cat "$pid_file" 2>/dev/null) || pid=""
        local cmd_str="unknown"
        [[ -f "$jobs_dir/${job_id}.cmd" ]] && cmd_str=$(cat "$jobs_dir/${job_id}.cmd" 2>/dev/null) || true
        local start_ts=0
        [[ -f "$jobs_dir/${job_id}.start" ]] && start_ts=$(cat "$jobs_dir/${job_id}.start" 2>/dev/null) || true

        # Truncate command for display
        if (( ${#cmd_str} > 40 )); then
            cmd_str="${cmd_str:0:40}..."
        fi

        # Calculate elapsed/age
        local age_desc=""
        if (( start_ts > 0 )); then
            local elapsed=$((now - start_ts))
            if (( elapsed < 60 )); then
                age_desc="${elapsed}s"
            elif (( elapsed < 3600 )); then
                age_desc="$((elapsed / 60))m"
            else
                age_desc="$((elapsed / 3600))h"
            fi
        fi

        # Check status
        local status="DONE"
        local status_detail=""
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            status="RUNNING"
            status_detail="PID: ${pid}, ${age_desc}"
        else
            local exit_code="unknown"
            [[ -f "$jobs_dir/${job_id}.exit" ]] && exit_code=$(cat "$jobs_dir/${job_id}.exit" 2>/dev/null) || true
            if [[ "$exit_code" == "0" ]]; then
                status="DONE"
            elif [[ "$exit_code" != "unknown" ]]; then
                status="FAILED"
            fi
            status_detail="exit: ${exit_code}, ${age_desc} ago"
        fi

        printf '  %-6s  %-8s  %s (%s)\n' "$job_id" "$status" "$cmd_str" "$status_detail"
    done

    if (( found == 0 )); then
        printf '  (no background jobs)\n'
    fi
}

_bg_stop() {
    local job_id="$1"
    local jobs_dir="$2"

    if [[ -z "$job_id" || "$job_id" == "null" ]]; then
        echo "Error: job_id is required for 'stop' action"
        return 1
    fi

    local pid_file="$jobs_dir/${job_id}.pid"
    local log_file="$jobs_dir/${job_id}.log"

    if [[ ! -f "$pid_file" ]]; then
        echo "Error: job not found: $job_id"
        return 1
    fi

    local pid
    pid=$(cat "$pid_file" 2>/dev/null) || pid=""

    if [[ -z "$pid" ]]; then
        echo "Error: no PID for job $job_id"
        return 1
    fi

    # Check if still running
    if ! kill -0 "$pid" 2>/dev/null; then
        echo "Job $job_id is already finished."
        _bg_check "$job_id" "$jobs_dir"
        return 0
    fi

    # Send SIGTERM
    printf 'Stopping job %s (PID: %s)...\n' "$job_id" "$pid"
    kill -TERM "$pid" 2>/dev/null

    # Wait briefly for graceful shutdown
    local wait_count=0
    while (( wait_count < 10 )); do
        if ! kill -0 "$pid" 2>/dev/null; then
            break
        fi
        sleep 0.5
        wait_count=$((wait_count + 1))
    done

    # If still running, SIGKILL
    if kill -0 "$pid" 2>/dev/null; then
        printf 'Process did not exit gracefully, sending SIGKILL...\n'
        kill -9 "$pid" 2>/dev/null
        sleep 0.5
    fi

    printf 'Job %s stopped.\n\n' "$job_id"

    # Show final output
    printf '--- Final output (last 20 lines) ---\n'
    if [[ -f "$log_file" ]]; then
        tail -20 "$log_file" 2>/dev/null || echo "(no output)"
    else
        echo "(no output)"
    fi
}

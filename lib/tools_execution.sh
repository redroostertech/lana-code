#!/usr/bin/env bash
# Execution enhancement tools: context_compress, test_run, diff_apply
# Compatible with bash 3.2+ (NO associative arrays, NO read -a, NO readarray)

# ── Tool definitions JSON (merged with base tools by API layer) ──

get_execution_tool_definitions() {
    cat << 'TOOLS_EOF'
[
  {
    "type": "function",
    "function": {
      "name": "context_compress",
      "description": "Compress long text by extracting only the most relevant parts. Use this when command output, file contents, or error messages are very long. Returns a condensed version that preserves key information (errors, warnings, key data points) while discarding noise. ALWAYS use this when output exceeds ~100 lines.",
      "parameters": {
        "type": "object",
        "properties": {
          "text": {
            "type": "string",
            "description": "The long text to compress"
          },
          "mode": {
            "type": "string",
            "enum": ["errors", "summary", "key_lines", "head_tail"],
            "description": "Compression mode: 'errors' extracts error/warning lines, 'summary' gives line counts and structure, 'key_lines' extracts lines with key patterns, 'head_tail' shows first and last N lines"
          },
          "max_lines": {
            "type": "integer",
            "description": "Maximum number of output lines (default 30)"
          }
        },
        "required": ["text", "mode"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "test_run",
      "description": "Run tests and return structured results. Auto-detects the test framework based on project files. Returns a concise summary of pass/fail/error counts and details of failures only. Much more context-efficient than running tests via bash.",
      "parameters": {
        "type": "object",
        "properties": {
          "path": {
            "type": "string",
            "description": "Specific test file or directory to test (optional, defaults to all tests)"
          },
          "filter": {
            "type": "string",
            "description": "Filter pattern to select specific tests (e.g., test name, class name)"
          },
          "verbose": {
            "type": "boolean",
            "description": "If true, include passing test names too (default false — only show failures)"
          }
        },
        "required": []
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "diff_apply",
      "description": "Apply a unified diff patch to one or more files. More efficient than multiple edit_file calls for multi-line or multi-file edits. The diff should be in standard unified diff format (like output of 'diff -u' or 'git diff').",
      "parameters": {
        "type": "object",
        "properties": {
          "patch": {
            "type": "string",
            "description": "The unified diff content to apply. Must include --- and +++ file headers and @@ hunk headers."
          },
          "dry_run": {
            "type": "boolean",
            "description": "If true, show what would change without actually applying (default false)"
          }
        },
        "required": ["patch"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "recall_turn",
      "description": "Retrieve full details from earlier turns that were compressed or archived to save context. When tool results are compressed (you see messages like 'full content in turn archive' or 'use recall_turn'), call this to get the original uncompressed data. Search by keyword (file names, tool names, or content keywords).",
      "parameters": {
        "type": "object",
        "properties": {
          "query": {
            "type": "string",
            "description": "Keyword(s) to search for in archived turns (e.g., file name, function name, error text)"
          }
        },
        "required": ["query"]
      }
    }
  }
]
TOOLS_EOF
}

# ══════════════════════════════════════════════════════════
# Tool: recall_turn
# ══════════════════════════════════════════════════════════

tool_recall_turn() {
    local args="$1"
    local query
    query=$(echo "$args" | jq -r '.query // empty')

    if [[ -z "$query" ]]; then
        echo "Error: query is required"
        return 1
    fi

    state_recall_turn "$query"
}

# ══════════════════════════════════════════════════════════
# Tool 1: context_compress
# ══════════════════════════════════════════════════════════

tool_context_compress() {
    local args="$1"
    local text mode max_lines
    text=$(printf '%s' "$args" | jq -r '.text // empty')
    mode=$(printf '%s' "$args" | jq -r '.mode // empty')
    max_lines=$(printf '%s' "$args" | jq -r '.max_lines // empty')

    if [[ -z "$text" ]]; then
        echo "Error: text is required"
        return 1
    fi

    if [[ -z "$mode" ]]; then
        echo "Error: mode is required"
        return 1
    fi

    # Default max_lines
    [[ -z "$max_lines" || "$max_lines" == "null" ]] && max_lines=30

    local total_lines
    total_lines=$(printf '%s\n' "$text" | wc -l | tr -d ' ')

    local output=""

    case "$mode" in
        errors)
            output=$(_compress_errors "$text" "$max_lines")
            ;;
        summary)
            output=$(_compress_summary "$text" "$max_lines")
            ;;
        key_lines)
            output=$(_compress_key_lines "$text" "$max_lines")
            ;;
        head_tail)
            output=$(_compress_head_tail "$text" "$max_lines")
            ;;
        *)
            echo "Error: unknown mode '$mode'. Use: errors, summary, key_lines, head_tail"
            return 1
            ;;
    esac

    local output_lines
    output_lines=$(printf '%s\n' "$output" | wc -l | tr -d ' ')

    printf '[Compressed: %s -> %s lines, mode: %s]\n%s' \
        "$total_lines" "$output_lines" "$mode" "$output"
}

# ── errors mode: extract error/warning lines with context ──

_compress_errors() {
    local text="$1"
    local max_lines="$2"
    local tmp_input="$SESSION_DIR/compress_input_$$"
    local tmp_errors="$SESSION_DIR/compress_errors_$$"
    local tmp_dedup="$SESSION_DIR/compress_dedup_$$"

    printf '%s\n' "$text" > "$tmp_input"

    # Find line numbers matching error patterns (case-insensitive)
    local error_pattern='[Ee]rror|ERROR|[Ww]arning|WARN|[Ff]ailed|FAILED|[Ee]xception|[Tt]raceback|[Pp]anic|PANIC|[Ff]atal'

    # Extract matching lines with 1 line of leading context (-B1)
    grep -n -E "$error_pattern" "$tmp_input" 2>/dev/null | head -n "$max_lines" > "$tmp_errors" || true

    if [[ ! -s "$tmp_errors" ]]; then
        rm -f "$tmp_input" "$tmp_errors" "$tmp_dedup"
        echo "No errors/warnings found in output"
        return 0
    fi

    # Build output with context: for each error line, grab the preceding line too
    local result=""
    local prev_linenum=0
    local total_lines
    total_lines=$(wc -l < "$tmp_input" | tr -d ' ')
    local error_count=0
    local seen_lines=""

    while IFS= read -r match_line; do
        # match_line format: "LINENUM:content"
        local linenum="${match_line%%:*}"
        local content="${match_line#*:}"

        # Deduplicate identical error messages
        local content_trimmed
        content_trimmed=$(printf '%s' "$content" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')

        # Check if we have seen this exact line before (simple linear scan)
        local is_dup=false
        local check_line
        while IFS= read -r check_line; do
            [[ -z "$check_line" ]] && continue
            if [[ "$check_line" == "$content_trimmed" ]]; then
                is_dup=true
                break
            fi
        done <<< "$seen_lines"

        if $is_dup; then
            continue
        fi
        seen_lines="${seen_lines}${content_trimmed}
"

        error_count=$((error_count + 1))

        # Get 1 line of context before (if not adjacent to previous match)
        if [[ -n "$linenum" ]] && (( linenum > 1 )); then
            local ctx_linenum=$((linenum - 1))
            if (( ctx_linenum > prev_linenum )); then
                local ctx_line
                ctx_line=$(sed -n "${ctx_linenum}p" "$tmp_input" 2>/dev/null) || true
                if [[ -n "$ctx_line" ]]; then
                    result="${result}  ${ctx_linenum}: ${ctx_line}
"
                fi
            fi
        fi

        result="${result}> ${linenum}: ${content}
"
        prev_linenum="$linenum"

        # Cap output
        local current_output_lines
        current_output_lines=$(printf '%s' "$result" | wc -l | tr -d ' ')
        if (( current_output_lines >= max_lines - 2 )); then
            break
        fi
    done < "$tmp_errors"

    result="${result}
Extracted ${error_count} error/warning lines from ${total_lines} total lines"

    rm -f "$tmp_input" "$tmp_errors" "$tmp_dedup"

    printf '%s' "$result"
}

# ── summary mode: structural overview ──

_compress_summary() {
    local text="$1"
    local max_lines="$2"
    local tmp_input="$SESSION_DIR/compress_summary_$$"

    printf '%s\n' "$text" > "$tmp_input"

    local total_lines
    total_lines=$(wc -l < "$tmp_input" | tr -d ' ')

    # Count patterns
    local error_count warning_count success_count
    error_count=$(grep -ciE 'error|ERROR|failed|FAILED|fatal|FATAL|exception|traceback|panic' "$tmp_input" 2>/dev/null) || error_count=0
    warning_count=$(grep -ciE 'warning|WARN' "$tmp_input" 2>/dev/null) || warning_count=0
    success_count=$(grep -ciE 'success|passed|PASSED|ok |OK |SUCCEEDED|completed' "$tmp_input" 2>/dev/null) || success_count=0

    # Determine build status
    local status="UNKNOWN"
    if (( error_count > 0 )); then
        status="FAILED"
    elif (( success_count > 0 )); then
        status="PASSED"
    fi

    local result=""

    # First 5 lines
    result="--- First 5 lines ---
"
    local head_lines
    head_lines=$(head -5 "$tmp_input")
    result="${result}${head_lines}
"

    # Last 5 lines
    result="${result}
--- Last 5 lines ---
"
    local tail_lines
    tail_lines=$(tail -5 "$tmp_input")
    result="${result}${tail_lines}
"

    # Summary line
    result="${result}
Total: ${total_lines} lines | ${error_count} errors | ${warning_count} warnings | Status: ${status}"

    rm -f "$tmp_input"

    printf '%s' "$result"
}

# ── key_lines mode: extract structurally important lines ──

_compress_key_lines() {
    local text="$1"
    local max_lines="$2"
    local tmp_input="$SESSION_DIR/compress_keylines_$$"

    printf '%s\n' "$text" > "$tmp_input"

    local result=""
    local count=0

    # Pattern 1: file paths with line numbers (src/foo.py:42:)
    while IFS= read -r line; do
        (( count >= max_lines )) && break
        result="${result}${line}
"
        count=$((count + 1))
    done < <(grep -nE '[a-zA-Z0-9_/]+\.[a-zA-Z]+:[0-9]+' "$tmp_input" 2>/dev/null | head -n "$max_lines")

    # Pattern 2: lines with =>, ->, :: (definitions/output)
    while IFS= read -r line; do
        (( count >= max_lines )) && break
        result="${result}${line}
"
        count=$((count + 1))
    done < <(grep -nE '=>|->|::' "$tmp_input" 2>/dev/null | head -n "$((max_lines - count))")

    # Pattern 3: diff lines (+ or -)
    while IFS= read -r line; do
        (( count >= max_lines )) && break
        result="${result}${line}
"
        count=$((count + 1))
    done < <(grep -nE '^\+|^-' "$tmp_input" 2>/dev/null | head -n "$((max_lines - count))")

    # Pattern 4: TODO, FIXME, HACK, XXX
    while IFS= read -r line; do
        (( count >= max_lines )) && break
        result="${result}${line}
"
        count=$((count + 1))
    done < <(grep -nE 'TODO|FIXME|HACK|XXX' "$tmp_input" 2>/dev/null | head -n "$((max_lines - count))")

    # Pattern 5: assert, expect, test
    while IFS= read -r line; do
        (( count >= max_lines )) && break
        result="${result}${line}
"
        count=$((count + 1))
    done < <(grep -nE 'assert|expect|test' "$tmp_input" 2>/dev/null | head -n "$((max_lines - count))")

    # Pattern 6: section headers (ALL CAPS lines, ##, ===, ---)
    while IFS= read -r line; do
        (( count >= max_lines )) && break
        result="${result}${line}
"
        count=$((count + 1))
    done < <(grep -nE '^[A-Z][A-Z ]{4,}$|^##|^===|^---' "$tmp_input" 2>/dev/null | head -n "$((max_lines - count))")

    if [[ -z "$result" ]]; then
        result="No key lines detected. Try 'head_tail' or 'summary' mode instead."
    fi

    rm -f "$tmp_input"

    printf '%s' "$result"
}

# ── head_tail mode: first N/2 and last N/2 lines ──

_compress_head_tail() {
    local text="$1"
    local max_lines="$2"
    local tmp_input="$SESSION_DIR/compress_ht_$$"

    printf '%s\n' "$text" > "$tmp_input"

    local total_lines
    total_lines=$(wc -l < "$tmp_input" | tr -d ' ')

    # If text fits in max_lines, just return it all
    if (( total_lines <= max_lines )); then
        cat "$tmp_input"
        rm -f "$tmp_input"
        return 0
    fi

    local half=$((max_lines / 2))
    local omitted=$((total_lines - max_lines))

    local result=""
    local head_part
    head_part=$(head -n "$half" "$tmp_input")
    local tail_part
    tail_part=$(tail -n "$half" "$tmp_input")

    result="${head_part}
... (${omitted} lines omitted) ...
${tail_part}"

    rm -f "$tmp_input"

    printf '%s' "$result"
}


# ══════════════════════════════════════════════════════════
# Tool 2: test_run
# ══════════════════════════════════════════════════════════

tool_test_run() {
    local args="$1"
    local path filter verbose
    path=$(printf '%s' "$args" | jq -r '.path // empty')
    filter=$(printf '%s' "$args" | jq -r '.filter // empty')
    verbose=$(printf '%s' "$args" | jq -r '.verbose // empty')

    # Defaults
    [[ -z "$verbose" || "$verbose" == "null" ]] && verbose="false"

    # Resolve path
    if [[ -n "$path" && "$path" != "null" ]]; then
        [[ "$path" != /* ]] && path="$WORK_DIR/$path"
    fi

    # Auto-detect test framework
    local framework="" test_cmd=""

    framework=$(_detect_test_framework "$path")

    if [[ -z "$framework" ]]; then
        echo "Error: Could not detect test framework. No recognized test config found in $WORK_DIR"
        return 1
    fi

    # Build the test command
    test_cmd=$(_build_test_command "$framework" "$path" "$filter")

    ui_tool_call "test_run" "$framework: $test_cmd"

    if ! ui_confirm "Run tests?" "n" "execute"; then
        echo "Test run cancelled by user."
        return 1
    fi

    # Execute the tests
    local output_file="$SESSION_DIR/test_output_$$"
    local exit_code=0
    local start_time
    start_time=$(date +%s)

    printf "${C_DIM}" >/dev/tty
    (cd "$WORK_DIR" && bash -c "$test_cmd" 2>&1) | tee "$output_file" >/dev/tty
    exit_code=${PIPESTATUS[0]}
    printf "${C_RESET}" >/dev/tty

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    local raw_output
    raw_output=$(cat "$output_file" 2>/dev/null) || raw_output=""
    rm -f "$output_file"

    # Parse and format results
    local formatted
    formatted=$(_parse_test_output "$framework" "$raw_output" "$exit_code" "$duration" "$test_cmd" "$verbose")

    printf '%s' "$formatted"
}

# ── Detect test framework ──

_detect_test_framework() {
    local test_path="$1"
    local search_dir="${test_path:-$WORK_DIR}"

    # If test_path is a file, use its parent directory for detection
    [[ -f "$search_dir" ]] && search_dir=$(dirname "$search_dir")
    # Fall back to WORK_DIR if search_dir is empty
    [[ -z "$search_dir" ]] && search_dir="$WORK_DIR"

    # Check in order of specificity

    # Xcode project
    if ls "$search_dir"/*.xcodeproj >/dev/null 2>&1 || ls "$WORK_DIR"/*.xcodeproj >/dev/null 2>&1; then
        echo "xcodebuild"
        return 0
    fi

    # Swift package (Package.swift)
    if [[ -f "$WORK_DIR/Package.swift" ]]; then
        echo "swift"
        return 0
    fi

    # Cargo (Rust)
    if [[ -f "$WORK_DIR/Cargo.toml" ]]; then
        echo "cargo"
        return 0
    fi

    # Go
    if [[ -f "$WORK_DIR/go.mod" ]]; then
        echo "go"
        return 0
    fi

    # Node.js — check for specific frameworks first
    if [[ -f "$WORK_DIR/package.json" ]]; then
        # vitest
        if grep -q '"vitest"' "$WORK_DIR/package.json" 2>/dev/null; then
            echo "vitest"
            return 0
        fi
        # jest
        if grep -q '"jest"' "$WORK_DIR/package.json" 2>/dev/null; then
            echo "jest"
            return 0
        fi
        # generic npm test
        if jq -e '.scripts.test' "$WORK_DIR/package.json" >/dev/null 2>&1; then
            echo "npm"
            return 0
        fi
    fi

    # Python pytest (explicit config)
    if [[ -f "$WORK_DIR/pytest.ini" ]]; then
        echo "pytest"
        return 0
    fi
    if [[ -f "$WORK_DIR/pyproject.toml" ]] && grep -q 'pytest' "$WORK_DIR/pyproject.toml" 2>/dev/null; then
        echo "pytest"
        return 0
    fi
    if [[ -f "$WORK_DIR/requirements.txt" ]] && grep -q 'pytest' "$WORK_DIR/requirements.txt" 2>/dev/null; then
        echo "pytest"
        return 0
    fi

    # Python fallback (setup.py or pyproject.toml without pytest mention)
    if [[ -f "$WORK_DIR/setup.py" || -f "$WORK_DIR/pyproject.toml" ]]; then
        echo "pytest"
        return 0
    fi

    # Ruby rspec
    if [[ -f "$WORK_DIR/Gemfile" ]] && grep -q 'rspec' "$WORK_DIR/Gemfile" 2>/dev/null; then
        echo "rspec"
        return 0
    fi

    # Ruby rake
    if [[ -f "$WORK_DIR/Rakefile" ]]; then
        echo "rake"
        return 0
    fi

    # Makefile with test target
    if [[ -f "$WORK_DIR/Makefile" ]] && grep -qE '^test:' "$WORK_DIR/Makefile" 2>/dev/null; then
        echo "make"
        return 0
    fi

    # Nothing found
    echo ""
    return 1
}

# ── Build test command for detected framework ──

_build_test_command() {
    local framework="$1"
    local path="$2"
    local filter="$3"

    # Make path relative to WORK_DIR if it's an absolute path inside WORK_DIR
    local rel_path=""
    if [[ -n "$path" && "$path" != "null" ]]; then
        if [[ "$path" == "$WORK_DIR/"* ]]; then
            rel_path="${path#$WORK_DIR/}"
        elif [[ "$path" == /* ]]; then
            rel_path="$path"
        else
            rel_path="$path"
        fi
    fi

    case "$framework" in
        xcodebuild)
            local scheme=""
            # Try to extract scheme from xcodeproj
            local xcodeproj
            xcodeproj=$(ls -d "$WORK_DIR"/*.xcodeproj 2>/dev/null | head -1)
            if [[ -n "$xcodeproj" ]]; then
                scheme=$(xcodebuild -project "$xcodeproj" -list 2>/dev/null | \
                    sed -n '/Schemes:/,/^$/p' | grep -v 'Schemes:' | head -1 | tr -d '[:space:]') || true
            fi
            local cmd="xcodebuild test"
            [[ -n "$scheme" ]] && cmd="$cmd -scheme '$scheme'"
            [[ -n "$filter" ]] && cmd="$cmd -only-testing:'$filter'"
            cmd="$cmd 2>&1"
            echo "$cmd"
            ;;
        swift)
            local cmd="swift test"
            [[ -n "$filter" ]] && cmd="$cmd --filter '$filter'"
            echo "$cmd"
            ;;
        cargo)
            local cmd="cargo test"
            [[ -n "$filter" ]] && cmd="$cmd $filter"
            cmd="$cmd -- --nocapture"
            echo "$cmd"
            ;;
        go)
            local cmd="go test"
            if [[ -n "$rel_path" ]]; then
                cmd="$cmd ./$rel_path/..."
            else
                cmd="$cmd ./..."
            fi
            [[ -n "$filter" ]] && cmd="$cmd -run '$filter'"
            cmd="$cmd -v"
            echo "$cmd"
            ;;
        vitest)
            local cmd="npx vitest run"
            [[ -n "$rel_path" ]] && cmd="$cmd $rel_path"
            [[ -n "$filter" ]] && cmd="$cmd --testNamePattern='$filter'"
            echo "$cmd"
            ;;
        jest)
            local cmd="npx jest"
            [[ -n "$rel_path" ]] && cmd="$cmd $rel_path"
            [[ -n "$filter" ]] && cmd="$cmd --testNamePattern='$filter'"
            echo "$cmd"
            ;;
        npm)
            echo "npm test"
            ;;
        pytest)
            local cmd="python3 -m pytest"
            [[ -n "$rel_path" ]] && cmd="$cmd $rel_path"
            [[ -n "$filter" ]] && cmd="$cmd -k '$filter'"
            cmd="$cmd --tb=short -q"
            echo "$cmd"
            ;;
        rspec)
            local cmd="bundle exec rspec"
            [[ -n "$rel_path" ]] && cmd="$cmd $rel_path"
            [[ -n "$filter" ]] && cmd="$cmd -e '$filter'"
            echo "$cmd"
            ;;
        rake)
            echo "bundle exec rake test"
            ;;
        make)
            echo "make test"
            ;;
        *)
            echo "echo 'Unknown framework: $framework'"
            ;;
    esac
}

# ── Parse test output per framework ──

_parse_test_output() {
    local framework="$1"
    local raw_output="$2"
    local exit_code="$3"
    local duration="$4"
    local test_cmd="$5"
    local verbose="$6"

    local total=0 passed=0 failed=0 skipped=0 errors=0
    local failures=""
    local overall="PASS"
    (( exit_code != 0 )) && overall="FAIL"

    case "$framework" in
        pytest)
            # Parse pytest summary: "X passed, Y failed, Z error" etc.
            local summary_line
            summary_line=$(printf '%s\n' "$raw_output" | grep -E '(passed|failed|error)' | tail -1) || true

            if [[ -n "$summary_line" ]]; then
                passed=$(printf '%s' "$summary_line" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+') || passed=0
                failed=$(printf '%s' "$summary_line" | grep -oE '[0-9]+ failed' | grep -oE '[0-9]+') || failed=0
                errors=$(printf '%s' "$summary_line" | grep -oE '[0-9]+ error' | grep -oE '[0-9]+') || errors=0
                skipped=$(printf '%s' "$summary_line" | grep -oE '[0-9]+ skipped' | grep -oE '[0-9]+') || skipped=0
            fi
            [[ -z "$passed" ]] && passed=0
            [[ -z "$failed" ]] && failed=0
            [[ -z "$errors" ]] && errors=0
            [[ -z "$skipped" ]] && skipped=0
            total=$((passed + failed + errors + skipped))

            # Extract FAILED test details
            failures=$(_extract_pytest_failures "$raw_output")
            ;;

        jest|vitest)
            # Parse jest/vitest summary: "Tests: X passed, Y failed, Z total"
            local tests_line
            tests_line=$(printf '%s\n' "$raw_output" | grep -E 'Tests:' | tail -1) || true

            if [[ -n "$tests_line" ]]; then
                passed=$(printf '%s' "$tests_line" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+') || passed=0
                failed=$(printf '%s' "$tests_line" | grep -oE '[0-9]+ failed' | grep -oE '[0-9]+') || failed=0
                skipped=$(printf '%s' "$tests_line" | grep -oE '[0-9]+ skipped' | grep -oE '[0-9]+') || skipped=0
                total=$(printf '%s' "$tests_line" | grep -oE '[0-9]+ total' | grep -oE '[0-9]+') || total=0
            fi
            [[ -z "$passed" ]] && passed=0
            [[ -z "$failed" ]] && failed=0
            [[ -z "$skipped" ]] && skipped=0
            [[ -z "$total" ]] && total=$((passed + failed + skipped))

            # Extract FAIL blocks
            failures=$(_extract_jest_failures "$raw_output")
            ;;

        cargo)
            # Parse cargo test summary: "test result: ok. X passed; Y failed; Z ignored"
            local result_line
            result_line=$(printf '%s\n' "$raw_output" | grep -E '^test result:' | tail -1) || true

            if [[ -n "$result_line" ]]; then
                passed=$(printf '%s' "$result_line" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+') || passed=0
                failed=$(printf '%s' "$result_line" | grep -oE '[0-9]+ failed' | grep -oE '[0-9]+') || failed=0
                skipped=$(printf '%s' "$result_line" | grep -oE '[0-9]+ ignored' | grep -oE '[0-9]+') || skipped=0
            fi
            [[ -z "$passed" ]] && passed=0
            [[ -z "$failed" ]] && failed=0
            [[ -z "$skipped" ]] && skipped=0
            total=$((passed + failed + skipped))

            # Extract failed test names
            failures=$(_extract_cargo_failures "$raw_output")
            ;;

        go)
            # Parse go test output: count --- FAIL: and --- PASS:
            passed=$(printf '%s\n' "$raw_output" | grep -cE '--- PASS:') || passed=0
            failed=$(printf '%s\n' "$raw_output" | grep -cE '--- FAIL:') || failed=0
            skipped=$(printf '%s\n' "$raw_output" | grep -cE '--- SKIP:') || skipped=0
            total=$((passed + failed + skipped))

            # Extract failure details
            failures=$(_extract_go_failures "$raw_output")
            ;;

        xcodebuild|swift)
            # Parse xcodebuild/swift test output
            local exec_line
            exec_line=$(printf '%s\n' "$raw_output" | grep -E 'Executed [0-9]+ test' | tail -1) || true

            if [[ -n "$exec_line" ]]; then
                total=$(printf '%s' "$exec_line" | grep -oE 'Executed [0-9]+' | grep -oE '[0-9]+') || total=0
                failed=$(printf '%s' "$exec_line" | grep -oE '[0-9]+ failure' | grep -oE '[0-9]+') || failed=0
            fi
            [[ -z "$total" ]] && total=0
            [[ -z "$failed" ]] && failed=0
            passed=$((total - failed))
            (( passed < 0 )) && passed=0

            failures=$(_extract_xcode_failures "$raw_output")
            ;;

        rspec)
            # Parse rspec output: "X examples, Y failures, Z pending"
            local rspec_line
            rspec_line=$(printf '%s\n' "$raw_output" | grep -E '[0-9]+ examples?' | tail -1) || true

            if [[ -n "$rspec_line" ]]; then
                total=$(printf '%s' "$rspec_line" | grep -oE '[0-9]+ examples?' | grep -oE '[0-9]+') || total=0
                failed=$(printf '%s' "$rspec_line" | grep -oE '[0-9]+ failures?' | grep -oE '[0-9]+') || failed=0
                skipped=$(printf '%s' "$rspec_line" | grep -oE '[0-9]+ pending' | grep -oE '[0-9]+') || skipped=0
            fi
            [[ -z "$total" ]] && total=0
            [[ -z "$failed" ]] && failed=0
            [[ -z "$skipped" ]] && skipped=0
            passed=$((total - failed - skipped))
            (( passed < 0 )) && passed=0

            failures=$(_extract_rspec_failures "$raw_output")
            ;;

        *)
            # Fallback: use context_compress in errors mode
            total=$(printf '%s\n' "$raw_output" | wc -l | tr -d ' ')
            failures=$(tool_context_compress "$(printf '{"text":%s,"mode":"errors","max_lines":20}' \
                "$(printf '%s' "$raw_output" | jq -Rs '.')")" 2>/dev/null) || true
            ;;
    esac

    # Determine overall status from parsed data
    if (( failed > 0 || errors > 0 || exit_code != 0 )); then
        overall="FAIL"
    else
        overall="PASS"
    fi

    # Format output
    local result="Test Results: ${overall}
  Framework: ${framework}
  Command: ${test_cmd}
  Duration: ${duration}s

  Total: ${total} | Passed: ${passed} | Failed: ${failed} | Skipped: ${skipped}"

    if [[ -n "$failures" ]]; then
        result="${result}

  Failures:
${failures}"
    fi

    printf '%s' "$result"
}

# ── Per-framework failure extractors ──

_extract_pytest_failures() {
    local output="$1"
    local result=""

    # Pytest FAILED lines: "FAILED tests/test_foo.py::test_bar - AssertionError: ..."
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        # Strip "FAILED " prefix
        local detail="${line#FAILED }"
        # Split on " - " to get test name and error
        local test_name="${detail%% - *}"
        local error_msg="${detail#* - }"
        [[ "$error_msg" == "$detail" ]] && error_msg=""

        # Truncate error message to 3 lines
        if [[ -n "$error_msg" ]]; then
            error_msg=$(printf '%s' "$error_msg" | head -3)
        fi

        result="${result}    x ${test_name}
"
        [[ -n "$error_msg" ]] && result="${result}      ${error_msg}
"
    done < <(printf '%s\n' "$output" | grep -E '^FAILED ' | head -20)

    printf '%s' "$result"
}

_extract_jest_failures() {
    local output="$1"
    local result=""
    local tmp_file="$SESSION_DIR/jest_fail_$$"

    printf '%s\n' "$output" > "$tmp_file"

    # Extract FAIL file lines and their first error line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local test_file="${line#*FAIL }"
        result="${result}    x ${test_file}
"
    done < <(grep -E '^\s*FAIL\s' "$tmp_file" | head -20)

    # Extract individual test failure names: "x test name"
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local trimmed
        trimmed=$(printf '%s' "$line" | sed 's/^[[:space:]]*//')
        result="${result}    ${trimmed}
"
    done < <(grep -E '^\s+[x✕✗]' "$tmp_file" | head -20)

    rm -f "$tmp_file"
    printf '%s' "$result"
}

_extract_cargo_failures() {
    local output="$1"
    local result=""

    # Cargo: "test name ... FAILED"
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local test_name
        test_name=$(printf '%s' "$line" | sed 's/ \.\.\. FAILED$//' | sed 's/^test //')
        result="${result}    x ${test_name}
"
    done < <(printf '%s\n' "$output" | grep -E '^\s*test .+ \.\.\. FAILED' | head -20)

    printf '%s' "$result"
}

_extract_go_failures() {
    local output="$1"
    local result=""
    local tmp_file="$SESSION_DIR/go_fail_$$"

    printf '%s\n' "$output" > "$tmp_file"

    # Go: "--- FAIL: TestName (0.00s)"
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local test_name
        test_name=$(printf '%s' "$line" | sed 's/--- FAIL: //' | sed 's/ (.*//')

        # Try to grab the error message (next non-empty line after FAIL)
        local error_msg
        error_msg=$(grep -A3 "--- FAIL: ${test_name}" "$tmp_file" 2>/dev/null | \
            tail -n +2 | grep -v '^$' | head -2 | sed 's/^[[:space:]]*/      /') || error_msg=""

        result="${result}    x ${test_name}
"
        [[ -n "$error_msg" ]] && result="${result}${error_msg}
"
    done < <(printf '%s\n' "$output" | grep -E '--- FAIL:' | head -20)

    rm -f "$tmp_file"
    printf '%s' "$result"
}

_extract_xcode_failures() {
    local output="$1"
    local result=""

    # Xcode: "Test Case '-[ClassName testName]' failed (0.001 seconds)."
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local test_name
        test_name=$(printf '%s' "$line" | sed "s/.*Test Case '\\(.*\\)' failed.*/\\1/" | sed 's/-\[//' | sed 's/\]//')
        result="${result}    x ${test_name}
"
    done < <(printf '%s\n' "$output" | grep -E "Test Case.*failed" | head -20)

    printf '%s' "$result"
}

_extract_rspec_failures() {
    local output="$1"
    local result=""

    # RSpec: lines after "Failures:" section, format "1) Description"
    local in_failures=false
    local count=0

    while IFS= read -r line; do
        if [[ "$line" == "Failures:" ]]; then
            in_failures=true
            continue
        fi
        if $in_failures; then
            # Stop at empty line after failures or next section
            if [[ "$line" =~ ^[A-Z] && "$line" != *")"* ]]; then
                break
            fi
            # Numbered failure line: "  1) SomeSpec does something"
            if [[ "$line" =~ ^[[:space:]]*[0-9]+\) ]]; then
                local trimmed
                trimmed=$(printf '%s' "$line" | sed 's/^[[:space:]]*//')
                result="${result}    x ${trimmed}
"
                count=$((count + 1))
                (( count >= 20 )) && break
            fi
            # Error detail line (Failure/Error:)
            if [[ "$line" == *"Failure/Error:"* ]]; then
                local trimmed
                trimmed=$(printf '%s' "$line" | sed 's/^[[:space:]]*//')
                result="${result}      ${trimmed}
"
            fi
        fi
    done <<< "$output"

    printf '%s' "$result"
}


# ══════════════════════════════════════════════════════════
# Tool 3: diff_apply
# ══════════════════════════════════════════════════════════

tool_diff_apply() {
    local args="$1"
    local patch_content dry_run
    patch_content=$(printf '%s' "$args" | jq -r '.patch // empty')
    dry_run=$(printf '%s' "$args" | jq -r '.dry_run // empty')

    if [[ -z "$patch_content" ]]; then
        echo "Error: patch is required"
        return 1
    fi

    # Default dry_run
    [[ -z "$dry_run" || "$dry_run" == "null" ]] && dry_run="false"

    # Check for patch or git command availability
    local patch_cmd=""
    if command -v patch >/dev/null 2>&1; then
        patch_cmd="patch"
    elif command -v git >/dev/null 2>&1; then
        patch_cmd="git"
    else
        echo "Error: neither 'patch' nor 'git' is installed. Cannot apply diffs."
        return 1
    fi

    # Save patch to temp file
    local patch_file="$SESSION_DIR/diff_patch_$$"
    printf '%s\n' "$patch_content" > "$patch_file"

    # Parse file paths and change counts from the patch
    local summary=""
    local file_count=0
    local prev_file=""

    while IFS= read -r line; do
        # Match +++ lines to get target file paths
        if [[ "$line" == "+++"* ]]; then
            local fpath
            fpath=$(printf '%s' "$line" | sed 's/^+++ //' | sed 's/\t.*//')
            # Strip a/ or b/ prefix
            fpath=$(printf '%s' "$fpath" | sed 's|^[ab]/||')
            # Skip /dev/null (file deletions)
            [[ "$fpath" == "/dev/null" ]] && continue

            file_count=$((file_count + 1))
            prev_file="$fpath"
        fi
    done < "$patch_file"

    # Count additions and deletions per file using a different approach
    # (bash 3.2 compatible — no associative arrays)
    local detailed_summary=""
    local current_file=""
    local adds=0 dels=0 hunks=0

    while IFS= read -r line; do
        if [[ "$line" == "+++"* ]]; then
            # Emit previous file stats
            if [[ -n "$current_file" ]]; then
                detailed_summary="${detailed_summary}  M ${current_file} (+${adds} -${dels}, ${hunks} hunk(s))
"
            fi
            current_file=$(printf '%s' "$line" | sed 's/^+++ //' | sed 's/\t.*//' | sed 's|^[ab]/||')
            [[ "$current_file" == "/dev/null" ]] && current_file=""
            adds=0
            dels=0
            hunks=0
        elif [[ "$line" == "@@"* ]]; then
            hunks=$((hunks + 1))
        elif [[ "$line" == "+"* && "$line" != "+++"* ]]; then
            adds=$((adds + 1))
        elif [[ "$line" == "-"* && "$line" != "---"* ]]; then
            dels=$((dels + 1))
        fi
    done < "$patch_file"

    # Emit last file
    if [[ -n "$current_file" ]]; then
        detailed_summary="${detailed_summary}  M ${current_file} (+${adds} -${dels}, ${hunks} hunk(s))
"
    fi

    # Handle new files (--- /dev/null)
    while IFS= read -r line; do
        if [[ "$line" == "--- /dev/null" ]]; then
            # Next +++ line is the new file
            :
        fi
    done < "$patch_file"

    summary="Patch affects ${file_count} file(s):
${detailed_summary}"

    ui_tool_call "diff_apply" "${file_count} file(s)"
    printf "${C_DIM}%s${C_RESET}\n" "$summary" >/dev/tty

    # If dry run, just show the summary and exit
    if [[ "$dry_run" == "true" ]]; then
        rm -f "$patch_file"
        printf '%s\n(dry run — no changes applied)' "$summary"
        return 0
    fi

    if ! ui_confirm "Apply this patch?" "n" "mutation"; then
        rm -f "$patch_file"
        echo "Patch cancelled by user."
        return 1
    fi

    # Apply the patch
    local apply_output=""
    local apply_exit=0

    if [[ "$patch_cmd" == "patch" ]]; then
        # Try patch -p1 first (git-style paths with a/ b/ prefix), then fall back to -p0
        apply_output=$(cd "$WORK_DIR" && patch -p1 --fuzz=2 < "$patch_file" 2>&1)
        apply_exit=$?

        if (( apply_exit != 0 )); then
            # Revert any partial application from failed -p1
            cd "$WORK_DIR" && patch -p1 -R < "$patch_file" >/dev/null 2>&1 || true

            # Try -p0
            apply_output=$(cd "$WORK_DIR" && patch -p0 --fuzz=2 < "$patch_file" 2>&1)
            apply_exit=$?
        fi
    else
        # Use git apply
        apply_output=$(cd "$WORK_DIR" && git apply --verbose "$patch_file" 2>&1)
        apply_exit=$?

        if (( apply_exit != 0 )); then
            # Try with -p0
            apply_output=$(cd "$WORK_DIR" && git apply --verbose -p0 "$patch_file" 2>&1)
            apply_exit=$?
        fi
    fi

    # Clean up
    rm -f "$patch_file"

    if (( apply_exit != 0 )); then
        # Check for reject files
        local rejects=""
        local rej_file
        while IFS= read -r rej_file; do
            [[ -z "$rej_file" ]] && continue
            rejects="${rejects}
--- ${rej_file} ---
$(cat "$rej_file" 2>/dev/null)
"
            rm -f "$rej_file"
        done < <(find "$WORK_DIR" -name "*.rej" -newer "$SESSION_DIR" 2>/dev/null)

        local err_result="Patch FAILED (exit code: ${apply_exit}):
${apply_output}"

        if [[ -n "$rejects" ]]; then
            err_result="${err_result}

Reject files:${rejects}

Suggest: review the rejected hunks and apply manually with edit_file."
        fi

        printf '%s' "$err_result"
        return 1
    fi

    # Success
    local result="Patch applied successfully:
${apply_output}"

    printf '%s' "$result"
}

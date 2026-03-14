#!/usr/bin/env bash
# Project loader, parallel indexer, dependency graph, LLM summaries

# ══════════════════════════════════════════════════════════
# SECTION 1: Project tree & loader (unchanged)
# ══════════════════════════════════════════════════════════

project_tree() {
    local dir="${1:-$WORK_DIR}"
    local max_depth="${2:-4}"
    local max_files=200

    find "$dir" \
        -not -path '*/.git/*' \
        -not -path '*/node_modules/*' \
        -not -path '*/__pycache__/*' \
        -not -path '*/.venv/*' \
        -not -path '*/venv/*' \
        -not -path '*/.next/*' \
        -not -path '*/dist/*' \
        -not -path '*/build/*' \
        -not -path '*/.cache/*' \
        -not -path '*/.DS_Store' \
        -maxdepth "$max_depth" \
        2>/dev/null | head -"$max_files" | sort | \
    awk -v base="$dir" '{
        sub(base "/", "", $0)
        n = gsub(/\//, "/")
        indent = ""
        for (i = 0; i < n; i++) indent = indent "  "
        split($0, parts, "/")
        print indent parts[length(parts)]
    }'
}

project_find_key_files() {
    local dir="${1:-$WORK_DIR}"
    local key_files=""

    for f in README.md README.rst README.txt README; do
        [[ -f "$dir/$f" ]] && key_files="$key_files $dir/$f" && break
    done
    for f in package.json Cargo.toml pyproject.toml setup.py go.mod Gemfile pom.xml build.gradle CMakeLists.txt Makefile; do
        [[ -f "$dir/$f" ]] && key_files="$key_files $dir/$f"
    done
    for f in .env.example tsconfig.json .eslintrc.json .prettierrc docker-compose.yml Dockerfile; do
        [[ -f "$dir/$f" ]] && key_files="$key_files $dir/$f"
    done
    for f in src/main.ts src/index.ts src/main.py src/app.py main.py app.py main.go cmd/main.go src/main.rs src/lib.rs index.js src/index.js; do
        [[ -f "$dir/$f" ]] && key_files="$key_files $dir/$f"
    done

    echo "$key_files"
}

project_load() {
    local dir="${1:-$WORK_DIR}"
    local context=""

    ui_info "Loading project: $dir"

    local tree
    tree=$(project_tree "$dir")
    context="## Project Structure\n\n\`\`\`\n${tree}\n\`\`\`\n"

    local key_files
    key_files=$(project_find_key_files "$dir")

    if [[ -n "$key_files" ]]; then
        context="${context}\n## Key Files\n"
        for f in $key_files; do
            local rel_path="${f#$dir/}"
            local size
            size=$(wc -c < "$f" 2>/dev/null)
            if (( size > 10000 )); then
                context="${context}\n### ${rel_path} (${size} bytes, too large - use read_file tool)\n"
                continue
            fi
            local content
            content=$(cat "$f" 2>/dev/null)
            context="${context}\n### ${rel_path}\n\`\`\`\n${content}\n\`\`\`\n"
            ui_dim "  loaded: $rel_path"
        done
    fi

    if [[ -d "$dir/.git" ]]; then
        local branch
        branch=$(cd "$dir" && git branch --show-current 2>/dev/null)
        local recent_commits
        recent_commits=$(cd "$dir" && git log --oneline -5 2>/dev/null)
        if [[ -n "$branch" ]]; then
            context="${context}\n## Git Info\n- Branch: ${branch}\n- Recent commits:\n\`\`\`\n${recent_commits}\n\`\`\`\n"
        fi
    fi

    local project_type="unknown"
    [[ -f "$dir/package.json" ]] && project_type="Node.js/JavaScript"
    [[ -f "$dir/pyproject.toml" || -f "$dir/setup.py" ]] && project_type="Python"
    [[ -f "$dir/Cargo.toml" ]] && project_type="Rust"
    [[ -f "$dir/go.mod" ]] && project_type="Go"
    [[ -f "$dir/pom.xml" || -f "$dir/build.gradle" ]] && project_type="Java"

    context="${context}\n## Project Type: ${project_type}\n"

    # Include index summary if available
    local index_file="$dir/$INDEX_DIR_NAME/index.json"
    if [[ -f "$index_file" ]]; then
        local idx_count
        idx_count=$(jq 'length' "$index_file" 2>/dev/null)
        context="${context}\n## Index Available\n${idx_count} files indexed. Use search_index tool to find symbols/files.\n"
    fi

    printf '%b' "$context"
}

# ══════════════════════════════════════════════════════════
# SECTION 2: Security utilities
# ══════════════════════════════════════════════════════════

# Validate a file path is within the project directory (no traversal)
_secure_path() {
    local base="$1" filepath="$2"
    local resolved
    resolved=$(cd "$base" && realpath -q "$filepath" 2>/dev/null || echo "")
    if [[ -z "$resolved" || "$resolved" != "$base"* ]]; then
        return 1
    fi
    echo "$resolved"
}

# Check if a file is a binary (skip for indexing)
_is_binary() {
    local filepath="$1"
    local mime
    mime=$(file -b --mime-type "$filepath" 2>/dev/null)
    [[ "$mime" != text/* && "$mime" != application/json && "$mime" != application/xml && "$mime" != application/javascript ]]
}

# Sanitize content before sending to LLM (strip obvious injection attempts)
_sanitize_for_llm() {
    local content="$1"
    # Remove any strings that look like prompt injection attempts in comments
    # Strip <|...|> tokens, [INST] markers, <<SYS>> tags
    echo "$content" | sed \
        -e 's/<|[^>]*|>//g' \
        -e 's/\[INST\]//g' \
        -e 's/\[\/INST\]//g' \
        -e 's/<<SYS>>//g' \
        -e 's/<\/SYS>>//g'
}

# ══════════════════════════════════════════════════════════
# SECTION 3: File discovery
# ══════════════════════════════════════════════════════════

# Find all indexable source files in a directory
_index_find_files() {
    local dir="$1"

    # Build find command using IFS splitting (portable across bash/zsh)
    local find_names=""
    local first=true
    local OLD_IFS="$IFS"
    IFS='|'
    for ext in $ALLOWED_EXTENSIONS; do
        if $first; then
            find_names="-name '*.${ext}'"
            first=false
        else
            find_names="$find_names -o -name '*.${ext}'"
        fi
    done

    local exclude_paths=""
    for d in $EXCLUDED_DIRS; do
        exclude_paths="$exclude_paths -not -path '*/${d}/*'"
    done
    IFS="$OLD_IFS"

    eval "find '$dir' -type f \\( $find_names \\) $exclude_paths 2>/dev/null" | head -"$INDEX_MAX_FILES"
}

# ══════════════════════════════════════════════════════════
# SECTION 4: Symbol extraction
# ══════════════════════════════════════════════════════════

_extract_symbols() {
    local filepath="$1"
    local defs=""

    case "$filepath" in
        *.py)
            defs=$(grep -oE '(def |class |async def )\w+' "$filepath" 2>/dev/null | \
                awk '{print $NF}' | head -50 | tr '\n' ',' | sed 's/,$//')
            ;;
        *.js|*.ts|*.tsx|*.jsx|*.vue|*.svelte)
            defs=$(grep -oE '(function |const |let |var |class |export (default )?(function |class |const |let )?)\w+' "$filepath" 2>/dev/null | \
                grep -oE '\w+$' | head -50 | tr '\n' ',' | sed 's/,$//')
            ;;
        *.go)
            defs=$(grep -oE '(func |type )\w+' "$filepath" 2>/dev/null | \
                awk '{print $2}' | head -50 | tr '\n' ',' | sed 's/,$//')
            ;;
        *.rs)
            defs=$(grep -oE '(fn |struct |enum |impl |trait |pub fn |pub struct |pub enum )\w+' "$filepath" 2>/dev/null | \
                awk '{print $NF}' | head -50 | tr '\n' ',' | sed 's/,$//')
            ;;
        *.java|*.kt|*.scala|*.cs)
            defs=$(grep -oE '(class |interface |enum |record |fun |func |def |object )\w+' "$filepath" 2>/dev/null | \
                awk '{print $NF}' | head -50 | tr '\n' ',' | sed 's/,$//')
            ;;
        *.rb)
            defs=$(grep -oE '(def |class |module )\w+' "$filepath" 2>/dev/null | \
                awk '{print $2}' | head -50 | tr '\n' ',' | sed 's/,$//')
            ;;
        *.sh)
            defs=$(grep -oE '^\w+\s*\(\)' "$filepath" 2>/dev/null | \
                sed 's/()//' | head -50 | tr '\n' ',' | sed 's/,$//')
            ;;
        *.c|*.cpp|*.h|*.hpp)
            defs=$(grep -oE '(class |struct |enum |void |int |char |bool |auto |template)\s+\w+' "$filepath" 2>/dev/null | \
                awk '{print $NF}' | head -50 | tr '\n' ',' | sed 's/,$//')
            ;;
        *.php)
            defs=$(grep -oE '(function |class |interface |trait )\w+' "$filepath" 2>/dev/null | \
                awk '{print $NF}' | head -50 | tr '\n' ',' | sed 's/,$//')
            ;;
        *.swift)
            defs=$(grep -oE '(func |class |struct |enum |protocol )\w+' "$filepath" 2>/dev/null | \
                awk '{print $NF}' | head -50 | tr '\n' ',' | sed 's/,$//')
            ;;
    esac

    echo "${defs:-}"
}

# ══════════════════════════════════════════════════════════
# SECTION 5: Import/dependency extraction
# ══════════════════════════════════════════════════════════

_extract_imports() {
    local filepath="$1"
    local imports=""

    case "$filepath" in
        *.py)
            # import foo / from foo import bar / from foo.bar import baz
            imports=$(grep -oE '(^import \w+|^from [\w.]+)' "$filepath" 2>/dev/null | \
                sed 's/^import //; s/^from //' | head -30 | tr '\n' ',' | sed 's/,$//')
            ;;
        *.js|*.ts|*.tsx|*.jsx|*.vue|*.svelte)
            # import ... from 'path' / require('path')
            imports=$(grep -oE "(from ['\"][^'\"]+['\"]|require\(['\"][^'\"]+['\"]\))" "$filepath" 2>/dev/null | \
                sed "s/from ['\"]//; s/['\"]//g; s/require(//; s/)//;" | head -30 | tr '\n' ',' | sed 's/,$//')
            ;;
        *.go)
            # "package/path"
            imports=$(grep -oE '"[^"]+/[^"]+"' "$filepath" 2>/dev/null | \
                tr -d '"' | head -30 | tr '\n' ',' | sed 's/,$//')
            ;;
        *.rs)
            # use crate::path / use std::path
            imports=$(grep -oE 'use (crate|super|std|self)[:a-zA-Z_:]+' "$filepath" 2>/dev/null | \
                sed 's/^use //' | head -30 | tr '\n' ',' | sed 's/,$//')
            ;;
        *.java|*.kt|*.scala)
            # import com.foo.Bar
            imports=$(grep -oE 'import [\w.]+' "$filepath" 2>/dev/null | \
                sed 's/^import //' | head -30 | tr '\n' ',' | sed 's/,$//')
            ;;
        *.rb)
            # require 'foo' / require_relative 'foo'
            imports=$(grep -oE "(require|require_relative) ['\"][^'\"]+['\"]" "$filepath" 2>/dev/null | \
                sed "s/require_relative ['\"]//; s/require ['\"]//; s/['\"]//g" | head -30 | tr '\n' ',' | sed 's/,$//')
            ;;
        *.c|*.cpp|*.h|*.hpp)
            # #include "foo.h" / #include <foo>
            imports=$(grep -oE '#include [<"][^>"]+[>"]' "$filepath" 2>/dev/null | \
                sed 's/#include [<"]//; s/[>"]//;' | head -30 | tr '\n' ',' | sed 's/,$//')
            ;;
        *.php)
            # use Namespace\Class / require_once 'file'
            imports=$(grep -oE "(use [\w\\\\]+|require_once ['\"][^'\"]+['\"])" "$filepath" 2>/dev/null | \
                sed "s/use //; s/require_once ['\"]//; s/['\"]//g" | head -30 | tr '\n' ',' | sed 's/,$//')
            ;;
        *.swift)
            # import Module
            imports=$(grep -oE '^import \w+' "$filepath" 2>/dev/null | \
                sed 's/^import //' | head -30 | tr '\n' ',' | sed 's/,$//')
            ;;
    esac

    echo "${imports:-}"
}

# ══════════════════════════════════════════════════════════
# SECTION 6: Documentation extraction
# ══════════════════════════════════════════════════════════

_extract_docs() {
    local filepath="$1"
    local max_chars="${INDEX_SUMMARY_MAX_INPUT:-2000}"
    local docs=""

    case "$filepath" in
        *.py)
            # Extract module docstring (triple-quoted string at top) + class/function docstrings
            docs=$(perl -0777 -ne '
                # Module docstring
                if (/\A\s*(?:#[^\n]*\n)*\s*("""(.*?)"""|'"'"''"'"''"'"'(.*?)'"'"''"'"''"'"')/s) {
                    print $2 // $3; print "\n---\n";
                }
                # Function/class docstrings
                while (/(?:def|class)\s+(\w+).*?:\s*\n\s*"""(.*?)"""/gs) {
                    print "$1: $2\n";
                }
            ' "$filepath" 2>/dev/null | head -c "$max_chars")
            ;;
        *.js|*.ts|*.tsx|*.jsx)
            # Extract JSDoc comments: /** ... */
            docs=$(perl -0777 -ne '
                while (/\/\*\*\s*(.*?)\s*\*\//gs) {
                    my $c = $1;
                    $c =~ s/^\s*\*\s?//gm;
                    print "$c\n---\n";
                }
            ' "$filepath" 2>/dev/null | head -c "$max_chars")
            ;;
        *.rs)
            # Extract /// doc comments and //! module-level docs
            docs=$(grep -E '^\s*(///|//!)' "$filepath" 2>/dev/null | \
                sed 's/^\s*\/\/[\/!]\s*//' | head -c "$max_chars")
            ;;
        *.go)
            # Go doc comments: lines starting with // before func/type declarations
            docs=$(perl -0777 -ne '
                while (/((?:\/\/[^\n]*\n)+)\s*(?:func|type|var|const)/g) {
                    my $c = $1;
                    $c =~ s/\/\/\s?//g;
                    print "$c---\n";
                }
            ' "$filepath" 2>/dev/null | head -c "$max_chars")
            ;;
        *.java|*.kt|*.scala|*.cs)
            # Javadoc: /** ... */
            docs=$(perl -0777 -ne '
                while (/\/\*\*\s*(.*?)\s*\*\//gs) {
                    my $c = $1;
                    $c =~ s/^\s*\*\s?//gm;
                    print "$c\n---\n";
                }
            ' "$filepath" 2>/dev/null | head -c "$max_chars")
            ;;
        *.rb)
            # RDoc comments: lines starting with # before def/class
            docs=$(perl -0777 -ne '
                while (/((?:#[^\n]*\n)+)\s*(?:def|class|module)/g) {
                    my $c = $1;
                    $c =~ s/#\s?//g;
                    print "$c---\n";
                }
            ' "$filepath" 2>/dev/null | head -c "$max_chars")
            ;;
        *.sh)
            # Shell header comments
            docs=$(head -30 "$filepath" 2>/dev/null | grep '^#' | sed 's/^#\s*//' | head -c "$max_chars")
            ;;
        *)
            # Generic: grab leading comment block
            docs=$(head -20 "$filepath" 2>/dev/null | grep -E '^\s*(#|//|/\*|\*)' | \
                sed 's/^\s*[#/*]*\s*//' | head -c "$max_chars")
            ;;
    esac

    echo "${docs:-}"
}

# ══════════════════════════════════════════════════════════
# SECTION 7: Parallel worker for indexing a chunk of files
# ══════════════════════════════════════════════════════════

# Worker: process a chunk of files, write results to a temp file
# Called as a background subshell
_index_worker() {
    local chunk_file="$1"       # file containing list of file paths
    local output_file="$2"      # where to write JSON results
    local progress_file="$3"    # shared progress counter file
    local base_dir="$4"         # project root for relative paths

    local results="[]"

    while IFS= read -r filepath; do
        [[ -z "$filepath" ]] && continue

        # Security: validate path is within project
        local resolved
        resolved=$(_secure_path "$base_dir" "$filepath")
        if [[ -z "$resolved" ]]; then
            continue
        fi

        # Skip binary files
        if _is_binary "$filepath"; then
            continue
        fi

        # Skip oversized files
        local fsize
        fsize=$(wc -c < "$filepath" 2>/dev/null | tr -d ' ')
        if (( fsize > INDEX_MAX_FILE_SIZE )); then
            continue
        fi

        local rel_path="${filepath#$base_dir/}"
        local lines
        lines=$(wc -l < "$filepath" 2>/dev/null | tr -d ' ')
        local mtime
        mtime=$(stat -f '%m' "$filepath" 2>/dev/null || stat -c '%Y' "$filepath" 2>/dev/null)

        # Extract symbols
        local symbols
        symbols=$(_extract_symbols "$filepath")

        # Extract imports
        local imports
        imports=$(_extract_imports "$filepath")

        # Extract documentation
        local docs
        docs=$(_extract_docs "$filepath")
        # Sanitize docs before storing
        docs=$(_sanitize_for_llm "$docs")

        # Build JSON entry for this file
        results=$(echo "$results" | jq \
            --arg path "$rel_path" \
            --arg symbols "${symbols:-}" \
            --arg imports "${imports:-}" \
            --arg docs "${docs:-}" \
            --argjson lines "${lines:-0}" \
            --argjson size "${fsize:-0}" \
            --argjson mtime "${mtime:-0}" \
            '. + [{
                "path": $path,
                "symbols": ($symbols | split(",") | map(select(. != ""))),
                "imports": ($imports | split(",") | map(select(. != ""))),
                "docs": $docs,
                "lines": $lines,
                "size": $size,
                "mtime": $mtime,
                "summary": ""
            }]')

        # Update shared progress counter
        echo "1" >> "$progress_file"

    done < "$chunk_file"

    # Write results
    echo "$results" > "$output_file"
}

# ══════════════════════════════════════════════════════════
# SECTION 8: LLM summary generation
# ══════════════════════════════════════════════════════════

_generate_summary() {
    local filepath="$1"
    local symbols="$2"
    local docs="$3"
    local rel_path="$4"

    # Build a compact prompt using extracted docs + symbol list
    local code_snippet=""
    if [[ -n "$docs" ]]; then
        code_snippet="Documentation:\n${docs}\n\n"
    fi
    if [[ -n "$symbols" ]]; then
        code_snippet="${code_snippet}Symbols defined: ${symbols}\n"
    fi

    # If no docs or symbols, grab first N lines of the file
    if [[ -z "$docs" && -z "$symbols" ]]; then
        code_snippet=$(head -c "$INDEX_SUMMARY_MAX_INPUT" "$filepath" 2>/dev/null)
        code_snippet=$(_sanitize_for_llm "$code_snippet")
    fi

    local prompt="Summarize this source file in ONE sentence (max 120 chars). State what it does, not what it contains. File: ${rel_path}\n\n${code_snippet}"

    local payload
    payload=$(jq -n \
        --arg prompt "$prompt" \
        --arg model_name "$API_MODEL" \
        '{
            "model": $model_name,
            "messages": [{"role": "user", "content": $prompt}],
            "max_tokens": 60,
            "temperature": 0.1
        }')

    local response
    response=$(curl -s \
        -X POST "${API_URL}/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        --max-time 30 2>/dev/null)

    local summary
    summary=$(echo "$response" | jq -r '.choices[0].message.content // ""' 2>/dev/null)

    # Clean up the summary
    summary=$(echo "$summary" | head -1 | sed 's/^[[:space:]]*//' | head -c 200)

    echo "$summary"
}

# Worker: generate LLM summaries for a batch of files
_summary_worker() {
    local batch_file="$1"       # JSON array of file entries to summarize
    local output_file="$2"      # where to write results
    local progress_file="$3"    # shared progress counter
    local base_dir="$4"

    local results="[]"

    local count
    count=$(jq 'length' "$batch_file" 2>/dev/null)

    for (( i=0; i<count; i++ )); do
        local entry
        entry=$(jq -c ".[$i]" "$batch_file")

        local rel_path symbols_str docs
        rel_path=$(echo "$entry" | jq -r '.path')
        symbols_str=$(echo "$entry" | jq -r '.symbols | join(", ")')
        docs=$(echo "$entry" | jq -r '.docs // ""')

        local filepath="$base_dir/$rel_path"
        if [[ ! -f "$filepath" ]]; then
            results=$(echo "$results" | jq --arg path "$rel_path" '. + [{"path": $path, "summary": ""}]')
            echo "1" >> "$progress_file"
            continue
        fi

        local summary
        summary=$(_generate_summary "$filepath" "$symbols_str" "$docs" "$rel_path")

        results=$(echo "$results" | jq \
            --arg path "$rel_path" \
            --arg summary "$summary" \
            '. + [{"path": $path, "summary": $summary}]')

        echo "1" >> "$progress_file"
    done

    echo "$results" > "$output_file"
}

# ══════════════════════════════════════════════════════════
# SECTION 9: Dependency graph builder
# ══════════════════════════════════════════════════════════

_build_dependency_graph() {
    local index_file="$1"
    local deps_file="$2"

    # Build adjacency list: for each file, list files it imports
    # We resolve import paths to actual files where possible
    #
    # Import resolution strategy:
    #   1. Exact path suffix match: import "../../utils/auth" matches "src/utils/auth.ts"
    #   2. Basename match: import "auth" matches files named "auth.ts", "auth.py", etc.
    # We skip common stdlib/external imports (< 4 chars, known stdlib names)
    jq '
        # Known stdlib/external imports to skip (would cause massive false positives)
        ["os", "sys", "io", "re", "fs", "net", "url", "tls", "vm", "dns",
         "http", "path", "util", "zlib", "time", "json", "math", "struct",
         "typing", "abc", "ast", "csv", "ssl", "fmt", "log", "strings",
         "sync", "sort", "flag", "bytes", "errors", "context",
         "react", "vue", "express", "lodash", "axios", "chalk",
         "assert", "buffer", "child_process", "cluster", "crypto",
         "dgram", "domain", "events", "freelist", "module",
         "process", "punycode", "querystring", "readline",
         "repl", "stream", "string_decoder", "timers", "tty",
         "v8", "wasi", "worker_threads", "console",
         "argparse", "collections", "functools", "itertools",
         "datetime", "hashlib", "inspect", "logging", "platform",
         "random", "signal", "socket", "subprocess", "tempfile",
         "threading", "traceback", "unittest", "warnings",
         "stdio.h", "stdlib.h", "string.h", "stdint.h", "stdbool.h",
         "math.h", "time.h", "errno.h", "assert.h", "ctype.h",
         "float.h", "limits.h", "signal.h", "stdarg.h", "stddef.h"
        ] as $skip_imports |

        # Build a lookup of all file paths
        [.[].path] as $all_paths |

        # For each file, try to match its imports to actual files
        [.[] | . as $file_entry | {
            file: .path,
            imports_raw: .imports,
            depends_on: [
                .imports[] |
                . as $imp |
                # Skip known stdlib/external imports
                select(($skip_imports | index($imp)) == null) |
                # Skip very short imports (1-2 chars) — almost always stdlib
                select(($imp | length) >= 3) |
                # Normalize: strip leading ./ or ../ prefixes, strip quotes
                ($imp | gsub("^[\"'\'']+|[\"'\'']+$"; "") | gsub("^\\.+/+"; "")) as $norm_imp |
                # Derive the basename without extension for matching
                ($norm_imp | split("/") | last | split(".") | first) as $imp_basename |
                select(($imp_basename | length) >= 3) |
                $all_paths[] |
                select(
                    # Match 1: path ends with the import (e.g., import "utils/auth" matches "src/utils/auth.ts")
                    (. | test("(^|/)" + ($norm_imp | gsub("[.]"; "\\.")) + "(\\.[^/]+)?$"; "i")) or
                    # Match 2: basename match — file stem equals import basename
                    ((split("/") | last | split(".") | first) == $imp_basename)
                ) |
                # Exclude self-references
                select(. != $file_entry.path)
            ] | unique,
            depended_by: []
        }] |

        # Build reverse dependencies
        . as $entries |
        [.[] | . as $entry |
            .depended_by = [
                $entries[] |
                select(.depends_on | index($entry.file)) |
                .file
            ]
        ]
    ' "$index_file" > "$deps_file" 2>/dev/null
}

# ══════════════════════════════════════════════════════════
# SECTION 10: Progress display
# ══════════════════════════════════════════════════════════

_progress_monitor() {
    local progress_file="$1"
    local total="$2"
    local phase="$3"

    local last_count=0
    local last_reported_pct=-1

    # In headless mode, use newlines (for Node streaming) and report every 5%
    local is_headless="${LANA_HEADLESS:-false}"

    while true; do
        local count
        count=$(wc -l < "$progress_file" 2>/dev/null | tr -d ' ')
        count=${count:-0}

        if (( count != last_count )); then
            local pct=$(( count * 100 / total ))

            if [[ "$is_headless" == "true" ]]; then
                # In headless mode: emit a line every 5% (or every 10 files for small counts)
                local report_interval=5
                (( total < 50 )) && report_interval=10
                if (( pct >= last_reported_pct + report_interval || count >= total )); then
                    printf "%s %d/%d (%d%%)\n" "$phase" "$count" "$total" "$pct"
                    last_reported_pct=$pct
                fi
            else
                # Interactive mode: in-place progress bar
                local bar_filled=$(( pct / 5 ))
                local bar_empty=$(( 20 - bar_filled ))
                local bar=""
                for (( b=0; b<bar_filled; b++ )); do bar="${bar}█"; done
                for (( b=0; b<bar_empty; b++ )); do bar="${bar}░"; done
                printf "\r${C_CYAN}  %s ${C_RESET}${C_WHITE}%s${C_RESET} ${C_DIM}%d/%d (%d%%)${C_RESET}" \
                    "$phase" "$bar" "$count" "$total" "$pct"
            fi
            last_count=$count
        fi

        if (( count >= total )); then
            if [[ "$is_headless" != "true" ]]; then
                printf "\r${C_CYAN}  %s ${C_RESET}${C_GREEN}%s${C_RESET} ${C_DIM}%d/%d (100%%)${C_RESET}\n" \
                    "$phase" "████████████████████" "$total" "$total"
            fi
            break
        fi

        sleep 0.3
    done
}

# ══════════════════════════════════════════════════════════
# SECTION 11: Main index orchestrator
# ══════════════════════════════════════════════════════════

project_index() {
    local dir="${1:-$WORK_DIR}"
    # Store index in LANA_INDEX_ROOT (project root) even when indexing a subdirectory
    local index_root="${LANA_INDEX_ROOT:-$dir}"
    local index_dir="$index_root/$INDEX_DIR_NAME"
    local index_file="$index_dir/index.json"
    local deps_file="$index_dir/deps.json"
    local meta_file="$index_dir/meta.json"
    local work_dir="$SESSION_DIR/indexer_$$"

    mkdir -p "$index_dir" "$work_dir"

    # ── Phase 0: Scan & count ──────────────────────────
    printf "\n${C_BOLD}${C_CYAN}  Indexing project${C_RESET} ${C_DIM}%s${C_RESET}\n\n" "$dir"

    ui_info "Phase 1/5: Scanning files..."
    local all_files_list="$work_dir/all_files.txt"
    _index_find_files "$dir" > "$all_files_list"

    local total_files
    total_files=$(wc -l < "$all_files_list" | tr -d ' ')

    if (( total_files == 0 )); then
        ui_warn "No indexable source files found."
        return 1
    fi

    local total_dirs
    total_dirs=$(cat "$all_files_list" | xargs -I{} dirname {} | sort -u | wc -l | tr -d ' ')

    printf "  ${C_DIM}Found ${C_WHITE}%d${C_DIM} files across ${C_WHITE}%d${C_DIM} directories${C_RESET}\n" \
        "$total_files" "$total_dirs"

    # ── Phase 1: Check for incremental updates ─────────
    local files_to_process="$work_dir/files_to_process.txt"
    local cached_entries="$work_dir/cached.json"
    echo '[]' > "$cached_entries"

    if [[ -f "$index_file" ]]; then
        ui_info "Phase 2/5: Checking for changes (incremental)..."
        local changed=0 cached=0

        while IFS= read -r filepath; do
            local rel_path="${filepath#$dir/}"
            local current_mtime
            current_mtime=$(stat -f '%m' "$filepath" 2>/dev/null || stat -c '%Y' "$filepath" 2>/dev/null)

            # Look up existing entry
            local existing_mtime
            existing_mtime=$(jq -r --arg p "$rel_path" '.[] | select(.path == $p) | .mtime' "$index_file" 2>/dev/null) || true

            if [[ -n "$existing_mtime" && "$existing_mtime" != "null" && "$existing_mtime" == "$current_mtime" ]]; then
                # File unchanged — preserve existing entry
                jq --arg p "$rel_path" '[.[] | select(.path == $p)]' "$index_file" >> "$work_dir/cached_append.jsonl"
                cached=$((cached + 1))
            else
                echo "$filepath" >> "$files_to_process"
                changed=$((changed + 1))
            fi
        done < "$all_files_list"

        # Merge cached entries
        if [[ -f "$work_dir/cached_append.jsonl" ]]; then
            cached_entries="$work_dir/cached_merged.json"
            jq -s 'add // []' "$work_dir/cached_append.jsonl" > "$cached_entries" 2>/dev/null
        fi

        printf "  ${C_DIM}Changed: ${C_WHITE}%d${C_DIM} | Cached: ${C_WHITE}%d${C_RESET}\n" "$changed" "$cached"

        if (( changed == 0 )); then
            ui_success "All files up to date. Skipping to dependency graph."
            _build_dependency_graph "$index_file" "$deps_file"
            ui_success "Dependency graph updated."
            return 0
        fi
    else
        # Full index — process all files
        cp "$all_files_list" "$files_to_process"
        printf "  ${C_DIM}Full index (no existing cache)${C_RESET}\n"
    fi

    local process_count
    process_count=$(wc -l < "$files_to_process" 2>/dev/null | tr -d ' ')
    process_count=${process_count:-0}

    # ── Phase 2: Parallel symbol + import + doc extraction ──
    printf "\n"
    ui_info "Phase 3/5: Extracting symbols, imports & docs ($INDEX_WORKERS workers)..."

    # Split files into chunks for parallel processing
    local chunk_size=$(( (process_count + INDEX_WORKERS - 1) / INDEX_WORKERS ))
    (( chunk_size < 1 )) && chunk_size=1

    split -l "$chunk_size" "$files_to_process" "$work_dir/chunk_"

    local progress_file="$work_dir/progress_extract.log"
    : > "$progress_file"

    # Start progress monitor in background
    _progress_monitor "$progress_file" "$process_count" "extracting" &
    local monitor_pid=$!
    disown "$monitor_pid" 2>/dev/null

    # Launch workers
    local worker_pids=()
    local worker_idx=0
    for chunk in "$work_dir"/chunk_*; do
        local worker_out="$work_dir/worker_${worker_idx}.json"
        _index_worker "$chunk" "$worker_out" "$progress_file" "$dir" &
        worker_pids+=($!)
        worker_idx=$((worker_idx + 1))
    done

    # Wait for all workers
    for pid in "${worker_pids[@]}"; do
        wait "$pid" 2>/dev/null
    done

    # Wait for progress monitor to finish
    wait "$monitor_pid" 2>/dev/null

    # Merge worker results + cached entries
    ui_info "Merging results..."
    local merged="$work_dir/merged.json"
    local all_jsons=("$cached_entries")
    for (( i=0; i<worker_idx; i++ )); do
        local wf="$work_dir/worker_${i}.json"
        [[ -f "$wf" ]] && all_jsons+=("$wf")
    done
    jq -s 'add | sort_by(.path)' "${all_jsons[@]}" > "$merged" 2>/dev/null

    # ── Phase 4 + 5: Dependency graph + LLM summaries (parallel) ──
    # These are independent — deps reads symbols/imports, summaries reads file metadata.
    # Running them in parallel saves the time Phase 4 takes.
    printf "\n"
    ui_info "Phase 4/5: Building dependency graph..."

    # Start dependency graph in background
    _build_dependency_graph "$merged" "$deps_file" &
    local deps_pid=$!

    # Meanwhile, start LLM summaries
    local needs_summary="$work_dir/needs_summary.json"
    jq '[.[] | select(.summary == "" or .summary == null)]' "$merged" > "$needs_summary" 2>/dev/null
    local summary_count
    summary_count=$(jq 'length' "$needs_summary" 2>/dev/null)
    summary_count=${summary_count:-0}

    if (( summary_count > 0 )); then
        ui_info "Phase 5/5: Generating LLM summaries ($summary_count files)..."

        # Check if server is running
        if ! api_health_check; then
            ui_warn "llama-server not running. Skipping LLM summaries."
            ui_warn "Start the agent normally first, then re-run \\\\index."
        else
            local progress_file_sum="$work_dir/progress_summary.log"
            : > "$progress_file_sum"

            # Start progress monitor
            _progress_monitor "$progress_file_sum" "$summary_count" "summarizing" &
            local sum_monitor_pid=$!
            disown "$sum_monitor_pid" 2>/dev/null

            # LLM calls are sequential — server handles one request at a time
            local sum_out="$work_dir/summary_results.json"
            _summary_worker "$needs_summary" "$sum_out" "$progress_file_sum" "$dir"

            wait "$sum_monitor_pid" 2>/dev/null

            # Merge summaries into the main index
            if [[ -f "$sum_out" ]]; then
                local final_merged="$work_dir/final.json"
                jq -s '
                    .[0] as $index | .[1] as $sums |
                    [$index[] | . as $entry |
                        ($sums[] | select(.path == $entry.path) | .summary) as $s |
                        if $s then .summary = $s else . end
                    ]
                ' "$merged" "$sum_out" > "$final_merged" 2>/dev/null
                merged="$final_merged"
            fi
        fi
    else
        ui_info "Phase 5/5: All files already have summaries. Skipping."
    fi

    # Wait for dependency graph to finish (likely already done by now)
    wait "$deps_pid" 2>/dev/null
    local dep_count
    dep_count=$(jq '[.[].depends_on | length] | add // 0' "$deps_file" 2>/dev/null)
    printf "  ${C_DIM}Mapped ${C_WHITE}%d${C_DIM} dependency links${C_RESET}\n" "$dep_count"

    # ── Write final index ──────────────────────────────
    cp "$merged" "$index_file"

    # Write metadata
    local final_count
    final_count=$(jq 'length' "$index_file" 2>/dev/null)
    jq -n \
        --argjson file_count "${final_count:-0}" \
        --argjson dir_count "${total_dirs:-0}" \
        --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg project_dir "$dir" \
        '{
            file_count: $file_count,
            dir_count: $dir_count,
            indexed_at: $timestamp,
            project_dir: $project_dir
        }' > "$meta_file"

    # Cleanup
    rm -rf "$work_dir"

    # ── Summary ────────────────────────────────────────
    printf "\n${C_GREEN}${C_BOLD}  Index complete${C_RESET}\n"
    printf "  ${C_DIM}Files:        ${C_WHITE}%d${C_RESET}\n" "$final_count"
    printf "  ${C_DIM}Directories:  ${C_WHITE}%d${C_RESET}\n" "$total_dirs"
    printf "  ${C_DIM}Dependencies: ${C_WHITE}%d${C_RESET}\n" "$dep_count"
    printf "  ${C_DIM}Index:        ${C_WHITE}%s${C_RESET}\n" "$index_file"
    printf "  ${C_DIM}Deps graph:   ${C_WHITE}%s${C_RESET}\n" "$deps_file"
    printf "\n"
}

# ══════════════════════════════════════════════════════════
# SECTION 12: Index search (enhanced with summaries + deps)
# ══════════════════════════════════════════════════════════

project_index_search() {
    local dir="${1:-$WORK_DIR}"
    local query="$2"
    local index_file="$dir/$INDEX_DIR_NAME/index.json"
    local deps_file="$dir/$INDEX_DIR_NAME/deps.json"

    if [[ ! -f "$index_file" ]]; then
        echo "No index found. Run \\index first."
        return 1
    fi

    # Search across file paths, symbols, AND summaries
    local results
    results=$(jq --arg q "$query" '[
        .[] | select(
            (.path | test($q; "i")) or
            (.symbols | any(test($q; "i"))) or
            (.summary | test($q; "i"))
        )
    ] | .[:20]' "$index_file" 2>/dev/null)

    local count
    count=$(echo "$results" | jq 'length')

    if (( count == 0 )); then
        echo "No matches found for: $query"
        return 0
    fi

    # Format results
    echo "$results" | jq -r '.[] |
        "\(.path) [\(.lines)L]" +
        (if (.symbols | length) > 0 then "\n  symbols: \(.symbols | join(", "))" else "" end) +
        (if .summary != "" then "\n  summary: \(.summary)" else "" end)
    '

    # Show related files from dependency graph if available
    if [[ -f "$deps_file" ]]; then
        local first_match
        first_match=$(echo "$results" | jq -r '.[0].path // empty')
        if [[ -n "$first_match" ]]; then
            local related
            related=$(jq --arg f "$first_match" '
                .[] | select(.file == $f) |
                "  depends on: \(.depends_on | join(", "))\n  depended by: \(.depended_by | join(", "))"
            ' "$deps_file" -r 2>/dev/null)
            if [[ -n "$related" && "$related" == *": "* ]]; then
                echo ""
                echo "  relationships for $first_match:"
                echo "$related"
            fi
        fi
    fi
}

# ══════════════════════════════════════════════════════════
# SECTION 13: @file reference expansion (unchanged)
# ══════════════════════════════════════════════════════════

expand_file_refs() {
    local input="$1"
    local result="$input"

    # Handle bare @ — launch interactive file picker
    # Matches: starts/ends with @, or has @ surrounded by spaces
    if [[ "$result" =~ (^|[[:space:]])@($|[[:space:]]) ]]; then
        local picked_file
        picked_file=$(ui_file_picker "$WORK_DIR") || true
        if [[ -n "$picked_file" && -f "$picked_file" ]]; then
            local _content _size _rel
            _size=$(wc -c < "$picked_file" 2>/dev/null)
            _rel="${picked_file#$WORK_DIR/}"
            if (( _size > FILE_SIZE_LIMIT )); then
                _content="[File too large: ${_size} bytes. Use read_file tool instead.]"
            else
                _content=$(cat "$picked_file" 2>/dev/null)
            fi
            local _replacement
            _replacement=$(printf '\n<file path="%s">\n%s\n</file>\n' "$_rel" "$_content")
            # Replace the bare @ with the file content
            result="${result/@/$_replacement}"
            ui_dim "  attached: $_rel"
        else
            # Remove the bare @ if cancelled
            result="${result/@/}"
        fi
    fi

    while [[ "$result" =~ @\"([^\"]+)\" ]] || [[ "$result" =~ @([^[:space:]@]+) ]]; do
        local match="${BASH_REMATCH[0]}"
        local filepath="${BASH_REMATCH[1]}"

        [[ "$filepath" != /* ]] && filepath="$WORK_DIR/$filepath"

        if [[ -f "$filepath" ]]; then
            local content
            local size
            size=$(wc -c < "$filepath" 2>/dev/null)

            if (( size > FILE_SIZE_LIMIT )); then
                content="[File too large: ${size} bytes. Use read_file tool instead.]"
            else
                content=$(cat "$filepath" 2>/dev/null)
            fi

            local rel_path="${filepath#$WORK_DIR/}"
            local replacement
            replacement=$(printf '\n<file path="%s">\n%s\n</file>\n' "$rel_path" "$content")

            result="${result//$match/$replacement}"
            ui_dim "  expanded: $rel_path"
        else
            ui_warn "File not found: $filepath"
            break
        fi

        [[ "$result" == "$input" ]] && break
        input="$result"
    done

    echo "$result"
}

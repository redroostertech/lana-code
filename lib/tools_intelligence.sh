#!/usr/bin/env bash
# Code intelligence tools: web_fetch, tree_parse, lsp_query
# Bash 3.2 compatible — NO associative arrays, NO read -a, NO readarray

# ── Intelligence tool definitions JSON ───────────────

get_intelligence_tool_definitions() {
    cat << 'INTEL_TOOLS_EOF'
[
  {
    "type": "function",
    "function": {
      "name": "web_fetch",
      "description": "Fetch a URL and extract its text content. Use this to look up documentation, API references, error messages, or any web resource. Returns cleaned text content (HTML tags stripped). Great for checking docs when unsure about an API, looking up error messages, or reading READMEs from GitHub.",
      "parameters": {
        "type": "object",
        "properties": {
          "url": {
            "type": "string",
            "description": "The URL to fetch"
          },
          "selector": {
            "type": "string",
            "description": "Optional: CSS-like content selector - 'main' for main content, 'code' for code blocks, 'pre' for preformatted text. Helps filter noise from web pages."
          },
          "max_length": {
            "type": "integer",
            "description": "Maximum characters to return (default 8000, to save context window)"
          }
        },
        "required": ["url"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "tree_parse",
      "description": "Extract code structure from source files — function signatures, class definitions, imports, exports, and type definitions. Returns a concise outline without implementation details. Much faster than reading entire files when you need to understand a file's API surface.",
      "parameters": {
        "type": "object",
        "properties": {
          "path": {
            "type": "string",
            "description": "File or directory to parse. For directories, parses all recognized source files."
          },
          "filter": {
            "type": "string",
            "enum": ["all", "functions", "classes", "imports", "exports", "types"],
            "description": "What to extract (default 'all')"
          },
          "depth": {
            "type": "integer",
            "description": "For directories, max depth to recurse (default 2)"
          }
        },
        "required": ["path"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "lsp_query",
      "description": "Query a Language Server for precise code intelligence: go-to-definition, find references, diagnostics (type errors), and hover info. Requires an LSP server to be installed for the language. Falls back to regex-based search if no LSP is available.",
      "parameters": {
        "type": "object",
        "properties": {
          "action": {
            "type": "string",
            "enum": ["diagnostics", "definition", "references", "hover", "check"],
            "description": "LSP action: 'diagnostics' for errors/warnings, 'definition' for go-to-def, 'references' for find-all-refs, 'hover' for type info, 'check' to see which LSP servers are available"
          },
          "file": {
            "type": "string",
            "description": "File path (required for all actions except 'check')"
          },
          "line": {
            "type": "integer",
            "description": "Line number (1-indexed, required for definition/references/hover)"
          },
          "column": {
            "type": "integer",
            "description": "Column number (1-indexed, required for definition/references/hover)"
          }
        },
        "required": ["action"]
      }
    }
  }
]
INTEL_TOOLS_EOF
}

# ══════════════════════════════════════════════════════
# Tool 1: web_fetch — fetch and extract text from URLs
# ══════════════════════════════════════════════════════

tool_web_fetch() {
    local args="$1"
    local url selector max_length
    url=$(echo "$args" | jq -r '.url // empty')
    selector=$(echo "$args" | jq -r '.selector // empty')
    max_length=$(echo "$args" | jq -r '.max_length // empty')

    # Default max_length
    if [[ -z "$max_length" || "$max_length" == "null" ]]; then
        max_length=8000
    fi

    # Validate URL
    if [[ -z "$url" ]]; then
        echo "Error: url is required"
        return 1
    fi

    if [[ "$url" != http://* && "$url" != https://* ]]; then
        echo "Error: url must start with http:// or https://"
        return 1
    fi

    # Check curl availability
    if ! command -v curl >/dev/null 2>&1; then
        echo "Error: curl is not available"
        return 1
    fi

    ui_tool_call "web_fetch" "$url"

    # Fetch with curl — capture HTTP status code separately
    local tmp_body="$SESSION_DIR/web_fetch_body_$$"
    local tmp_headers="$SESSION_DIR/web_fetch_headers_$$"
    local http_code

    http_code=$(curl -sL -m 15 \
        -A "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36" \
        --max-filesize 2097152 \
        -D "$tmp_headers" \
        -o "$tmp_body" \
        -w "%{http_code}" \
        "$url" 2>/dev/null) || true

    # Handle curl failure
    if [[ -z "$http_code" || "$http_code" == "000" ]]; then
        rm -f "$tmp_body" "$tmp_headers"
        echo "Error: Request timed out or failed to connect"
        return 1
    fi

    if [[ "$http_code" != "200" ]]; then
        rm -f "$tmp_body" "$tmp_headers"
        echo "Error: HTTP $http_code"
        return 1
    fi

    # Check content type — only process text content
    local content_type=""
    if [[ -f "$tmp_headers" ]]; then
        content_type=$(grep -i '^content-type:' "$tmp_headers" | tail -1 | sed 's/^[^:]*: *//; s/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]')
    fi

    if [[ -n "$content_type" && "$content_type" != *"text/"* && "$content_type" != *"json"* && "$content_type" != *"xml"* && "$content_type" != *"javascript"* ]]; then
        rm -f "$tmp_body" "$tmp_headers"
        echo "Error: Response is not text (Content-Type: $content_type)"
        return 1
    fi

    if [[ ! -s "$tmp_body" ]]; then
        rm -f "$tmp_body" "$tmp_headers"
        echo "Error: Empty response body"
        return 1
    fi

    # Process HTML to text
    local raw_content
    raw_content=$(cat "$tmp_body")
    rm -f "$tmp_body" "$tmp_headers"

    local text_content

    # Apply selector-based extraction BEFORE stripping tags
    if [[ -n "$selector" && "$selector" != "null" ]]; then
        text_content=$(_web_fetch_select "$raw_content" "$selector")
    else
        text_content="$raw_content"
    fi

    # Strip HTML to text
    text_content=$(_web_fetch_html_to_text "$text_content")

    # Measure total length before truncation
    local total_length=${#text_content}

    # Truncate if needed
    local truncated_note=""
    if (( total_length > max_length )); then
        text_content=$(printf '%s' "$text_content" | head -c "$max_length")
        truncated_note=" (truncated from $total_length)"
    fi

    local display_length=${#text_content}

    # Output
    printf 'URL: %s\n' "$url"
    [[ -n "$content_type" ]] && printf 'Content-Type: %s\n' "$content_type"
    printf 'Length: %s chars%s\n' "$display_length" "$truncated_note"
    printf -- '---\n'
    printf '%s\n' "$text_content"
}

# Extract content by selector (basic — no DOM parsing)
_web_fetch_select() {
    local html="$1"
    local selector="$2"
    local extracted=""

    case "$selector" in
        main)
            # Try <main>, then <article>, then <div class="content"...>
            extracted=$(printf '%s' "$html" | perl -0777 -ne '
                if (/<main[^>]*>(.*?)<\/main>/si) { print $1; }
                elsif (/<article[^>]*>(.*?)<\/article>/si) { print $1; }
                elsif (/<div[^>]*class="[^"]*content[^"]*"[^>]*>(.*?)<\/div>/si) { print $1; }
                else { print $_; }
            ' 2>/dev/null) || true
            ;;
        code)
            # Extract <code> and <pre> blocks
            extracted=$(printf '%s' "$html" | perl -0777 -ne '
                my @blocks;
                while (/<code[^>]*>(.*?)<\/code>/gsi) { push @blocks, $1; }
                while (/<pre[^>]*>(.*?)<\/pre>/gsi) { push @blocks, $1; }
                print join("\n---\n", @blocks) if @blocks;
            ' 2>/dev/null) || true
            ;;
        pre)
            # Extract <pre> blocks only
            extracted=$(printf '%s' "$html" | perl -0777 -ne '
                my @blocks;
                while (/<pre[^>]*>(.*?)<\/pre>/gsi) { push @blocks, $1; }
                print join("\n---\n", @blocks) if @blocks;
            ' 2>/dev/null) || true
            ;;
    esac

    # Fall back to full content if extraction found nothing
    if [[ -z "$extracted" ]]; then
        printf '%s' "$html"
    else
        printf '%s' "$extracted"
    fi
}

# Convert HTML to readable plain text
_web_fetch_html_to_text() {
    local html="$1"

    printf '%s' "$html" | \
        perl -0777 -pe '
            # Remove script and style blocks entirely
            s/<script[^>]*>.*?<\/script>//gsi;
            s/<style[^>]*>.*?<\/style>//gsi;
            # Remove HTML comments
            s/<!--.*?-->//gs;
            # Replace <br> and <p> and block elements with newlines
            s/<br\s*\/?>/\n/gi;
            s/<\/p>/\n\n/gi;
            s/<\/div>/\n/gi;
            s/<\/li>/\n/gi;
            s/<\/h[1-6]>/\n\n/gi;
            s/<\/tr>/\n/gi;
        ' 2>/dev/null | \
        sed 's/<[^>]*>//g' | \
        sed 's/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g; s/&quot;/"/g; s/&#39;/'"'"'/g; s/&nbsp;/ /g; s/&#x27;/'"'"'/g; s/&#x2F;/\//g; s/&apos;/'"'"'/g' | \
        sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | \
        cat -s
}


# ══════════════════════════════════════════════════════
# Tool 2: tree_parse — regex-based code structure extraction
# ══════════════════════════════════════════════════════

tool_tree_parse() {
    local args="$1"
    local path filter depth
    path=$(echo "$args" | jq -r '.path // empty')
    filter=$(echo "$args" | jq -r '.filter // empty')
    depth=$(echo "$args" | jq -r '.depth // empty')

    if [[ -z "$path" ]]; then
        echo "Error: path is required"
        return 1
    fi

    # Defaults
    [[ -z "$filter" || "$filter" == "null" ]] && filter="all"
    [[ -z "$depth" || "$depth" == "null" ]] && depth=2

    # Resolve relative paths
    [[ "$path" != /* ]] && path="$WORK_DIR/$path"

    if [[ -f "$path" ]]; then
        # Single file
        _tree_parse_file "$path" "$filter"
    elif [[ -d "$path" ]]; then
        # Directory — find and parse source files
        _tree_parse_directory "$path" "$filter" "$depth"
    else
        echo "Error: path not found: $path"
        return 1
    fi
}

# Detect language from file extension
_tree_detect_lang() {
    local file="$1"
    local ext="${file##*.}"
    ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')

    case "$ext" in
        py)                     echo "Python" ;;
        js|jsx)                 echo "JavaScript" ;;
        ts|tsx)                 echo "TypeScript" ;;
        swift)                  echo "Swift" ;;
        rs)                     echo "Rust" ;;
        go)                     echo "Go" ;;
        java)                   echo "Java" ;;
        kt|kts)                 echo "Kotlin" ;;
        rb)                     echo "Ruby" ;;
        c|h)                    echo "C" ;;
        cpp|hpp|cc|cxx|hxx)     echo "C++" ;;
        php)                    echo "PHP" ;;
        cs)                     echo "C#" ;;
        sh|bash|zsh)            echo "Shell" ;;
        lua)                    echo "Lua" ;;
        ex|exs)                 echo "Elixir" ;;
        hs)                     echo "Haskell" ;;
        scala)                  echo "Scala" ;;
        *)                      echo "" ;;
    esac
}

# Parse a single file — extract structure based on language
_tree_parse_file() {
    local file="$1"
    local filter="$2"

    if [[ ! -f "$file" ]]; then
        echo "Error: file not found: $file"
        return 1
    fi

    local lang
    lang=$(_tree_detect_lang "$file")

    if [[ -z "$lang" ]]; then
        echo "  (unsupported file type: ${file##*.})"
        return 0
    fi

    local line_count
    line_count=$(wc -l < "$file" | tr -d ' ')

    # Relativize path for display
    local display_path="$file"
    if [[ "$file" == "$WORK_DIR/"* ]]; then
        display_path="${file#$WORK_DIR/}"
    fi

    printf '%s (%s, %s lines):\n' "$display_path" "$lang" "$line_count"

    # Extract based on language
    case "$lang" in
        Python)         _tree_extract_python "$file" "$filter" ;;
        JavaScript|TypeScript)
                        _tree_extract_js_ts "$file" "$filter" ;;
        Swift)          _tree_extract_swift "$file" "$filter" ;;
        Rust)           _tree_extract_rust "$file" "$filter" ;;
        Go)             _tree_extract_go "$file" "$filter" ;;
        Java|Kotlin|Scala)
                        _tree_extract_java "$file" "$filter" ;;
        Ruby)           _tree_extract_ruby "$file" "$filter" ;;
        C|"C++")        _tree_extract_c_cpp "$file" "$filter" ;;
        C\#)            _tree_extract_java "$file" "$filter" ;;
        PHP)            _tree_extract_php "$file" "$filter" ;;
        Shell)          _tree_extract_shell "$file" "$filter" ;;
        *)
            echo "  (no extraction patterns for $lang)"
            ;;
    esac
    printf '\n'
}

# Parse a directory recursively
_tree_parse_directory() {
    local dir="$1"
    local filter="$2"
    local depth="$3"

    # Source file extensions to look for
    local extensions="py js jsx ts tsx swift rs go java kt rb c h cpp hpp cc cxx php cs sh lua ex exs hs scala"

    local file_count=0
    local max_files=50

    # Build find -name arguments for all extensions
    local find_cmd="find \"$dir\" -maxdepth $depth -type f"
    find_cmd="$find_cmd \\( -false"
    for ext in $extensions; do
        find_cmd="$find_cmd -o -name \"*.$ext\""
    done
    find_cmd="$find_cmd \\)"
    find_cmd="$find_cmd -not -path '*/.git/*'"
    find_cmd="$find_cmd -not -path '*/node_modules/*'"
    find_cmd="$find_cmd -not -path '*/__pycache__/*'"
    find_cmd="$find_cmd -not -path '*/.venv/*'"
    find_cmd="$find_cmd -not -path '*/venv/*'"
    find_cmd="$find_cmd -not -path '*/vendor/*'"
    find_cmd="$find_cmd -not -path '*/build/*'"
    find_cmd="$find_cmd -not -path '*/dist/*'"
    find_cmd="$find_cmd -not -path '*/.cache/*'"
    find_cmd="$find_cmd -not -path '*/target/*'"

    local found_file
    while IFS= read -r found_file; do
        [[ -z "$found_file" ]] && continue
        file_count=$((file_count + 1))
        if (( file_count > max_files )); then
            printf '... (showing first %s files, %s+ found)\n' "$max_files" "$file_count"
            break
        fi
        _tree_parse_file "$found_file" "$filter"
    done < <(eval "$find_cmd" 2>/dev/null | sort)

    if (( file_count == 0 )); then
        echo "No recognized source files found in: $dir"
    fi
}

# ── Per-language extraction functions ─────────────────
# Each function greps for patterns and groups output by category.
# Uses grep -n to get line numbers.

# Helper: print a category section if there are matches
_tree_print_section() {
    local label="$1"
    local content="$2"
    if [[ -n "$content" ]]; then
        printf '  %s:\n' "$label"
        printf '%s\n' "$content" | while IFS= read -r line; do
            printf '    %s\n' "$line"
        done
    fi
}

# Helper: should we show this category for the given filter?
_tree_should_show() {
    local filter="$1"
    local category="$2"
    [[ "$filter" == "all" || "$filter" == "$category" ]]
}

# ── Python ────────────────────────────────────────────
_tree_extract_python() {
    local file="$1" filter="$2"
    local imports="" classes="" functions="" decorators_buf=""

    if _tree_should_show "$filter" "imports"; then
        imports=$(grep -n '^import \|^from ' "$file" 2>/dev/null | head -20) || true
        _tree_print_section "Imports" "$imports"
    fi

    if _tree_should_show "$filter" "classes"; then
        classes=$(grep -n '^\s*class \w' "$file" 2>/dev/null | head -20) || true
        _tree_print_section "Classes" "$classes"
    fi

    if _tree_should_show "$filter" "functions"; then
        # Capture functions with optional decorators
        functions=$(grep -n '^\s*\(async \)\{0,1\}def \w' "$file" 2>/dev/null | head -40) || true
        _tree_print_section "Functions" "$functions"
    fi
}

# ── JavaScript / TypeScript ───────────────────────────
_tree_extract_js_ts() {
    local file="$1" filter="$2"

    if _tree_should_show "$filter" "imports"; then
        local imports
        imports=$(grep -n '^import ' "$file" 2>/dev/null | head -20) || true
        _tree_print_section "Imports" "$imports"
    fi

    if _tree_should_show "$filter" "exports"; then
        local exports
        exports=$(grep -n '^export ' "$file" 2>/dev/null | grep -v '^[0-9]*:export default function\|^[0-9]*:export default class\|^[0-9]*:export function\|^[0-9]*:export class\|^[0-9]*:export const\|^[0-9]*:export async' | head -20) || true
        _tree_print_section "Exports" "$exports"
    fi

    if _tree_should_show "$filter" "types"; then
        local types
        types=$(grep -n '^\s*\(export \)\{0,1\}\(type\|interface\) \w' "$file" 2>/dev/null | head -20) || true
        _tree_print_section "Types/Interfaces" "$types"
    fi

    if _tree_should_show "$filter" "classes"; then
        local classes
        classes=$(grep -n '^\s*\(export \)\{0,1\}class \w' "$file" 2>/dev/null | head -20) || true
        _tree_print_section "Classes" "$classes"
    fi

    if _tree_should_show "$filter" "functions"; then
        local functions
        # Named function declarations and const arrow functions
        functions=$(grep -n '^\s*\(export \)\{0,1\}\(export default \)\{0,1\}\(async \)\{0,1\}function \w\|^\s*\(export \)\{0,1\}const \w\+ = \(async \)\{0,1\}(' "$file" 2>/dev/null | head -40) || true
        _tree_print_section "Functions" "$functions"
    fi
}

# ── Swift ─────────────────────────────────────────────
_tree_extract_swift() {
    local file="$1" filter="$2"

    if _tree_should_show "$filter" "imports"; then
        local imports
        imports=$(grep -n '^import ' "$file" 2>/dev/null | head -20) || true
        _tree_print_section "Imports" "$imports"
    fi

    if _tree_should_show "$filter" "classes"; then
        local classes
        # class, struct, enum, protocol, actor, extension
        classes=$(grep -n '^\s*\(public \|private \|internal \|open \|fileprivate \)\{0,1\}\(final \)\{0,1\}\(class\|struct\|enum\|protocol\|actor\|extension\) \w' "$file" 2>/dev/null | head -20) || true
        _tree_print_section "Types" "$classes"
    fi

    if _tree_should_show "$filter" "functions"; then
        local functions
        functions=$(grep -n '^\s*\(public \|private \|internal \|open \|fileprivate \)\{0,1\}\(static \|class \)\{0,1\}\(override \)\{0,1\}func \w' "$file" 2>/dev/null | head -40) || true
        _tree_print_section "Functions" "$functions"
    fi

    if _tree_should_show "$filter" "types"; then
        local properties
        properties=$(grep -n '^\s*\(public \|private \|internal \|open \|fileprivate \)\{0,1\}\(static \|class \)\{0,1\}\(var\|let\) \w' "$file" 2>/dev/null | grep -v '^\s*\/\/' | head -30) || true
        _tree_print_section "Properties" "$properties"
    fi
}

# ── Rust ──────────────────────────────────────────────
_tree_extract_rust() {
    local file="$1" filter="$2"

    if _tree_should_show "$filter" "imports"; then
        local imports
        imports=$(grep -n '^use ' "$file" 2>/dev/null | head -20) || true
        _tree_print_section "Imports (use)" "$imports"
    fi

    if _tree_should_show "$filter" "classes"; then
        local types
        types=$(grep -n '^\s*\(pub\(([^)]*)\)\{0,1\} \)\{0,1\}\(struct\|enum\|trait\|impl\) \w' "$file" 2>/dev/null | head -20) || true
        _tree_print_section "Types" "$types"
    fi

    if _tree_should_show "$filter" "functions"; then
        local functions
        functions=$(grep -n '^\s*\(pub\(([^)]*)\)\{0,1\} \)\{0,1\}\(async \)\{0,1\}fn \w' "$file" 2>/dev/null | head -40) || true
        _tree_print_section "Functions" "$functions"
    fi

    if _tree_should_show "$filter" "imports"; then
        local modules
        modules=$(grep -n '^\(pub \)\{0,1\}mod \w' "$file" 2>/dev/null | head -20) || true
        _tree_print_section "Modules" "$modules"
    fi
}

# ── Go ────────────────────────────────────────────────
_tree_extract_go() {
    local file="$1" filter="$2"

    if _tree_should_show "$filter" "imports"; then
        local imports
        imports=$(grep -n '^import \|^\t"' "$file" 2>/dev/null | head -20) || true
        _tree_print_section "Imports" "$imports"
    fi

    if _tree_should_show "$filter" "classes" || _tree_should_show "$filter" "types"; then
        local types
        types=$(grep -n '^type \w' "$file" 2>/dev/null | head -20) || true
        _tree_print_section "Types" "$types"
    fi

    if _tree_should_show "$filter" "functions"; then
        local functions
        functions=$(grep -n '^func ' "$file" 2>/dev/null | head -40) || true
        _tree_print_section "Functions" "$functions"
    fi
}

# ── Java / Kotlin / Scala / C# ───────────────────────
_tree_extract_java() {
    local file="$1" filter="$2"

    if _tree_should_show "$filter" "imports"; then
        local imports
        imports=$(grep -n '^import ' "$file" 2>/dev/null | head -20) || true
        _tree_print_section "Imports" "$imports"
    fi

    if _tree_should_show "$filter" "classes"; then
        local classes
        classes=$(grep -n '^\s*\(public \|private \|protected \)\{0,1\}\(abstract \|final \|static \|sealed \|data \)\{0,1\}\(class\|interface\|enum\|object\|record\) \w' "$file" 2>/dev/null | head -20) || true
        _tree_print_section "Classes" "$classes"
    fi

    if _tree_should_show "$filter" "functions"; then
        local functions
        # Method declarations — lines with access modifier + return type + name + (
        functions=$(grep -n '^\s*\(public \|private \|protected \)\{0,1\}\(static \|abstract \|override \|suspend \|final \)\{0,1\}\(fun \|void \|int \|long \|String \|boolean \|double \|float \|char \|byte \|short \|var \|val \)\w\+\s*(' "$file" 2>/dev/null | head -40) || true
        # Also catch Kotlin fun declarations
        local kt_functions
        kt_functions=$(grep -n '^\s*\(public \|private \|protected \|internal \)\{0,1\}\(override \|suspend \)\{0,1\}fun \w' "$file" 2>/dev/null | head -40) || true
        if [[ -n "$kt_functions" ]]; then
            functions="$functions
$kt_functions"
        fi
        # Deduplicate
        functions=$(echo "$functions" | sort -t: -k1,1n -u)
        _tree_print_section "Functions/Methods" "$functions"
    fi
}

# ── Ruby ──────────────────────────────────────────────
_tree_extract_ruby() {
    local file="$1" filter="$2"

    if _tree_should_show "$filter" "imports"; then
        local requires
        requires=$(grep -n '^require' "$file" 2>/dev/null | head -20) || true
        _tree_print_section "Requires" "$requires"
    fi

    if _tree_should_show "$filter" "classes"; then
        local classes
        classes=$(grep -n '^\s*\(class\|module\) \w' "$file" 2>/dev/null | head -20) || true
        _tree_print_section "Classes/Modules" "$classes"
    fi

    if _tree_should_show "$filter" "functions"; then
        local functions
        functions=$(grep -n '^\s*def \w' "$file" 2>/dev/null | head -40) || true
        _tree_print_section "Methods" "$functions"
    fi
}

# ── C / C++ ──────────────────────────────────────────
_tree_extract_c_cpp() {
    local file="$1" filter="$2"

    if _tree_should_show "$filter" "imports"; then
        local includes
        includes=$(grep -n '^#include' "$file" 2>/dev/null | head -20) || true
        _tree_print_section "Includes" "$includes"

        local defines
        defines=$(grep -n '^#define ' "$file" 2>/dev/null | head -20) || true
        _tree_print_section "Defines" "$defines"
    fi

    if _tree_should_show "$filter" "classes"; then
        local types
        types=$(grep -n '^\s*\(typedef \)\{0,1\}\(struct\|class\|enum\|union\|namespace\) \w' "$file" 2>/dev/null | head -20) || true
        _tree_print_section "Types" "$types"
    fi

    if _tree_should_show "$filter" "functions"; then
        # Functions: lines with return type, name, and ( — heuristic
        local functions
        functions=$(grep -n '^\(static \|inline \|extern \|virtual \)\{0,1\}\(void\|int\|long\|char\|float\|double\|bool\|unsigned\|signed\|size_t\|auto\|const \)\{0,1\}\w\+\s\+\w\+\s*(.*)\s*{' "$file" 2>/dev/null | head -40) || true
        # Also catch function declarations ending with );
        local decls
        decls=$(grep -n '^\(static \|inline \|extern \|virtual \)\{0,1\}\(void\|int\|long\|char\|float\|double\|bool\|unsigned\|signed\|size_t\|auto\|const \)\{0,1\}\w\+\s\+\w\+\s*(.*)\s*;' "$file" 2>/dev/null | head -20) || true
        if [[ -n "$decls" ]]; then
            functions="$functions
$decls"
        fi
        functions=$(echo "$functions" | sort -t: -k1,1n -u)
        _tree_print_section "Functions" "$functions"
    fi
}

# ── PHP ───────────────────────────────────────────────
_tree_extract_php() {
    local file="$1" filter="$2"

    if _tree_should_show "$filter" "imports"; then
        local imports
        imports=$(grep -n '^\(use \|require\|include\)' "$file" 2>/dev/null | head -20) || true
        _tree_print_section "Imports" "$imports"
    fi

    if _tree_should_show "$filter" "classes"; then
        local classes
        classes=$(grep -n '^\s*\(abstract \|final \)\{0,1\}\(class\|interface\|trait\|enum\) \w' "$file" 2>/dev/null | head -20) || true
        _tree_print_section "Classes" "$classes"
    fi

    if _tree_should_show "$filter" "functions"; then
        local functions
        functions=$(grep -n '^\s*\(public \|private \|protected \)\{0,1\}\(static \)\{0,1\}function \w' "$file" 2>/dev/null | head -40) || true
        _tree_print_section "Functions" "$functions"
    fi
}

# ── Shell ─────────────────────────────────────────────
_tree_extract_shell() {
    local file="$1" filter="$2"

    if _tree_should_show "$filter" "imports"; then
        local sources
        sources=$(grep -n '^\. \|^source ' "$file" 2>/dev/null | head -20) || true
        _tree_print_section "Sources" "$sources"
    fi

    if _tree_should_show "$filter" "functions"; then
        local functions
        functions=$(grep -n '^\w\+\s*() *{$\|^function \w' "$file" 2>/dev/null | head -40) || true
        _tree_print_section "Functions" "$functions"
    fi
}


# ══════════════════════════════════════════════════════
# Tool 3: lsp_query — language server / compiler bridge
# ══════════════════════════════════════════════════════

tool_lsp_query() {
    local args="$1"
    local action file line column
    action=$(echo "$args" | jq -r '.action // empty')
    file=$(echo "$args" | jq -r '.file // empty')
    line=$(echo "$args" | jq -r '.line // empty')
    column=$(echo "$args" | jq -r '.column // empty')

    if [[ -z "$action" ]]; then
        echo "Error: action is required"
        return 1
    fi

    # Resolve relative paths
    if [[ -n "$file" && "$file" != "null" && "$file" != /* ]]; then
        file="$WORK_DIR/$file"
    fi

    case "$action" in
        check)
            _lsp_check_servers
            ;;
        diagnostics)
            if [[ -z "$file" || "$file" == "null" ]]; then
                echo "Error: file is required for diagnostics action"
                return 1
            fi
            _lsp_diagnostics "$file"
            ;;
        definition)
            if [[ -z "$file" || "$file" == "null" ]]; then
                echo "Error: file is required for definition action"
                return 1
            fi
            if [[ -z "$line" || "$line" == "null" || -z "$column" || "$column" == "null" ]]; then
                echo "Error: line and column are required for definition action"
                return 1
            fi
            _lsp_definition "$file" "$line" "$column"
            ;;
        references)
            if [[ -z "$file" || "$file" == "null" ]]; then
                echo "Error: file is required for references action"
                return 1
            fi
            if [[ -z "$line" || "$line" == "null" || -z "$column" || "$column" == "null" ]]; then
                echo "Error: line and column are required for references action"
                return 1
            fi
            _lsp_references "$file" "$line" "$column"
            ;;
        hover)
            if [[ -z "$file" || "$file" == "null" ]]; then
                echo "Error: file is required for hover action"
                return 1
            fi
            if [[ -z "$line" || "$line" == "null" || -z "$column" || "$column" == "null" ]]; then
                echo "Error: line and column are required for hover action"
                return 1
            fi
            _lsp_hover "$file" "$line" "$column"
            ;;
        *)
            echo "Error: unknown action '$action'. Use: check, diagnostics, definition, references, hover"
            return 1
            ;;
    esac
}

# ── check: detect available LSP servers / compilers ──

_lsp_check_servers() {
    echo "LSP Server / Compiler Availability:"
    echo ""

    # LSP servers
    local has_any=false
    _lsp_check_one "sourcekit-lsp"                "Swift (LSP)"         && has_any=true
    _lsp_check_one "swiftc"                       "Swift (compiler)"    && has_any=true
    _lsp_check_one "pyright"                      "Python (pyright)"    && has_any=true
    _lsp_check_one "pylsp"                        "Python (pylsp)"      && has_any=true
    _lsp_check_one "python3"                      "Python (syntax)"     && has_any=true
    _lsp_check_one "mypy"                         "Python (mypy)"       && has_any=true
    _lsp_check_one "typescript-language-server"    "TypeScript (LSP)"   && has_any=true
    _lsp_check_one "npx"                          "TypeScript (tsc)"    && has_any=true
    _lsp_check_one "gopls"                        "Go (LSP)"            && has_any=true
    _lsp_check_one "go"                           "Go (compiler)"       && has_any=true
    _lsp_check_one "rust-analyzer"                "Rust (LSP)"          && has_any=true
    _lsp_check_one "cargo"                        "Rust (cargo)"        && has_any=true
    _lsp_check_one "clangd"                       "C/C++ (LSP)"        && has_any=true
    _lsp_check_one "clang"                        "C/C++ (compiler)"   && has_any=true
    _lsp_check_one "gcc"                          "C/C++ (gcc)"        && has_any=true
    _lsp_check_one "ruby"                         "Ruby (syntax)"      && has_any=true
    _lsp_check_one "solargraph"                   "Ruby (LSP)"         && has_any=true

    echo ""
    echo "Note: 'diagnostics' uses compilers/linters; 'definition' and 'references' use regex fallback."
}

_lsp_check_one() {
    local cmd="$1" label="$2"
    if command -v "$cmd" >/dev/null 2>&1; then
        local version_info=""
        # Try to get version for some tools
        case "$cmd" in
            swiftc)     version_info=$($cmd --version 2>/dev/null | head -1) ;;
            python3)    version_info=$($cmd --version 2>/dev/null) ;;
            go)         version_info=$($cmd version 2>/dev/null | head -1) ;;
            cargo)      version_info=$($cmd --version 2>/dev/null | head -1) ;;
            clang)      version_info=$($cmd --version 2>/dev/null | head -1) ;;
            gcc)        version_info=$($cmd --version 2>/dev/null | head -1) ;;
            ruby)       version_info=$($cmd --version 2>/dev/null) ;;
        esac
        if [[ -n "$version_info" ]]; then
            printf '  [ok] %-28s %s\n' "$label" "$version_info"
        else
            printf '  [ok] %s\n' "$label"
        fi
        return 0
    else
        printf '  [--] %s (not installed)\n' "$label"
        return 1
    fi
}

# ── diagnostics: get errors/warnings using compilers ──

_lsp_diagnostics() {
    local file="$1"

    if [[ ! -f "$file" ]]; then
        echo "Error: file not found: $file"
        return 1
    fi

    local ext="${file##*.}"
    ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
    local output=""
    local tool_used=""

    case "$ext" in
        swift)
            if command -v swiftc >/dev/null 2>&1; then
                tool_used="swiftc -typecheck"
                output=$(swiftc -typecheck "$file" 2>&1) || true
            else
                echo "Error: swiftc is not installed. Install Xcode Command Line Tools."
                return 1
            fi
            ;;
        py)
            if command -v pyright >/dev/null 2>&1; then
                tool_used="pyright"
                output=$(pyright "$file" 2>&1) || true
            elif command -v python3 >/dev/null 2>&1; then
                tool_used="python3 -m py_compile"
                output=$(python3 -m py_compile "$file" 2>&1) || true
                if [[ -z "$output" ]]; then
                    output="No syntax errors found."
                fi
            else
                echo "Error: neither pyright nor python3 is available."
                return 1
            fi
            ;;
        js|jsx|ts|tsx)
            if command -v npx >/dev/null 2>&1 && [[ -f "$(dirname "$file")/tsconfig.json" || -f "$WORK_DIR/tsconfig.json" ]]; then
                tool_used="tsc --noEmit"
                output=$(npx tsc --noEmit "$file" 2>&1) || true
            else
                echo "Error: TypeScript checking requires npx and a tsconfig.json. Not available."
                return 1
            fi
            ;;
        go)
            if command -v go >/dev/null 2>&1; then
                tool_used="go vet"
                output=$(cd "$(dirname "$file")" && go vet ./... 2>&1) || true
                if [[ -z "$output" ]]; then
                    output="No issues found."
                fi
            else
                echo "Error: go is not installed."
                return 1
            fi
            ;;
        rs)
            if command -v cargo >/dev/null 2>&1; then
                # cargo check can trigger builds — confirm
                ui_tool_call "lsp_query" "diagnostics (cargo check) for $(basename "$file")"
                if ! ui_confirm "Run cargo check? (compiles code, may take a moment)" "n" "execute"; then
                    echo "Cancelled by user."
                    return 1
                fi
                tool_used="cargo check"
                local cargo_dir
                cargo_dir=$(_lsp_find_project_root "$file" "Cargo.toml")
                if [[ -n "$cargo_dir" ]]; then
                    output=$(cd "$cargo_dir" && cargo check 2>&1 | grep -A 2 "$(basename "$file")") || true
                else
                    output="Error: no Cargo.toml found in parent directories."
                fi
            else
                echo "Error: cargo is not installed."
                return 1
            fi
            ;;
        c|h)
            if command -v clang >/dev/null 2>&1; then
                tool_used="clang -fsyntax-only"
                output=$(clang -fsyntax-only "$file" 2>&1) || true
                if [[ -z "$output" ]]; then
                    output="No issues found."
                fi
            elif command -v gcc >/dev/null 2>&1; then
                tool_used="gcc -fsyntax-only"
                output=$(gcc -fsyntax-only "$file" 2>&1) || true
                if [[ -z "$output" ]]; then
                    output="No issues found."
                fi
            else
                echo "Error: neither clang nor gcc is available."
                return 1
            fi
            ;;
        cpp|hpp|cc|cxx|hxx)
            if command -v clang++ >/dev/null 2>&1; then
                tool_used="clang++ -fsyntax-only"
                output=$(clang++ -fsyntax-only -std=c++17 "$file" 2>&1) || true
                if [[ -z "$output" ]]; then
                    output="No issues found."
                fi
            elif command -v g++ >/dev/null 2>&1; then
                tool_used="g++ -fsyntax-only"
                output=$(g++ -fsyntax-only -std=c++17 "$file" 2>&1) || true
                if [[ -z "$output" ]]; then
                    output="No issues found."
                fi
            else
                echo "Error: neither clang++ nor g++ is available."
                return 1
            fi
            ;;
        rb)
            if command -v ruby >/dev/null 2>&1; then
                tool_used="ruby -c"
                output=$(ruby -c "$file" 2>&1) || true
            else
                echo "Error: ruby is not installed."
                return 1
            fi
            ;;
        sh|bash|zsh)
            if command -v bash >/dev/null 2>&1; then
                tool_used="bash -n"
                output=$(bash -n "$file" 2>&1) || true
                if [[ -z "$output" ]]; then
                    output="No syntax errors found."
                fi
            fi
            ;;
        *)
            echo "Error: no diagnostics support for .$ext files."
            echo "Supported: .py, .swift, .js/.ts/.tsx, .go, .rs, .c/.cpp, .rb, .sh"
            return 1
            ;;
    esac

    # Parse and format output
    local display_path="$file"
    if [[ "$file" == "$WORK_DIR/"* ]]; then
        display_path="${file#$WORK_DIR/}"
    fi

    printf 'Diagnostics for %s (via %s):\n' "$display_path" "$tool_used"
    printf '%s\n' "---"

    if [[ -z "$output" ]]; then
        printf 'No issues found.\n'
    else
        # Count errors and warnings
        local error_count warning_count
        error_count=$(echo "$output" | grep -ci 'error' 2>/dev/null) || error_count=0
        warning_count=$(echo "$output" | grep -ci 'warning' 2>/dev/null) || warning_count=0

        # Show output (truncated if very long)
        local output_lines
        output_lines=$(echo "$output" | wc -l | tr -d ' ')
        if (( output_lines > 50 )); then
            echo "$output" | head -50
            printf '\n... (%s more lines)\n' "$((output_lines - 50))"
        else
            echo "$output"
        fi

        if (( error_count > 0 || warning_count > 0 )); then
            printf '\nSummary: %s error(s), %s warning(s)\n' "$error_count" "$warning_count"
        fi
    fi
}

# ── definition: find where a symbol is defined ────────

_lsp_definition() {
    local file="$1" line="$2" column="$3"

    if [[ ! -f "$file" ]]; then
        echo "Error: file not found: $file"
        return 1
    fi

    # Extract the symbol at the given line:column
    local symbol
    symbol=$(_lsp_extract_symbol "$file" "$line" "$column")

    if [[ -z "$symbol" ]]; then
        echo "Error: no symbol found at line $line, column $column"
        return 1
    fi

    echo "Finding definition of '$symbol'..."
    echo ""

    local ext="${file##*.}"
    ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')

    # Build search patterns based on language
    local patterns=""
    case "$ext" in
        py)
            patterns="def ${symbol}\b|class ${symbol}\b|${symbol}\s*="
            ;;
        js|jsx|ts|tsx)
            patterns="function ${symbol}\b|class ${symbol}\b|const ${symbol}\b|let ${symbol}\b|var ${symbol}\b|interface ${symbol}\b|type ${symbol}\b"
            ;;
        swift)
            patterns="func ${symbol}\b|class ${symbol}\b|struct ${symbol}\b|enum ${symbol}\b|protocol ${symbol}\b|let ${symbol}\b|var ${symbol}\b"
            ;;
        rs)
            patterns="fn ${symbol}\b|struct ${symbol}\b|enum ${symbol}\b|trait ${symbol}\b|type ${symbol}\b|const ${symbol}\b|static ${symbol}\b|mod ${symbol}\b"
            ;;
        go)
            patterns="func ${symbol}\b|func \([^)]+\) ${symbol}\b|type ${symbol}\b|var ${symbol}\b|const ${symbol}\b"
            ;;
        java|kt|kts|scala|cs)
            patterns="class ${symbol}\b|interface ${symbol}\b|enum ${symbol}\b|void ${symbol}\s*\(|int ${symbol}\s*\(|String ${symbol}\s*\(|fun ${symbol}\b|def ${symbol}\b"
            ;;
        rb)
            patterns="def ${symbol}\b|class ${symbol}\b|module ${symbol}\b"
            ;;
        c|h|cpp|hpp|cc|cxx|hxx)
            patterns="struct ${symbol}\b|class ${symbol}\b|enum ${symbol}\b|typedef.*${symbol}\b|${symbol}\s*\("
            ;;
        *)
            patterns="${symbol}\s*[=(]|def ${symbol}\b|function ${symbol}\b|class ${symbol}\b"
            ;;
    esac

    # Search project for definitions
    local search_dir="$WORK_DIR"
    local results
    results=$(grep -rnE "$patterns" "$search_dir" \
        --include="*.${ext}" \
        --exclude-dir=.git \
        --exclude-dir=node_modules \
        --exclude-dir=__pycache__ \
        --exclude-dir=.venv \
        --exclude-dir=venv \
        --exclude-dir=vendor \
        --exclude-dir=build \
        --exclude-dir=dist \
        --exclude-dir=target \
        2>/dev/null | head -20) || true

    if [[ -z "$results" ]]; then
        # Broaden search to all source file types
        results=$(grep -rnE "$patterns" "$search_dir" \
            --include="*.py" --include="*.js" --include="*.ts" --include="*.tsx" \
            --include="*.swift" --include="*.rs" --include="*.go" --include="*.java" \
            --include="*.rb" --include="*.c" --include="*.h" --include="*.cpp" --include="*.hpp" \
            --include="*.kt" --include="*.cs" --include="*.php" \
            --exclude-dir=.git \
            --exclude-dir=node_modules \
            --exclude-dir=__pycache__ \
            --exclude-dir=.venv \
            --exclude-dir=vendor \
            --exclude-dir=build \
            --exclude-dir=dist \
            --exclude-dir=target \
            2>/dev/null | head -20) || true
    fi

    if [[ -z "$results" ]]; then
        echo "No definition found for '$symbol'."
        echo "The symbol may be from a standard library or external dependency."
    else
        echo "Possible definitions:"
        echo "$results" | while IFS= read -r match_line; do
            # Relativize paths for display
            local display_match="$match_line"
            if [[ "$match_line" == "$WORK_DIR/"* ]]; then
                display_match="${match_line#$WORK_DIR/}"
            fi
            printf '  %s\n' "$display_match"
        done
    fi
    echo ""
    echo "(regex-based search — may include false positives)"
}

# ── references: find all uses of a symbol ─────────────

_lsp_references() {
    local file="$1" line="$2" column="$3"

    if [[ ! -f "$file" ]]; then
        echo "Error: file not found: $file"
        return 1
    fi

    local symbol
    symbol=$(_lsp_extract_symbol "$file" "$line" "$column")

    if [[ -z "$symbol" ]]; then
        echo "Error: no symbol found at line $line, column $column"
        return 1
    fi

    echo "Finding references to '$symbol'..."
    echo ""

    local search_dir="$WORK_DIR"
    local results
    results=$(grep -rn "\b${symbol}\b" "$search_dir" \
        --include="*.py" --include="*.js" --include="*.ts" --include="*.tsx" --include="*.jsx" \
        --include="*.swift" --include="*.rs" --include="*.go" --include="*.java" \
        --include="*.rb" --include="*.c" --include="*.h" --include="*.cpp" --include="*.hpp" \
        --include="*.kt" --include="*.cs" --include="*.php" --include="*.sh" \
        --exclude-dir=.git \
        --exclude-dir=node_modules \
        --exclude-dir=__pycache__ \
        --exclude-dir=.venv \
        --exclude-dir=venv \
        --exclude-dir=vendor \
        --exclude-dir=build \
        --exclude-dir=dist \
        --exclude-dir=target \
        --exclude-dir=.cache \
        2>/dev/null | head -50) || true

    if [[ -z "$results" ]]; then
        echo "No references found for '$symbol'."
    else
        local ref_count
        ref_count=$(echo "$results" | wc -l | tr -d ' ')

        echo "References ($ref_count found, showing up to 50):"
        echo "$results" | while IFS= read -r match_line; do
            local display_match="$match_line"
            if [[ "$match_line" == "$WORK_DIR/"* ]]; then
                display_match="${match_line#$WORK_DIR/}"
            fi
            printf '  %s\n' "$display_match"
        done

        # Check for more
        local total_count
        total_count=$(grep -rc "\b${symbol}\b" "$search_dir" \
            --include="*.py" --include="*.js" --include="*.ts" --include="*.tsx" --include="*.jsx" \
            --include="*.swift" --include="*.rs" --include="*.go" --include="*.java" \
            --include="*.rb" --include="*.c" --include="*.h" --include="*.cpp" --include="*.hpp" \
            --include="*.kt" --include="*.cs" --include="*.php" --include="*.sh" \
            --exclude-dir=.git \
            --exclude-dir=node_modules \
            --exclude-dir=__pycache__ \
            --exclude-dir=.venv \
            --exclude-dir=vendor \
            --exclude-dir=build \
            --exclude-dir=dist \
            --exclude-dir=target \
            2>/dev/null | awk -F: '{s+=$NF}END{print s+0}') || total_count=0

        if (( total_count > 50 )); then
            printf '\n... (%s total references, showing first 50)\n' "$total_count"
        fi
    fi
    echo ""
    echo "(regex-based search — may include false positives)"
}

# ── hover: get type/signature info for a symbol ───────

_lsp_hover() {
    local file="$1" line="$2" column="$3"

    if [[ ! -f "$file" ]]; then
        echo "Error: file not found: $file"
        return 1
    fi

    local symbol
    symbol=$(_lsp_extract_symbol "$file" "$line" "$column")

    if [[ -z "$symbol" ]]; then
        echo "Error: no symbol found at line $line, column $column"
        return 1
    fi

    echo "Hover info for '$symbol':"
    echo ""

    # Show the line where the symbol is used
    local source_line
    source_line=$(sed -n "${line}p" "$file")
    printf '  Source:  %s:%s\n' "$(basename "$file")" "$line"
    printf '  Line:    %s\n' "$source_line"
    echo ""

    # Try to find the definition to show the signature
    local ext="${file##*.}"
    ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')

    local patterns=""
    case "$ext" in
        py)     patterns="def ${symbol}\\b|class ${symbol}\\b" ;;
        js|jsx|ts|tsx) patterns="function ${symbol}\\b|class ${symbol}\\b|const ${symbol}\\b|interface ${symbol}\\b|type ${symbol}\\b" ;;
        swift)  patterns="func ${symbol}\\b|class ${symbol}\\b|struct ${symbol}\\b|protocol ${symbol}\\b" ;;
        rs)     patterns="fn ${symbol}\\b|struct ${symbol}\\b|enum ${symbol}\\b|trait ${symbol}\\b" ;;
        go)     patterns="func.*${symbol}\\b|type ${symbol}\\b" ;;
        *)      patterns="def ${symbol}\\b|function ${symbol}\\b|class ${symbol}\\b" ;;
    esac

    local def_result
    def_result=$(grep -rnE "$patterns" "$WORK_DIR" \
        --include="*.${ext}" \
        --exclude-dir=.git \
        --exclude-dir=node_modules \
        --exclude-dir=__pycache__ \
        --exclude-dir=.venv \
        --exclude-dir=vendor \
        --exclude-dir=build \
        --exclude-dir=dist \
        2>/dev/null | head -5) || true

    if [[ -n "$def_result" ]]; then
        echo "Definition:"
        echo "$def_result" | while IFS= read -r match_line; do
            local display_match="$match_line"
            if [[ "$match_line" == "$WORK_DIR/"* ]]; then
                display_match="${match_line#$WORK_DIR/}"
            fi
            printf '  %s\n' "$display_match"
        done
    else
        echo "  No definition found in project — may be from standard library or dependency."
    fi
    echo ""
    echo "(regex-based lookup — for precise type info, use a language-specific type checker)"
}

# ── Helper: extract symbol (word) at line:column ──────

_lsp_extract_symbol() {
    local file="$1" line="$2" column="$3"

    # Get the line content
    local line_content
    line_content=$(sed -n "${line}p" "$file" 2>/dev/null)

    if [[ -z "$line_content" ]]; then
        return 1
    fi

    # Extract the word at/around the given column (1-indexed)
    # Walk left and right from the column to find word boundaries
    local col_idx=$((column - 1))
    local len=${#line_content}

    # Bounds check
    if (( col_idx < 0 )); then
        col_idx=0
    fi
    if (( col_idx >= len )); then
        col_idx=$((len - 1))
    fi

    # Find word start (walk left while alphanumeric or underscore)
    local start=$col_idx
    while (( start > 0 )); do
        local prev_char="${line_content:$((start - 1)):1}"
        case "$prev_char" in
            [a-zA-Z0-9_]) start=$((start - 1)) ;;
            *) break ;;
        esac
    done

    # Find word end (walk right while alphanumeric or underscore)
    local end=$col_idx
    while (( end < len - 1 )); do
        local next_char="${line_content:$((end + 1)):1}"
        case "$next_char" in
            [a-zA-Z0-9_]) end=$((end + 1)) ;;
            *) break ;;
        esac
    done

    local word="${line_content:$start:$((end - start + 1))}"

    # Validate: must be a valid identifier
    if [[ "$word" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
        echo "$word"
    fi
}

# ── Helper: find project root by walking up for a marker file ──

_lsp_find_project_root() {
    local file="$1"
    local marker="$2"
    local dir
    dir=$(dirname "$file")

    while [[ "$dir" != "/" ]]; do
        if [[ -f "$dir/$marker" ]]; then
            echo "$dir"
            return 0
        fi
        dir=$(dirname "$dir")
    done
    return 1
}

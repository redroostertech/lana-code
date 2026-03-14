#!/usr/bin/env bash
# Terminal UI: colors, formatting, layout primitives, tool display
# Beautiful ANSI terminal UI — zero dependencies, pure escape codes
# NOTE: ui_tool_call, ui_tool_result, ui_confirm all write to /dev/tty
#       so they remain visible even when called inside $() subshells.

# ── Headless mode (when called from Node frontend) ────
# When LANA_HEADLESS=true, skip all tty output (Node handles the UI)
if [[ "${LANA_HEADLESS:-false}" == "true" ]]; then
    ui_tool_call() { :; }
    ui_tool_result() { :; }
    ui_confirm() { echo "y"; }
    ui_tool_confirm() { _UI_CONFIRM_RESULT=0; return 0; }
    ui_info() { echo "[INFO] $*"; }
    ui_success() { echo "[OK] $*"; }
    ui_warn() { echo "[WARN] $*"; }
    ui_error() { echo "[ERROR] $*" >&2; }
    ui_dim() { :; }
    ui_debug() { :; }
    # Stub all color/icon/box variables so scripts using them don't fail with set -u
    C_RESET='' C_BOLD='' C_DIM='' C_ITALIC='' C_UNDERLINE=''
    C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_MAGENTA='' C_CYAN='' C_WHITE='' C_GRAY=''
    C_BRED='' C_BGREEN='' C_BYELLOW='' C_BBLUE='' C_BMAGENTA='' C_BCYAN=''
    C_BG_RED='' C_BG_GREEN='' C_BG_YELLOW='' C_BG_BLUE='' C_BG_GRAY=''
    BOX_TL='' BOX_TR='' BOX_BL='' BOX_BR='' BOX_H='' BOX_V=''
    BOX_LT='' BOX_RT='' BOX_BT='' BOX_TT=''
    IC_FILE='' IC_SEARCH='' IC_EXEC='' IC_CODE='' IC_NET='' IC_GIT=''
    IC_AGENT='' IC_MEM='' IC_PLAN='' IC_OK='' IC_ERR='' IC_WARN=''
    IC_INFO='' IC_ARROW='' IC_LOCK='' IC_UNDO='' IC_TOOL='' IC_EDIT='' IC_DOT=''
    return 0 2>/dev/null || true
fi

# ── Color Palette ─────────────────────────────────────
# Primary palette — intentional, muted, professional
C_RESET='\033[0m'
C_BOLD='\033[1m'
C_DIM='\033[2m'
C_ITALIC='\033[3m'
C_UNDERLINE='\033[4m'

# Base colors
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_BLUE='\033[0;34m'
C_MAGENTA='\033[0;35m'
C_CYAN='\033[0;36m'
C_WHITE='\033[1;37m'
C_GRAY='\033[0;90m'

# Bright/bold variants
C_BRED='\033[1;31m'
C_BGREEN='\033[1;32m'
C_BYELLOW='\033[1;33m'
C_BBLUE='\033[1;34m'
C_BMAGENTA='\033[1;35m'
C_BCYAN='\033[1;36m'

# Background colors
C_BG_RED='\033[41m'
C_BG_GREEN='\033[42m'
C_BG_YELLOW='\033[43m'
C_BG_BLUE='\033[44m'
C_BG_GRAY='\033[100m'

# ── Box Drawing Characters ───────────────────────────
# Light box set
BOX_TL='╭'   # top-left
BOX_TR='╮'   # top-right
BOX_BL='╰'   # bottom-left
BOX_BR='╯'   # bottom-right
BOX_H='─'    # horizontal
BOX_V='│'    # vertical
BOX_LT='├'   # left tee
BOX_RT='┤'   # right tee
BOX_BT='┴'   # bottom tee
BOX_TT='┬'   # top tee

# ── Icons (Unicode) ──────────────────────────────────
IC_FILE='  '    # file operations
IC_SEARCH=' '   # search/find
IC_EXEC=' '    # execute/bash
IC_CODE=' '    # code/parse
IC_NET=' '     # network/web
IC_GIT=' '     # git
IC_AGENT=' '   # subagent
IC_MEM=' '     # memory
IC_PLAN=' '    # plan
IC_OK=' '      # success checkmark
IC_ERR=' '     # error
IC_WARN=' '    # warning
IC_INFO=' '    # info
IC_ARROW=' '   # arrow/pointer
IC_LOCK=' '    # permission/lock
IC_UNDO=' '    # undo
IC_TOOL=' '    # generic tool

# Map tool names to icons
_tool_icon() {
    case "$1" in
        read_file|write_file|edit_file|file_tree|batch_edit) echo "$IC_FILE" ;;
        grep_search|glob_find|search_index|scaffold_search)  echo "$IC_SEARCH" ;;
        bash|run_background|test_run|diff_apply)             echo "$IC_EXEC" ;;
        tree_parse|lsp_query|context_compress)               echo "$IC_CODE" ;;
        web_fetch)                                            echo "$IC_NET" ;;
        git_smart)                                            echo "$IC_GIT" ;;
        subagent)                                             echo "$IC_AGENT" ;;
        memory|recall_turn)                                   echo "$IC_MEM" ;;
        task_plan|project_detect)                             echo "$IC_PLAN" ;;
        undo)                                                 echo "$IC_UNDO" ;;
        mcp_*)                                                echo "$IC_NET" ;;
        *)                                                    echo "$IC_TOOL" ;;
    esac
}

# ── Layout Primitives ────────────────────────────────

# Get terminal width (fallback to 80)
_term_width() {
    local w
    w=$(tput cols 2>/dev/null) || w=80
    echo "$w"
}

# Draw a horizontal rule
ui_hr() {
    local char="${1:-$BOX_H}" color="${2:-$C_DIM}" width
    width=$(_term_width)
    printf "${color}"
    printf '%*s' "$width" '' | tr ' ' "$char"
    printf "${C_RESET}\n"
}

# Draw a labeled horizontal divider: ── label ──────────
ui_divider() {
    local label="$1" color="${2:-$C_DIM}" width pad
    width=$(_term_width)
    local label_len=${#label}
    pad=$(( (width - label_len - 6) ))
    (( pad < 4 )) && pad=4
    printf "${color}  ${BOX_H}${BOX_H} ${C_RESET}${color}%s${C_RESET}${color} " "$label"
    printf '%*s' "$pad" '' | tr ' ' "$BOX_H"
    printf "${C_RESET}\n"
}

# Draw a box around text
# Usage: ui_box "title" "line1\nline2\nline3" [width] [color]
ui_box() {
    local title="$1" body="$2" width="${3:-0}" color="${4:-$C_DIM}"
    local tw
    tw=$(_term_width)
    (( width == 0 )) && width=$((tw - 4))
    (( width > tw - 4 )) && width=$((tw - 4))

    local inner=$((width - 2))

    # Top border with title
    if [[ -n "$title" ]]; then
        local title_len=${#title}
        local right_pad=$((inner - title_len - 3))
        (( right_pad < 1 )) && right_pad=1
        printf "  ${color}${BOX_TL}${BOX_H} ${C_RESET}${C_BOLD}%s${C_RESET}${color} " "$title"
        printf '%*s' "$right_pad" '' | tr ' ' "$BOX_H"
        printf "${BOX_TR}${C_RESET}\n"
    else
        printf "  ${color}${BOX_TL}"
        printf '%*s' "$inner" '' | tr ' ' "$BOX_H"
        printf "${BOX_TR}${C_RESET}\n"
    fi

    # Body lines
    while IFS= read -r line; do
        local visible_len
        # Strip ANSI codes for length calculation
        visible_len=$(printf '%s' "$line" | sed 's/\x1b\[[0-9;]*m//g' | wc -c | tr -d ' ')
        local pad=$((inner - visible_len - 1))
        (( pad < 0 )) && pad=0
        printf "  ${color}${BOX_V}${C_RESET} %b%*s${color}${BOX_V}${C_RESET}\n" "$line" "$pad" ""
    done <<< "$body"

    # Bottom border
    printf "  ${color}${BOX_BL}"
    printf '%*s' "$inner" '' | tr ' ' "$BOX_H"
    printf "${BOX_BR}${C_RESET}\n"
}

# Draw a progress bar
# Usage: ui_progress_bar <percent> <width> <filled_color> <empty_color>
ui_progress_bar() {
    local pct="$1" width="${2:-20}" fill_color="${3:-$C_BGREEN}" empty_color="${4:-$C_DIM}"
    (( pct > 100 )) && pct=100
    (( pct < 0 )) && pct=0

    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))

    # Color based on percentage
    if (( pct >= 80 )); then
        fill_color="$C_BRED"
    elif (( pct >= 60 )); then
        fill_color="$C_BYELLOW"
    fi

    printf "${fill_color}"
    printf '%*s' "$filled" '' | tr ' ' '█'
    printf "${empty_color}"
    printf '%*s' "$empty" '' | tr ' ' '░'
    printf "${C_RESET}"
}

# Right-align text on same line
ui_right_align() {
    local text="$1" color="${2:-$C_DIM}" width
    width=$(_term_width)
    local text_len=${#text}
    local pad=$((width - text_len - 1))
    (( pad < 0 )) && pad=0
    printf "\033[%dG${color}%s${C_RESET}" "$pad" "$text"
}

# ── Prompt ────────────────────────────────────────────

ui_user_prompt() {
    printf "\n${C_BGREEN}>${C_RESET} "
}

# Readline prompt — \001/\002 bracket non-printing chars so readline
# calculates visible width correctly (prevents line-wrap corruption)
RL_PROMPT=$'\n\001\033[1;32m\002>\001\033[0m\002 '
RL_PROMPT_CONT=$'\001\033[2m\002  ... \001\033[0m\002'
# Plain ANSI versions (for Python input reader — no readline \001/\002 markers)
# Note: no leading \n — the caller prints the newline before invoking the reader
RL_PROMPT_PLAIN=$'\033[1;32m>\033[0m '
RL_PROMPT_CONT_PLAIN=$'\033[2m  ... \033[0m'

# ── Labels & Messages ────────────────────────────────

ui_assistant_label() {
    printf "\n${C_BBLUE}assistant${C_RESET}\n"
}

ui_error() {
    printf "  ${C_BRED}${IC_ERR} %s${C_RESET}\n" "$1" >&2
}

ui_warn() {
    printf "  ${C_YELLOW}${IC_WARN} %s${C_RESET}\n" "$1" >&2
}

ui_info() {
    printf "  ${C_CYAN}${IC_INFO} %s${C_RESET}\n" "$1"
}

ui_success() {
    printf "  ${C_BGREEN}${IC_OK} %s${C_RESET}\n" "$1"
}

ui_dim() {
    printf "  ${C_DIM}%s${C_RESET}\n" "$1"
}

# Debug output — conditional on LANA_DEBUG, always to /dev/tty
ui_debug() {
    if [[ "${LANA_DEBUG:-false}" == "true" || "${LANA_DEBUG:-0}" == "1" ]]; then
        printf "  ${C_GRAY}[debug] %s${C_RESET}\n" "$1" >/dev/tty
    fi
}

# ── Tool Call Display ─────────────────────────────────

ui_tool_call() {
    local name="$1" args="${2:-}"
    local icon
    icon=$(_tool_icon "$name")

    printf "${C_DIM}  ${BOX_V}${C_RESET}" >/dev/tty

    # Tool name with icon
    printf " ${C_BYELLOW}${icon} ${name}${C_RESET}" >/dev/tty

    # Format args — show path or brief summary
    if [[ -n "$args" && "$args" != "{}" && "$args" != "null" ]]; then
        # Truncate long args
        local display_args="$args"
        if (( ${#display_args} > 80 )); then
            display_args="${display_args:0:77}..."
        fi
        printf " ${C_DIM}%s${C_RESET}" "$display_args" >/dev/tty
    fi
    printf "\n" >/dev/tty
}

# Tool result preview — always writes to /dev/tty
ui_tool_result() {
    local result="$1" max_preview=400
    local tool_name="${2:-}"

    if [[ -z "$result" ]]; then
        case "$tool_name" in
            write_file|edit_file)
                printf "${C_DIM}  ${BOX_V}${C_RESET} ${C_GREEN}${IC_OK} done${C_RESET}\n" >/dev/tty
                ;;
            *)
                printf "${C_DIM}  ${BOX_V} ${IC_OK} (empty result)${C_RESET}\n" >/dev/tty
                ;;
        esac
        return
    fi

    # Count lines for display
    local line_count
    line_count=$(echo "$result" | wc -l | tr -d ' ')

    if (( line_count <= 5 )); then
        # Show all lines indented
        while IFS= read -r line; do
            if (( ${#line} > 120 )); then
                line="${line:0:117}..."
            fi
            printf "${C_DIM}  ${BOX_V}  %s${C_RESET}\n" "$line" >/dev/tty
        done <<< "$result"
    else
        # Show first 3 lines + count
        local shown=0
        while IFS= read -r line; do
            (( shown >= 3 )) && break
            if (( ${#line} > 120 )); then
                line="${line:0:117}..."
            fi
            printf "${C_DIM}  ${BOX_V}  %s${C_RESET}\n" "$line" >/dev/tty
            shown=$((shown + 1))
        done <<< "$result"
        printf "${C_DIM}  ${BOX_V}  ... (%s lines total)${C_RESET}\n" "$line_count" >/dev/tty
    fi
}

# ── Confirmation Dialog ──────────────────────────────

ui_confirm() {
    local prompt="$1" default="${2:-n}"
    local category="${3:-mutation}"  # "mutation" or "execute"

    # Fine-grained permission override
    if [[ "${_PERM_OVERRIDE:-}" == "allow" ]]; then
        printf "${C_DIM}  ${BOX_V} ${IC_OK} auto-accepted (permission rule)${C_RESET}\n" >/dev/tty
        return 0
    fi

    # Auto-accept based on mode
    case "$ACCEPT_MODE" in
        yolo)
            printf "${C_DIM}  ${BOX_V} ${IC_OK} auto-accepted${C_RESET}\n" >/dev/tty
            return 0
            ;;
        auto-edit)
            if [[ "$category" != "execute" ]]; then
                printf "${C_DIM}  ${BOX_V} ${IC_OK} auto-accepted${C_RESET}\n" >/dev/tty
                return 0
            fi
            ;;
    esac

    # Interactive confirmation
    local hint="y/N"
    [[ "$default" == "y" ]] && hint="Y/n"

    printf "  ${C_BYELLOW}? ${C_RESET}${C_BOLD}%s${C_RESET} ${C_DIM}[%s]${C_RESET} " "$prompt" "$hint" >/dev/tty
    local answer
    read -r answer </dev/tty
    answer="${answer:-$default}"
    [[ "$answer" =~ ^[Yy] ]]
}

# ── Rich Tool Confirmation ────────────────────────────
# Claude Code-style confirmation with command preview, warnings, and arrow-key Yes/No
# Usage: ui_tool_confirm "tool_label" "command_or_content" "description" ["warning"]
# Returns: 0 = proceed, 1 = cancel
# Sets: _UI_AMENDED_CMD (if user edited the command via Tab)

_UI_AMENDED_CMD=""

ui_tool_confirm() {
    local label="$1" content="$2" description="${3:-}" warning="${4:-}"
    local category="${5:-execute}"
    _UI_AMENDED_CMD=""

    # Fine-grained permission override
    if [[ "${_PERM_OVERRIDE:-}" == "allow" ]]; then
        printf "${C_DIM}  ${BOX_V} ${IC_OK} auto-accepted (permission rule)${C_RESET}\n" >/dev/tty
        return 0
    fi

    # Auto-accept based on mode
    case "$ACCEPT_MODE" in
        yolo)
            printf "${C_DIM}  ${BOX_V} ${IC_OK} auto-accepted${C_RESET}\n" >/dev/tty
            return 0
            ;;
        auto-edit)
            if [[ "$category" != "execute" ]]; then
                printf "${C_DIM}  ${BOX_V} ${IC_OK} auto-accepted${C_RESET}\n" >/dev/tty
                return 0
            fi
            ;;
    esac

    # Auto-detect warnings for bash commands
    if [[ -z "$warning" && "$label" == "Bash command" ]]; then
        # Check for potentially risky patterns
        if echo "$content" | grep -qE '^\s*sudo\s'; then
            warning="This command requires admin privileges"
        elif echo "$content" | grep -qE 'rm\s+(-[a-zA-Z]*r|--recursive)'; then
            warning="Recursive delete — verify the target path"
        elif echo "$content" | grep -qE 'chmod|chown'; then
            warning="Changing file permissions/ownership"
        elif echo "$content" | grep -qE 'curl.*\|\s*(bash|sh|zsh)'; then
            warning="Piping remote content to shell"
        elif echo "$content" | grep -qE '>[^>]'; then
            warning="Redirecting output — may overwrite a file"
        fi
    fi

    # ── Draw the confirmation box ──
    printf "\n" >/dev/tty

    # Label header (colored by type)
    local label_color="$C_BYELLOW"
    case "$label" in
        *"Bash"*|*"bash"*) label_color="$C_BRED" ;;
        *"Edit"*|*"edit"*) label_color="$C_BYELLOW" ;;
        *"Write"*|*"write"*) label_color="$C_BGREEN" ;;
    esac

    # Top border
    printf "  ${C_DIM}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${C_RESET}\n" >/dev/tty

    # Label
    printf "  ${label_color}${C_BOLD}%s${C_RESET}\n" "$label" >/dev/tty
    printf "\n" >/dev/tty

    # Command/content (indented, may be multi-line)
    local line_num=0
    while IFS= read -r line; do
        line_num=$((line_num + 1))
        if (( line_num > 10 )); then
            printf "    ${C_DIM}... (truncated)${C_RESET}\n" >/dev/tty
            break
        fi
        if (( ${#line} > 100 )); then
            line="${line:0:97}..."
        fi
        printf "    ${C_WHITE}%s${C_RESET}\n" "$line" >/dev/tty
    done <<< "$content"

    # Description (dimmed, below command)
    if [[ -n "$description" ]]; then
        printf "    ${C_DIM}%s${C_RESET}\n" "$description" >/dev/tty
    fi

    # Warning (yellow, if present)
    if [[ -n "$warning" ]]; then
        printf "\n  ${C_BYELLOW}${C_BOLD}%s${C_RESET}\n" "$warning" >/dev/tty
    fi

    printf "\n" >/dev/tty

    # ── Interactive Yes/No/Amend selector ──
    _ui_raw_mode_on

    local selected=0  # 0=Yes, 1=No
    local options=("Yes" "No")

    _ui_tc_render() {
        printf "  ${C_BOLD}Do you want to proceed?${C_RESET}\n" >/dev/tty
        local i=0
        while (( i < 2 )); do
            if (( i == selected )); then
                printf "  ${C_BCYAN}${IC_ARROW}${C_RESET}${C_BOLD} %s. %s${C_RESET}\n" "$((i+1))" "${options[$i]}" >/dev/tty
            else
                printf "     ${C_DIM}%s. %s${C_RESET}\n" "$((i+1))" "${options[$i]}" >/dev/tty
            fi
            i=$((i + 1))
        done
        printf "\n  ${C_DIM}Esc to cancel${C_RESET}" >/dev/tty
        if [[ "$label" == "Bash command" ]]; then
            printf "${C_DIM} · Tab to amend${C_RESET}" >/dev/tty
        fi
        printf "\n" >/dev/tty
    }

    _ui_tc_clear() {
        # question + 2 options + hints = 4 lines, + blank line = 5
        local lines=5
        local l=0
        while (( l < lines )); do
            printf '\033[A\033[K' >/dev/tty
            l=$((l + 1))
        done
    }

    _ui_tc_render

    while true; do
        local key
        _ui_read_key; key="$_UI_KEY"

        case "$key" in
            up|k|1)
                if (( selected != 0 )); then
                    _ui_tc_clear
                    selected=0
                    _ui_tc_render
                fi
                ;;
            down|j|2)
                if (( selected != 1 )); then
                    _ui_tc_clear
                    selected=1
                    _ui_tc_render
                fi
                ;;
            enter)
                _ui_tc_clear
                _ui_raw_mode_off
                if (( selected == 0 )); then
                    printf "  ${C_BGREEN}${IC_OK} Proceeding${C_RESET}\n" >/dev/tty
                    return 0
                else
                    printf "  ${C_DIM}Cancelled${C_RESET}\n" >/dev/tty
                    return 1
                fi
                ;;
            y|Y)
                _ui_tc_clear
                _ui_raw_mode_off
                printf "  ${C_BGREEN}${IC_OK} Proceeding${C_RESET}\n" >/dev/tty
                return 0
                ;;
            n|N|esc|q)
                _ui_tc_clear
                _ui_raw_mode_off
                printf "  ${C_DIM}Cancelled${C_RESET}\n" >/dev/tty
                return 1
                ;;
            tab)
                # Amend: let user edit the command (bash commands only)
                if [[ "$label" == "Bash command" ]]; then
                    _ui_tc_clear
                    _ui_raw_mode_off
                    printf "  ${C_CYAN}Amend command ${C_DIM}(edit and press Enter):${C_RESET}\n" >/dev/tty
                    printf "  ${C_BGREEN}>${C_RESET} " >/dev/tty
                    local amended_cmd
                    read -r -e -i "$content" amended_cmd </dev/tty
                    if [[ -n "$amended_cmd" && "$amended_cmd" != "$content" ]]; then
                        _UI_AMENDED_CMD="$amended_cmd"
                        printf "  ${C_BGREEN}${IC_OK} Command amended${C_RESET}\n" >/dev/tty
                    else
                        printf "  ${C_DIM}No changes${C_RESET}\n" >/dev/tty
                    fi
                    return 0
                fi
                ;;
        esac
    done
}

# ── Spinner ───────────────────────────────────────────
SPINNER_PID=""

spinner_start() {
    local msg="${1:-thinking}"
    (
        local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
        local i=0
        while true; do
            printf "\r${C_DIM}  %s ${C_CYAN}%s${C_RESET}" "${frames[$((i % ${#frames[@]}))]}" "$msg"
            sleep 0.1
            i=$((i + 1))
        done
    ) &
    SPINNER_PID=$!
    disown "$SPINNER_PID" 2>/dev/null
}

spinner_stop() {
    if [[ -n "$SPINNER_PID" ]]; then
        kill "$SPINNER_PID" 2>/dev/null
        wait "$SPINNER_PID" 2>/dev/null
        SPINNER_PID=""
        printf "\r\033[K"
    fi
}

# ── Banner ────────────────────────────────────────────

ui_banner() {
    local model="$1"
    local model_short
    model_short=$(basename "$(get_model_path "$model" 2>/dev/null)" .gguf 2>/dev/null) || model_short="$model"

    printf "\n"
    printf "  ${C_BMAGENTA}╦  ╔═╗ ╔╗╔ ╔═╗${C_RESET}  ${C_BCYAN}╔═╗ ╔═╗ ╔╦╗ ╔═╗${C_RESET}\n"
    printf "  ${C_BMAGENTA}║  ╠═╣ ║║║ ╠═╣${C_RESET}  ${C_BCYAN}║   ║ ║  ║║ ║╣${C_RESET}\n"
    printf "  ${C_BMAGENTA}╩═╝╩ ╩ ╝╚╝ ╩ ╩${C_RESET}  ${C_BCYAN}╚═╝ ╚═╝ ═╩╝ ╚═╝${C_RESET}\n"
    printf "\n"

    # Info line in a subtle box
    local info_body=""
    local dir_name
    dir_name="$(basename "${WORK_DIR:-$PWD}")"
    info_body="${C_DIM}v0.3.0${C_RESET}  ${C_DIM}${BOX_V}${C_RESET}  ${C_CYAN}${model_short}${C_RESET}  ${C_DIM}${BOX_V}${C_RESET}  ${C_DIM}${CONTEXT_SIZE} ctx${C_RESET}  ${C_DIM}${BOX_V}${C_RESET}  ${C_BBLUE}${dir_name}${C_RESET}"
    if [[ "${USE_PROXY:-false}" == "true" ]]; then
        info_body="${info_body}  ${C_DIM}${BOX_V}${C_RESET}  ${C_GREEN}proxy${C_RESET}"
    fi
    printf "  %b\n" "$info_body"

    if [[ "${ACCEPT_MODE:-confirm}" != "confirm" ]]; then
        printf "  ${C_YELLOW}${IC_WARN} accept: %s${C_RESET}\n" "$ACCEPT_MODE"
    fi

    printf "\n"
    printf "  ${C_DIM}Type ${C_RESET}${C_CYAN}/help${C_RESET}${C_DIM} for commands  ${BOX_V}  ${C_RESET}${C_CYAN}/quit${C_RESET}${C_DIM} to exit${C_RESET}\n"
    ui_hr "$BOX_H" "$C_DIM"
    printf "\n"
}

# ── Context Status Bar ────────────────────────────────
# Compact one-liner shown after each turn

ui_turn_footer() {
    local turn="$1" est_tokens="$2" context_size="$3" prompt_t="${4:-0}" completion_t="${5:-0}"
    local pct=$((est_tokens * 100 / context_size))

    printf "\n  ${C_DIM}${BOX_H}${BOX_H}${BOX_H}${C_RESET}" >/dev/tty
    printf " ${C_DIM}turn %s${C_RESET}" "$turn" >/dev/tty
    printf " ${C_DIM}${BOX_V}${C_RESET} " >/dev/tty

    # Progress bar (10-char wide)
    ui_progress_bar "$pct" 10 >/dev/tty

    printf " ${C_DIM}%s%%${C_RESET}" "$pct" >/dev/tty
    printf " ${C_DIM}(~%s tok)${C_RESET}" "$est_tokens" >/dev/tty
    printf "\n\n" >/dev/tty
}

# ── Help Menu ─────────────────────────────────────────

ui_help() {
    printf "\n"

    # Session commands
    local session_body=""
    session_body="${C_CYAN}/status${C_RESET}  ${C_DIM}${BOX_V}${C_RESET} Project status dashboard
${C_CYAN}/model${C_RESET}   ${C_DIM}${BOX_V}${C_RESET} Switch model ${C_DIM}[name]${C_RESET}
${C_CYAN}/compact${C_RESET} ${C_DIM}${BOX_V}${C_RESET} Compact conversation context
${C_CYAN}/clear${C_RESET}   ${C_DIM}${BOX_V}${C_RESET} Clear conversation
${C_CYAN}/debug${C_RESET}   ${C_DIM}${BOX_V}${C_RESET} Toggle debug mode ${C_DIM}(show API payloads & paths)${C_RESET}
${C_CYAN}/version${C_RESET} ${C_DIM}${BOX_V}${C_RESET} Show version info
${C_CYAN}/quit${C_RESET}    ${C_DIM}${BOX_V}${C_RESET} Exit"
    ui_box "Session" "$session_body" 50

    # Project commands
    local project_body=""
    project_body="${C_CYAN}/load${C_RESET}    ${C_DIM}${BOX_V}${C_RESET} Load project into context ${C_DIM}[path]${C_RESET}
${C_CYAN}/index${C_RESET}   ${C_DIM}${BOX_V}${C_RESET} Index project symbols ${C_DIM}[path]${C_RESET}
${C_CYAN}/search${C_RESET}  ${C_DIM}${BOX_V}${C_RESET} Search index ${C_DIM}<query>${C_RESET}
${C_CYAN}/cd${C_RESET}      ${C_DIM}${BOX_V}${C_RESET} Change working directory ${C_DIM}[path]${C_RESET}
${C_CYAN}/memory${C_RESET}  ${C_DIM}${BOX_V}${C_RESET} View/set project memories"
    ui_box "Project" "$project_body" 50

    # Workflow commands
    local workflow_body=""
    workflow_body="${C_CYAN}/plan${C_RESET}    ${C_DIM}${BOX_V}${C_RESET} Plan mode ${C_DIM}(read-only exploration)${C_RESET}
${C_CYAN}/fork${C_RESET}    ${C_DIM}${BOX_V}${C_RESET} Fork session ${C_DIM}[name]${C_RESET}
${C_CYAN}/undo${C_RESET}    ${C_DIM}${BOX_V}${C_RESET} Revert last file edit/write
${C_CYAN}/accept${C_RESET}  ${C_DIM}${BOX_V}${C_RESET} Permission mode ${C_DIM}[confirm|auto-edit|yolo]${C_RESET}
${C_CYAN}/subagent${C_RESET}${C_DIM}${BOX_V}${C_RESET} Spawn subagent ${C_DIM}<research|plan|execute> <task>${C_RESET}"
    ui_box "Workflow" "$workflow_body" 58

    # History commands
    local history_body=""
    history_body="${C_CYAN}/history${C_RESET} ${C_DIM}${BOX_V}${C_RESET} List past sessions ${C_DIM}[query]${C_RESET}
${C_CYAN}/recall${C_RESET}  ${C_DIM}${BOX_V}${C_RESET} Recall session context ${C_DIM}<id>${C_RESET}"
    ui_box "History" "$history_body" 50

    # Tools summary
    printf "\n"
    ui_divider "Tools (24)" "$C_DIM"
    printf "  ${IC_FILE} ${C_DIM}Files${C_RESET}     read_file  write_file  edit_file  file_tree  undo  batch_edit\n"
    printf "  ${IC_SEARCH} ${C_DIM}Search${C_RESET}    grep_search  glob_find  search_index  scaffold_search\n"
    printf "  ${IC_EXEC} ${C_DIM}Execute${C_RESET}   bash  run_background  test_run  diff_apply\n"
    printf "  ${IC_CODE} ${C_DIM}Code${C_RESET}      tree_parse  lsp_query  context_compress  web_fetch\n"
    printf "  ${IC_PLAN} ${C_DIM}Project${C_RESET}   project_detect  memory  git_smart  task_plan\n"
    printf "  ${IC_AGENT} ${C_DIM}Agent${C_RESET}     subagent ${C_DIM}(research, execute, plan)${C_RESET}  recall_turn\n"
    printf "  ${IC_NET} ${C_DIM}MCP${C_RESET}       external tools via ${C_DIM}.lana/mcp.json${C_RESET}\n"

    # Tips
    printf "\n"
    ui_divider "Tips" "$C_DIM"
    printf "  ${C_CYAN}@filepath${C_RESET}    Include file contents in your message\n"
    printf "  ${C_CYAN}Ctrl+C${C_RESET}       Interrupt current operation\n"
    printf "  ${C_CYAN}ESC${C_RESET}          Cancel streaming response\n"
    printf "\n"
}

# ── Status Dashboard ──────────────────────────────────

ui_status_dashboard() {
    local work_dir="$1" current_model="$2" session_turns="$3"

    printf "\n"

    # Project info
    local short_dir project_type=""
    short_dir=$(echo "$work_dir" | sed "s|^$HOME|~|")

    if [[ -f "$work_dir/package.json" ]]; then
        local deps
        deps=$(jq -r '(.dependencies // {}) + (.devDependencies // {}) | keys[]' "$work_dir/package.json" 2>/dev/null) || true
        if echo "$deps" | grep -q "^next$"; then project_type="Next.js"
        elif echo "$deps" | grep -q "^react$"; then project_type="React"
        elif echo "$deps" | grep -q "^vue$"; then project_type="Vue"
        elif echo "$deps" | grep -q "^svelte$"; then project_type="Svelte"
        else project_type="Node.js"; fi
        echo "$deps" | grep -q "^typescript$" && project_type="$project_type + TypeScript"
    elif [[ -f "$work_dir/Cargo.toml" ]]; then project_type="Rust"
    elif [[ -f "$work_dir/go.mod" ]]; then project_type="Go"
    elif [[ -f "$work_dir/Package.swift" ]]; then project_type="Swift"
    elif [[ -f "$work_dir/requirements.txt" || -f "$work_dir/pyproject.toml" ]]; then project_type="Python"
    elif [[ -f "$work_dir/Makefile" ]]; then project_type="Make"
    fi

    # Build status body
    local body=""

    # Project
    body="${C_DIM}Project${C_RESET}   ${C_BOLD}${short_dir}${C_RESET}"
    if [[ -n "$project_type" ]]; then
        body="${body}  ${C_DIM}(${project_type})${C_RESET}"
    fi

    # Git
    if [[ -d "$work_dir/.git" ]]; then
        local branch uncommitted
        branch=$(cd "$work_dir" && git rev-parse --abbrev-ref HEAD 2>/dev/null) || branch=""
        uncommitted=$(cd "$work_dir" && git status --porcelain 2>/dev/null | wc -l | tr -d ' ') || uncommitted=0
        if [[ -n "$branch" ]]; then
            body="${body}
${C_DIM}Branch${C_RESET}    ${IC_GIT} ${C_GREEN}${branch}${C_RESET}"
            if [[ "$uncommitted" -gt 0 ]]; then
                body="${body}  ${C_YELLOW}${uncommitted} changed${C_RESET}"
            fi
        fi
    fi

    # Model
    local model_file
    model_file=$(basename "$(get_model_path "$current_model")" .gguf 2>/dev/null) || model_file="$current_model"
    body="${body}
${C_DIM}Model${C_RESET}     ${C_CYAN}${model_file}${C_RESET}"

    # Context usage with progress bar
    local est_tokens context_pct
    est_tokens=$(state_estimate_tokens 2>/dev/null) || est_tokens=0
    context_pct=$((est_tokens * 100 / CONTEXT_SIZE))
    body="${body}
${C_DIM}Context${C_RESET}   $(ui_progress_bar "$context_pct" 15) ${C_DIM}${context_pct}%${C_RESET}  ${C_DIM}(~${est_tokens} / ${CONTEXT_SIZE})${C_RESET}"

    # Memories
    local memory_file="$work_dir/.lana/memory.json"
    local mem_count=0
    if [[ -f "$memory_file" ]]; then
        mem_count=$(jq 'length' "$memory_file" 2>/dev/null) || mem_count=0
    fi
    body="${body}
${C_DIM}Memories${C_RESET}  ${IC_MEM} ${mem_count} entries"

    # Plan
    local plan_file="$work_dir/.lana/current_plan.json"
    if [[ -f "$plan_file" ]]; then
        local plan_title total_steps completed_steps
        plan_title=$(jq -r '.title // empty' "$plan_file" 2>/dev/null)
        total_steps=$(jq '.steps | length' "$plan_file" 2>/dev/null) || total_steps=0
        completed_steps=$(jq '[.steps[] | select(.status == "done")] | length' "$plan_file" 2>/dev/null) || completed_steps=0
        if [[ -n "$plan_title" && "$total_steps" -gt 0 ]]; then
            body="${body}
${C_DIM}Plan${C_RESET}      ${IC_PLAN} ${completed_steps}/${total_steps} — ${plan_title}"
        fi
    fi

    # Session
    local files_count=0
    if [[ -n "${SESSION_FILES_TOUCHED:-}" ]]; then
        files_count=$(printf '%s' "$SESSION_FILES_TOUCHED" | tr '|' '\n' | sort -u | wc -l | tr -d ' ')
    fi
    body="${body}
${C_DIM}Session${C_RESET}   ${session_turns} turns  ${C_DIM}${BOX_V}${C_RESET}  ${files_count} files touched"

    # Accept mode + plan mode
    body="${body}
${C_DIM}Accept${C_RESET}    ${ACCEPT_MODE}"
    if [[ "${PLAN_MODE:-false}" == "true" ]]; then
        body="${body}  ${C_DIM}${BOX_V}${C_RESET}  ${C_YELLOW}PLAN MODE (read-only)${C_RESET}"
    fi

    ui_box "Status" "$body" 70 "$C_DIM"
    printf "\n"
}

# ── Quick Command List ────────────────────────────────
# Shown when user types just "/" and presses enter

ui_show_commands() {
    printf "\n"
    printf "  ${C_CYAN}/status${C_RESET}  ${C_DIM}dashboard${C_RESET}     ${C_CYAN}/model${C_RESET}   ${C_DIM}switch${C_RESET}       ${C_CYAN}/memory${C_RESET}  ${C_DIM}memories${C_RESET}\n"
    printf "  ${C_CYAN}/load${C_RESET}    ${C_DIM}load project${C_RESET}  ${C_CYAN}/index${C_RESET}   ${C_DIM}index project${C_RESET}  ${C_CYAN}/search${C_RESET}  ${C_DIM}search index${C_RESET}\n"
    printf "  ${C_CYAN}/plan${C_RESET}    ${C_DIM}plan mode${C_RESET}     ${C_CYAN}/fork${C_RESET}    ${C_DIM}fork session${C_RESET}   ${C_CYAN}/undo${C_RESET}    ${C_DIM}revert edit${C_RESET}\n"
    printf "  ${C_CYAN}/compact${C_RESET} ${C_DIM}compress ctx${C_RESET}  ${C_CYAN}/clear${C_RESET}   ${C_DIM}clear chat${C_RESET}     ${C_CYAN}/quit${C_RESET}    ${C_DIM}exit${C_RESET}\n"
    printf "\n"
}

# ── Markdown-lite Rendering ──────────────────────────

render_markdown() {
    local text="$1"
    local in_code_block=false
    local lang=""

    while IFS= read -r line; do
        if [[ "$line" =~ ^\`\`\` ]]; then
            if $in_code_block; then
                printf "${C_RESET}"
                printf "  ${C_DIM}${BOX_BL}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${C_RESET}\n"
                in_code_block=false
            else
                lang="${line#\`\`\`}"
                if [[ -n "$lang" ]]; then
                    printf "  ${C_DIM}${BOX_TL}${BOX_H}${BOX_H} %s ${BOX_H}${BOX_H}${BOX_H}${C_RESET}\n" "$lang"
                else
                    printf "  ${C_DIM}${BOX_TL}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${C_RESET}\n"
                fi
                in_code_block=true
            fi
            continue
        fi

        if $in_code_block; then
            printf "  ${C_DIM}${BOX_V}${C_RESET} ${C_GREEN}%s${C_RESET}\n" "$line"
        else
            # Bold: **text**
            line=$(echo "$line" | sed 's/\*\*\([^*]*\)\*\*/\\033[1m\1\\033[0m/g')
            # Inline code: `text`
            line=$(echo "$line" | sed 's/`\([^`]*\)`/\\033[0;36m\1\\033[0m/g')
            # Headers
            if [[ "$line" =~ ^###\  ]]; then
                printf "  ${C_BOLD}${C_CYAN}   %s${C_RESET}\n" "${line#*### }"
            elif [[ "$line" =~ ^##\  ]]; then
                printf "  ${C_BOLD}${C_CYAN}  %s${C_RESET}\n" "${line#*## }"
            elif [[ "$line" =~ ^#\  ]]; then
                printf "\n  ${C_BOLD}${C_CYAN} %s${C_RESET}\n" "${line#*# }"
            # Bullet points
            elif [[ "$line" =~ ^[[:space:]]*[-\*]\  ]]; then
                printf "  ${C_DIM}  •${C_RESET} %b\n" "${line#*- }"
            else
                printf "  %b\n" "$line"
            fi
        fi
    done <<< "$text"

    # Close unclosed code block
    $in_code_block && printf "  ${C_DIM}${BOX_BL}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${C_RESET}\n"
}

# ── Readline: input history & tab completion ─────────

# Command list for tab completion
LANA_COMMANDS="/quit /exit /clear /model /load /cd /index /search /status /memory /history /recall /compact /plan /accept /debug /version /help /fork /undo"

ui_setup_readline() {
    mkdir -p "$(dirname "$LANA_INPUT_HISTORY")"

    if [[ -f "$LANA_INPUT_HISTORY" ]]; then
        local line
        while IFS= read -r line; do
            history -s "$line"
        done < "$LANA_INPUT_HISTORY"
    fi

    # Tab completion
    if ((BASH_VERSINFO[0] >= 4)); then
        bind -x '"\t": _lana_tab_complete' 2>/dev/null || true
    else
        bind '"\t": ""' 2>/dev/null || true
    fi
}

_lana_tab_complete() {
    local cur="$READLINE_LINE"
    [[ "$cur" != /* ]] && return

    local matches=()
    for cmd in $LANA_COMMANDS; do
        [[ "$cmd" == "$cur"* ]] && matches+=("$cmd")
    done

    if [[ ${#matches[@]} -eq 0 ]]; then
        return
    elif [[ ${#matches[@]} -eq 1 ]]; then
        READLINE_LINE="${matches[0]} "
        READLINE_POINT=${#READLINE_LINE}
    else
        printf "\n"
        for m in "${matches[@]}"; do
            printf "  ${C_CYAN}%s${C_RESET}  " "$m"
        done
        printf "\n${C_BGREEN}>${C_RESET} %s" "$cur"
    fi
}

# Add input to readline history and persist
ui_add_to_history() {
    local line="$1"
    [[ -z "$line" ]] && return
    history -s "$line"
    printf '%s\n' "$line" >> "$LANA_INPUT_HISTORY"

    if [[ -f "$LANA_INPUT_HISTORY" ]]; then
        local count
        count=$(wc -l < "$LANA_INPUT_HISTORY" | tr -d ' ')
        if (( count > LANA_INPUT_HISTORY_SIZE )); then
            local tmp="${LANA_INPUT_HISTORY}.tmp"
            tail -n "$LANA_INPUT_HISTORY_SIZE" "$LANA_INPUT_HISTORY" > "$tmp" && mv "$tmp" "$LANA_INPUT_HISTORY"
        fi
    fi
}

# ══════════════════════════════════════════════════════
# Interactive Components — raw terminal, arrow keys, ESC
# All read/write to /dev/tty for subshell compatibility
# ══════════════════════════════════════════════════════

# ── Raw terminal mode helpers ─────────────────────────

_ui_raw_mode_on() {
    _UI_SAVED_STTY=$(stty -g </dev/tty 2>/dev/null) || true
    stty -echo -icanon min 1 time 0 </dev/tty 2>/dev/null || true
    # Hide cursor
    printf '\033[?25l' >/dev/tty
}

_ui_raw_mode_off() {
    # Show cursor
    printf '\033[?25h' >/dev/tty
    if [[ -n "${_UI_SAVED_STTY:-}" ]]; then
        stty "$_UI_SAVED_STTY" </dev/tty 2>/dev/null || true
    fi
}

# Read a single keypress — sets _UI_KEY to:
#   "up" "down" "left" "right" "enter" "esc" "tab" "backspace" or the character
# Uses a global variable instead of stdout to avoid subshell overhead
# (subshells can cause timing issues reading multi-byte escape sequences)
_UI_KEY=""
_ui_read_key() {
    local c
    IFS= read -r -n1 c </dev/tty 2>/dev/null || true

    if [[ -z "$c" ]]; then
        _UI_KEY="enter"
        return
    fi

    # ESC sequence
    if [[ "$c" == $'\x1b' ]]; then
        local seq=""
        # Try to read 2 more chars (arrow keys are ESC [ A/B/C/D)
        IFS= read -r -n1 -t 0.2 seq </dev/tty 2>/dev/null || true
        if [[ "$seq" == "[" ]]; then
            local arrow=""
            IFS= read -r -n1 -t 0.2 arrow </dev/tty 2>/dev/null || true
            case "$arrow" in
                A) _UI_KEY="up"; return ;;
                B) _UI_KEY="down"; return ;;
                C) _UI_KEY="right"; return ;;
                D) _UI_KEY="left"; return ;;
                H) _UI_KEY="home"; return ;;
                F) _UI_KEY="end"; return ;;
            esac
        fi
        _UI_KEY="esc"
        return
    fi

    # Tab
    if [[ "$c" == $'\t' ]]; then
        _UI_KEY="tab"
        return
    fi

    # Backspace (both 127 and ^H)
    if [[ "$c" == $'\x7f' || "$c" == $'\x08' ]]; then
        _UI_KEY="backspace"
        return
    fi

    # Regular character
    _UI_KEY="$c"
}


# ── Select Menu ───────────────────────────────────────
# Usage: result=$(ui_select "Title" "option1" "option2" "option3")
# Returns: selected option text, or "" if cancelled
# Supports: up/down arrows, j/k vim keys, enter to select, esc/q to cancel

ui_select() {
    local title="$1"
    shift
    local items=("$@")
    local count=${#items[@]}
    local selected=0
    local max_visible=10
    local scroll_offset=0

    if (( count == 0 )); then
        return 1
    fi

    _ui_raw_mode_on
    trap '_ui_raw_mode_off' EXIT INT TERM

    # Calculate visible window
    local visible=$count
    (( visible > max_visible )) && visible=$max_visible

    # Draw initial menu
    printf '\n' >/dev/tty
    if [[ -n "$title" ]]; then
        printf "  ${C_BOLD}%s${C_RESET} ${C_DIM}(↑↓ navigate, enter select, esc cancel)${C_RESET}\n" "$title" >/dev/tty
    fi

    # Render function
    _ui_select_render() {
        local sel="$1" offset="$2"
        local i end
        end=$((offset + visible))
        (( end > count )) && end=$count

        # Scroll indicator top
        if (( offset > 0 )); then
            printf "  ${C_DIM}  ↑ %s more${C_RESET}\n" "$offset" >/dev/tty
        fi

        i=$offset
        while (( i < end )); do
            if (( i == sel )); then
                printf "  ${C_BCYAN}${IC_ARROW}${C_RESET} ${C_BOLD}${C_CYAN}%s${C_RESET}\n" "${items[$i]}" >/dev/tty
            else
                printf "    ${C_DIM}%s${C_RESET}\n" "${items[$i]}" >/dev/tty
            fi
            i=$((i + 1))
        done

        # Scroll indicator bottom
        if (( end < count )); then
            printf "  ${C_DIM}  ↓ %s more${C_RESET}\n" "$((count - end))" >/dev/tty
        fi
    }

    # Lines to clear: title + visible items + possible scroll indicators
    _ui_select_clear() {
        local lines=$((visible + 1))
        (( scroll_offset > 0 )) && lines=$((lines + 1))
        local end=$((scroll_offset + visible))
        (( end < count )) && lines=$((lines + 1))

        # Move up and clear each line
        local l=0
        while (( l < lines )); do
            printf '\033[A\033[K' >/dev/tty
            l=$((l + 1))
        done
    }

    _ui_select_render "$selected" "$scroll_offset"

    while true; do
        local key
        _ui_read_key; key="$_UI_KEY"

        case "$key" in
            up|k)
                if (( selected > 0 )); then
                    _ui_select_clear
                    selected=$((selected - 1))
                    # Adjust scroll
                    if (( selected < scroll_offset )); then
                        scroll_offset=$selected
                    fi
                    _ui_select_render "$selected" "$scroll_offset"
                fi
                ;;
            down|j)
                if (( selected < count - 1 )); then
                    _ui_select_clear
                    selected=$((selected + 1))
                    # Adjust scroll
                    if (( selected >= scroll_offset + visible )); then
                        scroll_offset=$((selected - visible + 1))
                    fi
                    _ui_select_render "$selected" "$scroll_offset"
                fi
                ;;
            home)
                _ui_select_clear
                selected=0
                scroll_offset=0
                _ui_select_render "$selected" "$scroll_offset"
                ;;
            "end")
                _ui_select_clear
                selected=$((count - 1))
                scroll_offset=$((count - visible))
                (( scroll_offset < 0 )) && scroll_offset=0
                _ui_select_render "$selected" "$scroll_offset"
                ;;
            enter)
                _ui_select_clear
                _ui_raw_mode_off
                trap - EXIT INT TERM
                printf "  ${C_BCYAN}${IC_OK} %s${C_RESET}\n" "${items[$selected]}" >/dev/tty
                echo "${items[$selected]}"
                return 0
                ;;
            esc|q)
                _ui_select_clear
                _ui_raw_mode_off
                trap - EXIT INT TERM
                printf "  ${C_DIM}cancelled${C_RESET}\n" >/dev/tty
                echo ""
                return 1
                ;;
        esac
    done
}

# ── File Picker ───────────────────────────────────────
# Usage: result=$(ui_file_picker "/path/to/dir" "filter_pattern")
# Returns: selected file path, or "" if cancelled
# Supports: up/down to navigate, enter to select file, right/enter on dir to descend,
#           left/backspace to go up, tab to toggle dirs-only, esc to cancel
# Filter: optional glob pattern like "*.sh" or "*.py"

ui_file_picker() {
    local start_dir="${1:-$PWD}"
    local filter="${2:-}"
    local current_dir="$start_dir"
    local selected=0
    local max_visible=15

    _ui_raw_mode_on
    trap '_ui_raw_mode_off' EXIT INT TERM

    _ui_fp_list_entries() {
        local dir="$1" filt="$2"
        local entries=()

        # Always show .. unless at filesystem root
        if [[ "$dir" != "/" ]]; then
            entries+=("..")
        fi

        # Directories first (sorted)
        local d
        while IFS= read -r d; do
            [[ -n "$d" ]] && entries+=("${d}/")
        done < <(ls -1 "$dir" 2>/dev/null | while IFS= read -r name; do
            [[ -d "$dir/$name" ]] && echo "$name"
        done | sort)

        # Files (filtered, sorted)
        local f
        while IFS= read -r f; do
            if [[ -n "$f" ]]; then
                if [[ -z "$filt" ]]; then
                    entries+=("$f")
                else
                    case "$f" in
                        $filt) entries+=("$f") ;;
                    esac
                fi
            fi
        done < <(ls -1 "$dir" 2>/dev/null | while IFS= read -r name; do
            [[ -f "$dir/$name" ]] && echo "$name"
        done | sort)

        # Output entries (newline-separated for safe reading)
        local e
        for e in "${entries[@]}"; do
            printf '%s\n' "$e"
        done
    }

    _ui_fp_render() {
        local sel="$1" offset="$2" total="$3"
        local short_dir
        short_dir=$(echo "$current_dir" | sed "s|^$HOME|~|")

        # Header
        printf "  ${C_DIM}${BOX_TL}${BOX_H}${BOX_H}${C_RESET} ${C_BOLD}%s${C_RESET}\n" "$short_dir" >/dev/tty
        if [[ -n "$filter" ]]; then
            printf "  ${C_DIM}${BOX_V}  filter: %s${C_RESET}\n" "$filter" >/dev/tty
        fi

        local visible=$total
        (( visible > max_visible )) && visible=$max_visible

        # Scroll indicator top
        if (( offset > 0 )); then
            printf "  ${C_DIM}${BOX_V}  ↑ %s more${C_RESET}\n" "$offset" >/dev/tty
        fi

        local i end
        end=$((offset + visible))
        (( end > total )) && end=$total

        i=$offset
        while (( i < end )); do
            local entry="${_fp_entries[$i]}"
            local icon=""
            local color="$C_RESET"

            if [[ "$entry" == ".." ]]; then
                icon="↩ "
                color="$C_DIM"
            elif [[ "$entry" == */ ]]; then
                icon=" "
                color="$C_BBLUE"
            else
                # File icon by extension
                local ext="${entry##*.}"
                case "$ext" in
                    sh|bash|zsh)  icon=" "; color="$C_GREEN" ;;
                    py)           icon=" "; color="$C_YELLOW" ;;
                    js|ts|jsx|tsx) icon=" "; color="$C_BYELLOW" ;;
                    rs)           icon=" "; color="$C_RED" ;;
                    go)           icon=" "; color="$C_CYAN" ;;
                    swift)        icon=" "; color="$C_YELLOW" ;;
                    json|yaml|yml|toml) icon=" "; color="$C_DIM" ;;
                    md|txt)       icon=" "; color="$C_DIM" ;;
                    *)            icon=" "; color="$C_DIM" ;;
                esac
            fi

            if (( i == sel )); then
                printf "  ${C_DIM}${BOX_V}${C_RESET} ${C_BCYAN}${IC_ARROW}${C_RESET}${color}${C_BOLD} ${icon}%s${C_RESET}\n" "$entry" >/dev/tty
            else
                printf "  ${C_DIM}${BOX_V}${C_RESET}   ${color} ${icon}%s${C_RESET}\n" "$entry" >/dev/tty
            fi
            i=$((i + 1))
        done

        # Scroll indicator bottom
        if (( end < total )); then
            printf "  ${C_DIM}${BOX_V}  ↓ %s more${C_RESET}\n" "$((total - end))" >/dev/tty
        fi

        # Footer
        printf "  ${C_DIM}${BOX_BL}${BOX_H}${BOX_H} ↑↓ navigate  enter select  ← back  esc cancel${C_RESET}\n" >/dev/tty
    }

    _ui_fp_clear() {
        local total="$1"
        local visible=$total
        (( visible > max_visible )) && visible=$max_visible

        # header + items + footer + optional filter + optional scroll indicators
        local lines=$((visible + 2))  # header + items + footer
        [[ -n "$filter" ]] && lines=$((lines + 1))
        (( _fp_offset > 0 )) && lines=$((lines + 1))
        local end=$((_fp_offset + visible))
        (( end > total )) && end=$total
        # Bottom scroll indicator
        (( end < total )) && lines=$((lines + 1))

        local l=0
        while (( l < lines )); do
            printf '\033[A\033[K' >/dev/tty
            l=$((l + 1))
        done
    }

    # Main loop
    local _fp_offset=0
    local _fp_entries=()

    while true; do
        # Build entry list
        _fp_entries=()
        while IFS= read -r line; do
            _fp_entries+=("$line")
        done < <(_ui_fp_list_entries "$current_dir" "$filter")

        local total=${#_fp_entries[@]}
        if (( total == 0 )); then
            _fp_entries+=("..")
            total=1
        fi

        # Reset selection if out of bounds
        (( selected >= total )) && selected=$((total - 1))
        (( selected < 0 )) && selected=0
        _fp_offset=0

        local visible=$total
        (( visible > max_visible )) && visible=$max_visible

        printf '\n' >/dev/tty
        _ui_fp_render "$selected" "$_fp_offset" "$total"

        while true; do
            local key
            _ui_read_key; key="$_UI_KEY"

            case "$key" in
                up|k)
                    if (( selected > 0 )); then
                        _ui_fp_clear "$total"
                        selected=$((selected - 1))
                        if (( selected < _fp_offset )); then
                            _fp_offset=$selected
                        fi
                        _ui_fp_render "$selected" "$_fp_offset" "$total"
                    fi
                    ;;
                down|j)
                    if (( selected < total - 1 )); then
                        _ui_fp_clear "$total"
                        selected=$((selected + 1))
                        if (( selected >= _fp_offset + visible )); then
                            _fp_offset=$((selected - visible + 1))
                        fi
                        _ui_fp_render "$selected" "$_fp_offset" "$total"
                    fi
                    ;;
                enter|right)
                    local entry="${_fp_entries[$selected]}"
                    if [[ "$entry" == ".." ]]; then
                        # Go up
                        _ui_fp_clear "$total"
                        current_dir=$(dirname "$current_dir")
                        selected=0
                        _fp_offset=0
                        break  # rebuild entry list
                    elif [[ "$entry" == */ ]]; then
                        # Enter directory
                        _ui_fp_clear "$total"
                        current_dir="$current_dir/${entry%/}"
                        selected=0
                        _fp_offset=0
                        break  # rebuild entry list
                    else
                        # Select file
                        _ui_fp_clear "$total"
                        _ui_raw_mode_off
                        trap - EXIT INT TERM
                        local full_path="$current_dir/$entry"
                        printf "  ${C_BCYAN}${IC_OK} %s${C_RESET}\n" "$entry" >/dev/tty
                        echo "$full_path"
                        return 0
                    fi
                    ;;
                left|backspace)
                    # Go up a directory
                    if [[ "$current_dir" != "/" ]]; then
                        _ui_fp_clear "$total"
                        current_dir=$(dirname "$current_dir")
                        selected=0
                        _fp_offset=0
                        break  # rebuild entry list
                    fi
                    ;;
                esc|q)
                    _ui_fp_clear "$total"
                    _ui_raw_mode_off
                    trap - EXIT INT TERM
                    printf "  ${C_DIM}cancelled${C_RESET}\n" >/dev/tty
                    echo ""
                    return 1
                    ;;
            esac
        done
    done
}

# ── Search/Filter Select ─────────────────────────────
# Like ui_select but with a type-to-filter search box
# Usage: result=$(ui_search_select "Title" "item1" "item2" ...)
# Returns: selected item text, or "" if cancelled

ui_search_select() {
    local title="$1"
    shift
    local all_items=("$@")
    local query=""
    local selected=0
    local max_visible=10
    local scroll_offset=0

    if (( ${#all_items[@]} == 0 )); then
        return 1
    fi

    _ui_raw_mode_on
    trap '_ui_raw_mode_off' EXIT INT TERM

    # Filter items by query
    _ui_ss_filter() {
        local q="$1"
        local item
        _ss_filtered=()
        for item in "${all_items[@]}"; do
            if [[ -z "$q" ]]; then
                _ss_filtered+=("$item")
            else
                # Case-insensitive substring match
                local lower_item lower_q
                lower_item=$(printf '%s' "$item" | tr '[:upper:]' '[:lower:]')
                lower_q=$(printf '%s' "$q" | tr '[:upper:]' '[:lower:]')
                if [[ "$lower_item" == *"$lower_q"* ]]; then
                    _ss_filtered+=("$item")
                fi
            fi
        done
    }

    _ui_ss_render() {
        local sel="$1" offset="$2"
        local count=${#_ss_filtered[@]}
        local visible=$count
        (( visible > max_visible )) && visible=$max_visible

        # Title
        if [[ -n "$title" ]]; then
            printf "  ${C_BOLD}%s${C_RESET}\n" "$title" >/dev/tty
        fi

        # Search box
        printf "  ${C_DIM}${BOX_TL}${BOX_H}${C_RESET} ${C_BCYAN}%s${C_RESET}" "$query" >/dev/tty
        printf "${C_DIM}▌${C_RESET}\n" >/dev/tty

        if (( count == 0 )); then
            printf "  ${C_DIM}${BOX_V}  no matches${C_RESET}\n" >/dev/tty
        else
            # Scroll indicator top
            if (( offset > 0 )); then
                printf "  ${C_DIM}${BOX_V}  ↑ %s more${C_RESET}\n" "$offset" >/dev/tty
            fi

            local i end
            end=$((offset + visible))
            (( end > count )) && end=$count
            i=$offset
            while (( i < end )); do
                if (( i == sel )); then
                    printf "  ${C_DIM}${BOX_V}${C_RESET} ${C_BCYAN}${IC_ARROW}${C_RESET} ${C_BOLD}${C_CYAN}%s${C_RESET}\n" "${_ss_filtered[$i]}" >/dev/tty
                else
                    printf "  ${C_DIM}${BOX_V}${C_RESET}    ${C_DIM}%s${C_RESET}\n" "${_ss_filtered[$i]}" >/dev/tty
                fi
                i=$((i + 1))
            done

            # Scroll indicator bottom
            if (( end < count )); then
                printf "  ${C_DIM}${BOX_V}  ↓ %s more${C_RESET}\n" "$((count - end))" >/dev/tty
            fi
        fi

        printf "  ${C_DIM}${BOX_BL}${BOX_H}${BOX_H} type to filter  ↑↓ navigate  enter select  esc cancel${C_RESET}\n" >/dev/tty
    }

    _ui_ss_clear() {
        local count=${#_ss_filtered[@]}
        local visible=$count
        (( visible > max_visible )) && visible=$max_visible
        (( count == 0 )) && visible=1  # "no matches" line

        # title + search box + items + footer + scroll indicators
        local lines=$((visible + 3))  # title + search + items + footer
        (( scroll_offset > 0 )) && lines=$((lines + 1))
        local end=$((scroll_offset + visible))
        (( end > count )) && end=$count
        (( end < count )) && lines=$((lines + 1))

        local l=0
        while (( l < lines )); do
            printf '\033[A\033[K' >/dev/tty
            l=$((l + 1))
        done
    }

    local _ss_filtered=()
    _ui_ss_filter "$query"

    printf '\n' >/dev/tty
    _ui_ss_render "$selected" "$scroll_offset"

    while true; do
        local key
        _ui_read_key; key="$_UI_KEY"
        local count=${#_ss_filtered[@]}
        local visible=$count
        (( visible > max_visible )) && visible=$max_visible

        case "$key" in
            up|k)
                if (( selected > 0 )); then
                    _ui_ss_clear
                    selected=$((selected - 1))
                    (( selected < scroll_offset )) && scroll_offset=$selected
                    _ui_ss_render "$selected" "$scroll_offset"
                fi
                ;;
            down|j)
                if (( selected < count - 1 )); then
                    _ui_ss_clear
                    selected=$((selected + 1))
                    (( selected >= scroll_offset + visible )) && scroll_offset=$((selected - visible + 1))
                    _ui_ss_render "$selected" "$scroll_offset"
                fi
                ;;
            enter)
                if (( count > 0 )); then
                    _ui_ss_clear
                    _ui_raw_mode_off
                    trap - EXIT INT TERM
                    printf "  ${C_BCYAN}${IC_OK} %s${C_RESET}\n" "${_ss_filtered[$selected]}" >/dev/tty
                    echo "${_ss_filtered[$selected]}"
                    return 0
                fi
                ;;
            esc)
                _ui_ss_clear
                _ui_raw_mode_off
                trap - EXIT INT TERM
                printf "  ${C_DIM}cancelled${C_RESET}\n" >/dev/tty
                echo ""
                return 1
                ;;
            backspace)
                if [[ -n "$query" ]]; then
                    _ui_ss_clear
                    query="${query%?}"
                    _ui_ss_filter "$query"
                    selected=0
                    scroll_offset=0
                    _ui_ss_render "$selected" "$scroll_offset"
                fi
                ;;
            tab)
                ;; # ignore
            *)
                # Type character into search
                if [[ ${#key} -eq 1 ]] && [[ "$key" =~ [[:print:]] ]]; then
                    _ui_ss_clear
                    query="${query}${key}"
                    _ui_ss_filter "$query"
                    selected=0
                    scroll_offset=0
                    _ui_ss_render "$selected" "$scroll_offset"
                fi
                ;;
        esac
    done
}

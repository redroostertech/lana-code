#!/usr/bin/env bash
# Interactive UI test script — run directly in terminal
# Usage: bash test_interactive_ui.sh [test_name]
#   test_name: select, search, filepicker, all (default: all)

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/lib/ui.sh"

WORK_DIR="$SCRIPT_DIR"

test_select() {
    printf "\n${C_BOLD}${C_BCYAN}═══ Test 1: Basic Select Menu ═══${C_RESET}\n"
    printf "${C_DIM}Use arrow keys (or j/k) to navigate, Enter to select, ESC to cancel${C_RESET}\n"

    local result
    result=$(ui_select "Pick a color" "Red" "Green" "Blue" "Yellow" "Magenta" "Cyan" "White") || true

    if [[ -n "$result" ]]; then
        ui_success "You selected: $result"
    else
        ui_warn "Selection cancelled"
    fi
}

test_select_long() {
    printf "\n${C_BOLD}${C_BCYAN}═══ Test 2: Scrollable Select (20 items) ═══${C_RESET}\n"
    printf "${C_DIM}This list scrolls — notice ↑↓ indicators${C_RESET}\n"

    local items=()
    local i
    for i in $(seq 1 20); do
        items+=("Item $i — option number $i")
    done

    local result
    result=$(ui_select "Pick from 20 items" "${items[@]}") || true

    if [[ -n "$result" ]]; then
        ui_success "You selected: $result"
    else
        ui_warn "Selection cancelled"
    fi
}

test_search_select() {
    printf "\n${C_BOLD}${C_BCYAN}═══ Test 3: Search/Filter Select ═══${C_RESET}\n"
    printf "${C_DIM}Type to filter the list, arrows to navigate, Enter to select${C_RESET}\n"

    local result
    result=$(ui_search_select "Pick a model" \
        "Qwen2.5-Coder-14B-Instruct-Q5_K_M" \
        "Qwen3-Coder-30B-A3B-Instruct-Q4_K_M" \
        "DeepSeek-Coder-V2-Lite-Instruct" \
        "CodeLlama-34B-Instruct-GGUF" \
        "Mistral-7B-Instruct-v0.3" \
        "Phi-3-medium-128k-instruct" \
        "Gemma-2-27B-IT" \
        "Llama-3.1-70B-Instruct" \
        "StarCoder2-15B") || true

    if [[ -n "$result" ]]; then
        ui_success "You selected: $result"
    else
        ui_warn "Selection cancelled"
    fi
}

test_file_picker() {
    printf "\n${C_BOLD}${C_BCYAN}═══ Test 4: File Picker ═══${C_RESET}\n"
    printf "${C_DIM}Navigate: ↑↓ move, Enter/→ select/enter dir, ←/Backspace go up, ESC cancel${C_RESET}\n"

    local result
    result=$(ui_file_picker "$SCRIPT_DIR") || true

    if [[ -n "$result" ]]; then
        ui_success "You selected: $result"
        local size
        size=$(wc -c < "$result" 2>/dev/null | tr -d ' ')
        ui_dim "  Size: $size bytes"
    else
        ui_warn "Selection cancelled"
    fi
}

test_file_picker_filtered() {
    printf "\n${C_BOLD}${C_BCYAN}═══ Test 5: File Picker (*.sh filter) ═══${C_RESET}\n"
    printf "${C_DIM}Only .sh files are shown${C_RESET}\n"

    local result
    result=$(ui_file_picker "$SCRIPT_DIR" "*.sh") || true

    if [[ -n "$result" ]]; then
        ui_success "You selected: $result"
    else
        ui_warn "Selection cancelled"
    fi
}

test_model_select() {
    printf "\n${C_BOLD}${C_BCYAN}═══ Test 6: Model Selector (like /model) ═══${C_RESET}\n"

    local result
    result=$(ui_select "Switch model" $MODEL_NAMES) || true

    if [[ -n "$result" ]]; then
        ui_success "Model selected: $result"
        local path
        path=$(get_model_path "$result")
        ui_dim "  Path: $path"
    else
        ui_warn "Selection cancelled"
    fi
}

test_rich_confirm() {
    printf "\n${C_BOLD}${C_BCYAN}═══ Test: Rich Tool Confirmation (Bash) ═══${C_RESET}\n"
    printf "${C_DIM}Arrow keys to select Yes/No, Enter to confirm, Tab to amend, ESC to cancel${C_RESET}\n"

    ACCEPT_MODE="confirm"
    _PERM_OVERRIDE=""

    if ui_tool_confirm "Bash command" 'grep -n "^\s*work_dir=\"\$SESSION_DIR/indexer_\$\$\"" lib/project.sh' "Check specific variable initialization"; then
        if [[ -n "$_UI_AMENDED_CMD" ]]; then
            ui_success "Amended command: $_UI_AMENDED_CMD"
        else
            ui_success "Confirmed!"
        fi
    else
        ui_warn "Cancelled"
    fi

    printf "\n${C_BOLD}${C_BCYAN}═══ Test: Rich Tool Confirmation (Write) ═══${C_RESET}\n"

    if ui_tool_confirm "Write file" "src/components/Button.tsx" "Create new file (45 lines)" "" "mutation"; then
        ui_success "Write confirmed!"
    else
        ui_warn "Write cancelled"
    fi

    printf "\n${C_BOLD}${C_BCYAN}═══ Test: Rich Confirmation with Warning ═══${C_RESET}\n"

    if ui_tool_confirm "Bash command" "sudo rm -rf /tmp/old-cache/" "" "Recursive delete with admin privileges"; then
        ui_success "Confirmed with warning!"
    else
        ui_warn "Cancelled (good choice!)"
    fi
}

test_static_ui() {
    printf "\n${C_BOLD}${C_BCYAN}═══ Test 7: Static UI Components ═══${C_RESET}\n"

    echo ""
    ui_banner "qwen2.5"

    echo "Messages:"
    ui_error "Something went wrong"
    ui_warn "Context running low"
    ui_info "Project detected"
    ui_success "File written successfully"
    echo ""

    echo "Progress bars:"
    printf "  10%%: "; ui_progress_bar 10 20; printf "\n"
    printf "  40%%: "; ui_progress_bar 40 20; printf "\n"
    printf "  65%%: "; ui_progress_bar 65 20; printf "\n"
    printf "  85%%: "; ui_progress_bar 85 20; printf "\n"
    echo ""

    echo "Box:"
    ui_box "Example" "First line of content
Second line here
Third line with ${C_CYAN}color${C_RESET}" 45
    echo ""

    echo "Divider:"
    ui_divider "Section Name"
    echo ""

    echo "Tool calls:"
    ui_tool_call "read_file" "lib/ui.sh"
    ui_tool_call "bash" "ls -la"
    ui_tool_call "grep_search" "pattern=TODO"
    echo ""

    echo "Help menu:"
    ui_help
}

# ── Main ──────────────────────────────────────────────

test_name="${1:-all}"

case "$test_name" in
    select)
        test_select
        ;;
    scroll)
        test_select_long
        ;;
    search)
        test_search_select
        ;;
    filepicker|fp)
        test_file_picker
        ;;
    filter)
        test_file_picker_filtered
        ;;
    model)
        test_model_select
        ;;
    confirm)
        test_rich_confirm
        ;;
    static)
        test_static_ui
        ;;
    all)
        test_static_ui
        printf "\n${C_BOLD}${C_YELLOW}Press Enter to continue to interactive tests...${C_RESET}"
        read -r
        test_select
        test_select_long
        test_search_select
        test_rich_confirm
        test_file_picker
        test_file_picker_filtered
        test_model_select
        ;;
    *)
        printf "Usage: bash %s [select|scroll|search|filepicker|filter|model|confirm|static|all]\n" "$(basename "$0")"
        ;;
esac

printf "\n${C_BGREEN}${IC_OK} Tests complete${C_RESET}\n\n"

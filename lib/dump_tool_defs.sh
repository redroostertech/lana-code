#!/usr/bin/env bash
# Outputs all tool definitions as a single JSON array to stdout.
# Used by the Node.js TUI to load tool schemas at startup.

LANA_HOME="${LANA_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
source "$LANA_HOME/config.sh"

# Stub out UI functions so they don't interfere
ui_tool_call() { :; }
ui_tool_result() { :; }
ui_confirm() { echo "y"; }
ui_tool_confirm() { _UI_CONFIRM_RESULT=0; return 0; }
ui_warn() { :; }
ui_error() { echo "$*" >&2; }
ui_dim() { :; }
ui_debug() { :; }
ui_info() { :; }
ui_success() { :; }
spinner_start() { :; }
spinner_stop() { :; }

WORK_DIR="${LANA_WORK_DIR:-$(pwd)}"
SESSION_DIR="/tmp/lana-defs-$$"
mkdir -p "$SESSION_DIR"

source "$LANA_HOME/lib/tools.sh"
source "$LANA_HOME/lib/tools_awareness.sh"
source "$LANA_HOME/lib/tools_execution.sh"
source "$LANA_HOME/lib/tools_intelligence.sh"
source "$LANA_HOME/lib/tools_fileops.sh"

get_tool_definitions

rm -rf "$SESSION_DIR"

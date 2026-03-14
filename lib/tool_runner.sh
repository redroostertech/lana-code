#!/usr/bin/env bash
# LANA CODE — Thin bash shim for tool execution.
# Called by the Node.js frontend via child_process.spawn.
#
# Usage: bash tool_runner.sh <tool_name> <args_json>
#
# Outputs tool result on stdout. Errors on stderr.
# The Node side handles all user confirmations before calling this.

set -uo pipefail 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── Load configuration ───────────────────────────────
source "$SCRIPT_DIR/config.sh"

# Override: headless mode (no tty UI), auto-accept (Node handles confirms)
export LANA_HEADLESS="${LANA_HEADLESS:-true}"
export ACCEPT_MODE="${ACCEPT_MODE:-yolo}"
export WORK_DIR="${LANA_WORK_DIR:-$(pwd)}"

# Session dir (tools need it for cold storage, etc.)
SESSION_DIR="${SESSION_DIR:-/tmp/lana-$$}"
mkdir -p "$SESSION_DIR/turns" 2>/dev/null || true
export SESSION_DIR

# ── Load tool modules ────────────────────────────────
source "$SCRIPT_DIR/lib/ui.sh"
source "$SCRIPT_DIR/lib/state.sh"
source "$SCRIPT_DIR/lib/tools.sh"
source "$SCRIPT_DIR/lib/tools_awareness.sh"
source "$SCRIPT_DIR/lib/tools_execution.sh"
source "$SCRIPT_DIR/lib/tools_intelligence.sh"
source "$SCRIPT_DIR/lib/tools_fileops.sh"
source "$SCRIPT_DIR/lib/project.sh"
source "$SCRIPT_DIR/lib/permissions.sh"
source "$SCRIPT_DIR/lib/hooks.sh"

# ── Validate arguments ───────────────────────────────
if [[ $# -lt 2 ]]; then
    echo "Usage: tool_runner.sh <tool_name> <args_json>" >&2
    exit 1
fi

TOOL_NAME="$1"
TOOL_ARGS="$2"

# ── Execute the tool ─────────────────────────────────
execute_tool "$TOOL_NAME" "$TOOL_ARGS"

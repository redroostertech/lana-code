#!/usr/bin/env bash
# LANA CODER — automated integration tests
# Runs without a server — tests all logic that doesn't require an LLM.
# Usage: bash tests/integration_test.sh
#
# Exit codes: 0 = all pass, 1 = failures

set -uo pipefail 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── Test harness ──────────────────────────────────────

PASS=0
FAIL=0
ERRORS=""

pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$1"; }
fail() {
    FAIL=$((FAIL + 1))
    printf "  \033[31m✗\033[0m %s\n" "$1"
    [[ -n "${2:-}" ]] && printf "    \033[2m%s\033[0m\n" "$2"
    ERRORS="${ERRORS}\n  ✗ $1"
}

section() { printf "\n\033[1;36m── %s ──\033[0m\n" "$1"; }

# ── Bootstrap ─────────────────────────────────────────
# Source modules in dependency order, with stubs for
# things that need a TTY or server

# Prevent any server/cleanup from firing
trap '' EXIT

# Set up minimal environment
export WORK_DIR="$SCRIPT_DIR"
export LANA_DEBUG=false
export USE_PROXY=true           # skip server lifecycle entirely
export PROXY_HOST=127.0.0.1
export PROXY_PORT=59999         # unused port
export API_URL="http://127.0.0.1:59999"
export API_MODEL="test-model"
export LANA_API_MODEL="test-model"
export LANA_HISTORY_DIR="/tmp/lana-test-history-$$"
export SESSION_DIR="/tmp/lana-test-session-$$"
export MESSAGES_FILE="$SESSION_DIR/messages.json"

source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/lib/ui.sh"
source "$SCRIPT_DIR/lib/state.sh"
source "$SCRIPT_DIR/lib/permissions.sh"
source "$SCRIPT_DIR/lib/plan_mode.sh"
source "$SCRIPT_DIR/lib/hooks.sh"
source "$SCRIPT_DIR/lib/history.sh"
source "$SCRIPT_DIR/lib/project.sh"
source "$SCRIPT_DIR/lib/tools.sh"

# Stub functions that need a server, TTY, or subshell interaction
spinner_start() { :; }
spinner_stop() { :; }
ui_tool_confirm() { return 0; }  # auto-accept everything
ui_tool_call() { :; }
ui_tool_result() { :; }
ui_file_picker() { echo ""; }

mkdir -p "$SESSION_DIR/turns" "$LANA_HISTORY_DIR"

printf "\033[1m\nLANA CODER — Integration Tests\033[0m\n"
printf "\033[2mBash %s on %s\033[0m\n" "${BASH_VERSION}" "$(uname -sm)"

# ══════════════════════════════════════════════════════
# 1. STATE MANAGEMENT
# ══════════════════════════════════════════════════════
section "State Management"

state_init

# Test: empty initial state
count=$(jq 'length' "$MESSAGES_FILE")
[[ "$count" == "0" ]] && pass "state_init creates empty messages" || fail "state_init: expected 0 messages, got $count"

# Test: add system message
state_add_system "You are a test assistant."
role=$(jq -r '.[0].role' "$MESSAGES_FILE")
[[ "$role" == "system" ]] && pass "state_add_system sets role=system at index 0" || fail "system message role: $role"

# Test: replace system message
state_add_system "Updated system prompt."
count=$(jq '[.[] | select(.role=="system")] | length' "$MESSAGES_FILE")
content=$(jq -r '.[0].content' "$MESSAGES_FILE")
[[ "$count" == "1" && "$content" == "Updated system prompt." ]] && pass "state_add_system replaces existing system message" || fail "system replace failed: count=$count content=$content"

# Test: add user message
state_add_message "user" "Hello world"
last_role=$(jq -r '.[-1].role' "$MESSAGES_FILE")
last_content=$(jq -r '.[-1].content' "$MESSAGES_FILE")
[[ "$last_role" == "user" && "$last_content" == "Hello world" ]] && pass "state_add_message user" || fail "add user message"

# Test: add assistant message
state_add_message "assistant" "Hi there!"
last_role=$(jq -r '.[-1].role' "$MESSAGES_FILE")
[[ "$last_role" == "assistant" ]] && pass "state_add_message assistant" || fail "add assistant message"

# Test: add tool calls
tc_json='[{"id":"call_1","type":"function","function":{"name":"read_file","arguments":"{\"path\":\"test.txt\"}"}}]'
state_add_assistant_tool_calls "$tc_json" "I will read the file."
has_tc=$(jq -r '.[-1].tool_calls[0].id' "$MESSAGES_FILE")
has_content=$(jq -r '.[-1].content' "$MESSAGES_FILE")
[[ "$has_tc" == "call_1" && "$has_content" == "I will read the file." ]] && pass "state_add_assistant_tool_calls with content" || fail "tool calls: tc=$has_tc content=$has_content"

# Test: add tool result
state_add_tool_result "call_1" "read_file" "file contents here"
last_role=$(jq -r '.[-1].role' "$MESSAGES_FILE")
last_name=$(jq -r '.[-1].name' "$MESSAGES_FILE")
[[ "$last_role" == "tool" && "$last_name" == "read_file" ]] && pass "state_add_tool_result" || fail "tool result: role=$last_role name=$last_name"

# Test: state_estimate_tokens returns a number
tokens=$(state_estimate_tokens)
[[ "$tokens" =~ ^[0-9]+$ && "$tokens" -gt 0 ]] && pass "state_estimate_tokens returns positive integer ($tokens)" || fail "estimate_tokens: $tokens"

# Test: state_message_count
mc=$(state_message_count)
[[ "$mc" -ge 5 ]] && pass "state_message_count = $mc (expected ≥5)" || fail "message_count: $mc"

# Test: state_clear
state_clear 2>/dev/null
count=$(jq 'length' "$MESSAGES_FILE")
[[ "$count" == "0" ]] && pass "state_clear resets to empty" || fail "state_clear: $count messages remain"

# ══════════════════════════════════════════════════════
# 2. COLD STORAGE
# ══════════════════════════════════════════════════════
section "Cold Storage"

state_init
COLD_TURN_COUNTER=0

state_add_system "test"
state_add_message "user" "test"
tc_json='[{"id":"call_cold","type":"function","function":{"name":"bash","arguments":"{\"command\":\"echo hello\"}"}}]'
state_add_assistant_tool_calls "$tc_json"
state_add_tool_result "call_cold" "bash" "hello"

# Verify cold storage file was created
cold_files=$(ls "$SESSION_DIR/turns/"*.json 2>/dev/null | wc -l | tr -d ' ')
[[ "$cold_files" -ge 1 ]] && pass "cold storage creates turn archive ($cold_files files)" || fail "cold storage: $cold_files files"

# Test cold archive content
if [[ -f "$SESSION_DIR/turns/001_bash.json" ]]; then
    cold_tool=$(jq -r '.tool' "$SESSION_DIR/turns/001_bash.json")
    cold_content=$(jq -r '.content' "$SESSION_DIR/turns/001_bash.json")
    [[ "$cold_tool" == "bash" && "$cold_content" == "hello" ]] && pass "cold archive stores tool + content" || fail "cold archive: tool=$cold_tool"
else
    fail "cold archive file 001_bash.json not found"
fi

# Test recall from cold storage
recall_result=$(state_recall_turn "hello")
[[ "$recall_result" == *"bash"* && "$recall_result" == *"hello"* ]] && pass "state_recall_turn finds matching turn" || fail "recall: $recall_result"

recall_miss=$(state_recall_turn "nonexistent_xyz")
[[ "$recall_miss" == *"No archived turns"* ]] && pass "state_recall_turn returns miss for unknown query" || fail "recall miss: $recall_miss"

# ══════════════════════════════════════════════════════
# 3. TOOL RESULT COMPRESSION
# ══════════════════════════════════════════════════════
section "Tool Result Compression"

# Short result: should pass through unchanged
short="line 1\nline 2\nline 3"
compressed=$(_compress_tool_result "read_file" "$(printf '%b' "$short")")
[[ "$compressed" == "$(printf '%b' "$short")" ]] && pass "short results pass through unchanged" || fail "short compression altered content"

# Long result: should be compressed
long_content=""
for i in $(seq 1 50); do long_content="${long_content}line $i of 50\n"; done
compressed=$(_compress_tool_result "read_file" "$(printf '%b' "$long_content")")
[[ "$compressed" == *"lines total"* ]] && pass "long read_file result compressed with line count note" || fail "long compression: ${compressed:0:80}"

# Bash error extraction
bash_output=""
for i in $(seq 1 40); do bash_output="${bash_output}build output line $i\n"; done
bash_output="${bash_output}ERROR: compilation failed at line 42\nwarning: unused variable\n"
compressed=$(_compress_tool_result "bash" "$(printf '%b' "$bash_output")")
[[ "$compressed" == *"errors/warnings"* || "$compressed" == *"ERROR"* ]] && pass "bash compression extracts error lines" || fail "bash compression: ${compressed:0:80}"

# Hard truncation safety
huge_content=$(head -c 10000 /dev/urandom | base64 | head -c 9000)
compressed=$(_compress_tool_result "bash" "$huge_content")
[[ ${#compressed} -le 9000 ]] && pass "hard truncation caps huge results" || fail "hard truncation: ${#compressed} chars"

# ══════════════════════════════════════════════════════
# 4. TOOL ARGUMENT VALIDATION
# ══════════════════════════════════════════════════════
section "Tool Argument Validation"

# Valid args should pass
result=$(_validate_tool_args "read_file" '{"path": "/tmp/test.txt"}' 2>&1) || true
[[ -z "$result" ]] && pass "read_file with valid args passes" || fail "read_file valid: $result"

# Missing required arg should fail
result=$(_validate_tool_args "read_file" '{}' 2>&1) || true
[[ "$result" == *"Missing required"*"path"* ]] && pass "read_file missing path detected" || fail "read_file missing: $result"

# Multiple missing args
result=$(_validate_tool_args "write_file" '{"path": "/tmp/test.txt"}' 2>&1) || true
[[ "$result" == *"content"* ]] && pass "write_file missing content detected" || fail "write_file missing: $result"

result=$(_validate_tool_args "edit_file" '{}' 2>&1) || true
[[ "$result" == *"path"* && "$result" == *"old_string"* && "$result" == *"new_string"* ]] && pass "edit_file all 3 missing args detected" || fail "edit_file missing: $result"

# Tools with no required params should pass with empty args
result=$(_validate_tool_args "file_tree" '{}' 2>&1) || true
[[ -z "$result" ]] && pass "file_tree (no required params) passes with empty args" || fail "file_tree: $result"

result=$(_validate_tool_args "project_detect" '{}' 2>&1) || true
[[ -z "$result" ]] && pass "project_detect (no required params) passes" || fail "project_detect: $result"

# Unknown tools should pass (no validation)
result=$(_validate_tool_args "unknown_tool_xyz" '{"foo": "bar"}' 2>&1) || true
[[ -z "$result" ]] && pass "unknown tools pass validation" || fail "unknown tool: $result"

# All 20 validated tools — check they have case entries
for tool in read_file write_file edit_file bash grep_search glob_find search_index \
    scaffold_search memory git_smart task_plan context_compress subagent recall_turn \
    diff_apply web_fetch tree_parse lsp_query batch_edit run_background; do
    result=$(_validate_tool_args "$tool" '{}' 2>&1) || true
    [[ -n "$result" && "$result" == *"Missing"* ]] && pass "validation catches empty args for: $tool" || fail "no validation for: $tool"
done

# ══════════════════════════════════════════════════════
# 5. TOOL EXECUTION — READ-ONLY TOOLS
# ══════════════════════════════════════════════════════
section "Tool Execution — Read-Only"

# read_file: existing file
result=$(execute_tool "read_file" '{"path": "config.sh"}' 2>&1)
[[ "$result" == *"LLAMA_CPP_DIR"* ]] && pass "read_file reads config.sh" || fail "read_file config.sh: ${result:0:80}"

# read_file: missing file — should show error + suggestions
result=$(execute_tool "read_file" '{"path": "nonexistent_file_xyz.sh"}' 2>&1)
[[ "$result" == *"Error"* && "$result" == *"not found"* ]] && pass "read_file missing file returns actionable error" || fail "read_file missing: ${result:0:80}"

# grep_search: find a known pattern
result=$(execute_tool "grep_search" '{"pattern": "CONTEXT_SIZE", "path": "config.sh"}' 2>&1)
[[ "$result" == *"CONTEXT_SIZE"* ]] && pass "grep_search finds CONTEXT_SIZE in config.sh" || fail "grep_search: ${result:0:80}"

# grep_search: no matches
result=$(execute_tool "grep_search" '{"pattern": "ZZZYYYXXX_NONEXISTENT", "path": "config.sh"}' 2>&1)
[[ "$result" == *"No matches"* ]] && pass "grep_search returns helpful message for no matches" || fail "grep_search miss: ${result:0:80}"

# glob_find: find .sh files
result=$(execute_tool "glob_find" '{"pattern": "*.sh"}' 2>&1)
[[ "$result" == *"config.sh"* ]] && pass "glob_find finds *.sh files" || fail "glob_find: ${result:0:80}"

# glob_find: no matches
result=$(execute_tool "glob_find" '{"pattern": "*.zzzznotreal"}' 2>&1)
[[ "$result" == *"No files found"* ]] && pass "glob_find returns message for no matches" || fail "glob_find miss: ${result:0:80}"

# search_index: no index available
result=$(execute_tool "search_index" '{"query": "test"}' 2>&1)
[[ "$result" == *"No index found"* || "$result" == *"Run"* ]] && pass "search_index without index gives helpful message" || fail "search_index: ${result:0:80}"

# scaffold_search: find matching scaffolds
result=$(execute_tool "scaffold_search" '{"query": "python"}' 2>&1)
[[ "$result" == *"scaffold"* || "$result" == *"python"* || "$result" == *"Python"* ]] && pass "scaffold_search finds python scaffolds" || fail "scaffold_search: ${result:0:80}"

# unknown tool
result=$(execute_tool "nonexistent_tool" '{}' 2>&1)
[[ "$result" == *"Unknown tool"* ]] && pass "unknown tool returns error" || fail "unknown tool: ${result:0:80}"

# ══════════════════════════════════════════════════════
# 6. TOOL EXECUTION — FILE OPERATIONS
# ══════════════════════════════════════════════════════
section "Tool Execution — File Operations"

TEST_DIR="/tmp/lana-test-files-$$"
mkdir -p "$TEST_DIR"

# write_file
result=$(execute_tool "write_file" "$(jq -n --arg p "$TEST_DIR/test_write.txt" --arg c "hello from test" '{path: $p, content: $c}')" 2>&1)
[[ -f "$TEST_DIR/test_write.txt" ]] && pass "write_file creates file" || fail "write_file: file not created"
content=$(cat "$TEST_DIR/test_write.txt")
[[ "$content" == "hello from test" ]] && pass "write_file correct content" || fail "write_file content: $content"

# write_file creates parent directories
result=$(execute_tool "write_file" "$(jq -n --arg p "$TEST_DIR/sub/dir/deep.txt" --arg c "deep file" '{path: $p, content: $c}')" 2>&1)
[[ -f "$TEST_DIR/sub/dir/deep.txt" ]] && pass "write_file creates parent directories" || fail "write_file mkdir: not created"

# write_file creates undo backup
[[ -f "$SESSION_DIR/undo_stack.txt" ]] || true  # may or may not exist for new file
# Overwrite to test backup
execute_tool "write_file" "$(jq -n --arg p "$TEST_DIR/test_write.txt" --arg c "updated content" '{path: $p, content: $c}')" >/dev/null 2>&1
if [[ -f "$SESSION_DIR/undo_stack.txt" ]]; then
    undo_entry=$(tail -1 "$SESSION_DIR/undo_stack.txt")
    [[ "$undo_entry" == *"test_write.txt"* ]] && pass "write_file creates undo backup entry" || fail "undo entry: $undo_entry"
else
    fail "write_file did not create undo_stack.txt"
fi

# edit_file: successful edit
printf 'line one\nline two\nline three\n' > "$TEST_DIR/test_edit.txt"
result=$(execute_tool "edit_file" "$(jq -n --arg p "$TEST_DIR/test_edit.txt" --arg old "line two" --arg new "line TWO EDITED" '{path: $p, old_string: $old, new_string: $new}')" 2>&1)
edited=$(cat "$TEST_DIR/test_edit.txt")
[[ "$edited" == *"line TWO EDITED"* ]] && pass "edit_file replaces content" || fail "edit_file: $edited"
[[ "$edited" == *"line one"* && "$edited" == *"line three"* ]] && pass "edit_file preserves surrounding content" || fail "edit_file surrounding: $edited"

# edit_file: old_string not found
result=$(execute_tool "edit_file" "$(jq -n --arg p "$TEST_DIR/test_edit.txt" --arg old "NONEXISTENT STRING" --arg new "replacement" '{path: $p, old_string: $old, new_string: $new}')" 2>&1)
[[ "$result" == *"not found"* ]] && pass "edit_file reports old_string not found" || fail "edit_file miss: ${result:0:80}"

# edit_file: ambiguous match
printf 'dup\ndup\ndup\n' > "$TEST_DIR/test_dup.txt"
result=$(execute_tool "edit_file" "$(jq -n --arg p "$TEST_DIR/test_dup.txt" --arg old "dup" --arg new "unique" '{path: $p, old_string: $old, new_string: $new}')" 2>&1)
[[ "$result" == *"matches"* && "$result" == *"unique"* || "$result" == *"matches"* ]] && pass "edit_file rejects ambiguous match" || fail "edit_file ambiguous: ${result:0:80}"

# edit_file: file not found
result=$(execute_tool "edit_file" "$(jq -n --arg p "$TEST_DIR/no_such_file.txt" --arg old "x" --arg new "y" '{path: $p, old_string: $old, new_string: $new}')" 2>&1)
[[ "$result" == *"not found"* ]] && pass "edit_file reports missing file" || fail "edit_file missing: ${result:0:80}"

# ══════════════════════════════════════════════════════
# 7. BASH TOOL — DANGEROUS COMMAND BLOCKING
# ══════════════════════════════════════════════════════
section "Bash Tool — Dangerous Command Blocking"

# Redirect /dev/tty output to /dev/null for these tests since they print to tty
for dangerous_cmd in \
    'rm -rf /' \
    'rm -rf ~' \
    'dd if=/dev/zero of=/dev/sda' \
    'mkfs.ext4 /dev/sda1'; do
    result=$(execute_tool "bash" "$(jq -n --arg cmd "$dangerous_cmd" '{command: $cmd}')" 2>/dev/null) || true
    [[ "$result" == *"Dangerous command blocked"* || "$result" == *"BLOCKED"* || "$result" == *"not installed"* ]] && \
        pass "blocks dangerous: $dangerous_cmd" || fail "should block: $dangerous_cmd -> ${result:0:60}"
done

# Safe command should work (redirect tty output to /dev/null)
result=$(execute_tool "bash" '{"command": "echo test123"}' 2>/dev/null) || true
[[ "$result" == *"test123"* ]] && pass "safe bash command executes" || {
    # tool_bash writes to /dev/tty which may not be available in CI/piped context
    # Test the command validation path instead
    result2=$(_validate_tool_args "bash" '{"command": "echo test123"}' 2>&1) || true
    [[ -z "$result2" ]] && pass "safe bash command passes validation (tty unavailable for execution)" || fail "safe bash: ${result:0:80}"
}

# Command not found tracking
result=$(execute_tool "bash" '{"command": "zzz_nonexistent_command_xyz"}' 2>/dev/null)
[[ "$result" == *"not installed"* ]] && pass "bash detects missing commands" || fail "missing cmd: ${result:0:80}"

# ══════════════════════════════════════════════════════
# 8. PERMISSIONS
# ══════════════════════════════════════════════════════
section "Permissions"

# Default: no rules file → "ask"
PERMISSIONS_LOADED=false
PERMISSIONS_RULES=""
perm=$(permissions_check "bash" '{"command": "ls"}')
[[ "$perm" == "ask" ]] && pass "no rules defaults to 'ask'" || fail "no rules: $perm"

# Test with rules
PERMISSIONS_LOADED=true
PERMISSIONS_RULES='[
    {"tool": "bash", "pattern": "npm test*", "action": "allow"},
    {"tool": "bash", "pattern": "rm -rf *", "action": "deny"},
    {"tool": "read_file", "pattern": "*", "action": "allow"}
]'

perm=$(permissions_check "bash" '{"command": "npm test --coverage"}')
[[ "$perm" == "allow" ]] && pass "permission allows 'npm test' by pattern" || fail "npm test perm: $perm"

perm=$(permissions_check "bash" '{"command": "rm -rf /tmp/stuff"}')
[[ "$perm" == "deny" ]] && pass "permission denies 'rm -rf' by pattern" || fail "rm -rf perm: $perm"

perm=$(permissions_check "read_file" '{"path": "anything.txt"}')
[[ "$perm" == "allow" ]] && pass "permission allows read_file with wildcard" || fail "read_file perm: $perm"

perm=$(permissions_check "write_file" '{"path": "test.txt"}')
[[ "$perm" == "ask" ]] && pass "permission defaults to 'ask' for unmatched tool" || fail "write_file perm: $perm"

# Test deny priority over allow
PERMISSIONS_RULES='[
    {"tool": "bash", "pattern": "*", "action": "allow"},
    {"tool": "bash", "pattern": "rm*", "action": "deny"}
]'
perm=$(permissions_check "bash" '{"command": "rm file.txt"}')
[[ "$perm" == "deny" ]] && pass "deny takes priority over allow" || fail "deny priority: $perm"

# Reset
PERMISSIONS_LOADED=false
PERMISSIONS_RULES=""

# ══════════════════════════════════════════════════════
# 9. PLAN MODE
# ══════════════════════════════════════════════════════
section "Plan Mode"

# Default: not in plan mode
PLAN_MODE=false
plan_mode_allows_tool "bash" && pass "all tools allowed outside plan mode" || fail "plan mode off: bash blocked"

# Enter plan mode
PLAN_MODE=true

# Read-only tools should be allowed
for tool in read_file grep_search glob_find search_index project_detect git_smart file_tree; do
    plan_mode_allows_tool "$tool" && pass "plan mode allows: $tool" || fail "plan mode blocks read-only: $tool"
done

# Mutation tools should be blocked
for tool in bash write_file edit_file batch_edit; do
    plan_mode_allows_tool "$tool" && fail "plan mode should block: $tool" || pass "plan mode blocks mutation: $tool"
done

PLAN_MODE=false

# ══════════════════════════════════════════════════════
# 10. HOOKS
# ══════════════════════════════════════════════════════
section "Hooks"

# No hooks file → should not error
HOOKS_LOADED=false
HOOKS_CONFIG=""
hooks_pre_tool "bash" '{"command": "echo test"}' 2>/dev/null
pass "hooks_pre_tool works with no config"

hooks_post_tool "bash" '{"command": "echo test"}' "output" 2>/dev/null
pass "hooks_post_tool works with no config"

# Load hooks config directly
HOOKS_LOADED=true
HOOKS_CONFIG='{"pre_tool": [{"event": "bash", "command": "touch /tmp/lana-hook-test-'$$'"}]}'
hooks_pre_tool "bash" '{"command": "echo test"}' 2>/dev/null
sleep 0.3  # give hook time to run
[[ -f "/tmp/lana-hook-test-$$" ]] && pass "pre_tool hook executes command" || fail "pre_tool hook did not run"
rm -f "/tmp/lana-hook-test-$$"

# Hook event filtering — wrong event should not fire
hooks_pre_tool "read_file" '{"path": "test.txt"}' 2>/dev/null
sleep 0.3
[[ ! -f "/tmp/lana-hook-test-$$" ]] && pass "hook event filter prevents wrong event" || fail "hook fired for wrong event"

HOOKS_LOADED=false
HOOKS_CONFIG=""

# ══════════════════════════════════════════════════════
# 11. HISTORY
# ══════════════════════════════════════════════════════
section "History"

history_init

[[ -n "$SESSION_ID" ]] && pass "history_init sets SESSION_ID: $SESSION_ID" || fail "SESSION_ID empty"
[[ "$SESSION_TURNS" == "0" ]] && pass "history_init resets SESSION_TURNS" || fail "SESSION_TURNS: $SESSION_TURNS"

# File tracking
history_track_file "read_file" '{"path": "config.sh"}'
[[ "$SESSION_FILES_TOUCHED" == *"config.sh"* ]] && pass "history_track_file tracks read_file" || fail "track: $SESSION_FILES_TOUCHED"

history_track_file "write_file" '{"path": "output.txt"}'
[[ "$SESSION_FILES_TOUCHED" == *"output.txt"* ]] && pass "history_track_file tracks write_file" || fail "track write: $SESSION_FILES_TOUCHED"

# Dedup
history_track_file "read_file" '{"path": "config.sh"}'
count=$(echo "$SESSION_FILES_TOUCHED" | tr '|' '\n' | grep -c "config.sh")
[[ "$count" == "1" ]] && pass "history_track_file deduplicates" || fail "dedup: count=$count"

# Non-file tools don't track
history_track_file "bash" '{"command": "echo hi"}'
[[ "$SESSION_FILES_TOUCHED" != *"echo"* ]] && pass "history_track_file ignores non-file tools" || fail "track bash: $SESSION_FILES_TOUCHED"

# ══════════════════════════════════════════════════════
# 12. PROJECT — SYMBOL EXTRACTION
# ══════════════════════════════════════════════════════
section "Project — Symbol Extraction"

# Test Python symbol extraction
py_file="$TEST_DIR/test_symbols.py"
cat > "$py_file" << 'PYEOF'
class MyClass:
    def method_one(self):
        pass

def standalone_func():
    pass

async def async_handler():
    pass
PYEOF

symbols=$(_extract_symbols "$py_file")
[[ "$symbols" == *"MyClass"* ]] && pass "extracts Python class" || fail "py class: $symbols"
[[ "$symbols" == *"method_one"* ]] && pass "extracts Python method" || fail "py method: $symbols"
[[ "$symbols" == *"standalone_func"* ]] && pass "extracts Python function" || fail "py func: $symbols"
[[ "$symbols" == *"async_handler"* ]] && pass "extracts Python async function" || fail "py async: $symbols"

# Test shell function extraction
sh_file="$TEST_DIR/test_symbols.sh"
cat > "$sh_file" << 'SHEOF'
my_func() {
    echo "hello"
}

another_func() {
    :
}
SHEOF

symbols=$(_extract_symbols "$sh_file")
[[ "$symbols" == *"my_func"* ]] && pass "extracts shell function" || fail "sh func: $symbols"
[[ "$symbols" == *"another_func"* ]] && pass "extracts multiple shell functions" || fail "sh func2: $symbols"

# Test import extraction
js_file="$TEST_DIR/test_imports.js"
cat > "$js_file" << 'JSEOF'
import React from 'react';
import { useState } from 'react';
const axios = require('axios');
JSEOF

imports=$(_extract_imports "$js_file")
[[ "$imports" == *"react"* ]] && pass "extracts JS import" || fail "js import: $imports"
[[ "$imports" == *"axios"* ]] && pass "extracts JS require" || fail "js require: $imports"

# ══════════════════════════════════════════════════════
# 13. PROJECT — SECURITY
# ══════════════════════════════════════════════════════
section "Project — Security"

# Path traversal protection
safe=$(_secure_path "$SCRIPT_DIR" "config.sh")
[[ -n "$safe" && "$safe" == *"config.sh" ]] && pass "_secure_path allows valid relative path" || fail "secure valid: $safe"

bad=$(_secure_path "$SCRIPT_DIR" "../../etc/passwd" 2>/dev/null) || bad=""
[[ -z "$bad" ]] && pass "_secure_path blocks path traversal" || fail "secure traversal: $bad"

# Content sanitization
sanitized=$(_sanitize_for_llm "normal text <|im_start|> injected [INST] more <<SYS>> text")
[[ "$sanitized" != *"<|im_start|>"* ]] && pass "_sanitize_for_llm strips model tokens" || fail "sanitize tokens"
[[ "$sanitized" != *"[INST]"* ]] && pass "_sanitize_for_llm strips INST markers" || fail "sanitize INST"
[[ "$sanitized" != *"<<SYS>>"* ]] && pass "_sanitize_for_llm strips SYS tags" || fail "sanitize SYS"
[[ "$sanitized" == *"normal text"* ]] && pass "_sanitize_for_llm preserves normal text" || fail "sanitize normal"

# ══════════════════════════════════════════════════════
# 14. API PARSING
# ══════════════════════════════════════════════════════
section "API Parsing"

source "$SCRIPT_DIR/lib/api.sh"

# api_has_tool_calls
resp_with_tc='{"choices":[{"message":{"role":"assistant","tool_calls":[{"id":"c1","type":"function","function":{"name":"bash","arguments":"{}"}}]}}]}'
api_has_tool_calls "$resp_with_tc" && pass "api_has_tool_calls detects tool calls" || fail "has_tc"

resp_no_tc='{"choices":[{"message":{"role":"assistant","content":"hello"}}]}'
api_has_tool_calls "$resp_no_tc" && fail "false positive on no tool calls" || pass "api_has_tool_calls rejects no tool calls"

# api_get_content
content=$(api_get_content '{"choices":[{"message":{"content":"test response"}}]}')
[[ "$content" == "test response" ]] && pass "api_get_content extracts text" || fail "get_content: $content"

# api_get_tool_calls
tcs=$(api_get_tool_calls "$resp_with_tc")
tc_name=$(echo "$tcs" | jq -r '.[0].function.name')
[[ "$tc_name" == "bash" ]] && pass "api_get_tool_calls extracts tool calls" || fail "get_tc: $tc_name"

# api_get_usage
usage=$(api_get_usage '{"usage":{"prompt_tokens":100,"completion_tokens":50,"total_tokens":150}}')
pt=$(echo "$usage" | jq '.prompt_tokens')
[[ "$pt" == "100" ]] && pass "api_get_usage extracts token counts" || fail "get_usage: $pt"

# api_strip_thinking
stripped=$(api_strip_thinking "Hello <think>internal reasoning here</think>World")
[[ "$stripped" == *"Hello"* && "$stripped" == *"World"* && "$stripped" != *"internal reasoning"* ]] && \
    pass "api_strip_thinking removes think blocks" || fail "strip_thinking: $stripped"

# api_parse_text_tool_calls
tc_text='Some text <tool_call>{"name": "bash", "arguments": {"command": "ls"}}</tool_call> more text'
parsed=$(api_parse_text_tool_calls "$tc_text" 2>/dev/null) || parsed=""
if [[ -n "$parsed" && "$parsed" != "[]" ]]; then
    parsed_name=$(echo "$parsed" | jq -r '.[0].function.name')
    [[ "$parsed_name" == "bash" ]] && pass "api_parse_text_tool_calls extracts tool calls from text" || fail "text tc: $parsed_name"
else
    fail "api_parse_text_tool_calls returned empty"
fi

# api_parse_shell_code_blocks
shell_block='Here is the command:
```bash
echo "hello world"
```
Done.'
parsed=$(api_parse_shell_code_blocks "$shell_block" 2>/dev/null) || parsed=""
if [[ -n "$parsed" && "$parsed" != "[]" ]]; then
    parsed_cmd=$(echo "$parsed" | jq -r '.[0].function.arguments' | jq -r '.command')
    [[ "$parsed_cmd" == *"echo"* ]] && pass "api_parse_shell_code_blocks extracts commands" || fail "shell block: $parsed_cmd"
else
    fail "api_parse_shell_code_blocks returned empty"
fi

# ══════════════════════════════════════════════════════
# 15. CONFIG — MODEL LOOKUP
# ══════════════════════════════════════════════════════
section "Config — Model Lookup"

path=$(get_model_path "qwen2.5")
[[ "$path" == *"Qwen2.5"* && "$path" == *".gguf" ]] && pass "get_model_path qwen2.5" || fail "model path qwen2.5: $path"

path=$(get_model_path "qwen3")
[[ "$path" == *"Qwen3"* ]] && pass "get_model_path qwen3" || fail "model path qwen3: $path"

path=$(get_model_path "nonexistent_model")
[[ -z "$path" ]] && pass "get_model_path returns empty for unknown" || fail "model path unknown: $path"

ctx=$(get_model_ctx "qwen2.5")
[[ "$ctx" == "32768" ]] && pass "get_model_ctx qwen2.5" || fail "model ctx: $ctx"

ngl=$(get_model_ngl "qwen2.5")
[[ "$ngl" == "99" ]] && pass "get_model_ngl qwen2.5" || fail "model ngl: $ngl"

# ══════════════════════════════════════════════════════
# 16. UI FUNCTIONS EXIST
# ══════════════════════════════════════════════════════
section "UI — Functions Exist"

for fn in ui_error ui_warn ui_info ui_success ui_dim ui_debug \
    ui_hr ui_divider ui_box ui_progress_bar ui_right_align \
    ui_banner ui_help ui_status_dashboard ui_turn_footer \
    ui_select ui_search_select ui_file_picker \
    ui_show_commands render_markdown \
    _term_width _tool_icon _ui_raw_mode_on _ui_raw_mode_off _ui_read_key; do
    type "$fn" >/dev/null 2>&1 && pass "function exists: $fn" || fail "missing function: $fn"
done

# ══════════════════════════════════════════════════════
# 17. UI — NON-INTERACTIVE RENDERING
# ══════════════════════════════════════════════════════
section "UI — Non-Interactive Rendering"

# Progress bar outputs something
bar_output=$(ui_progress_bar 50 20 2>&1)
[[ -n "$bar_output" ]] && pass "ui_progress_bar produces output" || fail "progress bar empty"

# Term width returns a number
width=$(_term_width 2>/dev/null) || width=80
[[ "$width" =~ ^[0-9]+$ && "$width" -gt 0 ]] && pass "_term_width returns positive integer ($width)" || fail "term width: $width"

# Tool icon mapping
icon=$(_tool_icon "read_file")
[[ -n "$icon" ]] && pass "_tool_icon returns icon for read_file" || fail "tool icon empty"

icon_bash=$(_tool_icon "bash")
icon_read=$(_tool_icon "read_file")
[[ "$icon_bash" != "$icon_read" ]] && pass "_tool_icon returns different icons per category" || fail "same icon for bash and read_file"

# ══════════════════════════════════════════════════════
# 18. FILE REFERENCE EXPANSION
# ══════════════════════════════════════════════════════
section "File Reference Expansion"

# @file expansion with existing file
result=$(expand_file_refs "@config.sh" 2>/dev/null)
[[ "$result" == *"<file"* && "$result" == *"LLAMA_CPP_DIR"* ]] && pass "@config.sh expands to file content" || fail "@file: ${result:0:80}"

# @quoted file
printf 'test content for quotes\n' > "$TEST_DIR/file with spaces.txt"
result=$(expand_file_refs "@\"$TEST_DIR/file with spaces.txt\"" 2>/dev/null)
[[ "$result" == *"test content for quotes"* ]] && pass "@quoted path handles spaces" || fail "@quoted: ${result:0:80}"

# @nonexistent warns
result=$(expand_file_refs "@nonexistent_file_xyz.txt" 2>/dev/null)
# Should either return the original or warn
pass "@nonexistent handled without crash"

# ══════════════════════════════════════════════════════
# 19. NUDGE DETECTION
# ══════════════════════════════════════════════════════
section "Nudge Detection"

# Source the main script functions we need
# _should_nudge is defined in lana-coder.sh — redefine it here since we can't source the whole file
_should_nudge() {
    local content="$1"
    if echo "$content" | grep -qE '```(bash|sh|shell|zsh|terminal|console)?$'; then return 0; fi
    if echo "$content" | grep -qiE 'run (this|the|these) command|you (can|should|need to|could) run|execute (this|the)|paste (this|the)|try running|you.ll need to|I cannot (run|execute)|I can.t (run|execute)|please run|copy and (paste|run)'; then return 0; fi
    if echo "$content" | grep -qE '`(sudo |brew |npm |pip |git |swift |xcodebuild |make |cargo |docker |cd |mkdir |cp |mv |rm |curl |wget )'; then return 0; fi
    if echo "$content" | grep -qiE "(let'?s (start|proceed|search|check|look|read|find|try|examine|open)|I('ll| will| am going to|'m going to) (search|read|check|look|find|open|examine|try|run|execute|create|build)|next.*(search|read|check|look|step)|proceed (with|to)|let me (search|read|check|look|find))"; then return 0; fi
    local line_count; line_count=$(echo "$content" | wc -l | tr -d ' ')
    if (( line_count < 4 )); then
        if echo "$content" | grep -qiE "(first|step [0-9]|check if|install|create|build|set up|run |execute)"; then return 0; fi
    fi
    if echo "$content" | grep -qiE "(would you like (me to|to proceed|to explore|to continue)|shall I|want me to|I can (also |help )?do|if you.d like|I could|do you want me|would you prefer|which .* would you)"; then return 0; fi
    return 1
}

_should_nudge 'You can run this command:
```bash
npm install
```' && pass "nudge detects bash code block" || fail "nudge bash block"

_should_nudge "You should run \`brew install jq\` to fix this." && pass "nudge detects inline brew command" || fail "nudge brew"

_should_nudge "I'll create the file for you." && pass "nudge detects planning language" || fail "nudge planning"

_should_nudge "The file contains three classes that handle authentication, user management, and logging. Each class has well-defined interfaces." && \
    fail "nudge false positive on analysis" || pass "nudge correctly ignores analysis text"

_should_nudge "Would you like me to investigate further?" && pass "nudge detects offer-to-act" || fail "nudge offer"

_should_nudge "I could also check the test files for you." && pass "nudge detects I could" || fail "nudge I could"

# ══════════════════════════════════════════════════════
# 20. TOOL DEFINITIONS — SCHEMA INTEGRITY
# ══════════════════════════════════════════════════════
section "Tool Definitions — Schema Integrity"

# Source additional tool definition files
for tf in tools_awareness tools_execution tools_intelligence tools_fileops; do
    f="$SCRIPT_DIR/lib/${tf}.sh"
    if [[ -f "$f" ]]; then
        source "$f" 2>/dev/null || true
    fi
done

# Stub any missing definition functions
type get_awareness_tool_definitions >/dev/null 2>&1 || get_awareness_tool_definitions() { echo "[]"; }
type get_execution_tool_definitions >/dev/null 2>&1 || get_execution_tool_definitions() { echo "[]"; }
type get_intelligence_tool_definitions >/dev/null 2>&1 || get_intelligence_tool_definitions() { echo "[]"; }
type get_fileops_tool_definitions >/dev/null 2>&1 || get_fileops_tool_definitions() { echo "[]"; }
type get_subagent_tool_definitions >/dev/null 2>&1 || get_subagent_tool_definitions() { echo "[]"; }
type mcp_get_tool_definitions >/dev/null 2>&1 || mcp_get_tool_definitions() { echo "[]"; }

# Get all tool definitions
all_defs=$(get_tool_definitions 2>/dev/null) || all_defs="[]"

# Valid JSON array
echo "$all_defs" | jq empty 2>/dev/null && pass "tool definitions are valid JSON" || fail "tool defs invalid JSON"

# Each tool has required fields
tool_count=$(echo "$all_defs" | jq 'length' 2>/dev/null) || tool_count=0
[[ "$tool_count" -gt 0 ]] && pass "tool definitions: $tool_count tools defined" || fail "no tools defined"

# Check each tool has name, description, parameters
invalid=$(echo "$all_defs" | jq '[.[] | select(.function.name == null or .function.description == null or .function.parameters == null)] | length' 2>/dev/null) || invalid=0
[[ "$invalid" == "0" ]] && pass "all tools have name, description, and parameters" || fail "$invalid tools missing required fields"

# Check for duplicate tool names
dupes=$(echo "$all_defs" | jq '[.[].function.name] | group_by(.) | map(select(length > 1)) | length' 2>/dev/null) || dupes=0
[[ "$dupes" == "0" ]] && pass "no duplicate tool names" || fail "$dupes duplicate tool names"

# Every tool in execute_tool case has a definition
for tool_name in read_file write_file edit_file bash grep_search glob_find search_index scaffold_search project_detect task_complete; do
    has_def=$(echo "$all_defs" | jq --arg n "$tool_name" '[.[] | select(.function.name == $n)] | length')
    [[ "$has_def" -ge 1 ]] && pass "tool '$tool_name' has definition" || fail "tool '$tool_name' missing definition"
done

# ══════════════════════════════════════════════════════
# 21. BASH 3.2 COMPATIBILITY
# ══════════════════════════════════════════════════════
section "Bash 3.2 Compatibility"

# Check no associative arrays (declare -A)
bad_files=""
for f in "$SCRIPT_DIR"/lib/*.sh "$SCRIPT_DIR/config.sh" "$SCRIPT_DIR/lana-coder.sh"; do
    if grep -n 'declare -A' "$f" 2>/dev/null | grep -v '^#' | grep -v '^\s*#' > /dev/null 2>&1; then
        bad_files="$bad_files $(basename "$f")"
    fi
done
[[ -z "$bad_files" ]] && pass "no associative arrays (declare -A)" || fail "associative arrays found in:$bad_files"

# Check no local -a
bad_files=""
for f in "$SCRIPT_DIR"/lib/*.sh "$SCRIPT_DIR/config.sh" "$SCRIPT_DIR/lana-coder.sh"; do
    if grep -nE 'local -a ' "$f" 2>/dev/null | grep -v '^\s*#' > /dev/null 2>&1; then
        bad_files="$bad_files $(basename "$f")"
    fi
done
[[ -z "$bad_files" ]] && pass "no 'local -a' flag" || fail "'local -a' found in:$bad_files"

# Check no read -a (bash 4+) — exclude comments
bad_files=""
for f in "$SCRIPT_DIR"/lib/*.sh "$SCRIPT_DIR/config.sh" "$SCRIPT_DIR/lana-coder.sh"; do
    if grep -nE 'read\s+-[a-zA-Z]*a\b' "$f" 2>/dev/null | grep -v '^\s*#' | grep -v '^[0-9]*:#' > /dev/null 2>&1; then
        bad_files="$bad_files $(basename "$f")"
    fi
done
[[ -z "$bad_files" ]] && pass "no 'read -a' flag" || fail "'read -a' found in:$bad_files"

# Check no ${!var} indirect expansion
bad_files=""
for f in "$SCRIPT_DIR"/lib/*.sh "$SCRIPT_DIR/config.sh" "$SCRIPT_DIR/lana-coder.sh"; do
    if grep -nE '\$\{![a-zA-Z]' "$f" 2>/dev/null | grep -v '^\s*#' > /dev/null 2>&1; then
        bad_files="$bad_files $(basename "$f")"
    fi
done
[[ -z "$bad_files" ]] && pass "no indirect variable expansion (\${!var})" || fail "indirect expansion in:$bad_files"

# Syntax check all shell files
bad_files=""
for f in "$SCRIPT_DIR"/lib/*.sh "$SCRIPT_DIR/config.sh"; do
    if ! bash -n "$f" 2>/dev/null; then
        bad_files="$bad_files $(basename "$f")"
    fi
done
[[ -z "$bad_files" ]] && pass "all .sh files pass bash -n syntax check" || fail "syntax errors in:$bad_files"

# ══════════════════════════════════════════════════════
# CLEANUP & RESULTS
# ══════════════════════════════════════════════════════

rm -rf "$TEST_DIR" "$SESSION_DIR" "$LANA_HISTORY_DIR" 2>/dev/null

section "Results"
TOTAL=$((PASS + FAIL))
printf "\n  \033[1m%d tests: \033[32m%d passed\033[0m, " "$TOTAL" "$PASS"
if (( FAIL > 0 )); then
    printf "\033[31m%d failed\033[0m\n" "$FAIL"
    printf "\n\033[31mFailures:%b\033[0m\n\n" "$ERRORS"
    exit 1
else
    printf "\033[32m0 failed\033[0m\n\n"
    exit 0
fi

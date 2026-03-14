#!/usr/bin/env bash
# MCP (Model Context Protocol) stdio client
# Compatible with bash 3.2+
#
# Connects to MCP servers via stdio to discover and invoke external tools.
#
# Configuration in .lana/mcp.json:
# {
#   "servers": {
#     "github": {
#       "command": "npx",
#       "args": ["-y", "@modelcontextprotocol/server-github"],
#       "env": {"GITHUB_TOKEN": "ghp_..."}
#     },
#     "sqlite": {
#       "command": "npx",
#       "args": ["-y", "@modelcontextprotocol/server-sqlite", "mydb.db"]
#     },
#     "custom": {
#       "command": "python3",
#       "args": ["my_mcp_server.py"]
#     }
#   }
# }
#
# Tools are exposed as mcp_<server>_<tool> to the LLM.

# ── MCP state ────────────────────────────────────────
MCP_LOADED=false
MCP_CONFIG=""
MCP_TOOLS_JSON="[]"
MCP_SERVER_PIDS=""

# ── Load MCP config ──────────────────────────────────
mcp_load() {
    local config_file="$WORK_DIR/.lana/mcp.json"

    if [[ ! -f "$config_file" ]]; then
        MCP_CONFIG="{}"
        MCP_TOOLS_JSON="[]"
        MCP_LOADED=true
        return 0
    fi

    MCP_CONFIG=$(cat "$config_file" 2>/dev/null) || MCP_CONFIG="{}"

    local server_count
    server_count=$(echo "$MCP_CONFIG" | jq '.servers | length' 2>/dev/null) || server_count=0

    if (( server_count == 0 )); then
        MCP_TOOLS_JSON="[]"
        MCP_LOADED=true
        return 0
    fi

    ui_dim "  MCP: discovering tools from $server_count server(s)..."

    # Discover tools from each server
    MCP_TOOLS_JSON="[]"
    local server_names
    server_names=$(echo "$MCP_CONFIG" | jq -r '.servers | keys[]' 2>/dev/null) || true

    local name
    for name in $server_names; do
        local tools
        tools=$(_mcp_discover_tools "$name") || true
        if [[ -n "$tools" && "$tools" != "[]" && "$tools" != "null" ]]; then
            # Merge discovered tools
            MCP_TOOLS_JSON=$(jq -s '.[0] + .[1]' <<< "$MCP_TOOLS_JSON
$tools")
            local tool_count
            tool_count=$(echo "$tools" | jq 'length' 2>/dev/null) || tool_count=0
            ui_dim "  MCP: $name — $tool_count tools"
        else
            ui_debug "MCP: $name — no tools discovered (server may not be available)"
        fi
    done

    MCP_LOADED=true
}

# ── Discover tools from a single MCP server ──────────
_mcp_discover_tools() {
    local server_name="$1"

    local cmd args_json env_json
    cmd=$(echo "$MCP_CONFIG" | jq -r --arg n "$server_name" '.servers[$n].command // empty')
    args_json=$(echo "$MCP_CONFIG" | jq -c --arg n "$server_name" '.servers[$n].args // []')
    env_json=$(echo "$MCP_CONFIG" | jq -c --arg n "$server_name" '.servers[$n].env // {}')

    if [[ -z "$cmd" ]]; then
        return 1
    fi

    # Check if command exists
    if ! command -v "$cmd" >/dev/null 2>&1; then
        ui_debug "MCP: command not found: $cmd"
        return 1
    fi

    # Build the command with args
    local full_cmd="$cmd"
    local arg_list
    arg_list=$(echo "$args_json" | jq -r '.[]' 2>/dev/null) || true
    local arg
    for arg in $arg_list; do
        full_cmd="$full_cmd $(printf '%q' "$arg")"
    done

    # Build environment exports
    local env_exports=""
    local env_keys
    env_keys=$(echo "$env_json" | jq -r 'keys[]' 2>/dev/null) || true
    local ekey
    for ekey in $env_keys; do
        local eval
        eval=$(echo "$env_json" | jq -r --arg k "$ekey" '.[$k]')
        env_exports="export $ekey=$(printf '%q' "$eval"); "
    done

    # Send tools/list JSON-RPC request via stdio
    local request='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"lana-coder","version":"0.2.0"}}}'
    local tools_request='{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'

    # Pipe both requests, capture response
    local response
    response=$(printf '%s\n%s\n' "$request" "$tools_request" | \
        (cd "$WORK_DIR" && eval "${env_exports}${full_cmd}") 2>/dev/null | \
        timeout 10 head -20 2>/dev/null) || true

    if [[ -z "$response" ]]; then
        return 1
    fi

    # Parse the tools/list response — find the JSON-RPC response with tools
    local tools_result
    tools_result=$(echo "$response" | while IFS= read -r line; do
        # Try to parse each line as JSON-RPC response
        local method_check
        method_check=$(echo "$line" | jq -r '.result.tools // empty' 2>/dev/null) || true
        if [[ -n "$method_check" && "$method_check" != "null" ]]; then
            echo "$method_check"
            break
        fi
    done)

    if [[ -z "$tools_result" || "$tools_result" == "null" ]]; then
        return 1
    fi

    # Convert MCP tool schema to OpenAI-compatible tool definitions
    # Prefix tool names with mcp_<server>_ to namespace them
    echo "$tools_result" | jq --arg prefix "mcp_${server_name}_" '[
        .[] | {
            type: "function",
            function: {
                name: ($prefix + .name),
                description: (.description // "MCP tool"),
                parameters: (.inputSchema // {"type": "object", "properties": {}})
            }
        }
    ]' 2>/dev/null
}

# ── Get MCP tool definitions for merging ─────────────
mcp_get_tool_definitions() {
    # Lazy-load MCP config
    if [[ "$MCP_LOADED" != "true" ]]; then
        mcp_load
    fi

    echo "$MCP_TOOLS_JSON"
}

# ── Execute an MCP tool call ─────────────────────────
mcp_execute_tool() {
    local full_name="$1" args_json="$2"

    # Parse server name and tool name from mcp_<server>_<tool>
    local without_prefix="${full_name#mcp_}"
    local server_name="${without_prefix%%_*}"
    local tool_name="${without_prefix#*_}"

    if [[ -z "$server_name" || -z "$tool_name" ]]; then
        echo "Error: invalid MCP tool name: $full_name"
        return 1
    fi

    # Get server config
    local cmd args_arr_json env_json
    cmd=$(echo "$MCP_CONFIG" | jq -r --arg n "$server_name" '.servers[$n].command // empty')
    args_arr_json=$(echo "$MCP_CONFIG" | jq -c --arg n "$server_name" '.servers[$n].args // []')
    env_json=$(echo "$MCP_CONFIG" | jq -c --arg n "$server_name" '.servers[$n].env // {}')

    if [[ -z "$cmd" ]]; then
        echo "Error: MCP server not found: $server_name"
        return 1
    fi

    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: MCP server command not found: $cmd"
        return 1
    fi

    # Build command
    local full_cmd="$cmd"
    local arg
    while IFS= read -r arg; do
        [[ -z "$arg" ]] && continue
        full_cmd="$full_cmd $(printf '%q' "$arg")"
    done < <(echo "$args_arr_json" | jq -r '.[]' 2>/dev/null)

    # Build environment exports
    local env_exports=""
    local ekey
    while IFS= read -r ekey; do
        [[ -z "$ekey" ]] && continue
        local eval
        eval=$(echo "$env_json" | jq -r --arg k "$ekey" '.[$k]')
        env_exports="export $ekey=$(printf '%q' "$eval"); "
    done < <(echo "$env_json" | jq -r 'keys[]' 2>/dev/null)

    ui_tool_call "mcp:$server_name" "$tool_name"

    # Send JSON-RPC initialize + tools/call
    local init_request='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"lana-coder","version":"0.2.0"}}}'

    local call_request
    call_request=$(jq -n \
        --arg name "$tool_name" \
        --argjson args "$args_json" \
        '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":$name,"arguments":$args}}')

    local response
    response=$(printf '%s\n%s\n' "$init_request" "$call_request" | \
        (cd "$WORK_DIR" && eval "${env_exports}${full_cmd}") 2>/dev/null | \
        timeout 30 cat 2>/dev/null) || true

    if [[ -z "$response" ]]; then
        echo "Error: MCP server returned no response"
        return 1
    fi

    # Find the tools/call response (id: 2)
    local result
    result=$(echo "$response" | while IFS= read -r line; do
        local rid
        rid=$(echo "$line" | jq -r '.id // empty' 2>/dev/null) || true
        if [[ "$rid" == "2" ]]; then
            # Check for error
            local err
            err=$(echo "$line" | jq -r '.error.message // empty' 2>/dev/null) || true
            if [[ -n "$err" ]]; then
                echo "Error: $err"
            else
                # Extract content from result
                echo "$line" | jq -r '
                    .result.content // [] |
                    map(if .type == "text" then .text else (.type + ": " + (. | tostring)) end) |
                    join("\n")
                ' 2>/dev/null
            fi
            break
        fi
    done)

    if [[ -z "$result" ]]; then
        echo "Error: could not parse MCP response"
        return 1
    fi

    echo "$result"
}

# ── Reload MCP (called when WORK_DIR changes) ───────
mcp_reload() {
    MCP_LOADED=false
    mcp_load
}

# ── Cleanup MCP server processes ─────────────────────
mcp_cleanup() {
    # MCP servers are short-lived (stdio), no persistent processes to clean up
    :
}

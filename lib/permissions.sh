#!/usr/bin/env bash
# Fine-grained permission rules for tool execution
# Compatible with bash 3.2+
#
# Rules are loaded from .lana/permissions.json in the working directory.
# Format:
# [
#   {"tool": "bash", "pattern": "npm run *", "action": "allow"},
#   {"tool": "bash", "pattern": "rm -rf *", "action": "deny"},
#   {"tool": "edit_file", "pattern": "/src/**/*.ts", "action": "allow"},
#   {"tool": "bash", "pattern": "*", "action": "ask"}
# ]
#
# Actions: "allow" (auto-accept), "deny" (block), "ask" (prompt user)
# Priority: deny > ask > allow (most restrictive wins)
# Pattern matching: glob-style for tool arguments

# ── Cached rules ─────────────────────────────────────
PERMISSIONS_LOADED=false
PERMISSIONS_FILE=""
PERMISSIONS_RULES=""

# ── Load permissions from project config ─────────────
permissions_load() {
    local perm_file="$WORK_DIR/.lana/permissions.json"
    PERMISSIONS_FILE="$perm_file"

    if [[ -f "$perm_file" ]]; then
        PERMISSIONS_RULES=$(cat "$perm_file" 2>/dev/null) || PERMISSIONS_RULES="[]"
        PERMISSIONS_LOADED=true
        ui_debug "Permissions loaded: $(echo "$PERMISSIONS_RULES" | jq 'length') rules"
    else
        PERMISSIONS_RULES="[]"
        PERMISSIONS_LOADED=true
    fi
}

# ── Check permission for a tool call ─────────────────
# Returns: "allow", "deny", or "ask" (default)
permissions_check() {
    local tool_name="$1" tool_args="$2"

    # Lazy-load rules
    if [[ "$PERMISSIONS_LOADED" != "true" ]]; then
        permissions_load
    fi

    # No rules? Fall back to default behavior
    local rule_count
    rule_count=$(echo "$PERMISSIONS_RULES" | jq 'length' 2>/dev/null) || rule_count=0
    if (( rule_count == 0 )); then
        echo "ask"
        return 0
    fi

    # Extract the match target based on tool type
    local match_target=""
    case "$tool_name" in
        bash)
            match_target=$(echo "$tool_args" | jq -r '.command // empty' 2>/dev/null)
            ;;
        read_file|write_file|edit_file)
            match_target=$(echo "$tool_args" | jq -r '.path // empty' 2>/dev/null)
            ;;
        grep_search)
            match_target=$(echo "$tool_args" | jq -r '.pattern // empty' 2>/dev/null)
            ;;
        batch_edit)
            match_target=$(echo "$tool_args" | jq -r '.pattern // empty' 2>/dev/null)
            ;;
        *)
            match_target="$tool_name"
            ;;
    esac

    # Evaluate rules — collect all matching actions
    local has_deny=false
    local has_allow=false
    local has_ask=false

    local i=0
    while (( i < rule_count )); do
        local rule_tool rule_pattern rule_action
        rule_tool=$(echo "$PERMISSIONS_RULES" | jq -r ".[$i].tool // empty")
        rule_pattern=$(echo "$PERMISSIONS_RULES" | jq -r ".[$i].pattern // empty")
        rule_action=$(echo "$PERMISSIONS_RULES" | jq -r ".[$i].action // \"ask\"")

        i=$((i + 1))

        # Skip if tool doesn't match
        if [[ -n "$rule_tool" && "$rule_tool" != "$tool_name" && "$rule_tool" != "*" ]]; then
            continue
        fi

        # Check if pattern matches the target
        if [[ -n "$rule_pattern" && -n "$match_target" ]]; then
            # Use bash glob matching (case statement supports wildcards)
            local matched=false
            case "$match_target" in
                $rule_pattern) matched=true ;;
            esac

            if $matched; then
                case "$rule_action" in
                    deny)  has_deny=true ;;
                    allow) has_allow=true ;;
                    ask)   has_ask=true ;;
                esac
            fi
        elif [[ -z "$rule_pattern" || "$rule_pattern" == "*" ]]; then
            # Wildcard pattern matches everything
            case "$rule_action" in
                deny)  has_deny=true ;;
                allow) has_allow=true ;;
                ask)   has_ask=true ;;
            esac
        fi
    done

    # Priority: deny > ask > allow
    if $has_deny; then
        echo "deny"
    elif $has_ask; then
        echo "ask"
    elif $has_allow; then
        echo "allow"
    else
        echo "ask"  # default
    fi
}

# ── Reload permissions (called when WORK_DIR changes) ──
permissions_reload() {
    PERMISSIONS_LOADED=false
    permissions_load
}

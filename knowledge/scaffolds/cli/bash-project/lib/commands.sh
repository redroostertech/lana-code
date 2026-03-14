#!/usr/bin/env bash
#
# commands.sh - Subcommand implementations
#

cmd_greet() {
    local name="${1:-}"
    if [ -z "$name" ]; then
        die "Usage: mycli greet <name>"
    fi

    local greeting="${2:-Hello}"
    log_verbose "greeting=$greeting, name=$name"
    echo "${greeting}, ${name}!"
}

cmd_info() {
    echo "mycli v${VERSION}"
    echo "Verbose: ${VERBOSE}"
    echo "Shell: ${BASH_VERSION}"
    echo "OS: $(uname -s) $(uname -m)"
}

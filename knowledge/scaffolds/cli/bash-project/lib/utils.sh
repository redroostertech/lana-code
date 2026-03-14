#!/usr/bin/env bash
#
# utils.sh - Shared utility functions
#

# Print an error message and exit
die() {
    echo "Error: $*" >&2
    exit 1
}

# Print a message if verbose mode is on
log_verbose() {
    if [ "${VERBOSE:-0}" -eq 1 ]; then
        echo "[verbose] $*" >&2
    fi
}

# Print a colored message (falls back gracefully if no tty)
print_color() {
    local color="$1"
    shift
    if [ -t 1 ]; then
        case "$color" in
            red)    printf '\033[0;31m%s\033[0m\n' "$*" ;;
            green)  printf '\033[0;32m%s\033[0m\n' "$*" ;;
            yellow) printf '\033[0;33m%s\033[0m\n' "$*" ;;
            blue)   printf '\033[0;34m%s\033[0m\n' "$*" ;;
            *)      echo "$*" ;;
        esac
    else
        echo "$*"
    fi
}

# Check if a command exists
require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        die "Required command not found: $1"
    fi
}

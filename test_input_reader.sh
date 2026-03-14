#!/usr/bin/env bash
# Test the Node.js input reader — run directly in your terminal
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
READER="$SCRIPT_DIR/lib/input_reader.mjs"

GREEN='\033[0;32m'
RED='\033[0;31m'
DIM='\033[2m'
BOLD='\033[1m'
CYAN='\033[0;36m'
RESET='\033[0m'

echo ""
printf "${BOLD}${CYAN}── LANA Input Reader Test ──${RESET}\n"
echo ""

# Test 1: Node available
printf "  node: "
if command -v node >/dev/null 2>&1; then
    printf "${GREEN}$(node --version)${RESET}\n"
else
    printf "${RED}not found${RESET}\n"
    echo "  Install: brew install node"
    exit 1
fi

# Test 2: Reader file exists
printf "  reader: "
if [[ -f "$READER" ]]; then
    printf "${GREEN}found${RESET}\n"
else
    printf "${RED}not found at $READER${RESET}\n"
    exit 1
fi

# Test 3: Interactive test
echo ""
printf "${BOLD}Interactive test:${RESET}\n"
printf "${DIM}  - Type something + Enter → should show LINE:<text>${RESET}\n"
printf "${DIM}  - Type just @ + Enter    → should show @${RESET}\n"
printf "${DIM}  - Press up arrow          → should navigate history${RESET}\n"
printf "${DIM}  - Press Ctrl+D            → should show EOF${RESET}\n"
printf "${DIM}  - Press Ctrl+C            → should show INT${RESET}\n"
echo ""

tmpfile="/tmp/lana-reader-test"
errfile="/tmp/lana-reader-test-err"
: > "$tmpfile"
: > "$errfile"

node "$READER" $'\033[1;32m> \033[0m' /tmp/lana-test-history 100 \
    3>"$tmpfile" 2>"$errfile"
rc=$?

echo ""
printf "${BOLD}Results:${RESET}\n"
printf "  exit code: %s\n" "$rc"

result=$(cat "$tmpfile" 2>/dev/null)
result="${result%$'\n'}"
if [[ -n "$result" ]]; then
    printf "  ${GREEN}protocol output: %s${RESET}\n" "$result"
else
    printf "  ${RED}no output on fd 3${RESET}\n"
fi

if [[ -s "$errfile" ]]; then
    printf "  ${RED}errors:${RESET}\n"
    cat "$errfile"
fi

rm -f "$tmpfile" "$errfile" /tmp/lana-test-history

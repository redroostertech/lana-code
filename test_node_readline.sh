#!/usr/bin/env bash
# Minimal test: does Node readline handle arrow keys?
# Run this in your terminal and press up arrow.
echo "Press up arrow, then type 'hello' and press Enter:"
node -e "
const tty = require('tty');
const readline = require('readline');

// Diagnostic
console.error('stdin.isTTY:', process.stdin.isTTY);
console.error('stdout.isTTY:', process.stdout.isTTY);

const rl = readline.createInterface({
  input: process.stdin,
  output: process.stdout,
  terminal: true,
  history: ['previous-command'],
  historySize: 100,
});

rl.prompt();

rl.on('line', (text) => {
  console.error('result:', text);
  rl.close();
  process.exit(0);
});
" 3>/dev/null
echo ""
echo "If you saw [A instead of 'previous-command', readline is broken."

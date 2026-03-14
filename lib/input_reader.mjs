#!/usr/bin/env node
/**
 * LANA CODER — Node.js readline input reader.
 *
 * Provides full line editing (arrow keys, history, Ctrl shortcuts)
 * with @ detection for the file picker.
 *
 * Protocol (single line on fd 3, then process exits):
 *   LINE:<text>          Normal input
 *   @                    Bare @ (triggers file picker)
 *   @MID:<text_before>   Input ending with " @" (mid-line file picker)
 *   EOF                  Ctrl+D on empty line
 *   INT                  Ctrl+C
 *
 * Usage:
 *   node input_reader.mjs <prompt> <history_file> [history_size]
 *
 * Bash caller must redirect stdin/stdout to /dev/tty and open fd 3 for
 * writing (e.g., </dev/tty >/dev/tty 3>tmpfile).
 */

import * as fs from 'fs';
import * as path from 'path';
import * as readline from 'readline';

const args = process.argv.slice(2);
if (args.length < 2) {
  process.stderr.write('Usage: node input_reader.mjs <prompt> <history_file> [history_size]\n');
  process.exit(1);
}

const promptText = args[0];
const historyFile = args[1];
const maxSize = parseInt(args[2] || '500', 10);

// ── Write result to fd 3 ──────────────────────────────
function writeResult(msg) {
  try {
    fs.writeSync(3, msg + '\n');
  } catch {
    // fd 3 not available — fallback to stderr
    process.stderr.write(msg + '\n');
  }
}

// ── Load history from file ────────────────────────────
function loadHistory() {
  try {
    const data = fs.readFileSync(historyFile, 'utf8');
    return data.split('\n').filter(l => l.trim()).slice(-maxSize);
  } catch {
    return [];
  }
}

// ── Save line to history file ─────────────────────────
function saveToHistory(line) {
  if (!line.trim()) return;
  try {
    fs.mkdirSync(path.dirname(historyFile), { recursive: true });
    fs.appendFileSync(historyFile, line + '\n');
    // Trim if too long
    const lines = fs.readFileSync(historyFile, 'utf8').split('\n').filter(l => l.trim());
    if (lines.length > maxSize) {
      fs.writeFileSync(historyFile, lines.slice(-maxSize).join('\n') + '\n');
    }
  } catch { /* ignore */ }
}

// ── Create readline interface on stdin/stdout ──
// Bash caller redirects these to /dev/tty so they're real TTY streams.
const rl = readline.createInterface({
  input: process.stdin,
  output: process.stdout,
  prompt: promptText,
  history: loadHistory(),
  historySize: maxSize,
  terminal: true,
});

let answered = false;

function finish(msg) {
  if (answered) return;
  answered = true;
  writeResult(msg);
  rl.close();
  process.exit(0);
}

rl.on('SIGINT', () => finish('INT'));

rl.prompt();

rl.on('line', (text) => {
  saveToHistory(text);
  if (text.trim() === '@') {
    finish('@');
  } else if (text.endsWith(' @')) {
    finish('@MID:' + text.slice(0, -2));
  } else {
    finish('LINE:' + text);
  }
});

rl.on('close', () => finish('EOF'));

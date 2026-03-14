import React, { useState, useEffect, useRef } from 'react';
import { Box, Text, useInput } from 'ink';
import * as fs from 'fs';

interface PromptProps {
  onSubmit: (text: string) => void;
  onAtSign?: (prefix: string) => void;
  onSlash?: () => void;
  initialValue?: string;
  historyFile?: string;
  historySize?: number;
}

/**
 * Input prompt with line editing and history navigation.
 * Fires onAtSign immediately when @ is typed (no Enter needed).
 */
export default function Prompt({ onSubmit, onAtSign, onSlash, initialValue, historyFile, historySize = 500 }: PromptProps) {
  const [value, setValue] = useState(initialValue ?? '');
  const [cursor, setCursor] = useState(initialValue?.length ?? 0);

  // Update value when initialValue changes (e.g. after file picker)
  useEffect(() => {
    if (initialValue !== undefined) {
      setValue(initialValue);
      setCursor(initialValue.length);
    }
  }, [initialValue]);
  const [history, setHistory] = useState<string[]>([]);
  const [historyIdx, setHistoryIdx] = useState(-1);
  const [savedInput, setSavedInput] = useState('');

  // Load history on mount
  useEffect(() => {
    if (!historyFile) return;
    try {
      const data = fs.readFileSync(historyFile, 'utf8');
      const lines = data.split('\n').filter((l: string) => l.trim());
      setHistory(lines.slice(-historySize));
    } catch {
      // No history file yet
    }
  }, [historyFile, historySize]);

  const saveToHistory = (line: string) => {
    if (!line.trim() || !historyFile) return;
    try {
      const dir = historyFile.replace(/\/[^/]+$/, '');
      fs.mkdirSync(dir, { recursive: true });
      fs.appendFileSync(historyFile, line + '\n');
      setHistory(prev => [...prev, line].slice(-historySize));
    } catch { /* ignore */ }
  };

  // Track last ESC timestamp for double-tap detection
  const lastEscRef = useRef(0);

  useInput((input, key) => {
    // Double-tap ESC to clear input
    if (key.escape) {
      const now = Date.now();
      if (now - lastEscRef.current < 400) {
        // Double-tap: clear input
        setValue('');
        setCursor(0);
        setHistoryIdx(-1);
        lastEscRef.current = 0;
      } else {
        lastEscRef.current = now;
      }
      return;
    }

    if (key.return) {
      const text = value.trim();
      if (text) saveToHistory(text);
      onSubmit(value);
      setValue('');
      setCursor(0);
      setHistoryIdx(-1);
      return;
    }

    if (key.upArrow) {
      if (history.length === 0) return;
      if (historyIdx === -1) {
        setSavedInput(value);
        const newIdx = history.length - 1;
        setHistoryIdx(newIdx);
        setValue(history[newIdx]!);
        setCursor(history[newIdx]!.length);
      } else if (historyIdx > 0) {
        const newIdx = historyIdx - 1;
        setHistoryIdx(newIdx);
        setValue(history[newIdx]!);
        setCursor(history[newIdx]!.length);
      }
      return;
    }

    if (key.downArrow) {
      if (historyIdx === -1) return;
      if (historyIdx < history.length - 1) {
        const newIdx = historyIdx + 1;
        setHistoryIdx(newIdx);
        setValue(history[newIdx]!);
        setCursor(history[newIdx]!.length);
      } else {
        setHistoryIdx(-1);
        setValue(savedInput);
        setCursor(savedInput.length);
      }
      return;
    }

    if (key.leftArrow) {
      setCursor(c => Math.max(0, c - 1));
      return;
    }

    if (key.rightArrow) {
      setCursor(c => Math.min(value.length, c + 1));
      return;
    }

    if (key.backspace || key.delete) {
      if (cursor > 0) {
        setValue(v => v.slice(0, cursor - 1) + v.slice(cursor));
        setCursor(c => c - 1);
      }
      return;
    }

    // Ctrl+A: beginning of line
    if (key.ctrl && input === 'a') {
      setCursor(0);
      return;
    }

    // Ctrl+E: end of line
    if (key.ctrl && input === 'e') {
      setCursor(value.length);
      return;
    }

    // Ctrl+U: clear line
    if (key.ctrl && input === 'u') {
      setValue('');
      setCursor(0);
      return;
    }

    // Ctrl+W: delete word backward
    if (key.ctrl && input === 'w') {
      const before = value.slice(0, cursor);
      const after = value.slice(cursor);
      const trimmed = before.replace(/\S+\s*$/, '');
      setValue(trimmed + after);
      setCursor(trimmed.length);
      return;
    }

    // Regular character input
    if (input && !key.ctrl && !key.meta) {
      // Detect @ — trigger file picker immediately
      if (input === '@' && onAtSign) {
        const prefix = value.slice(0, cursor);
        // If empty or preceded by space, trigger file picker
        if (prefix === '' || prefix.endsWith(' ')) {
          onAtSign(prefix);
          setValue('');
          setCursor(0);
          setHistoryIdx(-1);
          return;
        }
      }

      // Detect / at start of input — trigger command picker
      if (input === '/' && onSlash) {
        const prefix = value.slice(0, cursor);
        if (prefix === '') {
          onSlash();
          setValue('');
          setCursor(0);
          setHistoryIdx(-1);
          return;
        }
      }

      setValue(v => v.slice(0, cursor) + input + v.slice(cursor));
      setCursor(c => c + input.length);
      setHistoryIdx(-1);
    }
  });

  // Manually wrap text to terminal width so Ink doesn't break mid-word.
  // We treat the full string (prefix + value + cursor) as one line and split
  // it into rows ourselves, rendering each row as its own <Text>.
  const prefix = '|> ';
  const fullText = prefix + value;
  const cols = process.stdout.columns || 80;

  // Word-aware wrapping: try to break at spaces rather than mid-word.
  // We must track exact character positions so cursor mapping still works.
  const rows: string[] = [];
  let pos = 0;
  while (pos < fullText.length) {
    if (pos + cols >= fullText.length) {
      // Last chunk — take everything
      rows.push(fullText.slice(pos));
      break;
    }
    // Look for a space to break at within the last ~20 chars of the row
    let breakAt = cols;
    const searchStart = Math.max(0, cols - 20);
    for (let j = cols; j >= searchStart; j--) {
      if (fullText[pos + j] === ' ') {
        breakAt = j + 1; // include the space at end of this row
        break;
      }
    }
    rows.push(fullText.slice(pos, pos + breakAt));
    pos += breakAt;
  }
  // Ensure at least one row (with cursor space)
  if (rows.length === 0) rows.push(prefix);

  // Figure out where the cursor falls in the variable-width wrapped rows
  const cursorPos = prefix.length + cursor; // absolute position in fullText
  let cursorRow = 0;
  let cursorCol = cursorPos;
  let charCount = 0;
  for (let r = 0; r < rows.length; r++) {
    if (cursorPos < charCount + rows[r]!.length) {
      cursorRow = r;
      cursorCol = cursorPos - charCount;
      break;
    }
    charCount += rows[r]!.length;
    cursorRow = r; // fallback to last row
    cursorCol = cursorPos - charCount;
  }

  return (
    <Box flexDirection="column" marginTop={1}>
      {rows.map((row, rowIdx) => {
        if (rowIdx === cursorRow) {
          // This row contains the cursor
          const before = row.slice(0, cursorCol);
          const cursorChar = row[cursorCol] ?? ' ';
          const after = row.slice(cursorCol + 1);
          return (
            <Text key={rowIdx}>
              {rowIdx === 0 ? (
                <>
                  <Text color="green" bold>{before.slice(0, prefix.length)}</Text>
                  {before.slice(prefix.length)}
                </>
              ) : (
                <Text>{before}</Text>
              )}
              <Text inverse>{cursorChar}</Text>
              {after}
            </Text>
          );
        }
        // Non-cursor row
        return (
          <Text key={rowIdx}>
            {rowIdx === 0 ? (
              <>
                <Text color="green" bold>{row.slice(0, prefix.length)}</Text>
                {row.slice(prefix.length)}
              </>
            ) : (
              row
            )}
          </Text>
        );
      })}
    </Box>
  );
}

import React, { useState, useEffect, useMemo } from 'react';
import { Box, Text, useInput } from 'ink';
import * as fs from 'fs';
import * as path from 'path';

interface FilePickerProps {
  startDir: string;
  onSelect: (filePath: string) => void;
  onCancel: () => void;
}

interface Entry {
  name: string;
  isDir: boolean;
}

function listEntries(dir: string): Entry[] {
  const entries: Entry[] = [];

  // Parent directory
  if (dir !== '/') {
    entries.push({ name: '..', isDir: true });
  }

  try {
    const names = fs.readdirSync(dir).sort();

    // Directories first
    for (const name of names) {
      if (name.startsWith('.')) continue;
      try {
        const stat = fs.statSync(path.join(dir, name));
        if (stat.isDirectory()) {
          entries.push({ name: name + '/', isDir: true });
        }
      } catch { /* skip */ }
    }

    // Then files
    for (const name of names) {
      if (name.startsWith('.')) continue;
      try {
        const stat = fs.statSync(path.join(dir, name));
        if (stat.isFile()) {
          entries.push({ name, isDir: false });
        }
      } catch { /* skip */ }
    }
  } catch { /* empty dir or permission error */ }

  return entries;
}

function fileIcon(name: string, isDir: boolean): { icon: string; color: string } {
  if (name === '..') return { icon: '↩', color: 'gray' };
  if (isDir) return { icon: '📁', color: 'blue' };

  const ext = name.split('.').pop()?.toLowerCase() ?? '';
  switch (ext) {
    case 'sh': case 'bash': case 'zsh': return { icon: '📜', color: 'green' };
    case 'py': return { icon: '🐍', color: 'yellow' };
    case 'js': case 'ts': case 'tsx': case 'jsx': return { icon: '📦', color: 'yellow' };
    case 'rs': return { icon: '🦀', color: 'red' };
    case 'go': return { icon: '🔷', color: 'cyan' };
    case 'swift': return { icon: '🔶', color: 'yellow' };
    case 'json': case 'yaml': case 'yml': case 'toml': return { icon: '📋', color: 'gray' };
    case 'md': case 'txt': return { icon: '📄', color: 'gray' };
    default: return { icon: '📄', color: 'gray' };
  }
}

const MAX_VISIBLE = 15;

export default function FilePicker({ startDir, onSelect, onCancel }: FilePickerProps) {
  const [currentDir, setCurrentDir] = useState(startDir);
  const [allEntries, setAllEntries] = useState<Entry[]>([]);
  const [selected, setSelected] = useState(0);
  const [offset, setOffset] = useState(0);
  const [filter, setFilter] = useState('');

  // Refresh entries when directory changes
  useEffect(() => {
    const newEntries = listEntries(currentDir);
    setAllEntries(newEntries);
    setSelected(0);
    setOffset(0);
    setFilter('');
  }, [currentDir]);

  // Filter entries based on typed text
  const entries = useMemo(() => {
    if (!filter) return allEntries;
    const lower = filter.toLowerCase();
    // Always keep ".." visible, filter the rest
    return allEntries.filter(e =>
      e.name === '..' || e.name.toLowerCase().includes(lower)
    );
  }, [allEntries, filter]);

  // Clamp selection when filter changes
  useEffect(() => {
    setSelected(s => Math.min(s, Math.max(0, entries.length - 1)));
    setOffset(0);
  }, [entries.length]);

  useInput((input, key) => {
    if (key.escape) {
      if (filter) {
        // First escape clears filter, second cancels picker
        setFilter('');
        return;
      }
      onCancel();
      return;
    }

    if (key.upArrow) {
      setSelected(s => {
        const next = Math.max(0, s - 1);
        if (next < offset) setOffset(next);
        return next;
      });
      return;
    }

    if (key.downArrow) {
      setSelected(s => {
        const next = Math.min(entries.length - 1, s + 1);
        if (next >= offset + MAX_VISIBLE) setOffset(next - MAX_VISIBLE + 1);
        return next;
      });
      return;
    }

    // Enter: navigate into directories, select files
    if (key.return) {
      const entry = entries[selected];
      if (!entry) return;

      if (entry.name === '..') {
        setCurrentDir(path.dirname(currentDir));
      } else if (entry.isDir) {
        // Enter on a directory = navigate into it
        setCurrentDir(path.join(currentDir, entry.name.replace(/\/$/, '')));
      } else {
        // Enter on a file = select it
        onSelect(path.join(currentDir, entry.name));
      }
      return;
    }

    // Tab: select the current item (file OR directory)
    if (key.tab) {
      const entry = entries[selected];
      if (!entry || entry.name === '..') return;

      const fullPath = path.join(currentDir, entry.name.replace(/\/$/, ''));
      onSelect(fullPath);
      return;
    }

    // Right arrow: navigate into directory
    if (key.rightArrow) {
      const entry = entries[selected];
      if (!entry) return;
      if (entry.name === '..') {
        setCurrentDir(path.dirname(currentDir));
      } else if (entry.isDir) {
        setCurrentDir(path.join(currentDir, entry.name.replace(/\/$/, '')));
      }
      return;
    }

    // Left arrow / backspace with no filter: go up
    if (key.leftArrow) {
      if (currentDir !== '/') {
        setCurrentDir(path.dirname(currentDir));
      }
      return;
    }

    // Backspace: remove last filter character, or go up if no filter
    if (key.backspace || key.delete) {
      if (filter.length > 0) {
        setFilter(f => f.slice(0, -1));
      } else if (currentDir !== '/') {
        setCurrentDir(path.dirname(currentDir));
      }
      return;
    }

    // Ctrl+U: clear filter
    if (key.ctrl && input === 'u') {
      setFilter('');
      return;
    }

    // Regular character input → type-to-filter
    if (input && !key.ctrl && !key.meta && input.length === 1) {
      setFilter(f => f + input);
      return;
    }
  });

  const shortDir = currentDir.replace(process.env['HOME'] ?? '', '~');
  const visible = entries.slice(offset, offset + MAX_VISIBLE);

  return (
    <Box flexDirection="column" marginLeft={2}>
      {/* Header */}
      <Box>
        <Text dimColor>{'╭── '}</Text>
        <Text bold>{shortDir}</Text>
      </Box>

      {/* Filter bar */}
      {filter && (
        <Box>
          <Text dimColor>{'│'}</Text>
          <Text color="yellow">{' 🔍 '}</Text>
          <Text color="yellow" bold>{filter}</Text>
          <Text dimColor>{` (${entries.length - (entries[0]?.name === '..' ? 1 : 0)} matches)`}</Text>
        </Box>
      )}

      {/* Scroll up indicator */}
      {offset > 0 && (
        <Box>
          <Text dimColor>{'│  ↑ '}{offset}{' more'}</Text>
        </Box>
      )}

      {/* Entries */}
      {visible.map((entry, i) => {
        const idx = offset + i;
        const { icon, color } = fileIcon(entry.name, entry.isDir);
        const isSelected = idx === selected;

        return (
          <Box key={`${entry.name}-${idx}`}>
            <Text dimColor>{'│'}</Text>
            {isSelected ? (
              <Text color="cyan" bold>{' ▸ '}</Text>
            ) : (
              <Text>{'   '}</Text>
            )}
            <Text color={isSelected ? 'cyan' : color} bold={isSelected}>
              {icon}{' '}{entry.name}
            </Text>
          </Box>
        );
      })}

      {/* Empty state */}
      {entries.length === 0 && (
        <Box>
          <Text dimColor>{'│   (no matches)'}</Text>
        </Box>
      )}

      {/* Scroll down indicator */}
      {offset + MAX_VISIBLE < entries.length && (
        <Box>
          <Text dimColor>{'│  ↓ '}{entries.length - offset - MAX_VISIBLE}{' more'}</Text>
        </Box>
      )}

      {/* Footer */}
      <Box>
        <Text dimColor>{'╰── ↑↓ navigate  enter open  tab select  ← back  type to filter  esc cancel'}</Text>
      </Box>
    </Box>
  );
}

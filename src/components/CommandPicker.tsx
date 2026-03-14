import React, { useState, useMemo } from 'react';
import { Box, Text, useInput } from 'ink';

export interface CommandDef {
  name: string;
  description: string;
  icon?: string;
}

interface CommandPickerProps {
  commands: CommandDef[];
  onSelect: (command: string) => void;
  onCancel: () => void;
  initialFilter?: string;
}

export default function CommandPicker({ commands, onSelect, onCancel, initialFilter = '' }: CommandPickerProps) {
  const [filter, setFilter] = useState(initialFilter);
  const [selected, setSelected] = useState(0);

  const filtered = useMemo(() => {
    if (!filter) return commands;
    const lower = filter.toLowerCase();
    return commands.filter(c =>
      c.name.toLowerCase().includes(lower) ||
      c.description.toLowerCase().includes(lower)
    );
  }, [commands, filter]);

  // Clamp selection
  const clampedSelected = Math.min(selected, Math.max(0, filtered.length - 1));

  useInput((input, key) => {
    if (key.escape) {
      onCancel();
      return;
    }

    if (key.upArrow) {
      setSelected(s => Math.max(0, s - 1));
      return;
    }

    if (key.downArrow) {
      setSelected(s => Math.min(filtered.length - 1, s + 1));
      return;
    }

    if (key.return || key.tab) {
      const cmd = filtered[clampedSelected];
      if (cmd) {
        onSelect(cmd.name);
      }
      return;
    }

    if (key.backspace || key.delete) {
      if (filter.length > 0) {
        setFilter(f => f.slice(0, -1));
        setSelected(0);
      } else {
        onCancel();
      }
      return;
    }

    // Type to filter
    if (input && !key.ctrl && !key.meta && input.length === 1) {
      setFilter(f => f + input);
      setSelected(0);
      return;
    }
  });

  return (
    <Box flexDirection="column" marginLeft={2}>
      {/* Header with filter */}
      <Box>
        <Text dimColor>{'╭── '}</Text>
        <Text color="yellow" bold>{'/'}</Text>
        <Text color="yellow" bold>{filter}</Text>
        <Text inverse>{' '}</Text>
      </Box>

      {/* Command list */}
      {filtered.map((cmd, i) => {
        const isSelected = i === clampedSelected;
        return (
          <Box key={cmd.name}>
            <Text dimColor>{'│'}</Text>
            {isSelected ? (
              <Text color="cyan" bold>{' ▸ '}</Text>
            ) : (
              <Text>{'   '}</Text>
            )}
            <Text color={isSelected ? 'cyan' : 'yellow'} bold={isSelected}>
              {cmd.icon ?? '⚡'}{' /'}{cmd.name}
            </Text>
            <Text dimColor>{'  '}{cmd.description}</Text>
          </Box>
        );
      })}

      {/* Empty state */}
      {filtered.length === 0 && (
        <Box>
          <Text dimColor>{'│   (no matching commands)'}</Text>
        </Box>
      )}

      {/* Footer */}
      <Box>
        <Text dimColor>{'╰── ↑↓ navigate  enter select  type to filter  esc cancel'}</Text>
      </Box>
    </Box>
  );
}

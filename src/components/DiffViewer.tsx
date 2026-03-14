import React from 'react';
import { Box, Text } from 'ink';
import * as Diff from 'diff';

interface DiffViewerProps {
  filePath: string;
  oldContent: string;
  newContent: string;
}

/**
 * Renders a unified diff with green/red highlighting and line numbers.
 * Similar to Claude Code's edit display.
 */
export default function DiffViewer({ filePath, oldContent, newContent }: DiffViewerProps) {
  const changes = Diff.createTwoFilesPatch('a/' + filePath, 'b/' + filePath, oldContent, newContent, '', '', {
    context: 3,
  });

  const lines = changes.split('\n');
  // Skip the first 4 header lines (---, +++, etc.) and render our own
  const diffLines = lines.slice(4);

  return (
    <Box flexDirection="column" marginLeft={2}>
      {/* File header */}
      <Box>
        <Text dimColor>╭── </Text>
        <Text color="cyan" bold>{filePath}</Text>
      </Box>

      {diffLines.map((line, i) => {
        if (line.startsWith('@@')) {
          // Hunk header
          return (
            <Box key={i}>
              <Text dimColor>│ </Text>
              <Text color="cyan" dimColor>{line}</Text>
            </Box>
          );
        }
        if (line.startsWith('+')) {
          // Added line
          return (
            <Box key={i}>
              <Text dimColor>│ </Text>
              <Text color="green" bold>+ </Text>
              <Text color="green">{line.slice(1)}</Text>
            </Box>
          );
        }
        if (line.startsWith('-')) {
          // Removed line
          return (
            <Box key={i}>
              <Text dimColor>│ </Text>
              <Text color="red" bold>- </Text>
              <Text color="red">{line.slice(1)}</Text>
            </Box>
          );
        }
        if (line.startsWith(' ')) {
          // Context line
          return (
            <Box key={i}>
              <Text dimColor>│   {line.slice(1)}</Text>
            </Box>
          );
        }
        return null;
      })}

      {/* Footer */}
      <Box>
        <Text dimColor>╰────────</Text>
      </Box>
    </Box>
  );
}

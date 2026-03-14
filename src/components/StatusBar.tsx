import React from 'react';
import { Box, Text } from 'ink';

interface StatusBarProps {
  turn: number;
  loopCount?: number;
  maxLoops?: number;
  estimatedTokens: number;
  contextSize: number;
  promptTokens?: number;
  completionTokens?: number;
}

export default function StatusBar({
  turn,
  loopCount,
  maxLoops,
  estimatedTokens,
  contextSize,
  promptTokens,
  completionTokens,
}: StatusBarProps) {
  const pct = Math.min(100, Math.round((estimatedTokens / contextSize) * 100));

  // Progress bar
  const barWidth = 20;
  const filled = Math.round((pct / 100) * barWidth);
  const bar = '█'.repeat(filled) + '░'.repeat(barWidth - filled);

  let barColor: string;
  if (pct >= 80) barColor = 'red';
  else if (pct >= 60) barColor = 'yellow';
  else barColor = 'green';

  return (
    <Box flexDirection="column" marginTop={1}>
      <Text dimColor>{'─'.repeat(60)}</Text>
      <Box gap={1}>
        <Text dimColor>turn {turn}</Text>
        {loopCount != null && maxLoops != null && (
          <Text dimColor>loop {loopCount}/{maxLoops}</Text>
        )}
        <Text dimColor>ctx </Text>
        <Text color={barColor}>{bar}</Text>
        <Text dimColor>{' '}{pct}%</Text>
        {promptTokens != null && completionTokens != null && (
          <Text dimColor>{' '}({promptTokens}+{completionTokens} tokens)</Text>
        )}
      </Box>
    </Box>
  );
}

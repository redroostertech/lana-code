import React from 'react';
import { Box, Text } from 'ink';

interface BannerProps {
  version: string;
  model: string;
  contextSize: number;
  projectName?: string;
}

// ASCII art matching the bash version's ui_banner
const LOGO_LINES = [
  '██       █████  ███    ██  █████',
  '██      ██   ██ ████   ██ ██   ██',
  '██      ███████ ██ ██  ██ ███████',
  '██      ██   ██ ██  ██ ██ ██   ██',
  '███████ ██   ██ ██   ████ ██   ██',
];

const CODER_LINES = [
  ' ██████  ██████  ██████  ███████',
  '██      ██    ██ ██   ██ ██',
  '██      ██    ██ ██   ██ █████',
  '██      ██    ██ ██   ██ ██',
  ' ██████  ██████  ██████  ███████',
];

export default function Banner({ version, model, contextSize, projectName }: BannerProps) {
  return (
    <Box flexDirection="column" marginTop={1}>
      <Box flexDirection="column">
        {LOGO_LINES.map((line, i) => (
          <Box key={i}>
            <Text color="magenta" bold>{line}</Text>
            <Text> </Text>
            <Text color="cyan" bold>{CODER_LINES[i]}</Text>
          </Box>
        ))}
      </Box>
      <Box marginTop={1} gap={1}>
        <Text dimColor>v{version}</Text>
        <Text dimColor>|</Text>
        <Text>{model}</Text>
        <Text dimColor>|</Text>
        <Text dimColor>{contextSize} ctx</Text>
        {projectName && (
          <>
            <Text dimColor>|</Text>
            <Text color="cyan" bold>{projectName}</Text>
          </>
        )}
      </Box>
      <Box marginTop={0}>
        <Text dimColor>Type /help for commands  |  /quit to exit</Text>
      </Box>
      <Box>
        <Text dimColor>{'─'.repeat(60)}</Text>
      </Box>
    </Box>
  );
}

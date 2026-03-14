import React from 'react';
import { Box, Text } from 'ink';
import Spinner from './Spinner.js';
import MarkdownRenderer from './MarkdownRenderer.js';

export type StreamPhase = 'idle' | 'thinking' | 'streaming' | 'tool_calls' | 'done';

interface StreamingOutputProps {
  phase: StreamPhase;
  content: string;
  thinkContent: string;
  abortReason?: string;
}

export default function StreamingOutput({
  phase,
  content,
  thinkContent,
  abortReason,
}: StreamingOutputProps) {
  if (phase === 'idle') return null;

  return (
    <Box flexDirection="column" marginTop={1}>
      {/* Thinking phase — show header + think content + spinner */}
      {(phase === 'thinking' || thinkContent) && (
        <Box flexDirection="column">
          <Box>
            <Text color="blue" bold>assistant</Text>
            {phase === 'thinking' && <Text dimColor> (thinking)</Text>}
          </Box>
          {thinkContent && (
            <Box flexDirection="column" marginLeft={2}>
              {thinkContent.split('\n').filter(l => l.trim()).map((line, i) => (
                <Text key={i} dimColor>{line}</Text>
              ))}
            </Box>
          )}
          {phase === 'thinking' && (
            <Box marginLeft={2}>
              <Spinner label="thinking" />
            </Box>
          )}
          {thinkContent && phase !== 'thinking' && <Text dimColor>{'───'}</Text>}
        </Box>
      )}

      {/* Streaming/done content */}
      {content && (
        <Box flexDirection="column">
          {!thinkContent && phase !== 'thinking' && (
            <Text color="blue" bold>assistant</Text>
          )}
          <MarkdownRenderer text={content} />
        </Box>
      )}

      {/* Abort reason */}
      {abortReason && (
        <Box marginTop={0}>
          <Text color="yellow">{'  '}{abortReason === 'interrupted' ? '✕ interrupted' : abortReason === 'repetition detected' ? '⚠ output truncated — repetition detected' : `⚠ ${abortReason}`}</Text>
        </Box>
      )}
    </Box>
  );
}

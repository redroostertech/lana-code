import React from 'react';
import { Box, Text } from 'ink';

interface ToolCallProps {
  name: string;
  args: Record<string, any>;
  result?: string;
  status: 'pending' | 'running' | 'done' | 'error';
}

// Tool icons matching ui.sh _tool_icon
function toolIcon(name: string): { icon: string; color: string } {
  switch (name) {
    case 'read_file':
      return { icon: '📖', color: 'yellow' };
    case 'write_file':
      return { icon: '📝', color: 'yellow' };
    case 'edit_file':
      return { icon: '✏️', color: 'yellow' };
    case 'bash':
      return { icon: '⚡', color: 'green' };
    case 'grep_search':
    case 'glob_find':
    case 'search_index':
    case 'scaffold_search':
      return { icon: '🔍', color: 'blue' };
    case 'web_fetch':
      return { icon: '🌐', color: 'cyan' };
    case 'task_complete':
      return { icon: '✅', color: 'green' };
    default:
      return { icon: '🔧', color: 'gray' };
  }
}

function formatArgs(name: string, args: Record<string, any>): string {
  switch (name) {
    case 'read_file':
    case 'write_file':
      return args.path ?? '';
    case 'edit_file':
      return args.path ?? '';
    case 'bash':
      return (args.command ?? '').slice(0, 60);
    case 'grep_search':
      return `"${args.pattern ?? ''}"${args.path ? ` in ${args.path}` : ''}`;
    case 'glob_find':
      return args.pattern ?? '';
    case 'task_complete':
      return (args.summary ?? '').slice(0, 60);
    default: {
      const first = Object.values(args)[0];
      return typeof first === 'string' ? first.slice(0, 60) : '';
    }
  }
}

function formatResult(result: string, maxLines = 5): string[] {
  const lines = result.split('\n');
  if (lines.length <= maxLines) return lines;
  return [...lines.slice(0, 3), `  ... (${lines.length} lines total)`];
}

export default function ToolCall({ name, args, result, status }: ToolCallProps) {
  const { icon, color } = toolIcon(name);
  const argsPreview = formatArgs(name, args);

  return (
    <Box flexDirection="column" marginLeft={2}>
      <Box>
        <Text dimColor>│ </Text>
        <Text color={color}>{icon}</Text>
        <Text bold> {name}</Text>
        {argsPreview && <Text dimColor> {argsPreview}</Text>}
        {status === 'running' && <Text color="yellow"> ⏳</Text>}
        {status === 'error' && <Text color="red"> ✕</Text>}
      </Box>
      {result && (
        <Box flexDirection="column" marginLeft={2}>
          {formatResult(result).map((line, i) => (
            <Text key={i} dimColor>{line}</Text>
          ))}
        </Box>
      )}
    </Box>
  );
}

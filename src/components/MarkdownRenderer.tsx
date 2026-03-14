import React from 'react';
import { Box, Text } from 'ink';
import { wordWrap } from '../utils/wordwrap.js';

interface MarkdownRendererProps {
  text: string;
}

/**
 * Renders markdown-formatted text in the terminal.
 * Handles: headers, code blocks, bold, inline code, bullets, numbered lists.
 * Word-wraps text to avoid mid-word breaks at terminal edge.
 */
export default function MarkdownRenderer({ text }: MarkdownRendererProps) {
  const cols = (process.stdout.columns || 80) - 4; // 2 indent + 2 margin
  const lines = text.split('\n');
  let inCodeBlock = false;
  let codeLang = '';
  let lastWasEmpty = false;

  const elements: React.ReactElement[] = [];

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]!;

    // Code block fence
    if (line.startsWith('```')) {
      lastWasEmpty = false;
      if (inCodeBlock) {
        elements.push(
          <Text key={`cb-end-${i}`} dimColor>  {'╰────────'}</Text>
        );
        inCodeBlock = false;
      } else {
        codeLang = line.slice(3).trim();
        elements.push(
          <Text key={`cb-start-${i}`} dimColor>
            {codeLang ? `  ╭── ${codeLang} ───` : '  ╭────────'}
          </Text>
        );
        inCodeBlock = true;
      }
      continue;
    }

    if (inCodeBlock) {
      elements.push(
        <Box key={`code-${i}`}>
          <Text dimColor>  │ </Text>
          <Text color="green">{line}</Text>
        </Box>
      );
      continue;
    }

    // Headers (h4, h3, h2, h1 — check longest prefix first)
    if (line.startsWith('#### ')) {
      lastWasEmpty = false;
      elements.push(<Text key={`h4-${i}`} bold color="cyan">{'    '}{line.slice(5)}</Text>);
      continue;
    }
    if (line.startsWith('### ')) {
      lastWasEmpty = false;
      elements.push(<Text key={`h3-${i}`} bold color="cyan">{'   '}{line.slice(4)}</Text>);
      continue;
    }
    if (line.startsWith('## ')) {
      lastWasEmpty = false;
      elements.push(<Text key={`h2-${i}`} bold color="cyan">{'  '}{line.slice(3)}</Text>);
      continue;
    }
    if (line.startsWith('# ')) {
      lastWasEmpty = false;
      elements.push(
        <Box key={`h1-${i}`} flexDirection="column">
          <Text bold color="cyan">{' '}{line.slice(2)}</Text>
        </Box>
      );
      continue;
    }

    // Numbered lists (e.g. "1. item", "  2. item")
    const numMatch = line.match(/^(\s*)\d+\.\s+(.*)/);
    if (numMatch) {
      lastWasEmpty = false;
      const [, indent, content] = numMatch;
      const num = line.match(/(\d+)\./)?.[1] ?? '';
      const prefix = `  ${indent ?? ''}${num}. `;
      const wrapped = wordWrap(content ?? '', cols - prefix.length);
      const wrapLines = wrapped.split('\n');
      wrapLines.forEach((wl, wi) => {
        elements.push(
          <Box key={`num-${i}-${wi}`}>
            <Text>{wi === 0 ? `  ${indent ?? ''}` : ' '.repeat(prefix.length)}</Text>
            {wi === 0 && <Text dimColor>{num}. </Text>}
            <InlineMarkdown text={wl} />
          </Box>
        );
      });
      continue;
    }

    // Bullet points
    const bulletMatch = line.match(/^(\s*)[-*]\s+(.*)/);
    if (bulletMatch) {
      lastWasEmpty = false;
      const [, indent, content] = bulletMatch;
      const prefix = `  ${indent ?? ''}• `;
      const wrapped = wordWrap(content ?? '', cols - prefix.length);
      const wrapLines = wrapped.split('\n');
      wrapLines.forEach((wl, wi) => {
        elements.push(
          <Box key={`bullet-${i}-${wi}`}>
            <Text>{wi === 0 ? `  ${indent ?? ''}` : ' '.repeat(prefix.length)}</Text>
            {wi === 0 && <Text dimColor>• </Text>}
            <InlineMarkdown text={wl} />
          </Box>
        );
      });
      continue;
    }

    // Regular text with inline formatting
    if (line.trim() === '') {
      // Collapse consecutive empty lines into one
      if (!lastWasEmpty) {
        elements.push(<Text key={`empty-${i}`}>{' '}</Text>);
        lastWasEmpty = true;
      }
    } else {
      lastWasEmpty = false;
      const wrapped = wordWrap(line, cols);
      const wrapLines = wrapped.split('\n');
      wrapLines.forEach((wl, wi) => {
        elements.push(
          <Box key={`text-${i}-${wi}`}>
            <Text>  </Text>
            <InlineMarkdown text={wl} />
          </Box>
        );
      });
    }
  }

  // Close unclosed code block
  if (inCodeBlock) {
    elements.push(<Text key="cb-unclosed" dimColor>  {'╰────────'}</Text>);
  }

  return <Box flexDirection="column">{elements}</Box>;
}

/**
 * Renders inline markdown: **bold** and `code`
 */
function InlineMarkdown({ text }: { text: string }) {
  // Split on **bold** and `code` patterns
  const parts: React.ReactElement[] = [];
  let remaining = text;
  let key = 0;

  while (remaining.length > 0) {
    // Bold: **text**
    const boldMatch = remaining.match(/^(.*?)\*\*([^*]+)\*\*(.*)/s);
    if (boldMatch) {
      const [, before, bold, after] = boldMatch;
      if (before) {
        parts.push(...renderCodeSpans(before, key));
        key += 10;
      }
      parts.push(<Text key={`bold-${key++}`} bold>{bold}</Text>);
      remaining = after ?? '';
      continue;
    }

    // No more bold — render remaining with code spans
    parts.push(...renderCodeSpans(remaining, key));
    break;
  }

  return <Text>{parts}</Text>;
}

function renderCodeSpans(text: string, startKey: number): React.ReactElement[] {
  const parts: React.ReactElement[] = [];
  let remaining = text;
  let key = startKey;

  while (remaining.length > 0) {
    const codeMatch = remaining.match(/^(.*?)`([^`]+)`(.*)/s);
    if (codeMatch) {
      const [, before, code, after] = codeMatch;
      if (before) parts.push(<Text key={`t-${key++}`}>{before}</Text>);
      parts.push(<Text key={`code-${key++}`} color="cyan">{code}</Text>);
      remaining = after ?? '';
    } else {
      parts.push(<Text key={`t-${key++}`}>{remaining}</Text>);
      break;
    }
  }

  return parts;
}

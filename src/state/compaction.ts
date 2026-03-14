// Context compaction — rolling conversation summarization
// Ports the logic from lib/history.sh (history_compact_rolling)

import type { ChatMessage } from '../api/types.js';
import type { LanaConfig } from './config.js';

/**
 * Format messages into a text block for the summarization prompt.
 */
function formatMessagesForSummary(messages: ChatMessage[], maxCharsPerMsg = 300): string {
  const lines: string[] = [];
  for (const msg of messages) {
    const role = msg.role.toUpperCase();
    let content = msg.content ?? '';

    if (msg.role === 'assistant' && msg.tool_calls) {
      const toolNames = msg.tool_calls.map(tc => tc.function.name).join(', ');
      content = `[Called tools: ${toolNames}]`;
    }

    if (msg.role === 'tool') {
      const name = msg.name ?? 'tool';
      content = `[${name} result] ${content}`;
    }

    // Truncate long content
    if (content.length > maxCharsPerMsg) {
      content = content.slice(0, maxCharsPerMsg) + '...';
    }

    if (content.trim()) {
      lines.push(`${role}: ${content}`);
    }
  }
  return lines.join('\n');
}

/**
 * Build the prompt to send to the LLM for summarization.
 */
function buildCompactionPrompt(existingSummary: string | null, messagesToCompact: string): string {
  const base = existingSummary
    ? `You are updating an existing conversation summary with new messages.\n\nExisting summary:\n${existingSummary}\n\nNew messages to incorporate:\n${messagesToCompact}`
    : `Summarize the following conversation messages:\n\n${messagesToCompact}`;

  return `${base}

Write a structured summary in this format (max 400 tokens):

**GOALS:** What the user is trying to accomplish
**FILES:** Key files discussed or modified (paths only)
**PROGRESS:** What has been done so far
**STATE:** Current state — what was the last thing being worked on, any blockers or next steps

Be concise. Focus on information needed to continue the conversation.`;
}

/**
 * Determine which messages to compact and which to keep.
 * Returns the split point: messages before it get compacted, after it stay hot.
 */
function findCompactionBoundary(messages: ChatMessage[], keepTurns: number): number {
  // Count backward from the end to find the boundary
  // A "turn" = user message + all following assistant/tool messages until next user message
  let turnsFound = 0;
  let boundary = messages.length;

  for (let i = messages.length - 1; i >= 0; i--) {
    if (messages[i]!.role === 'user') {
      turnsFound++;
      if (turnsFound >= keepTurns) {
        boundary = i;
        break;
      }
    }
  }

  // Don't compact system message (index 0) or existing summary (index 1 if it starts with [Conversation Summary])
  const minBoundary = messages[1]?.content?.startsWith('[Conversation Summary]') ? 2 : 1;
  return Math.max(boundary, minBoundary);
}

export interface CompactionResult {
  messages: ChatMessage[];
  summary: string;
  compactedCount: number;
  tokensBefore: number;
  tokensAfter: number;
}

/**
 * Perform rolling compaction on messages.
 * Calls the LLM to summarize old messages, keeps recent turns hot.
 */
export async function compactMessages(
  messages: ChatMessage[],
  config: LanaConfig,
  estimateTokens: (msgs: ChatMessage[]) => number,
): Promise<CompactionResult> {
  const tokensBefore = estimateTokens(messages);
  const boundary = findCompactionBoundary(messages, config.compactKeepTurns);

  // Extract existing summary if present
  let existingSummary: string | null = null;
  let startIdx = 1; // skip system message
  if (messages[1]?.content?.startsWith('[Conversation Summary]')) {
    existingSummary = messages[1].content.replace('[Conversation Summary]\n', '');
    startIdx = 2;
  }

  // Messages to compact (between existing summary and boundary)
  const toCompact = messages.slice(startIdx, boundary);
  if (toCompact.length < 2) {
    // Nothing meaningful to compact
    return { messages, summary: existingSummary ?? '', compactedCount: 0, tokensBefore, tokensAfter: tokensBefore };
  }

  // Format and call LLM for summary
  const formatted = formatMessagesForSummary(toCompact);
  const prompt = buildCompactionPrompt(existingSummary, formatted);

  // Call the API directly (non-streaming, no tools)
  const response = await fetch(`${config.apiUrl}/v1/chat/completions`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      model: config.apiModel,
      messages: [
        { role: 'system', content: 'You are a conversation summarizer. Be concise and structured.' },
        { role: 'user', content: prompt },
      ],
      temperature: config.compactTemperature,
      max_tokens: config.compactSummaryMaxTokens,
      stream: false,
    }),
  });

  if (!response.ok) {
    throw new Error(`Compaction API call failed: ${response.status}`);
  }

  const data = await response.json() as any;
  const summary = data.choices?.[0]?.message?.content ?? existingSummary ?? '';

  // Rebuild messages: [system] + [summary] + [kept recent]
  const system = messages[0]!;
  const keptRecent = messages.slice(boundary);

  const newMessages: ChatMessage[] = [
    system,
    { role: 'user', content: `[Conversation Summary]\n${summary}` },
    { role: 'assistant', content: 'Understood. I have the context from our previous conversation. How can I help?' },
    ...keptRecent,
  ];

  const tokensAfter = estimateTokens(newMessages);

  return {
    messages: newMessages,
    summary,
    compactedCount: toCompact.length,
    tokensBefore,
    tokensAfter,
  };
}

/**
 * Check if compaction should be triggered based on context usage.
 */
export function shouldCompact(estimatedTokens: number, contextSize: number, triggerPct: number): boolean {
  const usage = (estimatedTokens / contextSize) * 100;
  return usage >= triggerPct;
}

/**
 * Emergency trim — hard-cut old messages when compaction isn't enough.
 * Keeps system + summary + last N messages.
 */
export function emergencyTrim(messages: ChatMessage[], keepCount = 8): ChatMessage[] {
  if (messages.length <= keepCount + 2) return messages;

  const system = messages[0]!;
  const hasSummary = messages[1]?.content?.startsWith('[Conversation Summary]');
  const kept = messages.slice(-keepCount);

  if (hasSummary) {
    // Keep system + summary + assistant response + recent
    return [system, messages[1]!, messages[2]!, ...kept];
  }
  return [system, ...kept];
}

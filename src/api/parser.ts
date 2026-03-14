// SSE stream parser — converts raw SSE text into structured deltas
// Port of the embedded Perl SSE parser from lib/api.sh

import type { StreamDelta, ToolCall } from './types.js';

/**
 * Parse a single SSE data line into a StreamDelta.
 * Returns null for non-data lines or [DONE].
 */
export function parseSSELine(line: string): StreamDelta | null {
  const match = line.match(/^data:\s*(.+)/);
  if (!match) return null;

  const data = match[1]!;
  if (data === '[DONE]') {
    return { type: 'done' };
  }

  let chunk: any;
  try {
    chunk = JSON.parse(data);
  } catch {
    return null;
  }

  const delta = chunk.choices?.[0]?.delta;
  const finishReason = chunk.choices?.[0]?.finish_reason;

  // Usage info (usually in the final chunk)
  if (chunk.usage) {
    return {
      type: 'usage',
      promptTokens: chunk.usage.prompt_tokens ?? 0,
      completionTokens: chunk.usage.completion_tokens ?? 0,
      model: chunk.model,
      finishReason: finishReason ?? undefined,
    };
  }

  if (!delta) {
    return finishReason ? { type: 'done', finishReason, model: chunk.model } : null;
  }

  // Content delta
  if (delta.content != null && delta.content !== '') {
    return {
      type: 'content',
      text: delta.content,
      model: chunk.model,
      finishReason: finishReason ?? undefined,
    };
  }

  // Tool call delta
  if (delta.tool_calls) {
    for (const tc of delta.tool_calls) {
      return {
        type: 'tool_call',
        toolCallIndex: tc.index ?? 0,
        toolCallId: tc.id,
        functionName: tc.function?.name,
        functionArgs: tc.function?.arguments,
        model: chunk.model,
        finishReason: finishReason ?? undefined,
      };
    }
  }

  // Finish reason only
  if (finishReason) {
    return { type: 'done', finishReason, model: chunk.model };
  }

  return null;
}

/**
 * Assembles streaming tool call deltas into complete ToolCall objects.
 */
export class ToolCallAssembler {
  private calls: Map<number, ToolCall> = new Map();

  addDelta(delta: StreamDelta): void {
    if (delta.type !== 'tool_call') return;

    const idx = delta.toolCallIndex ?? 0;
    let call = this.calls.get(idx);

    if (!call) {
      call = {
        id: delta.toolCallId ?? `call_${idx}`,
        type: 'function',
        function: { name: '', arguments: '' },
      };
      this.calls.set(idx, call);
    }

    if (delta.toolCallId) call.id = delta.toolCallId;
    if (delta.functionName) call.function.name += delta.functionName;
    if (delta.functionArgs) call.function.arguments += delta.functionArgs;
  }

  getToolCalls(): ToolCall[] {
    return Array.from(this.calls.values());
  }

  hasToolCalls(): boolean {
    return this.calls.size > 0;
  }

  reset(): void {
    this.calls.clear();
  }
}

/**
 * Detects <think>...</think> blocks in streaming content.
 * Returns processed text with think blocks separated.
 */
export class ThinkBlockParser {
  private inThink = false;

  /**
   * Process a content delta. Returns:
   * - { type: 'text', text } for normal content
   * - { type: 'think_start' } when entering a think block
   * - { type: 'think', text } for think block content
   * - { type: 'think_end' } when exiting a think block
   * May return multiple segments.
   */
  process(text: string): Array<
    | { type: 'text'; text: string }
    | { type: 'think_start' }
    | { type: 'think'; text: string }
    | { type: 'think_end' }
  > {
    const segments: Array<
      | { type: 'text'; text: string }
      | { type: 'think_start' }
      | { type: 'think'; text: string }
      | { type: 'think_end' }
    > = [];

    let remaining = text;

    while (remaining.length > 0) {
      if (!this.inThink) {
        const thinkStart = remaining.indexOf('<think>');
        if (thinkStart === -1) {
          segments.push({ type: 'text', text: remaining });
          break;
        }
        if (thinkStart > 0) {
          segments.push({ type: 'text', text: remaining.slice(0, thinkStart) });
        }
        segments.push({ type: 'think_start' });
        this.inThink = true;
        remaining = remaining.slice(thinkStart + 7); // len('<think>')
      } else {
        const thinkEnd = remaining.indexOf('</think>');
        if (thinkEnd === -1) {
          if (remaining.length > 0) {
            segments.push({ type: 'think', text: remaining });
          }
          break;
        }
        if (thinkEnd > 0) {
          segments.push({ type: 'think', text: remaining.slice(0, thinkEnd) });
        }
        segments.push({ type: 'think_end' });
        this.inThink = false;
        remaining = remaining.slice(thinkEnd + 8); // len('</think>')
      }
    }

    return segments;
  }

  isInThinkBlock(): boolean {
    return this.inThink;
  }

  reset(): void {
    this.inThink = false;
  }
}

/**
 * Detects repetitive output (same line appearing N+ times).
 */
export class RepetitionDetector {
  private lineCounts = new Map<string, number>();
  private limit: number;

  constructor(limit = 3) {
    this.limit = limit;
  }

  /** Returns true if repetition detected (should abort). */
  addLine(line: string): boolean {
    if (line.trim() === '') return false;
    const count = (this.lineCounts.get(line) ?? 0) + 1;
    this.lineCounts.set(line, count);
    return count >= this.limit;
  }

  reset(): void {
    this.lineCounts.clear();
  }
}

// SSE streaming client for llama-server (OpenAI-compatible API)
// Replaces curl + embedded Perl parser from lib/api.sh

import type {
  ChatMessage,
  ChatCompletionRequest,
  StreamDelta,
  ToolCall,
  ToolDefinition,
} from './types.js';
import { parseSSELine, ToolCallAssembler, ThinkBlockParser, RepetitionDetector } from './parser.js';
import type { LanaConfig } from '../state/config.js';

export interface StreamResult {
  content: string;
  toolCalls: ToolCall[];
  finishReason: string;
  model: string;
  promptTokens: number;
  completionTokens: number;
  aborted: boolean;
  abortReason?: string;
}

export interface StreamCallbacks {
  onText?: (text: string) => void;
  onThinkStart?: () => void;
  onThink?: (text: string) => void;
  onThinkEnd?: () => void;
  onToolCallDelta?: (index: number, name: string, args: string) => void;
  onSpinner?: () => void;
  onError?: (error: string) => void;
}

/**
 * Check if the API server is healthy.
 */
export async function healthCheck(config: LanaConfig): Promise<boolean> {
  try {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 2000);
    const res = await fetch(`${config.apiUrl}/health`, { signal: controller.signal });
    clearTimeout(timeout);
    return res.ok;
  } catch {
    return false;
  }
}

/**
 * Stream a chat completion from the API.
 * Returns an assembled result after the stream completes.
 */
export async function streamChatCompletion(
  messages: ChatMessage[],
  tools: ToolDefinition[],
  config: LanaConfig,
  callbacks: StreamCallbacks = {},
  abortSignal?: AbortSignal,
): Promise<StreamResult> {
  const payload: ChatCompletionRequest = {
    model: config.apiModel,
    messages,
    tools: tools.length > 0 ? tools : undefined,
    tool_choice: tools.length > 0 ? 'auto' : undefined,
    temperature: config.temperature,
    max_tokens: config.maxTokens,
    frequency_penalty: config.frequencyPenalty,
    presence_penalty: config.presencePenalty,
    stream: true,
    stream_options: { include_usage: true },
  };

  const response = await fetch(`${config.apiUrl}/v1/chat/completions`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
    signal: abortSignal,
  });

  if (!response.ok) {
    const errText = await response.text().catch(() => 'unknown error');
    return {
      content: '',
      toolCalls: [],
      finishReason: 'error',
      model: config.apiModel,
      promptTokens: 0,
      completionTokens: 0,
      aborted: false,
      abortReason: `API error ${response.status}: ${errText}`,
    };
  }

  const reader = response.body?.getReader();
  if (!reader) {
    return {
      content: '',
      toolCalls: [],
      finishReason: 'error',
      model: config.apiModel,
      promptTokens: 0,
      completionTokens: 0,
      aborted: false,
      abortReason: 'No response body',
    };
  }

  const decoder = new TextDecoder();
  const toolAssembler = new ToolCallAssembler();
  const thinkParser = new ThinkBlockParser();
  const repetitionDetector = new RepetitionDetector();

  let content = '';
  let finishReason = 'stop';
  let model = config.apiModel;
  let promptTokens = 0;
  let completionTokens = 0;
  let aborted = false;
  let abortReason: string | undefined;
  let lineBuf = '';
  let sseBuffer = '';

  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;

      sseBuffer += decoder.decode(value, { stream: true });

      // Process complete SSE lines
      let newlineIdx: number;
      while ((newlineIdx = sseBuffer.indexOf('\n')) !== -1) {
        const line = sseBuffer.slice(0, newlineIdx).trim();
        sseBuffer = sseBuffer.slice(newlineIdx + 1);

        if (line === '') continue;

        const delta = parseSSELine(line);
        if (!delta) continue;

        if (delta.model) model = delta.model;

        if (delta.type === 'done') {
          if (delta.finishReason) finishReason = delta.finishReason;
          continue;
        }

        if (delta.type === 'usage') {
          promptTokens = delta.promptTokens ?? 0;
          completionTokens = delta.completionTokens ?? 0;
          if (delta.finishReason) finishReason = delta.finishReason;
          continue;
        }

        if (delta.type === 'error') {
          abortReason = delta.error;
          aborted = true;
          break;
        }

        if (delta.type === 'content' && delta.text) {
          // Process through think block parser
          const segments = thinkParser.process(delta.text);
          for (const seg of segments) {
            switch (seg.type) {
              case 'think_start':
                callbacks.onThinkStart?.();
                break;
              case 'think':
                callbacks.onThink?.(seg.text);
                break;
              case 'think_end':
                callbacks.onThinkEnd?.();
                break;
              case 'text':
                content += seg.text;
                // Line-buffered rendering for markdown
                lineBuf += seg.text;
                while (lineBuf.includes('\n')) {
                  const idx = lineBuf.indexOf('\n');
                  const completeLine = lineBuf.slice(0, idx);
                  lineBuf = lineBuf.slice(idx + 1);

                  // Repetition detection
                  if (repetitionDetector.addLine(completeLine)) {
                    aborted = true;
                    abortReason = 'repetition detected';
                    break;
                  }

                  callbacks.onText?.(completeLine + '\n');
                }
                // Emit partial line for live display
                if (lineBuf.length > 0 && !aborted) {
                  callbacks.onText?.(lineBuf);
                  lineBuf = '';
                }
                break;
            }
          }
          if (aborted) break;
        }

        if (delta.type === 'tool_call') {
          toolAssembler.addDelta(delta);
          const calls = toolAssembler.getToolCalls();
          const idx = delta.toolCallIndex ?? 0;
          const call = calls[idx];
          if (call) {
            callbacks.onToolCallDelta?.(idx, call.function.name, call.function.arguments);
          }
        }
      }

      if (aborted) break;
    }
  } catch (err: any) {
    if (err.name === 'AbortError') {
      aborted = true;
      abortReason = 'interrupted';
    } else {
      throw err;
    }
  } finally {
    reader.releaseLock();
  }

  return {
    content,
    toolCalls: toolAssembler.getToolCalls(),
    finishReason,
    model,
    promptTokens,
    completionTokens,
    aborted,
    abortReason,
  };
}

// OpenAI-compatible API types for llama-server

export interface ChatMessage {
  role: 'system' | 'user' | 'assistant' | 'tool';
  content?: string;
  tool_calls?: ToolCall[];
  tool_call_id?: string;
  name?: string;
}

export interface ToolCall {
  id: string;
  type: 'function';
  function: {
    name: string;
    arguments: string;
  };
}

export interface ToolDefinition {
  type: 'function';
  function: {
    name: string;
    description: string;
    parameters: {
      type: 'object';
      properties: Record<string, any>;
      required?: string[];
    };
  };
}

export interface ChatCompletionRequest {
  model: string;
  messages: ChatMessage[];
  tools?: ToolDefinition[];
  tool_choice?: 'auto' | 'none';
  temperature?: number;
  max_tokens?: number;
  frequency_penalty?: number;
  presence_penalty?: number;
  stream?: boolean;
  stream_options?: { include_usage: boolean };
}

export interface StreamDelta {
  type: 'content' | 'tool_call' | 'usage' | 'done' | 'error';
  // Content delta
  text?: string;
  // Tool call delta
  toolCallIndex?: number;
  toolCallId?: string;
  functionName?: string;
  functionArgs?: string;
  // Usage
  promptTokens?: number;
  completionTokens?: number;
  // Finish reason
  finishReason?: string;
  // Model name
  model?: string;
  // Error
  error?: string;
}

export interface ChatCompletionResponse {
  choices: Array<{
    message: ChatMessage;
    finish_reason: string;
  }>;
  model: string;
  usage: {
    prompt_tokens: number;
    completion_tokens: number;
    total_tokens: number;
  };
}

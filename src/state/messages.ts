// Conversation state management — useReducer for message history
// Matches the messages.json format from the bash version

import { useReducer, useCallback } from 'react';
import type { ChatMessage, ToolCall } from '../api/types.js';

export interface MessagesState {
  messages: ChatMessage[];
  turnCount: number;
}

export type MessagesAction =
  | { type: 'set_system'; content: string }
  | { type: 'add_user'; content: string }
  | { type: 'add_assistant'; content: string; toolCalls?: ToolCall[] }
  | { type: 'add_tool_result'; toolCallId: string; name: string; result: string }
  | { type: 'clear' }
  | { type: 'replace_messages'; messages: ChatMessage[] };

function messagesReducer(state: MessagesState, action: MessagesAction): MessagesState {
  switch (action.type) {
    case 'set_system': {
      // Replace or add system message at index 0
      const msgs = [...state.messages];
      if (msgs.length > 0 && msgs[0]!.role === 'system') {
        msgs[0] = { role: 'system', content: action.content };
      } else {
        msgs.unshift({ role: 'system', content: action.content });
      }
      return { ...state, messages: msgs };
    }

    case 'add_user':
      return {
        ...state,
        messages: [...state.messages, { role: 'user', content: action.content }],
        turnCount: state.turnCount + 1,
      };

    case 'add_assistant': {
      const msg: ChatMessage = { role: 'assistant' };
      if (action.content) msg.content = action.content;
      if (action.toolCalls && action.toolCalls.length > 0) msg.tool_calls = action.toolCalls;
      return { ...state, messages: [...state.messages, msg] };
    }

    case 'add_tool_result':
      return {
        ...state,
        messages: [
          ...state.messages,
          { role: 'tool', content: action.result, tool_call_id: action.toolCallId, name: action.name },
        ],
      };

    case 'clear':
      return { messages: [], turnCount: 0 };

    case 'replace_messages':
      return { ...state, messages: action.messages };

    default:
      return state;
  }
}

export function useMessages(initialSystem?: string) {
  const initial: MessagesState = {
    messages: initialSystem ? [{ role: 'system', content: initialSystem }] : [],
    turnCount: 0,
  };

  const [state, dispatch] = useReducer(messagesReducer, initial);

  const estimateTokens = useCallback(() => {
    // Rough estimate: ~4 chars per token
    const totalChars = state.messages.reduce((sum, m) => {
      let chars = (m.content?.length ?? 0);
      if (m.tool_calls) {
        chars += JSON.stringify(m.tool_calls).length;
      }
      return sum + chars;
    }, 0);
    return Math.ceil(totalChars / 4);
  }, [state.messages]);

  return { state, dispatch, estimateTokens };
}

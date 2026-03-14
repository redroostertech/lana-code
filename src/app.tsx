import React, { useState, useCallback, useEffect, useRef } from 'react';
import { Box, Text, useApp, useInput, Static } from 'ink';
import * as fs from 'fs';
import * as path from 'path';

import Banner from './components/Banner.js';
import Prompt from './components/Prompt.js';
import Spinner from './components/Spinner.js';
import StreamingOutput from './components/StreamingOutput.js';
import type { StreamPhase } from './components/StreamingOutput.js';
import MarkdownRenderer from './components/MarkdownRenderer.js';
import ToolCallDisplay from './components/ToolCall.js';
import Confirmation from './components/Confirmation.js';
import DiffViewer from './components/DiffViewer.js';
import StatusBar from './components/StatusBar.js';
import FilePicker from './components/FilePicker.js';
import CommandPicker from './components/CommandPicker.js';
import type { CommandDef } from './components/CommandPicker.js';
import Checkpoint from './components/Checkpoint.js';
import type { CheckpointChoice } from './components/Checkpoint.js';

import { spawn as spawnProc, execSync } from 'child_process';
import { streamChatCompletion, healthCheck } from './api/client.js';
import type { StreamCallbacks, StreamResult } from './api/client.js';
import type { ChatMessage, ToolCall, ToolDefinition } from './api/types.js';
import { useMessages } from './state/messages.js';
import { executeTool, setEmbeddingProvider } from './tools/executor.js';
import type { LanaConfig } from './state/config.js';
import { detectFlow, buildSystemPrompt } from './prompts/builder.js';
import { ModelManager } from './embedding/model-manager.js';
import { EmbeddingIndexer } from './embedding/indexer.js';
import { compactMessages, shouldCompact, emergencyTrim } from './state/compaction.js';
import { SessionTracker, listSessions, loadSession, buildRecallContext } from './state/session.js';
import { hybridSearch, formatSearchResults } from './embedding/search.js';

// Rendered conversation items (static, already displayed)
interface ConversationItem {
  id: string;
  type: 'banner' | 'user' | 'assistant' | 'tool_call' | 'tool_result' | 'status' | 'error';
  content: string;
  toolName?: string;
  toolArgs?: Record<string, any>;
  toolResult?: string;
}

interface PendingConfirmation {
  toolCall: ToolCall;
  args: Record<string, any>;
  label: string;
  content?: string;
  warning?: string;
  diff?: { filePath: string; oldContent: string; newContent: string };
  resolve: (accepted: boolean) => void;
}

interface PendingCheckpoint {
  reason: string;
  resolve: (choice: CheckpointChoice) => void;
}

interface AppProps {
  config: LanaConfig;
  systemPrompt: string;
  toolDefs: ToolDefinition[];
}

export default function App({ config, systemPrompt, toolDefs }: AppProps) {
  const { exit } = useApp();
  const { state: msgState, dispatch, estimateTokens } = useMessages(systemPrompt);

  // Rendered conversation (items that have been fully processed)
  // Seed with banner as the first static item
  const [items, setItems] = useState<ConversationItem[]>([
    { id: 'banner', type: 'banner', content: '' },
  ]);
  const [itemCounter, setItemCounter] = useState(0);

  // Streaming state
  const [streamPhase, setStreamPhase] = useState<StreamPhase>('idle');
  const [streamContent, setStreamContent] = useState('');
  const [thinkContent, setThinkContent] = useState('');
  const [abortReason, setAbortReason] = useState<string | undefined>();

  // Agent state
  const [isAgentRunning, setIsAgentRunning] = useState(false);
  const [loopCount, setLoopCount] = useState(0);
  const [promptTokens, setPromptTokens] = useState(0);
  const [completionTokens, setCompletionTokens] = useState(0);

  // Confirmation dialog
  const [pendingConfirm, setPendingConfirm] = useState<PendingConfirmation | null>(null);

  // Agent loop checkpoint
  const [pendingCheckpoint, setPendingCheckpoint] = useState<PendingCheckpoint | null>(null);

  // File picker state
  const [showFilePicker, setShowFilePicker] = useState(false);
  const [filePickerPrefix, setFilePickerPrefix] = useState('');
  const [promptInitialValue, setPromptInitialValue] = useState<string | undefined>(undefined);

  // Command picker state
  const [showCommandPicker, setShowCommandPicker] = useState(false);

  // Command definitions for the picker
  const commandDefs: CommandDef[] = [
    { name: 'help', description: 'Show available commands', icon: '❓' },
    { name: 'status', description: 'Show session info', icon: '📊' },
    { name: 'index', description: 'Index project (symbols + embeddings). --force to rebuild', icon: '🔍' },
    { name: 'search', description: 'Search project index', icon: '🔎' },
    { name: 'load', description: 'Load project into context', icon: '📂' },
    { name: 'model', description: 'Switch model', icon: '🤖' },
    { name: 'compact', description: 'Compress context', icon: '📦' },
    { name: 'accept', description: 'Set permission mode (confirm/auto-edit/yolo)', icon: '🔒' },
    { name: 'subagent', description: 'Spawn subagent (research/plan/execute)', icon: '🧬' },
    { name: 'plan', description: 'Plan mode (read-only exploration)', icon: '📋' },
    { name: 'fork', description: 'Fork session', icon: '🔀' },
    { name: 'undo', description: 'Revert last file edit', icon: '↩️' },
    { name: 'debug', description: 'Toggle debug mode (show API details)', icon: '🐛' },
    { name: 'memory', description: 'View/set project memories', icon: '🧠' },
    { name: 'history', description: 'List past sessions', icon: '📜' },
    { name: 'recall', description: 'Recall previous session context', icon: '🔄' },
    { name: 'clear', description: 'Clear conversation', icon: '🧹' },
    { name: 'version', description: 'Show version info', icon: '📌' },
    { name: 'quit', description: 'Exit', icon: '👋' },
  ];

  // Abort controller
  const abortRef = useRef<AbortController | null>(null);
  const debugRef = useRef(false);

  // Model manager for embedding (initialized once)
  const modelManagerRef = useRef<ModelManager | null>(null);
  if (!modelManagerRef.current) {
    const chatModelPath = process.env['CHAT_MODEL_PATH'] || '';
    const mm = new ModelManager({
      chatPort: config.chatPort,
      chatModelPath,
      chatModelCtx: config.chatModelCtx,
      chatModelNgl: config.chatModelNgl,
      embeddingPort: config.embeddingPort,
      embeddingModelPath: config.embeddingModelPath,
      llamaServerBin: config.llamaServerBin,
      threads: config.threads,
    });
    // Forward model manager events to conversation items
    mm.on('status', (msg: string) => {
      setItems(prev => [...prev, { id: `mm-${Date.now()}`, type: 'status', content: msg }]);
    });
    mm.on('error', (err: Error) => {
      setItems(prev => [...prev, { id: `mm-err-${Date.now()}`, type: 'error', content: err.message }]);
    });
    // Register embedding provider for hybrid search
    setEmbeddingProvider(mm.getProvider());
    modelManagerRef.current = mm;
  }

  // Pre-warm embedding model at launch (dual mode only, non-blocking)
  const preWarmStarted = useRef(false);
  useEffect(() => {
    if (preWarmStarted.current) return;
    preWarmStarted.current = true;
    const mm = modelManagerRef.current;
    if (mm) {
      mm.preWarm().catch(() => { /* logged via event emitter */ });
    }
  }, []);

  // Session tracker for persistence
  const sessionRef = useRef<SessionTracker | null>(null);
  if (!sessionRef.current) {
    sessionRef.current = new SessionTracker(config);
  }

  // Mutable config ref — allows runtime changes (model, acceptMode)
  const configRef = useRef(config);
  const [currentModel, setCurrentModel] = useState(config.currentModel);
  const [acceptMode, setAcceptMode] = useState(config.acceptMode);

  // Save session + stop embedding on unmount
  useEffect(() => {
    return () => {
      if (sessionRef.current && msgState.turnCount > 0) {
        sessionRef.current.save(msgState.messages);
      }
      modelManagerRef.current?.shutdown().catch(() => {});
    };
  }, []); // eslint-disable-line — intentionally only on unmount

  const nextId = useCallback(() => {
    setItemCounter(c => c + 1);
    return `item-${itemCounter}`;
  }, [itemCounter]);

  const addItem = useCallback((item: Omit<ConversationItem, 'id'>) => {
    setItems(prev => [...prev, { ...item, id: `item-${Date.now()}-${Math.random()}` }]);
  }, []);

  // Handle Ctrl+C to interrupt
  useInput((input, key) => {
    if (key.escape && isAgentRunning) {
      abortRef.current?.abort();
    }
  });

  // Determine if a tool needs confirmation
  const needsConfirmation = useCallback((name: string, args: Record<string, any>): boolean => {
    if (acceptMode === 'yolo') return false;
    // Read-only tools auto-confirm
    const readOnly = ['read_file', 'grep_search', 'glob_find', 'search_index',
      'scaffold_search', 'file_tree', 'tree_parse', 'recall_turn', 'task_complete',
      'project_detect', 'git_smart', 'lsp_query', 'memory'];
    if (config.autoConfirmRead && readOnly.includes(name)) return false;
    // auto-edit: also auto-approve write/edit tools
    if (acceptMode === 'auto-edit') {
      const editTools = ['write_file', 'edit_file', 'move_file', 'copy_file', 'delete_file'];
      if (editTools.includes(name)) return false;
    }
    return true;
  }, [acceptMode, config.autoConfirmRead]);

  // Get confirmation from user via Ink UI
  const getConfirmation = useCallback((toolCall: ToolCall, args: Record<string, any>): Promise<boolean> => {
    return new Promise((resolve) => {
      const name = toolCall.function.name;
      let label = name;
      let content: string | undefined;
      let warning: string | undefined;
      let diff: PendingConfirmation['diff'] | undefined;

      if (name === 'bash') {
        label = 'Bash command';
        content = args.command;
        // Detect risky patterns
        const cmd = args.command ?? '';
        if (/rm\s+(-rf|--force)/.test(cmd)) warning = 'Destructive: rm with force flag';
        if (/sudo/.test(cmd)) warning = 'Elevated privileges: sudo';
        if (/\|\s*(bash|sh|zsh)/.test(cmd)) warning = 'Pipe to shell execution';
      } else if (name === 'write_file') {
        label = `Write file: ${args.path}`;
        content = (args.content ?? '').slice(0, 500);
        // Try to show diff if file exists
        try {
          const existing = fs.readFileSync(path.resolve(config.lanaDir, '..', args.path), 'utf8');
          diff = { filePath: args.path, oldContent: existing, newContent: args.content ?? '' };
        } catch {
          // New file, no diff
        }
      } else if (name === 'edit_file') {
        label = `Edit file: ${args.path}`;
        try {
          const existing = fs.readFileSync(path.resolve(config.lanaDir, '..', args.path), 'utf8');
          const newContent = existing.replace(args.old_string, args.new_string);
          diff = { filePath: args.path, oldContent: existing, newContent };
        } catch {
          content = `Replace: ${(args.old_string ?? '').slice(0, 100)}\nWith: ${(args.new_string ?? '').slice(0, 100)}`;
        }
      } else {
        content = JSON.stringify(args, null, 2).slice(0, 300);
      }

      setPendingConfirm({ toolCall, args, label, content, warning, diff, resolve });
    });
  }, [config.lanaDir]);

  // Checkpoint: pause the agent loop and ask the user what to do
  const getCheckpoint = useCallback((reason: string): Promise<CheckpointChoice> => {
    return new Promise<CheckpointChoice>((resolve) => {
      setPendingCheckpoint({ reason, resolve });
    });
  }, []);

  // Run the agent turn (agentic tool loop)
  // IMPORTANT: We maintain a local copy of messages because React state updates
  // (via dispatch) don't take effect until re-render. Within this async loop,
  // msgState.messages would be stale — the LLM would never see tool results.
  const runAgentTurn = useCallback(async (userContent: string, hasAttachedFiles = false) => {
    setIsAgentRunning(true);
    setLoopCount(0);

    // Detect flow and build an optimized system prompt for this turn
    const isFirstTurn = msgState.turnCount === 0;
    const flow = hasAttachedFiles ? 'files-attached' as const : detectFlow(userContent, isFirstTurn);
    const workDir = process.env['LANA_WORK_DIR'] || process.cwd();
    const optimizedPrompt = buildSystemPrompt(flow, { lanaDir: config.lanaDir, workDir });

    // Update the system prompt for this turn
    dispatch({ type: 'set_system', content: optimizedPrompt });

    // Local copy of messages that we update synchronously within the loop.
    // We add the user message HERE (not via dispatch) because dispatch is async
    // and won't be visible within this function's closure.
    // Use the optimized system prompt in the local copy too.
    let localMessages: ChatMessage[] = [
      { role: 'system', content: optimizedPrompt },
      ...msgState.messages.filter(m => m.role !== 'system'),
      { role: 'user', content: userContent },
    ];

    // Also dispatch so React state eventually catches up
    dispatch({ type: 'add_user', content: userContent });

    // When user attached @files, pre-seed synthetic startup tool results so the
    // model thinks project_detect/memory already ran and skips straight to the task.
    // Small models follow their trained patterns rigidly — this satisfies the pattern.
    if (hasAttachedFiles) {
      const fakeDetectId = `preseed_detect_${Date.now()}`;
      const fakeMemoryId = `preseed_memory_${Date.now()}`;
      localMessages = [
        ...localMessages,
        {
          role: 'assistant',
          tool_calls: [
            { id: fakeDetectId, type: 'function', function: { name: 'project_detect', arguments: '{}' } },
            { id: fakeMemoryId, type: 'function', function: { name: 'memory', arguments: '{"action":"read"}' } },
          ],
        },
        { role: 'tool', content: 'Project context loaded. User has attached files — focus on those.', tool_call_id: fakeDetectId, name: 'project_detect' },
        { role: 'tool', content: 'No relevant memories. Proceed with the attached files.', tool_call_id: fakeMemoryId, name: 'memory' },
      ];
    }

    let loops = 0;
    const maxLoops = config.maxToolLoops;
    let lastToolCallSig = '';  // detect repeated identical tool calls

    while (true) {
      loops++;
      setLoopCount(loops);

      // Max loops checkpoint — ask user instead of silently stopping
      if (loops > maxLoops) {
        addItem({ type: 'status', content: `Reached ${maxLoops} tool loops.` });
        const choice = await getCheckpoint(
          `Reached ${maxLoops} tool call limit. Continue working or stop?`
        );
        if (choice === 'continue') {
          // Reset counter and keep going
          loops = 1;
          continue;
        } else {
          break;
        }
      }

      // Mid-loop compaction: check context usage BEFORE the next API call
      // so we don't send a prompt that exceeds the context window.
      const midLoopTokens = Math.ceil(JSON.stringify(localMessages).length / 4);
      if (shouldCompact(midLoopTokens, config.contextSize, config.compactTriggerPct)) {
        addItem({ type: 'status', content: `Context at ~${Math.round((midLoopTokens / config.contextSize) * 100)}% — compacting...` });
        try {
          const compResult = await compactMessages(localMessages, config, (msgs) =>
            Math.ceil(msgs.reduce((s, m) => s + (m.content?.length ?? 0) + (m.tool_calls ? JSON.stringify(m.tool_calls).length : 0), 0) / 4)
          );
          if (compResult.compactedCount > 0) {
            localMessages = compResult.messages;
            dispatch({ type: 'replace_messages', messages: localMessages });
            addItem({ type: 'status', content: `Compacted ${compResult.compactedCount} messages (${compResult.tokensBefore} → ${compResult.tokensAfter} tokens)` });
          }
        } catch {
          // Compaction failed mid-loop — emergency trim to keep going
          localMessages = emergencyTrim(localMessages);
          dispatch({ type: 'replace_messages', messages: localMessages });
          addItem({ type: 'status', content: 'Emergency trim applied mid-loop to stay within context.' });
        }
      }

      // Health check
      const healthy = await healthCheck(config);
      if (!healthy) {
        addItem({ type: 'error', content: `Server not responding at ${config.apiUrl}` });
        break;
      }

      // Stream the completion
      setStreamPhase('thinking');
      setStreamContent('');
      setThinkContent('');
      setAbortReason(undefined);

      const abortController = new AbortController();
      abortRef.current = abortController;

      const callbacks: StreamCallbacks = {
        onText: (text) => {
          setStreamPhase('streaming');
          setStreamContent(prev => prev + text);
        },
        onThinkStart: () => {
          setStreamPhase('thinking');
        },
        onThink: (text) => {
          setThinkContent(prev => prev + text);
        },
        onThinkEnd: () => {
          setStreamPhase('streaming');
        },
      };

      let result: StreamResult;
      try {
        result = await streamChatCompletion(
          localMessages,  // Use local copy, not stale React state
          toolDefs,
          config,
          callbacks,
          abortController.signal,
        );
      } catch (err: any) {
        addItem({ type: 'error', content: `API error: ${err.message}` });
        break;
      }

      setPromptTokens(result.promptTokens);
      setCompletionTokens(result.completionTokens);

      if (result.aborted) {
        setAbortReason(result.abortReason);
        setStreamPhase('done');
        if (result.content) {
          dispatch({ type: 'add_assistant', content: result.content });
          addItem({ type: 'assistant', content: result.content });
        }
        break;
      }

      // Build assistant message and add to both local + React state
      const assistantMsg: ChatMessage = { role: 'assistant' };
      if (result.content) assistantMsg.content = result.content;
      if (result.toolCalls.length > 0) assistantMsg.tool_calls = result.toolCalls;
      localMessages = [...localMessages, assistantMsg];

      dispatch({
        type: 'add_assistant',
        content: result.content,
        toolCalls: result.toolCalls.length > 0 ? result.toolCalls : undefined,
      });

      // Flush streamed content to conversation history
      if (result.content) {
        addItem({ type: 'assistant', content: result.content });
      }
      setStreamPhase('idle');
      setStreamContent('');
      setThinkContent('');

      // Handle finish_reason: "length" — model hit max_tokens, output was truncated.
      // This can happen mid-text or mid-tool-call. In either case, discard any
      // partial tool calls (they may be malformed) and push the model to continue.
      if (result.finishReason === 'length') {
        addItem({ type: 'status', content: '⚠ Response hit token limit — continuing...' });

        // If there were partial tool calls, strip them from the assistant message
        // we already pushed to localMessages (last entry).
        if (result.toolCalls.length > 0) {
          const lastMsg = localMessages[localMessages.length - 1]!;
          if (lastMsg.role === 'assistant' && lastMsg.tool_calls) {
            delete lastMsg.tool_calls;
            localMessages = [...localMessages.slice(0, -1), lastMsg];
          }
        }

        const continueMsg: ChatMessage = {
          role: 'user',
          content: '[system: Your previous response was cut off because it exceeded the token limit. Continue EXACTLY where you left off — finish the text you were writing. Do not restart or summarize what you already said.]',
        };
        localMessages = [...localMessages, continueMsg];
        continue;
      }

      // If no tool calls — checkpoint with user instead of silently exiting
      if (result.toolCalls.length === 0) {
        const choice = await getCheckpoint(
          'Model responded with text but didn\'t call any tools.'
        );
        if (choice === 'continue') {
          // Push the model to use tools
          const pushMsg: ChatMessage = {
            role: 'user',
            content: '[system: The user wants you to continue working. Use your tools to make progress on the task. Do not just describe what you would do — actually do it by calling the appropriate tools.]',
          };
          localMessages = [...localMessages, pushMsg];
          dispatch({ type: 'add_user', content: pushMsg.content! });
          continue;
        } else if (choice === 'redirect') {
          // User will type a new message — break out and let the prompt handle it
          break;
        } else {
          // 'done' — ask the model to wrap up with next action items
          const wrapUpMsg: ChatMessage = {
            role: 'user',
            content: '[system: The user is satisfied with the current progress and wants to pause here. Give a brief, friendly wrap-up. Then list the next action items or follow-up tasks you would suggest, as a short bulleted list. Do NOT use any tools — just respond with text.]',
          };
          localMessages = [...localMessages, wrapUpMsg];
          dispatch({ type: 'add_user', content: wrapUpMsg.content! });

          // One more LLM call for the wrap-up (no tools)
          setStreamPhase('thinking');
          setStreamContent('');
          setThinkContent('');
          const wrapAbort = new AbortController();
          abortRef.current = wrapAbort;
          try {
            const wrapResult = await streamChatCompletion(
              localMessages, toolDefs, config, callbacks, wrapAbort.signal,
            );
            if (wrapResult.content) {
              const wrapAssistant: ChatMessage = { role: 'assistant', content: wrapResult.content };
              localMessages = [...localMessages, wrapAssistant];
              dispatch({ type: 'add_assistant', content: wrapResult.content });
              addItem({ type: 'assistant', content: wrapResult.content });
            }
            setPromptTokens(wrapResult.promptTokens);
            setCompletionTokens(wrapResult.completionTokens);
          } catch {
            // wrap-up failed — not critical, just move on
          }
          setStreamPhase('idle');
          setStreamContent('');
          setThinkContent('');
          break;
        }
      }

      // Detect repeated identical tool calls (loop detection)
      const currentSig = result.toolCalls.map(tc => `${tc.function.name}:${tc.function.arguments}`).join('|');
      if (currentSig === lastToolCallSig) {
        addItem({ type: 'status', content: '⚠ Loop detected — same tool calls repeated. Stopping.' });
        for (const tc of result.toolCalls) {
          const loopMsg: ChatMessage = {
            role: 'tool',
            content: 'ERROR: Loop detected — you called the same tool with the same arguments as the previous turn. Please proceed differently or provide a final answer.',
            tool_call_id: tc.id,
            name: tc.function.name,
          };
          localMessages = [...localMessages, loopMsg];
          dispatch({
            type: 'add_tool_result',
            toolCallId: tc.id,
            name: tc.function.name,
            result: loopMsg.content!,
          });
        }
        break;
      }
      lastToolCallSig = currentSig;

      // Execute tool calls — parallel when possible, sequential when confirmation needed
      let taskComplete = false;
      let userRejected = false;

      // Partition tool calls: auto-approved vs needs-confirmation
      const parsedCalls = result.toolCalls.map(tc => {
        let args: Record<string, any>;
        try { args = JSON.parse(tc.function.arguments); } catch { args = {}; }
        return { tc, args, needsConfirm: needsConfirmation(tc.function.name, args) };
      });

      const autoApproved = parsedCalls.filter(c => !c.needsConfirm);
      const needsApproval = parsedCalls.filter(c => c.needsConfirm);

      // Run auto-approved tools in parallel
      if (autoApproved.length > 0) {
        // Display all tool calls first
        for (const { tc, args } of autoApproved) {
          addItem({ type: 'tool_call', content: tc.function.name, toolName: tc.function.name, toolArgs: args });
          sessionRef.current?.trackToolCall(tc.function.name, args);
        }

        const parallelResults = await Promise.all(
          autoApproved.map(({ tc }) =>
            executeTool(tc.function.name, tc.function.arguments, config.lanaDir, process.cwd())
          )
        );

        for (let i = 0; i < autoApproved.length; i++) {
          const { tc } = autoApproved[i]!;
          const toolResult = parallelResults[i]!;
          const resultText = toolResult.output || toolResult.error || '(no output)';

          const toolMsg: ChatMessage = { role: 'tool', content: resultText, tool_call_id: tc.id, name: tc.function.name };
          localMessages = [...localMessages, toolMsg];
          dispatch({ type: 'add_tool_result', toolCallId: tc.id, name: tc.function.name, result: resultText });
          addItem({ type: 'tool_result', content: resultText, toolName: tc.function.name, toolResult: resultText });

          if (tc.function.name === 'task_complete') taskComplete = true;
        }
      }

      // Run needs-approval tools sequentially (each needs user input)
      if (!taskComplete) {
        for (const { tc, args } of needsApproval) {
          addItem({ type: 'tool_call', content: tc.function.name, toolName: tc.function.name, toolArgs: args });
          sessionRef.current?.trackToolCall(tc.function.name, args);

          const accepted = await getConfirmation(tc, args);
          if (!accepted) {
            const rejectMsg: ChatMessage = { role: 'tool', content: 'User rejected this action.', tool_call_id: tc.id, name: tc.function.name };
            localMessages = [...localMessages, rejectMsg];
            dispatch({ type: 'add_tool_result', toolCallId: tc.id, name: tc.function.name, result: 'User rejected this action.' });
            addItem({ type: 'tool_result', content: 'rejected', toolName: tc.function.name });
            userRejected = true;
            break;
          }

          const toolResult = await executeTool(tc.function.name, tc.function.arguments, config.lanaDir, process.cwd());
          const resultText = toolResult.output || toolResult.error || '(no output)';

          const toolMsg: ChatMessage = { role: 'tool', content: resultText, tool_call_id: tc.id, name: tc.function.name };
          localMessages = [...localMessages, toolMsg];
          dispatch({ type: 'add_tool_result', toolCallId: tc.id, name: tc.function.name, result: resultText });
          addItem({ type: 'tool_result', content: resultText, toolName: tc.function.name, toolResult: resultText });

          if (tc.function.name === 'task_complete') { taskComplete = true; break; }
        }
      }

      if (taskComplete || userRejected) break;
    }

    // Sync final local messages to React state
    dispatch({ type: 'replace_messages', messages: localMessages });

    // Track the turn for session persistence
    sessionRef.current?.trackTurn();

    // Auto-compaction: check if context usage exceeds trigger threshold
    const estTokens = Math.ceil(JSON.stringify(localMessages).length / 4);
    if (shouldCompact(estTokens, config.contextSize, config.compactTriggerPct)) {
      addItem({ type: 'status', content: 'Context getting large — compacting conversation...' });
      try {
        const result = await compactMessages(localMessages, config, (msgs) =>
          Math.ceil(msgs.reduce((s, m) => s + (m.content?.length ?? 0) + (m.tool_calls ? JSON.stringify(m.tool_calls).length : 0), 0) / 4)
        );
        if (result.compactedCount > 0) {
          dispatch({ type: 'replace_messages', messages: result.messages });
          sessionRef.current?.trackCompaction({
            at: new Date().toISOString(),
            messages_compacted: result.compactedCount,
            tokens_before: result.tokensBefore,
            tokens_after: result.tokensAfter,
            summary: result.summary,
          });
          addItem({ type: 'status', content: `Compacted ${result.compactedCount} messages (${result.tokensBefore} → ${result.tokensAfter} tokens)` });
        }
      } catch (err: any) {
        // Compaction failed — try emergency trim
        const trimmed = emergencyTrim(localMessages);
        dispatch({ type: 'replace_messages', messages: trimmed });
        addItem({ type: 'status', content: `Compaction failed (${err.message}). Emergency trim applied.` });
      }
    }

    // Auto-save session periodically (every 3 turns)
    if (sessionRef.current && msgState.turnCount > 0 && msgState.turnCount % 3 === 0) {
      try {
        sessionRef.current.save(localMessages);
      } catch { /* best effort */ }
    }

    setStreamPhase('idle');
    setIsAgentRunning(false);
    abortRef.current = null;
  }, [msgState.messages, config, toolDefs, dispatch, addItem, needsConfirmation, getConfirmation, getCheckpoint]);

  // Handle file picker selection — insert @filepath into prompt so user can keep typing
  const handleFileSelect = useCallback((filePath: string) => {
    setShowFilePicker(false);
    const relPath = filePath.replace(process.cwd() + '/', '');
    // Reconstruct the prompt: prefix + @relPath + trailing space for continued typing
    const newValue = `${filePickerPrefix}@${relPath} `;
    setPromptInitialValue(newValue);
    addItem({ type: 'status', content: `  attached: ${relPath}` });
    setFilePickerPrefix('');
  }, [filePickerPrefix, addItem]);

  const handleFileCancel = useCallback(() => {
    setShowFilePicker(false);
    setFilePickerPrefix('');
    addItem({ type: 'status', content: '  cancelled' });
  }, [addItem]);

  // Handle @ typed in the prompt — triggers file picker immediately (no Enter needed)
  const handleAtSign = useCallback((prefix: string) => {
    setFilePickerPrefix(prefix);
    setShowFilePicker(true);
  }, []);

  // Handle / typed — show command picker
  const handleSlash = useCallback(() => {
    setShowCommandPicker(true);
  }, []);

  // Handle command selected from picker — populate the prompt so user can press Enter
  const handleCommandSelect = useCallback((commandName: string) => {
    setShowCommandPicker(false);
    setPromptInitialValue(`/${commandName}`);
  }, []);

  const handleCommandCancel = useCallback(() => {
    setShowCommandPicker(false);
  }, []);

  // Handle user input (Enter pressed)
  const handleInput = useCallback(async (text: string) => {
    if (!text.trim()) return;

    // Handle commands
    if (text.startsWith('/')) {
      const cmdParts = text.slice(1).split(/\s+/);
      const cmd = cmdParts[0]?.toLowerCase();
      const cmdArgs = cmdParts.slice(1).join(' ');
      switch (cmd) {
        case 'quit':
        case 'exit':
          // Save session before exit
          if (sessionRef.current && msgState.turnCount > 0) {
            sessionRef.current.save(msgState.messages);
            addItem({ type: 'status', content: `Session saved: ${sessionRef.current.id}` });
          }
          // Shut down embedding server
          modelManagerRef.current?.shutdown().catch(() => {});
          exit();
          return;
        case 'clear':
          setItems([{ id: 'banner', type: 'banner', content: '' }]);
          dispatch({ type: 'clear' });
          dispatch({ type: 'set_system', content: systemPrompt });
          addItem({ type: 'status', content: 'Conversation cleared.' });
          return;
        case 'status': {
          const est = estimateTokens();
          const pct = Math.round((est / config.contextSize) * 100);
          const workDir = process.env['LANA_WORK_DIR'] || process.cwd();
          const indexExists = fs.existsSync(path.join(workDir, '.lana', 'index.json'));
          const dbExists = fs.existsSync(path.join(workDir, '.lana', 'index.db'));
          addItem({
            type: 'status',
            content: [
              `Model: ${currentModel}  Mode: ${acceptMode}`,
              `Context: ${est}/${config.contextSize} tokens (${pct}%)`,
              `Turns: ${msgState.turnCount}  Session: ${sessionRef.current?.id ?? 'none'}`,
              `Dir: ${workDir}`,
              `Index: ${indexExists ? 'yes' : 'no'}  Vectors: ${dbExists ? 'yes' : 'no'}`,
            ].join('\n'),
          });
          return;
        }
        case 'compact': {
          const est = estimateTokens();
          if (msgState.messages.length < 4) {
            addItem({ type: 'status', content: 'Nothing to compact — conversation is short.' });
            return;
          }
          addItem({ type: 'status', content: 'Compacting conversation...' });
          setIsAgentRunning(true);
          try {
            const result = await compactMessages(msgState.messages, config, (msgs) =>
              Math.ceil(msgs.reduce((s, m) => s + (m.content?.length ?? 0) + (m.tool_calls ? JSON.stringify(m.tool_calls).length : 0), 0) / 4)
            );
            if (result.compactedCount > 0) {
              dispatch({ type: 'replace_messages', messages: result.messages });
              sessionRef.current?.trackCompaction({
                at: new Date().toISOString(),
                messages_compacted: result.compactedCount,
                tokens_before: result.tokensBefore,
                tokens_after: result.tokensAfter,
                summary: result.summary,
              });
              addItem({ type: 'status', content: `Compacted ${result.compactedCount} messages (${result.tokensBefore} → ${result.tokensAfter} tokens)` });
            } else {
              addItem({ type: 'status', content: 'Nothing to compact.' });
            }
          } catch (err: any) {
            addItem({ type: 'error', content: `Compaction failed: ${err.message}` });
          }
          setIsAgentRunning(false);
          return;
        }
        case 'model': {
          if (!cmdArgs) {
            addItem({ type: 'status', content: `Current model: ${currentModel}\nAvailable: ${config.modelNames.join(', ')}` });
            return;
          }
          const newModel = cmdArgs.trim();
          if (!config.modelNames.includes(newModel)) {
            addItem({ type: 'error', content: `Unknown model: ${newModel}. Available: ${config.modelNames.join(', ')}` });
            return;
          }
          if (newModel === currentModel) {
            addItem({ type: 'status', content: `Already using ${newModel}.` });
            return;
          }
          if (config.useProxy) {
            // Proxy mode: just switch the API model name
            configRef.current = { ...configRef.current, currentModel: newModel, apiModel: newModel };
            setCurrentModel(newModel);
            addItem({ type: 'status', content: `Switched to ${newModel} (proxy mode — no server restart needed).` });
            return;
          }
          // Direct mode: restart llama-server with new model
          addItem({ type: 'status', content: `Switching to ${newModel} — restarting server...` });
          setIsAgentRunning(true);
          try {
            execSync(`bash "${path.join(config.lanaDir, 'setup.sh')}" switch "${newModel}"`, {
              env: { ...process.env, CURRENT_MODEL: newModel },
              timeout: 120_000,
              stdio: 'pipe',
            });
            configRef.current = { ...configRef.current, currentModel: newModel };
            setCurrentModel(newModel);
            addItem({ type: 'status', content: `Model switched to ${newModel}. Server ready.` });
          } catch (err: any) {
            addItem({ type: 'error', content: `Model switch failed: ${err.message}` });
          }
          setIsAgentRunning(false);
          return;
        }
        case 'accept': {
          if (!cmdArgs) {
            addItem({ type: 'status', content: `Current mode: ${acceptMode}\nOptions: confirm, auto-edit, yolo` });
            return;
          }
          const mode = cmdArgs.trim() as 'confirm' | 'auto-edit' | 'yolo';
          if (!['confirm', 'auto-edit', 'yolo'].includes(mode)) {
            addItem({ type: 'error', content: `Invalid mode: ${mode}. Options: confirm, auto-edit, yolo` });
            return;
          }
          setAcceptMode(mode);
          configRef.current = { ...configRef.current, acceptMode: mode };
          addItem({ type: 'status', content: `Permission mode set to: ${mode}` });
          return;
        }
        case 'search': {
          if (!cmdArgs) {
            addItem({ type: 'error', content: 'Usage: /search <query>' });
            return;
          }
          const workDir = process.env['LANA_WORK_DIR'] || process.cwd();
          setIsAgentRunning(true);
          try {
            let provider = modelManagerRef.current?.getProvider() ?? null;
            const results = await hybridSearch(cmdArgs, workDir, provider, { mode: 'hybrid', maxResults: 20 });
            const formatted = formatSearchResults(results);
            addItem({ type: 'status', content: formatted });
          } catch (err: any) {
            addItem({ type: 'error', content: `Search failed: ${err.message}` });
          }
          setIsAgentRunning(false);
          return;
        }
        case 'load': {
          const workDir = process.env['LANA_WORK_DIR'] || process.cwd();
          const loadPath = cmdArgs ? path.resolve(workDir, cmdArgs.trim()) : workDir;
          if (!fs.existsSync(loadPath)) {
            addItem({ type: 'error', content: `Path not found: ${loadPath}` });
            return;
          }
          try {
            const stat = fs.statSync(loadPath);
            if (!stat.isDirectory()) {
              addItem({ type: 'error', content: `Not a directory: ${loadPath}` });
              return;
            }
            // Read directory tree (shallow — top 2 levels)
            const lines: string[] = [`Project: ${loadPath}`, ''];
            const readDir = (dir: string, prefix: string, depth: number) => {
              if (depth > 2) return;
              const entries = fs.readdirSync(dir, { withFileTypes: true })
                .filter(e => !e.name.startsWith('.') && !['node_modules', '__pycache__', 'dist', 'build', '.git', 'venv', '.venv', 'target'].includes(e.name))
                .sort((a, b) => {
                  if (a.isDirectory() !== b.isDirectory()) return a.isDirectory() ? -1 : 1;
                  return a.name.localeCompare(b.name);
                });
              for (const e of entries) {
                if (e.isDirectory()) {
                  lines.push(`${prefix}${e.name}/`);
                  readDir(path.join(dir, e.name), prefix + '  ', depth + 1);
                } else {
                  lines.push(`${prefix}${e.name}`);
                }
              }
            };
            readDir(loadPath, '  ', 0);

            // Read key files for context
            const keyFiles = ['README.md', 'package.json', 'Cargo.toml', 'go.mod', 'pyproject.toml'];
            const keyContents: string[] = [];
            for (const name of keyFiles) {
              const fp = path.join(loadPath, name);
              try {
                const content = fs.readFileSync(fp, 'utf8');
                if (content.length <= 5000) {
                  keyContents.push(`\n--- ${name} ---\n${content}`);
                }
              } catch { /* not present */ }
            }

            // Check for existing index
            const indexPath = path.join(loadPath, '.lana', 'index.json');
            let indexInfo = '';
            if (fs.existsSync(indexPath)) {
              try {
                const idx = JSON.parse(fs.readFileSync(indexPath, 'utf8'));
                indexInfo = `\nIndex: ${Array.isArray(idx) ? idx.length : 0} files indexed`;
              } catch { /* malformed */ }
            }

            const projectContext = lines.join('\n') + keyContents.join('\n') + indexInfo;

            // Inject as a user message with project context
            const contextMsg = `I've loaded the project at ${loadPath}. Here's the structure:\n\n${projectContext}`;
            dispatch({ type: 'add_user', content: contextMsg });
            dispatch({ type: 'add_assistant', content: `Project loaded: ${loadPath}` });
            addItem({ type: 'status', content: `Loaded project: ${loadPath} (${lines.length - 2} entries)${indexInfo}` });
          } catch (err: any) {
            addItem({ type: 'error', content: `Failed to load project: ${err.message}` });
          }
          return;
        }
        case 'history': {
          const sessions = listSessions(config, cmdArgs || undefined);
          if (sessions.length === 0) {
            addItem({ type: 'status', content: 'No sessions found.' });
            return;
          }
          const lines = sessions.map(s => {
            const date = new Date(s.start).toLocaleDateString();
            const time = new Date(s.start).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
            const dir = s.work_dir.replace(process.env['HOME'] ?? '', '~');
            return `  ${s.id.slice(0, 15)}  ${date} ${time}  ${s.turns}t  ${dir}  ${s.summary.slice(0, 60)}`;
          });
          addItem({ type: 'status', content: `Sessions:\n${lines.join('\n')}\n\nUse /recall <id> to load a session.` });
          return;
        }
        case 'recall': {
          if (!cmdArgs) {
            addItem({ type: 'error', content: 'Usage: /recall <session-id or prefix>' });
            return;
          }
          const session = loadSession(config, cmdArgs.trim());
          if (!session) {
            addItem({ type: 'error', content: `Session not found: ${cmdArgs}` });
            return;
          }
          const context = buildRecallContext(session);
          dispatch({ type: 'add_user', content: `[Previous Session Context]\n${context}` });
          dispatch({ type: 'add_assistant', content: 'I have the context from the previous session. How can I help?' });
          addItem({ type: 'status', content: `Recalled session ${session.id} (${session.turns} turns)` });
          return;
        }
        case 'index': {
          const workDir = process.env['LANA_WORK_DIR'] || process.cwd();
          const lanaDir = path.join(workDir, '.lana');
          const indexJsonPath = path.join(lanaDir, 'index.json');
          const indexDbPath = path.join(lanaDir, 'index.db');

          // Parse /index arguments: /index [path] [--force] [--type ext,ext]
          const indexTokens = text.slice('/index'.length).trim().split(/\s+/).filter(Boolean);
          let forceReindex = false;
          let typeFilter = '';   // comma-separated extensions (e.g., "ts,tsx,js")
          let targetDir = '';    // subdirectory to scope indexing to
          for (let ti = 0; ti < indexTokens.length; ti++) {
            const tok = indexTokens[ti]!;
            if (tok === '--force' || tok === '-f') {
              forceReindex = true;
            } else if ((tok === '--type' || tok === '-t') && indexTokens[ti + 1]) {
              typeFilter = indexTokens[++ti]!;
            } else if (!tok.startsWith('-')) {
              // Positional arg = target directory
              targetDir = tok;
            }
          }

          // Resolve target directory relative to workDir
          const indexTargetDir = targetDir
            ? path.resolve(workDir, targetDir)
            : workDir;
          if (targetDir && !fs.existsSync(indexTargetDir)) {
            addItem({ type: 'error', content: `Directory not found: ${targetDir}` });
            return;
          }

          // Build scope description for status messages
          const scopeParts: string[] = [];
          if (targetDir) scopeParts.push(targetDir);
          if (typeFilter) scopeParts.push(`*.{${typeFilter}}`);
          const scopeDesc = scopeParts.length > 0 ? ` (${scopeParts.join(' ')})` : '';

          // Fast freshness check — skip if nothing changed since last index
          if (!forceReindex && !targetDir && !typeFilter && fs.existsSync(indexJsonPath)) {
            try {
              // Check if any source files are newer than the index
              const hasNewer = execSync(
                `find "${workDir}" -type f \\( -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.py' -o -name '*.rs' -o -name '*.go' -o -name '*.swift' -o -name '*.java' -o -name '*.rb' -o -name '*.c' -o -name '*.cpp' \\) -not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/dist/*' -not -path '*/build/*' -newer "${indexJsonPath}" 2>/dev/null | head -1`,
                { encoding: 'utf8', timeout: 5000 }
              ).trim();

              if (!hasNewer) {
                // No files newer than index — we're up to date
                const meta = JSON.parse(fs.readFileSync(indexJsonPath, 'utf8'));
                const fileCount = Array.isArray(meta) ? meta.length : 0;
                let chunkInfo = '';
                if (fs.existsSync(indexDbPath)) {
                  try {
                    const { VectorStore } = await import('./embedding/vector-store.js');
                    const store = new VectorStore(workDir);
                    const stats = store.getStats();
                    chunkInfo = `, ${stats.chunkCount} vector chunks`;
                    store.close();
                  } catch { /* no db stats */ }
                }
                addItem({ type: 'status', content: `Index is current (${fileCount} files${chunkInfo}). Use /index --force to rebuild.` });
                return;
              }
            } catch {
              // Freshness check failed — fall through to full index
            }
          }

          if (forceReindex && fs.existsSync(lanaDir)) {
            try {
              if (fs.existsSync(indexJsonPath)) fs.unlinkSync(indexJsonPath);
              if (fs.existsSync(indexDbPath)) fs.unlinkSync(indexDbPath);
              const depsPath = path.join(lanaDir, 'deps.json');
              if (fs.existsSync(depsPath)) fs.unlinkSync(depsPath);
              addItem({ type: 'status', content: `Cleared existing index. Rebuilding${scopeDesc}...` });
            } catch { /* best effort */ }
          }

          addItem({ type: 'status', content: `Starting project indexing${scopeDesc}...` });
          setIsAgentRunning(true);

          // Phases 1-4: Node-native tree-sitter pipeline
          try {
            const { ProjectIndexer } = await import('./ast/indexer.js');
            const indexer = new ProjectIndexer();
            indexer.on('status', (msg: string) => addItem({ type: 'status', content: msg }));
            indexer.on('progress', (_pct: number, msg: string) => addItem({ type: 'status', content: msg }));

            const indexResult = await indexer.indexProject(workDir, {
              targetDir: targetDir || undefined,
              typeFilter: typeFilter ? typeFilter.split(',') : undefined,
              force: forceReindex,
            });
          } catch (err: any) {
            addItem({ type: 'error', content: `Index failed: ${err.message}` });
          }

          // Phase 6: embedding
          if (modelManagerRef.current && fs.existsSync(config.embeddingModelPath)) {
            const indexer = new EmbeddingIndexer(modelManagerRef.current);
            indexer.on('status', (msg: string) => {
              addItem({ type: 'status', content: msg });
            });
            indexer.on('progress', (_pct: number, msg: string) => {
              // Could update a progress bar here — for now, log milestones
            });
            indexer.on('error', (err: Error) => {
              addItem({ type: 'error', content: `Embedding error: ${err.message}` });
            });
            try {
              const result = await indexer.indexProject(workDir);
              if (result.chunksEmbedded > 0) {
                addItem({ type: 'status', content: `Vector index ready — ${result.chunksEmbedded} chunks from ${result.filesProcessed} files. Semantic search enabled.` });
              }
            } catch (err: any) {
              addItem({ type: 'error', content: `Embedding failed: ${err.message}. Regex search still available.` });
            }
          } else if (!fs.existsSync(config.embeddingModelPath)) {
            addItem({ type: 'status', content: 'Embedding model not found — skipping vector indexing. Regex search available.' });
          }

          setIsAgentRunning(false);
          return;
        }
        case 'help':
          addItem({
            type: 'status',
            content: [
              'Commands:',
              '  /help                       — Show this help',
              '  /status                     — Show session + context info',
              '  /index [path] [flags]       — Index project (--type ext, --force)',
              '  /search <query>             — Search project index (hybrid)',
              '  /load [path]                — Load project structure into context',
              '  /model [name]               — Show or switch model',
              '  /compact                    — Compress conversation context',
              '  /accept [mode]              — Set permission mode (confirm/auto-edit/yolo)',
              '  /history [query]            — List past sessions',
              '  /recall <id>                — Load previous session context',
              '  /clear                      — Clear conversation',
              '  /quit                       — Exit',
              '',
              'Shortcuts:',
              '  @file.ts                    — Attach file contents to prompt',
              '  @directory/                 — Attach directory listing',
              '  Drag files from Finder      — Auto-detected as attachments',
            ].join('\n'),
          });
          return;
        case 'debug':
        case 'd': {
          const prev = debugRef.current ?? false;
          debugRef.current = !prev;
          addItem({ type: 'status', content: `Debug mode: ${!prev ? 'ON' : 'OFF'}` });
          return;
        }
        case 'version':
        case 'v':
          addItem({ type: 'status', content: `LANA CODER v0.4.0\nModel: ${config.apiModel}\nServer: ${config.apiUrl}` });
          return;
        case 'subagent':
        case 'sa':
          addItem({ type: 'status', content: 'Subagents are available in the terminal (bash) interface.\nUse: /sa <research|plan|execute> <task>' });
          return;
        case 'plan':
        case 'fork':
        case 'undo':
        case 'memory':
        case 'mem':
          addItem({ type: 'status', content: `/${cmd} is available in the terminal (bash) interface.` });
          return;
        default:
          addItem({ type: 'error', content: `Unknown command: /${cmd}` });
          return;
      }
    }

    // Auto-detect dragged/pasted file paths — treat bare absolute paths as @attachments
    // When you drag a file into the terminal, it pastes the absolute path as text
    let processedText = text;
    const words = text.trim().split(/\s+/);
    const detectedPaths: string[] = [];
    for (const word of words) {
      // Match absolute paths (possibly with ~ prefix) that aren't already @-prefixed
      const resolved = word.startsWith('~/')
        ? path.join(process.env['HOME'] || '', word.slice(1))
        : word;
      if (path.isAbsolute(resolved) && !word.startsWith('@') && fs.existsSync(resolved)) {
        detectedPaths.push(resolved);
      }
    }
    // If we found bare paths, convert them to @references
    if (detectedPaths.length > 0) {
      for (const dp of detectedPaths) {
        processedText = processedText.replace(dp, `@${dp}`);
        // Also handle ~/... form
        const home = process.env['HOME'] || '';
        if (home && dp.startsWith(home)) {
          processedText = processedText.replace(`~${dp.slice(home.length)}`, `@${dp}`);
        }
      }
    }

    // Expand @file and @directory references — read content and include it
    let expandedText = processedText;
    const atRefs = processedText.match(/@(\S+)/g);
    if (atRefs) {
      const attachments: string[] = [];
      for (const ref of atRefs) {
        const filePath = ref.slice(1); // remove @
        const fullPath = path.isAbsolute(filePath) ? filePath : path.resolve(process.cwd(), filePath);
        try {
          const stat = fs.statSync(fullPath);
          if (stat.isDirectory()) {
            // Directory: list contents + read key files
            const dirEntries = fs.readdirSync(fullPath)
              .filter((n: string) => !n.startsWith('.'))
              .sort();
            const listing = dirEntries.map((n: string) => {
              const s = fs.statSync(path.join(fullPath, n));
              return s.isDirectory() ? `  ${n}/` : `  ${n}`;
            }).join('\n');

            let dirContent = `<directory path="${filePath}">\nContents:\n${listing}\n`;

            // Auto-include small, important files (README, configs)
            const importantFiles = ['README.md', 'README', 'package.json', 'Cargo.toml',
              'Makefile', 'go.mod', 'pyproject.toml', 'setup.py', 'build.gradle'];
            for (const name of importantFiles) {
              const fp = path.join(fullPath, name);
              try {
                const content = fs.readFileSync(fp, 'utf8');
                if (content.length <= config.fileSizeLimit) {
                  dirContent += `\n--- ${name} ---\n${content}\n`;
                }
              } catch { /* not present */ }
            }

            dirContent += '</directory>';
            attachments.push(dirContent);
          } else {
            // File: read content
            const content = fs.readFileSync(fullPath, 'utf8');
            const truncated = content.length > config.fileSizeLimit
              ? content.slice(0, config.fileSizeLimit) + '\n... (truncated)'
              : content;
            attachments.push(`<file path="${filePath}">\n${truncated}\n</file>`);
          }
        } catch {
          attachments.push(`<file path="${filePath}">\n(could not read file or directory)\n</file>`);
        }
      }
      if (attachments.length > 0) {
        expandedText = text + '\n\n'
          + 'The user has provided the following file(s) and/or directory listing(s). The contents are already included below — you do not need to read them again:\n\n'
          + attachments.join('\n\n');
      }
    }

    // Display user message in conversation (but don't dispatch — runAgentTurn handles it)
    addItem({ type: 'user', content: text });

    // Run agent turn — pass expanded text directly so it's added to localMessages
    // synchronously (dispatch is async and would be stale)
    const hasAttachedFiles = !!(atRefs && atRefs.length > 0);
    await runAgentTurn(expandedText, hasAttachedFiles);
  }, [addItem, exit, systemPrompt, estimateTokens, config, msgState.turnCount, runAgentTurn]);

  return (
    <Box flexDirection="column">
      {/* All static output (banner + conversation history) */}
      <Static items={items}>
        {(item) => {
          switch (item.type) {
            case 'banner':
              return (
                <Box key={item.id}>
                  <Banner
                    version="0.4.0"
                    model={currentModel}
                    contextSize={config.contextSize}
                  />
                </Box>
              );
            case 'user':
              return (
                <Box key={item.id} marginTop={1}>
                  <Text color="green" bold>{'|> '}</Text>
                  <Text>{item.content}</Text>
                </Box>
              );
            case 'assistant':
              return (
                <Box key={item.id} flexDirection="column" marginTop={1}>
                  <Text color="blue" bold>assistant</Text>
                  <MarkdownRenderer text={item.content} />
                </Box>
              );
            case 'tool_call':
              return (
                <Box key={item.id}>
                  <ToolCallDisplay
                    name={item.toolName!}
                    args={item.toolArgs!}
                    status="done"
                  />
                </Box>
              );
            case 'tool_result':
              return (
                <Box key={item.id} marginLeft={4}>
                  <Text dimColor>{(item.toolResult ?? item.content).split('\n').slice(0, 3).join('\n')}</Text>
                </Box>
              );
            case 'status':
              return (
                <Box key={item.id} marginTop={1}>
                  <Text dimColor>{item.content}</Text>
                </Box>
              );
            case 'error':
              return (
                <Box key={item.id} marginTop={1}>
                  <Text color="red">✕ {item.content}</Text>
                </Box>
              );
            default:
              return <Box key={item.id} />;
          }
        }}
      </Static>

      {/* Live streaming output */}
      {streamPhase !== 'idle' && (
        <StreamingOutput
          phase={streamPhase}
          content={streamContent}
          thinkContent={thinkContent}
          abortReason={abortReason}
        />
      )}

      {/* Confirmation dialog */}
      {pendingConfirm && (
        <Box flexDirection="column">
          {pendingConfirm.diff && (
            <DiffViewer
              filePath={pendingConfirm.diff.filePath}
              oldContent={pendingConfirm.diff.oldContent}
              newContent={pendingConfirm.diff.newContent}
            />
          )}
          <Confirmation
            label={pendingConfirm.label}
            content={pendingConfirm.diff ? undefined : pendingConfirm.content}
            warning={pendingConfirm.warning}
            onConfirm={() => {
              pendingConfirm.resolve(true);
              setPendingConfirm(null);
            }}
            onReject={() => {
              pendingConfirm.resolve(false);
              setPendingConfirm(null);
            }}
          />
        </Box>
      )}

      {/* Agent loop checkpoint */}
      {pendingCheckpoint && (
        <Checkpoint
          reason={pendingCheckpoint.reason}
          onChoice={(choice) => {
            pendingCheckpoint.resolve(choice);
            setPendingCheckpoint(null);
          }}
        />
      )}

      {/* Status bar */}
      {isAgentRunning && (
        <StatusBar
          turn={msgState.turnCount}
          loopCount={loopCount}
          maxLoops={config.maxToolLoops}
          estimatedTokens={estimateTokens()}
          contextSize={config.contextSize}
          promptTokens={promptTokens}
          completionTokens={completionTokens}
        />
      )}

      {/* File picker */}
      {showFilePicker && (
        <FilePicker
          startDir={process.cwd()}
          onSelect={handleFileSelect}
          onCancel={handleFileCancel}
        />
      )}

      {/* Command picker */}
      {showCommandPicker && (
        <CommandPicker
          commands={commandDefs}
          onSelect={handleCommandSelect}
          onCancel={handleCommandCancel}
        />
      )}

      {/* Input prompt — only shown when not streaming */}
      {!isAgentRunning && !pendingConfirm && !showFilePicker && !showCommandPicker && (
        <Prompt
          onSubmit={(text) => {
            setPromptInitialValue(undefined);
            handleInput(text);
          }}
          onAtSign={handleAtSign}
          onSlash={handleSlash}
          initialValue={promptInitialValue}
          historyFile={config.inputHistory}
          historySize={config.inputHistorySize}
        />
      )}
    </Box>
  );
}

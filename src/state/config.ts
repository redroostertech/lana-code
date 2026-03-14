// Reads configuration from environment variables set by the bash launcher
// Falls back to defaults matching config.sh

import * as fs from 'fs';
import * as path from 'path';

export interface LanaConfig {
  // API
  apiUrl: string;
  apiModel: string;
  useProxy: boolean;

  // Inference
  contextSize: number;
  temperature: number;
  maxTokens: number;
  frequencyPenalty: number;
  presencePenalty: number;

  // Agent
  autoConfirmRead: boolean;
  maxToolLoops: number;
  acceptMode: 'confirm' | 'auto-edit' | 'yolo';
  fileSizeLimit: number;

  // Paths
  lanaDir: string;
  historyDir: string;
  inputHistory: string;
  inputHistorySize: number;
  sessionDir: string;

  // Compaction
  compactTriggerPct: number;
  compactKeepTurns: number;
  compactEmergencyPct: number;
  compactSummaryMaxTokens: number;
  compactTemperature: number;

  // Tool results
  toolResultMaxLines: number;
  toolResultKeepHead: number;
  toolResultKeepTail: number;
  coldStorageEnabled: boolean;

  // Debug
  debug: boolean;

  // Models
  modelNames: string[];
  currentModel: string;

  // Embedding
  embeddingPort: number;
  embeddingModelPath: string;
  embeddingModelName: string;
  llamaServerBin: string;
  chatPort: number;
  chatModelCtx: number;
  chatModelNgl: number;
  threads: number;
}

function env(key: string, fallback: string): string {
  return process.env[key] ?? fallback;
}

function envBool(key: string, fallback: boolean): boolean {
  const val = process.env[key];
  if (!val) return fallback;
  return val === 'true' || val === '1';
}

function envInt(key: string, fallback: number): number {
  const val = process.env[key];
  if (!val) return fallback;
  const n = parseInt(val, 10);
  return isNaN(n) ? fallback : n;
}

function envFloat(key: string, fallback: number): number {
  const val = process.env[key];
  if (!val) return fallback;
  const n = parseFloat(val);
  return isNaN(n) ? fallback : n;
}

/**
 * Load config from environment. The bash launcher exports all config.sh
 * values before exec-ing the Node process.
 */
export function loadConfig(): LanaConfig {
  const lanaDir = env('LANA_DIR', path.resolve(new URL('.', import.meta.url).pathname, '..'));
  const homeDir = process.env['HOME'] ?? '/tmp';

  return {
    apiUrl: env('API_URL', 'http://127.0.0.1:8080'),
    apiModel: env('LANA_API_MODEL', 'local-model'),
    useProxy: envBool('USE_PROXY', false),

    contextSize: envInt('CONTEXT_SIZE', 32768),
    temperature: envFloat('TEMPERATURE', 0.2),
    maxTokens: envInt('MAX_TOKENS', 32768),
    frequencyPenalty: envFloat('FREQUENCY_PENALTY', 0.3),
    presencePenalty: envFloat('PRESENCE_PENALTY', 0.2),

    autoConfirmRead: envBool('AUTO_CONFIRM_READ', true),
    maxToolLoops: envInt('MAX_TOOL_LOOPS', 50),
    acceptMode: env('ACCEPT_MODE', 'confirm') as 'confirm' | 'auto-edit' | 'yolo',
    fileSizeLimit: envInt('FILE_SIZE_LIMIT', 50000),

    lanaDir,
    historyDir: env('LANA_HISTORY_DIR', path.join(homeDir, '.lana', 'history')),
    inputHistory: env('LANA_INPUT_HISTORY', path.join(homeDir, '.lana', 'input_history')),
    inputHistorySize: envInt('LANA_INPUT_HISTORY_SIZE', 500),
    sessionDir: env('SESSION_DIR', `/tmp/lana-${process.pid}`),

    compactTriggerPct: envInt('COMPACT_TRIGGER_PCT', 60),
    compactKeepTurns: envInt('COMPACT_KEEP_TURNS', 4),
    compactEmergencyPct: envInt('COMPACT_EMERGENCY_PCT', 80),
    compactSummaryMaxTokens: envInt('COMPACT_SUMMARY_MAX_TOKENS', 400),
    compactTemperature: envFloat('COMPACT_TEMPERATURE', 0.1),

    toolResultMaxLines: envInt('TOOL_RESULT_MAX_LINES', 30),
    toolResultKeepHead: envInt('TOOL_RESULT_KEEP_HEAD', 10),
    toolResultKeepTail: envInt('TOOL_RESULT_KEEP_TAIL', 5),
    coldStorageEnabled: envBool('COLD_STORAGE_ENABLED', true),

    debug: envBool('LANA_DEBUG', false),

    modelNames: env('MODEL_NAMES', 'qwen2.5 qwen3').split(/\s+/),
    currentModel: env('CURRENT_MODEL', env('LANA_API_MODEL', 'qwen2.5')),

    embeddingPort: envInt('EMBEDDING_PORT', 8081),
    embeddingModelPath: env('EMBEDDING_MODEL_PATH', path.join(homeDir, 'llama.cpp', 'models', 'nomic-embed-text-v1.5.Q8_0.gguf')),
    embeddingModelName: env('EMBEDDING_MODEL_NAME', 'nomic-embed-text'),
    llamaServerBin: env('LLAMA_SERVER', path.join(homeDir, 'llama.cpp', 'build', 'bin', 'llama-server')),
    chatPort: envInt('SERVER_PORT', 8080),
    chatModelCtx: envInt('CONTEXT_SIZE', 32768),
    chatModelNgl: envInt('GPU_LAYERS', 99),
    threads: envInt('THREADS', 10),
  };
}

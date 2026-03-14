// Tool execution bridge — spawns bash tool_runner.sh for each tool call
// This keeps all 20+ bash tool implementations untouched.
// Some tools (like search_index) have native Node implementations for
// enhanced functionality (vector search).

import { spawn } from 'child_process';
import * as path from 'path';
import * as fs from 'fs';
import { hybridSearch, formatSearchResults } from '../embedding/search.js';
import type { EmbeddingProvider } from '../embedding/provider.js';

export interface ToolResult {
  output: string;
  exitCode: number;
  error?: string;
}

const TIMEOUT_MS = 300_000; // 5 minutes, matching current curl timeout

// Optional embedding provider — set by App when model manager is initialized
let _embeddingProvider: EmbeddingProvider | null = null;

export function setEmbeddingProvider(provider: EmbeddingProvider | null): void {
  _embeddingProvider = provider;
}

/**
 * Execute a tool by spawning the bash tool_runner.sh script.
 * Some tools have Node-native fast paths (e.g., search_index with vector support).
 */
export async function executeTool(
  toolName: string,
  argsJson: string,
  lanaDir: string,
  workDir: string,
): Promise<ToolResult> {
  // ── Native Node fast path: search_index with vector DB ──
  if (toolName === 'search_index') {
    const dbPath = path.join(workDir, '.lana', 'index.db');
    if (fs.existsSync(dbPath)) {
      try {
        const args = JSON.parse(argsJson);
        const query = args.query || args.pattern || '';
        if (query) {
          const results = await hybridSearch(query, workDir, _embeddingProvider, {
            mode: 'hybrid',
            maxResults: 20,
          });
          return {
            output: formatSearchResults(results),
            exitCode: 0,
          };
        }
      } catch {
        // Fall through to bash
      }
    }
  }

  const toolRunner = path.join(lanaDir, 'lib', 'tool_runner.sh');

  return new Promise((resolve) => {
    const child = spawn('bash', [toolRunner, toolName, argsJson], {
      cwd: workDir,
      env: {
        ...process.env,
        LANA_HEADLESS: 'true',
        ACCEPT_MODE: 'yolo',
        LANA_WORK_DIR: workDir,
      },
      stdio: ['ignore', 'pipe', 'pipe'],
      timeout: TIMEOUT_MS,
    });

    let stdout = '';
    let stderr = '';

    child.stdout.on('data', (data) => {
      stdout += String(data);
    });

    child.stderr.on('data', (data) => {
      stderr += String(data);
    });

    child.on('error', (err: Error) => {
      resolve({
        output: '',
        exitCode: 1,
        error: `Failed to spawn tool_runner: ${err.message}`,
      });
    });

    child.on('close', (code: number | null) => {
      resolve({
        output: stdout.trim(),
        exitCode: code ?? 1,
        error: stderr.trim() || undefined,
      });
    });
  });
}

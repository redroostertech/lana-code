// Embedding provider interface — system-agnostic abstraction.
// LlamaEmbeddingProvider uses a local llama-server instance on a dedicated port.
// Future providers (Ollama, OpenAI, etc.) implement the same interface.

import { spawn, execSync, type ChildProcess } from 'child_process';

export interface EmbeddingResult {
  embedding: number[];
  tokenCount: number;
}

export interface EmbeddingProvider {
  readonly name: string;
  readonly dimensions: number;
  isAvailable(): Promise<boolean>;
  start(): Promise<void>;
  stop(): Promise<void>;
  embed(text: string): Promise<EmbeddingResult>;
  embedBatch(texts: string[]): Promise<EmbeddingResult[]>;
}

export interface LlamaEmbeddingConfig {
  port: number;
  modelPath: string;
  llamaServerBin: string;
  gpuLayers?: number;
  threads?: number;
  contextSize?: number;
}

export class LlamaEmbeddingProvider implements EmbeddingProvider {
  readonly name = 'llama-embedding';
  readonly dimensions = 768; // nomic-embed-text

  private serverProcess: ChildProcess | null = null;
  private config: LlamaEmbeddingConfig;
  private baseUrl: string;

  constructor(config: LlamaEmbeddingConfig) {
    this.config = config;
    this.baseUrl = `http://127.0.0.1:${config.port}`;
  }

  async isAvailable(): Promise<boolean> {
    try {
      const res = await fetch(`${this.baseUrl}/health`, {
        signal: AbortSignal.timeout(2000),
      });
      return res.ok;
    } catch {
      return false;
    }
  }

  async start(): Promise<void> {
    if (await this.isAvailable()) return; // already running

    const { modelPath, llamaServerBin, port } = this.config;
    const gpuLayers = this.config.gpuLayers ?? 99;
    const threads = this.config.threads ?? 4;
    const ctxSize = this.config.contextSize ?? 2048;

    // Kill any existing process on the port
    try {
      execSync(`lsof -ti :${port} | xargs kill -9 2>/dev/null`, { stdio: 'ignore' });
    } catch { /* nothing on port */ }

    const args = [
      '--model', modelPath,
      '--host', '127.0.0.1',
      '--port', String(port),
      '--embedding',
      '--ctx-size', String(ctxSize),
      '--n-gpu-layers', String(gpuLayers),
      '--threads', String(threads),
      '--no-webui',
    ];

    this.serverProcess = spawn(llamaServerBin, args, {
      stdio: ['ignore', 'pipe', 'pipe'],
      detached: false,
    });

    this.serverProcess.on('error', () => {
      this.serverProcess = null;
    });

    // Wait for health (up to 60s for embedding model — it's small)
    const maxWait = 60_000;
    const interval = 500;
    let waited = 0;
    while (waited < maxWait) {
      if (await this.isAvailable()) return;
      await new Promise(r => setTimeout(r, interval));
      waited += interval;
    }

    throw new Error(`Embedding server did not start within ${maxWait / 1000}s`);
  }

  async stop(): Promise<void> {
    if (this.serverProcess) {
      this.serverProcess.kill('SIGTERM');
      this.serverProcess = null;
    }
    // Also kill anything on the port as cleanup
    try {
      execSync(`lsof -ti :${this.config.port} | xargs kill -9 2>/dev/null`, { stdio: 'ignore' });
    } catch { /* clean */ }
  }

  async embed(text: string): Promise<EmbeddingResult> {
    const results = await this.embedBatch([text]);
    return results[0]!;
  }

  async embedBatch(texts: string[]): Promise<EmbeddingResult[]> {
    const res = await fetch(`${this.baseUrl}/v1/embeddings`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        input: texts,
        model: 'embedding',
      }),
      signal: AbortSignal.timeout(30_000),
    });

    if (!res.ok) {
      const body = await res.text();
      throw new Error(`Embedding request failed (${res.status}): ${body}`);
    }

    const json = await res.json() as {
      data: Array<{ embedding: number[]; index: number }>;
      usage?: { prompt_tokens: number };
    };

    const tokenCount = Math.ceil((json.usage?.prompt_tokens ?? 0) / texts.length);

    // Sort by index to match input order
    const sorted = json.data.sort((a, b) => a.index - b.index);
    return sorted.map(d => ({
      embedding: d.embedding,
      tokenCount,
    }));
  }
}

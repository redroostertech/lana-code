// Model manager — handles dual-load vs swap decision for chat + embedding models.
// Emits events for the Ink UI to display status notifications.

import { EventEmitter } from 'events';
import { spawn, execSync } from 'child_process';
import * as os from 'os';
import * as fs from 'fs';
import type { EmbeddingProvider, LlamaEmbeddingConfig } from './provider.js';
import { LlamaEmbeddingProvider } from './provider.js';

export type ModelMode = 'dual' | 'swap';

export interface ModelManagerConfig {
  // Chat server
  chatPort: number;
  chatModelPath: string;
  chatModelCtx: number;
  chatModelNgl: number;

  // Embedding
  embeddingPort: number;
  embeddingModelPath: string;

  // Shared
  llamaServerBin: string;
  threads: number;
}

export interface ModelManagerEvents {
  status: [message: string];
  'mode-decided': [mode: ModelMode, reason: string];
  'swap-start': [direction: 'to-embedding' | 'to-chat'];
  'swap-complete': [direction: 'to-embedding' | 'to-chat'];
  error: [error: Error];
}

export class ModelManager extends EventEmitter {
  private mode: ModelMode | null = null;
  private embeddingProvider: LlamaEmbeddingProvider;
  private config: ModelManagerConfig;
  private chatWasRunning = false;
  private preWarmed = false;

  constructor(config: ModelManagerConfig) {
    super();
    this.config = config;
    this.embeddingProvider = new LlamaEmbeddingProvider({
      port: config.embeddingPort,
      modelPath: config.embeddingModelPath,
      llamaServerBin: config.llamaServerBin,
      threads: Math.max(2, Math.floor(config.threads / 2)),
    });
  }

  getProvider(): EmbeddingProvider {
    return this.embeddingProvider;
  }

  /**
   * Decide whether to run both models simultaneously or swap.
   */
  decideMode(): ModelMode {
    if (this.mode) return this.mode;

    const totalMem = os.totalmem();
    const totalGB = totalMem / (1024 ** 3);

    let chatModelSize = 0;
    try {
      chatModelSize = fs.statSync(this.config.chatModelPath).size;
    } catch {
      // Can't stat chat model — assume we need swap to be safe
      this.mode = 'swap';
      const reason = `Cannot read chat model size — defaulting to swap mode`;
      this.emit('mode-decided', 'swap', reason);
      return 'swap';
    }

    const embeddingModelSize = 270 * 1024 * 1024; // ~270MB
    const overhead = 2 * 1024 ** 3; // 2GB for OS + Node
    const available = totalMem - overhead;

    if (available >= chatModelSize + embeddingModelSize) {
      this.mode = 'dual';
      const reason = `${totalGB.toFixed(0)}GB RAM — both models fit simultaneously`;
      this.emit('mode-decided', 'dual', reason);
      this.emit('status', `Memory: ${reason}`);
    } else {
      this.mode = 'swap';
      const chatGB = (chatModelSize / (1024 ** 3)).toFixed(1);
      const reason = `${totalGB.toFixed(0)}GB RAM, chat model ${chatGB}GB — will swap during embedding`;
      this.emit('mode-decided', 'swap', reason);
      this.emit('status', `Memory: ${reason}`);
    }

    return this.mode;
  }

  /**
   * Start the embedding server. In swap mode, stops the chat server first.
   */
  async startEmbedding(): Promise<void> {
    const mode = this.decideMode();

    // Check if embedding model exists
    if (!fs.existsSync(this.config.embeddingModelPath)) {
      const err = new Error(
        `Embedding model not found: ${this.config.embeddingModelPath}\n` +
        `Run install.sh to download nomic-embed-text, or set EMBEDDING_MODEL_PATH.`
      );
      this.emit('error', err);
      throw err;
    }

    if (mode === 'swap') {
      // Check if chat server is running so we know to restart it later
      this.chatWasRunning = await this.isChatServerRunning();
      if (this.chatWasRunning) {
        this.emit('swap-start', 'to-embedding');
        this.emit('status', 'Pausing chat model to free memory for embedding...');
        await this.stopChatServer();
        // Brief pause to let memory free
        await new Promise(r => setTimeout(r, 1000));
      }
    }

    this.emit('status', 'Starting embedding model...');
    try {
      await this.embeddingProvider.start();
      this.emit('status', 'Embedding model ready.');
    } catch (err: any) {
      this.emit('error', err);
      // If we stopped chat for this, restart it
      if (mode === 'swap' && this.chatWasRunning) {
        this.emit('status', 'Embedding failed. Restarting chat model...');
        await this.startChatServer();
      }
      throw err;
    }
  }

  /**
   * Stop the embedding server. In swap mode, restarts the chat server.
   * In dual mode with pre-warming, keeps the server alive (call shutdown() to force-stop).
   */
  async stopEmbedding(): Promise<void> {
    // If pre-warmed in dual mode, keep the server alive for future searches
    if (this.preWarmed && this.mode === 'dual') {
      this.emit('status', 'Embedding server staying warm for semantic search.');
      return;
    }

    await this.embeddingProvider.stop();
    this.emit('status', 'Embedding model stopped.');

    if (this.mode === 'swap' && this.chatWasRunning) {
      this.emit('swap-start', 'to-chat');
      this.emit('status', 'Restarting chat model...');
      await this.startChatServer();
      this.emit('status', 'Chat model restored. Ready for conversation.');
      this.emit('swap-complete', 'to-chat');
    }
  }

  /**
   * Force-stop the embedding server (used on app shutdown).
   */
  async shutdown(): Promise<void> {
    this.preWarmed = false;
    await this.embeddingProvider.stop();
  }

  /**
   * Pre-warm the embedding server at launch.
   * Only starts in dual mode (enough RAM for both). In swap mode, does nothing.
   * The server stays alive for the entire session — no stop after indexing.
   */
  async preWarm(): Promise<void> {
    const mode = this.decideMode();

    if (mode !== 'dual') {
      this.emit('status', `Embedding: swap mode — will start on-demand during /index`);
      return;
    }

    if (!fs.existsSync(this.config.embeddingModelPath)) {
      this.emit('status', `Embedding model not found — semantic search unavailable`);
      return;
    }

    // Check if already running (e.g. from a previous session)
    if (await this.embeddingProvider.isAvailable()) {
      this.emit('status', 'Embedding server already running.');
      this.preWarmed = true;
      return;
    }

    this.emit('status', 'Pre-warming embedding model...');
    try {
      await this.embeddingProvider.start();
      this.preWarmed = true;
      this.emit('status', 'Embedding model ready — semantic search enabled.');
    } catch (err: any) {
      this.emit('status', `Embedding pre-warm failed: ${err.message}. Regex search only.`);
    }
  }

  /**
   * Whether the embedding server was pre-warmed and should stay alive.
   */
  isPreWarmed(): boolean {
    return this.preWarmed;
  }

  /**
   * Check if the embedding provider is currently available.
   */
  async isEmbeddingAvailable(): Promise<boolean> {
    return this.embeddingProvider.isAvailable();
  }

  // ── Chat server management (mirrors setup.sh) ─────

  private async isChatServerRunning(): Promise<boolean> {
    try {
      const res = await fetch(`http://127.0.0.1:${this.config.chatPort}/health`, {
        signal: AbortSignal.timeout(2000),
      });
      return res.ok;
    } catch {
      return false;
    }
  }

  private async stopChatServer(): Promise<void> {
    try {
      execSync(`lsof -ti :${this.config.chatPort} | xargs kill -9 2>/dev/null`, { stdio: 'ignore' });
    } catch { /* nothing running */ }

    // Wait for port to be free
    let attempts = 0;
    while (attempts < 20) {
      if (!(await this.isChatServerRunning())) return;
      await new Promise(r => setTimeout(r, 500));
      attempts++;
    }
  }

  private async startChatServer(): Promise<void> {
    const { llamaServerBin, chatModelPath, chatPort, chatModelCtx, chatModelNgl, threads } = this.config;

    const args = [
      '--model', chatModelPath,
      '--host', '127.0.0.1',
      '--port', String(chatPort),
      '--ctx-size', String(chatModelCtx),
      '--n-gpu-layers', String(chatModelNgl),
      '--threads', String(threads),
      '--flash-attn', 'on',
      '--jinja',
      '--no-webui',
    ];

    const child = spawn(llamaServerBin, args, {
      stdio: ['ignore', 'pipe', 'pipe'],
      detached: true,
    });
    child.unref(); // let it outlive this process

    // Wait for health
    const maxWait = 120_000; // chat model can be large
    const interval = 2000;
    let waited = 0;
    while (waited < maxWait) {
      if (await this.isChatServerRunning()) return;
      await new Promise(r => setTimeout(r, interval));
      waited += interval;
      if (waited % 30_000 === 0) {
        this.emit('status', `Still loading chat model... (${waited / 1000}s)`);
      }
    }

    throw new Error('Chat server did not restart within timeout');
  }
}

// Session persistence — save, load, list, recall conversations
// Ports logic from lib/history.sh

import * as fs from 'fs';
import * as path from 'path';
import * as crypto from 'crypto';
import type { ChatMessage } from '../api/types.js';
import type { LanaConfig } from './config.js';

export interface SessionMeta {
  id: string;
  start: string;
  end?: string;
  work_dir: string;
  model: string;
  turns: number;
  summary: string;
  files_touched: string[];
}

export interface SessionData extends SessionMeta {
  version: number;
  messages: ChatMessage[];
  compactions: CompactionRecord[];
}

export interface CompactionRecord {
  at: string;
  messages_compacted: number;
  tokens_before: number;
  tokens_after: number;
  summary: string;
}

/**
 * Generate a unique session ID: YYYYMMDD_HHMMSS_<8 hex chars>
 */
export function generateSessionId(): string {
  const now = new Date();
  const date = now.toISOString().replace(/[-:T]/g, '').slice(0, 15).replace(/(\d{8})(\d{6})/, '$1_$2');
  const rand = crypto.randomBytes(4).toString('hex');
  return `${date}_${rand}`;
}

/**
 * Track files touched during the session.
 */
export class SessionTracker {
  readonly id: string;
  readonly startTime: string;
  private filesTouched = new Set<string>();
  private turnCount = 0;
  private compactions: CompactionRecord[] = [];
  private config: LanaConfig;
  private lastSummary = '';

  constructor(config: LanaConfig) {
    this.id = generateSessionId();
    this.startTime = new Date().toISOString();
    this.config = config;

    // Ensure history directory exists
    fs.mkdirSync(config.historyDir, { recursive: true });
  }

  trackTurn(): void {
    this.turnCount++;
  }

  trackFile(filePath: string): void {
    this.filesTouched.add(filePath);
  }

  trackCompaction(record: CompactionRecord): void {
    this.compactions.push(record);
    this.lastSummary = record.summary;
  }

  /**
   * Extract file paths from tool calls and track them.
   */
  trackToolCall(name: string, args: Record<string, any>): void {
    const pathArg = args.path || args.file_path || args.target || args.destination;
    if (pathArg && typeof pathArg === 'string') {
      this.filesTouched.add(pathArg);
    }
  }

  /**
   * Save the session to disk.
   */
  save(messages: ChatMessage[], summary?: string): void {
    const sessionFile = path.join(this.config.historyDir, `${this.id}.json`);

    const data: SessionData = {
      id: this.id,
      version: 2,
      start: this.startTime,
      end: new Date().toISOString(),
      work_dir: process.env['LANA_WORK_DIR'] || process.cwd(),
      model: this.config.currentModel,
      turns: this.turnCount,
      summary: summary || this.lastSummary || this.generateQuickSummary(messages),
      files_touched: [...this.filesTouched],
      messages,
      compactions: this.compactions,
    };

    fs.writeFileSync(sessionFile, JSON.stringify(data, null, 2));

    // Update index
    this.updateIndex(data);
  }

  /**
   * Generate a quick summary from the first user message.
   */
  private generateQuickSummary(messages: ChatMessage[]): string {
    const firstUser = messages.find(m => m.role === 'user' && !m.content?.startsWith('[Conversation Summary]'));
    if (!firstUser?.content) return '(empty session)';
    return firstUser.content.slice(0, 200);
  }

  /**
   * Update the session index file.
   */
  private updateIndex(data: SessionData): void {
    const indexFile = path.join(this.config.historyDir, 'index.json');
    let index: SessionMeta[] = [];

    try {
      index = JSON.parse(fs.readFileSync(indexFile, 'utf8'));
    } catch { /* new index */ }

    // Remove existing entry for this session (in case of re-save)
    index = index.filter(s => s.id !== data.id);

    // Add new entry at the beginning
    index.unshift({
      id: data.id,
      start: data.start,
      end: data.end,
      work_dir: data.work_dir,
      model: data.model,
      turns: data.turns,
      summary: data.summary.slice(0, 200),
      files_touched: data.files_touched,
    });

    // Keep only last 100 sessions in index
    index = index.slice(0, 100);

    fs.writeFileSync(indexFile, JSON.stringify(index, null, 2));
  }
}

/**
 * List recent sessions, optionally filtered by search query.
 */
export function listSessions(config: LanaConfig, query?: string, limit = 20): SessionMeta[] {
  const indexFile = path.join(config.historyDir, 'index.json');
  let index: SessionMeta[] = [];

  try {
    index = JSON.parse(fs.readFileSync(indexFile, 'utf8'));
  } catch {
    return [];
  }

  if (query) {
    const q = query.toLowerCase();
    index = index.filter(s =>
      s.summary.toLowerCase().includes(q) ||
      s.work_dir.toLowerCase().includes(q) ||
      s.model.toLowerCase().includes(q) ||
      s.files_touched.some(f => f.toLowerCase().includes(q))
    );
  }

  return index.slice(0, limit);
}

/**
 * Load a previous session's data by ID (or ID prefix).
 */
export function loadSession(config: LanaConfig, idOrPrefix: string): SessionData | null {
  const historyDir = config.historyDir;

  // Try exact match first
  const exactPath = path.join(historyDir, `${idOrPrefix}.json`);
  if (fs.existsSync(exactPath)) {
    try {
      return JSON.parse(fs.readFileSync(exactPath, 'utf8'));
    } catch { return null; }
  }

  // Try prefix match
  try {
    const files = fs.readdirSync(historyDir).filter(f => f.endsWith('.json') && f !== 'index.json');
    const match = files.find(f => f.startsWith(idOrPrefix));
    if (match) {
      return JSON.parse(fs.readFileSync(path.join(historyDir, match), 'utf8'));
    }
  } catch { /* no history dir */ }

  return null;
}

/**
 * Build a context message from a recalled session.
 */
export function buildRecallContext(session: SessionData): string {
  const parts = [
    `Previous session (${session.id})`,
    `Model: ${session.model}`,
    `Directory: ${session.work_dir}`,
    `Turns: ${session.turns}`,
  ];

  if (session.summary) {
    parts.push(`\nSummary:\n${session.summary}`);
  }

  if (session.files_touched.length > 0) {
    parts.push(`\nFiles touched:\n${session.files_touched.map(f => `  ${f}`).join('\n')}`);
  }

  return parts.join('\n');
}

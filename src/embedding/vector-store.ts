// SQLite-based vector store for embedding storage and similarity search.
// Uses better-sqlite3 for synchronous, fast SQLite operations.
// Vectors stored as raw binary BLOBs — cosine similarity computed in JS.

import Database from 'better-sqlite3';
import * as path from 'path';
import * as fs from 'fs';

export interface FileRecord {
  id?: number;
  path: string;
  mtime: number;
  hash: string | null;
  size: number;
  lines: number;
  summary: string | null;
}

export interface ChunkRecord {
  id?: number;
  fileId: number;
  chunkIndex: number;
  content: string;
  chunkType: 'code' | 'summary' | 'docs';
  startLine: number | null;
  endLine: number | null;
  embedding: number[];
  tokenCount: number | null;
}

export interface SearchHit {
  path: string;
  score: number;
  snippet: string;
  chunkType: string;
  startLine: number | null;
  endLine: number | null;
}

const SCHEMA_VERSION = '1';

const SCHEMA_SQL = `
CREATE TABLE IF NOT EXISTS files (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  path TEXT NOT NULL UNIQUE,
  mtime INTEGER NOT NULL,
  hash TEXT,
  size INTEGER NOT NULL,
  lines INTEGER NOT NULL,
  summary TEXT,
  indexed_at TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS chunks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
  chunk_index INTEGER NOT NULL,
  content TEXT NOT NULL,
  chunk_type TEXT NOT NULL DEFAULT 'code',
  start_line INTEGER,
  end_line INTEGER,
  embedding BLOB NOT NULL,
  token_count INTEGER,
  UNIQUE(file_id, chunk_index)
);

CREATE INDEX IF NOT EXISTS idx_files_path ON files(path);
CREATE INDEX IF NOT EXISTS idx_chunks_file ON chunks(file_id);

CREATE TABLE IF NOT EXISTS meta (
  key TEXT PRIMARY KEY,
  value TEXT
);
`;

export class VectorStore {
  private db: Database.Database;

  constructor(projectDir: string) {
    const indexDir = path.join(projectDir, '.lana');
    fs.mkdirSync(indexDir, { recursive: true });
    const dbPath = path.join(indexDir, 'index.db');
    this.db = new Database(dbPath);
    this.db.pragma('journal_mode = WAL');
    this.db.pragma('foreign_keys = ON');
    this.init();
  }

  private init(): void {
    this.db.exec(SCHEMA_SQL);
    const version = this.getMeta('schema_version');
    if (!version) {
      this.setMeta('schema_version', SCHEMA_VERSION);
    }
  }

  // ── Meta ────────────────────────────────────────────

  getMeta(key: string): string | null {
    const row = this.db.prepare('SELECT value FROM meta WHERE key = ?').get(key) as { value: string } | undefined;
    return row?.value ?? null;
  }

  setMeta(key: string, value: string): void {
    this.db.prepare('INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)').run(key, value);
  }

  // ── Files ───────────────────────────────────────────

  getFile(filePath: string): (FileRecord & { id: number }) | null {
    const row = this.db.prepare('SELECT * FROM files WHERE path = ?').get(filePath) as any;
    if (!row) return null;
    return {
      id: row.id,
      path: row.path,
      mtime: row.mtime,
      hash: row.hash,
      size: row.size,
      lines: row.lines,
      summary: row.summary,
    };
  }

  upsertFile(file: FileRecord): number {
    const stmt = this.db.prepare(`
      INSERT INTO files (path, mtime, hash, size, lines, summary)
      VALUES (@path, @mtime, @hash, @size, @lines, @summary)
      ON CONFLICT(path) DO UPDATE SET
        mtime = @mtime, hash = @hash, size = @size, lines = @lines,
        summary = @summary, indexed_at = datetime('now')
    `);
    const result = stmt.run({
      path: file.path,
      mtime: file.mtime,
      hash: file.hash,
      size: file.size,
      lines: file.lines,
      summary: file.summary,
    });
    // Get the id (either inserted or existing)
    if (result.changes > 0 && result.lastInsertRowid) {
      return Number(result.lastInsertRowid);
    }
    const existing = this.getFile(file.path);
    return existing!.id;
  }

  deleteFileChunks(fileId: number): void {
    this.db.prepare('DELETE FROM chunks WHERE file_id = ?').run(fileId);
  }

  // ── Chunks ──────────────────────────────────────────

  insertChunk(chunk: ChunkRecord): void {
    this.db.prepare(`
      INSERT OR REPLACE INTO chunks
        (file_id, chunk_index, content, chunk_type, start_line, end_line, embedding, token_count)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    `).run(
      chunk.fileId,
      chunk.chunkIndex,
      chunk.content,
      chunk.chunkType,
      chunk.startLine,
      chunk.endLine,
      packVector(chunk.embedding),
      chunk.tokenCount,
    );
  }

  insertChunksBatch(chunks: ChunkRecord[]): void {
    const insert = this.db.prepare(`
      INSERT OR REPLACE INTO chunks
        (file_id, chunk_index, content, chunk_type, start_line, end_line, embedding, token_count)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    `);
    const tx = this.db.transaction((items: ChunkRecord[]) => {
      for (const chunk of items) {
        insert.run(
          chunk.fileId,
          chunk.chunkIndex,
          chunk.content,
          chunk.chunkType,
          chunk.startLine,
          chunk.endLine,
          packVector(chunk.embedding),
          chunk.tokenCount,
        );
      }
    });
    tx(chunks);
  }

  // ── Vector Search ───────────────────────────────────

  /**
   * Find the top-N most similar chunks to the query vector.
   * Brute-force cosine similarity — fast enough for <10K chunks.
   */
  searchSimilar(queryVec: number[], topK: number = 20): SearchHit[] {
    const rows = this.db.prepare(`
      SELECT c.content, c.embedding, c.chunk_type, c.start_line, c.end_line, f.path
      FROM chunks c JOIN files f ON c.file_id = f.id
    `).all() as Array<{
      content: string;
      embedding: Buffer;
      chunk_type: string;
      start_line: number | null;
      end_line: number | null;
      path: string;
    }>;

    const scored: SearchHit[] = rows.map(row => ({
      path: row.path,
      score: cosineSimilarity(queryVec, unpackVector(row.embedding)),
      snippet: row.content.slice(0, 300),
      chunkType: row.chunk_type,
      startLine: row.start_line,
      endLine: row.end_line,
    }));

    // Sort by score descending, deduplicate by file (best chunk per file)
    scored.sort((a, b) => b.score - a.score);
    const seen = new Set<string>();
    const results: SearchHit[] = [];
    for (const hit of scored) {
      if (seen.has(hit.path)) continue;
      seen.add(hit.path);
      results.push(hit);
      if (results.length >= topK) break;
    }
    return results;
  }

  // ── Stats ───────────────────────────────────────────

  getStats(): { fileCount: number; chunkCount: number } {
    const files = this.db.prepare('SELECT COUNT(*) as c FROM files').get() as { c: number };
    const chunks = this.db.prepare('SELECT COUNT(*) as c FROM chunks').get() as { c: number };
    return { fileCount: files.c, chunkCount: chunks.c };
  }

  close(): void {
    this.db.close();
  }
}

// ── Vector utilities ────────────────────────────────

export function packVector(vec: number[]): Buffer {
  const buf = Buffer.alloc(vec.length * 4);
  for (let i = 0; i < vec.length; i++) {
    buf.writeFloatLE(vec[i]!, i * 4);
  }
  return buf;
}

export function unpackVector(blob: Buffer): number[] {
  const len = blob.length / 4;
  const vec = new Array<number>(len);
  for (let i = 0; i < len; i++) {
    vec[i] = blob.readFloatLE(i * 4);
  }
  return vec;
}

export function cosineSimilarity(a: number[], b: number[]): number {
  let dot = 0;
  let normA = 0;
  let normB = 0;
  for (let i = 0; i < a.length; i++) {
    dot += a[i]! * b[i]!;
    normA += a[i]! * a[i]!;
    normB += b[i]! * b[i]!;
  }
  const denom = Math.sqrt(normA) * Math.sqrt(normB);
  return denom === 0 ? 0 : dot / denom;
}

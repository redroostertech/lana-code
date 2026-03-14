// Embedding indexer — orchestrates: scan → chunk → embed → store.
// Reads file list from existing index.json, incrementally re-embeds changed files.

import { EventEmitter } from 'events';
import * as fs from 'fs';
import * as path from 'path';
import * as crypto from 'crypto';
import { VectorStore } from './vector-store.js';
import { chunkFile } from './chunker.js';
import type { ModelManager } from './model-manager.js';
import type { ChunkRecord } from './vector-store.js';

interface IndexJsonEntry {
  path: string;
  symbols: string[];
  imports: string[];
  docs: string;
  lines: number;
  size: number;
  mtime: number;
  summary: string;
}

export interface IndexerEvents {
  progress: [percent: number, message: string];
  status: [message: string];
  error: [error: Error];
}

const BATCH_SIZE = 16;

export class EmbeddingIndexer extends EventEmitter {
  private modelManager: ModelManager;

  constructor(modelManager: ModelManager) {
    super();
    this.modelManager = modelManager;
  }

  /**
   * Run the embedding phase on a project.
   * Reads index.json for file metadata, chunks changed files, embeds, stores in index.db.
   */
  async indexProject(projectDir: string): Promise<{ filesProcessed: number; chunksEmbedded: number }> {
    const indexJsonPath = path.join(projectDir, '.lana', 'index.json');

    // Read the existing index.json (from bash Phase 1-5)
    let entries: IndexJsonEntry[];
    try {
      const raw = fs.readFileSync(indexJsonPath, 'utf8');
      entries = JSON.parse(raw);
    } catch (err: any) {
      this.emit('error', new Error(`Cannot read index.json: ${err.message}. Run /index first.`));
      return { filesProcessed: 0, chunksEmbedded: 0 };
    }

    if (entries.length === 0) {
      this.emit('status', 'No files in index.json — nothing to embed.');
      return { filesProcessed: 0, chunksEmbedded: 0 };
    }

    // Open/create the vector store
    const store = new VectorStore(projectDir);

    // Determine which files need re-embedding
    const filesToProcess: IndexJsonEntry[] = [];
    for (const entry of entries) {
      if (this.needsReindex(store, entry, projectDir)) {
        filesToProcess.push(entry);
      }
    }

    if (filesToProcess.length === 0) {
      const stats = store.getStats();
      this.emit('status', `All ${stats.fileCount} files up to date (${stats.chunkCount} chunks). Skipping embedding.`);
      store.close();
      return { filesProcessed: 0, chunksEmbedded: 0 };
    }

    this.emit('status', `${filesToProcess.length} files need embedding (${entries.length - filesToProcess.length} cached).`);

    // Start embedding server (may swap if needed)
    try {
      await this.modelManager.startEmbedding();
    } catch (err: any) {
      this.emit('error', new Error(`Failed to start embedding: ${err.message}`));
      store.close();
      return { filesProcessed: 0, chunksEmbedded: 0 };
    }

    const provider = this.modelManager.getProvider();
    let totalChunks = 0;
    let filesProcessed = 0;

    try {
      // Process files in batches
      for (let i = 0; i < filesToProcess.length; i++) {
        const entry = filesToProcess[i]!;
        const fullPath = path.join(projectDir, entry.path);

        let content: string;
        try {
          content = fs.readFileSync(fullPath, 'utf8');
        } catch {
          continue; // file may have been deleted since indexing
        }

        // Compute content hash
        const hash = crypto.createHash('sha256').update(content).digest('hex');

        // Chunk the file
        const chunks = chunkFile(entry.path, content, entry.summary);
        if (chunks.length === 0) continue;

        // Upsert file record
        const fileId = store.upsertFile({
          path: entry.path,
          mtime: entry.mtime,
          hash,
          size: entry.size,
          lines: entry.lines,
          summary: entry.summary || null,
        });

        // Delete old chunks for this file
        store.deleteFileChunks(fileId);

        // Embed chunks in batches
        const texts = chunks.map(c => c.content);
        const chunkRecords: ChunkRecord[] = [];

        for (let b = 0; b < texts.length; b += BATCH_SIZE) {
          const batch = texts.slice(b, b + BATCH_SIZE);
          const results = await provider.embedBatch(batch);

          for (let j = 0; j < results.length; j++) {
            const chunkIdx = b + j;
            const chunk = chunks[chunkIdx]!;
            const result = results[j]!;

            chunkRecords.push({
              fileId,
              chunkIndex: chunkIdx,
              content: chunk.content,
              chunkType: chunk.chunkType,
              startLine: chunk.startLine,
              endLine: chunk.endLine,
              embedding: result.embedding,
              tokenCount: result.tokenCount,
            });
          }
        }

        // Store all chunks for this file in a single transaction
        store.insertChunksBatch(chunkRecords);
        totalChunks += chunkRecords.length;
        filesProcessed++;

        // Emit progress
        const pct = Math.round(((i + 1) / filesToProcess.length) * 100);
        this.emit('progress', pct, `Embedded ${entry.path} (${chunkRecords.length} chunks)`);
      }
    } finally {
      // Always stop embedding server (restarts chat if swap mode)
      await this.modelManager.stopEmbedding();
    }

    // Update meta
    store.setMeta('last_indexed', new Date().toISOString());
    store.setMeta('embedding_model', provider.name);
    store.setMeta('dimensions', String(provider.dimensions));

    const stats = store.getStats();
    this.emit('status', `Embedding complete: ${filesProcessed} files, ${totalChunks} chunks. DB has ${stats.fileCount} files, ${stats.chunkCount} total chunks.`);
    store.close();

    return { filesProcessed, chunksEmbedded: totalChunks };
  }

  /**
   * Check if a file needs re-embedding by comparing mtime and content hash.
   */
  private needsReindex(store: VectorStore, entry: IndexJsonEntry, projectDir: string): boolean {
    const existing = store.getFile(entry.path);
    if (!existing) return true; // new file

    // Fast check: mtime
    if (existing.mtime === entry.mtime) return false;

    // Slow check: content hash (file was touched but maybe not changed)
    try {
      const content = fs.readFileSync(path.join(projectDir, entry.path), 'utf8');
      const hash = crypto.createHash('sha256').update(content).digest('hex');
      if (existing.hash === hash) {
        // Update mtime only, skip re-embedding
        store.upsertFile({ ...entry, hash, summary: entry.summary || null });
        return false;
      }
    } catch {
      return true; // can't read, re-index to be safe
    }

    return true; // content changed
  }
}

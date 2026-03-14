// Hybrid search — combines regex matching (index.json) with vector similarity (index.db).
// Uses Reciprocal Rank Fusion (RRF) to merge results from both sources.

import * as fs from 'fs';
import * as path from 'path';
import { VectorStore } from './vector-store.js';
import type { EmbeddingProvider } from './provider.js';

export interface HybridSearchResult {
  path: string;
  score: number;
  matchType: 'regex' | 'vector' | 'both';
  symbols?: string[];
  summary?: string;
  snippet?: string;
  startLine?: number | null;
  endLine?: number | null;
}

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

export type SearchMode = 'regex' | 'vector' | 'hybrid';

/**
 * Hybrid search across regex index (index.json) and vector index (index.db).
 * Falls back gracefully: if no DB exists, regex-only. If no embedding server, regex-only.
 */
export async function hybridSearch(
  query: string,
  projectDir: string,
  embeddingProvider: EmbeddingProvider | null,
  options: { maxResults?: number; mode?: SearchMode } = {},
): Promise<HybridSearchResult[]> {
  const { maxResults = 20, mode = 'hybrid' } = options;
  const indexDir = path.join(projectDir, '.lana');
  const jsonPath = path.join(indexDir, 'index.json');
  const dbPath = path.join(indexDir, 'index.db');

  let regexResults: HybridSearchResult[] = [];
  let vectorResults: HybridSearchResult[] = [];

  // ── Regex search (index.json) ─────────────────────
  if (mode === 'regex' || mode === 'hybrid') {
    if (fs.existsSync(jsonPath)) {
      try {
        const entries: IndexJsonEntry[] = JSON.parse(fs.readFileSync(jsonPath, 'utf8'));
        const re = new RegExp(query, 'i');

        regexResults = entries
          .filter(e =>
            re.test(e.path) ||
            (e.symbols && e.symbols.some(s => re.test(s))) ||
            (e.summary && re.test(e.summary))
          )
          .slice(0, maxResults)
          .map((e, i) => ({
            path: e.path,
            score: 1 - (i / maxResults),
            matchType: 'regex' as const,
            symbols: e.symbols,
            summary: e.summary,
          }));
      } catch {
        // Malformed index.json — skip regex
      }
    }
  }

  // ── Vector search (index.db) ──────────────────────
  if (mode === 'vector' || mode === 'hybrid') {
    if (fs.existsSync(dbPath) && embeddingProvider) {
      try {
        const isAvailable = await embeddingProvider.isAvailable();
        if (isAvailable) {
          const queryResult = await embeddingProvider.embed(query);
          const store = new VectorStore(projectDir);
          const hits = store.searchSimilar(queryResult.embedding, maxResults);
          store.close();

          vectorResults = hits.map(hit => ({
            path: hit.path,
            score: hit.score,
            matchType: 'vector' as const,
            snippet: hit.snippet,
            startLine: hit.startLine,
            endLine: hit.endLine,
          }));
        }
      } catch {
        // Vector search failed — fall through to regex-only
      }
    }
  }

  // ── Reciprocal Rank Fusion ────────────────────────
  if (mode === 'hybrid' && regexResults.length > 0 && vectorResults.length > 0) {
    return rrfMerge(regexResults, vectorResults, maxResults);
  }

  // Single-source fallback
  if (mode === 'vector') return vectorResults;
  if (vectorResults.length > 0 && regexResults.length === 0) return vectorResults;
  return regexResults;
}

/**
 * Reciprocal Rank Fusion — merges two ranked lists.
 * Files appearing in both lists get a boosted score.
 */
function rrfMerge(
  listA: HybridSearchResult[],
  listB: HybridSearchResult[],
  maxResults: number,
): HybridSearchResult[] {
  const k = 60; // RRF constant — higher values reduce rank differences
  const scores = new Map<string, { score: number; result: HybridSearchResult }>();

  listA.forEach((r, rank) => {
    const rrf = 1 / (k + rank + 1);
    scores.set(r.path, { score: rrf, result: { ...r } });
  });

  listB.forEach((r, rank) => {
    const rrf = 1 / (k + rank + 1);
    const existing = scores.get(r.path);
    if (existing) {
      existing.score += rrf;
      existing.result.matchType = 'both';
      // Merge fields from vector result
      if (r.snippet) existing.result.snippet = r.snippet;
      if (r.startLine != null) existing.result.startLine = r.startLine;
      if (r.endLine != null) existing.result.endLine = r.endLine;
    } else {
      scores.set(r.path, { score: rrf, result: { ...r } });
    }
  });

  return [...scores.values()]
    .sort((a, b) => b.score - a.score)
    .slice(0, maxResults)
    .map(s => ({ ...s.result, score: s.score }));
}

/**
 * Format search results for display as tool output.
 */
export function formatSearchResults(results: HybridSearchResult[]): string {
  if (results.length === 0) return 'No results found.';

  const lines: string[] = [];
  for (const r of results) {
    const tag = r.matchType === 'both' ? '★' : r.matchType === 'vector' ? '⃗' : '⌕';
    lines.push(`${tag} ${r.path} (score: ${r.score.toFixed(3)})`);
    if (r.symbols && r.symbols.length > 0) {
      lines.push(`    symbols: ${r.symbols.slice(0, 10).join(', ')}`);
    }
    if (r.summary) {
      lines.push(`    summary: ${r.summary}`);
    }
    if (r.snippet) {
      const preview = r.snippet.split('\n').slice(0, 3).join('\n    ');
      const loc = r.startLine ? ` (L${r.startLine}-${r.endLine})` : '';
      lines.push(`    match${loc}: ${preview}`);
    }
  }
  return lines.join('\n');
}

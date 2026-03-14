// Code-aware text chunker.
// Splits source files into ~500 token chunks at natural boundaries
// (function definitions, class declarations, blank line gaps).

export interface Chunk {
  content: string;
  startLine: number;
  endLine: number;
  chunkType: 'code' | 'summary' | 'docs';
}

const TARGET_CHUNK_CHARS = 2000;  // ~500 tokens at 4 chars/token
const MAX_CHUNK_CHARS = 3000;     // hard cap
const MAX_CHUNKS_PER_FILE = 20;

// Regex patterns for function/class boundaries (matches start of line)
const BOUNDARY_PATTERNS = [
  /^(?:export\s+)?(?:async\s+)?function\s/m,          // JS/TS functions
  /^(?:export\s+)?(?:const|let|var)\s+\w+\s*=/m,      // JS/TS const declarations
  /^(?:export\s+)?(?:class|interface|type|enum)\s/m,   // JS/TS classes/types
  /^def\s+\w+/m,                                       // Python functions
  /^class\s+\w+/m,                                     // Python classes
  /^(?:pub\s+)?(?:fn|struct|enum|impl|trait)\s/m,      // Rust
  /^func\s+/m,                                         // Go
  /^(?:public|private|protected)?\s*(?:static\s+)?(?:class|interface|void|int|String)\s/m, // Java/C#
  /^\w+\s*\([^)]*\)\s*\{/m,                            // C/C++ function definitions
];

/**
 * Chunk a source file into pieces suitable for embedding.
 */
export function chunkFile(
  filePath: string,
  content: string,
  summary?: string | null,
): Chunk[] {
  const lines = content.split('\n');
  const chunks: Chunk[] = [];

  if (lines.length === 0) return chunks;

  // Find boundary line numbers (where functions/classes start)
  const boundaries: number[] = [0]; // always start at line 0
  for (let i = 1; i < lines.length; i++) {
    const line = lines[i]!;
    // Blank line after non-blank is a weak boundary
    if (line.trim() === '' && i > 0 && lines[i - 1]!.trim() !== '') {
      continue; // skip weak boundaries, prefer strong ones
    }
    // Strong boundary: function/class definition
    for (const pattern of BOUNDARY_PATTERNS) {
      if (pattern.test(line)) {
        boundaries.push(i);
        break;
      }
    }
  }

  // Merge boundaries into chunks of ~TARGET_CHUNK_CHARS
  let chunkStart = 0;
  let chunkChars = 0;
  let lastBoundary = 0;

  for (let b = 0; b < boundaries.length; b++) {
    const boundaryLine = boundaries[b]!;

    // Calculate chars from chunkStart to this boundary
    let segmentChars = 0;
    for (let i = lastBoundary; i < boundaryLine; i++) {
      segmentChars += (lines[i]?.length ?? 0) + 1;
    }
    chunkChars += segmentChars;
    lastBoundary = boundaryLine;

    // If we've accumulated enough, emit a chunk
    if (chunkChars >= TARGET_CHUNK_CHARS || b === boundaries.length - 1) {
      const endLine = (b < boundaries.length - 1) ? boundaryLine - 1 : lines.length - 1;
      const chunkContent = lines.slice(chunkStart, endLine + 1).join('\n');

      if (chunkContent.trim().length > 0) {
        const header = `// File: ${filePath} (lines ${chunkStart + 1}-${endLine + 1})`;
        chunks.push({
          content: `${header}\n${chunkContent.slice(0, MAX_CHUNK_CHARS)}`,
          startLine: chunkStart + 1,
          endLine: endLine + 1,
          chunkType: 'code',
        });
      }

      chunkStart = boundaryLine;
      chunkChars = 0;

      if (chunks.length >= MAX_CHUNKS_PER_FILE) break;
    }
  }

  // Handle remaining lines if no boundary triggered final chunk
  if (chunkStart < lines.length && chunks.length < MAX_CHUNKS_PER_FILE) {
    const remaining = lines.slice(chunkStart).join('\n');
    if (remaining.trim().length > 0) {
      const header = `// File: ${filePath} (lines ${chunkStart + 1}-${lines.length})`;
      chunks.push({
        content: `${header}\n${remaining.slice(0, MAX_CHUNK_CHARS)}`,
        startLine: chunkStart + 1,
        endLine: lines.length,
        chunkType: 'code',
      });
    }
  }

  // If file is small enough for a single chunk and we got nothing, do whole file
  if (chunks.length === 0 && content.trim().length > 0) {
    const header = `// File: ${filePath} (lines 1-${lines.length})`;
    chunks.push({
      content: `${header}\n${content.slice(0, MAX_CHUNK_CHARS)}`,
      startLine: 1,
      endLine: lines.length,
      chunkType: 'code',
    });
  }

  // Add summary as its own chunk if available
  if (summary && summary.trim()) {
    chunks.push({
      content: `File summary for ${filePath}: ${summary}`,
      startLine: 1,
      endLine: lines.length,
      chunkType: 'summary',
    });
  }

  return chunks;
}

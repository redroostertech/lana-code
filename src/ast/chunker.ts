// AST-aware code chunking — splits files at real function/class boundaries
import type { Tree, Node as TSNode } from 'web-tree-sitter';
import { parseFile } from './parser.js';
import type { Chunk } from './types.js';

const TARGET_CHUNK_CHARS = 2000;  // ~500 tokens
const MAX_CHUNK_CHARS = 3000;
const MAX_CHUNKS_PER_FILE = 20;

// Node types that represent top-level declarations (natural chunk boundaries)
const BOUNDARY_TYPES = new Set([
  // JS/TS
  'function_declaration', 'class_declaration', 'interface_declaration',
  'type_alias_declaration', 'enum_declaration', 'export_statement',
  'lexical_declaration', 'variable_declaration',
  // Python
  'function_definition', 'class_definition', 'decorated_definition',
  // Rust
  'function_item', 'struct_item', 'enum_item', 'trait_item',
  'impl_item', 'type_item', 'const_item', 'mod_item',
  // Go
  'function_declaration', 'method_declaration', 'type_declaration',
  // C/C++
  'function_definition', 'struct_specifier', 'class_specifier',
  'enum_specifier', 'namespace_definition', 'preproc_function_def',
  // Java
  'class_declaration', 'interface_declaration', 'method_declaration',
  'enum_declaration',
  // Ruby
  'method', 'class', 'module',
]);

/**
 * AST-aware file chunking. Falls back to line-based chunking if parsing fails.
 */
export async function chunkFileAST(
  filePath: string,
  content: string,
  summary?: string | null,
): Promise<Chunk[]> {
  // Try AST-based chunking
  try {
    const result = await parseFile(filePath, content);
    if (result) {
      const chunks = chunkFromTree(filePath, content, result.tree);
      if (chunks.length > 0) {
        // Add summary chunk if available
        if (summary?.trim()) {
          chunks.push({
            content: `File summary for ${filePath}: ${summary}`,
            chunkType: 'summary',
            startLine: 0,
            endLine: 0,
          });
        }
        return chunks.slice(0, MAX_CHUNKS_PER_FILE);
      }
    }
  } catch {
    // Fall through to line-based
  }

  // Fallback: line-based chunking
  return chunkByLines(filePath, content, summary);
}

/**
 * Chunk a file using its AST tree. Groups top-level nodes into chunks.
 */
function chunkFromTree(filePath: string, content: string, tree: Tree): Chunk[] {
  const root = tree.rootNode;
  const chunks: Chunk[] = [];

  // Collect top-level declaration nodes and their line ranges
  const nodes: { startLine: number; endLine: number; text: string }[] = [];

  for (let i = 0; i < root.childCount; i++) {
    const child = root.child(i);
    if (!child) continue;

    // Skip comments at top level (they'll be included via line ranges)
    if (child.type === 'comment' || child.type === 'line_comment' || child.type === 'block_comment') {
      continue;
    }

    nodes.push({
      startLine: child.startPosition.row + 1,
      endLine: child.endPosition.row + 1,
      text: child.text,
    });
  }

  if (nodes.length === 0) return [];

  // Group nodes into chunks, respecting size targets
  let currentChunk = '';
  let chunkStartLine = nodes[0]!.startLine;
  let chunkEndLine = nodes[0]!.startLine;

  for (const node of nodes) {
    const nodeText = node.text;

    if (currentChunk.length + nodeText.length > MAX_CHUNK_CHARS && currentChunk.length > 0) {
      // Flush current chunk
      chunks.push({
        content: `// File: ${filePath} (lines ${chunkStartLine}-${chunkEndLine})\n${currentChunk}`,
        chunkType: 'code',
        startLine: chunkStartLine,
        endLine: chunkEndLine,
      });

      currentChunk = nodeText;
      chunkStartLine = node.startLine;
      chunkEndLine = node.endLine;
    } else {
      if (currentChunk) currentChunk += '\n\n';
      currentChunk += nodeText;
      chunkEndLine = node.endLine;
    }
  }

  // Flush last chunk
  if (currentChunk) {
    chunks.push({
      content: `// File: ${filePath} (lines ${chunkStartLine}-${chunkEndLine})\n${currentChunk}`,
      chunkType: 'code',
      startLine: chunkStartLine,
      endLine: chunkEndLine,
    });
  }

  return chunks;
}

/**
 * Fallback: line-based chunking for unsupported languages.
 */
function chunkByLines(filePath: string, content: string, summary?: string | null): Chunk[] {
  const lines = content.split('\n');
  const chunks: Chunk[] = [];

  for (let i = 0; i < lines.length; i += 50) {
    const slice = lines.slice(i, i + 50);
    const text = slice.join('\n');
    if (text.trim().length < 20) continue;

    chunks.push({
      content: `// File: ${filePath} (lines ${i + 1}-${Math.min(i + 50, lines.length)})\n${text}`,
      chunkType: 'code',
      startLine: i + 1,
      endLine: Math.min(i + 50, lines.length),
    });
  }

  if (summary?.trim()) {
    chunks.push({
      content: `File summary for ${filePath}: ${summary}`,
      chunkType: 'summary',
      startLine: 0,
      endLine: 0,
    });
  }

  return chunks.slice(0, MAX_CHUNKS_PER_FILE);
}

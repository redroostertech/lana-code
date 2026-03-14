// Import/export extraction via tree-sitter AST queries
import * as path from 'path';
import type { Tree, Language } from 'web-tree-sitter';
import { getQuery } from './parser.js';
import type { LanguageConfig } from './languages.js';
import type { ImportDef, ExportDef } from './types.js';

/**
 * Extract all imports from a parsed tree.
 */
export function extractImports(tree: Tree, lang: Language, config: LanguageConfig): ImportDef[] {
  const query = getQuery(lang, config.importQuery, `imports:${config.id}`);
  if (!query) return [];

  const matches = query.matches(tree.rootNode);
  const imports: ImportDef[] = [];

  for (const match of matches) {
    let source = '';
    let importNode = match.captures.find(c => c.name === 'import')?.node;

    for (const capture of match.captures) {
      if (capture.name === 'source') {
        source = capture.node.text;
      }
    }

    if (!source) continue;

    // Clean up source — remove quotes, angle brackets
    source = source.replace(/^["'<]|["'>]$/g, '');

    // Extract specifiers from the import node
    const specifiers = extractSpecifiers(importNode, config.id);

    const isRelative = source.startsWith('.') || source.startsWith('/');

    imports.push({
      source,
      specifiers,
      isRelative,
      startLine: (importNode?.startPosition.row ?? 0) + 1,
    });
  }

  return imports;
}

/**
 * Extract imported names (specifiers) from an import statement node.
 */
function extractSpecifiers(importNode: any, langId: string): string[] {
  if (!importNode) return [];
  const specs: string[] = [];

  // Walk children looking for import specifier nodes
  for (let i = 0; i < importNode.childCount; i++) {
    const child = importNode.child(i);
    if (!child) continue;

    // JS/TS: import_clause > named_imports > import_specifier
    if (child.type === 'import_clause') {
      for (let j = 0; j < child.childCount; j++) {
        const clause = child.child(j);
        if (!clause) continue;
        if (clause.type === 'identifier') {
          specs.push(clause.text); // default import
        }
        if (clause.type === 'named_imports') {
          for (let k = 0; k < clause.childCount; k++) {
            const spec = clause.child(k);
            if (spec && spec.type === 'import_specifier') {
              const nameNode = spec.childForFieldName('name') || spec.firstNamedChild;
              if (nameNode) specs.push(nameNode.text);
            }
          }
        }
        if (clause.type === 'namespace_import') {
          const nameNode = clause.childForFieldName('name') || clause.lastNamedChild;
          if (nameNode) specs.push(`* as ${nameNode.text}`);
        }
      }
    }
  }

  return specs;
}

/**
 * Extract exports from a parsed tree.
 */
export function extractExports(tree: Tree, lang: Language, config: LanguageConfig): ExportDef[] {
  if (!config.exportQuery) return [];

  const query = getQuery(lang, config.exportQuery, `exports:${config.id}`);
  if (!query) return [];

  const matches = query.matches(tree.rootNode);
  const exports: ExportDef[] = [];

  for (const match of matches) {
    let name = '';
    let source = '';
    let isReexport = false;

    for (const capture of match.captures) {
      if (capture.name === 'name') name = capture.node.text;
      if (capture.name === 'source') {
        source = capture.node.text.replace(/^["']|["']$/g, '');
        isReexport = true;
      }
      if (capture.name === 'reexport') isReexport = true;
    }

    if (isReexport && source) {
      exports.push({ name: name || '*', kind: 'reexport', source });
    } else if (name) {
      exports.push({ name, kind: 'named' });
    }
  }

  return exports;
}

// Common extensions to try when resolving relative imports
const RESOLVE_EXTENSIONS = [
  '', '.ts', '.tsx', '.js', '.jsx', '.mjs',
  '/index.ts', '/index.tsx', '/index.js', '/index.jsx',
  '.py', '.rs', '.go', '.c', '.h', '.cpp', '.hpp',
  '.java', '.rb', '.swift',
];

/**
 * Resolve a relative import path to an actual file path in the project.
 */
export function resolveImportPath(
  importSource: string,
  currentFile: string,
  allFiles: Set<string>,
): string | null {
  if (!importSource.startsWith('.') && !importSource.startsWith('/')) {
    return null; // external package
  }

  const currentDir = path.dirname(currentFile);
  const base = path.normalize(path.join(currentDir, importSource));

  for (const ext of RESOLVE_EXTENSIONS) {
    const candidate = base + ext;
    if (allFiles.has(candidate)) return candidate;
  }

  return null;
}

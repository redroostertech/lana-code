// Symbol extraction via tree-sitter AST queries
import type { Tree, Language, Node as TSNode } from 'web-tree-sitter';
import { getQuery } from './parser.js';
import type { LanguageConfig } from './languages.js';
import type { SymbolDef } from './types.js';

// Map tree-sitter node types to our symbol kinds
// Map tree-sitter node types to symbol kinds
// Some types overlap across languages but map to the same kind, so this works fine
const NODE_KIND_MAP = new Map<string, SymbolDef['kind']>([
  // JS/TS
  ['function_declaration', 'function'],
  ['class_declaration', 'class'],
  ['method_definition', 'method'],
  ['interface_declaration', 'interface'],
  ['type_alias_declaration', 'type'],
  ['enum_declaration', 'enum'],
  ['variable_declaration', 'variable'],
  ['lexical_declaration', 'variable'],
  // Python
  ['function_definition', 'function'],
  ['class_definition', 'class'],
  ['decorated_definition', 'function'],
  // Rust
  ['function_item', 'function'],
  ['struct_item', 'struct'],
  ['enum_item', 'enum'],
  ['trait_item', 'trait'],
  ['impl_item', 'class'],
  ['type_item', 'type'],
  ['const_item', 'constant'],
  ['static_item', 'variable'],
  ['mod_item', 'module'],
  // Go
  ['method_declaration', 'method'],
  ['type_declaration', 'type'],
  // C/C++
  ['struct_specifier', 'struct'],
  ['enum_specifier', 'enum'],
  ['class_specifier', 'class'],
  ['namespace_definition', 'module'],
  ['type_definition', 'type'],
  // Java
  ['enum_declaration', 'enum'],
  // Ruby
  ['method', 'method'],
  ['module', 'module'],
]);

/**
 * Check if a node has an export/pub modifier.
 */
function isExported(node: TSNode, langId: string): boolean {
  const parent = node.parent;
  if (!parent) return false;

  // JS/TS: export statement wraps the declaration
  if (parent.type === 'export_statement') return true;

  // Rust: pub keyword
  if (langId === 'rust') {
    for (let i = 0; i < node.childCount; i++) {
      const child = node.child(i);
      if (child && child.type === 'visibility_modifier') return true;
    }
  }

  // Go: exported if name starts with uppercase
  if (langId === 'go') {
    const nameNode = node.childForFieldName('name');
    if (nameNode) {
      const name = nameNode.text;
      return name.length > 0 && name[0] === name[0].toUpperCase() && name[0] !== name[0].toLowerCase();
    }
  }

  // Python: not exported if starts with _
  if (langId === 'python') {
    const nameNode = node.childForFieldName('name');
    if (nameNode) return !nameNode.text.startsWith('_');
  }

  return false;
}

/**
 * Extract a docstring from the node's preceding sibling or first child.
 */
function extractDocstring(node: TSNode, langId: string): string | undefined {
  // Check preceding sibling for comment
  const prev = node.previousNamedSibling;
  if (prev && (prev.type === 'comment' || prev.type === 'line_comment' || prev.type === 'block_comment')) {
    return prev.text.slice(0, 200);
  }

  // Python: docstring is the first expression_statement > string child
  if (langId === 'python' && (node.type === 'function_definition' || node.type === 'class_definition')) {
    const body = node.childForFieldName('body');
    if (body && body.firstNamedChild?.type === 'expression_statement') {
      const expr = body.firstNamedChild.firstNamedChild;
      if (expr && (expr.type === 'string' || expr.type === 'concatenated_string')) {
        return expr.text.slice(0, 200);
      }
    }
  }

  return undefined;
}

/**
 * Extract all symbols from a parsed tree using tree-sitter queries.
 */
export function extractSymbols(tree: Tree, lang: Language, config: LanguageConfig): SymbolDef[] {
  const query = getQuery(lang, config.symbolQuery, `symbols:${config.id}`);
  if (!query) return [];

  const matches = query.matches(tree.rootNode);
  const symbols: SymbolDef[] = [];

  for (const match of matches) {
    let nameText = '';
    let defNode: TSNode | null = null;

    for (const capture of match.captures) {
      if (capture.name === 'name') {
        nameText = capture.node.text;
      }
      if (capture.name === 'def') {
        defNode = capture.node;
      }
    }

    if (!nameText || !defNode) continue;

    // Skip anonymous/empty names
    if (!nameText.trim()) continue;

    const kind = NODE_KIND_MAP.get(defNode.type) || 'function';
    const exported = isExported(defNode, config.id);
    const docstring = extractDocstring(defNode, config.id);

    symbols.push({
      name: nameText,
      kind,
      startLine: defNode.startPosition.row + 1,
      endLine: defNode.endPosition.row + 1,
      exported,
      docstring,
    });
  }

  return symbols;
}

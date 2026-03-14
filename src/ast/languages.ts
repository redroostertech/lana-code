// Language registry — maps file extensions to tree-sitter grammars and queries
import * as path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const NODE_MODULES = path.resolve(__dirname, '..', '..', 'node_modules');

export interface LanguageConfig {
  id: string;
  extensions: string[];
  grammarPackage: string;
  wasmFile: string;
  symbolQuery: string;
  importQuery: string;
  exportQuery: string;
}

function wasmPath(pkg: string, file: string): string {
  return path.join(NODE_MODULES, pkg, file);
}

const LANGUAGES: LanguageConfig[] = [
  {
    id: 'typescript',
    extensions: ['.ts'],
    grammarPackage: 'tree-sitter-typescript',
    wasmFile: wasmPath('tree-sitter-typescript', 'tree-sitter-typescript.wasm'),
    symbolQuery: `
      (function_declaration name: (identifier) @name) @def
      (class_declaration name: (type_identifier) @name) @def
      (method_definition name: (property_identifier) @name) @def
      (interface_declaration name: (type_identifier) @name) @def
      (type_alias_declaration name: (type_identifier) @name) @def
      (enum_declaration name: (identifier) @name) @def
      (lexical_declaration
        (variable_declarator name: (identifier) @name)) @def
    `,
    importQuery: `
      (import_statement source: (string (string_fragment) @source)) @import
    `,
    exportQuery: `
      (export_statement
        declaration: (_
          name: [(identifier) (type_identifier)] @name)) @export
      (export_statement source: (string (string_fragment) @source)) @reexport
    `,
  },
  {
    id: 'tsx',
    extensions: ['.tsx'],
    grammarPackage: 'tree-sitter-typescript',
    wasmFile: wasmPath('tree-sitter-typescript', 'tree-sitter-tsx.wasm'),
    symbolQuery: `
      (function_declaration name: (identifier) @name) @def
      (class_declaration name: (type_identifier) @name) @def
      (method_definition name: (property_identifier) @name) @def
      (interface_declaration name: (type_identifier) @name) @def
      (type_alias_declaration name: (type_identifier) @name) @def
      (enum_declaration name: (identifier) @name) @def
      (lexical_declaration
        (variable_declarator name: (identifier) @name)) @def
    `,
    importQuery: `
      (import_statement source: (string (string_fragment) @source)) @import
    `,
    exportQuery: `
      (export_statement
        declaration: (_
          name: [(identifier) (type_identifier)] @name)) @export
      (export_statement source: (string (string_fragment) @source)) @reexport
    `,
  },
  {
    id: 'javascript',
    extensions: ['.js', '.jsx', '.mjs', '.cjs'],
    grammarPackage: 'tree-sitter-javascript',
    wasmFile: wasmPath('tree-sitter-javascript', 'tree-sitter-javascript.wasm'),
    symbolQuery: `
      (function_declaration name: (identifier) @name) @def
      (class_declaration name: (identifier) @name) @def
      (method_definition name: (property_identifier) @name) @def
      (variable_declaration
        (variable_declarator name: (identifier) @name)) @def
      (lexical_declaration
        (variable_declarator name: (identifier) @name)) @def
    `,
    importQuery: `
      (import_statement source: (string (string_fragment) @source)) @import
    `,
    exportQuery: `
      (export_statement
        declaration: (_
          name: (identifier) @name)) @export
      (export_statement source: (string (string_fragment) @source)) @reexport
    `,
  },
  {
    id: 'python',
    extensions: ['.py'],
    grammarPackage: 'tree-sitter-python',
    wasmFile: wasmPath('tree-sitter-python', 'tree-sitter-python.wasm'),
    symbolQuery: `
      (function_definition name: (identifier) @name) @def
      (class_definition name: (identifier) @name) @def
    `,
    importQuery: `
      (import_from_statement module_name: (dotted_name) @source) @import
      (import_statement name: (dotted_name) @source) @import
    `,
    exportQuery: '', // Python doesn't have explicit exports
  },
  {
    id: 'rust',
    extensions: ['.rs'],
    grammarPackage: 'tree-sitter-rust',
    wasmFile: wasmPath('tree-sitter-rust', 'tree-sitter-rust.wasm'),
    symbolQuery: `
      (function_item name: (identifier) @name) @def
      (struct_item name: (type_identifier) @name) @def
      (enum_item name: (type_identifier) @name) @def
      (trait_item name: (type_identifier) @name) @def
      (impl_item type: (type_identifier) @name) @def
      (type_item name: (type_identifier) @name) @def
      (const_item name: (identifier) @name) @def
      (static_item name: (identifier) @name) @def
    `,
    importQuery: `
      (use_declaration argument: (_) @source) @import
    `,
    exportQuery: '',
  },
  {
    id: 'go',
    extensions: ['.go'],
    grammarPackage: 'tree-sitter-go',
    wasmFile: wasmPath('tree-sitter-go', 'tree-sitter-go.wasm'),
    symbolQuery: `
      (function_declaration name: (identifier) @name) @def
      (method_declaration name: (field_identifier) @name) @def
      (type_declaration (type_spec name: (type_identifier) @name)) @def
    `,
    importQuery: `
      (import_spec path: (interpreted_string_literal) @source) @import
    `,
    exportQuery: '',
  },
  {
    id: 'c',
    extensions: ['.c', '.h'],
    grammarPackage: 'tree-sitter-c',
    wasmFile: wasmPath('tree-sitter-c', 'tree-sitter-c.wasm'),
    symbolQuery: `
      (function_definition declarator: (_) @name) @def
      (struct_specifier name: (_) @name) @def
      (enum_specifier name: (_) @name) @def
      (type_definition declarator: (_) @name) @def
    `,
    importQuery: `
      (preproc_include path: (_) @source) @import
    `,
    exportQuery: '',
  },
  {
    id: 'cpp',
    extensions: ['.cpp', '.cc', '.cxx', '.hpp', '.hxx'],
    grammarPackage: 'tree-sitter-cpp',
    wasmFile: wasmPath('tree-sitter-cpp', 'tree-sitter-cpp.wasm'),
    symbolQuery: `
      (function_definition declarator: (_) @name) @def
      (class_specifier name: (_) @name) @def
      (struct_specifier name: (_) @name) @def
      (enum_specifier name: (_) @name) @def
      (namespace_definition name: (_) @name) @def
    `,
    importQuery: `
      (preproc_include path: (_) @source) @import
    `,
    exportQuery: '',
  },
  {
    id: 'java',
    extensions: ['.java'],
    grammarPackage: 'tree-sitter-java',
    wasmFile: wasmPath('tree-sitter-java', 'tree-sitter-java.wasm'),
    symbolQuery: `
      (class_declaration name: (identifier) @name) @def
      (interface_declaration name: (identifier) @name) @def
      (method_declaration name: (identifier) @name) @def
      (enum_declaration name: (identifier) @name) @def
    `,
    importQuery: `
      (import_declaration (scoped_identifier) @source) @import
    `,
    exportQuery: '',
  },
  {
    id: 'ruby',
    extensions: ['.rb'],
    grammarPackage: 'tree-sitter-ruby',
    wasmFile: wasmPath('tree-sitter-ruby', 'tree-sitter-ruby.wasm'),
    symbolQuery: `
      (method name: (identifier) @name) @def
      (class name: (constant) @name) @def
      (module name: (constant) @name) @def
    `,
    importQuery: `
      (call method: (identifier) @method arguments: (argument_list (string (string_content) @source))
        (#eq? @method "require"))
    `,
    exportQuery: '',
  },
];

// Build extension -> language lookup
const extMap = new Map<string, LanguageConfig>();
for (const lang of LANGUAGES) {
  for (const ext of lang.extensions) {
    extMap.set(ext, lang);
  }
}

export function getLanguageForFile(filePath: string): LanguageConfig | null {
  const ext = path.extname(filePath).toLowerCase();
  return extMap.get(ext) || null;
}

export function getSupportedExtensions(): string[] {
  return LANGUAGES.flatMap(l => l.extensions);
}

export function getAllLanguages(): LanguageConfig[] {
  return LANGUAGES;
}

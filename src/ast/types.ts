// Shared types for AST-based code analysis

export interface SymbolDef {
  name: string;
  kind: 'function' | 'class' | 'method' | 'interface' | 'type' | 'enum' | 'struct' | 'trait' | 'variable' | 'constant' | 'module';
  startLine: number;
  endLine: number;
  exported: boolean;
  docstring?: string;
}

export interface ImportDef {
  source: string;       // raw import path (e.g., "./utils/auth", "react")
  specifiers: string[]; // imported names (e.g., ["foo", "bar"])
  isRelative: boolean;
  startLine: number;
}

export interface ExportDef {
  name: string;
  kind: 'named' | 'default' | 'reexport';
  source?: string;      // for re-exports: from "..."
}

export interface FileAnalysis {
  path: string;
  language: string;
  symbols: SymbolDef[];
  imports: ImportDef[];
  exports: ExportDef[];
  lines: number;
  size: number;
  mtime: number;
}

export interface DependencyNode {
  file: string;
  importsRaw: string[];
  dependsOn: string[];
  dependedBy: string[];
}

export interface Chunk {
  content: string;
  chunkType: 'code' | 'summary' | 'docs';
  startLine: number;
  endLine: number;
}

// Node-native project indexer — replaces bash phases 1-5 with tree-sitter
import { EventEmitter } from 'events';
import * as fs from 'fs';
import * as path from 'path';
import * as crypto from 'crypto';
import { init as initParser, parseFile } from './parser.js';
import { extractSymbols } from './symbols.js';
import { extractImports, extractExports } from './imports.js';
import { buildDependencyGraph, serializeDepsJson } from './graph.js';
import { getSupportedExtensions } from './languages.js';
import type { FileAnalysis, DependencyNode } from './types.js';

// Directories to exclude from scanning
const EXCLUDED_DIRS = new Set([
  '.git', 'node_modules', '__pycache__', '.venv', 'venv', '.next',
  'dist', 'build', '.cache', '.tox', '.mypy_cache', '.pytest_cache',
  'target', 'vendor', 'deps', '_build', '.lana',
]);

export interface IndexOptions {
  targetDir?: string;      // subdirectory to scope indexing to
  typeFilter?: string[];   // only these extensions (e.g., ['.ts', '.tsx'])
  force?: boolean;
  maxFiles?: number;
}

export interface IndexResult {
  files: number;
  directories: number;
  dependencies: number;
  cached: number;
  duration: number;
}

interface IndexEntry {
  path: string;
  symbols: string[];
  imports: string[];
  docs: string;
  lines: number;
  size: number;
  mtime: number;
  summary: string;
}

export class ProjectIndexer extends EventEmitter {
  /**
   * Run the full indexing pipeline (Phases 1-4).
   * Phase 5 (LLM summaries) and Phase 6 (embeddings) are handled separately.
   */
  async indexProject(
    projectDir: string,
    options: IndexOptions = {},
  ): Promise<IndexResult> {
    const startTime = Date.now();
    const scanDir = options.targetDir
      ? path.resolve(projectDir, options.targetDir)
      : projectDir;
    const indexRoot = projectDir; // .lana always at project root
    const lanaDir = path.join(indexRoot, '.lana');
    const indexFile = path.join(lanaDir, 'index.json');
    const depsFile = path.join(lanaDir, 'deps.json');
    const metaFile = path.join(lanaDir, 'meta.json');

    fs.mkdirSync(lanaDir, { recursive: true });

    // Initialize tree-sitter
    this.emit('status', 'Initializing tree-sitter parser...');
    await initParser();

    // ── Phase 1: Scan files ──────────────────────────
    this.emit('status', 'Phase 1/4: Scanning files...');
    const supportedExts = options.typeFilter?.length
      ? options.typeFilter.map(e => e.startsWith('.') ? e : `.${e}`)
      : getSupportedExtensions();
    const extSet = new Set(supportedExts.map(e => e.toLowerCase()));

    const allFiles = this.scanFiles(scanDir, projectDir, extSet, options.maxFiles || 2000);
    const dirCount = new Set(allFiles.map(f => path.dirname(f))).size;

    this.emit('status', `Found ${allFiles.length} files across ${dirCount} directories`);

    if (allFiles.length === 0) {
      this.emit('status', 'No indexable source files found.');
      return { files: 0, directories: 0, dependencies: 0, cached: 0, duration: Date.now() - startTime };
    }

    // ── Phase 2: Incremental check ───────────────────
    let existingEntries = new Map<string, IndexEntry>();
    let cached = 0;

    if (!options.force && fs.existsSync(indexFile)) {
      this.emit('status', 'Phase 2/4: Checking for changes...');
      try {
        const existing: IndexEntry[] = JSON.parse(fs.readFileSync(indexFile, 'utf8'));
        for (const entry of existing) {
          existingEntries.set(entry.path, entry);
        }
      } catch { /* corrupted index, rebuild */ }
    }

    const filesToProcess: string[] = [];
    const cachedEntries: IndexEntry[] = [];

    for (const relPath of allFiles) {
      const fullPath = path.join(projectDir, relPath);
      try {
        const stat = fs.statSync(fullPath);
        const mtime = Math.floor(stat.mtimeMs / 1000);
        const existing = existingEntries.get(relPath);

        if (existing && existing.mtime === mtime) {
          cachedEntries.push(existing);
          cached++;
        } else {
          filesToProcess.push(relPath);
        }
      } catch {
        filesToProcess.push(relPath); // re-process if stat fails
      }
    }

    if (filesToProcess.length === 0) {
      this.emit('status', `✓ All ${cached} files up to date`);
      // Still rebuild deps (fast)
      const entries: IndexEntry[] = [...cachedEntries];
      this.writeDepsGraph(entries, projectDir, depsFile);
      return { files: 0, directories: dirCount, dependencies: 0, cached, duration: Date.now() - startTime };
    }

    this.emit('status', `Changed: ${filesToProcess.length} | Cached: ${cached}`);

    // ── Phase 3: Parse + extract with tree-sitter ────
    this.emit('status', `Phase 3/4: Analyzing ${filesToProcess.length} files with tree-sitter...`);

    const analyses: FileAnalysis[] = [];
    const newEntries: IndexEntry[] = [];
    let processedCount = 0;
    let lastReportedPct = -1;

    for (const relPath of filesToProcess) {
      const fullPath = path.join(projectDir, relPath);
      let content: string;
      try {
        content = fs.readFileSync(fullPath, 'utf8');
      } catch {
        processedCount++;
        continue;
      }

      const stat = fs.statSync(fullPath);
      const mtime = Math.floor(stat.mtimeMs / 1000);
      const lines = content.split('\n').length;

      try {
        const result = await parseFile(relPath, content);
        if (result) {
          const symbols = extractSymbols(result.tree, result.lang, result.config);
          const imports = extractImports(result.tree, result.lang, result.config);
          const exports = extractExports(result.tree, result.lang, result.config);

          analyses.push({
            path: relPath,
            language: result.config.id,
            symbols,
            imports,
            exports,
            lines,
            size: stat.size,
            mtime,
          });

          // Build index entry (backward compatible with index.json format)
          const existingEntry = existingEntries.get(relPath);
          newEntries.push({
            path: relPath,
            symbols: symbols.map(s => s.name),
            imports: imports.map(i => i.source),
            docs: symbols.filter(s => s.docstring).map(s => `${s.name}: ${s.docstring}`).join('; ').slice(0, 500),
            lines,
            size: stat.size,
            mtime,
            summary: existingEntry?.summary || '', // preserve existing summary
          });
        } else {
          // Unsupported language — include basic metadata
          newEntries.push({
            path: relPath,
            symbols: [],
            imports: [],
            docs: '',
            lines,
            size: stat.size,
            mtime,
            summary: existingEntries.get(relPath)?.summary || '',
          });
        }
      } catch {
        // Parse error — include with empty analysis
        newEntries.push({
          path: relPath,
          symbols: [],
          imports: [],
          docs: '',
          lines,
          size: stat.size,
          mtime,
          summary: existingEntries.get(relPath)?.summary || '',
        });
      }

      processedCount++;
      const pct = Math.floor((processedCount / filesToProcess.length) * 100);
      if (pct >= lastReportedPct + 5) {
        this.emit('progress', pct, `analyzing ${processedCount}/${filesToProcess.length} (${pct}%)`);
        lastReportedPct = pct;
      }
    }

    // Merge new + cached entries
    const allEntries = [...cachedEntries, ...newEntries].sort((a, b) => a.path.localeCompare(b.path));

    // Write index.json
    fs.writeFileSync(indexFile, JSON.stringify(allEntries, null, 2));
    this.emit('status', `✓ Analyzed ${filesToProcess.length} files (${allEntries.length} total in index)`);

    // ── Phase 4: Build dependency graph ──────────────
    this.emit('status', 'Phase 4/4: Building dependency graph...');
    const depCount = this.writeDepsGraph(allEntries, projectDir, depsFile);
    this.emit('status', `✓ Mapped ${depCount} dependency links`);

    // Write metadata
    const meta = {
      file_count: allEntries.length,
      dir_count: dirCount,
      indexed_at: new Date().toISOString(),
      project_dir: projectDir,
      analyzer: 'tree-sitter',
    };
    fs.writeFileSync(metaFile, JSON.stringify(meta, null, 2));

    const duration = Date.now() - startTime;
    this.emit('status', `Index complete — ${allEntries.length} files, ${depCount} deps (${(duration / 1000).toFixed(1)}s)`);

    return {
      files: filesToProcess.length,
      directories: dirCount,
      dependencies: depCount,
      cached,
      duration,
    };
  }

  /**
   * Build and write the dependency graph. Returns total dependency count.
   */
  private writeDepsGraph(entries: IndexEntry[], projectDir: string, depsFile: string): number {
    // Convert IndexEntry to FileAnalysis for graph builder
    const allPaths = new Set(entries.map(e => e.path));
    const analyses: FileAnalysis[] = entries.map(e => ({
      path: e.path,
      language: '',
      symbols: [],
      imports: e.imports.map(source => ({
        source,
        specifiers: [],
        isRelative: source.startsWith('.') || source.startsWith('/'),
        startLine: 0,
      })),
      exports: [],
      lines: e.lines,
      size: e.size,
      mtime: e.mtime,
    }));

    const graph = buildDependencyGraph(analyses);
    const serialized = serializeDepsJson(graph);
    fs.writeFileSync(depsFile, JSON.stringify(serialized, null, 2));

    let depCount = 0;
    for (const node of graph) {
      depCount += node.dependsOn.length;
    }
    return depCount;
  }

  /**
   * Recursively scan for source files.
   */
  private scanFiles(
    dir: string,
    projectRoot: string,
    extensions: Set<string>,
    maxFiles: number,
  ): string[] {
    const results: string[] = [];

    const walk = (currentDir: string) => {
      if (results.length >= maxFiles) return;

      let entries: fs.Dirent[];
      try {
        entries = fs.readdirSync(currentDir, { withFileTypes: true });
      } catch {
        return;
      }

      for (const entry of entries) {
        if (results.length >= maxFiles) return;

        if (entry.name.startsWith('.')) continue;
        if (EXCLUDED_DIRS.has(entry.name) && entry.isDirectory()) continue;

        const fullPath = path.join(currentDir, entry.name);

        if (entry.isDirectory()) {
          walk(fullPath);
        } else if (entry.isFile()) {
          const ext = path.extname(entry.name).toLowerCase();
          if (extensions.has(ext)) {
            results.push(path.relative(projectRoot, fullPath));
          }
        }
      }
    };

    walk(dir);
    return results.sort();
  }
}

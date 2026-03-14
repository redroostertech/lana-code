// Core tree-sitter parser — WASM-based, lazy grammar loading
import { Parser, Language, Query, Tree } from 'web-tree-sitter';
import * as fs from 'fs';
import * as path from 'path';
import { fileURLToPath } from 'url';
import { getLanguageForFile } from './languages.js';
import type { LanguageConfig } from './languages.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const NODE_MODULES = path.resolve(__dirname, '..', '..', 'node_modules');
const WASM_PATH = path.join(NODE_MODULES, 'web-tree-sitter', 'web-tree-sitter.wasm');

let initialized = false;
const languageCache = new Map<string, Language>();
const queryCache = new Map<string, Query>();
let parserInstance: Parser | null = null;

/**
 * Initialize the tree-sitter WASM runtime. Must be called once before parsing.
 */
export async function init(): Promise<void> {
  if (initialized) return;
  await Parser.init({
    locateFile: () => WASM_PATH,
  });
  initialized = true;
}

/**
 * Get or create a Parser instance.
 */
function getParser(): Parser {
  if (!parserInstance) {
    parserInstance = new Parser();
  }
  return parserInstance;
}

/**
 * Load a language grammar from its WASM file. Cached after first load.
 */
export async function loadLanguage(config: LanguageConfig): Promise<Language> {
  const cached = languageCache.get(config.id);
  if (cached) return cached;

  if (!fs.existsSync(config.wasmFile)) {
    throw new Error(`Grammar WASM not found: ${config.wasmFile}`);
  }

  const lang = await Language.load(config.wasmFile);
  languageCache.set(config.id, lang);
  return lang;
}

/**
 * Get a compiled query for a language. Cached.
 */
const failedQueries = new Set<string>();

export function getQuery(lang: Language, queryStr: string, cacheKey: string): Query | null {
  if (!queryStr.trim()) return null;
  if (failedQueries.has(cacheKey)) return null;
  const cached = queryCache.get(cacheKey);
  if (cached) return cached;

  try {
    const q = new Query(lang, queryStr);
    queryCache.set(cacheKey, q);
    return q;
  } catch (err: any) {
    failedQueries.add(cacheKey);
    console.error(`Query compilation failed for ${cacheKey}: ${err.message}`);
    return null;
  }
}

/**
 * Parse a file's content and return the tree-sitter Tree.
 */
export async function parseFile(filePath: string, content: string): Promise<{ tree: Tree; lang: Language; config: LanguageConfig } | null> {
  await init();

  const config = getLanguageForFile(filePath);
  if (!config) return null;

  const lang = await loadLanguage(config);
  const parser = getParser();
  parser.setLanguage(lang);

  const tree = parser.parse(content);
  if (!tree) return null;
  return { tree, lang, config };
}

/**
 * Parse content with a known language config.
 */
export async function parseWithLanguage(content: string, config: LanguageConfig): Promise<{ tree: Tree; lang: Language } | null> {
  await init();
  const lang = await loadLanguage(config);
  const parser = getParser();
  parser.setLanguage(lang);
  const tree = parser.parse(content);
  if (!tree) return null;
  return { tree, lang };
}

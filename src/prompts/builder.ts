/**
 * Flow-aware prompt builder.
 * Composes a system prompt from modular sections based on what the user is doing.
 */

import * as fs from 'fs';
import * as path from 'path';

export type PromptFlow = 'fresh-session' | 'files-attached' | 'exploration' | 'general';

interface PromptBuilderOptions {
  lanaDir: string;
  workDir: string;
}

// Cache loaded prompt files
const promptCache = new Map<string, string>();

function loadPromptFile(lanaDir: string, filename: string): string {
  const cached = promptCache.get(filename);
  if (cached !== undefined) return cached;

  const filePath = path.join(lanaDir, 'prompts', filename);
  try {
    const content = fs.readFileSync(filePath, 'utf8');
    promptCache.set(filename, content);
    return content;
  } catch {
    promptCache.set(filename, '');
    return '';
  }
}

/**
 * Detect the flow type from user input.
 */
export function detectFlow(userInput: string, isFirstTurn: boolean): PromptFlow {
  // Files attached via @
  if (/@\S+/.test(userInput)) {
    return 'files-attached';
  }

  // Fresh session — first turn with no files
  if (isFirstTurn) {
    return 'fresh-session';
  }

  // Exploration — open-ended questions about a project/codebase
  const explorationPatterns = [
    /^(tell me about|what (does|is)|explain|describe|how does|overview|explore|analyze)\b/i,
    /\b(this project|this codebase|this repo)\b/i,
  ];
  if (explorationPatterns.some(p => p.test(userInput))) {
    return 'exploration';
  }

  return 'general';
}

/**
 * Build the system prompt for the given flow.
 * Composes: base + tools reference + flow-specific context + environment.
 */
export function buildSystemPrompt(
  flow: PromptFlow,
  opts: PromptBuilderOptions,
): string {
  const { lanaDir, workDir } = opts;

  // Always include the base prompt
  let base = loadPromptFile(lanaDir, 'system-base.txt');
  if (!base) {
    // Fallback to the monolithic prompt if modular files don't exist
    base = loadPromptFile(lanaDir, 'system.txt');
  }

  const parts: string[] = [base];

  // Add tools reference (compact)
  const tools = loadPromptFile(lanaDir, 'context-tools.txt');
  if (tools) parts.push(tools);

  // Add flow-specific context
  const flowFile: Record<PromptFlow, string> = {
    'fresh-session': 'context-fresh-session.txt',
    'files-attached': 'context-files-attached.txt',
    'exploration': 'context-exploration.txt',
    'general': '', // No extra context needed
  };
  const contextFile = flowFile[flow];
  if (contextFile) {
    const context = loadPromptFile(lanaDir, contextFile);
    if (context) parts.push(context);
  }

  // Always append environment info
  parts.push(`## Environment\n- Working directory: ${workDir}\n- All file paths are relative to the working directory unless absolute.\n- The user is working in this directory. Use it as the base for all file operations.`);

  return parts.join('\n\n');
}

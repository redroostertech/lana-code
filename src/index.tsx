#!/usr/bin/env node
// LANA CODER — Ink-based terminal UI entry point

import React from 'react';
import { render } from 'ink';
import * as fs from 'fs';
import * as path from 'path';
import { execSync } from 'child_process';

import App from './app.js';
import { loadConfig } from './state/config.js';
import type { ToolDefinition } from './api/types.js';

// Load config from env vars (set by bash launcher) or defaults
const config = loadConfig();

// Load system prompt and inject working directory context
let systemPrompt = 'You are LANA, a locally autonomous coding assistant.';
const promptPath = path.join(config.lanaDir, 'prompts', 'system.txt');
try {
  systemPrompt = fs.readFileSync(promptPath, 'utf8');
} catch {
  // Use default if system prompt file not found
}

const workDir = process.env['LANA_WORK_DIR'] || process.cwd();
systemPrompt += `\n\n## Environment\n- Working directory: ${workDir}\n- All file paths are relative to the working directory unless absolute.\n- The user is working in this directory. Use it as the base for all file operations.`;

// Load tool definitions from bash scripts (all 24 tools)
let toolDefs: ToolDefinition[] = [];
try {
  const dumpScript = path.join(config.lanaDir, 'lib', 'dump_tool_defs.sh');
  const json = execSync(`bash "${dumpScript}"`, {
    env: { ...process.env, LANA_HOME: config.lanaDir, LANA_WORK_DIR: workDir },
    timeout: 5000,
  }).toString();
  toolDefs = JSON.parse(json);
} catch (err: any) {
  process.stderr.write(`Warning: Could not load tool definitions: ${err.message}\n`);
  // Fallback to minimal set
  toolDefs = [
    { type: 'function', function: { name: 'read_file', description: 'Read a file.', parameters: { type: 'object', properties: { path: { type: 'string', description: 'File path' } }, required: ['path'] } } },
    { type: 'function', function: { name: 'write_file', description: 'Create or overwrite a file.', parameters: { type: 'object', properties: { path: { type: 'string', description: 'File path' }, content: { type: 'string', description: 'Content' } }, required: ['path', 'content'] } } },
    { type: 'function', function: { name: 'edit_file', description: 'Replace a string in a file.', parameters: { type: 'object', properties: { path: { type: 'string', description: 'File path' }, old_string: { type: 'string', description: 'String to find' }, new_string: { type: 'string', description: 'Replacement' } }, required: ['path', 'old_string', 'new_string'] } } },
    { type: 'function', function: { name: 'bash', description: 'Execute a bash command.', parameters: { type: 'object', properties: { command: { type: 'string', description: 'Command' } }, required: ['command'] } } },
    { type: 'function', function: { name: 'grep_search', description: 'Search file contents.', parameters: { type: 'object', properties: { pattern: { type: 'string', description: 'Pattern' } }, required: ['pattern'] } } },
    { type: 'function', function: { name: 'task_complete', description: 'Signal task completion.', parameters: { type: 'object', properties: { summary: { type: 'string', description: 'Summary' } }, required: ['summary'] } } },
  ];
}

// Render the Ink app
render(<App config={config} systemPrompt={systemPrompt} toolDefs={toolDefs} />);

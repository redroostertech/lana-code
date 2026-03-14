# Usage Guide

## Starting LANA

```bash
# Start in current directory
lana-code

# Start in a project directory
lana-code ~/my-project

# Start with a specific model
LANA_MODEL=qwen3 lana-code

# Start in proxy mode (routes through lana-proxy)
LANA_USE_PROXY=true lana-code
```

## The TUI

LANA runs as a React Ink terminal application with a rich interactive interface.

```
┌─────────────────────────────────────────┐
│  LANA CODE v0.4.0                      │
│  Model: qwen2.5 | Dir: ~/my-project    │
├─────────────────────────────────────────┤
│                                         │
│  assistant                              │
│    Let me read that file first.         │
│    [tool: read_file] main.py            │
│    This is a Flask web application...   │
│                                         │
├─────────────────────────────────────────┤
│  lana>                                  │
│  ──────── qwen2.5 | ~/my-project ──────│
└─────────────────────────────────────────┘
```

### Keyboard Shortcuts

| Key | Action |
|---|---|
| `Enter` | Send prompt |
| `Ctrl+C` | Interrupt current tool loop |
| `ESC` | Stop generation mid-stream |
| `Ctrl+D` | Exit (on empty prompt) |
| `Up/Down` | Navigate input history |

### Command Picker

Type `/` to open an interactive command picker with fuzzy search:

```
lana> /
  ┌──────────────────────────┐
  │ /index   Index project   │  ← arrow keys to navigate
  │ /search  Search index    │
  │ /load    Load project    │
  │ /status  Show dashboard  │
  │ ...                      │
  └──────────────────────────┘
```

Start typing to filter commands. Press Enter to select, Escape to cancel.

## File Attachment

Attach files or directories to your prompt by prefixing paths with `@`:

```
lana> Explain this code @src/auth.ts

lana> Review these files @src/middleware/ @package.json

lana> What's different between @old.py and @new.py
```

- `@file.ts` — Attaches the file's contents to the prompt
- `@directory/` — Attaches a listing of the directory contents
- Multiple `@` attachments can be used in a single prompt

### File Dropzone

Drag and drop files from Finder into the terminal — LANA auto-detects absolute file paths and treats them as `@` attachments. You can also paste file paths directly.

## Commands

All commands start with `/`. Type `/` to open the interactive picker, or type the full command:

### Project Management

```bash
/load [path]                # Load a project directory into context
/index [path] [flags]       # Index project with tree-sitter (see below)
/search <query>             # Search the project index
/cd [path]                  # Change working directory
/status                     # Show project dashboard (files, index, context usage)
```

### Conversation

```bash
/clear                      # Clear conversation and start fresh
/compact                    # Manually compress conversation to save context
/memory                     # View or set project-specific memories
```

### Session History

```bash
/history [query]            # List past sessions (optionally filter)
/recall <id>                # Load a previous session's context
```

### Model & Settings

```bash
/model                      # Show current model
/model qwen3                # Switch to a different model
/accept confirm             # Set permission mode (confirm/auto-edit/yolo)
/debug                      # Toggle debug mode (shows raw API payloads)
/version                    # Show version, model, and server info
```

## Project Indexing

### Basic Usage

```
lana> /index
```

This runs the tree-sitter analysis pipeline on your project:

1. **Phase 1 — Scan**: Finds all source files (respects `.git`, `node_modules`, etc. exclusions)
2. **Phase 2 — Incremental check**: Compares file mtimes against the existing index, skips unchanged files
3. **Phase 3 — AST analysis**: Parses each file with tree-sitter, extracts symbols, imports, and exports
4. **Phase 4 — Dependency graph**: Resolves import paths and builds forward/reverse dependency edges

Progress is displayed in real-time in the status bar.

### Scoped Indexing

```bash
/index src                  # Only index the src/ subdirectory
/index --type ts,tsx        # Only TypeScript files
/index --type py            # Only Python files
/index src --type rs        # Rust files under src/
/index --force              # Re-index everything (ignore mtime cache)
```

### What Gets Extracted

**Symbols** (per language):
- Functions, methods, classes, interfaces, types, enums, traits, structs, modules, constants

**Imports**:
- Source paths, named/default/namespace specifiers
- Classified as relative or external
- Resolved to actual file paths (tries `.ts`, `.tsx`, `/index.ts`, etc.)

**Exports**:
- Named exports with identifiers
- Re-exports with source paths

**Dependencies**:
- Forward edges: "file A depends on file B"
- Reverse edges: "file B is depended on by file A"

### Supported Languages

| Language | Extensions | Symbols | Imports | Exports |
|---|---|---|---|---|
| TypeScript | `.ts` | functions, classes, interfaces, types, enums | ES imports | named, re-exports |
| TSX | `.tsx` | functions, classes, interfaces, types, enums | ES imports | named, re-exports |
| JavaScript | `.js`, `.jsx`, `.mjs`, `.cjs` | functions, classes, variables | ES imports | named, re-exports |
| Python | `.py` | functions, classes | `import`, `from...import` | *(convention-based)* |
| Rust | `.rs` | functions, structs, enums, traits, impls, types | `use` declarations | *(pub-based)* |
| Go | `.go` | functions, methods, types | `import` | *(uppercase-based)* |
| C | `.c`, `.h` | functions, structs, enums, typedefs | `#include` | — |
| C++ | `.cpp`, `.cc`, `.hpp`, etc. | functions, classes, structs, enums, namespaces | `#include` | — |
| Java | `.java` | classes, interfaces, methods, enums | `import` | — |
| Ruby | `.rb` | methods, classes, modules | `require` | — |

### Index Output

Stored in your project's `.lana/` directory:

| File | Contents |
|---|---|
| `index.json` | All files with symbols, imports, docs, metadata |
| `deps.json` | Dependency graph (forward + reverse edges) |
| `meta.json` | Index metadata (file count, timestamp, analyzer) |
| `index.db` | SQLite vector store (if embedding is enabled) |

## Searching

### Basic Search

```
lana> /search authentication middleware
```

Searches the project index for matching files by:
- File paths
- Symbol names
- LLM-generated summaries

### Semantic Search (with embeddings)

When the vector index is built (`.lana/index.db` exists), search becomes hybrid:

1. **Regex match** — Searches paths, symbols, and summaries in `index.json`
2. **Vector match** — Embeds your query and finds similar code chunks via cosine similarity
3. **Merge** — Results are combined using Reciprocal Rank Fusion (k=60)

This means searching "authentication handling" will find `verifyToken()`, `checkJWT()`, and related code even without keyword overlap.

## Tool Execution

When the LLM needs to interact with your system, it calls tools. LANA handles the execution.

### Permission Modes

**confirm** (default) — Asks before every write, edit, or command execution:

```
assistant wants to run: bash
  command: npm install express

  [y]es  [n]o  [e]dit  > _
```

**auto-edit** — Auto-approves file reads and edits, confirms command execution:

```
lana> /accept auto-edit
```

**yolo** — Auto-approves everything (use in trusted projects):

```
lana> /accept yolo
```

You can also set this via environment variable:

```bash
LANA_ACCEPT=yolo lana-code
```

### Tool Types

**Reading tools** (always auto-approved with `AUTO_CONFIRM_READ=true`):
- `read_file` — Read file contents
- `grep_search` — Search with regex
- `glob_find` — Find files by pattern
- `list_dir` — List directory contents
- `search_index` — Search project index

**Writing tools** (require confirmation in confirm mode):
- `write_file` — Create or overwrite files
- `edit_file` — Find-and-replace edits (shown as color-coded diffs)
- `move_file`, `copy_file`, `delete_file`

**Execution tools** (require confirmation in confirm and auto-edit modes):
- `bash` — Run shell commands

### Tool Loop

LANA runs up to 50 tool calls per turn (configurable via `MAX_TOOL_LOOPS` in config.sh). When the limit is reached, LANA asks the model to summarize progress and remaining work, then offers the user a choice: continue, redirect, or stop.

Long tool outputs (80+ lines by default) are automatically compressed into summaries to save context space.

## Conversation Management

### Context Window

LANA tracks context usage (shown in the status bar). When the conversation approaches the context limit (default 32K tokens), it automatically compacts older messages:

1. The oldest messages are summarized into a compact paragraph
2. Recent messages are preserved verbatim
3. The conversation continues with the compressed context

You can manually compact at any time:

```
lana> /compact
```

### Project Memories

LANA can store project-specific notes that persist across sessions:

```
lana> /memory
```

Memories are loaded into the system prompt whenever you work in that project directory.

### Session History

Every conversation is saved automatically. Browse past sessions:

```
lana> /history
lana> /history flask migration
```

Load a previous session's context:

```
lana> /recall abc123
```

## Debug Mode

Toggle debug mode to see raw API payloads:

```
lana> /debug
```

When enabled, shows:
- Full JSON request sent to the LLM
- Full JSON response received
- Token usage per request

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `LANA_MODEL` | `qwen2.5` | Default model to use |
| `LANA_ACCEPT` | `confirm` | Permission mode |
| `LANA_USE_PROXY` | `false` | Route through lana-proxy |
| `LANA_API_MODEL` | *(auto)* | Model name in API requests |
| `LANA_DEBUG` | `false` | Enable debug output |
| `LANA_HISTORY_DIR` | `~/.lana/history` | Session history location |

## Example Workflows

### Code Review

```
lana> /load .
lana> Review the changes in src/auth.py. Look for security issues.
```

### Feature Implementation

```
lana> /load .
lana> /index
lana> Add a rate limiter middleware to the Express app. \
      It should limit to 100 requests per minute per IP. \
      Use the existing middleware pattern in @src/middleware/
```

### Exploring a New Codebase

```
lana> /load ~/unfamiliar-project
lana> /index
lana> Explain the architecture of this project. What are the main \
      components and how do they interact?
```

### Debugging

```
lana> Read the error log at /tmp/app.log and explain what's failing.
      Then fix the root cause.
```

### Targeted Indexing

```
lana> /index src/api --type ts
lana> /search request validation
lana> Show me all the API endpoint handlers and their validation logic
```

## Tips

- **Use `@` to attach context** — `@src/auth.ts` is faster than asking LANA to read the file.
- **Use `/index` for large projects** — The symbol index lets LANA find relevant code without reading every file.
- **Scope your index** — `/index src --type ts` is faster than indexing everything when you only need TypeScript.
- **Be specific** — "Fix the authentication bug" is vague. "The login endpoint returns 500 when the email contains a plus sign" gives LANA something concrete.
- **Start with confirm mode** — Watch what LANA does before switching to yolo.
- **Use Ctrl+C to redirect** — If LANA goes down the wrong path, interrupt and give a course correction.
- **Check /status** — Shows context usage, loaded project info, and index state.
- **Drag files in** — Drag from Finder into the terminal instead of typing paths.

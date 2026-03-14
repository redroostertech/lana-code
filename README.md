# LANA CODE

**Locally Autonomous Neural Agent** — a fully local agentic coding CLI with a rich terminal UI.

LANA CODE is an interactive terminal assistant that uses local LLMs via llama.cpp to help with software engineering tasks: reading, writing, editing, and executing code with tool-use capabilities. No cloud APIs, no telemetry, everything runs on your machine.

Built with **TypeScript**, **React Ink** for the TUI, and **tree-sitter** for AST-powered code analysis.

## Quick Start

```bash
# Install (builds llama.cpp, downloads models, installs Node dependencies)
bash install.sh

# Run
lana-code
```

## How It Works

```
┌──────────┐     ┌──────────────────┐     ┌─────────────┐
│          │────>│                  │────>│             │
│ Terminal │     │  LANA CODE      │     │  llama.cpp  │
│  (you)   │<───│  (Ink/React TUI) │<───│  (local LLM)│
│          │     │                  │     │             │
└──────────┘     └────────┬─────────┘     └─────────────┘
                          │
              ┌───────────┼───────────┐
              │           │           │
        ┌─────┴────┐ ┌────┴────┐ ┌────┴──────┐
        │  Tools   │ │ AST     │ │ Embedding │
        │ read/edit│ │ tree-   │ │ vector    │
        │ bash/grep│ │ sitter  │ │ search    │
        │ glob/etc │ │ analysis│ │ (SQLite)  │
        └──────────┘ └─────────┘ └───────────┘
```

1. You type a prompt or question
2. LANA sends your conversation + available tools to the local LLM
3. The LLM responds with text or tool calls (read a file, run a command, etc.)
4. LANA executes the tools and feeds results back to the LLM
5. Loop continues until the LLM provides a final text response

All inference runs locally on your GPU via llama.cpp. No data leaves your machine.

## Features

### Rich Terminal UI (React Ink)

LANA uses [Ink](https://github.com/vadimdemedes/ink) for a full React-based terminal interface:

- **Streaming markdown** — Responses render with headers, bold, code blocks, and syntax highlighting
- **Command picker** — Type `/` to get an interactive fuzzy-searchable command menu
- **File attachment** — Prefix paths with `@` to attach file or directory contents to your prompt
- **File dropzone** — Drag files into the terminal and they're auto-detected and attached
- **Diff viewer** — File edits display as color-coded diffs before confirmation
- **Status bar** — Shows model, working directory, context usage, and indexing progress
- **Spinner** — Animated thinking indicator during LLM inference

### Agentic Tool Loop

LANA executes multi-step tasks autonomously. The LLM can chain tool calls to:

- Read files to understand code
- Search codebases with grep and glob
- Write new files or edit existing ones
- Run shell commands and inspect output
- Index projects for symbol-aware search

### Tools (22 available)

**Core:**
- `read_file` — Read file contents with optional line range
- `write_file` — Create or overwrite files
- `edit_file` — Surgical find-and-replace edits
- `bash` — Execute shell commands

**Awareness:**
- `grep_search` — Search file contents with regex
- `glob_find` — Find files by pattern
- `list_dir` — List directory contents
- `search_index` — Hybrid search (regex + vector semantic search)

**Execution:**
- `bash` with configurable permission modes

**Intelligence:**
- `project_summary` — Generate project overviews
- `file_summary` — Summarize individual files

**File Operations:**
- `move_file`, `copy_file`, `delete_file`

### Permission Modes

Control how much autonomy LANA has:

| Mode | Behavior |
|---|---|
| `confirm` | Ask before every write/edit/execute (default) |
| `auto-edit` | Auto-approve reads and edits, confirm executions |
| `yolo` | Auto-approve everything |

Switch at any time: `/accept yolo`

### Project Indexing (tree-sitter)

LANA uses [tree-sitter](https://tree-sitter.github.io/) (via WASM) for fast, accurate code analysis:

```
/index
```

The indexer:
- **Parses ASTs** for 10 languages using tree-sitter grammars
- **Extracts symbols** — functions, classes, interfaces, types, enums, traits, structs
- **Maps imports/exports** — resolves relative paths, tracks specifiers
- **Builds dependency graphs** — forward and reverse edges between files
- **Incremental** — only re-analyzes files with changed mtimes
- **Fast** — ~7 seconds for 2000 files (vs minutes with regex-based tools)

Supported languages: TypeScript, TSX, JavaScript, Python, Rust, Go, C, C++, Java, Ruby

You can scope indexing:

```
/index src              # Only index the src/ subdirectory
/index --type ts,tsx    # Only TypeScript files
/index --force          # Re-index everything (ignore cache)
```

Index is stored in your project's `.lana/` directory (`index.json`, `deps.json`, `meta.json`).

### Vector Embeddings & Semantic Search

LANA can run a second llama-server instance for embedding:

```
Chat:      llama-server :8080  (qwen2.5-coder 14B, ~10GB)
Embedding: llama-server :8081  (nomic-embed-text, ~270MB)
```

- **Code-aware chunking** — Splits at function/class boundaries using AST analysis
- **SQLite vector store** — Embeddings stored in `.lana/index.db` per project
- **Hybrid search** — Combines regex matching with cosine similarity, merged via Reciprocal Rank Fusion
- **RAM-aware** — Dual-loads both models on 16GB+ machines; swaps models on 8GB machines with clear notifications

Semantic search means "authentication handling" finds `verifyToken()` even without keyword overlap.

### File Attachment

Attach files or directories to your prompt with `@`:

```
lana> Explain this code @src/auth.ts

lana> Review these files @src/middleware/ @package.json

lana> What's different between @old.py and @new.py
```

Drag-and-drop also works — LANA auto-detects file paths pasted or dragged into the terminal.

### Conversation Management

- **Auto-compaction** — When context approaches the limit, LANA automatically compresses older messages into a summary
- **Session history** — Conversations are saved and searchable across sessions
- **Session recall** — Load previous session context into the current conversation

## Proxy Mode

LANA CODE can route through **[lana-proxy](https://github.com/redroostertech/lana-proxy)** for advanced model routing, caching, analytics, and request queuing:

```bash
# Start lana-proxy (see lana-proxy README)
lana-proxy

# Run LANA in proxy mode
LANA_USE_PROXY=true lana-code
```

In proxy mode:
- Server lifecycle is managed by lana-proxy, not lana-coder
- `/model` switches the model name sent to the proxy (proxy handles routing)
- Health checks target the proxy instead of llama-server directly
- No llama-server or model files required locally

## Commands

Type `/` to open the interactive command picker, or type a command directly:

| Command | Description |
|---|---|
| `/status` | Project status dashboard |
| `/model [name]` | Switch model (or show current) |
| `/load [path]` | Load project into context |
| `/index [path] [--type ext] [--force]` | Index project with tree-sitter |
| `/search <query>` | Search project index (hybrid regex + vector) |
| `/cd [path]` | Change working directory |
| `/memory` | View/set project memories |
| `/history [query]` | List past sessions |
| `/recall <id>` | Recall session context |
| `/compact` | Manually compact conversation |
| `/accept [mode]` | Set permission mode |
| `/debug` | Toggle debug mode (shows API payloads) |
| `/clear` | Clear conversation |
| `/version` | Show version info |
| `/help` | Show all commands |
| `/quit` | Exit |

## Configuration

All settings are in `config.sh`:

### Models

```bash
MODEL_NAMES="qwen2.5 qwen3"
DEFAULT_MODEL="qwen2.5"
```

Each model has per-model context size and GPU layer settings. Switch at runtime with `/model qwen3`.

### Inference

| Variable | Default | Description |
|---|---|---|
| `CONTEXT_SIZE` | `32768` | Token context window |
| `GPU_LAYERS` | `99` | Layers on GPU (99 = all) |
| `THREADS` | `10` | CPU threads for inference |
| `TEMPERATURE` | `0.2` | Generation temperature |
| `MAX_TOKENS` | `4096` | Max response tokens |
| `FREQUENCY_PENALTY` | `0.3` | Penalize repeated tokens |
| `PRESENCE_PENALTY` | `0.2` | Encourage topic diversity |

### Agent

| Variable | Default | Description |
|---|---|---|
| `AUTO_CONFIRM_READ` | `true` | Skip confirmation for read-only tools |
| `MAX_TOOL_LOOPS` | `50` | Max tool calls per turn |
| `ACCEPT_MODE` | `confirm` | Permission mode |
| `AUTO_COMPRESS_THRESHOLD` | `80` | Auto-compress outputs exceeding N lines |

### Embedding

| Variable | Default | Description |
|---|---|---|
| `EMBEDDING_PORT` | `8081` | Embedding server port |
| `EMBEDDING_MODEL_PATH` | *(auto)* | Path to embedding model GGUF |
| `EMBEDDING_MODEL_NAME` | `nomic-embed-text` | Embedding model identifier |

### Proxy

| Variable | Default | Description |
|---|---|---|
| `USE_PROXY` | `false` | Route through lana-proxy (env: `LANA_USE_PROXY`) |
| `PROXY_HOST` | `127.0.0.1` | Proxy address |
| `PROXY_PORT` | `5304` | Proxy port |
| `API_MODEL` | *(auto)* | Model name sent in API requests (env: `LANA_API_MODEL`) |

## Architecture

```
bin/
  lana-code               Entry point (launches Ink TUI or bash REPL)
  lana-code-ink            Ink TUI entry point
src/
  index.tsx                Ink app bootstrap
  app.tsx                  Main app component (REPL, commands, tool loop)
  api/                     LLM API communication
  ast/                     Tree-sitter code analysis
    parser.ts              WASM-based tree-sitter parser (lazy grammar loading)
    languages.ts           Language registry (10 languages, queries)
    symbols.ts             Symbol extraction (functions, classes, types)
    imports.ts             Import/export extraction with path resolution
    graph.ts               Dependency graph builder (forward + reverse edges)
    indexer.ts             Orchestrator (scan → parse → extract → graph)
    chunker.ts             AST-aware code chunking for embeddings
    types.ts               Shared types (SymbolDef, ImportDef, etc.)
  embedding/               Vector embedding pipeline
    provider.ts            EmbeddingProvider interface + LlamaEmbeddingProvider
    model-manager.ts       Dual-load vs swap logic, server lifecycle
    vector-store.ts        SQLite schema, cosine similarity, CRUD
    chunker.ts             Embedding-specific chunking
    indexer.ts             Embedding orchestrator (chunk → embed → store)
    search.ts              Hybrid search (regex + vector + RRF merge)
  components/              React Ink UI components
    Banner.tsx             Startup banner
    CommandPicker.tsx       Interactive `/` command menu
    Confirmation.tsx        Tool approval prompts
    DiffViewer.tsx          Color-coded file diffs
    FilePicker.tsx          File selection
    MarkdownRenderer.tsx    Streaming markdown display
    Prompt.tsx              User input with history
    Spinner.tsx             Thinking animation
    StatusBar.tsx           Model/context/progress display
    StreamingOutput.tsx     Real-time LLM output
    ToolCall.tsx            Tool call display
  hooks/                   React hooks
  prompts/                 System prompt templates
  state/                   State management
    config.ts              LanaConfig type + loading
  tools/                   Tool definitions
    executor.ts            Tool execution engine
  utils/                   Shared utilities
config.sh                  All configuration
setup.sh                   Server lifecycle (start/stop/switch)
lib/
  api.sh                   API communication + SSE streaming (Perl)
  state.sh                 Conversation state management
  ui.sh                    Terminal UI (colors, prompts, spinners)
  tools.sh                 Core tool definitions + execution
  tools_awareness.sh       Search/discovery tools
  tools_execution.sh       Shell execution tools
  tools_intelligence.sh    Summarization tools
  tools_fileops.sh         File operation tools
  project.sh               Legacy bash indexing (superseded by tree-sitter)
  history.sh               Session history + conversation compaction
```

### Key Design Decisions

- **React Ink TUI** — Full React component model for terminal UI. Enables streaming markdown, interactive pickers, diff viewers, and status bars.
- **Tree-sitter (WASM)** — AST-based code analysis via `web-tree-sitter`. Accurate symbol extraction, import resolution, and dependency graphing across 10 languages. No native bindings — runs everywhere Node runs.
- **SQLite vector store** — Embeddings stored as raw binary BLOBs in per-project `.lana/index.db`. Brute-force cosine similarity is fast enough for project-scale (~50ms for 8K chunks).
- **Hybrid search** — Regex matching (paths, symbols, summaries) merged with vector similarity via Reciprocal Rank Fusion. Gets both exact and semantic matches.
- **Bash compatibility layer** — Core tool execution still uses battle-tested bash scripts. The Ink TUI spawns bash processes for tool calls, with headless-mode stubs for UI functions.
- **Embedded Perl for SSE** — Streaming requires stateful line-by-line parsing with non-blocking I/O. Perl handles this inside the bash pipeline without external dependencies.
- **Tool call fallbacks** — Handles structured tool_calls, text-based `<tool_call>` tags, and shell code block extraction. Local models aren't always consistent.

## Requirements

- macOS (tested on Apple Silicon M4 Pro)
- **Node.js 18+** — For the Ink TUI and tree-sitter analysis
- llama.cpp built with Metal support (or lana-proxy)
- `jq` — JSON processing
- `curl` — HTTP requests
- `perl` — SSE streaming parser (pre-installed on macOS)

## The LANA Suite

LANA CODE is part of the broader LANA ecosystem:

| Tool | Description |
|---|---|
| **lana-code** | Agentic coding CLI (this project) |
| **[lana-proxy](https://github.com/redroostertech/lana-proxy)** | Anthropic-to-OpenAI API translation proxy |

## License

MIT License.

# Contributing to LANA CODE

Thanks for your interest in contributing! LANA CODE is a fully local agentic coding CLI, and we welcome contributions of all kinds — bug fixes, new tools, UI improvements, documentation, and more.

## Getting Started

1. **Fork and clone** the repo:

   ```bash
   git clone https://github.com/<your-username>/lana-code.git
   cd lana-code
   ```

2. **Install dependencies:**

   ```bash
   bash install.sh
   ```

   This builds llama.cpp, downloads default models, and installs Node.js dependencies.

3. **Run in development mode:**

   ```bash
   npm run dev
   ```

   Or use the bash REPL directly:

   ```bash
   bash lana-coder.sh
   ```

4. **Run tests:**

   ```bash
   bash tests/integration_test.sh
   ```

## Project Structure

- `src/` — TypeScript + React Ink TUI (components, tools, AST indexing, embedding)
- `lib/` — Bash scripts (tool execution, API calls, UI, state management)
- `bin/` — Entry point scripts
- `config.sh` — All configuration variables
- `knowledge/` — Scaffold templates for project creation
- `tests/` — Integration tests

See the [Architecture section](README.md#architecture) in the README for a detailed file-by-file breakdown.

## How to Contribute

### Reporting Bugs

Open an issue with:

- What you expected to happen
- What actually happened
- Steps to reproduce
- Your environment (macOS version, chip, Node version, model being used)

### Suggesting Features

Open an issue describing the feature, why it's useful, and how it might work. We're especially interested in:

- New tools for the agentic loop
- Tree-sitter grammar support for additional languages
- UI/UX improvements to the Ink TUI
- Better model compatibility and prompt handling

### Submitting Pull Requests

1. Create a feature branch from `development`:

   ```bash
   git checkout development
   git pull origin development
   git checkout -b feature/your-feature-name
   ```

2. Make your changes — keep commits focused and atomic.

3. Test your changes:

   ```bash
   bash tests/integration_test.sh
   ```

4. Push and open a PR against `development`:

   ```bash
   git push origin feature/your-feature-name
   ```

### Code Style

- **TypeScript/TSX** — Follow the existing patterns in `src/`. We use React Ink components for the TUI.
- **Bash** — Use `set -uo pipefail`. Quote variables. Use `local` for function variables.
- Keep changes minimal and focused — don't refactor unrelated code in the same PR.
- No unnecessary dependencies — LANA CODE is designed to run with minimal external requirements.

### Commit Messages

Write clear, concise commit messages:

```
Add vector search support for Ruby files

Extend the tree-sitter indexer to parse Ruby ASTs and extract
symbols for the embedding pipeline.
```

## Areas Where Help is Welcome

- **Language support** — Adding tree-sitter grammars and symbol queries for new languages
- **Tool development** — New tools for the agentic loop (see `lib/tools.sh` and `src/tools/`)
- **Testing** — Expanding integration test coverage
- **Documentation** — Improving guides, examples, and inline docs
- **Platform support** — Linux compatibility testing and fixes

## Development Tips

- The Ink TUI (`src/`) and bash backend (`lib/`) are loosely coupled — the TUI spawns bash processes for tool execution
- `config.sh` is the single source of truth for all settings
- Debug mode (`/debug` in the REPL) shows raw API payloads — helpful when working on prompt or tool-call handling
- The project uses `.lana/` directories per-project for index data — check there when debugging indexing issues

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).

# Installation Guide

## System Requirements

| Requirement | Minimum | Recommended |
|---|---|---|
| OS | macOS 13+ | macOS 14+ (Sonoma/Tahoe) |
| Architecture | Intel (x86_64) | Apple Silicon (M1/M2/M3/M4) |
| RAM | 16 GB | 24 GB+ |
| Disk | 15 GB free | 30 GB+ free |
| Node.js | 18+ | 22+ (LTS) |
| Shell | bash 3.2+ | zsh (macOS default) |

### Required Tools

These must be available before installation:

| Tool | How to get it |
|---|---|
| `git` | `xcode-select --install` |
| `node` / `npm` | [nodejs.org](https://nodejs.org) or `brew install node` |
| `curl` | Pre-installed on macOS |
| `jq` | `curl -sL https://github.com/jqlang/jq/releases/latest/download/jq-macos-arm64 -o ~/bin/jq && chmod +x ~/bin/jq` |
| `clang++` | `xcode-select --install` |
| `make` | `xcode-select --install` |
| `perl` | Pre-installed on macOS |

`cmake` is downloaded automatically by the installer if not present.

## Quick Install

```bash
git clone <repo-url> ~/Desktop/local-coder
cd ~/Desktop/local-coder
bash install.sh
npm install
source ~/.zshrc
lana-code
```

That's it. The installer handles llama.cpp, model downloads, and PATH setup. `npm install` pulls in the Node dependencies (React Ink, tree-sitter grammars, SQLite).

## Install Options

```bash
# Default: install everything with Qwen2.5-Coder-14B
bash install.sh

# Choose a different model
bash install.sh --model qwen3        # Qwen3-Coder-30B-A3B (18.6 GB)
bash install.sh --model all          # Both models

# Build llama.cpp without downloading models
bash install.sh --skip-models
```

## What the Installer Does

### Step 1: System Requirements Check

Verifies macOS, architecture, RAM, and required tools. Warns if RAM is below 16 GB.

### Step 2: cmake

Downloads cmake 3.31.6 to `~/local-tools/bin/` if not already installed. Skips if cmake is found in PATH.

### Step 3: Build llama.cpp

- Clones `https://github.com/ggml-org/llama.cpp` to `~/llama.cpp/`
- Builds with Metal GPU acceleration (`-DGGML_METAL=on`)
- Uses all CPU cores for compilation
- Produces `~/llama.cpp/build/bin/llama-server`
- Skips if already built

### Step 4: Download Model(s)

Downloads to `~/llama.cpp/models/`:

| Model | Size | Best for |
|---|---|---|
| Qwen2.5-Coder-14B-Instruct Q5_K_M | 10.5 GB | Fast coding tasks, 24GB machines |
| Qwen3-Coder-30B-A3B-Instruct Q4_K_M | 18.6 GB | Higher quality, MoE architecture |
| nomic-embed-text-v1.5 Q8_0 | ~270 MB | Embedding model for vector search |

Downloads resume if interrupted (uses `curl -C -`). Skips if the file already exists.

### Step 5: Install Node Dependencies

```bash
npm install
```

This installs:
- **React Ink** — Terminal UI framework
- **web-tree-sitter** — WASM-based AST parser
- **Tree-sitter grammars** — Language-specific WASM files for 10 languages (TypeScript, JavaScript, Python, Rust, Go, C, C++, Java, Ruby, TSX)
- **better-sqlite3** — Native SQLite bindings for the vector store
- **diff** — For rendering file edit diffs

### Step 6: Install CLI

- Makes all scripts executable
- Creates `~/bin/lana-code` symlink
- Adds `~/bin` to PATH in your shell config (`~/.zshrc` or `~/.bashrc`)

## Directory Layout After Install

```
~/llama.cpp/                    llama.cpp source + build
  build/bin/llama-server        The inference server binary
  models/
    Qwen2.5-Coder-14B-*.gguf   Default coding model
    nomic-embed-text-*.gguf     Embedding model (for vector search)
~/Desktop/local-coder/          LANA CODE source
  bin/lana-code                 Entry point
  bin/lana-code-ink             Ink TUI entry point
  src/                          TypeScript source
    app.tsx                     Main app component
    ast/                        Tree-sitter analysis pipeline
    embedding/                  Vector embedding pipeline
    components/                 React Ink UI components
  config.sh                     Configuration
  package.json                  Node dependencies
  ...
~/bin/
  lana-code -> ~/Desktop/local-coder/bin/lana-code
```

## Post-Install Verification

```bash
# Reload shell
source ~/.zshrc

# Check the command works
lana-code --help

# Build TypeScript (if running from source)
npm run build

# Start a session
lana-code
```

On first run, LANA will:
1. Start the llama.cpp server (takes 10-60 seconds for model loading)
2. Show the LANA banner
3. Present the input prompt

## Proxy Mode Setup (Optional)

To use lana-proxy for advanced routing, caching, and analytics:

```bash
# 1. Install lana-proxy (see lana-proxy docs)
cd ~/Desktop/lana-proxy
bash install.sh

# 2. Start the proxy stack
./start.sh

# 3. Run LANA in proxy mode
LANA_USE_PROXY=true lana-code
```

Or set it permanently:

```bash
echo 'export LANA_USE_PROXY=true' >> ~/.zshrc
source ~/.zshrc
lana-code
```

## Updating

### Update LANA CODE

```bash
cd ~/Desktop/local-coder
git pull
npm install    # In case dependencies changed
npm run build  # Rebuild TypeScript
```

### Update llama.cpp

```bash
cd ~/llama.cpp
git pull
cmake --build build --config Release -j$(sysctl -n hw.ncpu)
```

### Download a New Model

Place any GGUF file in `~/llama.cpp/models/` and add its config to `config.sh`.

## Uninstall

```bash
# Remove symlink
rm ~/bin/lana-code

# Remove LANA source
rm -rf ~/Desktop/local-coder

# Remove llama.cpp (optional — shared with lana-proxy)
rm -rf ~/llama.cpp

# Remove session data
rm -rf ~/.lana
```

## Troubleshooting

### "jq not found"

```bash
curl -sL https://github.com/jqlang/jq/releases/latest/download/jq-macos-arm64 -o ~/bin/jq
chmod +x ~/bin/jq
```

### "llama-server not found"

The build may have failed. Check build logs:

```bash
cd ~/llama.cpp
cmake -B build -DGGML_METAL=on
cmake --build build --config Release -j$(sysctl -n hw.ncpu)
```

### npm install fails on better-sqlite3

`better-sqlite3` requires a C++ compiler. Ensure Xcode CLT is installed:

```bash
xcode-select --install
```

### Tree-sitter WASM files not found

Run `npm install` — the grammar packages include pre-built `.wasm` files:

```bash
cd ~/Desktop/local-coder
npm install
```

### Server takes too long to start

Large models (18GB+) can take 30-60 seconds to load into GPU memory. The installer uses a 10-minute timeout. If loading stalls:

```bash
# Check server log
cat /tmp/lana-$$/llama-server.log

# Try with fewer GPU layers
# Edit config.sh: MODEL_NGL_qwen3=50
```

### "Metal not available"

Ensure you're on Apple Silicon and have Xcode CLT installed:

```bash
xcode-select --install
```

### Model download interrupted

Re-run the install — downloads resume from where they left off:

```bash
bash install.sh
```

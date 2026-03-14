#!/usr/bin/env bash
# ╦  ╔═╗ ╔╗╔ ╔═╗  ╔═╗ ╔═╗ ╔╦╗ ╔═╗ ╦═╗
# ║  ╠═╣ ║║║ ╠═╣  ║   ║ ║  ║║ ║╣  ╠╦╝
# ╩═╝╩ ╩ ╝╚╝ ╩ ╩  ╚═╝ ╚═╝ ═╩╝ ╚═╝ ╩╚═
# Locally Autonomous Neural Agent — Installer
#
# Usage: ./install.sh [--skip-models] [--model qwen2.5|qwen3|all]
#
# This script:
#   1. Checks system requirements
#   2. Downloads cmake if needed
#   3. Clones and builds llama.cpp with Metal GPU acceleration
#   4. Downloads coding model(s)
#   5. Installs the `lana-code` command to your PATH

set -euo pipefail

# ── Config ────────────────────────────────────────────
LANA_VERSION="0.2.0"
INSTALL_DIR="$(cd "$(dirname "$0")" && pwd)"
LLAMA_CPP_DIR="$HOME/llama.cpp"
MODELS_DIR="$LLAMA_CPP_DIR/models"
CMAKE_VERSION="3.31.6"
BIN_DIR="$HOME/bin"

# Model URLs
MODEL_QWEN25_URL="https://huggingface.co/bartowski/Qwen2.5-Coder-14B-Instruct-GGUF/resolve/main/Qwen2.5-Coder-14B-Instruct-Q5_K_M.gguf"
MODEL_QWEN25_FILE="Qwen2.5-Coder-14B-Instruct-Q5_K_M.gguf"
MODEL_QWEN25_SIZE="10.5 GB"

MODEL_QWEN3_URL="https://huggingface.co/unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF/resolve/main/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"
MODEL_QWEN3_FILE="Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"
MODEL_QWEN3_SIZE="18.6 GB"

MODEL_EMBED_URL="https://huggingface.co/nomic-ai/nomic-embed-text-v1.5-GGUF/resolve/main/nomic-embed-text-v1.5.Q8_0.gguf"
MODEL_EMBED_FILE="nomic-embed-text-v1.5.Q8_0.gguf"
MODEL_EMBED_SIZE="0.27 GB"

# ── Colors ────────────────────────────────────────────
R='\033[0m'
B='\033[1m'
DIM='\033[2m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'

# ── Parse args ────────────────────────────────────────
SKIP_MODELS=false
MODEL_CHOICE="qwen2.5"  # default: just the 14B model

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-models) SKIP_MODELS=true; shift ;;
        --model)       shift; MODEL_CHOICE="${1:-qwen2.5}"; shift ;;
        --help|-h)
            echo "Usage: ./install.sh [--skip-models] [--model qwen2.5|qwen3|all]"
            echo ""
            echo "Options:"
            echo "  --skip-models       Skip model downloads (build llama.cpp only)"
            echo "  --model <name>      Choose model: qwen2.5 (default), qwen3, or all"
            echo "  --help              Show this help"
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ── Helpers ───────────────────────────────────────────
step() {
    printf "\n${B}${CYAN}[$1/$TOTAL_STEPS]${R} ${B}%s${R}\n" "$2"
}

ok() {
    printf "  ${GREEN}✓${R} %s\n" "$1"
}

warn() {
    printf "  ${YELLOW}!${R} %s\n" "$1"
}

fail() {
    printf "  ${RED}✗ %s${R}\n" "$1" >&2
    exit 1
}

info() {
    printf "  ${DIM}%s${R}\n" "$1"
}

# ── Count steps ───────────────────────────────────────
TOTAL_STEPS=5
$SKIP_MODELS && TOTAL_STEPS=4

# ── Banner ────────────────────────────────────────────
printf "\n"
printf "${B}${MAGENTA}  ╦  ╔═╗ ╔╗╔ ╔═╗${R}  ${B}${CYAN}╔═╗ ╔═╗ ╔╦╗ ╔═╗ ╦═╗${R}\n"
printf "${B}${MAGENTA}  ║  ╠═╣ ║║║ ╠═╣${R}  ${B}${CYAN}║   ║ ║  ║║ ║╣  ╠╦╝${R}\n"
printf "${B}${MAGENTA}  ╩═╝╩ ╩ ╝╚╝ ╩ ╩${R}  ${B}${CYAN}╚═╝ ╚═╝ ═╩╝ ╚═╝ ╩╚═${R}\n"
printf "${DIM}  Locally Autonomous Neural Agent — Installer v${LANA_VERSION}${R}\n\n"

# ══════════════════════════════════════════════════════
# Step 1: Check system requirements
# ══════════════════════════════════════════════════════
step 1 "Checking system requirements"

# OS check
if [[ "$(uname)" != "Darwin" ]]; then
    fail "macOS required (detected: $(uname))"
fi
ok "macOS detected"

# Architecture check
ARCH="$(uname -m)"
if [[ "$ARCH" != "arm64" ]]; then
    warn "Apple Silicon recommended (detected: $ARCH). Metal acceleration may not work."
else
    ok "Apple Silicon (arm64)"
fi

# Memory check
MEM_BYTES=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
MEM_GB=$(( MEM_BYTES / 1073741824 ))
if (( MEM_GB < 16 )); then
    warn "Only ${MEM_GB}GB RAM detected. 16GB+ recommended for coding models."
else
    ok "${MEM_GB}GB RAM"
fi

# Required tools
for tool in git curl jq; do
    if command -v "$tool" >/dev/null 2>&1; then
        ok "$tool found ($(command -v "$tool"))"
    else
        fail "$tool is required but not found. Install it and try again."
    fi
done

# C++ compiler
if command -v clang++ >/dev/null 2>&1; then
    ok "clang++ found"
elif command -v g++ >/dev/null 2>&1; then
    ok "g++ found"
else
    fail "C++ compiler required. Install Xcode Command Line Tools: xcode-select --install"
fi

# make
if command -v make >/dev/null 2>&1; then
    ok "make found"
else
    fail "make required. Install Xcode Command Line Tools: xcode-select --install"
fi

# ══════════════════════════════════════════════════════
# Step 2: Install cmake (if needed)
# ══════════════════════════════════════════════════════
step 2 "Setting up cmake"

CMAKE_BIN=""
if command -v cmake >/dev/null 2>&1; then
    CMAKE_BIN="$(command -v cmake)"
    ok "cmake already installed ($CMAKE_BIN)"
elif [[ -x "$HOME/local-tools/bin/cmake" ]]; then
    CMAKE_BIN="$HOME/local-tools/bin/cmake"
    ok "cmake found at $CMAKE_BIN"
else
    info "Downloading cmake ${CMAKE_VERSION}..."
    mkdir -p "$HOME/local-tools/bin"
    TMP_CMAKE="/tmp/lana-cmake-$$.tar.gz"
    curl -sL "https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/cmake-${CMAKE_VERSION}-macos-universal.tar.gz" \
        -o "$TMP_CMAKE"
    tar -xzf "$TMP_CMAKE" -C /tmp/
    cp "/tmp/cmake-${CMAKE_VERSION}-macos-universal/CMake.app/Contents/bin/cmake" "$HOME/local-tools/bin/"
    cp -r "/tmp/cmake-${CMAKE_VERSION}-macos-universal/CMake.app/Contents/share" "$HOME/local-tools/"
    rm -rf "$TMP_CMAKE" "/tmp/cmake-${CMAKE_VERSION}-macos-universal"
    CMAKE_BIN="$HOME/local-tools/bin/cmake"
    ok "cmake ${CMAKE_VERSION} installed to $CMAKE_BIN"
fi

# ══════════════════════════════════════════════════════
# Step 3: Build llama.cpp
# ══════════════════════════════════════════════════════
step 3 "Building llama.cpp with Metal acceleration"

LLAMA_SERVER="$LLAMA_CPP_DIR/build/bin/llama-server"

if [[ -x "$LLAMA_SERVER" ]]; then
    ok "llama-server already built ($LLAMA_SERVER)"
else
    if [[ ! -d "$LLAMA_CPP_DIR" ]]; then
        info "Cloning llama.cpp..."
        git clone --depth 1 https://github.com/ggml-org/llama.cpp.git "$LLAMA_CPP_DIR" 2>&1 | tail -1
    fi

    info "Configuring with Metal GPU support..."
    (cd "$LLAMA_CPP_DIR" && "$CMAKE_BIN" -B build -DGGML_METAL=on 2>&1 | tail -3)

    info "Compiling (this may take a few minutes)..."
    NPROC=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
    (cd "$LLAMA_CPP_DIR" && "$CMAKE_BIN" --build build --config Release -j "$NPROC" 2>&1 | tail -3)

    if [[ -x "$LLAMA_SERVER" ]]; then
        ok "llama-server built successfully"
    else
        fail "Build failed. Check $LLAMA_CPP_DIR/build for errors."
    fi
fi

mkdir -p "$MODELS_DIR"

# ══════════════════════════════════════════════════════
# Step 4: Download models
# ══════════════════════════════════════════════════════
CURRENT_STEP=4
if ! $SKIP_MODELS; then
    step $CURRENT_STEP "Downloading model(s)"

    download_model() {
        local name="$1" url="$2" file="$3" size="$4"
        local dest="$MODELS_DIR/$file"

        if [[ -f "$dest" ]]; then
            local actual_size
            actual_size=$(ls -lh "$dest" | awk '{print $5}')
            ok "$name already downloaded ($actual_size)"
            return 0
        fi

        info "Downloading $name ($size)..."
        info "This may take a while depending on your connection."
        curl -L -C - --progress-bar "$url" -o "$dest"

        if [[ -f "$dest" ]]; then
            local actual_size
            actual_size=$(ls -lh "$dest" | awk '{print $5}')
            ok "$name downloaded ($actual_size)"
        else
            warn "Failed to download $name"
        fi
    }

    case "$MODEL_CHOICE" in
        qwen2.5)
            download_model "Qwen2.5-Coder-14B" "$MODEL_QWEN25_URL" "$MODEL_QWEN25_FILE" "$MODEL_QWEN25_SIZE"
            ;;
        qwen3)
            download_model "Qwen3-Coder-30B-A3B" "$MODEL_QWEN3_URL" "$MODEL_QWEN3_FILE" "$MODEL_QWEN3_SIZE"
            ;;
        all)
            download_model "Qwen2.5-Coder-14B" "$MODEL_QWEN25_URL" "$MODEL_QWEN25_FILE" "$MODEL_QWEN25_SIZE"
            download_model "Qwen3-Coder-30B-A3B" "$MODEL_QWEN3_URL" "$MODEL_QWEN3_FILE" "$MODEL_QWEN3_SIZE"
            ;;
        *)
            warn "Unknown model: $MODEL_CHOICE. Skipping download."
            ;;
    esac

    # Always download embedding model (tiny — 270MB)
    download_model "nomic-embed-text (embedding)" "$MODEL_EMBED_URL" "$MODEL_EMBED_FILE" "$MODEL_EMBED_SIZE"

    CURRENT_STEP=5
fi

# ══════════════════════════════════════════════════════
# Step 5: Install CLI
# ══════════════════════════════════════════════════════
step $CURRENT_STEP "Installing lana-code CLI"

# Make scripts executable
chmod +x "$INSTALL_DIR/lana-coder.sh"
chmod +x "$INSTALL_DIR/bin/lana-code"
chmod +x "$INSTALL_DIR/setup.sh"
chmod +x "$INSTALL_DIR"/lib/*.sh

# Create ~/bin and symlink
mkdir -p "$BIN_DIR"
ln -sf "$INSTALL_DIR/bin/lana-code" "$BIN_DIR/lana-code"
ok "Symlinked lana-code -> $BIN_DIR/lana-code"

# Check if ~/bin is in PATH
SHELL_RC=""
case "$SHELL" in
    */zsh)  SHELL_RC="$HOME/.zshrc" ;;
    */bash) SHELL_RC="$HOME/.bashrc" ;;
    *)      SHELL_RC="$HOME/.profile" ;;
esac

if echo "$PATH" | tr ':' '\n' | grep -qx "$BIN_DIR"; then
    ok "$BIN_DIR already in PATH"
else
    # Check if it's already in the rc file but not in current session
    if grep -q "export PATH.*\$HOME/bin" "$SHELL_RC" 2>/dev/null; then
        ok "PATH entry already in $SHELL_RC (reload your shell)"
    else
        echo '' >> "$SHELL_RC"
        echo '# LANA CODE' >> "$SHELL_RC"
        echo 'export PATH="$HOME/bin:$PATH"' >> "$SHELL_RC"
        ok "Added $BIN_DIR to PATH in $SHELL_RC"
    fi
fi

# ══════════════════════════════════════════════════════
# Node.js dependencies (Ink TUI)
# ══════════════════════════════════════════════════════
printf "\n${B}${CYAN}  Node.js TUI dependencies${R}\n"

# Check for node
if command -v node >/dev/null 2>&1; then
    NODE_VER="$(node -v)"
    ok "Node.js found ($NODE_VER)"
else
    fail "Node.js is required but not found. Install it: https://nodejs.org or brew install node"
fi

# Install npm dependencies (always run to pick up new deps)
info "Installing npm dependencies..."
(cd "$INSTALL_DIR" && npm install --silent 2>&1 | tail -3)
if [[ -d "$INSTALL_DIR/node_modules" ]]; then
    ok "npm dependencies installed"
else
    fail "npm install failed. Run manually: cd $INSTALL_DIR && npm install"
fi

# ══════════════════════════════════════════════════════
# Done
# ══════════════════════════════════════════════════════
printf "\n"
printf "${B}${GREEN}  Installation complete!${R}\n\n"
printf "  ${DIM}To get started:${R}\n"
printf "    ${CYAN}source %s${R}          ${DIM}# reload PATH (one time)${R}\n" "$SHELL_RC"
printf "    ${CYAN}lana-code${R}                    ${DIM}# start coding${R}\n"
printf "    ${CYAN}lana-code --help${R}             ${DIM}# see all options${R}\n"
printf "    ${CYAN}lana-code ~/my-project${R}       ${DIM}# open a project${R}\n"
printf "\n"
printf "  ${DIM}Or run directly:${R}\n"
printf "    ${CYAN}%s/bin/lana-code${R}\n" "$INSTALL_DIR"
printf "\n"

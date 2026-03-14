#!/usr/bin/env bash
# lana-coder configuration
# Compatible with bash 3.2+ (macOS default)

# ── Paths ──────────────────────────────────────────────
LLAMA_CPP_DIR="$HOME/llama.cpp"
LLAMA_SERVER="$LLAMA_CPP_DIR/build/bin/llama-server"
MODELS_DIR="$LLAMA_CPP_DIR/models"

# ── Models (bash 3.2 compatible — no associative arrays) ──
MODEL_NAMES="qwen2.5 qwen3"
MODEL_PATH_qwen25="$MODELS_DIR/Qwen2.5-Coder-14B-Instruct-Q5_K_M.gguf"
MODEL_PATH_qwen3="$MODELS_DIR/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"
MODEL_CTX_qwen25=32768    # 14B Q5_K_M: ~10GB model
MODEL_CTX_qwen3=32768     # 30B-A3B MoE Q4_K_M: ~18GB model, A3B activated
MODEL_NGL_qwen25=99       # all layers on GPU
MODEL_NGL_qwen3=99        # all layers on GPU
DEFAULT_MODEL="qwen2.5"

# ── Embedding Model ──────────────────────────────────
EMBEDDING_MODEL_PATH="$MODELS_DIR/nomic-embed-text-v1.5.Q8_0.gguf"
EMBEDDING_MODEL_NAME="nomic-embed-text"
EMBEDDING_PORT=8081

# Lookup function: model name -> file path
get_model_path() {
    local name="$1"
    case "$name" in
        qwen2.5) echo "$MODEL_PATH_qwen25" ;;
        qwen3)   echo "$MODEL_PATH_qwen3" ;;
        *)       echo "" ;;
    esac
}

# Lookup function: model name -> context size
get_model_ctx() {
    local name="$1"
    case "$name" in
        qwen2.5) echo "$MODEL_CTX_qwen25" ;;
        qwen3)   echo "$MODEL_CTX_qwen3" ;;
        *)       echo "$CONTEXT_SIZE" ;;
    esac
}

# Lookup function: model name -> GPU layers
get_model_ngl() {
    local name="$1"
    case "$name" in
        qwen2.5) echo "$MODEL_NGL_qwen25" ;;
        qwen3)   echo "$MODEL_NGL_qwen3" ;;
        *)       echo "$GPU_LAYERS" ;;
    esac
}

# ── Proxy Mode ────────────────────────────────────────
# When USE_PROXY=true, lana-coder routes through lana-proxy instead of
# talking directly to llama-server. The proxy handles model routing,
# caching, queuing, and analytics. Server lifecycle is managed externally.
USE_PROXY="${LANA_USE_PROXY:-false}"
PROXY_HOST="127.0.0.1"
PROXY_PORT=5304

# ── Server (direct mode) ─────────────────────────────
SERVER_HOST="127.0.0.1"
SERVER_PORT=8080

# ── API endpoint (auto-selected based on proxy mode) ──
if [[ "$USE_PROXY" == "true" ]]; then
    API_URL="http://${PROXY_HOST}:${PROXY_PORT}"
    API_MODEL="${LANA_API_MODEL:-$DEFAULT_MODEL}"
else
    API_URL="http://${SERVER_HOST}:${SERVER_PORT}"
    API_MODEL="${LANA_API_MODEL:-local-model}"
fi
export LANA_API_MODEL="$API_MODEL"

# ── Inference ──────────────────────────────────────────
CONTEXT_SIZE=32768
GPU_LAYERS=99
THREADS=10
# KV cache quantization — disabled for now. Single-user on M4 Pro unified
# memory means the full f16 cache isn't wasteful, and f16 preserves maximum
# attention quality. Re-enable if memory pressure becomes an issue or if
# running larger context windows (64K+).
#KV_CACHE_TYPE_K="q8_0"       # q8_0 = ~half KV VRAM, negligible quality loss
#KV_CACHE_TYPE_V="q4_0"       # q4_0 = aggressive; keys matter more than values
TEMPERATURE=0.2
MAX_TOKENS=32768
FREQUENCY_PENALTY=0.3      # penalize repeated tokens (prevents repetition loops)
PRESENCE_PENALTY=0.2       # encourage topic diversity

# ── Agent ──────────────────────────────────────────────
AUTO_CONFIRM_READ=true     # skip confirmation for read-only tools
MAX_TOOL_LOOPS=50          # max tool calls per turn before pause-and-ask
ACCEPT_MODE="${LANA_ACCEPT:-confirm}"   # confirm | auto-edit | yolo
FILE_SIZE_LIMIT=50000      # max bytes to read from a file (chars)

# ── Subagents ─────────────────────────────────────────
SUBAGENT_MAX_LOOPS=30              # max iterations before forced summary
SUBAGENT_CHECKPOINT_INTERVAL=8     # ask user every N tool calls
SUBAGENT_CONTEXT_BUDGET_PCT=70     # stop when subagent context hits this %
SUBAGENT_RESULT_TRUNCATE=4000      # truncate individual tool results (chars)
SUBAGENT_SUMMARY_TRUNCATE=8000     # truncate final summary to main agent (chars)

# ── Indexer ─────────────────────────────────────────────
INDEX_WORKERS=4                # parallel workers for indexing
INDEX_MAX_FILE_SIZE=100000     # skip files larger than 100KB for indexing
INDEX_MAX_FILES=2000           # max files to index
INDEX_SUMMARY_MAX_INPUT=2000   # max chars of code/docs sent to LLM per file
INDEX_DIR_NAME=".lana"  # hidden dir inside project for index data

# ── History & Compaction ──────────────────────────────
LANA_HISTORY_DIR="${LANA_HISTORY_DIR:-$HOME/.lana/history}"
COMPACT_TRIGGER_PCT=60             # compact when context usage exceeds this %
COMPACT_KEEP_TURNS=4               # keep last N turn-pairs hot
COMPACT_EMERGENCY_PCT=80           # hard fallback: aggressive trim
COMPACT_SUMMARY_MAX_TOKENS=400     # max tokens for compaction summary
COMPACT_TEMPERATURE=0.1            # low temp for deterministic summaries

# ── Tool Result Compression ──────────────────────────
TOOL_RESULT_MAX_LINES=30           # compress tool results beyond this
TOOL_RESULT_KEEP_HEAD=10           # keep first N lines
TOOL_RESULT_KEEP_TAIL=5            # keep last N lines
COLD_STORAGE_ENABLED=true          # archive full results to disk

# ── Input History (readline) ─────────────────────────
LANA_INPUT_HISTORY="$HOME/.lana/input_history"
LANA_INPUT_HISTORY_SIZE=500        # max lines to keep

# ── Debug ─────────────────────────────────────────────
LANA_DEBUG=${LANA_DEBUG:-false}     # set to true or 1 to show API payloads

# ── Security ───────────────────────────────────────────
ALLOWED_EXTENSIONS='py|js|ts|tsx|jsx|rs|go|java|rb|c|cpp|h|hpp|sh|swift|kt|scala|cs|php|lua|zig|ex|exs|erl|hs|ml|vue|svelte'
EXCLUDED_DIRS='.git|node_modules|__pycache__|.venv|venv|.next|dist|build|.cache|.tox|.mypy_cache|.pytest_cache|target|vendor|deps|_build'

# ── Directories ────────────────────────────────────────
LANA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Python (prompt_toolkit input reader) ──────────────
LANA_PYTHON="$LANA_DIR/.venv/bin/python3"
if [[ ! -x "$LANA_PYTHON" ]]; then
    LANA_PYTHON="python3"  # fallback to system python
fi
LANA_INPUT_READER="$LANA_DIR/lib/input_reader.py"
SESSION_DIR="/tmp/lana-$$"

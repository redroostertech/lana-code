#!/usr/bin/env bash
# Server lifecycle management

LLAMA_SERVER_PID=""
LLAMA_SERVER_LOG="$SESSION_DIR/llama-server.log"

# ── Start llama-server ─────────────────────────────────

server_start() {
    local model_path="$1"

    if [[ ! -f "$model_path" ]]; then
        ui_error "Model not found: $model_path"
        return 1
    fi

    if [[ ! -x "$LLAMA_SERVER" ]]; then
        ui_error "llama-server not found at: $LLAMA_SERVER"
        return 1
    fi

    # Kill any existing server on our port
    server_stop 2>/dev/null

    mkdir -p "$SESSION_DIR"

    # Use per-model context size and GPU layers
    local ctx="${CONTEXT_SIZE}"
    local ngl="${GPU_LAYERS}"
    local model_ctx model_ngl
    model_ctx=$(get_model_ctx "$CURRENT_MODEL" 2>/dev/null)
    model_ngl=$(get_model_ngl "$CURRENT_MODEL" 2>/dev/null)
    [[ -n "$model_ctx" ]] && ctx="$model_ctx"
    [[ -n "$model_ngl" ]] && ngl="$model_ngl"
    CONTEXT_SIZE="$ctx"

    ui_info "Starting llama-server..."
    ui_dim "  model: $(basename "$model_path")"
    ui_dim "  context: ${ctx} tokens, gpu layers: ${ngl}"

    "$LLAMA_SERVER" \
        --model "$model_path" \
        --host "$SERVER_HOST" \
        --port "$SERVER_PORT" \
        --ctx-size "$ctx" \
        --n-gpu-layers "$ngl" \
        --threads "$THREADS" \
        --flash-attn on \
        --cache-type-k "${KV_CACHE_TYPE_K:-f16}" \
        --cache-type-v "${KV_CACHE_TYPE_V:-f16}" \
        --jinja \
        --no-webui \
        > "$LLAMA_SERVER_LOG" 2>&1 &

    LLAMA_SERVER_PID=$!
    disown "$LLAMA_SERVER_PID" 2>/dev/null

    # Wait for server to be ready
    if ! api_wait_for_server; then
        ui_error "Server failed to start. Check log: $LLAMA_SERVER_LOG"
        cat "$LLAMA_SERVER_LOG" | tail -20 >&2
        return 1
    fi

    ui_success "Server ready (PID: $LLAMA_SERVER_PID)"
    return 0
}

# ── Stop llama-server ──────────────────────────────────

server_stop() {
    if [[ -n "$LLAMA_SERVER_PID" ]]; then
        kill "$LLAMA_SERVER_PID" 2>/dev/null || true
        wait "$LLAMA_SERVER_PID" 2>/dev/null || true
        LLAMA_SERVER_PID=""
    fi

    # Also kill any orphaned server on our port
    local pid
    pid=$(lsof -ti :"$SERVER_PORT" 2>/dev/null || true)
    if [[ -n "$pid" ]]; then
        kill "$pid" 2>/dev/null || true
    fi
}

# ── Switch model ───────────────────────────────────────

server_switch_model() {
    local model_key="$1"
    local model_path
    model_path=$(get_model_path "$model_key")

    if [[ -z "$model_path" ]]; then
        ui_error "Unknown model: $model_key"
        ui_info "Available models: $MODEL_NAMES"
        return 1
    fi

    if [[ ! -f "$model_path" ]]; then
        ui_error "Model file not found: $model_path"
        return 1
    fi

    ui_info "Switching to model: $model_key"
    server_stop
    CURRENT_MODEL="$model_key"
    server_start "$model_path"
}

# ── Check dependencies ─────────────────────────────────

check_deps() {
    local missing=""

    command -v jq >/dev/null || missing="$missing jq"
    command -v curl >/dev/null || missing="$missing curl"

    # In proxy mode, llama-server and models are managed by lana-proxy
    if [[ "$USE_PROXY" != "true" ]]; then
        [[ -x "$LLAMA_SERVER" ]] || missing="$missing llama-server"
    fi

    if [[ -n "$missing" ]]; then
        ui_error "Missing dependencies:$missing"
        echo "" >&2
        for dep in $missing; do
            case "$dep" in
                jq)   echo "  Install jq: curl -sL https://github.com/jqlang/jq/releases/latest/download/jq-macos-arm64 -o /usr/local/bin/jq && chmod +x /usr/local/bin/jq" >&2 ;;
                curl) echo "  Install curl: should be built-in on macOS. Try: xcode-select --install" >&2 ;;
                llama-server) echo "  Run install.sh to build llama.cpp" >&2 ;;
            esac
        done
        return 1
    fi

    # In proxy mode, skip model file check — proxy handles backend
    if [[ "$USE_PROXY" != "true" ]]; then
        local has_model=false
        for name in $MODEL_NAMES; do
            local mp
            mp=$(get_model_path "$name")
            [[ -f "$mp" ]] && has_model=true && break
        done

        if ! $has_model; then
            ui_error "No model files found. Expected in: $MODELS_DIR"
            return 1
        fi
    fi

    return 0
}

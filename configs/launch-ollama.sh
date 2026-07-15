#!/usr/bin/env bash
# =============================================================================
# launch-ollama.sh — Ollama Server Setup and Launcher
# =============================================================================
# Usage:
#   launch-ollama.sh [--install] [--pull] [--start] [--status] [--verify] [--stop]
#
# Description:
#   Manages the Ollama local LLM server for the Agor unattended testing workflow.
#   Handles installation, model pulling (devstral:24b + deepseek-coder-v2-lite:16b),
#   server startup with MLX backend, health verification, and shutdown.
#
#   Ollama runs on the HOST (not in Docker) for direct Apple Silicon/Metal access.
#
# Hardware Requirements:
#   - macOS with Apple Silicon (M2/M3/M4)
#   - 32GB+ unified memory (both models fit in ~23GB)
#   - Fast SSD for model storage
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
PRIMARY_MODEL="${AGOR_PRIMARY_MODEL:-devstral:24b}"
FAST_MODEL="${AGOR_FAST_MODEL:-deepseek-coder-v2-lite:16b}"
OLLAMA_HOST="${AGOR_OLLAMA_HOST:-127.0.0.1}"
OLLAMA_PORT="${AGOR_OLLAMA_PORT:-11434}"
API_URL="http://${OLLAMA_HOST}:${OLLAMA_PORT}"
PIDFILE="${HOME}/.ollama/ollama.pid"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
info() { echo -e "[INFO] $*"; }

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Ollama server management for Agor unattended testing workflow.

Options:
  --install    Install Ollama (if not present)
  --pull       Pull both models (devstral:24b + deepseek-coder-v2-lite:16b)
  --start      Start Ollama server with MLX backend
  --status     Show server and model status
  --verify     Run full connectivity verification
  --stop       Stop Ollama server

Examples:
  # Full setup (install + pull + start + verify)
  $(basename "$0") --install --pull --start --verify

  # Just start (already installed and pulled)
  $(basename "$0") --start

  # Check status
  $(basename "$0") --status

Environment:
  AGOR_PRIMARY_MODEL    Primary model (default: devstral:24b)
  AGOR_FAST_MODEL       Fast model (default: deepseek-coder-v2-lite:16b)
  AGOR_OLLAMA_HOST      Bind host (default: 127.0.0.1)
  AGOR_OLLAMA_PORT      Port (default: 11434)
  OLLAMA_MLX            Enable MLX backend (set to 1)
  OLLAMA_KEEP_ALIVE     Keep models resident (default: 30m)
EOF
    exit 0
}

# ---------------------------------------------------------------------------
# Platform detection
# ---------------------------------------------------------------------------
detect_platform() {
    local os arch
    os="$(uname -s)"
    arch="$(uname -m)"

    if [[ "$os" == "Darwin" ]]; then
        if [[ "$arch" == "arm64" ]]; then
            echo "macos-arm64"
        else
            echo "macos-amd64"
        fi
    elif [[ "$os" == "Linux" ]]; then
        echo "linux-${arch}"
    else
        error "Unsupported platform: $os $arch"
    fi
}

# ---------------------------------------------------------------------------
# Check Apple Silicon
# ---------------------------------------------------------------------------
check_apple_silicon() {
    if [[ "$(uname -s)" != "Darwin" ]]; then
        warn "Not macOS — MLX backend will not be available"
        return 1
    fi
    if [[ "$(uname -m)" != "arm64" ]]; then
        warn "Not Apple Silicon — MLX backend requires ARM64"
        return 1
    fi
    log "Apple Silicon detected — MLX backend available"
    return 0
}

# ---------------------------------------------------------------------------
# Check memory
# ---------------------------------------------------------------------------
check_memory() {
    local total_gb
    if [[ "$(uname -s)" == "Darwin" ]]; then
        total_gb="$(($(sysctl -n hw.memsize) / 1024 / 1024 / 1024))"
    else
        total_gb="$(free -g | awk '/^Mem:/{print $2}')"
    fi

    log "Total memory: ${total_gb}GB"

    if [[ "$total_gb" -lt 24 ]]; then
        error "Insufficient memory: ${total_gb}GB. Minimum 24GB recommended for dual-model setup."
    elif [[ "$total_gb" -lt 32 ]]; then
        warn "Memory is tight: ${total_gb}GB. Models may need to swap. Consider running one model at a time."
    else
        log "Memory OK: ${total_gb}GB — both models can stay resident"
    fi
}

# ---------------------------------------------------------------------------
# INSTALL — Install Ollama
# ---------------------------------------------------------------------------
cmd_install() {
    log "Checking Ollama installation..."

    if command -v ollama >/dev/null 2>&1; then
        local version
        version="$(ollama --version 2>/dev/null || echo 'unknown')"
        log "Ollama already installed: $version"
        return 0
    fi

    log "Installing Ollama..."
    local platform
    platform="$(detect_platform)"

    case "$platform" in
        macos-*)
            # macOS: use official installer
            curl -fsSL https://ollama.com/install.sh | sh
            ;;
        linux-*)
            curl -fsSL https://ollama.com/install.sh | sh
            ;;
        *)
            error "Unsupported platform: $platform"
            ;;
    esac

    log "Ollama installed successfully"
}

# ---------------------------------------------------------------------------
# PULL — Download models
# ---------------------------------------------------------------------------
cmd_pull() {
    log "Pulling models..."

    # Ensure Ollama is running temporarily for pull
    local ollama_was_running=false
    if curl -s "$API_URL/api/tags" >/dev/null 2>&1; then
        ollama_was_running=true
    else
        log "Starting Ollama temporarily for model pull..."
        ollama serve &
        local ollama_pid=$!
        sleep 5
    fi

    # Wait for Ollama to be ready
    local retries=0
    while ! curl -s "$API_URL/api/tags" >/dev/null 2>&1; do
        retries=$((retries + 1))
        if [[ $retries -gt 30 ]]; then
            error "Ollama failed to start for model pull"
        fi
        sleep 1
    done

    # Pull primary model
    log "Pulling primary model: $PRIMARY_MODEL"
    ollama pull "$PRIMARY_MODEL"

    # Pull fast model
    log "Pulling fast model: $FAST_MODEL"
    ollama pull "$FAST_MODEL"

    # Stop temporary Ollama
    if [[ "$ollama_was_running" == false ]]; then
        log "Stopping temporary Ollama instance..."
        kill "$ollama_pid" 2>/dev/null || true
        wait "$ollama_pid" 2>/dev/null || true
    fi

    log "Models pulled successfully"
}

# ---------------------------------------------------------------------------
# START — Launch Ollama server
# ---------------------------------------------------------------------------
cmd_start() {
    log "Starting Ollama server..."

    # Check if already running
    if curl -s "$API_URL/api/tags" >/dev/null 2>&1; then
        warn "Ollama is already running on $API_URL"
        return 0
    fi

    # Check if PID file exists
    if [[ -f "$PIDFILE" ]]; then
        local old_pid
        old_pid="$(cat "$PIDFILE")"
        if kill -0 "$old_pid" 2>/dev/null; then
            warn "Ollama already running (PID: $old_pid)"
            return 0
        else
            rm -f "$PIDFILE"
        fi
    fi

    # Enable MLX backend on Apple Silicon
    if check_apple_silicon; then
        export OLLAMA_MLX=1
        log "MLX backend enabled for Apple Silicon"
    fi

    # Keep models resident in memory
    export OLLAMA_KEEP_ALIVE="${OLLAMA_KEEP_ALIVE:-30m}"
    export OLLAMA_MAX_LOADED_MODELS=2

    # Start Ollama in background
    log "Ollama starting on $API_URL..."
    ollama serve > "${HOME}/.ollama/server.log" 2>&1 &
    local ollama_pid=$!
    echo "$ollama_pid" > "$PIDFILE"

    # Wait for readiness
    local retries=0
    while ! curl -s "$API_URL/api/tags" >/dev/null 2>&1; do
        retries=$((retries + 1))
        if [[ $retries -gt 60 ]]; then
            error "Ollama failed to start after 60 seconds"
        fi
        if ! kill -0 "$ollama_pid" 2>/dev/null; then
            error "Ollama process exited unexpectedly"
        fi
        sleep 1
    done

    log "Ollama ready on $API_URL (PID: $ollama_pid)"
}

# ---------------------------------------------------------------------------
# STATUS — Show current state
# ---------------------------------------------------------------------------
cmd_status() {
    echo "=== Ollama Server Status ==="
    if curl -s "$API_URL/api/tags" >/dev/null 2>&1; then
        echo -e "${GREEN}● Running${NC} on $API_URL"
    else
        echo -e "${RED}● Stopped${NC}"
        return 0
    fi

    echo ""
    echo "=== Loaded Models ==="
    curl -s "$API_URL/api/tags" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    for model in data.get('models', []):
        name = model.get('name', 'unknown')
        size = model.get('size', 0)
        size_gb = size / (1024**3)
        print(f'  {name}: {size_gb:.1f}GB')
except Exception as e:
    print(f'  Error parsing model list: {e}')
" 2>/dev/null || echo "  Could not parse model list"

    echo ""
    echo "=== Configuration ==="
    echo "  Primary model: $PRIMARY_MODEL"
    echo "  Fast model:    $FAST_MODEL"
    echo "  MLX backend:   ${OLLAMA_MLX:-not set}"
    echo "  Keep-alive:    ${OLLAMA_KEEP_ALIVE:-default}"
    echo "  Max models:    ${OLLAMA_MAX_LOADED_MODELS:-default}"
}

# ---------------------------------------------------------------------------
# VERIFY — Full connectivity check
# ---------------------------------------------------------------------------
cmd_verify() {
    log "Running full verification..."

    # 1. Server reachable
    if ! curl -s "$API_URL/api/tags" >/dev/null 2>&1; then
        error "Ollama server not reachable at $API_URL"
    fi
    log "✓ Server reachable"

    # 2. Primary model available
    if ! curl -s "$API_URL/api/tags" | grep -q "$PRIMARY_MODEL"; then
        error "Primary model not found: $PRIMARY_MODEL (run with --pull)"
    fi
    log "✓ Primary model: $PRIMARY_MODEL"

    # 3. Fast model available
    if ! curl -s "$API_URL/api/tags" | grep -q "$FAST_MODEL"; then
        error "Fast model not found: $FAST_MODEL (run with --pull)"
    fi
    log "✓ Fast model: $FAST_MODEL"

    # 4. OpenAI-compatible API working
    local test_resp
    test_resp="$(curl -s -X POST "$API_URL/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d '{
            "model": "'"$PRIMARY_MODEL"'",
            "messages": [{"role": "user", "content": "Say hello"}],
            "max_tokens": 10
        }' 2>/dev/null)"

    if echo "$test_resp" | grep -q '"content"'; then
        log "✓ OpenAI API working (primary model)"
    else
        error "OpenAI API test failed: $test_resp"
    fi

    log "All verification checks passed!"
}

# ---------------------------------------------------------------------------
# STOP — Shutdown Ollama
# ---------------------------------------------------------------------------
cmd_stop() {
    log "Stopping Ollama..."

    if [[ -f "$PIDFILE" ]]; then
        local pid
        pid="$(cat "$PIDFILE")"
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid"
            wait "$pid" 2>/dev/null || true
            log "Ollama stopped (PID: $pid)"
        fi
        rm -f "$PIDFILE"
    else
        # Try to find and kill ollama processes
        pkill -f "ollama serve" 2>/dev/null || true
        log "Ollama stopped"
    fi
}

# ---------------------------------------------------------------------------
# Main dispatch
# ---------------------------------------------------------------------------
[[ $# -eq 0 ]] && usage

# Pre-flight checks
check_memory

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --install)   cmd_install; shift ;;
        --pull)      cmd_pull; shift ;;
        --start)     cmd_start; shift ;;
        --status)    cmd_status; shift ;;
        --verify)    cmd_verify; shift ;;
        --stop)      cmd_stop; shift ;;
        --help|-h)   usage ;;
        *)           error "Unknown option: $1" ;;
    esac
done

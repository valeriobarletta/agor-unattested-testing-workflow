#!/usr/bin/env bash
# =============================================================================
# setup-host.sh — One-Time Host Environment Setup
# =============================================================================
# Usage:
#   setup-host.sh [--check-only] [--skip-deps] [--force]
#
# Description:
#   Prepares the host machine for the Agor unattended testing workflow:
#   - Creates isolated Docker network
#   - Creates base directories
#   - Checks/installs prerequisites (Docker, Git, Node 22+, Python, jq)
#   - Installs Ollama
#   - Pulls both models (devstral:24b + deepseek-coder-v2-lite:16b)
#   - Builds executor Docker image
#   - Validates Ollama connectivity
#
#   This script is idempotent — running it multiple times is safe.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
PRIMARY_MODEL="${AGOR_PRIMARY_MODEL:-devstral:24b}"
FAST_MODEL="${AGOR_FAST_MODEL:-deepseek-coder-v2-lite:16b}"
OLLAMA_HOST="${AGOR_OLLAMA_HOST:-http://localhost:11434}"
NETWORK_NAME="${AGOR_NETWORK:-agor-isolated}"
EXECUTOR_IMAGE="${AGOR_EXECUTOR_IMAGE:-agor-executor:latest}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() { echo -e "${GREEN}[OK]${NC} $*"; }
error() { echo -e "${RED}[FAIL]${NC} $*" >&2; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
info() { echo -e "${BLUE}[INFO]${NC} $*"; }

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

One-time host setup for Agor unattended testing workflow.

Options:
  --check-only    Only check prerequisites, don't install anything
  --skip-deps     Skip dependency installation (just check)
  --force         Force re-install even if already present
  --help, -h      Show this help

Examples:
  $(basename "$0")              # Full setup
  $(basename "$0") --check-only # Just verify
EOF
    exit 0
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
CHECK_ONLY=false
SKIP_DEPS=false
FORCE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check-only) CHECK_ONLY=true; shift ;;
        --skip-deps)  SKIP_DEPS=true; shift ;;
        --force)      FORCE=true; shift ;;
        --help|-h)    usage ;;
        *)            error "Unknown option: $1"; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Check functions
# ---------------------------------------------------------------------------

check_docker() {
    if command -v docker >/dev/null 2>&1; then
        local version
        version="$(docker --version 2>/dev/null || echo 'unknown')"
        log "Docker: $version"
        return 0
    fi
    error "Docker not found"
    return 1
}

check_git() {
    if command -v git >/dev/null 2>&1; then
        local version
        version="$(git --version 2>/dev/null || echo 'unknown')"
        log "Git: $version"
        return 0
    fi
    error "Git not found"
    return 1
}

check_node() {
    if command -v node >/dev/null 2>&1; then
        local version
        version="$(node --version 2>/dev/null || echo 'unknown')"
        # Check version >= 22.12
        local major
        major="$(node -p 'process.version.match(/^v(\d+)/)[1]' 2>/dev/null || echo 0)"
        if [[ "$major" -ge 22 ]]; then
            log "Node.js: $version (OK)"
            return 0
        else
            warn "Node.js: $version (need >= 22.12)"
            return 1
        fi
    fi
    error "Node.js not found"
    return 1
}

check_python() {
    if command -v python3 >/dev/null 2>&1; then
        local version
        version="$(python3 --version 2>/dev/null || echo 'unknown')"
        log "Python: $version"
        return 0
    fi
    error "Python 3 not found"
    return 1
}

check_jq() {
    if command -v jq >/dev/null 2>&1; then
        log "jq: $(jq --version 2>/dev/null)"
        return 0
    fi
    error "jq not found"
    return 1
}

check_ollama() {
    if command -v ollama >/dev/null 2>&1; then
        local version
        version="$(ollama --version 2>/dev/null || echo 'unknown')"
        log "Ollama: $version"
        return 0
    fi
    error "Ollama not found"
    return 1
}

# ---------------------------------------------------------------------------
# Install functions
# ---------------------------------------------------------------------------

install_docker() {
    info "Installing Docker..."
    case "$(uname -s)" in
        Darwin)
            warn "Please install Docker Desktop for Mac manually:"
            warn "  https://docs.docker.com/desktop/install/mac-install/"
            return 1
            ;;
        Linux)
            curl -fsSL https://get.docker.com | sh
            sudo usermod -aG docker "$USER"
            ;;
    esac
}

install_node() {
    info "Installing Node.js 22..."
    # Use n or nvm if available, otherwise official installer
    if command -v n >/dev/null 2>&1; then
        sudo n 22
    elif command -v nvm >/dev/null 2>&1; then
        nvm install 22
        nvm use 22
    else
        curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
        sudo apt-get install -y nodejs
    fi
}

install_jq() {
    info "Installing jq..."
    case "$(uname -s)" in
        Darwin) brew install jq ;;
        Linux)  sudo apt-get install -y jq ;;
    esac
}

install_ollama() {
    info "Installing Ollama..."
    curl -fsSL https://ollama.com/install.sh | sh
}

# ---------------------------------------------------------------------------
# Setup functions
# ---------------------------------------------------------------------------

setup_directories() {
    info "Creating directories..."
    local dirs=(
        "/var/repos"
        "/var/agor/artifacts"
        "/var/agor/logs"
        "/var/agor/sessions"
    )
    for dir in "${dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            log "Directory exists: $dir"
        else
            sudo mkdir -p "$dir"
            sudo chmod 755 "$dir"
            log "Created: $dir"
        fi
    done
}

setup_network() {
    info "Setting up Docker network..."
    if [[ -x "$SCRIPT_DIR/network-setup.sh" ]]; then
        "$SCRIPT_DIR/network-setup.sh" create
    else
        warn "network-setup.sh not found — skipping network setup"
    fi
}

setup_ollama_models() {
    info "Pulling Ollama models..."

    # Start Ollama if not running
    local ollama_was_running=false
    if curl -s "$OLLAMA_HOST/api/tags" >/dev/null 2>&1; then
        ollama_was_running=true
    else
        info "Starting Ollama temporarily..."
        ollama serve &
        sleep 5
    fi

    # Wait for Ollama
    local retries=0
    while ! curl -s "$OLLAMA_HOST/api/tags" >/dev/null 2>&1; do
        retries=$((retries + 1))
        [[ $retries -gt 30 ]] && error "Ollama failed to start"
        sleep 1
    done

    # Pull models
    log "Pulling: $PRIMARY_MODEL"
    ollama pull "$PRIMARY_MODEL"

    log "Pulling: $FAST_MODEL"
    ollama pull "$FAST_MODEL"

    # Stop if we started it
    if [[ "$ollama_was_running" == false ]]; then
        pkill -f "ollama serve" || true
    fi

    log "Models pulled successfully"
}

build_executor_image() {
    info "Building executor Docker image..."
    local dockerfile="$SCRIPT_DIR/../configs/Dockerfile.executor"
    [[ ! -f "$dockerfile" ]] && dockerfile="$SCRIPT_DIR/Dockerfile.executor"

    if [[ ! -f "$dockerfile" ]]; then
        warn "Dockerfile not found — skipping image build"
        return 1
    fi

    docker build -f "$dockerfile" -t "$EXECUTOR_IMAGE" .
    log "Docker image built: $EXECUTOR_IMAGE"
}

validate_ollama() {
    info "Validating Ollama connectivity..."

    if ! curl -s "$OLLAMA_HOST/api/tags" >/dev/null 2>&1; then
        error "Ollama not reachable at $OLLAMA_HOST"
        return 1
    fi

    # Check primary model
    if ! curl -s "$OLLAMA_HOST/api/tags" | grep -q "$PRIMARY_MODEL"; then
        error "Primary model not found: $PRIMARY_MODEL"
        return 1
    fi
    log "Primary model available: $PRIMARY_MODEL"

    # Check fast model
    if ! curl -s "$OLLAMA_HOST/api/tags" | grep -q "$FAST_MODEL"; then
        error "Fast model not found: $FAST_MODEL"
        return 1
    fi
    log "Fast model available: $FAST_MODEL"

    # Quick API test
    local resp
    resp="$(curl -s -X POST "$OLLAMA_HOST/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d '{"model": "'"$PRIMARY_MODEL"'", "messages": [{"role": "user", "content": "Hello"}], "max_tokens": 5}')"

    if echo "$resp" | grep -q '"content"'; then
        log "Ollama API working correctly"
    else
        error "Ollama API test failed"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    echo "============================================"
    echo " Agor Unattended Testing Workflow — Setup"
    echo "============================================"
    echo ""

    local failed_checks=()

    # Check prerequisites
    info "Checking prerequisites..."
    check_docker      || failed_checks+=("docker")
    check_git         || failed_checks+=("git")
    check_node        || failed_checks+=("node")
    check_python      || failed_checks+=("python")
    check_jq          || failed_checks+=("jq")
    check_ollama      || failed_checks+=("ollama")

    echo ""

    # If check-only, report and exit
    if $CHECK_ONLY; then
        if [[ ${#failed_checks[@]} -eq 0 ]]; then
            log "All prerequisites satisfied"
            exit 0
        else
            error "Missing: ${failed_checks[*]}"
            exit 1
        fi
    fi

    # Install missing dependencies
    if ! $SKIP_DEPS && [[ ${#failed_checks[@]} -gt 0 ]]; then
        info "Installing missing dependencies: ${failed_checks[*]}"
        for dep in "${failed_checks[@]}"; do
            case "$dep" in
                docker) install_docker || warn "Docker install failed" ;;
                node)   install_node || warn "Node install failed" ;;
                jq)     install_jq || warn "jq install failed" ;;
                ollama) install_ollama || warn "Ollama install failed" ;;
            esac
        done
    fi

    # Setup directories
    setup_directories

    # Setup network
    setup_network

    # Pull Ollama models
    if ! $SKIP_DEPS; then
        setup_ollama_models
    fi

    # Build Docker image
    build_executor_image || warn "Docker image build skipped"

    # Validate
    validate_ollama

    echo ""
    echo "============================================"
    log "Setup complete!"
    echo ""
    echo "Next steps:"
    echo "  1. Install Agor: npm install -g agor-live && agor init"
    echo "  2. Copy configs:"
    echo "     cp configs/codex_config.toml ~/.codex/config.toml"
    echo "     cp configs/agor_config.yaml ~/.agor/config.yaml"
    echo "  3. Start Ollama: OLLAMA_MLX=1 ollama serve"
    echo "  4. Run integration tests from integration_guide.md"
    echo "============================================"
}

main

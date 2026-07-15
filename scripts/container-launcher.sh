#!/usr/bin/env bash
# =============================================================================
# container-launcher.sh — Launch Isolated Executor Container
# =============================================================================
# Usage:
#   container-launcher.sh <worktree_path> [plan_path]
#
# Description:
#   Launches a hardened Docker container for the Codex CLI executor with
#   full security isolation. The container can access Ollama on the host
#   via host.docker.internal:11434.
#
# Security features:
#   - All capabilities dropped
#   - Read-only root filesystem
#   - No privilege escalation
#   - Isolated network (agor-isolated)
#   - Only worktree mounted (no home, no SSH, no secrets)
#   - Secrets injected via tmpfs (memory-only)
#   - Resource limits (CPU, memory, PIDs)
#   - Timeout enforcement
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
IMAGE_NAME="${AGOR_EXECUTOR_IMAGE:-agor-executor:latest}"
NETWORK_NAME="${AGOR_NETWORK:-agor-isolated}"
CONTAINER_PREFIX="agor-exec"
TIMEOUT_SECONDS="${AGOR_EXEC_TIMEOUT:-600}"
MAX_RETRIES=2
AUTHORIZED_ROOT="/var/repos"

# Ollama host configuration (container → host)
OLLAMA_HOST="http://host.docker.internal:11434"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }
error() { log "ERROR: $*"; exit 1; }
warn() { log "WARN: $*"; }

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") <worktree_path> [plan_path]

Launch an isolated Codex executor container for a Git worktree.

Arguments:
  worktree_path    Absolute path to the Git worktree (must be under $AUTHORIZED_ROOT)
  plan_path        Optional: path to machine-readable execution plan JSON

Environment:
  AGOR_EXECUTOR_IMAGE   Docker image name (default: agor-executor:latest)
  AGOR_NETWORK          Docker network name (default: agor-isolated)
  AGOR_EXEC_TIMEOUT     Max execution seconds (default: 600)
  AGOR_SECRETS_FILE     Optional: path to secrets env file for tmpfs injection

Examples:
  $(basename "$0") /var/repos/agor-JIRA-123
  $(basename "$0") /var/repos/agor-JIRA-123 /tmp/plan-123.json
EOF
    exit 0
}

# ---------------------------------------------------------------------------
# Validate worktree path
# ---------------------------------------------------------------------------
validate_worktree() {
    local path="$1"

    # Must be absolute
    [[ "$path" != /* ]] && error "Worktree path must be absolute: $path"

    # Canonicalize
    local canonical
    canonical="$(realpath -e "$path" 2>/dev/null)" || error "Path does not exist: $path"

    # Must be within authorized root
    [[ "$canonical" != "$AUTHORIZED_ROOT"/* ]] && error \
        "Worktree outside authorized root: $canonical (must be under $AUTHORIZED_ROOT)"

    # Must be a Git worktree
    [[ ! -d "$canonical/.git" && ! -f "$canonical/.git" ]] && warn \
        "Path may not be a Git worktree: $canonical"

    echo "$canonical"
}

# ---------------------------------------------------------------------------
# Generate unique container name
# ---------------------------------------------------------------------------
generate_container_name() {
    local suffix
    suffix="$(basename "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-')-$(date +%s)"
    echo "${CONTAINER_PREFIX}-${suffix}"
}

# ---------------------------------------------------------------------------
# Prepare secrets tmpfs
# ---------------------------------------------------------------------------
prepare_secrets() {
    local container_id="$1"
    local secret_dir="/run/agor-secrets/${container_id}"

    mkdir -p "$secret_dir"
    mount -t tmpfs -o size=1m,mode=700 tmpfs "$secret_dir" 2>/dev/null || {
        warn "Cannot mount tmpfs for secrets — falling back to regular directory"
    }

    # If a secrets file is provided, copy it into tmpfs
    if [[ -n "${AGOR_SECRETS_FILE:-}" && -f "$AGOR_SECRETS_FILE" ]]; then
        cp "$AGOR_SECRETS_FILE" "${secret_dir}/env"
        chmod 600 "${secret_dir}/env"
        log "Secrets injected from: $AGOR_SECRETS_FILE"
    fi

    echo "$secret_dir"
}

# ---------------------------------------------------------------------------
# Main launch
# ---------------------------------------------------------------------------
main() {
    [[ $# -lt 1 ]] && usage

    local worktree_raw="$1"
    local plan_path="${2:-}"

    # Validate inputs
    local worktree_path
    worktree_path="$(validate_worktree "$worktree_raw")"
    log "Worktree: $worktree_path"

    if [[ -n "$plan_path" ]]; then
        [[ ! -f "$plan_path" ]] && error "Plan file not found: $plan_path"
        plan_path="$(realpath "$plan_path")"
        log "Plan: $plan_path"
    fi

    # Generate container name
    local container_name
    container_name="$(generate_container_name "$worktree_path")"
    log "Container: $container_name"

    # Prepare secrets tmpfs
    local secret_dir
    secret_dir="$(prepare_secrets "$container_name")"

    # Cleanup trap
    cleanup() {
        local exit_code=$?
        log "Cleaning up container: $container_name"
        docker stop "$container_name" >/dev/null 2>&1 || true
        docker rm "$container_name" >/dev/null 2>&1 || true
        umount "$secret_dir" 2>/dev/null || true
        rm -rf "$secret_dir"
        log "Cleanup complete (exit code: $exit_code)"
        return $exit_code
    }
    trap cleanup EXIT

    # Build Docker run command
    local docker_args=(
        # Run and remove
        --rm
        --name "$container_name"
        --hostname "$container_name"

        # Security: Drop all capabilities
        --cap-drop=ALL

        # Security: No privilege escalation
        --security-opt=no-new-privileges:true

        # Security: Read-only root filesystem
        --read-only

        # Security: Private namespaces
        --pid=private
        --ipc=private
        --uts=private

        # Resource limits
        --cpus=2
        --memory=2g
        --memory-swap=2g
        --pids-limit=100
        --ulimit nofile=1024:1024

        # Network: Isolated Docker network
        --network="$NETWORK_NAME"

        # Filesystem: Only worktree mounted (read-write for code changes)
        --volume "${worktree_path}:/workspace:rw"

        # Security: Null-mounts for forbidden paths
        --volume /dev/null:/root/.ssh:ro
        --volume /dev/null:/root/.aws:ro
        --volume /dev/null:/root/.config:ro
        --volume /dev/null:/root/.codex:ro
        --volume /dev/null:/root/.ollama:ro
        --volume /dev/null:/etc/shadow:ro
        --volume /dev/null:/var/run/docker.sock:ro

        # Tmpfs for writable areas (noexec, nosuid)
        --tmpfs /tmp:rw,noexec,nosuid,size=200m
        --tmpfs /var/tmp:rw,noexec,nosuid,size=100m
        --tmpfs /home/codex:rw,noexec,nosuid,size=50m

        # Working directory
        --workdir /workspace

        # Environment: Isolated Git config
        --env GIT_CONFIG_NOSYSTEM=1
        --env GIT_CONFIG_GLOBAL=/dev/null
        --env HOME=/tmp

        # Environment: Ollama host (container → host)
        --env OLLAMA_HOST="$OLLAMA_HOST"
        --env OLLAMA_API_KEY=""

        # Allow container to reach host Ollama (Linux compatibility)
        --add-host=host.docker.internal:host-gateway
    )

    # Mount plan file if provided (read-only)
    if [[ -n "$plan_path" ]]; then
        docker_args+=(--volume "${plan_path}:/workspace/.agor/plan.json:ro")
    fi

    # Mount secrets tmpfs if populated
    if [[ -f "${secret_dir}/env" ]]; then
        docker_args+=(--volume "${secret_dir}:/run/secrets:ro")
        docker_args+=(--env-file "${secret_dir}/env")
    fi

    # Log the command
    log "docker run ${docker_args[*]} $IMAGE_NAME <command>"

    # Execute with timeout
    local exit_code=0
    timeout "$TIMEOUT_SECONDS" docker run "${docker_args[@]}" "$IMAGE_NAME" \
        codex \
        --model "${AGOR_MODEL:-devstral:24b}" \
        --model-provider ollama \
        --sandbox workspace-write \
        --approval never \
        ${plan_path:+--plan /workspace/.agor/plan.json} \
        || exit_code=$?

    if [[ $exit_code -eq 124 ]]; then
        error "Executor timed out after ${TIMEOUT_SECONDS}s"
    fi

    log "Executor finished with exit code: $exit_code"
    exit $exit_code
}

main "$@"

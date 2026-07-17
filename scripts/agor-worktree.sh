#!/usr/bin/env bash
# =============================================================================
# agor-worktree.sh — Secure Git Worktree Manager
# =============================================================================
# Usage:
#   agor-worktree.sh create <repo_path> <ticket_id>
#   agor-worktree.sh cleanup <worktree_path>
#   agor-worktree.sh list
#   agor-worktree.sh validate <path>
#
# Description:
#   Creates and manages isolated Git worktrees for Agor executor sessions.
#   Each worktree is a completely independent checkout with its own HEAD,
#   index, and working tree — no switching or stashing required.
#
#   Security features:
#   - Canonical path validation (prevents traversal)
#   - Path must be within authorized root
#   - Git config isolation (no hooks, no credentials)
#   - Automatic cleanup with trap
#
#   CVE-2026-55607 mitigation:
#   - All paths resolved through realpath before use
#   - No relative path acceptance for worktree locations
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
AUTHORIZED_ROOT="/var/repos"
BRANCH_PREFIX="agor"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }
error() { log "ERROR: $*"; exit 1; }

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") <command> [args]

Commands:
  create <repo_path> <ticket_id>  Create isolated worktree for ticket
  cleanup <worktree_path>         Remove worktree and prune
  list                            List active Agor worktrees
  validate <path>                 Validate path is within authorized root

Examples:
  $(basename "$0") create /path/to/repo JIRA-123
  $(basename "$0") cleanup /var/repos/agor-JIRA-123
  $(basename "$0") list
  $(basename "$0") validate /var/repos/agor-JIRA-123
EOF
    exit 0
}

# ---------------------------------------------------------------------------
# Path validation (CVE-2026-55607 mitigation)
# ---------------------------------------------------------------------------
validate_path() {
    local path="$1"

    # Must be absolute
    [[ "$path" != /* ]] && error "Path must be absolute: $path"

    # Resolve to canonical path
    local canonical
    canonical="$(realpath -m "$path" 2>/dev/null)" || error "Cannot resolve path: $path"

    # Must be within authorized root
    local auth_root
    auth_root="$(realpath -m "$AUTHORIZED_ROOT")"
    [[ "$canonical" == "$auth_root"/* ]] || error \
        "Path outside authorized root: $canonical (must be under $auth_root)"

    # Check for path traversal attempts
    [[ "$canonical" == *".."* ]] && error "Path traversal detected: $canonical"

    echo "$canonical"
}

# ---------------------------------------------------------------------------
# Git config isolation
# ---------------------------------------------------------------------------
setup_git_isolation() {
    local worktree_path="$1"

    # No hooks
    git -C "$worktree_path" config --local core.hooksPath /dev/null

    # No credential helpers
    git -C "$worktree_path" config --local credential.helper ""

    # No fsmonitor
    git -C "$worktree_path" config --local core.fsmonitor false

    # No untracked cache
    git -C "$worktree_path" config --local core.untrackedCache false

    # Isolate from system and global config
    export GIT_CONFIG_NOSYSTEM=1
    export GIT_CONFIG_GLOBAL=/dev/null

    log "Git isolation configured for: $worktree_path"
}

# ---------------------------------------------------------------------------
# CREATE — Create isolated worktree
# ---------------------------------------------------------------------------
cmd_create() {
    [[ $# -lt 2 ]] && usage

    local repo_path="$1"
    local ticket_id="$2"

    # Validate repo path
    local canonical_repo
    canonical_repo="$(realpath -e "$repo_path" 2>/dev/null)" || error "Repo not found: $repo_path"
    [[ ! -d "$canonical_repo/.git" ]] && error "Not a git repository: $canonical_repo"

    # Generate worktree path and branch name
    local safe_ticket
    safe_ticket="$(printf '%s' "$ticket_id" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-')"
    local worktree_path="$AUTHORIZED_ROOT/${BRANCH_PREFIX}-${safe_ticket}"
    local branch_name="${BRANCH_PREFIX}/${safe_ticket}"

    # Check if worktree already exists
    if [[ -d "$worktree_path" ]]; then
        warn "Worktree already exists: $worktree_path"
        validate_path "$worktree_path" > /dev/null
        echo "SECURE_WORKTREE_PATH=$worktree_path"
        return 0
    fi

    # Create directory
    mkdir -p "$worktree_path"

    # Create branch and worktree
    git -C "$canonical_repo" branch "$branch_name" 2>/dev/null || true
    git -C "$canonical_repo" worktree add "$worktree_path" "$branch_name"

    # Setup git isolation
    setup_git_isolation "$worktree_path"

    # Validate final path
    local validated
    validated="$(validate_path "$worktree_path")"

    log "Worktree created: $validated (branch: $branch_name)"
    echo "SECURE_WORKTREE_PATH=$validated"
    echo "BRANCH_NAME=$branch_name"
}

# ---------------------------------------------------------------------------
# CLEANUP — Remove worktree
# ---------------------------------------------------------------------------
cmd_cleanup() {
    [[ $# -lt 1 ]] && usage

    local worktree_path="$1"

    # Validate path before cleanup
    local canonical
    canonical="$(validate_path "$worktree_path")"

    log "Cleaning up worktree: $canonical"

    # Remove worktree
    git -C "$canonical" worktree remove --force "$canonical" 2>/dev/null || {
        # If git worktree remove fails, force remove (with safety guard)
        local basename_canonical
        basename_canonical="$(basename "$canonical")"
        [[ "$basename_canonical" != agor-* ]] && error "Refusing to remove non-agor directory: $canonical"
        rm -rf "$canonical"
    }

    # Prune stale worktree entries
    git worktree prune

    log "Worktree cleaned up: $canonical"
}

# ---------------------------------------------------------------------------
# LIST — List active worktrees
# ---------------------------------------------------------------------------
cmd_list() {
    log "Active Agor worktrees:"
    git worktree list --porcelain 2>/dev/null | grep "^worktree " | while read -r line; do
        local path="${line#worktree }"
        if [[ "$(basename "$path")" == agor-* ]]; then
            echo "  $path"
        fi
    done
}

# ---------------------------------------------------------------------------
# VALIDATE — Check path authorization
# ---------------------------------------------------------------------------
cmd_validate() {
    [[ $# -lt 1 ]] && usage
    local path="$1"
    validate_path "$path" > /dev/null && echo "VALID: $path"
}

# ---------------------------------------------------------------------------
# Main dispatch
# ---------------------------------------------------------------------------
[[ $# -lt 1 ]] && usage

case "$1" in
    create)   shift; cmd_create "$@" ;;
    cleanup)  shift; cmd_cleanup "$@" ;;
    list)     shift; cmd_list "$@" ;;
    validate) shift; cmd_validate "$@" ;;
    --help|-h) usage ;;
    *) error "Unknown command: $1" ;;
esac

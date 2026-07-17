#!/usr/bin/env bash
# =============================================================================
# test-discovery.sh — Auto-Discover Repository Test Commands
# =============================================================================
# Usage:
#   test-discovery.sh <project_root>
#
# Description:
#   Analyzes a project directory to determine the project type and discovers
#   available test commands across multiple layers: static validation, unit
#   tests, integration tests, E2E tests, and build.
#
# Supported project types:
#   - Node.js (package.json — jest, vitest, mocha, playwright, cypress)
#   - Python (pyproject.toml, setup.py — pytest, unittest)
#   - Rust (Cargo.toml — cargo test)
#   - Generic (Makefile)
#
# Output: JSON object with test commands per layer
#
# Security: This script runs in the executor container and only reads
# configuration files. It does not execute any discovered commands.
# =============================================================================

set -euo pipefail

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
Usage: $(basename "$0") <project_root>

Auto-discover test commands for a repository.

Arguments:
  project_root    Path to the project repository root

Output:
  JSON object with discovered test commands per layer:
  {
    "project_type": "node",
    "static_validation": ["npm run lint", "npm run typecheck"],
    "unit_tests": ["npm test -- --coverage"],
    "integration_tests": ["npm run test:integration"],
    "e2e_tests": ["npm run test:e2e"],
    "build": ["npm run build"]
  }

Supported project types: node, python, rust, generic
EOF
    exit 0
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
[[ $# -lt 1 ]] && usage
PROJECT_ROOT="$(cd "$1" && pwd)"
[[ ! -d "$PROJECT_ROOT" ]] && error "Not a directory: $PROJECT_ROOT"

log "Scanning project: $PROJECT_ROOT"

# ---------------------------------------------------------------------------
# Node.js detection
# ---------------------------------------------------------------------------
detect_node() {
    local root="$1"
    [[ ! -f "$root/package.json" ]] && return 1

    log "Detected: Node.js project"

    local pkg="$root/package.json"
    local static=()
    local unit=()
    local integration=()
    local e2e=()
    local build_cmd=()

    # Read scripts from package.json using Python for reliable JSON parsing
    local scripts
    scripts="$(_PKG_PATH="$pkg" python3 -c '
import json, sys, os
pkg_path = os.environ["_PKG_PATH"]
try:
    with open(pkg_path) as f:
        data = json.load(f)
    scripts = data.get("scripts", {})
    for name, cmd in scripts.items():
        print(f"{name}:{cmd}")
except Exception as e:
    sys.exit(0)
')"

    # Static validation
    while IFS= read -r line; do
        local name="${line%%:*}"
        case "$name" in
            lint|eslint|tslint|biome|xo|standard)
                static+=("npm run $name") ;;
            typecheck|tsc|"type-check")
                static+=("npm run $name") ;;
            format|prettier|fmt)
                static+=("npm run $name") ;;
        esac
    done <<< "$scripts"

    # Build
    while IFS= read -r line; do
        local name="${line%%:*}"
        case "$name" in
            build|compile|bundle)
                build_cmd+=("npm run $name") ;;
        esac
    done <<< "$scripts"

    # Unit tests
    while IFS= read -r line; do
        local name="${line%%:*}"
        case "$name" in
            test|"test:unit"|"test-unit"|unittest|jest|vitest)
                unit+=("npm run $name -- --coverage") ;;
        esac
    done <<< "$scripts"

    # Integration tests
    while IFS= read -r line; do
        local name="${line%%:*}"
        case "$name" in
            "test:integration"|"test-integration"|"test:api"|"test:db")
                integration+=("npm run $name") ;;
        esac
    done <<< "$scripts"

    # E2E tests
    while IFS= read -r line; do
        local name="${line%%:*}"
        case "$name" in
            "test:e2e"|"test-e2e"|"test:browser"|e2e|playwright|cypress)
                e2e+=("npm run $name") ;;
        esac
    done <<< "$scripts"

    # Detect frameworks in devDependencies for metadata
    local has_jest="false" has_vitest="false" has_playwright="false"
    _PKG_PATH="$pkg" python3 -c '
import json, os
pkg_path = os.environ["_PKG_PATH"]
try:
    with open(pkg_path) as f:
        data = json.load(f)
    deps = {**data.get("dependencies", {}), **data.get("devDependencies", {})}
    print("jest" in deps)
    print("vitest" in deps)
    print("@playwright/test" in deps)
except:
    print("false"); print("false"); print("false")
' | {
        read -r has_jest
        read -r has_vitest
        read -r has_playwright
    }

    # Output JSON via environment variables (avoid shell injection)
    {
        export _AGOR_HAS_JEST="$has_jest"
        export _AGOR_HAS_VITEST="$has_vitest"
        export _AGOR_HAS_PLAYWRIGHT="$has_playwright"
        export _AGOR_STATIC_CMDS _AGOR_UNIT_CMDS _AGOR_INTEGRATION_CMDS _AGOR_E2E_CMDS _AGOR_BUILD_CMDS
        _AGOR_STATIC_CMDS="${static[*]}"
        _AGOR_UNIT_CMDS="${unit[*]}"
        _AGOR_INTEGRATION_CMDS="${integration[*]}"
        _AGOR_E2E_CMDS="${e2e[*]}"
        _AGOR_BUILD_CMDS="${build_cmd[*]}"
        python3 -c '
import json, os

def cmds_to_list(cmds_str):
    return cmds_str.split() if cmds_str else []

result = {
    "project_type": "node",
    "static_validation": cmds_to_list(os.environ.get("_AGOR_STATIC_CMDS", "")),
    "unit_tests": cmds_to_list(os.environ.get("_AGOR_UNIT_CMDS", "")),
    "integration_tests": cmds_to_list(os.environ.get("_AGOR_INTEGRATION_CMDS", "")),
    "e2e_tests": cmds_to_list(os.environ.get("_AGOR_E2E_CMDS", "")),
    "build": cmds_to_list(os.environ.get("_AGOR_BUILD_CMDS", "")),
    "_meta": {
        "package_manager": "npm",
        "has_jest": os.environ.get("_AGOR_HAS_JEST", "false") == "True",
        "has_vitest": os.environ.get("_AGOR_HAS_VITEST", "false") == "True",
        "has_playwright": os.environ.get("_AGOR_HAS_PLAYWRIGHT", "false") == "True"
    }
}
print(json.dumps(result, indent=2))
'
    } 2>/dev/null || echo '{
  "project_type": "node",
  "static_validation": [],
  "unit_tests": [],
  "integration_tests": [],
  "e2e_tests": [],
  "build": []
}'

    return 0
}

# ---------------------------------------------------------------------------
# Python detection
# ---------------------------------------------------------------------------
detect_python() {
    local root="$1"
    [[ ! -f "$root/pyproject.toml" && ! -f "$root/setup.py" && ! -f "$root/setup.cfg" ]] && return 1

    log "Detected: Python project"

    local static=()
    local unit=()
    local integration=()
    local e2e=()
    local build_cmd=()

    # Check for pytest
    if [[ -f "$root/pyproject.toml" ]]; then
        _ROOT_PATH="$root" python3 -c '
import tomllib, sys, os
root_path = os.environ["_ROOT_PATH"]
try:
    with open(os.path.join(root_path, "pyproject.toml"), "rb") as f:
        data = tomllib.load(f)
    # Check for pytest, ruff, mypy, black in tool table
    tools = data.get("tool", {})
    print("pytest" in tools)
    print("ruff" in tools)
    print("mypy" in tools)
    print("black" in tools)
except Exception:
    print("false"); print("false"); print("false"); print("false")
' 2>/dev/null | {
            read -r has_pytest; read -r has_ruff; read -r has_mypy; read -r has_black
            [[ "$has_ruff" == "True" ]] && static+=("ruff check .")
            [[ "$has_mypy" == "True" ]] && static+=("mypy .")
            [[ "$has_black" == "True" ]] && static+=("black --check .")
        }
    fi

    # Default pytest command
    [[ -f "$root/pyproject.toml" || -d "$root/tests" || -d "$root/test" ]] && unit+=("pytest --cov=src --cov-report=xml --cov-report=term")

    # Check for integration test directories
    [[ -d "$root/tests/integration" ]] && integration+=("pytest tests/integration/")
    [[ -d "$root/tests/e2e" ]] && e2e+=("pytest tests/e2e/")

    {
        export _AGOR_STATIC_CMDS _AGOR_UNIT_CMDS _AGOR_INTEGRATION_CMDS _AGOR_E2E_CMDS
        _AGOR_STATIC_CMDS="${static[*]}"
        _AGOR_UNIT_CMDS="pytest --cov=src --cov-report=xml --cov-report=term"
        _AGOR_INTEGRATION_CMDS="${integration[*]}"
        _AGOR_E2E_CMDS="${e2e[*]}"
        python3 -c '
import json, os

def cmds_to_list(cmds_str):
    return cmds_str.split() if cmds_str else []

result = {
    "project_type": "python",
    "static_validation": cmds_to_list(os.environ.get("_AGOR_STATIC_CMDS", "")),
    "unit_tests": [os.environ.get("_AGOR_UNIT_CMDS", "pytest")],
    "integration_tests": cmds_to_list(os.environ.get("_AGOR_INTEGRATION_CMDS", "")),
    "e2e_tests": cmds_to_list(os.environ.get("_AGOR_E2E_CMDS", "")),
    "build": ["python -m build"],
    "_meta": {"package_manager": "pip"}
}
print(json.dumps(result, indent=2))
'
    } 2>/dev/null || echo '{
  "project_type": "python",
  "static_validation": ["pytest --cov=src --cov-report=xml --cov-report=term"],
  "unit_tests": [],
  "integration_tests": [],
  "e2e_tests": [],
  "build": ["python -m build"]
}'

    return 0
}

# ---------------------------------------------------------------------------
# Rust detection
# ---------------------------------------------------------------------------
detect_rust() {
    local root="$1"
    [[ ! -f "$root/Cargo.toml" ]] && return 1

    log "Detected: Rust project"

    echo '{
  "project_type": "rust",
  "static_validation": ["cargo clippy -- -D warnings", "cargo fmt -- --check"],
  "unit_tests": ["cargo test"],
  "integration_tests": ["cargo test --test '\''*integration*'\''"],
  "e2e_tests": [],
  "build": ["cargo build --release"],
  "_meta": {"package_manager": "cargo"}
}'

    return 0
}

# ---------------------------------------------------------------------------
# Generic (Makefile) detection
# ---------------------------------------------------------------------------
detect_generic() {
    local root="$1"
    [[ ! -f "$root/Makefile" && ! -f "$root/makefile" ]] && return 1

    log "Detected: Generic project (Makefile)"

    local mkf="$root/Makefile"
    [[ ! -f "$mkf" ]] && mkf="$root/makefile"

    local static=()
    local unit=()
    local integration=()
    local e2e=()
    local build_cmd=()

    # Parse Makefile targets
    local targets
    targets="$(grep -E '^[a-zA-Z_-]+:' "$mkf" | sed 's/:.*//' | sort -u)"

    while IFS= read -r target; do
        [[ -z "$target" ]] && continue
        case "$target" in
            lint|fmt|format|check|static)
                static+=("make $target") ;;
            test|"test-unit"|"test-unit")
                unit+=("make $target") ;;
            "test-integration"|"test-integration")
                integration+=("make $target") ;;
            "test-e2e"|e2e|"test-browser")
                e2e+=("make $target") ;;
            build|all)
                build_cmd+=("make $target") ;;
        esac
    done <<< "$targets"

    {
        export _AGOR_STATIC_CMDS _AGOR_UNIT_CMDS _AGOR_INTEGRATION_CMDS _AGOR_E2E_CMDS _AGOR_BUILD_CMDS
        _AGOR_STATIC_CMDS="${static[*]}"
        _AGOR_UNIT_CMDS="${unit[*]}"
        _AGOR_INTEGRATION_CMDS="${integration[*]}"
        _AGOR_E2E_CMDS="${e2e[*]}"
        _AGOR_BUILD_CMDS="${build_cmd[*]}"
        python3 -c '
import json, os

def cmds_to_list(cmds_str):
    return cmds_str.split() if cmds_str else []

result = {
    "project_type": "generic",
    "static_validation": cmds_to_list(os.environ.get("_AGOR_STATIC_CMDS", "")),
    "unit_tests": cmds_to_list(os.environ.get("_AGOR_UNIT_CMDS", "")),
    "integration_tests": cmds_to_list(os.environ.get("_AGOR_INTEGRATION_CMDS", "")),
    "e2e_tests": cmds_to_list(os.environ.get("_AGOR_E2E_CMDS", "")),
    "build": cmds_to_list(os.environ.get("_AGOR_BUILD_CMDS", "")),
    "_meta": {"package_manager": "make"}
}
print(json.dumps(result, indent=2))
'
    } 2>/dev/null || echo '{
  "project_type": "generic",
  "static_validation": [],
  "unit_tests": ["make test"],
  "integration_tests": [],
  "e2e_tests": [],
  "build": ["make build"]
}'

    return 0
}

# ---------------------------------------------------------------------------
# Main dispatch
# ---------------------------------------------------------------------------
main() {
    if detect_node "$PROJECT_ROOT"; then exit 0; fi
    if detect_python "$PROJECT_ROOT"; then exit 0; fi
    if detect_rust "$PROJECT_ROOT"; then exit 0; fi
    if detect_generic "$PROJECT_ROOT"; then exit 0; fi

    # Unknown project type — return empty structure
    log "Unknown project type — returning empty test configuration"
    echo '{
  "project_type": "unknown",
  "static_validation": [],
  "unit_tests": [],
  "integration_tests": [],
  "e2e_tests": [],
  "build": [],
  "_meta": {"error": "Could not detect project type"}
}'
}

main

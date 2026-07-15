#!/usr/bin/env bash
# =============================================================================
# test-runner.sh — Execute Tests and Collect Artifacts
# =============================================================================
# Usage:
#   test-runner.sh <test_type> <worktree_path> [artifacts_dir]
#
# Test types: static, unit, integration, e2e, all
#
# Description:
#   Discovers and executes test commands for a repository, collects
#   test output, coverage reports, and E2E artifacts (screenshots, traces).
#
#   Relies on test-discovery.sh to determine available test commands.
# =============================================================================

set -euo pipefail

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
Usage: $(basename "$0") <test_type> <worktree_path> [artifacts_dir]

Execute tests and collect artifacts.

Arguments:
  test_type      One of: static, unit, integration, e2e, all
  worktree_path  Path to the Git worktree containing the code
  artifacts_dir  Directory to store artifacts (default: /var/agor/artifacts/<timestamp>)

Examples:
  $(basename "$0") all /var/repos/agor-JIRA-123
  $(basename "$0") unit /var/repos/agor-JIRA-123 /tmp/test-artifacts
EOF
    exit 0
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
[[ $# -lt 2 ]] && usage

TEST_TYPE="$1"
WORKTREE="$(cd "$2" && pwd)"
ARTIFACTS_DIR="${3:-/var/agor/artifacts/$(date +%Y%m%d-%H%M%S)}"

[[ ! -d "$WORKTREE" ]] && error "Worktree not found: $WORKTREE"

mkdir -p "$ARTIFACTS_DIR"
log "Artifacts: $ARTIFACTS_DIR"

# ---------------------------------------------------------------------------
# Test discovery
# ---------------------------------------------------------------------------
DISCOVERY="$(cd "$(dirname "$0")" && pwd)/test-discovery.sh"
[[ ! -x "$DISCOVERY" ]] && error "test-discovery.sh not found: $DISCOVERY"

log "Running test discovery..."
TEST_CONFIG="$($DISCOVERY "$WORKTREE" 2>/dev/null || echo '{}')"

# ---------------------------------------------------------------------------
# Result tracking
# ---------------------------------------------------------------------------
declare -A RESULTS
declare -A EXIT_CODES
OVERALL_STATUS="passed"

# ---------------------------------------------------------------------------
# Run a test layer
# ---------------------------------------------------------------------------
run_layer() {
    local layer="$1"
    local commands_json="$2"

    log "Running layer: $layer"

    local layer_dir="$ARTIFACTS_DIR/$layer"
    mkdir -p "$layer_dir"

    # Parse commands from JSON
    local commands
    commands="$(echo "$commands_json" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    for cmd in data:
        print(cmd)
except:
    pass
")"

    [[ -z "$commands" ]] && {
        log "No commands for layer: $layer"
        RESULTS["$layer"]="skipped"
        return 0
    }

    local layer_stdout="$layer_dir/stdout.log"
    local layer_stderr="$layer_dir/stderr.log"
    local layer_exit=0

    while IFS= read -r cmd; do
        [[ -z "$cmd" ]] && continue
        log "  $ $cmd"

        local cmd_exit=0
        (cd "$WORKTREE" && eval "$cmd" >> "$layer_stdout" 2>> "$layer_stderr") || cmd_exit=$?

        if [[ $cmd_exit -ne 0 ]]; then
            layer_exit=$cmd_exit
            warn "  FAILED (exit $cmd_exit): $cmd"
        else
            log "  OK: $cmd"
        fi
    done <<< "$commands"

    EXIT_CODES["$layer"]=$layer_exit

    if [[ $layer_exit -eq 0 ]]; then
        RESULTS["$layer"]="passed"
    else
        RESULTS["$layer"]="failed"
        OVERALL_STATUS="failed"
    fi

    # Copy coverage if available
    find "$WORKTREE" -maxdepth 3 \( \
        -name "coverage.xml" -o \
        -name "lcov.info" -o \
        -name "coverage.json" -o \
        -name ".coverage" -o \
        -name "htmlcov" -type d \
    \) -exec cp -r {} "$layer_dir/" \; 2>/dev/null || true

    # Copy E2E artifacts on failure
    if [[ $layer_exit -ne 0 && "$layer" == "e2e" ]]; then
        find "$WORKTREE" -maxdepth 3 \( \
            -name "test-results" -type d -o \
            -name "playwright-report" -type d -o \
            -name "cypress" -type d -o \
            -name "*.png" -path "*/screenshots/*" \
        \) -exec cp -r {} "$layer_dir/" \; 2>/dev/null || true
    fi

    return $layer_exit
}

# ---------------------------------------------------------------------------
# Parse test results from output
# ---------------------------------------------------------------------------
parse_results() {
    local layer="$1"
    local stdout_file="$ARTIFACTS_DIR/$layer/stdout.log"

    [[ ! -f "$stdout_file" ]] && return

    local passed=0 failed=0 skipped=0

    # Try to detect test framework and parse
    local framework
    framework="$(detect_framework "$stdout_file")"

    case "$framework" in
        jest)
            # Jest output: "Tests: 5 passed, 1 failed, 2 skipped"
            local line
            line="$(grep -E "Tests:\s+[0-9]+" "$stdout_file" | tail -1)"
            passed="$(echo "$line" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+' || echo 0)"
            failed="$(echo "$line" | grep -oE '[0-9]+ failed' | grep -oE '[0-9]+' || echo 0)"
            skipped="$(echo "$line" | grep -oE '[0-9]+ skipped' | grep -oE '[0-9]+' || echo 0)"
            ;;
        vitest)
            # Vitest: " Test Files  3 passed (3)"
            passed="$(grep -oE '[0-9]+ passed' "$stdout_file" | grep -oE '[0-9]+' | tail -1 || echo 0)"
            failed="$(grep -oE '[0-9]+ failed' "$stdout_file" | grep -oE '[0-9]+' | tail -1 || echo 0)"
            ;;
        pytest)
            # pytest: "3 passed, 1 failed, 2 skipped"
            local summary
            summary="$(grep -E "passed|failed|error" "$stdout_file" | tail -1)"
            passed="$(echo "$summary" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+' || echo 0)"
            failed="$(echo "$summary" | grep -oE '[0-9]+ failed' | grep -oE '[0-9]+' || echo 0)"
            skipped="$(echo "$summary" | grep -oE '[0-9]+ skipped' | grep -oE '[0-9]+' || echo 0)"
            ;;
        cargo)
            # Cargo: "test result: ok. 5 passed; 1 failed; 0 ignored"
            local line
            line="$(grep "test result:" "$stdout_file" | tail -1)"
            passed="$(echo "$line" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+' || echo 0)"
            failed="$(echo "$line" | grep -oE '[0-9]+ failed' | grep -oE '[0-9]+' || echo 0)"
            ;;
    esac

    # Write parsed results
    cat > "$ARTIFACTS_DIR/$layer/results.json" <<EOF
{
  "layer": "$layer",
  "framework": "$framework",
  "passed": ${passed:-0},
  "failed": ${failed:-0},
  "skipped": ${skipped:-0}
}
EOF
}

detect_framework() {
    local file="$1"
    if grep -q "PASS\|FAIL" "$file" 2>/dev/null && grep -q "jest" "$file" 2>/dev/null; then
        echo "jest"
    elif grep -q "Vitest" "$file" 2>/dev/null; then
        echo "vitest"
    elif grep -q "pytest" "$file" 2>/dev/null; then
        echo "pytest"
    elif grep -q "test result:" "$file" 2>/dev/null; then
        echo "cargo"
    else
        echo "unknown"
    fi
}

# ---------------------------------------------------------------------------
# Collect git diff
# ---------------------------------------------------------------------------
collect_git_diff() {
    local diff_file="$ARTIFACTS_DIR/git-diff.patch"
    (cd "$WORKTREE" && git diff --patch > "$diff_file" 2>/dev/null) || true
    [[ -s "$diff_file" ]] && log "Git diff collected: $diff_file"
}

# ---------------------------------------------------------------------------
# Generate summary JSON
# ---------------------------------------------------------------------------
generate_summary() {
    local summary_file="$ARTIFACTS_DIR/test-report.json"

    python3 -c "
import json, os

result = {
    'timestamp': '$(date -u +%Y-%m-%dT%H:%M:%SZ)',
    'worktree': '$WORKTREE',
    'overall_status': '$OVERALL_STATUS',
    'layers': {}
}

layers = ['static_validation', 'unit_tests', 'integration_tests', 'e2e_tests']
for layer in layers:
    layer_dir = os.path.join('$ARTIFACTS_DIR', layer)
    if os.path.exists(os.path.join(layer_dir, 'results.json')):
        with open(os.path.join(layer_dir, 'results.json')) as f:
            result['layers'][layer] = json.load(f)
    else:
        status = '${RESULTS['$layer']:-not_run}'
        result['layers'][layer] = {'status': status}

# Add coverage info
coverage_files = []
for root, dirs, files in os.walk('$ARTIFACTS_DIR'):
    for f in files:
        if 'coverage' in f.lower():
            coverage_files.append(os.path.relpath(os.path.join(root, f), '$ARTIFACTS_DIR'))
result['coverage_files'] = coverage_files

with open('$summary_file', 'w') as f:
    json.dump(result, f, indent=2)

print(f'Summary written to: $summary_file')
print(f'Overall: {result[\"overall_status\"]}')
"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    log "Test runner starting: type=$TEST_TYPE worktree=$WORKTREE"

    # Determine which layers to run
    local layers=()
    case "$TEST_TYPE" in
        static)      layers=("static_validation") ;;
        unit)        layers=("unit_tests") ;;
        integration) layers=("integration_tests") ;;
        e2e)         layers=("e2e_tests") ;;
        all)         layers=("static_validation" "unit_tests" "integration_tests" "e2e_tests") ;;
        *)           error "Unknown test type: $TEST_TYPE" ;;
    esac

    # Run each layer
    for layer in "${layers[@]}"; do
        local commands
        commands="$(echo "$TEST_CONFIG" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    cmds = data.get('$layer', [])
    print(json.dumps(cmds))
except:
    print('[]')
")"
        run_layer "$layer" "$commands" || true  # Continue even if layer fails
        parse_results "$layer"
    done

    # Collect git diff
    collect_git_diff

    # Generate summary
    generate_summary

    # Final status
    if [[ "$OVERALL_STATUS" == "passed" ]]; then
        log "All tests passed"
        exit 0
    else
        log "Some tests failed — see $ARTIFACTS_DIR"
        exit 1
    fi
}

main

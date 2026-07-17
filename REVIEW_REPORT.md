# Comprehensive Code Review Report

**Repository:** `valeriobarletta/agor-unattested-testing-workflow`  
**Date:** July 17, 2026  
**Scope:** All 30 files  
**Total Findings:** 216  
**Verdict:** **NEEDS_FIX** — Do not deploy to production without addressing critical issues.

---

## Executive Summary

| Category | Files | Critical | High | Medium | Low | Info | Total |
|----------|-------|----------|------|--------|-----|------|-------|
| Shell Scripts | 7 | 5 | 9 | 30 | 23 | 0 | 67 |
| Python Modules | 7 | 3 | 13 | 28 | 38 | 0 | 82 |
| Config Files | 5 | 0 | 3 | 12 | 11 | 6 | 32 |
| Documentation | 7 | 0 | 4 | 15 | 16 | 0 | 35 |
| **TOTAL** | **30** | **8** | **29** | **85** | **88** | **6** | **216** |

### Files by Verdict

| Verdict | Count | Files |
|---------|-------|-------|
| CRITICAL | 2 | `scripts/test-runner.sh`, `scripts/container-launcher.sh` |
| NEEDS_FIX | 11 | `scripts/setup-host.sh`, `scripts/agor-worktree.sh`, `scripts/test-discovery.sh`, `scripts/network-setup.sh`, `configs/launch-ollama.sh`, `scripts/orchestrator.py`, `scripts/policy_engine.py`, `scripts/session_manager.py`, `scripts/artifact_collector.py`, `scripts/pr_generator.py`, `scripts/config.py`, `configs/agor_config.yaml`, `configs/policy.yaml`, `configs/Dockerfile.executor`, `implementation_plan.md`, `runbook.md`, `integration_guide.md` |
| PASS | 5 | `scripts/exceptions.py`, `configs/codex_config.toml`, `configs/docker-compose.yml`, `FINAL_EVALUATION.md`, `evaluation_report.md`, `research/colibri_deep_dive.md`, `research/32gb_local_llm_options.md` |

---

## Top 15 Critical Issues (Must Fix)

| # | File | Line | Severity | Issue | Fix |
|---|------|------|----------|-------|-----|
| 1 | `test-runner.sh` | 102 | **CRITICAL** | `eval "$cmd"` executes arbitrary shell commands from untrusted repo configs (package.json, Makefile) | Remove `eval`. Use array-based execution: `read -ra cmdarray <<< "$cmd"; "${cmdarray[@]}"` |
| 2 | `container-launcher.sh` | 236 | **CRITICAL** | Full Docker command (with `--env-file` path) logged — secrets exposed in logs/process listings | Log only container name, image, worktree path. Never log full command. |
| 3 | `test-discovery.sh` | 107 | **CRITICAL** | Python code injection via unescaped paths in `python3 -c "...'$pkg'..."`. Path with `'` executes arbitrary Python | Pass paths via `sys.argv` or env vars, never inline into `-c` strings |
| 4 | `container-launcher.sh` | 152 | **CRITICAL** | `mount -t tmpfs` failure silently falls back to disk for secrets storage | Fail hard: `mount ... \|\| error "Cannot mount tmpfs — need root"` |
| 5 | `container-launcher.sh` | 137 | **CRITICAL** | `warn` instead of `error` for non-git paths — any directory under `/var/repos` can be mounted | Change to `error` and exit if `.git` not present |
| 6 | `orchestrator.py` | 319 | **CRITICAL** | `os.environ` used without `import os` — script crashes at runtime with `NameError` | Add `import os` at top of file |
| 7 | `pr_generator.py` | 253 | **CRITICAL** | GitHub token embedded in Git remote URL → written to `.git/config` on disk. Persists and leaks via `git remote -v` | Use `GIT_ASKPASS` with temporary credential helper instead |
| 8 | `test-runner.sh` | 243 | **CRITICAL** | Python inline code in `generate_summary` injects shell variables without escaping single quotes | Pass data via env vars or use `jq` for JSON generation |

---

## Top 15 High Issues (Should Fix)

| # | File | Line | Severity | Issue | Fix |
|---|------|------|----------|-------|-----|
| 9 | `setup-host.sh` | 118 | **HIGH** | `command -nvm` typo — `-n` is not a valid `command` flag. nvm branch never executes | Change to `command -v nvm` |
| 10 | `launch-ollama.sh` | 379 | **HIGH** | `pkill -f "ollama serve"` kills ALL Ollama processes system-wide | Track PID from PIDFILE, kill only that PID |
| 11 | `agor-worktree.sh` | 108 | **HIGH** | `echo "$ticket_id"` — ticket ID starting with `-` interpreted as echo flag | Use `printf '%s\n' "$ticket_id"` |
| 12 | `agor-worktree.sh` | 180 | **HIGH** | `rm -rf "$canonical"` fallback — if validation edge case returns parent, all worktrees deleted | Guard: verify basename starts with `agor-` before `rm -rf` |
| 13 | `network-setup.sh` | 143 | **HIGH** | `iptables -A FORWARD` appends duplicate rule on each `lockdown` run | Check first: `iptables -C ... 2>/dev/null \|\| iptables -A ...` |
| 14 | `Dockerfile.executor` | — | **HIGH** | `curl` installed but forbidden by `policy.yaml` — policy/tool mismatch | Remove `curl` from apt-get install list |
| 15 | `policy.yaml` | — | **HIGH** | `rm` allowed globally without path restrictions — can delete source code within `/workspace/src` | Add path-based rm restrictions |
| 16 | `orchestrator.py` | 154 | **HIGH** | Bare `except Exception` in `generate_plan()` swallows all errors indiscriminately | Catch specific: `URLError`, `JSONDecodeError`, `KeyError` |
| 17 | `orchestrator.py` | 136 | **HIGH** | f-string with untrusted `ticket_content` enables format-string injection | Use `str.Template` or string concatenation |
| 18 | `orchestrator.py` | 561 | **HIGH** | `artifacts_path` may be referenced before assignment in FAILED error path | Initialize before `try` block |
| 19 | `pr_generator.py` | 277 | **HIGH** | `e.stderr.decode()` on str object (when `text=True`) raises `AttributeError` | Check type: `e.stderr if isinstance(e.stderr, str) else e.stderr.decode()` |
| 20 | `pr_generator.py` | 214 | **HIGH** | Full execution plan JSON (with ticket content) embedded in PR description | Sanitize: use summary only, redact sensitive fields |
| 21 | `policy_engine.py` | 312 | **HIGH** | `Path.resolve()` follows symlinks — TOCTOU race between validation and execution | Use `os.path.realpath()` with `os.path.commonpath()` |
| 22 | `policy_engine.py` | 323 | **HIGH** | Forbidden path check uses substring match: `.github` matches `my.github.repo` | Use `Path.is_relative_to()` for proper comparison |
| 23 | `config.py` | 247 | **HIGH** | `load_config()` catches all exceptions, silently falls back to defaults — config errors invisible | Distinguish exception types, log at ERROR level |

---

## Cross-Category Issues

### 1. curl Installed but Policy-Forbidden (Config → Policy Conflict)
- **Dockerfile.executor** installs `curl` via apt-get
- **policy.yaml** lists `curl` in `forbidden_commands`
- **Impact:** Defense-in-depth gap — if policy engine is bypassed, `curl` is available for exfiltration
- **Fix:** Remove `curl` from Dockerfile. If needed at build time, use multi-stage build.

### 2. Port Numbers Fully Consistent (Good)
- Agor: 3030 — consistent across all 8 documents and 3 configs
- Ollama: 11434 — consistent across all configs, scripts, and docs
- No mismatches found

### 3. Model Names Fully Consistent (Good)
- `devstral:24b` — consistent in codex_config.toml, policy.yaml, agor_config.yaml, all docs
- `deepseek-coder-v2-lite:16b` — consistent everywhere

### 4. Exception Hierarchy 74% Dead Code
- 47 exception classes defined, only 12 used anywhere
- 35 classes never raised or caught
- **Fix:** Remove unused classes or implement them in the modules that should raise them

### 5. Bogus Commands in Docs
- `bash runbook.md | grep ...` appears in both `implementation_plan.md` and `runbook.md`
- Piping Markdown through bash will fail with syntax errors
- **Fix:** Use `grep -A 50 "Security Checklist" runbook.md`

### 6. macOS Compatibility Issues
- `sed -i` without backup extension (fails on macOS) in `integration_guide.md`
- `declare -A` requires Bash 4+ (macOS ships 3.2) in `test-runner.sh`
- `timeout` vs `gtimeout` on macOS in `container-launcher.sh`
- `free` command not available on macOS in `launch-ollama.sh`
- `iptables` is Linux-only in `network-setup.sh`

---

## Security Posture Assessment

| Control | Status | Notes |
|---------|--------|-------|
| Container hardening | Good | cap-drop ALL, read-only, no-new-privileges, non-root |
| Network isolation | Good | internal bridge, default-deny in policy |
| Git security | Good | config isolation, path validation |
| Plan validation | Good | 8-layer validation engine |
| Secret management | **Weak** | tmpfs fallback to disk, token written to .git/config |
| Command injection | **Critical** | `eval` in test-runner, Python injection in discovery |
| Path traversal | Good | canonical path validation in worktree manager |
| Output filtering | Missing | No secret scanning on PR descriptions |

---

## Recommendations by Priority

### Immediate (Block Production)
1. Fix all 8 CRITICAL issues (table above)
2. Fix `curl` in Dockerfile / policy mismatch
3. Add `import os` to `orchestrator.py`
4. Replace `eval` with array execution in `test-runner.sh`
5. Fix token exposure in `pr_generator.py`

### Short Term (1 Week)
6. Fix all 15 HIGH issues
7. Remove 35 unused exception classes
8. Fix `bash runbook.md` bogus commands in docs
9. Add macOS compatibility notes/commands
10. Pin npm package version in Dockerfile

### Medium Term (1 Month)
11. Address MEDIUM findings (85 total)
12. Add `OLLAMA_MAX_LOADED_MODELS` verification (may not be real env var)
13. Verify Codex CLI config keys against actual documentation
14. Add unit tests for policy engine
15. Add integration tests for full workflow

---

## Detailed Reports

Full per-category reports are available:
- [Shell Script Review](review_shell.md) — 67 findings across 7 scripts
- [Python Module Review](review_python.md) — 82 findings across 7 modules
- [Configuration Review](review_configs.md) — 32 findings across 5 configs
- [Documentation Review](review_docs.md) — 35 findings across 7 documents

---

*Review conducted by 4 specialized agents: Shell Reviewer, Python Reviewer, Config Reviewer, and Documentation Reviewer. All files were downloaded from the GitHub repository and analyzed independently.*

# Operator Runbook: Agor Unattended Testing Workflow

**Version:** 2.0 (Ollama Edition)
**Date:** July 15, 2026
**Audience:** DevOps engineers operating the Agor unattended testing workflow

---

## Table of Contents

1. [System Overview](#1-system-overview)
2. [Prerequisites](#2-prerequisites)
3. [Daily Operations](#3-daily-operations)
4. [Incident Response](#4-incident-response)
5. [Recovery Procedures](#5-recovery-procedures)
6. [Troubleshooting Guide](#6-troubleshooting-guide)
7. [Security Checklist](#7-security-checklist)
8. [Quick Reference](#8-quick-reference)

---

## 1. System Overview

The Agor unattended testing workflow automates the process of converting Jira/GitHub tickets into code changes, running tests, and preparing draft pull requests — all with human review as the final gate.

### Architecture (Updated: Ollama Dual-Model)

```
Ticket (Jira/GitHub)
    → Agor Orchestrator
        → Cloud Planner (Claude Opus) — generates execution plan
        → Policy Engine — validates plan
        → Git Worktree — isolated branch
        → Codex CLI + Ollama Executor
            → devstral:24b (complex tasks, ~14GB, 35-50 tok/s)
            → deepseek-coder-v2-lite:16b (quick fixes, ~9GB, 60-80 tok/s)
        → Test Runner — static/unit/integration/e2e
        → Artifact Collector — logs, coverage, screenshots
        → PR Generator — draft PR with evidence
    → Human Review ← YOU ARE HERE
        → Merge or Reject
```

### Dual-Model Auto Selection

| Task Complexity | Model | Speed | Use Case |
|----------------|-------|-------|----------|
| ≤3 steps, no new deps | deepseek-coder-v2-lite:16b | 60-80 tok/s | Quick fixes, refactoring |
| >3 steps or new deps | devstral:24b | 35-50 tok/s | Full implementation |

---

## 2. Prerequisites

### Hardware

| Requirement | Spec | Notes |
|-------------|------|-------|
| **Mac** | M2/M3/M4 Pro, Max, or Studio | Apple Silicon for MLX backend |
| **Memory** | 32GB unified memory minimum | Both models fit in ~23GB |
| **Storage** | 100GB free SSD | Model weights (~50GB) + artifacts |
| **Network** | Internet for initial setup | Can run offline after setup |

### Software

| Tool | Version | Purpose |
|------|---------|---------|
| macOS | 14+ | MLX backend requirement |
| Docker Desktop | 4.30+ | Executor containers |
| Node.js | 22.12+ | Agor runtime |
| Python | 3.11+ | Orchestrator + test runners |
| Git | 2.40+ | Worktree management |
| Ollama | 0.19+ | Local model serving |

### Accounts

- GitHub personal access token (repo scope)
- Anthropic API key (Claude Opus for planning)

### Environment Variables

```bash
export ANTHROPIC_API_KEY="sk-ant-..."
export GITHUB_TOKEN="ghp_..."
export OLLAMA_MLX=1                    # Enable Apple Silicon backend
export OLLAMA_KEEP_ALIVE=30m           # Keep models resident
```

---

## 3. Daily Operations

### Morning Review (15 minutes)

```bash
# Check Ollama status
ollama list                          # Both models should show
curl http://localhost:11434/v1/models  # API should respond

# Check active sessions
python3 scripts/orchestrator.py --list-sessions

# Review overnight runs
ls -la /var/agor/artifacts/          # Check for new artifacts
ls -la /var/agor/logs/               # Check for errors

# Check failed sessions
python3 scripts/orchestrator.py --failed-sessions
```

### Starting the System

```bash
# 1. Start Ollama (if not running)
OLLAMA_MLX=1 OLLAMA_KEEP_ALIVE=30m ollama serve &

# 2. Verify models
ollama list                          # Should show devstral:24b and lite:16b

# 3. Start Agor daemon
agor daemon start

# 4. Verify connectivity
curl http://localhost:3030/health    # Agor health check
curl http://localhost:11434/v1/models  # Ollama health check

# 5. Check Docker
docker network inspect agor-isolated  # Network should exist
docker images | grep agor-executor    # Image should exist
```

### Stopping the System

```bash
# Graceful shutdown
agor daemon stop                     # Stop Agor
pkill -f "ollama serve"             # Stop Ollama

# Check no active sessions
python3 scripts/orchestrator.py --list-sessions
# If active sessions exist, wait or abort them
```

### Monitoring

| Metric | Command | Healthy |
|--------|---------|---------|
| Ollama API | `curl http://localhost:11434/v1/models` | 200 OK |
| Agor daemon | `curl http://localhost:3030/health` | 200 OK |
| Disk space | `df -h /var/agor` | >20% free |
| Memory | `vm_stat` or `memory_pressure` | <80% used |
| Active sessions | `orchestrator.py --list-sessions` | ≤ max allowed |

### Log Locations

| Component | Path | Rotation |
|-----------|------|----------|
| Agor | `~/.agor/logs/` | 7 days |
| Ollama | `~/.ollama/server.log` | Manual |
| Orchestrator | `/var/agor/logs/` | 30 days |
| Audit | `/var/agor/audit/` | 90 days |
| Sessions | `/var/agor/sessions.jsonl` | Archive after 30 days |

---

## 4. Incident Response

### Session Stuck / Killed

**Symptoms:** Session status stuck in RUNNING for >10 minutes, no output

**Diagnosis:**
```bash
# Check if container is still running
docker ps | grep agor-exec

# Check container logs
docker logs <container_id>

# Check process in container
docker exec <container_id> ps aux

# Check if Ollama is responding
curl http://localhost:11434/v1/models
```

**Resolution:**
```bash
# Force stop container
docker stop <container_id>
docker rm <container_id>

# Update session status
python3 scripts/orchestrator.py --abort-session <session_id>

# Clean up worktree
./scripts/agor-worktree.sh cleanup /var/repos/agor-<ticket>
```

### Container Escape Suspected

> **CRITICAL:** This is a security incident.

**Symptoms:** Unexpected processes on host, network connections from container, files modified outside worktree

**Immediate containment:**
```bash
# Stop ALL containers immediately
docker stop $(docker ps -q --filter "name=agor-exec")

# Inspect container
docker inspect <container_id>
docker logs <container_id> > /tmp/incident-logs.txt

# Check for host modifications
find / -newer /tmp/marker -not -path '/proc/*' -not -path '/sys/*' 2>/dev/null

# Preserve evidence
cp /var/agor/sessions.jsonl /tmp/incident-sessions.jsonl
tar czf /tmp/incident-artifacts.tar.gz /var/agor/artifacts/
```

**Recovery:**
```bash
# Destroy and recreate network
./scripts/network-setup.sh destroy
./scripts/network-setup.sh create

# Review audit logs
grep "AGOR_BLOCKED" /var/log/syslog  # Check for blocked egress attempts
```

### Ollama Server Down

**Symptoms:** `curl http://localhost:11434/v1/models` returns connection refused

**Diagnosis:**
```bash
# Check if Ollama process is running
pgrep -f "ollama serve"

# Check Ollama logs
tail -50 ~/.ollama/server.log

# Check memory pressure
memory_pressure
vm_stat

# Check disk space
df -h ~/.ollama/models/
```

**Resolution:**
```bash
# Restart Ollama
pkill -f "ollama serve"
sleep 2
OLLAMA_MLX=1 OLLAMA_KEEP_ALIVE=30m ollama serve &
sleep 5
curl http://localhost:11434/v1/models  # Verify

# If models are missing, re-pull
ollama pull devstral:24b
ollama pull deepseek-coder-v2-lite:16b
```

**Common causes:**
| Cause | Fix |
|-------|-----|
| Out of memory | Close other apps, restart Ollama |
| Model corrupted | `ollama rm <model> && ollama pull <model>` |
| Port conflict | Check `lsof -i :11434` |
| Disk full | Clean up `~/.ollama/models/` or expand storage |

### Model Not Loaded / Slow First Request

**Symptoms:** First request after Ollama start takes 30-60 seconds

**Cause:** Ollama lazy-loads models on first request. With `OLLAMA_KEEP_ALIVE`, models stay resident after first load.

**Resolution:**
```bash
# Pre-load both models after starting Ollama
curl http://localhost:11434/v1/chat/completions \
  -d '{"model":"devstral:24b","messages":[{"role":"user","content":"Hi"}],"max_tokens":1}'

curl http://localhost:11434/v1/chat/completions \
  -d '{"model":"deepseek-coder-v2-lite:16b","messages":[{"role":"user","content":"Hi"}],"max_tokens":1}'

# Verify both loaded
ollama ps  # Shows currently loaded models
```

### Secret Exposure

> **CRITICAL:** Rotate all potentially exposed credentials.

**Symptoms:** Secret found in logs, PR description, or test output

**Response:**
```bash
# 1. Scan for exposed secrets
grep -r "ghp_\|sk-ant-\|AKIA" /var/agor/logs/ /var/agor/artifacts/

# 2. Rotate exposed credentials
# GitHub: https://github.com/settings/tokens → Regenerate
# Anthropic: https://console.anthropic.com/ → New key

# 3. Update environment
export GITHUB_TOKEN="ghp_NEW_TOKEN"
export ANTHROPIC_API_KEY="sk-ant-NEW_KEY"

# 4. Review secret injection mechanism
# Verify tmpfs is being used (not env vars in logs)
grep "AGOR_SECRETS_FILE" /var/agor/logs/
```

### Test Flakiness

**Symptoms:** Same test passes sometimes, fails others

**Policy:**
- First failure: retry once automatically
- Second failure: retry once more (total 2 retries)
- Third failure: mark as FAILED, require human review

**Identification:**
```bash
# Check if failures are consistent
python3 scripts/orchestrator.py --session-history <ticket>
# Look for patterns: same test failing intermittently
```

---

## 5. Recovery Procedures

### Full Restart from Stopped State

```bash
#!/bin/bash
# full-restart.sh

set -e

echo "=== Agor Full Restart ==="

# 1. Verify prerequisites
docker --version
ollama --version
node --version
python3 --version

# 2. Start Ollama
OLLAMA_MLX=1 OLLAMA_KEEP_ALIVE=30m ollama serve &
sleep 5
curl -s http://localhost:11434/v1/models > /dev/null && echo "Ollama OK"

# 3. Start Agor
agor daemon start
sleep 2
curl -s http://localhost:3030/health > /dev/null && echo "Agor OK"

# 4. Verify network
./scripts/network-setup.sh status

# 5. Verify executor image
docker images | grep agor-executor || {
    echo "Building executor image..."
    docker build -f configs/Dockerfile.executor -t agor-executor:latest .
}

echo "=== Restart Complete ==="
```

### Worktree Cleanup After Crash

```bash
# List all worktrees
./scripts/agor-worktree.sh list

# Clean up stale worktrees (no active session)
for wt in /var/repos/agor-*; do
    [[ -d "$wt" ]] || continue
    # Check if session is active
    session_id=$(basename "$wt" | sed 's/agor-//')
    if ! python3 scripts/orchestrator.py --is-active "$session_id" 2>/dev/null; then
        echo "Cleaning up stale worktree: $wt"
        ./scripts/agor-worktree.sh cleanup "$wt" || rm -rf "$wt"
    fi
done
```

### Session Database Recovery

```bash
# Backup current sessions
cp /var/agor/sessions.jsonl /var/agor/sessions.jsonl.bak.$(date +%s)

# If corrupted, restore from backup
# (You should have automated backups)

# Or start fresh (all history lost)
mv /var/agor/sessions.jsonl /var/agor/sessions.jsonl.corrupted.$(date +%s)
touch /var/agor/sessions.jsonl
```

---

## 6. Troubleshooting Guide

### Issue 1: "Ollama connection refused"

```bash
# Diagnosis
curl http://localhost:11434/v1/models
# → curl: (7) Failed to connect

# Fixes
pgrep -f "ollama serve" || echo "Ollama not running"
OLLAMA_MLX=1 ollama serve &
# Wait 10 seconds, retry
```

### Issue 2: "Model devstral:24b not found"

```bash
# Check available models
ollama list

# Pull missing model
ollama pull devstral:24b

# If pull fails (network), check connectivity
curl -I https://ollama.com
```

### Issue 3: "Container fails to start"

```bash
# Check Docker daemon
docker info

# Check network exists
docker network inspect agor-isolated

# Check image exists
docker images | grep agor-executor

# Manual test
docker run --rm --network agor-isolated agor-executor:latest codex --version
```

### Issue 4: "Executor times out"

```bash
# Check if Ollama is responding slowly
time curl -s http://localhost:11434/v1/chat/completions \
  -d '{"model":"devstral:24b","messages":[{"role":"user","content":"test"}],"max_tokens":10}'

# If >30s, Ollama may be swapping
# Check memory
vm_stat | grep "pageouts"  # High pageouts = swapping

# Fix: Close other apps or use Lite model for current task
```

### Issue 5: "Tests not found"

```bash
# Manual discovery
./scripts/test-discovery.sh /var/repos/agor-<ticket>

# Check project structure
ls -la /var/repos/agor-<ticket>/
cat /var/repos/agor-<ticket>/package.json 2>/dev/null || true
cat /var/repos/agor-<ticket>/pyproject.toml 2>/dev/null || true

# Add custom test commands to policy.yaml if needed
```

### Issue 6: "PR creation failed"

```bash
# Check GitHub token
export GITHUB_TOKEN="ghp_..."
curl -H "Authorization: token $GITHUB_TOKEN" https://api.github.com/user

# Check remote URL in worktree
cd /var/repos/agor-<ticket>
git remote -v

# Check branch exists
git branch | grep agor/
```

### Issue 7: "Policy validation failed"

```bash
# Check the plan
python3 -c "
import json
with open('/tmp/plan.json') as f:
    plan = json.load(f)
    print(json.dumps(plan, indent=2))
"

# Check policy
python3 scripts/policy_engine.py --validate /tmp/plan.json

# If false positive, update policy.yaml
```

### Issue 8: "MLX backend not activating"

```bash
# Check macOS version
sw_vers -productVersion  # Should be 14+

# Check Apple Silicon
uname -m  # Should be arm64

# Verify MLX is enabled
launchctl getenv OLLAMA_MLX  # Should be 1

# Check Ollama logs for MLX messages
grep -i "mlx" ~/.ollama/server.log

# Fix: Explicitly set environment
export OLLAMA_MLX=1
launchctl setenv OLLAMA_MLX 1
```

### Issue 9: "Wrong model selected for task"

```bash
# Check which model was used
python3 scripts/orchestrator.py --session <id>
# Look for "model_used" field

# Override manually for specific task
codex --model deepseek-coder-v2-lite:16b --profile fast
# or
codex --model devstral:24b --profile unattended
```

### Issue 10: "Out of memory during execution"

```bash
# Check current memory usage
memory_pressure  # Should be NORMAL

# Check loaded models
ollama ps  # Shows memory per model

# If both models loaded + Docker, may exceed 32GB
# Solution: Use only one model at a time
# Stop Ollama, start with single model:
OLLAMA_MAX_LOADED_MODELS=1 ollama serve
```

---

## 7. Security Checklist

### Weekly Verification

```bash
#!/bin/bash
# security-check.sh — Run weekly

echo "=== Security Checklist ==="

# 1. Verify isolation
docker network inspect agor-isolated --format '{{.Internal}}' | grep true && echo "[OK] Network internal" || echo "[FAIL] Network not internal"

# 2. Check no secrets in logs
grep -r "ghp_\|sk-ant-\|AKIA" /var/agor/logs/ && echo "[FAIL] Secrets in logs" || echo "[OK] No secrets in logs"

# 3. Verify tmpfs secret injection
mount | grep "agor-secrets" && echo "[OK] Secrets on tmpfs" || echo "[WARN] No active secret mounts"

# 4. Check audit logs
ls -la /var/agor/audit/ | wc -l | xargs -I {} echo "[INFO] {} audit log files"

# 5. Check container security
docker inspect agor-executor:latest --format '{{.Config.User}}' | grep -v root && echo "[OK] Non-root user" || echo "[WARN] Image uses root"

# 6. Verify model integrity
ollama list | grep devstral && echo "[OK] Primary model" || echo "[FAIL] Primary model missing"
ollama list | grep lite && echo "[OK] Fast model" || echo "[FAIL] Fast model missing"

echo "=== Check Complete ==="
```

---

## 8. Quick Reference

### Commands

| Task | Command |
|------|---------|
| Start Ollama | `OLLAMA_MLX=1 OLLAMA_KEEP_ALIVE=30m ollama serve &` |
| List models | `ollama list` |
| Check loaded | `ollama ps` |
| Start Agor | `agor daemon start` |
| Create worktree | `./scripts/agor-worktree.sh create <repo> <ticket>` |
| Run tests | `./scripts/test-runner.sh all <worktree>` |
| Launch container | `./scripts/container-launcher.sh <worktree>` |
| Check sessions | `python3 scripts/orchestrator.py --list-sessions` |
| Network status | `./scripts/network-setup.sh status` |

### Key Files

| File | Purpose |
|------|---------|
| `~/.codex/config.toml` | Codex CLI configuration |
| `~/.agor/config.yaml` | Agor orchestrator configuration |
| `configs/policy.yaml` | Security policy rules |
| `/var/agor/sessions.jsonl` | Session database |
| `/var/agor/artifacts/` | Test artifacts |
| `/var/agor/logs/` | Execution logs |
| `~/.ollama/server.log` | Ollama server logs |

### Emergency Contacts

| Issue | Escalation |
|-------|-----------|
| Security incident | Security team + disable Agor daemon |
| Credential exposure | Rotate immediately, notify security |
| Data breach | Follow incident response playbook |
| System outage | Check status page, engage on-call |

---

*Runbook version 2.0 — Ollama dual-model edition*
*For the previous DS4-based version, see git history*

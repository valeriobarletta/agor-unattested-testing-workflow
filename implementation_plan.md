# Implementation Plan: Agor Unattended Testing Workflow

**Version:** 2.0 (Ollama Edition)  
**Date:** July 15, 2026  
**Timeline:** 2-3 weeks MVP | 8-12 weeks production  
**Team:** 2 engineers (MVP) | 3-4 engineers (production)

---

## Table of Contents

1. [Phase 1: Foundation (Days 1-3)](#phase-1-foundation-days-1-3)
2. [Phase 2: Isolation (Days 4-6)](#phase-2-isolation-days-4-6)
3. [Phase 3: Testing (Days 7-10)](#phase-3-testing-days-7-10)
4. [Phase 4: Integration (Days 11-14)](#phase-4-integration-days-11-14)
5. [Implementation Timeline](#implementation-timeline)
6. [Risk Register](#risk-register)

---

## Phase 1: Foundation (Days 1-3)

**Goal:** All core components installed, connected, and verified.

### Day 1: Hardware & Ollama Setup

**Morning (4 hours):**

```bash
# 1. Verify hardware
system_profiler SPHardwareDataType | grep "Memory"
# Expected: 32 GB or higher

# 2. Install Ollama
curl -fsSL https://ollama.com/install.sh | sh
ollama --version

# 3. Start Ollama with MLX
export OLLAMA_MLX=1
export OLLAMA_KEEP_ALIVE=30m
export OLLAMA_MAX_LOADED_MODELS=2
ollama serve &
sleep 5

# 4. Pull models
ollama pull devstral:24b
ollama pull deepseek-coder-v2-lite:16b

# 5. Verify
curl http://localhost:11434/v1/models
ollama ps
```

**Afternoon (4 hours):**

```bash
# 6. Install Agor
npm install -g agor-live
agor init
agor daemon start

# 7. Verify Agor
curl http://localhost:3030/health

# 8. Install Codex CLI
npm install -g @openai/codex
codex --version

# 9. Configure Codex CLI
cat > ~/.codex/config.toml << 'EOF'
model = "devstral:24b"
model_provider = "ollama"

[model_providers.ollama]
name = "Ollama"
base_url = "http://localhost:11434/v1"
wire_api = "responses"

[profiles.unattended]
model = "devstral:24b"
approval_policy = "never"
sandbox_mode = "workspace-write"
network_access = false

[profiles.fast]
model = "deepseek-coder-v2-lite:16b"
approval_policy = "never"
sandbox_mode = "workspace-write"
EOF
```

**Day 1 Verification:**

```bash
# All should succeed:
curl http://localhost:11434/v1/models
curl http://localhost:3030/health
codex --model devstral:24b --approval never -- echo "test"
```

### Day 2: Docker & Network Setup

```bash
# 1. Verify Docker
docker --version
docker info

# 2. Create isolated network
./scripts/network-setup.sh create

# 3. Verify network
docker network inspect agor-isolated | grep '"Internal": true'

# 4. Build executor image
docker build -f configs/Dockerfile.executor -t agor-executor:latest .

# 5. Test executor container
docker run --rm --network agor-isolated agor-executor:latest codex --version

# 6. Verify Ollama access from container
docker run --rm --network agor-isolated \
  --env OLLAMA_HOST=http://host.docker.internal:11434 \
  agor-executor:latest sh -c '
    curl -s http://host.docker.internal:11434/v1/models
  '
```

### Day 3: End-to-End Connectivity

```bash
# 1. Configure Agor
cp configs/agor_config.yaml ~/.agor/config.yaml

# 2. Full connectivity test
# Test: Cloud planner → Agor → Codex → Ollama → Response
python3 << 'PYEOF'
import subprocess, json, os

# Verify all endpoints
endpoints = {
    "Ollama": "http://localhost:11434/v1/models",
    "Agor": "http://localhost:3030/health",
}

all_ok = True
for name, url in endpoints.items():
    result = subprocess.run(
        ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", url],
        capture_output=True, text=True
    )
    status = "OK" if result.stdout.strip() == "200" else "FAIL"
    if status == "FAIL":
        all_ok = False
    print(f"  {name}: {status}")

# Test Ollama chat completion
result = subprocess.run([
    "curl", "-s", "http://localhost:11434/v1/chat/completions",
    "-H", "Content-Type: application/json",
    "-d", json.dumps({
        "model": "devstral:24b",
        "messages": [{"role": "user", "content": "Say 'connected'"}],
        "max_tokens": 10
    })
], capture_output=True, text=True)

try:
    response = json.loads(result.stdout)
    content = response["choices"][0]["message"]["content"]
    print(f"  Ollama chat: OK ('{content.strip()}')")
except Exception as e:
    print(f"  Ollama chat: FAIL ({e})")
    all_ok = False

if all_ok:
    print("\nAll connectivity checks passed!")
else:
    print("\nSome checks failed. Review logs above.")
    exit(1)
PYEOF
```

**Phase 1 Exit Criteria:**
- [ ] Ollama running with both models loaded
- [ ] Agor daemon responding
- [ ] Codex CLI connecting to Ollama
- [ ] Docker network created
- [ ] Executor image built
- [ ] Container can reach Ollama via host.docker.internal

---

## Phase 2: Isolation (Days 4-6)

**Goal:** Secure execution environment with hardened containers and network isolation.

### Day 4: Worktree Security

```bash
# 1. Create test worktree
mkdir -p /var/repos
./scripts/agor-worktree.sh create /path/to/test-repo TEST-001

# 2. Verify isolation
cd /var/repos/agor-test-001
git config --list --local | grep hooksPath   # Should be /dev/null
git config --list --local | grep credential  # Should be empty

# 3. Test path validation
./scripts/agor-worktree.sh validate /var/repos/agor-test-001
# Expected: VALID: /var/repos/agor-test-001

./scripts/agor-worktree.sh validate /etc/passwd
# Expected: Error (outside authorized root)

# 4. Test cleanup
./scripts/agor-worktree.sh cleanup /var/repos/agor-test-001
# Verify removed
ls /var/repos/agor-test-001 2>/dev/null || echo "Cleaned up successfully"
```

### Day 5: Container Hardening

```bash
# 1. Test hardened container launch
mkdir -p /var/repos/test-worktree
git init /var/repos/test-worktree

./scripts/container-launcher.sh /var/repos/test-worktree

# 2. Verify security from inside container
docker exec <container_id> sh -c '
  # Check user
  id  # Should be uid 1000 (codex), not root
  
  # Check capabilities
  cat /proc/self/status | grep Cap  # Should be 0
  
  # Check filesystem
  touch /root/test 2>&1 || echo "Root is read-only or null-mounted"
  
  # Check network
  ping -c 1 8.8.8.8 2>&1 || echo "Network is isolated"
  
  # Check SSH
  ls -la ~/.ssh 2>&1 || echo "SSH directory is null-mounted"
  
  # Check Ollama access
  curl -s http://host.docker.internal:11434/v1/models | head -c 100
'

# 3. Verify resource limits
docker stats --no-stream <container_id>
# Check: CPU ≤ 200%, Memory ≤ 2GiB
```

### Day 6: Network Lockdown

```bash
# 1. Verify network rules
./scripts/network-setup.sh status

# 2. Test egress blocking
docker run --rm --network agor-isolated alpine ping -c 1 google.com
# Expected: bad address or network unreachable

# 3. Test allowed domains (if configured)
docker run --rm --network agor-isolated alpine nslookup registry.npmjs.org
# Expected: Should resolve (if in allowlist)

# 4. Verify iptables logs
dmesg | grep AGOR_BLOCKED | tail -5
```

**Phase 2 Exit Criteria:**
- [ ] Worktree creation with Git isolation
- [ ] Container runs as non-root user
- [ ] All capabilities dropped
- [ ] No access to host filesystem except worktree
- [ ] Network egress blocked by default
- [ ] Ollama accessible from container
- [ ] Resource limits enforced

---

## Phase 3: Testing (Days 7-10)

**Goal:** Test discovery, execution, and artifact collection working for all project types.

### Day 7: Test Discovery

```bash
# Test with Node.js project
mkdir -p /tmp/test-node && cd /tmp/test-node
cat > package.json << 'EOF'
{
  "name": "test-project",
  "scripts": {
    "test": "jest",
    "test:integration": "jest --config jest.integration.config.js",
    "lint": "eslint .",
    "build": "tsc"
  }
}
EOF

../../scripts/test-discovery.sh /tmp/test-node
# Expected: project_type=node, unit_tests=["npm test -- --coverage"]

# Test with Python project
mkdir -p /tmp/test-python && cd /tmp/test-python
cat > pyproject.toml << 'EOF'
[tool.pytest.ini_options]
testpaths = ["tests"]
EOF
mkdir tests
touch tests/__init__.py

../../scripts/test-discovery.sh /tmp/test-python
# Expected: project_type=python, unit_tests=["pytest --cov=..."]
```

### Day 8: Test Execution

```bash
# Create a real Node.js project with tests
mkdir -p /tmp/test-real && cd /tmp/test-real
npm init -y
npm install jest --save-dev

# Add a simple test
cat > sum.js << 'EOF'
function sum(a, b) { return a + b; }
module.exports = sum;
EOF

cat > sum.test.js << 'EOF'
const sum = require('./sum');
test('adds 1 + 2 to equal 3', () => {
  expect(sum(1, 2)).toBe(3);
});
EOF

# Run test discovery
../../scripts/test-discovery.sh /tmp/test-real

# Run tests
../../scripts/test-runner.sh all /tmp/test-real /tmp/test-artifacts

# Check artifacts
ls -la /tmp/test-artifacts/
cat /tmp/test-artifacts/test-report.json
```

### Day 9: Artifact Collection

```bash
# Verify artifact structure
python3 << 'PYEOF'
import json
from pathlib import Path

artifacts = Path("/tmp/test-artifacts")
report = json.loads((artifacts / "test-report.json").read_text())

print("Test Report Summary:")
print(f"  Overall: {report['overall_status']}")
for layer, results in report.get("layers", {}).items():
    status = results.get("status", "unknown")
    print(f"  {layer}: {status}")

# Verify coverage collection
if (artifacts / "coverage").exists():
    print("  Coverage: collected")
else:
    print("  Coverage: not collected (may need coverage tool)")
PYEOF
```

### Day 10: Policy Engine

```bash
# Test plan validation
python3 << 'PYEOF'
from scripts.policy_engine import PolicyEngine, create_default_policy, ValidationResult

policy = create_default_policy()
engine = PolicyEngine(policy)

# Valid plan
valid_plan = {
    "plan_id": "test-001",
    "steps": [
        {"action": "modify_file", "target": "/workspace/src/utils.js", "description": "Add helper"}
    ],
    "security_context": {"network_access": False, "max_files": 5},
    "new_dependencies": [],
    "acceptance_criteria": ["Tests pass"]
}

result = engine.validate_plan(valid_plan)
print(f"Valid plan: {'PASS' if result.passed else 'FAIL'}")

# Invalid plan (forbidden path)
invalid_plan = {
    "plan_id": "test-002",
    "steps": [
        {"action": "modify_file", "target": "/workspace/.github/workflows/ci.yml", "description": "Edit CI"}
    ],
    "security_context": {"network_access": True}
}

result = engine.validate_plan(invalid_plan)
print(f"Invalid plan: {'PASS' if result.passed else 'FAIL'} ({len(result.violations)} violations)")
for v in result.violations:
    print(f"  - {v.rule}: {v.message}")
PYEOF
```

**Phase 3 Exit Criteria:**
- [ ] Test discovery works for Node.js, Python, Rust
- [ ] Test runner executes tests and collects results
- [ ] Artifacts stored with proper structure
- [ ] Policy engine validates plans correctly
- [ ] Invalid plans are rejected with clear violations

---

## Phase 4: Integration (Days 11-14)

**Goal:** Full end-to-end workflow working with GitHub integration.

### Day 11: Orchestrator Deployment

```bash
# 1. Set environment variables
export ANTHROPIC_API_KEY="sk-ant-..."
export GITHUB_TOKEN="ghp_..."

# 2. Configure Python path
export PYTHONPATH="$(pwd)/scripts:$PYTHONPATH"

# 3. Test orchestrator components
python3 -c "
from scripts.config import load_config, ModelRole
from scripts.policy_engine import create_default_policy
from scripts.session_manager import SessionManager

config = load_config('configs/agor_config.yaml')
print(f'Primary model: {config.ollama.primary_model}')
print(f'Fast model: {config.ollama.fast_model}')

# Test model selection
role = ModelRole.from_task(2, 0)
print(f'Simple task model: {role.value}')

role = ModelRole.from_task(5, 1)
print(f'Complex task model: {role.value}')
"
```

### Day 12: GitHub Webhook

```bash
# 1. Create GitHub webhook payload test
cat > /tmp/webhook-test.json << 'EOF'
{
  "action": "opened",
  "issue": {
    "number": 123,
    "title": "Add user authentication",
    "body": "Implement JWT-based authentication for the API endpoints."
  },
  "repository": {
    "full_name": "my-org/my-repo"
  }
}
EOF

# 2. Test webhook handling
curl -X POST http://localhost:3030/webhooks/github \
  -H "Content-Type: application/json" \
  -H "X-GitHub-Event: issues" \
  -d @/tmp/webhook-test.json

# 3. Verify ticket was ingested
# (Check Agor logs or session manager)
```

### Day 13: Full Workflow Test

```bash
# Manual end-to-end test with a real ticket

# 1. Create a simple test repository
mkdir -p /tmp/e2e-test && cd /tmp/e2e-test
git init
cat > hello.js << 'EOF'
function hello() { return "world"; }
module.exports = hello;
EOF
git add . && git commit -m "init"

# 2. Run workflow
python3 scripts/orchestrator.py \
  --config configs/agor_config.yaml \
  --ticket "E2E-001" \
  --content "Add a goodbye function to hello.js" \
  --verbose 2>&1 | tee /tmp/e2e-output.log

# 3. Check results
echo "=== Workflow Output ==="
tail -50 /tmp/e2e-output.log
```

### Day 14: Monitoring & Runbook

```bash
# 1. Set up log rotation
sudo tee /etc/logrotate.d/agor << 'EOF'
/var/agor/logs/*.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 644 root root
}
EOF

# 2. Test health checks
./scripts/setup-host.sh --check-only

# 3. Verify session database
python3 -c "
from scripts.session_manager import SessionManager
sm = SessionManager('/var/agor/sessions.jsonl')
active = sm.list_active_sessions()
print(f'Active sessions: {len(active)}')
for s in active:
    print(f'  {s.session_id}: {s.ticket_ref} ({s.status.value})')
"

# 4. Run security checklist
grep -A 50 "Security Checklist" runbook.md
```

**Phase 4 Exit Criteria:**
- [ ] Orchestrator loads configuration correctly
- [ ] Full workflow executes without errors
- [ ] GitHub webhook ingests tickets
- [ ] Draft PR created with test evidence
- [ ] Human review gate enforced (no auto-merge)
- [ ] Monitoring and logging configured
- [ ] Runbook verified by operator

---

## Implementation Timeline

### Gantt Chart (Text)

```
Week 1:
  Day 1-3  [██████] Phase 1: Foundation
  Day 4-6  [██████] Phase 2: Isolation

Week 2:
  Day 7-10 [████████] Phase 3: Testing
  Day 11-14[████████] Phase 4: Integration

Week 3:
  Day 15-21[████████████] Pilot: 3 low-risk tickets
```

### Dependencies

```
Phase 1 (Foundation)
  ├── Ollama install → Model pull → API verify
  ├── Agor install → Daemon start → Health check
  ├── Codex CLI install → Config → Ollama test
  └── Docker setup → Network create → Image build

Phase 2 (Isolation)
  ├── Worktree script → Path validation → Git isolation
  ├── Container launcher → Security verify → Ollama access
  └── Network setup → Egress test → Firewall verify
       ↑
  Depends on Phase 1

Phase 3 (Testing)
  ├── Test discovery → All project types
  ├── Test runner → Execute → Collect artifacts
  └── Policy engine → Validate → Reject invalid
       ↑
  Depends on Phase 2

Phase 4 (Integration)
  ├── Orchestrator → All components
  ├── GitHub webhook → Ticket ingest
  └── Full E2E → Pilot tickets
       ↑
  Depends on Phase 3
```

---

## Risk Register

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|------------|
| Ollama model OOM on 32GB | Medium | High | Use single model, close other apps, add swap |
| MLX backend not working | Low | High | Fallback to standard Ollama backend |
| Docker Desktop not available | Low | Medium | Use Colima or podman as alternative |
| Codex CLI compatibility issue | Low | High | Test with specific version, report issue |
| Agor daemon instability | Low | Medium | Restart script, health check monitoring |
| Network isolation bypass | Low | Critical | iptables audit, gVisor upgrade path |
| Secret exposure in logs | Medium | High | Secret scanning, log rotation, audit |
| Test flakiness causing false failures | Medium | Medium | Retry logic, baseline comparison |
| Cloud planner API rate limit | Low | Medium | Retry with backoff, cache plans |
| Human reviewer availability | Medium | High | Batch reviews, clear guidelines |

---

*This plan assumes a 2-engineer team working full-time. Adjust timeline proportionally for part-time effort.*

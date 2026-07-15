# Integration Guide: Agor Unattended Testing Workflow

**Version:** 2.0 (Ollama Edition)  
**Date:** July 15, 2026  
**Audience:** DevOps engineers setting up the workflow

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Prerequisites](#2-prerequisites)
3. [Component Installation](#3-component-installation)
4. [Configuration](#4-configuration)
5. [Integration Testing](#5-integration-testing)
6. [GitHub/Jira Integration](#6-githubjira-integration)
7. [Security Hardening](#7-security-hardening)
8. [Customization](#8-customization)
9. [Known Limitations](#9-known-limitations)
10. [Migration Notes](#10-migration-notes)

---

## 1. Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                        HOST (macOS, 32GB+)                          │
│                                                                     │
│  ┌──────────────┐    ┌──────────────────────────────────────┐     │
│  │ Agor Daemon  │    │ Ollama Server (MLX Backend)          │     │
│  │  (Node.js)   │    │  localhost:11434                      │     │
│  │  port 3030   │    │                                     │     │
│  └──────┬───────┘    │  ┌──────────────┐ ┌──────────────┐ │     │
│         │             │  │ devstral:24b │ │ lite:16b     │ │     │
│         │             │  │ ~14GB Q4     │ │ ~9GB Q4      │ │     │
│         │             │  │ 35-50 tok/s  │ │ 60-80 tok/s  │ │     │
│         │             │  └──────────────┘ └──────────────┘ │     │
│         │             └──────────────────────────────────────┘     │
│         │                            ▲                              │
│         │                    OpenAI API                            │
│         │                    (/v1/chat/completions)                │
│         ▼                            │                              │
│  ┌──────────────────────────────────────────────────────────────┐ │
│  │                   Docker Executor Container                    │ │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐    │ │
│  │  │ Codex CLI │─▶│ Git      │  │ Test     │  │ Artifact │    │ │
│  │  │ (Rust)   │  │ Worktree │  │ Runner   │  │ Collector│    │ │
│  │  └──────────┘  └──────────┘  └──────────┘  └──────────┘    │ │
│  │                      │                                        │ │
│  │              Isolated Network (agor-isolated)                  │ │
│  └──────────────────────────────────────────────────────────────┘ │
│                                                                     │
│  ┌──────────────────────────────────────────────────────────────┐ │
│  │ Cloud Services                                                │ │
│  │  • Claude Opus (plan generation)                              │ │
│  │  • GitHub API (PR creation)                                   │ │
│  └──────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 2. Prerequisites

### Hardware Requirements

| Component | Minimum | Recommended |
|-----------|---------|-------------|
| Mac | M2 Pro 32GB | M3 Max 36GB+ or M4 Pro 48GB |
| Storage | 100GB free | 200GB free SSD |
| Network | Internet for setup | Always-on for webhooks |

### Software Requirements

| Tool | Version | Install Command |
|------|---------|-----------------|
| macOS | 14+ | System Preferences |
| Docker Desktop | 4.30+ | `brew install --cask docker` |
| Node.js | 22.12+ | `n 22` or `brew install node@22` |
| Python | 3.11+ | `brew install python@3.11` |
| Git | 2.40+ | `brew install git` |

### Account Requirements

- **GitHub:** Personal access token with `repo` scope
- **Anthropic:** API key for Claude Opus

---

## 3. Component Installation

### 3.1 Install Ollama

Ollama is the local model server. It must be installed first since other components depend on it.

```bash
# One-line install
curl -fsSL https://ollama.com/install.sh | sh

# Verify installation
ollama --version
# Expected: ollama version 0.19.0 or higher
```

**Start Ollama with MLX backend (Apple Silicon):**

```bash
# Set environment variables
export OLLAMA_MLX=1
export OLLAMA_KEEP_ALIVE=30m
export OLLAMA_MAX_LOADED_MODELS=2

# Start server in background
ollama serve &

# Wait for ready
sleep 5
curl http://localhost:11434/v1/models
```

**Pull both models:**

```bash
# Primary model: Devstral 24B (complex tasks)
ollama pull devstral:24b

# Fast model: DeepSeek-Coder-V2-Lite 16B (quick fixes)
ollama pull deepseek-coder-v2-lite:16b

# Verify both models
ollama list
# Expected output:
# NAME                            ID              SIZE    MODIFIED
# devstral:24b                    xxx...          14 GB   1 minute ago
# deepseek-coder-v2-lite:16b      xxx...          9.0 GB  1 minute ago
```

**Pre-load models (avoid first-request delay):**

```bash
# Warm up both models
curl -s http://localhost:11434/v1/chat/completions \
  -d '{"model":"devstral:24b","messages":[{"role":"user","content":"Hi"}],"max_tokens":1}'

curl -s http://localhost:11434/v1/chat/completions \
  -d '{"model":"deepseek-coder-v2-lite:16b","messages":[{"role":"user","content":"Hi"}],"max_tokens":1}'

# Verify loaded
ollama ps
```

### 3.2 Install Agor

```bash
# Install Agor CLI globally
npm install -g agor-live

# Verify
agor --version

# Initialize configuration
agor init

# This creates:
# ~/.agor/           # Config directory
# ~/.agor/config.yaml
# ~/.agor/agor.db    # SQLite database
```

**Start Agor daemon:**

```bash
# Start daemon
agor daemon start

# Verify health
curl http://localhost:3030/health
# Expected: {"status":"ok"}
```

### 3.3 Install Codex CLI

```bash
# Install via npm
npm install -g @openai/codex

# Verify
codex --version
```

### 3.4 Install Python Dependencies

```bash
# Install orchestrator dependencies
pip install pyyaml requests jsonschema

# For development
pip install pytest mypy ruff
```

### 3.5 Configure Docker

```bash
# Create isolated Docker network
./scripts/network-setup.sh create

# Verify
docker network inspect agor-isolated

# Build executor image
docker build -f configs/Dockerfile.executor -t agor-executor:latest .

# Verify
docker images | grep agor-executor
```

---

## 4. Configuration

### 4.1 Agor Configuration

Copy the config file:

```bash
cp configs/agor_config.yaml ~/.agor/config.yaml
```

**Key settings to verify:**

```yaml
# ~/.agor/config.yaml

security:
  mode: strict  # Must be strict for unattended workflows

daemon:
  port: 3030
  host: 127.0.0.1  # Localhost only

agents:
  - name: devstral-executor
    model: devstral:24b
    provider: ollama
    base_url: http://localhost:11434/v1

  - name: lite-executor
    model: deepseek-coder-v2-lite:16b
    provider: ollama
    base_url: http://localhost:11434/v1
```

### 4.2 Codex CLI Configuration

```bash
mkdir -p ~/.codex
cp configs/codex_config.toml ~/.codex/config.toml
```

**Key settings:**

```toml
# ~/.codex/config.toml
model = "devstral:24b"
model_provider = "ollama"

[model_providers.ollama]
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
```

### 4.3 Environment Variables

Add to `~/.zshrc` or `~/.bash_profile`:

```bash
# Agor workflow environment
export ANTHROPIC_API_KEY="sk-ant-api03-..."
export GITHUB_TOKEN="ghp_..."

# Ollama optimization
export OLLAMA_MLX=1
export OLLAMA_KEEP_ALIVE=30m
export OLLAMA_MAX_LOADED_MODELS=2
```

Then reload:

```bash
source ~/.zshrc  # or ~/.bash_profile
```

### 4.4 Policy Configuration

```bash
# Copy policy (customize as needed)
cp configs/policy.yaml /etc/agor/policy.yaml
# or
mkdir -p ~/.agor && cp configs/policy.yaml ~/.agor/policy.yaml
```

---

## 5. Integration Testing

### 5.1 Component Verification

**Test 1: Ollama connectivity**

```bash
curl -s http://localhost:11434/v1/models | python3 -m json.tool
# Expected: List including devstral:24b and deepseek-coder-v2-lite:16b
```

**Test 2: Ollama chat completion**

```bash
curl -s http://localhost:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "devstral:24b",
    "messages": [{"role": "user", "content": "Hello"}],
    "max_tokens": 10
  }' | python3 -c "import json,sys; print(json.load(sys.stdin)['choices'][0]['message']['content'])"
# Expected: A greeting response
```

**Test 3: Codex CLI with Ollama**

```bash
echo "Say hello briefly" | codex --model devstral:24b --approval never
# Expected: Brief greeting
```

**Test 4: Agor daemon health**

```bash
curl -s http://localhost:3030/health
# Expected: {"status":"ok"}
```

**Test 5: Docker network**

```bash
docker network inspect agor-isolated --format '{{.Internal}}'
# Expected: true
```

**Test 6: Worktree creation**

```bash
mkdir -p /var/repos
./scripts/agor-worktree.sh create /path/to/your/repo TEST-123
# Expected: SECURE_WORKTREE_PATH=/var/repos/agor-test-123
```

### 5.2 End-to-End Test

```bash
# 1. Create a test ticket
export TEST_TICKET="TEST-$(date +%s)"
export TEST_CONTENT="Add a simple hello function to the utils module"

# 2. Run the full workflow
python3 scripts/orchestrator.py \
  --config configs/agor_config.yaml \
  --ticket "$TEST_TICKET" \
  --content "$TEST_CONTENT" \
  --verbose

# 3. Verify output
# - Check PR was created
# - Check test artifacts exist
# - Verify no secrets in logs
```

---

## 6. GitHub/Jira Integration

### 6.1 GitHub Webhook

1. Go to **Repository Settings → Webhooks → Add webhook**
2. **Payload URL:** `http://your-server:3030/webhooks/github`
3. **Content type:** `application/json`
4. **Secret:** Set a strong secret, add to `GITHUB_WEBHOOK_SECRET` env var
5. **Events:** Select "Issues" and "Issue comments"

### 6.2 Jira Integration

1. Create API token at [id.atlassian.com](https://id.atlassian.com)
2. Add to environment:
   ```bash
   export JIRA_API_TOKEN="your-token"
   export JIRA_BASE_URL="https://your-domain.atlassian.net"
   export JIRA_PROJECT_KEY="PROJ"
   ```
3. Configure Agor webhook endpoint in Jira automation

---

## 7. Security Hardening

### 7.1 Network Isolation

```bash
# Verify network is internal only
docker network inspect agor-isolated | grep "Internal"

# Check iptables rules
sudo iptables -L AGOR_EGRESS -n --line-numbers

# Test egress is blocked
docker run --rm --network agor-isolated alpine ping -c 1 8.8.8.8
# Expected: Network unreachable
```

### 7.2 Secret Management

```bash
# Verify no secrets in environment
env | grep -i "token\|key\|secret" | grep -v "_=" 
# Should only show intentional env vars

# Test tmpfs secret injection
./scripts/container-launcher.sh /var/repos/agor-test-123
# Inside container, verify:
# ls -la /run/secrets/
# mount | grep secrets
```

### 7.3 Container Hardening Checklist

```bash
# Verify image security
docker inspect agor-executor:latest --format '{{.Config.User}}'
# Expected: codex (not root)

# Check capabilities
docker run --rm agor-executor:latest capsh --print 2>/dev/null || echo "No capsh"
# Expected: No capabilities

# Verify read-only
docker run --rm --read-only agor-executor:latest touch /tmp/test
# Expected: Success (tmpfs allows writes)
```

---

## 8. Customization

### 8.1 Adding New Project Types

Edit `scripts/test-discovery.sh` to add detection for new project types:

```bash
# Example: Add Go support
detect_go() {
    local root="$1"
    [[ ! -f "$root/go.mod" ]] && return 1
    
    echo '{
  "project_type": "go",
  "static_validation": ["go vet ./...", "gofmt -d ."],
  "unit_tests": ["go test -race -coverprofile=coverage.out ./..."],
  "integration_tests": [],
  "e2e_tests": [],
  "build": ["go build ./..."]
}'
    return 0
}
```

### 8.2 Modifying Policy Rules

Edit `configs/policy.yaml`:

```yaml
# Add allowed paths
allowed_paths:
  - /workspace/src
  - /workspace/tests
  - /workspace/api        # NEW

# Add allowed commands
allowed_commands:
  - go
  - golangci-lint         # NEW
```

### 8.3 Custom Test Commands

Override auto-discovery with explicit commands in the execution plan:

```json
{
  "test_commands": {
    "static_validation": ["custom-linter", "type-checker"],
    "unit_tests": ["test-runner --coverage"]
  }
}
```

### 8.4 Different Model Configuration

To use different models, update the config:

```toml
# ~/.codex/config.toml
[profiles.unattended]
model = "qwen3-coder:30b"  # Different primary model
```

And update the policy:

```yaml
# configs/policy.yaml
allowed_models:
  - qwen3-coder:30b
  - deepseek-coder-v2-lite:16b
```

---

## 9. Known Limitations

| Limitation | Impact | Workaround |
|------------|--------|------------|
| **MLX is Apple Silicon only** | Cannot use MLX on Intel Macs | Use standard Ollama backend (slower) |
| **32GB is tight for dual models** | May need to swap models | Use Lite only, or upgrade RAM |
| **gVisor on macOS** | gVisor Linux-only | Use Docker Desktop's built-in isolation |
| **First request slow** | Model loading delay | Pre-warm models after Ollama start |
| **No smart test selection** | Runs all tests every time | Acceptable for MVP; Phase 2 improvement |
| **Codex CLI requires responses API** | Ollama uses chat completions | OpenAI SDK auto-falls back |
| **Browser tests need Playwright** | Playwright MCP availability uncertain | Use native test runner for now |
| **Cloud planner cost** | Claude Opus API costs | Local model for plan generation (lower quality) |

---

## 10. Migration Notes

### From DS4 Stack (Original Proposal)

If you previously configured the DS4-based stack, here's what changed:

| Component | Before (DS4) | After (Ollama) |
|-----------|-------------|----------------|
| Model server | DS4 (localhost:8080) | Ollama (localhost:11434) |
| Primary model | deepseek-v4-flash | devstral:24b |
| Fast model | — | deepseek-coder-v2-lite:16b |
| RAM required | 128GB | 32GB |
| Backend | Metal/CUDA | MLX (Apple Silicon) |
| Install | Build from source | `curl \| sh` |
| API | `/v1/responses` native | Chat completions (auto-fallback) |

### Migration Steps

```bash
# 1. Stop DS4 (if running)
pkill -f ds4-server

# 2. Install Ollama
curl -fsSL https://ollama.com/install.sh | sh

# 3. Pull new models
ollama pull devstral:24b
ollama pull deepseek-coder-v2-lite:16b

# 4. Update Codex CLI config
sed -i 's/ds4/ollama/g' ~/.codex/config.toml
sed -i 's/localhost:8080/localhost:11434/g' ~/.codex/config.toml
sed -i 's/deepseek-v4-flash/devstral:24b/g' ~/.codex/config.toml

# 5. Verify
curl http://localhost:11434/v1/models
```

---

*For day-to-day operations, see the [Operator Runbook](runbook.md).*

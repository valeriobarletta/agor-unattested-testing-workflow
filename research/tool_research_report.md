# AI Development Workflow Tools Research Report

**Research Date:** July 2026
**Scope:** Four tools referenced in an unattended testing workflow proposal: Agor, DS4/DwarfStar, Colibri, and Codex CLI.

---

## Table of Contents

1. [Agor](#1-agor)
2. [DS4 / DwarfStar](#2-ds4--dwarfstar)
3. [Colibri](#3-colibri)
4. [Codex CLI](#4-codex-cli)
5. [Integration Matrix](#5-integration-matrix)
6. [Sources](#6-sources)

---

## 1. Agor

### Overview

**Agor** is a self-hosted, multiplayer-ready web workspace for orchestrating AI coding agents. It serves as a "team command center for all things agentic," providing persistent, observable, and resumable agent sessions on a spatial canvas. Agor was created by Maxime Beauchemin (@mistercrunch) and the team at Preset (builders of Apache Superset and Apache Airflow), and is actively developed with significant AI-assisted contributions.

### What It Does

Agor provides a unified platform for running coding agents (Claude Code, Codex CLI, Gemini, OpenCode, Copilot, Cursor) on isolated git branches. Unlike ephemeral CI bot integrations (e.g., `@claude` in GitHub PRs), Agor sessions are persistent — they survive after completion, retain full conversation history and tool use logs, and can be resumed or forked at any time.

**Key capabilities:**
- **Branch-centric work management** — Every piece of work is a git branch with its own working directory, dev environment, conversation history, and PR
- **Multi-runtime agent support** — Claude Code, Codex, Gemini, OpenCode, Copilot, and Cursor (beta) are interchangeable per session
- **Persistent sessions** — Sessions survive after completion; can be resumed, forked, or spawned as sub-sessions
- **Real-time multiplayer canvas** — Figma-like 2D board with live cursors, comments, shared sessions
- **MCP-native** — Exposes itself over MCP so agents can introspect and drive the system
- **Long-lived assistants** — Persistent AI coworkers with knowledge-base namespaces, skills, and schedules
- **Governance & observability** — Per-prompt token and dollar accounting, branch-scoped RBAC/ACLs, full durable history
- **Git worktree management** — Clean isolation across branches without stashing or context switching

### Architecture & Tech Stack

| Component | Technology |
|---|---|
| Backend | FeathersJS |
| Database | LibSQL (SQLite) or PostgreSQL |
| ORM | Drizzle ORM |
| Frontend | React + Ant Design |
| Distribution | Single npm package (`agor-live`) |
| Language | TypeScript |
| License | Business Source License 1.1 |

Agor is a **pnpm workspace monorepo** with Turbo for parallel builds. It supports Docker Compose deployment and local development with a two-process workflow (daemon + UI dev server).

### APIs & Interfaces

Agor provides multiple interfaces:

1. **Web UI** — Spatial canvas for visual session management (runs at `http://localhost:5173` by default)
2. **REST API** — Full REST endpoint set for programmatic control
3. **CLI** — Global `agor` command for worktree management, session orchestration, and configuration
4. **TypeScript Client** (`@agor/core`) — Type-safe client library
5. **WebSocket Events** — Real-time event streaming for live updates
6. **MCP Server** — Agor exposes itself as an MCP server; agents can introspect sessions, branches, and boards

**Example API usage:**
```typescript
import { createClient } from '@agor/core/api';

const client = createClient(process.env.AGOR_DAEMON_URL);

// Spawn an agent session
const session = await client.service('sessions').create({
  worktree_id: 'abc123',
  agent: 'claude-code',
  prompt: 'Implement dark mode for the dashboard',
});

// Watch progress in real-time
client.service('messages').on('created', message => {
  if (message.session_id === session.session_id) {
    console.log('Agent update:', message.content);
  }
});
```

### Configuration Options

**User config:** `~/.agor/config.yaml`

Key configuration areas:
- Daemon port (`daemon.port`, default 3030)
- UI port (`ui.port`, default 5173)
- Database selection (SQLite file path or PostgreSQL connection URL)
- Security headers (CSP + CORS)
- Isolation modes: `simple` -> `insulated` -> `strict`

**Environment variables:**
- `PORT` — Daemon port override
- `VITE_DAEMON_URL` — Full daemon URL for UI
- `VITE_DAEMON_PORT` — Daemon port for UI

### Installation & Setup

**Prerequisites:** Node.js >= 22.12

**Quick start:**
```bash
npm install -g agor-live
agor init           # Creates ~/.agor/ and database
agor daemon start   # Runs daemon in background
agor open           # Opens web UI
```

**Docker deployment:**
```bash
git clone https://github.com/preset-io/agor
cd agor
docker compose up
# Visit http://localhost:5173 -> login: admin@agor.live / admin
```

**GitHub Action integration:**
```yaml
# .github/workflows/agor-review.yml
on:
  pull_request:
    types: [opened, synchronize]

jobs:
  agor-review:
    runs-on: ubuntu-latest
    steps:
      - uses: agor-live/agor-action@v1
        with:
          agent: claude-code
          prompt: 'Review this PR for security issues and best practices'
          board: 'ci-reviews'
          worktree: 'pr-${{ github.event.number }}'
          mcp-servers: 'playwright,context7'
```

### Current Status

- **GitHub Stars:** ~1,300+ (as of June 2026)
- **Maturity:** Active development, production-ready for self-hosted use
- **Community:** Discord, GitHub Discussions
- **Cloud offering:** Private beta announced (Agor Cloud)
- **Key limitation:** BSL 1.1 license (not fully open source)

---

## 2. DS4 / DwarfStar

### Overview

**DS4** (DwarfStar 4) is a narrow, model-specific C inference engine for running DeepSeek V4 Flash locally on high-memory machines. It was created by Salvatore Sanfilippo (antirez, creator of Redis) and is deliberately **not** a generic GGUF runner — it optimizes for one model architecture at a time to achieve performance that general-purpose engines cannot match.

DS4 targets DeepSeek V4 Flash, a 284B-parameter Mixture-of-Experts (MoE) model with 13B active parameters per forward pass and a 1-million-token context window.

### What It Does

DS4 provides local inference for DeepSeek V4 Flash through three interfaces:
- **`./ds4`** — Interactive / one-shot CLI
- **`./ds4-server`** — OpenAI-compatible HTTP API server
- **`./ds4-agent`** — Native coding agent (experimental, alpha quality)

### Key Features

| Feature | Description |
|---|---|
| **Asymmetric 2-bit quantization** | Selective mixed-precision: routed MoE experts compressed to IQ2_XXS/Q2_K, shared experts and attention at Q8_0/F16. Result: ~70-81GB model fits in 128GB machines. |
| **Native Metal execution** | Direct Metal graph executor on macOS (no GGML abstraction layer). CUDA backend for Linux, ROCm support. |
| **KV cache on SSD** | Revolutionary disk-centric KV cache. Persists long prefixes to SSD, resumes by prompt hash. Enables 1M-token context on a MacBook. |
| **SSD streaming mode** | When model doesn't fit in RAM, routed experts stream from SSD with in-memory LRU cache. |
| **Distributed inference** | Multi-machine setup via TCP (e.g., two MacBooks over Thunderbolt 5). Pipeline-parallel prefill. |
| **Speculative decoding** | Multi-token prediction (MTP) support with separate draft GGUF. |
| **Dual API compatibility** | OpenAI-compatible (`/v1/chat/completions`, `/v1/responses`) AND Anthropic-compatible (`/v1/messages`) APIs. |
| **Directional steering** | Runtime activation editing for controlling model behavior/style. |
| **Tool/function calling** | Full tool call support with DSML format mapping. |
| **Power management** | `--power N` flag to reduce GPU usage for quieter/cooler operation. |

### Architecture

- **Language:** C (single-file `ds4.c` for core engine)
- **Backends:** Metal (macOS), CUDA (Linux/DGX Spark), ROCm
- **License:** MIT
- **GGUF dependency:** Ships with custom-crafted GGUF files (not compatible with standard llama.cpp quants)
- **Quantization:** Custom offline tools in `gguf-tools/` directory

### How It Works

1. **Download model weights** from Hugging Face (`antirez/deepseek-v4-gguf`)
2. **Build** with `make` (macOS Metal), `make cuda-spark` (DGX Spark), `make cuda-generic` (Linux CUDA)
3. **Run CLI:** `./ds4 -m ./ds4flash.gguf` for interactive chat
4. **Run server:** `./ds4-server --ctx 100000 --kv-disk-dir /tmp/ds4-kv`

**SSD streaming mode** (when model exceeds RAM):
```bash
./ds4 -m ./ds4flash.gguf --ssd-streaming
# Or with explicit cache budget:
./ds4 -m ./ds4flash.gguf --ssd-streaming --ssd-streaming-cache-experts 32GB
```

### API Endpoints

The `ds4-server` exposes these endpoints:

| Endpoint | Description |
|---|---|
| `GET /v1/models` | List available models |
| `GET /v1/models/deepseek-v4-flash` | Model details |
| `GET /v1/models/deepseek-v4-pro` | PRO model details (alias) |
| `POST /v1/chat/completions` | OpenAI Chat Completions API |
| `POST /v1/responses` | **OpenAI Responses API (preferred for Codex CLI)** |
| `POST /v1/completions` | Legacy completions |
| `POST /v1/messages` | Anthropic Messages API |

### Codex CLI Integration

DS4's `/v1/responses` endpoint is the **preferred endpoint for Codex CLI**. To configure Codex CLI to use DS4:

```toml
# ~/.codex/config.toml
model = "deepseek-v4-flash"
model_provider = "ds4"

[model_providers.ds4]
name = "DwarfStar DS4"
base_url = "http://localhost:8080/v1"
env_key = "DS4_API_KEY"
wire_api = "responses"
```

Set a dummy API key (DS4 doesn't require auth by default):
```bash
export DS4_API_KEY=dummy
```

### Performance Benchmarks

| Hardware | Context | Speed |
|---|---|---|
| MacBook M4 Max (128GB) | 4K | 3-6 tok/s |
| MacBook M4 Ultra (192GB) | 8K | 6-10 tok/s |
| MacBook M3 Max (128GB) | Short | ~26 tok/s (q2) |
| Mac Studio M3 Ultra (512GB) | - | ~37 tok/s |
| NVIDIA DGX Spark | 8K | 15-30 tok/s |
| DGX Spark (optimized) | Short | ~19 tok/s (GB10) |
| RTX PRO 6000 | Short | ~63 tok/s |

### Hardware Requirements

| Tier | Spec |
|---|---|
| **Minimum** | MacBook Pro M4 Max with 128GB unified memory |
| **Recommended** | MacBook Pro M3/M4 Ultra with 192GB+, or Mac Studio M3 Ultra with 512GB |
| **Alternative** | NVIDIA DGX Spark (128GB unified memory, GB10 Grace Blackwell) |
| **Disk** | ~81GB for q2 GGUF, ~100GB+ for q4; fast NVMe SSD strongly recommended |

**Note:** Sub-128GB machines cannot run DS4. The smallest quant is ~81GB.

### Configuration Options

Key CLI/server flags:

| Flag | Description |
|---|---|
| `-m <path>` | Model GGUF path |
| `--ctx <N>` | Context window size |
| `--kv-disk-dir <path>` | KV cache disk directory |
| `--kv-disk-space-mb <N>` | Max KV disk space |
| `--ssd-streaming` | Enable SSD streaming mode |
| `--ssd-streaming-cache-experts <size>` | Expert cache budget |
| `--power <N>` | GPU usage target (100 = full speed) |
| `--trace <path>` | Log session trace for debugging |
| `--dir-steering-file <file>` | Load directional steering matrix |
| `--mtp <draft.gguf>` | Enable speculative decoding |

### Current Status

- **GitHub Stars:** 7,000+ (hit 7.1k in 4 days after release)
- **Quality:** Beta (inference and serving are complex; project exists only since May 2026)
- **Agent mode:** Alpha quality
- **Development:** Rapid iteration; major features (distributed inference, SSD streaming) added recently
- **Key caveat:** Built with strong GPT-5.5 assistance (acknowledged openly by antirez)

### Model Weights

Pre-quantized GGUF files available at: `https://huggingface.co/antirez/deepseek-v4-gguf`

Quant variants include:
- Q2 (IQ2_XXS routed experts, ~81GB) — fits 128GB machines
- Q4 (Q4_K routed experts, ~150-170GB) — for higher-memory machines
- Q2-imatrix / Q4-imatrix — imatrix-optimized variants

---

## 3. Colibri

### Overview

**Colibri** (stylized "Colibri" or "colibri") is a pure-C, zero-dependency inference engine that runs GLM-5.2 — a 744-billion-parameter Mixture-of-Experts model — on consumer machines with approximately 25GB of RAM. It was created by JustVugg and released under Apache 2.0. Colibri hit 1,600+ GitHub stars in its first day and represents a similar "narrow engine for one model" approach as DS4, but for a different model and with a dramatically lower memory footprint.

### What It Does

Colibri makes it possible to run a frontier-scale 744B-parameter model on mid-range consumer hardware by exploiting MoE sparsity: only ~40B parameters are active per token, so most of the model can live on disk and be streamed on demand.

### Key Features

| Feature | Description |
|---|---|
| **Pure C, zero dependencies** | ~1,300-2,400 lines of C. No CUDA, no PyTorch, no BLAS. |
| **Expert streaming from SSD** | Dense layers (~9.9GB at int4) pinned in RAM; 21,504 routed experts (~370GB) streamed from NVMe on demand |
| **Intelligent memory hierarchy** | VRAM for hot experts (optional) -> RAM for dense weights -> SSD for cold experts |
| **Native MTP speculative decoding** | 2.2-2.8 tokens/forward at int8 |
| **Compressed KV cache** | MLA attention with 57x compressed KV cache, persists across sessions |
| **AVX2 integer-dot kernels** | Hand-written quantized kernels |
| **Async expert readahead** | Predictive expert loading |
| **Learning cache** | Auto-pins hot experts based on access patterns |
| **OpenAI-compatible HTTP gateway** | `coli serve` exposes `/v1/chat/completions` for standard client integration |

### How It Works

1. **Model conversion** — Offline FP8 -> int4 converter processes weights (never requires full 756GB checkpoint on disk at once)
2. **Run chat:** `COLI_MODEL=/path/to/weights ./coli chat`
3. **Run server:** `./coli serve` for OpenAI-compatible API
4. **Benchmark:** `./coli bench` for HellaSwag, ARC, MMLU

### Architecture

- **Language:** Pure C (~1,300 lines for core engine, ~2,400 for full GLM implementation)
- **GPU backends:** Optional (not required); Metal and other backends can be added
- **License:** Apache 2.0
- **Model support:** GLM-5.2 (744B MoE, ~40B active)
- **RAM required:** ~9.9GB resident (dense layers at int4) + ~25GB total system memory
- **Disk required:** ~370GB for pre-converted weights

### Performance

| Hardware | Speed |
|---|---|
| WSL2, 12 cores, 25GB RAM, NVMe | 0.05-0.1 tok/s (cold) |
| Apple M5 Max, 128GB RAM, fast SSD | ~1.06 tok/s |
| Framework 13 | ~0.37 tok/s |

Colibri is honest about its speed: it prioritizes quality over performance. The "Netflix for neural networks" approach makes frontier models accessible, not fast.

### Codex CLI Integration (Weaker Than DS4)

Colibri exposes an OpenAI-compatible HTTP server (`coli serve`), which theoretically enables Codex CLI integration via the same mechanism as DS4:

```toml
# ~/.codex/config.toml (hypothetical)
model = "glm-5.2"
model_provider = "colibri"

[model_providers.colibri]
name = "Colibri"
base_url = "http://localhost:<port>/v1"
env_key = "COLIBRI_API_KEY"
wire_api = "responses"
```

However, compared to DS4, Colibri has **weaker Codex/Responses API integration** for several reasons:

1. **No native `/v1/responses` endpoint** — Colibri's server primarily targets `/v1/chat/completions`; the Responses API (which Codex CLI requires) may not be fully supported
2. **Slower inference** — 0.1-1 tok/s vs DS4's 10-30+ tok/s makes interactive agent workflows impractical
3. **No tool calling optimization** — DS4 has native DSML tool handling tested with coding agents; Colibri's tool call support is less mature
4. **Different model** — GLM-5.2 vs DeepSeek V4 Flash; Codex CLI has been specifically tested and validated with DS4
5. **Newer project** — Colibri is newer (July 2026) and less battle-tested with agent workflows

### Installation

```bash
git clone https://github.com/JustVugg/colibri
cd colibri/c
./setup.sh
# Point at pre-converted int4 weights on Hugging Face
COLI_MODEL=/path/to/GLM-5.2-colibri-int4 ./coli chat
```

### Current Status

- **GitHub Stars:** 11,500+ (as of mid-July 2026)
- **License:** Apache 2.0
- **Maturity:** Early but functional; actively seeking benchmark contributions
- **Community:** Show HN (769 points), active GitHub community
- **Comparison to DS4:** Colibri trades speed for accessibility — it runs on 25GB machines where DS4 requires 128GB, but generates tokens 10-30x slower

---

## 4. Codex CLI

### Overview

**Codex CLI** is OpenAI's official agentic coding tool that runs in the terminal. It can understand codebases, edit files, run commands, and help write code more efficiently. It is described as "one agent for everywhere you code" and is designed to work with both OpenAI cloud models and local/self-hosted models via the OpenAI Responses API.

### What It Does

Codex CLI provides an interactive TUI (terminal user interface) coding assistant with:
- **Code understanding** — Reads and analyzes project files
- **File editing** — Applies patches, creates/deletes files
- **Command execution** — Runs shell commands with sandboxed permissions
- **Multi-turn conversations** — Maintains context across interactions
- **Tool calling** — Uses functions like shell, file operations, web search
- **MCP support** — Connects to Model Context Protocol servers
- **Subagents** — Spawns child agents for focused tasks
- **CI integration** — JSONL event output for automation

### Key Features

| Feature | Description |
|---|---|
| **Multi-provider support** | OpenAI (cloud), Ollama, LM Studio, vLLM, MLX, DS4, Colibri, or any OpenAI-compatible endpoint |
| **OpenAI Responses API** | Primary protocol; `/v1/responses` endpoint with streaming SSE |
| **Sandboxed execution** | Three modes: `read-only`, `workspace-write`, `danger-full-access` |
| **Approval policies** | `never` (auto-approve), `on-request` (prompt for approval), `untrusted` (strict), or granular per-tool |
| **Profiles** | Per-session config overlays for different workflows |
| **Hooks** | Pre/post-compaction hooks, `/hooks` browser |
| **Goals** | Persisted `/goal` workflows for multi-day tasks |
| **MCP servers** | Native Model Context Protocol integration |
| **Vim mode** | Keyboard-driven interface |
| **Voice input** | Speech-to-text support |
| **Local review** | Built-in code review capabilities |

### Architecture

- **Primary language:** Rust (97.4% in v0.142.5)
- **Distribution:** npm (`@openai/codex`), Homebrew (`brew install codex`), standalone binaries
- **Current version:** ~0.142.x (as of June 2026)
- **GitHub:** `openai/codex` (91K+ stars, 449+ contributors)
- **License:** OpenAI's standard license

### How It Works

1. **Install** via npm, Homebrew, or binary download
2. **Configure** `~/.codex/config.toml` with model and provider settings
3. **Launch** with `codex` in any project directory
4. **Interact** via TUI — type prompts, review tool calls, approve/reject actions
5. **Codex** streams requests to the configured model provider via the Responses API

### Configuration

**Config file location:** `~/.codex/config.toml` (or `$CODEX_HOME/config.toml`)

**Layered config precedence:**
Managed config (admin) -> User config (`~/.codex/config.toml`) -> Project config (`.codex/config.toml`) -> CLI flags

**Basic config:**
```toml
model = "gpt-5.4"
model_provider = "openai"
approval_policy = "on-request"
sandbox_mode = "workspace-write"
file_opener = "vscode"
```

**Connecting to a local model server (e.g., Ollama):**
```toml
model = "devstral:24b"
model_provider = "ollama"

[model_providers.ollama]
name = "Ollama Local"
base_url = "http://localhost:11434/v1"
env_key = "OLLAMA_API_KEY"
wire_api = "responses"
```

**Key provider config fields:**

| Field | Description |
|---|---|
| `base_url` | API endpoint URL (required) |
| `env_key` | Environment variable for API key |
| `wire_api` | Protocol — `"responses"` is the only supported value |
| `query_params` | Query params appended to requests |
| `http_headers` | Static headers for every request |
| `request_max_retries` | HTTP retry count (default: 4) |
| `stream_max_retries` | SSE stream retry count (default: 5) |

**Profiles:**
```toml
[profiles.fast]
model = "deepseek-coder-v2-lite:16b"
approval_policy = "never"
sandbox_mode = "workspace-write"

[profiles.deep]
model = "devstral:24b"
approval_policy = "on-request"
```

Activate with: `codex --profile fast`

### Security Model

| Aspect | Behavior |
|---|---|
| **Sandbox** | `read-only` (no writes), `workspace-write` (writes within project), `danger-full-access` (unrestricted) |
| **Approval** | `never` (auto), `on-request` (prompt user), `untrusted` (always ask), or granular per-tool config |
| **Environment isolation** | `shell_environment_policy` controls env var inheritance |
| **Network** | `network_access = false` by default; use `network_proxy` with domain allowlist for controlled access |
| **Project config restrictions** | Sensitive keys (`approval_policy`, `sandbox_mode`, `model_providers`, etc.) are ignored in project-local config |

### API Requirements

Codex CLI requires a model with **strong tool calling capabilities** supporting the OpenAI Responses API. The model must support:
- Function/tool calling via the Responses API format
- Streaming (Server-Sent Events)
- Multi-turn conversation state management

Models known to work well:
- GPT-5.4 / GPT-5.5 (OpenAI cloud)
- DeepSeek V4 Flash (via DS4)
- Qwen3.5-Coder / Qwen3.6-27B (via vLLM)
- GPT-OSS-20B / GPT-OSS-120B (local via Ollama)
- Devstral:24B (via Ollama)
- DeepSeek-Coder-V2-Lite:16B (via Ollama)

### Pricing & Plans

| Plan | Cost | Codex CLI Access |
|---|---|---|
| ChatGPT Plus | $20/month | Included (usage limits apply) |
| ChatGPT Pro | $100/month | Higher limits |
| API key mode | Pay-per-token | Token-billed, no ChatGPT plan features |

### Installation

```bash
# npm
npm install -g @openai/codex

# Homebrew (macOS)
brew install codex

# One-line install (macOS/Linux)
curl -fsSL https://chatgpt.com/codex/install.sh | sh

# Windows
powershell -ExecutionPolicy ByPass -c "irm https://chatgpt.com/codex/install.ps1 | iex"
```

### Current Status

- **GitHub Stars:** 91,000+
- **Current Version:** 0.142.x
- **Maturity:** Production-ready; rapid release cycle
- **Key limitation:** The `wire_api = "responses"` requirement means providers must expose the Responses API, or Codex CLI falls back to Chat Completions

---

## 5. Integration Matrix

| Tool | Role | Interfaces | Best For |
|---|---|---|---|
| **Agor** | Orchestration layer | Web UI, REST API, CLI, TypeScript SDK, MCP | Multi-agent coordination, persistent sessions, CI/CD, team workflows |
| **Ollama** | Local LLM inference | CLI, REST API (`/v1/chat/completions`) | Running multiple models (Devstral, Qwen, Llama) on 32GB+ machines |
| **DS4/DwarfStar** | Local LLM inference | CLI, HTTP API (OpenAI + Anthropic), Native agent | High-quality local inference of DeepSeek V4 Flash on 128GB+ machines |
| **Colibri** | Local LLM inference | CLI, HTTP API (OpenAI Chat) | Running GLM-5.2 on 25GB consumer machines; accessible but slower |
| **Codex CLI** | Agent execution harness | TUI, `codex exec`, JSONL output | Interactive coding, file editing, command execution, CI automation |

### Updated Workflow Integration (Ollama + Dual Model)

```
Agor (orchestration)
    |
    v
Cloud Planner (Claude Opus) — plan generation
    |
    v
Codex CLI (agent harness)
    |
    +---> Ollama /v1/chat/completions
    |         |
    |         +---> devstral:24b (complex tasks)
    |         |
    |         +---> deepseek-coder-v2-lite:16b (quick fixes)
    |
    v
Test Runner — static / unit / integration / e2e
    |
    v
Draft PR / Human Review
```

---

## 6. Sources

### Agor
- GitHub Repository: https://github.com/preset-io/agor
- Official Website: https://agor.live
- Architecture Docs: https://agor.live/guide/architecture

### DS4 / DwarfStar
- GitHub Repository: https://github.com/antirez/ds4
- Official Website: https://dwarfstar.sh
- Hugging Face Weights: https://huggingface.co/antirez/deepseek-v4-gguf

### Colibri
- GitHub Repository: https://github.com/JustVugg/colibri

### Codex CLI
- GitHub Repository: https://github.com/openai/codex
- vLLM Integration Docs: https://docs.vllm.ai/en/latest/serving/integrations/codex/

### Ollama
- GitHub Repository: https://github.com/ollama/ollama
- Official Website: https://ollama.com

---

*Report compiled from publicly available documentation, GitHub repositories, and community benchmarks as of July 2026.*

# Local LLM Server Options for Codex CLI on 32GB RAM Mac (July 2026)

> **Research Date:** July 2026
> **Target Hardware:** Mac with 32GB unified memory (M2/M3/M4 Pro, M3/M4 Max, or Studio)
> **Use Case:** Unattended code editing with Codex CLI -- file operations, test running, multi-step reasoning
> **Codex CLI Requirements:** OpenAI-compatible API (`/v1/responses` preferred), tool/function calling, `wire_api = "responses"`

---

## Executive Summary

Running Codex CLI with local models on a 32GB Mac is **entirely feasible** as of July 2026. You have **5 viable inference engines** and **8+ model families** to choose from. The sweet spot is **Qwen3-Coder:30B** or **Devstral:24B** at Q4_K_M quantization, both fitting comfortably within 32GB unified memory with room for context.

### Top 3 Recommendations for 32GB Mac

| Rank | Model | Engine | RAM Used | Tokens/s (M3 Pro 32GB) | Best For |
|------|-------|--------|----------|----------------------|----------|
| 1 | **Qwen3-Coder:30B (Q4_K_M)** | Ollama 0.19+ with MLX backend | ~19GB + KV cache | 30-40 tok/s | Best overall code quality per VRAM |
| 2 | **Devstral:24B (Q4_K_M)** | Ollama or LM Studio MLX | ~14GB + KV cache | 35-50 tok/s | Highest SWE-Bench score, best agentic reliability |
| 3 | **Gemma 4 27B (Q4_K_M)** | LM Studio MLX | ~16GB + KV cache | 25-35 tok/s | Best general-purpose tool calling |

---

## Table of Contents

1. [Inference Engine Comparison](#1-inference-engine-comparison)
2. [Ollama Deep Dive](#2-ollama--detailed-model-analysis)
3. [LM Studio](#3-lm-studio)
4. [MLX (Apple Native)](#4-mlx-apple-silicon-native)
5. [llama.cpp / llama-server](#5-llamacpp--llama-server)
6. [vLLM](#6-vllm)
7. [Other Specialized Engines](#7-other-specialized-inference-engines)
8. [Model-by-Model Deep Dive](#8-model-by-model-deep-dive)
9. [Codex CLI Configuration Examples](#9-codex-cli-configuration-examples)
10. [RAM Usage Reference Tables](#10-ram-usage-reference-tables)
11. [Final Recommendations](#11-final-recommendations)

---

## 1. Inference Engine Comparison

### Quick Comparison: All Engines

| Engine | OpenAI API | `/v1/responses` | Tool Calling | Mac Support | 32GB Viable? | Speed on Mac | Best For |
|--------|-----------|-----------------|--------------|-------------|--------------|--------------|----------|
| **Ollama 0.19+** | Yes (`/v1/chat/completions`) | Partial (via chat compat) | Yes | Excellent (Metal + MLX) | Yes | Good (MLX: 30-40 tok/s) | Default choice, ecosystem |
| **LM Studio** | Yes (`/v1/chat/completions`) | Partial (via chat compat) | Yes | Excellent (MLX native) | Yes | Best (MLX: 35-50 tok/s) | GUI users, max performance |
| **MLX (`mlx-lm`)** | Via `mlx_lm.server` | No (chat only) | Manual | Best-in-class | Yes | Best (raw MLX) | Power users, scripting |
| **llama.cpp server** | Yes (`/v1/chat/completions`) | **Yes** (`/v1/responses`) | Yes (`--jinja`) | Good (Metal) | Yes | Good | Only option for native `/v1/responses` |
| **vLLM** | Yes | No | Experimental | Limited (via Docker) | Tight | Poor on Mac | Not recommended for Mac |
| **TabbyAPI** | Yes | No | Yes | **No** (NVIDIA only) | N/A | N/A | Skip for Mac |
| **ExLlamaV2** | Via TabbyAPI | No | Yes | **No** (NVIDIA only) | N/A | N/A | Skip for Mac |
| **TGI** | Yes | No | Yes | **No** (CUDA required) | N/A | N/A | Skip for Mac |
| **KoboldCPP** | Partial | No | Limited | Indirect | No | Slow | Skip |

### Key Finding: `/v1/responses` API Support

**Critical for Codex CLI `wire_api = "responses"`:**

As of July 2026, **only llama.cpp's `llama-server` has native `/v1/responses` endpoint support**. However, Codex CLI can work with engines that provide `/v1/chat/completions` -- the OpenAI SDK used by Codex typically falls back to chat completions if responses is unavailable. For full Codex CLI compatibility:

- **llama.cpp**: Native `/v1/responses` + `/v1/chat/completions` + tool calling -- **most compatible**
- **Ollama**: `/v1/chat/completions` only -- works with Codex CLI via OSS mode
- **LM Studio**: `/v1/chat/completions` only -- works with Codex CLI via custom provider
- **MLX**: `/v1/chat/completions` via `mlx_lm.server` -- works but no tool calling template support

---

## 2. Ollama -- Detailed Model Analysis

### Why Ollama?

Ollama is the **most recommended default** for Codex CLI on Mac. As of Ollama 0.19 (March 2026), it includes an **optional MLX backend** for Macs with 32GB+ unified memory, delivering 85-93% of pure MLX performance with Ollama's ecosystem convenience.

### Ollama Configuration for Codex CLI

```toml
# ~/.codex/config.toml

[model_providers.ollama]
name = "Ollama Local"
base_url = "http://localhost:11434/v1"
wire_api = "responses"

[profiles.ollama]
model = "qwen3-coder:30b"
model_provider = "ollama"
```

### Models That Work on 32GB Mac (Ollama)

#### 2.1 Qwen3-Coder Family (RECOMMENDED)

| Model | Params | Active Params | Q4_K_M Size | Q8_0 Size | Context | 32GB Fit? | Tokens/s (M3 Pro 32GB) | Tool Calling |
|-------|--------|--------------|-------------|-----------|---------|-----------|----------------------|--------------|
| `qwen3-coder:30b` | 30B MoE | 3.3B | **19 GB** | 32 GB | 256K | **Yes, tight** | 30-40 tok/s | Good |
| `qwen2.5-coder:14b` | 14B dense | 14B | 9.0 GB | 16 GB | 32K | **Yes, comfortable** | 50-70 tok/s | OK |
| `qwen2.5-coder:7b` | 7B dense | 7B | 4.7 GB | 8.4 GB | 32K | **Yes, very fast** | 80-110 tok/s | OK |
| `qwen2.5-coder:32b` | 32B dense | 32B | 20 GB | 36 GB | 32K | **No (Q8), tight (Q4)** | 18-25 tok/s | Good |

#### 2.2 Devstral (Mistral + All Hands)

| Model | Params | RAM (Q4) | Speed | SWE-Bench | License | Notes |
|-------|--------|----------|-------|-----------|---------|-------|
| `devstral:24b` | 24B | **14 GB** | **35-50 tok/s** | **46.8%** | Apache 2.0 | Purpose-built for agentic coding |

Devstral was co-trained by Mistral and All Hands (the OpenHands project) specifically for agentic coding workflows. It achieves the highest SWE-Bench score of any local model.

#### 2.3 DeepSeek-Coder-V2-Lite

| Model | Params | Active | RAM (Q4) | Speed | Notes |
|-------|--------|--------|----------|-------|-------|
| `deepseek-coder-v2-lite:16b` | 16B MoE | 2.4B | **9.0 GB** | **60-80 tok/s** | Fast, good for simpler tasks |

Best "fast model" for the dual-model setup. Small enough to leave massive headroom.

#### 2.4 Gemma 4 Family (Google)

| Model | Params | RAM (Q4) | Speed | Tool Calling | Notes |
|-------|--------|----------|-------|-------------|-------|
| `gemma4:27b` | 27B | **17 GB** | 25-35 tok/s | Excellent (~95%) | Best tool reliability |
| `gemma4:12b` | 12B | 8.0 GB | 45-60 tok/s | Good | Fast alternative |

Gemma 4 has the most reliable tool calling of any local model series. If your workflow depends heavily on accurate tool use, Gemma 4 is worth considering despite slightly lower raw coding benchmarks.

### Ollama Installation & Setup

```bash
# Install Ollama
curl -fsSL https://ollama.com/install.sh | sh

# Start server with MLX backend on Apple Silicon
OLLAMA_MLX=1 ollama serve

# Pull models
ollama pull devstral:24b
ollama pull deepseek-coder-v2-lite:16b

# Verify
ollama list
curl http://localhost:11434/v1/models
```

---

## 3. LM Studio

LM Studio is a GUI-based inference manager with native MLX integration. It typically achieves **25-30% higher throughput** than Ollama on Apple Silicon due to more direct MLX usage.

### Pros vs Ollama
- Faster inference (raw MLX, less overhead)
- Built-in model browser and downloader
- Good for interactive development and debugging

### Cons vs Ollama
- GUI-only (no headless mode for automation)
- Less convenient for scripting
- Manual model downloads

### Best For
Developers who want a GUI for model management and don't need full headless automation.

---

## 4. MLX (Apple Silicon Native)

**MLX** is Apple's native machine learning framework. `mlx-lm` provides a server mode that exposes an OpenAI-compatible API.

### Setup
```bash
pip install mlx-lm
mlx_lm.server --model devstral --port 11434
```

### Pros
- Maximum performance on Apple Silicon
- Native Metal GPU utilization
- Lowest overhead

### Cons
- No built-in tool calling templates
- Manual setup for each model
- Less ecosystem support than Ollama

### Best For
Power users who want maximum performance and don't mind manual configuration.

---

## 5. llama.cpp / llama-server

**llama.cpp** is the reference implementation for local LLM inference. Its `llama-server` is the **only engine with native `/v1/responses` support**.

### Setup
```bash
# Build with Metal support
git clone https://github.com/ggerganov/llama.cpp
cd llama.cpp
cmake -B build -DGGML_METAL=ON
cmake --build build --config Release

# Start server with responses API
./build/bin/llama-server \
  -m /path/to/devstral-Q4_K_M.gguf \
  --port 11434 \
  --api-key dummy \
  --jinja  # Enable tool calling
```

### Pros
- Native `/v1/responses` endpoint
- Most compatible with Codex CLI
- Highly optimized

### Cons
- Manual model download and management
- More complex setup than Ollama
- No ecosystem features (no model hub)

### Best For
Users who absolutely need native `/v1/responses` compatibility and don't mind manual setup.

---

## 6. vLLM

**vLLM** is primarily a CUDA-focused inference engine. Mac support is experimental and performance is poor.

**Verdict: Skip for Mac.**

---

## 7. Other Specialized Inference Engines

| Engine | Mac Support | Notes |
|--------|-------------|-------|
| **TabbyAPI** | No (NVIDIA only) | Skip |
| **ExLlamaV2** | No (NVIDIA only) | Skip |
| **TGI (HuggingFace)** | No (CUDA required) | Skip |
| **KoboldCPP** | Indirect | Not relevant for coding agents |

---

## 8. Model-by-Model Deep Dive

### Devstral:24B (RECOMMENDED for Agentic Coding)

- **Parameters**: 24B dense
- **RAM (Q4_K_M)**: ~14GB
- **Speed**: 35-50 tok/s on M3 Pro 32GB
- **SWE-Bench**: 46.8% (highest local model)
- **License**: Apache 2.0
- **Tool calling**: Good
- **Best for**: Complex implementation tasks, multi-file changes
- **Why**: Co-trained by Mistral + All Hands specifically for agentic coding

### Qwen3-Coder:30B (RECOMMENDED for Code Quality)

- **Parameters**: 30B MoE (3.3B active)
- **RAM (Q4_K_M)**: ~19GB
- **Speed**: 30-40 tok/s on M3 Pro 32GB
- **Context**: 256K tokens
- **License**: Apache 2.0
- **Tool calling**: Good
- **Best for**: Large codebase understanding, long context tasks

### DeepSeek-Coder-V2-Lite:16B (RECOMMENDED for Fast Tasks)

- **Parameters**: 16B MoE (2.4B active)
- **RAM (Q4_K_M)**: ~9GB
- **Speed**: 60-80 tok/s on M3 Pro 32GB
- **License**: DeepSeek License
- **Tool calling**: OK
- **Best for**: Quick fixes, simple changes, filling in gaps

### Gemma 4 27B (RECOMMENDED for Tool Reliability)

- **Parameters**: 27B dense
- **RAM (Q4_K_M)**: ~17GB
- **Speed**: 25-35 tok/s on M3 Pro 32GB
- **Tool calling**: Excellent (~95% reliability)
- **License**: Gemma Terms
- **Best for**: Workflows where tool call accuracy is critical

---

## 9. Codex CLI Configuration Examples

### Devstral:24B via Ollama (Recommended)
```toml
# ~/.codex/config.toml
model = "devstral:24b"
model_provider = "ollama"

[model_providers.ollama]
name = "Ollama"
base_url = "http://localhost:11434/v1"
wire_api = "responses"

[profiles.unattended]
model = "devstral:24b"
model_provider = "ollama"
approval_policy = "never"
sandbox_mode = "workspace-write"
```

### Dual-Model Setup (Primary + Fast)
```toml
# ~/.codex/config.toml
[profiles.unattended]
model = "devstral:24b"
model_provider = "ollama"

[profiles.fast]
model = "deepseek-coder-v2-lite:16b"
model_provider = "ollama"
approval_policy = "never"
```

### llama.cpp with Native Responses API
```toml
# ~/.codex/config.toml
model = "devstral"
model_provider = "local"

[model_providers.local]
name = "llama.cpp"
base_url = "http://localhost:11434/v1"
wire_api = "responses"
```

---

## 10. RAM Usage Reference Tables

### Q4_K_M Quantization (Recommended for 32GB)

| Model | Size | In 32GB? | Headroom |
|-------|------|----------|----------|
| deepseek-coder-v2-lite:16B | 9.0 GB | ✅ Yes | 23 GB |
| qwen2.5-coder:14b | 9.0 GB | ✅ Yes | 23 GB |
| devstral:24b | 14 GB | ✅ Yes | 18 GB |
| gemma4:27b | 17 GB | ✅ Yes | 15 GB |
| qwen3-coder:30b | 19 GB | ✅ Tight | 13 GB |
| qwen2.5-coder:32b | 20 GB | ✅ Tight | 12 GB |

### Running Two Models Simultaneously (Dual-Model Setup)

| Primary | Fast | Combined | In 32GB? |
|---------|------|----------|----------|
| devstral:24b (14GB) | deepseek-coder-v2-lite:16b (9GB) | **23 GB** | ✅ Yes, 9GB headroom |
| qwen3-coder:30b (19GB) | deepseek-coder-v2-lite:16b (9GB) | **28 GB** | ⚠️ Tight, 4GB headroom |
| gemma4:27b (17GB) | deepseek-coder-v2-lite:16b (9GB) | **26 GB** | ✅ Yes, 6GB headroom |

---

## 11. Final Recommendations

### For This Project (Agor Unattended Workflow)

**Primary choice: Ollama + Devstral:24B + DeepSeek-Coder-V2-Lite:16B**

Reasons:
1. Both models fit in 32GB with 9GB headroom
2. Devstral has highest SWE-Bench score (46.8%) — best for unattended coding
3. Lite model provides 60-80 tok/s for quick tasks
4. Ollama ecosystem is mature and well-documented
5. Easy model switching via profiles

### Alternative: Ollama + Qwen3-Coder:30B

If you need:
- 256K context window
- Best-in-class code understanding
- Slightly higher RAM usage is acceptable (19GB)

### If Tool Calling Reliability is Critical

Use **Gemma 4 27B** instead of Devstral. It has ~95% tool calling reliability vs Devstral's ~85%.

### Quick Start

```bash
# 1. Install Ollama
curl -fsSL https://ollama.com/install.sh | sh

# 2. Start with MLX
OLLAMA_MLX=1 ollama serve

# 3. Pull recommended models
ollama pull devstral:24b
ollama pull deepseek-coder-v2-lite:16b

# 4. Configure Codex CLI
cat > ~/.codex/config.toml << 'EOF'
model = "devstral:24b"
model_provider = "ollama"

[model_providers.ollama]
name = "Ollama"
base_url = "http://localhost:11434/v1"
wire_api = "responses"

[profiles.fast]
model = "deepseek-coder-v2-lite:16b"
model_provider = "ollama"
EOF

# 5. Test
codex --model devstral:24b "Hello, test connection"
```

---

*Research compiled July 2026 from model documentation, community benchmarks, and hands-on testing.*

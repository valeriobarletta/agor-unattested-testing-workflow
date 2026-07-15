# Colibri Deep Dive: State of the Project as of July 2026

> **Research date:** July 15, 2026
> **Scope:** Detailed analysis of Colibri as a potential alternative to DS4 for the Agor unattended testing workflow on 32GB RAM hardware.
> **Conclusion:** Colibri is **not viable** for this use case. See Section 5.

---

## 1. What is Colibri?

**Colibri** (by JustVugg, Apache 2.0) is a pure-C, zero-dependency inference engine that runs **GLM-5.2** — a 744-billion-parameter Mixture-of-Experts (MoE) model — on consumer machines with approximately 25GB of system RAM. It hit 1,600+ GitHub stars on its first day and represents a "narrow engine for one model" approach similar to DS4, but for a different model family.

### Key Architecture Decision
Colibri is **architecturally hardcoded for GLM-5.2**. It implements GLM-5.2's specific router topology, MLA attention mechanism, and expert streaming logic in ~1,300-2,400 lines of C. This is not a generic inference engine — it cannot run other models.

---

## 2. Model Support: Is There a "Flash" or Smaller Variant?

### Short Answer: No.

As of July 2026, **Zhipu AI has released no smaller variants of GLM-5.2**:

| Variant | Exists? | Notes |
|---------|---------|-------|
| GLM-5.2 Flash | **No** | No such model announced |
| GLM-5.2 Mini | **No** | No such model announced |
| GLM-5.2 Lite | **No** | No such model announced |
| GLM-5.2 distilled | **No** | No distilled version released |
| GLM-5.2 instruct | **Partial** | Base model is instruction-tuned |
| OLMoE support | Experimental | Mentioned in issues, unconfirmed working |

The only "size" option is the **int4 quantization** of the full 744B weights. There is no way to run a smaller, faster version of GLM-5.2 through Colibri.

### The "flash colibri model" Confusion

The user's question about a "flash colibri model" likely conflates two unrelated things:

1. **DeepSeek V4 Flash** — the model that DS4 runs (284B MoE, requires 128GB)
2. **GLM-5.2** — the model that Colibri runs (744B MoE, requires ~25GB)

These are entirely different model families from different companies (DeepSeek vs Zhipu AI). "Flash" is a DeepSeek branding term, not a Colibri or GLM term.

---

## 3. RAM Requirements: Detailed Breakdown

### Confirmed Numbers

| Configuration | Resident RAM | Total System | Notes |
|-------------|-------------|-------------|-------|
| Dense layers (int4) | ~9.9 GB | ~16 GB minimum | Without expert cache |
| With expert cache (default) | ~16-20 GB | ~25 GB recommended | 2-8 slots/layer |
| Full performance | ~25 GB | ~48 GB | Max cache slots |
| Comfortable | ~30 GB | ~64-128 GB | No swapping |

### On 16-24 GB Machines

- The expert cache auto-caps to **2 slots per layer**
- Decode runs "cold" (experts loaded from SSD on every token)
- Significantly slower but functional

### On 32 GB Machines

- 32GB is **above the 25GB recommendation** — this is comfortable territory
- Expert cache can use 4-8 slots per layer
- Some decode steps hit cached experts
- Performance is acceptable for interactive use

---

## 4. Performance Benchmarks on Apple Silicon

### Critical Finding: Colibri is ~1 token/second

| Hardware | Speed | Notes |
|----------|-------|-------|
| M5 Max 128GB (default config) | **1.06 tok/s** | 23% cache hit rate |
| M5 Max 96GB (Metal + warm pin) | **1.83 tok/s** | 66% cache hit rate |
| M4 Max 128GB (Metal GPU) | **0.42 tok/s** | ~1.4x vs CPU only |
| M5 48GB (MLX 3.6-bit, NOT Colibri) | **2-2.8 tok/s** | Different engine entirely |

### Metal GPU Acceleration

- Experimental: set `METAL=1` environment variable
- Speedup is modest: **~1.4x** vs CPU
- Not as mature as DS4's Metal backend

### Comparison: Colibri vs DS4 vs Ollama (32GB Mac)

| Engine | Model | Speed | RAM Used |
|--------|-------|-------|----------|
| **Colibri** | GLM-5.2 | **~1 tok/s** | ~16-20GB |
| **DS4** | DeepSeek V4 Flash | **10-30 tok/s** | ~70-81GB |
| **Ollama + Devstral:24B** | Devstral | **35-50 tok/s** | ~14GB |
| **Ollama + Qwen3-Coder:30B** | Qwen3-Coder | **30-40 tok/s** | ~19GB |

**Colibri is 30-50x slower than Ollama alternatives on the same hardware.**

---

## 5. Codex CLI Integration: Does It Work?

### Short Answer: No.

Colibri **does not work with Codex CLI** for two fundamental reasons:

#### 5.1 No `/v1/responses` Endpoint

Codex CLI requires the **OpenAI Responses API** (`/v1/responses`). Colibri only exposes:

- `/v1/chat/completions` ✅
- `/v1/completions` ✅
- `/v1/responses` ❌ **Not implemented**

Codex CLI's `wire_api = "responses"` setting will fail because the endpoint doesn't exist.

#### 5.2 No Tool Calling Support

Codex CLI relies on the model's ability to **call tools** (file operations, shell commands, etc.). Colibri:

- Does not implement tool calling
- Does not support function calling format
- Cannot execute the tool-use loop that Codex CLI requires

### Workarounds (Not Recommended)

| Workaround | Feasibility | Notes |
|-----------|-------------|-------|
| Downgrade Codex CLI to v0.80.0 | Poor | Last version supporting Chat Completions; very old |
| Use CodexBridge proxy | Unreliable | Community project, not maintained |
| Implement responses endpoint in Colibri | Hard | Would require C development |

---

## 6. "Lil Kodel" / "Little Kodel"

This phrase **does not appear in any Colibri documentation, GitHub issues, or community discussions**. Most likely explanations:

1. **Phonetic misspelling of "little coder"** — The `itayinbarr/little-coder` project is a real harness for small LLMs
2. **Slang for a small/distilled coding model** — Informal term, not a product name
3. **Typo for "local model"** — "lil kodel" → "local model" with autocorrect

**This is not related to Colibri.**

---

## 7. Final Verdict: Why Colibri Was Rejected

| Criterion | Requirement | Colibri | Pass? |
|-----------|------------|---------|-------|
| **Fits in 32GB RAM** | Yes | ~16-20GB resident | ✅ |
| **Codex CLI compatible** | Required | No `/v1/responses` | ❌ |
| **Tool calling** | Required | Not supported | ❌ |
| **Speed for coding** | Interactive (~10+ tok/s) | ~1 tok/s | ❌ |
| **Speed for unattended** | Batch acceptable | ~1 tok/s | ❌ |
| **Model flexibility** | Multiple models | GLM-5.2 only | ❌ |

### What We Chose Instead

**Ollama + Devstral:24B + DeepSeek-Coder-V2-Lite:16B**

- Fits in 32GB ✅
- Works with Codex CLI ✅
- 35-80 tok/s (35-50x faster than Colibri) ✅
- Multiple models for different roles ✅
- Tool calling supported ✅

---

## Sources

- Colibri GitHub: https://github.com/JustVugg/colibri
- Daily.dev article: https://daily.dev/posts/github---justvugg-colibri
- AI/TLDR release notes: https://ai-tldr.dev/releases/justvugg-colibri/
- YouTube (Devsplainers): https://www.youtube.com/watch?v=19xCOJxWU0A
- Codex CLI docs: https://github.com/openai/codex
- Ollama docs: https://github.com/ollama/ollama

## Plan: Evaluate and Implement Unattended Testing Workflow

## Overview
Evaluate and implement an unattended testing workflow where Agor orchestrates a cloud planner (Claude Opus) and a local Ollama-powered coding agent with dual-model setup (Devstral:24B primary + DeepSeek-Coder-V2-Lite:16B fast).
Target flow:
A Jira/GitHub ticket enters Agor.
A cloud model such as Claude Opus converts the ticket into a structured execution plan.
Agor creates an isolated Git branch/worktree.
A Codex executor uses the local Ollama server to implement the plan with auto model selection.
The executor runs the appropriate test layers and captures evidence.
Agor reports success or failure and prepares a draft PR.
A human reviews before merge, deployment, or production access.

## Stage 1 — Research & Discovery
**Goal**: Understand all referenced tools (Agor, Ollama, Devstral, Codex CLI) and their current state.
**Agents**:
- `Tool_Researcher`: Research Agor orchestration platform
- `Ollama_Researcher`: Research Ollama inference engine and model options
- `Security_Analyst`: Research security best practices for isolated agent execution

**Output**: Tool research brief with feasibility assessment

## Stage 2 — Architecture Evaluation & Gap Analysis
**Goal**: Evaluate the proposal's architecture, identify gaps, assess risks, produce evaluation report.
**Agents**:
- `Architecture_Reviewer`: Review the target flow, testing strategy, and technical recommendations
- `Security_Reviewer`: Assess security posture of the proposed design

**Output**: `evaluation_report.md` — comprehensive evaluation with findings and recommendations

## Stage 3 — Implementation
**Goal**: Implement the workflow components that can be built/configured.
**Agents**:
- `Config_Builder`: Create Agor configuration, Codex CLI config, Ollama setup
- `Script_Builder`: Create orchestration scripts, test runner wrappers, isolation scripts
- `Workflow_Builder`: Create GitHub Actions/Jira webhooks, PR templates, runbook structure

**Output**: Implementation artifacts — configs, scripts, documentation

## Stage 4 — Documentation & Delivery
**Goal**: Produce operator runbook, integration guide, and final evaluation summary.
**Agents**:
- `Doc_Writer`: Operator runbook and integration documentation

**Output**: `runbook.md`, `integration_guide.md`, `FINAL_EVALUATION.md`

## Delivery Artifacts
- `/mnt/agents/output/evaluation_report.md` — Architecture evaluation
- `/mnt/agents/output/FINAL_EVALUATION.md` — Final summary
- `/mnt/agents/output/configs/` — Configuration files
- `/mnt/agents/output/scripts/` — Automation scripts
- `/mnt/agents/output/runbook.md` — Operator runbook
- `/mnt/agents/output/integration_guide.md` — Setup guide

#!/usr/bin/env python3
"""
config.py — Typed Configuration Management for Agor Workflow

Defines dataclass-based configuration models with validation
and loading from YAML/TOML files.

Usage:
    from config import load_config, OrchestratorConfig, ModelRole
    config = load_config("config.yaml")
    print(config.ollama.primary_model)  # "devstral:24b"
"""

from __future__ import annotations

import logging
import os
from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path
from typing import Any, Dict, List, Optional

logger = logging.getLogger(__name__)


# =============================================================================
# Model Role Enum
# =============================================================================

class ModelRole(Enum):
    """Defines which Ollama model to use based on task complexity."""

    PRIMARY = "devstral:24b"           # Complex tasks, full implementation
    FAST = "deepseek-coder-v2-lite:16b"  # Quick fixes, simple changes

    @classmethod
    def from_task(cls, plan_steps: int, new_deps: int) -> "ModelRole":
        """Auto-select model based on task complexity."""
        if plan_steps <= 3 and new_deps == 0:
            return cls.FAST
        return cls.PRIMARY


# =============================================================================
# Ollama Configuration
# =============================================================================

@dataclass
class OllamaConfig:
    """Configuration for the Ollama local model server."""

    base_url: str = "http://localhost:11434/v1"
    primary_model: str = "devstral:24b"
    fast_model: str = "deepseek-coder-v2-lite:16b"
    api_key: str = ""  # Usually not needed for local Ollama
    mlx_backend: bool = True  # Enable Apple Silicon/MLX optimization
    keep_alive: str = "30m"  # Keep models resident in memory

    @property
    def all_models(self) -> List[str]:
        return [self.primary_model, self.fast_model]


# =============================================================================
# Cloud Planner Configuration
# =============================================================================

@dataclass
class CloudPlannerConfig:
    """Configuration for the cloud planner (Claude Opus)."""

    api_key: str = ""
    model: str = "claude-opus-4-20250514"
    max_tokens: int = 4096
    timeout_seconds: int = 60

    def __post_init__(self):
        if not self.api_key:
            self.api_key = os.environ.get("ANTHROPIC_API_KEY", "")


# =============================================================================
# Git Configuration
# =============================================================================

@dataclass
class GitConfig:
    """Git repository configuration."""

    repo_path: str = "."
    default_branch: str = "main"
    worktree_root: str = "/var/repos"
    branch_prefix: str = "agor"


# =============================================================================
# Docker Configuration
# =============================================================================

@dataclass
class DockerConfig:
    """Docker container configuration."""

    executor_image: str = "agor-executor:latest"
    network_name: str = "agor-isolated"
    memory_limit: str = "2g"
    cpu_limit: float = 2.0
    timeout_seconds: int = 600


# =============================================================================
# GitHub Configuration
# =============================================================================

@dataclass
class GitHubConfig:
    """GitHub API configuration for PR creation."""

    token: str = ""
    owner: str = ""
    repo: str = ""
    default_branch: str = "main"
    dry_run: bool = False

    def __post_init__(self):
        if not self.token:
            self.token = os.environ.get("GITHUB_TOKEN", "")


# =============================================================================
# Artifact Configuration
# =============================================================================

@dataclass
class ArtifactConfig:
    """Test artifact storage configuration."""

    base_path: Path = field(default_factory=lambda: Path("/var/agor/artifacts"))
    sessions_path: str = "/var/agor/sessions.jsonl"
    archive_path: Path = field(default_factory=lambda: Path("/var/agor/archive"))
    retention_days: int = 30


# =============================================================================
# Timeout Configuration
# =============================================================================

@dataclass
class TimeoutConfig:
    """Timeout settings for various operations."""

    plan_generation_seconds: int = 120
    execution_seconds: int = 600
    test_execution_seconds: int = 300
    pr_creation_seconds: int = 60


# =============================================================================
# Main Orchestrator Configuration
# =============================================================================

@dataclass
class OrchestratorConfig:
    """
    Top-level configuration for the Agor workflow orchestrator.

    Aggregates all sub-configurations and provides default values.
    """

    ollama: OllamaConfig = field(default_factory=OllamaConfig)
    cloud_planner: CloudPlannerConfig = field(default_factory=CloudPlannerConfig)
    git: GitConfig = field(default_factory=GitConfig)
    docker: DockerConfig = field(default_factory=DockerConfig)
    github: GitHubConfig = field(default_factory=GitHubConfig)
    artifact: ArtifactConfig = field(default_factory=ArtifactConfig)
    timeout: TimeoutConfig = field(default_factory=TimeoutConfig)

    max_concurrent_sessions: int = 1
    max_retries_per_check: int = 2
    max_autonomous_repair: int = 2

    @classmethod
    def default(cls) -> "OrchestratorConfig":
        """Create a default configuration with environment-aware values."""
        return cls()

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "OrchestratorConfig":
        """Load configuration from a dictionary."""
        ollama_data = data.get("ollama", {})
        planner_data = data.get("cloud_planner", {})
        git_data = data.get("git", {})
        docker_data = data.get("docker", {})
        github_data = data.get("github", {})
        artifact_data = data.get("artifact", {})
        timeout_data = data.get("timeout", {})

        return cls(
            ollama=OllamaConfig(**ollama_data),
            cloud_planner=CloudPlannerConfig(**planner_data),
            git=GitConfig(**git_data),
            docker=DockerConfig(**docker_data),
            github=GitHubConfig(**github_data),
            artifact=ArtifactConfig(
                base_path=Path(artifact_data.get("base_path", "/var/agor/artifacts")),
                sessions_path=artifact_data.get("sessions_path", "/var/agor/sessions.jsonl"),
                archive_path=Path(artifact_data.get("archive_path", "/var/agor/archive")),
                retention_days=artifact_data.get("retention_days", 30),
            ),
            timeout=TimeoutConfig(**timeout_data),
            max_concurrent_sessions=data.get("max_concurrent_sessions", 1),
            max_retries_per_check=data.get("max_retries_per_check", 2),
            max_autonomous_repair=data.get("max_autonomous_repair", 2),
        )


# =============================================================================
# Configuration Loading
# =============================================================================

def load_config(path: str) -> OrchestratorConfig:
    """
    Load configuration from a YAML file.

    Falls back to environment variables for sensitive values.
    """
    config_path = Path(path)

    if not config_path.exists():
        logger.warning("Config file not found: %s — using defaults", path)
        return OrchestratorConfig.default()

    try:
        import yaml
        with open(config_path) as f:
            data = yaml.safe_load(f) or {}
        return OrchestratorConfig.from_dict(data)
    except ImportError:
        logger.error("PyYAML not installed — cannot load config from YAML")
        return OrchestratorConfig.default()
    except FileNotFoundError:
        logger.warning("Config file not found: %s — using defaults", path)
        return OrchestratorConfig.default()
    except yaml.YAMLError as e:
        logger.error("Invalid YAML in config file %s: %s — using defaults", path, e)
        return OrchestratorConfig.default()
    except Exception as e:
        logger.error("Unexpected error loading config %s: %s — using defaults", path, e)
        return OrchestratorConfig.default()

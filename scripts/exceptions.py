#!/usr/bin/env python3
"""
Exception hierarchy for the Agor unattended testing workflow.

Provides structured error handling with context for debugging,
security violations, and operational issues.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional


# =============================================================================
# Base Exception
# =============================================================================

class AgorError(Exception):
    """Base exception for all Agor workflow errors."""

    def __init__(
        self,
        message: str,
        details: Dict[str, Any] | None = None,
    ) -> None:
        super().__init__(message)
        self.message = message
        self.details = details or {}

    def __str__(self) -> str:
        if self.details:
            return f"{self.message} | details={self.details}"
        return self.message


# =============================================================================
# Configuration Errors
# =============================================================================

class ConfigError(AgorError):
    """Configuration loading or validation error."""
    pass


class ConfigNotFoundError(ConfigError):
    """Configuration file not found."""
    pass


class ConfigParseError(ConfigError):
    """Configuration file parse error (invalid YAML/TOML)."""
    pass


class ConfigValidationError(ConfigError):
    """Configuration value validation error."""
    pass


# =============================================================================
# Security Errors
# =============================================================================

class SecurityError(AgorError):
    """Security violation detected — execution must halt."""
    pass


class PathEscapeError(SecurityError):
    """Attempted path traversal outside authorized root."""
    pass


class ForbiddenPathError(SecurityError):
    """Access to forbidden path detected."""
    pass


class ForbiddenCommandError(SecurityError):
    """Forbidden command execution attempted."""
    pass


class NetworkViolationError(SecurityError):
    """Unauthorized network access attempted."""
    pass


class SecretExposureError(SecurityError):
    """Potential secret exposure detected in output."""
    pass


class CredentialError(SecurityError):
    """Credential management error."""
    pass


class CredentialNotFoundError(CredentialError):
    """Required credential not found in secret store."""
    pass


class CredentialExpiredError(CredentialError):
    """Credential has expired (TTL exceeded)."""
    pass


# =============================================================================
# Plan Errors
# =============================================================================

class PlanError(AgorError):
    """Plan generation or validation error."""
    pass


class PlanGenerationError(PlanError):
    """Cloud planner failed to generate a plan."""
    pass


class PlanValidationError(PlanError):
    """Plan failed security policy validation."""

    def __init__(
        self,
        message: str,
        violations: List[Dict[str, Any]],
        plan_id: str | None = None,
        details: Dict[str, Any] | None = None,
    ) -> None:
        super().__init__(message, details)
        self.violations = violations
        self.plan_id = plan_id


class PlanTimeoutError(PlanError):
    """Plan execution exceeded maximum allowed time."""
    pass


# =============================================================================
# Session Errors
# =============================================================================

class SessionError(AgorError):
    """Session lifecycle management error."""
    pass


class SessionNotFoundError(SessionError):
    """Requested session does not exist."""
    pass


class SessionAlreadyActiveError(SessionError):
    """Cannot start a new session — maximum concurrent sessions reached."""
    pass


class SessionTimeoutError(SessionError):
    """Session exceeded configured timeout."""
    pass


# =============================================================================
# Execution Errors
# =============================================================================

class ExecutionError(AgorError):
    """Code execution or test running error."""
    pass


class ExecutorSpawnError(ExecutionError):
    """Failed to spawn Codex executor in container."""
    pass


class ExecutorTimeoutError(ExecutionError):
    """Executor exceeded maximum runtime."""
    pass


class ExecutorCrashError(ExecutionError):
    """Executor process crashed unexpectedly."""
    pass


class TestFailureError(ExecutionError):
    """One or more test layers failed."""

    def __init__(
        self,
        message: str,
        failed_tests: List[str],
        test_output: str | None = None,
        details: Dict[str, Any] | None = None,
    ) -> None:
        super().__init__(message, details)
        self.failed_tests = failed_tests
        self.test_output = test_output


class WorktreeError(ExecutionError):
    """Git worktree operation failed."""
    pass


class WorktreeCreateError(WorktreeError):
    """Failed to create Git worktree."""
    pass


class WorktreeCleanupError(WorktreeError):
    """Failed to clean up Git worktree."""
    pass


# =============================================================================
# Artifact Errors
# =============================================================================

class ArtifactError(AgorError):
    """Test artifact collection or storage error."""
    pass


class ArtifactNotFoundError(ArtifactError):
    """Expected artifact not found after test execution."""
    pass


class ArtifactParseError(ArtifactError):
    """Failed to parse test output format."""
    pass


# =============================================================================
# Pull Request Errors
# =============================================================================

class PRError(AgorError):
    """Pull request creation or management error."""
    pass


class PRPushError(PRError):
    """Failed to push branch to remote."""
    pass


class PRCreationError(PRError):
    """Failed to create pull request via GitHub API."""
    pass


# =============================================================================
# Ollama Errors
# =============================================================================

class OllamaError(AgorError):
    """Ollama server communication or model error."""

    def __init__(
        self,
        message: str,
        model: str | None = None,
        status_code: int | None = None,
        response_body: str | None = None,
        details: Dict[str, Any] | None = None,
    ) -> None:
        super().__init__(message, details)
        self.model = model
        self.status_code = status_code
        self.response_body = response_body


class ModelNotAvailableError(OllamaError):
    """Requested model is not loaded or available in Ollama."""
    pass


class ModelLoadError(OllamaError):
    """Failed to load model into Ollama (OOM, corrupt file, etc.)."""
    pass


# =============================================================================
# Orchestrator Errors
# =============================================================================

class OrchestratorError(AgorError):
    """Top-level workflow orchestration error."""
    pass


class WorkflowAbortedError(OrchestratorError):
    """Workflow was manually aborted by operator."""
    pass


class MaxRetriesExceededError(OrchestratorError):
    """Maximum retry attempts exceeded for a recoverable operation."""
    pass


class NonDeterministicFailureError(OrchestratorError):
    """
    Failure appears non-deterministic (flaky tests, race conditions).
    Human review required.
    """
    pass


class AmbiguousRequirementError(OrchestratorError):
    """
    Ticket requirements are ambiguous or self-contradictory.
    Human clarification required.
    """
    pass


# =============================================================================
# Cloud Planner Errors
# =============================================================================

class CloudPlannerError(AgorError):
    """Cloud planner (Claude Opus) API error."""
    pass


class PlannerAPIError(CloudPlannerError):
    """API call to cloud planner failed."""
    pass


class PlannerRateLimitError(CloudPlannerError):
    """Rate limit exceeded for cloud planner API."""
    pass

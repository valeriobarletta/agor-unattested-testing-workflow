#!/usr/bin/env python3
"""
policy_engine.py — Plan Validation and Runtime Policy Enforcement

Validates execution plans against security policies before allowing
Codex CLI to execute. Implements multi-layer validation: schema,
paths, commands, network, resources, dependencies, models, and signatures.

Usage:
    from policy_engine import PolicyEngine, SecurityPolicy, create_default_policy
    policy = create_default_policy()
    engine = PolicyEngine(policy)
    result = engine.validate_plan(plan)
    if not result.passed:
        for v in result.violations:
            print(f"  [{v.severity}] {v.rule}: {v.message}")
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
import re
from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Set

from exceptions import PlanValidationError, SecurityError

logger = logging.getLogger(__name__)


# =============================================================================
# Risk Level and Action Enums
# =============================================================================

class RiskLevel(Enum):
    LOW = "low"
    MEDIUM = "medium"
    HIGH = "high"
    CRITICAL = "critical"


class Action(Enum):
    ALLOW = "allow"
    DENY = "deny"
    REQUIRE_APPROVAL = "require_approval"


# =============================================================================
# Data Models
# =============================================================================

@dataclass
class PolicyRule:
    name: str
    description: str
    risk_level: RiskLevel
    action: Action
    condition: Optional[Callable] = None


@dataclass
class SecurityPolicy:
    """
    Comprehensive security policy for plan validation.

    Defines what the executor is allowed to do: which files it can touch,
    which commands it can run, which models it can use, and what resources
    it can consume.
    """

    name: str = "codex-executor-default"
    version: str = "1.0"

    # Filesystem restrictions
    allowed_paths: List[str] = field(default_factory=lambda: [
        "/workspace/src",
        "/workspace/tests",
        "/workspace/docs",
    ])
    forbidden_paths: List[str] = field(default_factory=lambda: [
        "/workspace/.github",
        "/workspace/infra",
        "/workspace/secrets",
        "/workspace/.env",
        "/workspace/deploy",
        "/workspace/scripts",
    ])
    max_files_per_plan: int = 20
    max_lines_per_file: int = 500

    # Command restrictions
    allowed_commands: List[str] = field(default_factory=lambda: [
        "npm", "node", "npx",
        "python", "python3", "pytest",
        "git", "cat", "grep", "find",
        "ls", "pwd", "echo", "mkdir",
        "cp", "mv", "rm", "touch",
        "eslint", "prettier", "black", "flake8",
        "cargo", "rustc",
    ])
    forbidden_commands: List[str] = field(default_factory=lambda: [
        "curl", "wget", "nc", "netcat", "ssh", "scp", "sftp",
        "telnet", "nmap", "ping", "traceroute",
        "sudo", "su", "pkexec", "doas",
        "eval", "exec", "source",
        "docker", "kubectl", "helm",
        "ncat", "socat", "tcpdump", "wireshark",
        "base64", "xxd", "od", "hexdump",
    ])
    forbidden_patterns: List[str] = field(default_factory=list)

    # Model restrictions
    allowed_models: List[str] = field(default_factory=lambda: [
        "devstral:24b",
        "deepseek-coder-v2-lite:16b",
    ])

    # Network restrictions
    network_access: bool = False
    allowed_domains: List[str] = field(default_factory=list)

    # Dependency restrictions
    pre_approved_dependencies: List[str] = field(default_factory=list)
    require_approval_for_new_deps: bool = True

    # Resource limits
    max_execution_time_seconds: int = 600
    max_memory_mb: int = 2048
    max_cpu_cores: float = 2.0

    # Signing
    require_signed_plans: bool = False
    trusted_signers: List[str] = field(default_factory=list)


@dataclass
class PolicyViolation:
    rule: str
    message: str
    severity: RiskLevel


@dataclass
class ValidationResult:
    plan_id: str
    passed: bool
    violations: List[PolicyViolation]

    @property
    def highest_severity(self) -> Optional[RiskLevel]:
        if not self.violations:
            return None
        severity_order = [RiskLevel.LOW, RiskLevel.MEDIUM, RiskLevel.HIGH, RiskLevel.CRITICAL]
        max_idx = max(severity_order.index(v.severity) for v in self.violations)
        return severity_order[max_idx]

    def to_dict(self) -> Dict[str, Any]:
        return {
            "plan_id": self.plan_id,
            "passed": self.passed,
            "violations": [
                {"rule": v.rule, "message": v.message, "severity": v.severity.value}
                for v in self.violations
            ],
            "highest_severity": self.highest_severity.value if self.highest_severity else None,
        }


# =============================================================================
# Policy Engine
# =============================================================================

class PolicyEngine:
    """
    Validates execution plans against security policies.

    Implements defense-in-depth through 7 validation layers:
    1. Schema validation
    2. Path validation (canonical, no traversal)
    3. Command whitelist
    4. Network policy
    5. Resource limits
    6. Dependency validation
    7. Model validation
    8. Signature verification (optional)
    """

    # Patterns that suggest exfiltration or malicious behavior
    EXFIL_PATTERNS = [
        re.compile(r'\bcurl\s+.*https?://'),
        re.compile(r'\bwget\s+.*https?://'),
        re.compile(r'\bfetch\*\(\s*["\']https?://'),
        re.compile(r'\bhttps?://\S+\.(png|jpg|gif|svg)\b'),  # Markdown image exfiltration
        re.compile(r'\bdns\s*exfil', re.IGNORECASE),
    ]

    FORBIDDEN_IMPORTS = [
        "os.system", "subprocess.call", "subprocess.run",
        "subprocess.Popen", "subprocess.check_output",
        "urllib.request", "urllib2", "requests.get", "requests.post",
        "socket", "ftplib", "smtplib",
    ]

    def __init__(self, policy: SecurityPolicy) -> None:
        self.policy = policy
        self.forbidden_patterns = [
            re.compile(p, re.IGNORECASE) for p in policy.forbidden_patterns
        ]

    # ------------------------------------------------------------------
    # Main validation entry point
    # ------------------------------------------------------------------

    def validate_plan(self, plan: Dict[str, Any]) -> ValidationResult:
        """
        Run all validation layers against a plan.

        Args:
            plan: The machine-readable execution plan (dict)

        Returns:
            ValidationResult with pass/fail status and all violations
        """
        violations: List[PolicyViolation] = []
        plan_id = plan.get("plan_id", "unknown")

        # Layer 1: Schema validation
        violations.extend(self._validate_schema(plan))

        # Layer 2: Path validation
        violations.extend(self._validate_paths(plan))

        # Layer 3: Command validation
        violations.extend(self._validate_commands(plan))

        # Layer 4: Network policy
        violations.extend(self._validate_network(plan))

        # Layer 5: Resource limits
        violations.extend(self._validate_resources(plan))

        # Layer 6: Dependency validation
        violations.extend(self._validate_dependencies(plan))

        # Layer 7: Model validation
        violations.extend(self._validate_model(plan))

        # Layer 8: Signature verification (optional)
        if self.policy.require_signed_plans:
            violations.extend(self._validate_signature(plan))

        passed = len(violations) == 0

        if not passed:
            logger.warning(
                "Plan %s failed validation with %d violations",
                plan_id, len(violations),
            )
            for v in violations:
                logger.warning("  [%s] %s: %s", v.severity.value, v.rule, v.message)

        return ValidationResult(
            plan_id=plan_id,
            passed=passed,
            violations=violations,
        )

    # ------------------------------------------------------------------
    # Validation layers
    # ------------------------------------------------------------------

    def _validate_schema(self, plan: Dict[str, Any]) -> List[PolicyViolation]:
        """Validate plan conforms to expected schema."""
        violations: List[PolicyViolation] = []
        required = ["plan_id", "steps", "security_context"]

        for field_name in required:
            if field_name not in plan:
                violations.append(PolicyViolation(
                    rule="schema_validation",
                    message=f"Missing required field: {field_name}",
                    severity=RiskLevel.CRITICAL,
                ))

        # Validate steps structure
        steps = plan.get("steps", [])
        if not isinstance(steps, list):
            violations.append(PolicyViolation(
                rule="schema_validation",
                message="'steps' must be a list",
                severity=RiskLevel.CRITICAL,
            ))

        return violations

    def _validate_paths(self, plan: Dict[str, Any]) -> List[PolicyViolation]:
        """Validate all file paths are within allowed directories."""
        violations: List[PolicyViolation] = []

        for step in plan.get("steps", []):
            target = step.get("target", "")
            if not target:
                continue

            try:
                canonical_str = os.path.realpath(str(target))
            except (OSError, ValueError) as e:
                violations.append(PolicyViolation(
                    rule="path_validation",
                    message=f"Cannot resolve path: {target} ({e})",
                    severity=RiskLevel.CRITICAL,
                ))
                continue

            # Check forbidden paths
            for fp in self.policy.forbidden_paths:
                fp_path = Path(fp)
                try:
                    if Path(canonical_str).is_relative_to(fp_path):
                        violations.append(PolicyViolation(
                            rule="forbidden_path",
                            message=f"Step targets forbidden path: {target}",
                            severity=RiskLevel.CRITICAL,
                        ))
                except (ValueError, OSError):
                    pass

            # Check allowed paths
            in_allowed = False
            for allowed in self.policy.allowed_paths:
                allowed_str = os.path.realpath(allowed)
                try:
                    os.path.commonpath([canonical_str, allowed_str])
                    if canonical_str == allowed_str or canonical_str.startswith(allowed_str + os.sep):
                        in_allowed = True
                        break
                except ValueError:
                    continue

            if not in_allowed and self.policy.allowed_paths:
                violations.append(PolicyViolation(
                    rule="path_not_allowed",
                    message=f"Step targets path outside allowed set: {target}",
                    severity=RiskLevel.HIGH,
                ))

            # Check for path traversal
            if ".." in target:
                violations.append(PolicyViolation(
                    rule="path_traversal",
                    message=f"Path traversal detected: {target}",
                    severity=RiskLevel.CRITICAL,
                ))

        return violations

    def _validate_commands(self, plan: Dict[str, Any]) -> List[PolicyViolation]:
        """Validate all commands are on the allowed list."""
        violations: List[PolicyViolation] = []

        for step in plan.get("steps", []):
            command = step.get("command", "")
            if not command:
                continue

            cmd_name = command.split()[0]

            # Check forbidden commands
            if cmd_name in self.policy.forbidden_commands:
                violations.append(PolicyViolation(
                    rule="forbidden_command",
                    message=f"Forbidden command: {cmd_name}",
                    severity=RiskLevel.CRITICAL,
                ))

            # Check forbidden patterns
            for pattern in self.forbidden_patterns:
                if pattern.search(command):
                    violations.append(PolicyViolation(
                        rule="forbidden_pattern",
                        message=f"Command matches forbidden pattern: {pattern.pattern}",
                        severity=RiskLevel.CRITICAL,
                    ))

            # Check allowed commands
            if self.policy.allowed_commands:
                if cmd_name not in self.policy.allowed_commands:
                    violations.append(PolicyViolation(
                        rule="command_not_allowed",
                        message=f"Command not in allowlist: {cmd_name}",
                        severity=RiskLevel.HIGH,
                    ))

        return violations

    def _validate_network(self, plan: Dict[str, Any]) -> List[PolicyViolation]:
        """Validate network access policy."""
        violations: List[PolicyViolation] = []

        security = plan.get("security_context", {})
        wants_network = security.get("network_access", False)

        if wants_network and not self.policy.network_access:
            violations.append(PolicyViolation(
                rule="network_denied",
                message="Plan requests network access but policy denies it",
                severity=RiskLevel.HIGH,
            ))

        return violations

    def _validate_resources(self, plan: Dict[str, Any]) -> List[PolicyViolation]:
        """Validate resource limits."""
        violations: List[PolicyViolation] = []

        steps = plan.get("steps", [])
        if len(steps) > self.policy.max_files_per_plan:
            violations.append(PolicyViolation(
                rule="max_files_exceeded",
                message=f"Plan modifies too many files: {len(steps)} > {self.policy.max_files_per_plan}",
                severity=RiskLevel.MEDIUM,
            ))

        security = plan.get("security_context", {})
        requested_time = security.get("max_execution_time", 0)
        if requested_time > self.policy.max_execution_time_seconds:
            violations.append(PolicyViolation(
                rule="max_time_exceeded",
                message=f"Execution time {requested_time}s exceeds limit {self.policy.max_execution_time_seconds}s",
                severity=RiskLevel.MEDIUM,
            ))

        return violations

    def _validate_dependencies(self, plan: Dict[str, Any]) -> List[PolicyViolation]:
        """Validate new dependencies against pre-approved list."""
        violations: List[PolicyViolation] = []

        new_deps = plan.get("new_dependencies", [])
        for dep in new_deps:
            if dep not in self.policy.pre_approved_dependencies:
                violations.append(PolicyViolation(
                    rule="unapproved_dependency",
                    message=f"New dependency requires approval: {dep}",
                    severity=RiskLevel.HIGH,
                ))

        return violations

    def _validate_model(self, plan: Dict[str, Any]) -> List[PolicyViolation]:
        """Validate requested model is in allowed list."""
        violations: List[PolicyViolation] = []

        model = plan.get("model", "")
        if not model:
            return violations

        if model not in self.policy.allowed_models:
            violations.append(PolicyViolation(
                rule="model_not_allowed",
                message=f"Model '{model}' not in allowed list: {self.policy.allowed_models}",
                severity=RiskLevel.CRITICAL,
            ))

        return violations

    def _validate_signature(self, plan: Dict[str, Any]) -> List[PolicyViolation]:
        """Verify cryptographic signature on plan (placeholder)."""
        violations: List[PolicyViolation] = []

        signature = plan.get("signature", "")
        if not signature:
            violations.append(PolicyViolation(
                rule="missing_signature",
                message="Plan signature is required but missing",
                severity=RiskLevel.CRITICAL,
            ))

        return violations


# =============================================================================
# Plan Validator (Semantic Validation)
# =============================================================================

class PlanValidator:
    """
    Additional semantic validation beyond the policy engine.

    Checks for suspicious patterns in code changes, potential
    prompt injection indicators, and forbidden imports.
    """

    def __init__(self) -> None:
        self.exfil_patterns = [
            re.compile(r'https?://\S+\.(png|jpg|gif)\s*\)'),
            re.compile(r'\bdns\s*query|\bdns\s*exfil', re.IGNORECASE),
        ]

    def validate_code_changes(self, diff: str) -> List[Dict[str, Any]]:
        """
        Scan a code diff for suspicious patterns.

        Returns list of findings with severity and description.
        """
        findings: List[Dict[str, Any]] = []

        # Check for potential exfiltration
        for pattern in self.exfil_patterns:
            for match in pattern.finditer(diff):
                findings.append({
                    "severity": "high",
                    "type": "potential_exfiltration",
                    "match": match.group(),
                    "line": diff[:match.start()].count("\n") + 1,
                })

        # Check for forbidden imports
        forbidden = ["os.system", "subprocess.call", "urllib.request", "socket"]
        for imp in forbidden:
            if imp in diff:
                findings.append({
                    "severity": "critical",
                    "type": "forbidden_import",
                    "match": imp,
                })

        return findings

    def check_prompt_injection(self, text: str) -> List[Dict[str, Any]]:
        """
        Check for potential prompt injection indicators in ticket content.

        This is a best-effort defense — prompt injection cannot be fully prevented.
        """
        findings: List[Dict[str, Any]] = []

        injection_patterns = [
            (re.compile(r'ignore\s+(all\s+)?previous\s+instructions', re.IGNORECASE), "ignore_instructions"),
            (re.compile(r'ignore\s+(all\s+)?above', re.IGNORECASE), "ignore_above"),
            (re.compile(r'you\s+(are\s+)?(now\s+)?(an?\s+)?(unrestricted|uncensored)', re.IGNORECASE), "jailbreak_attempt"),
            (re.compile(r'DAN\s+mode|do\s+anything\s+now', re.IGNORECASE), "jailbreak_attempt"),
            (re.compile(r'~\s*\{', re.IGNORECASE), "template_injection"),
        ]

        for pattern, attack_type in injection_patterns:
            if pattern.search(text):
                findings.append({
                    "severity": "high",
                    "type": attack_type,
                    "match": pattern.search(text).group() if pattern.search(text) else "",
                })

        return findings


# =============================================================================
# Convenience Functions
# =============================================================================

def create_default_policy() -> SecurityPolicy:
    """Create a sensible default security policy."""
    return SecurityPolicy(
        name="codex-executor-default",
        version="1.0",
        allowed_paths=[
            "/workspace/src",
            "/workspace/tests",
            "/workspace/docs",
            "/workspace/public",
            "/workspace/lib",
        ],
        forbidden_paths=[
            "/workspace/.github",
            "/workspace/infra",
            "/workspace/secrets",
            "/workspace/.env",
            "/workspace/deploy",
            "/workspace/scripts",
            "/workspace/.ssh",
            "/workspace/.aws",
        ],
        allowed_models=[
            "devstral:24b",
            "deepseek-coder-v2-lite:16b",
        ],
        network_access=False,
        max_execution_time_seconds=600,
        max_memory_mb=2048,
    )


def validate_plan(plan: Dict[str, Any], policy: SecurityPolicy | None = None) -> ValidationResult:
    """One-shot plan validation with optional custom policy."""
    if policy is None:
        policy = create_default_policy()
    engine = PolicyEngine(policy)
    return engine.validate_plan(plan)

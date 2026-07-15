#!/usr/bin/env python3
"""
pr_generator.py — Draft PR Creation for Agor Workflow

Generates pull request descriptions from test results and code changes,
pushes branches, and creates PRs via the GitHub API.

Usage:
    from pr_generator import PRGenerator
    pr = PRGenerator(config)
    pr.create_pr_from_work(worktree_path, branch, title, description, results)
"""

from __future__ import annotations

import json
import logging
import subprocess
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

from config import GitHubConfig

logger = logging.getLogger(__name__)


# =============================================================================
# Data Models
# =============================================================================

@dataclass
class PRResult:
    """Result of a PR creation operation."""
    success: bool
    pr_url: str = ""
    pr_number: int = 0
    branch_pushed: bool = False
    error: str = ""

    def to_dict(self) -> Dict[str, Any]:
        return {
            "success": self.success,
            "pr_url": self.pr_url,
            "pr_number": self.pr_number,
            "branch_pushed": self.branch_pushed,
            "error": self.error,
        }


# =============================================================================
# PR Generator
# =============================================================================

class PRGenerator:
    """
    Generates draft pull requests from completed Agor executor work.

    Combines Git operations (branch push) with GitHub API calls to create
    fully-documented PRs with test evidence and execution context.
    """

    def __init__(self, config: GitHubConfig) -> None:
        self.config = config
        self._token = config.token
        self._api_base = "https://api.github.com"

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def create_pr_from_work(
        self,
        worktree_path: Path,
        branch_name: str,
        ticket_ref: str,
        plan: Dict[str, Any],
        test_results: Dict[str, Any],
        model_used: str | None = None,
        dry_run: bool = False,
    ) -> PRResult:
        """
        Full workflow: push branch → generate description → create PR.

        Args:
            worktree_path: Path to the Git worktree
            branch_name: Name of the branch to push
            ticket_ref: Original ticket reference (e.g., "JIRA-123")
            plan: The execution plan that was used
            test_results: Collected test results
            model_used: Which local model executed the work
            dry_run: If True, skip actual push/PR creation

        Returns:
            PRResult with success status and PR URL
        """
        logger.info("Creating PR from work: branch=%s ticket=%s", branch_name, ticket_ref)

        # 1. Push branch
        if not dry_run:
            push_ok = self.push_branch(worktree_path, branch_name)
            if not push_ok:
                return PRResult(success=False, error="Failed to push branch")
        else:
            logger.info("[DRY RUN] Would push branch: %s", branch_name)

        # 2. Generate title and description
        title = self.generate_title(ticket_ref, plan)
        description = self.generate_description(
            worktree_path, test_results, plan, model_used
        )

        # 3. Create PR
        if dry_run:
            logger.info("[DRY RUN] Would create PR:\n  Title: %s\n  Body: %d chars", title, len(description))
            return PRResult(success=True, pr_url="dry-run", branch_pushed=True)

        return self.create_pr(title, description, branch_name, self.config.default_branch)

    def generate_title(self, ticket_ref: str, plan: Dict[str, Any]) -> str:
        """Generate a concise PR title from ticket and plan."""
        steps = plan.get("steps", [])
        first_step = steps[0] if steps else {}
        action_desc = first_step.get("description", "Implement changes")

        # Truncate if too long
        max_len = 72
        title = f"[{ticket_ref}] {action_desc}"
        if len(title) > max_len:
            title = title[: max_len - 3] + "..."
        return title

    def generate_description(
        self,
        worktree_path: Path,
        test_results: Dict[str, Any],
        plan: Dict[str, Any],
        model_used: str | None = None,
    ) -> str:
        """
        Generate a comprehensive PR description with:
        - Summary of changes
        - Test evidence (pass/fail with links)
        - Execution plan context
        - Model information
        """
        lines: List[str] = []

        # Header
        lines.append("## Summary")
        lines.append("")
        acceptance = plan.get("acceptance_criteria", [])
        for criterion in acceptance:
            lines.append(f"- [x] {criterion}")
        lines.append("")

        # Model information
        if model_used:
            lines.append("## Model Information")
            lines.append(f"- **Model used**: `{model_used}`")
            if "devstral" in model_used.lower():
                lines.append("- **Backend**: Ollama (MLX)")
                lines.append("- **Role**: Complex implementation — auto-selected for multi-step tasks")
            elif "lite" in model_used.lower():
                lines.append("- **Backend**: Ollama (MLX)")
                lines.append("- **Role**: Quick fix — auto-selected for simple tasks")
            lines.append("")

        # Changes
        lines.append("## Changes")
        for step in plan.get("steps", []):
            action = step.get("action", "modify")
            target = step.get("target", "unknown")
            desc = step.get("description", "")
            icon = {"create": "📝", "modify": "🔧", "delete": "🗑️"}.get(action, "🔧")
            lines.append(f"- {icon} **`{target}`** — {desc}")
        lines.append("")

        # Test evidence
        lines.append("## Test Evidence")
        lines.append("")

        overall = test_results.get("overall", {})
        status = overall.get("status", "unknown")
        icon = "✅" if status == "passed" else "❌" if status == "failed" else "⚠️"
        lines.append(f"### Overall: {icon} {status.upper()}")
        lines.append("")

        for layer in ["static_validation", "unit_tests", "integration_tests", "e2e_tests"]:
            layer_results = test_results.get(layer, {})
            if not layer_results:
                continue
            layer_name = layer.replace("_", " ").title()
            passed = layer_results.get("passed", 0)
            failed = layer_results.get("failed", 0)
            skipped = layer_results.get("skipped", 0)
            icon = "✅" if failed == 0 else "❌"
            lines.append(f"- {icon} **{layer_name}**: {passed} passed, {failed} failed, {skipped} skipped")

        lines.append("")

        # Coverage
        coverage = test_results.get("coverage", {})
        if coverage:
            lines.append("### Coverage")
            pct = coverage.get("percentage", "N/A")
            lines.append(f"- Line coverage: **{pct}%**")
            lines.append("")

        # Plan context
        lines.append("## Execution Plan")
        lines.append(f"```json\n{json.dumps(plan, indent=2)}\n```")
        lines.append("")

        # Footer
        lines.append("---")
        lines.append("*This PR was drafted by the Agor unattended testing workflow.*")
        lines.append("*Human review is required before merge.*")

        return "\n".join(lines)

    def push_branch(self, worktree_path: Path, branch_name: str) -> bool:
        """Push the worktree branch to the remote repository."""
        logger.info("Pushing branch: %s from %s", branch_name, worktree_path)

        try:
            # Configure Git with isolated settings (no hooks, no credential helpers)
            env = {
                "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_CONFIG_GLOBAL": "/dev/null",
                "GIT_TERMINAL_PROMPT": "0",
            }

            # Check if remote exists
            result = subprocess.run(
                ["git", "remote", "get-url", "origin"],
                cwd=worktree_path,
                capture_output=True,
                text=True,
                env=env,
            )
            if result.returncode != 0:
                logger.error("No remote 'origin' configured in worktree")
                return False

            remote_url = result.stdout.strip()

            # Inject token into remote URL if using HTTPS
            if remote_url.startswith("https://") and self._token:
                remote_url = remote_url.replace(
                    "https://", f"https://x-access-token:{self._token}@"
                )

            # Set remote with token
            subprocess.run(
                ["git", "remote", "set-url", "origin", remote_url],
                cwd=worktree_path,
                check=True,
                env=env,
            )

            # Push branch
            subprocess.run(
                ["git", "push", "-u", "origin", branch_name],
                cwd=worktree_path,
                check=True,
                capture_output=True,
                env=env,
            )

            logger.info("Branch pushed: %s", branch_name)
            return True

        except subprocess.CalledProcessError as e:
            logger.error("Git push failed: %s", e.stderr.decode() if e.stderr else str(e))
            return False

    def create_pr(
        self,
        title: str,
        description: str,
        head_branch: str,
        base_branch: str = "main",
    ) -> PRResult:
        """Create a pull request via the GitHub API."""
        logger.info("Creating PR: %s → %s", head_branch, base_branch)

        url = f"{self._api_base}/repos/{self.config.owner}/{self.config.repo}/pulls"
        payload = json.dumps({
            "title": title,
            "body": description,
            "head": head_branch,
            "base": base_branch,
            "draft": True,
        }).encode()

        headers = {
            "Authorization": f"token {self._token}",
            "Accept": "application/vnd.github.v3+json",
            "Content-Type": "application/json",
        }

        try:
            req = urllib.request.Request(url, data=payload, headers=headers, method="POST")
            with urllib.request.urlopen(req, timeout=30) as resp:
                data = json.loads(resp.read())
                pr_number = data.get("number", 0)
                pr_url = data.get("html_url", "")
                logger.info("PR created: #%d %s", pr_number, pr_url)
                return PRResult(
                    success=True,
                    pr_url=pr_url,
                    pr_number=pr_number,
                    branch_pushed=True,
                )

        except urllib.error.HTTPError as e:
            body = e.read().decode()
            logger.error("GitHub API error: %d %s", e.code, body)
            return PRResult(success=False, error=f"GitHub API {e.code}: {body}")

        except Exception as e:
            logger.error("PR creation failed: %s", e)
            return PRResult(success=False, error=str(e))

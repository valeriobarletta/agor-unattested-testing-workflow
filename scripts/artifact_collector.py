#!/usr/bin/env python3
"""
artifact_collector.py — Test Artifact Collection and Reporting

Collects, parses, and organizes test outputs from multiple frameworks.
Supports Jest, Vitest, pytest, and Playwright output formats.

Usage:
    from artifact_collector import ArtifactCollector, TestResult
    collector = ArtifactCollector(config)
    result = collector.parse_test_results(raw_output, "jest")
    collector.store_artifacts(session_id, test_results, model_used)
"""

from __future__ import annotations

import json
import logging
import shutil
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

from config import ArtifactConfig

logger = logging.getLogger(__name__)


# =============================================================================
# Data Models
# =============================================================================

@dataclass
class TestResult:
    """Result of a single test layer execution."""

    test_type: str          # static_validation, unit_tests, etc.
    command: str            # The command that was run
    exit_code: int
    passed: int = 0
    failed: int = 0
    skipped: int = 0
    duration_seconds: float = 0.0
    output_path: str = ""
    framework: str = "unknown"

    @property
    def success(self) -> bool:
        return self.exit_code == 0 and self.failed == 0

    def to_dict(self) -> Dict[str, Any]:
        return {
            "test_type": self.test_type,
            "command": self.command,
            "exit_code": self.exit_code,
            "passed": self.passed,
            "failed": self.failed,
            "skipped": self.skipped,
            "duration_seconds": self.duration_seconds,
            "success": self.success,
            "framework": self.framework,
        }


@dataclass
class TestSummary:
    """Summary of all test layers for a session."""

    session_id: str
    overall_status: str = "unknown"
    layers: Dict[str, TestResult] = field(default_factory=dict)
    coverage_percentage: float = 0.0
    artifacts_path: str = ""
    model_used: str = ""
    timestamp: str = field(default_factory=lambda: datetime.now(timezone.utc).isoformat())

    def to_dict(self) -> Dict[str, Any]:
        return {
            "session_id": self.session_id,
            "overall_status": self.overall_status,
            "layers": {k: v.to_dict() for k, v in self.layers.items()},
            "coverage_percentage": self.coverage_percentage,
            "artifacts_path": self.artifacts_path,
            "model_used": self.model_used,
            "timestamp": self.timestamp,
        }


# =============================================================================
# Artifact Collector
# =============================================================================

class ArtifactCollector:
    """
    Collects and organizes test artifacts from executor runs.

    Parses output from multiple test frameworks and stores artifacts
    in a structured directory hierarchy.
    """

    def __init__(self, config: ArtifactConfig) -> None:
        self.config = config

    # ------------------------------------------------------------------
    # Test Output Parsing
    # ------------------------------------------------------------------

    def parse_test_results(self, raw_output: str, test_type: str) -> TestResult:
        """
        Parse raw test output and extract pass/fail counts.

        Auto-detects the test framework from output patterns.
        """
        framework = self._detect_framework(raw_output)

        parsers = {
            "jest": self._parse_jest,
            "vitest": self._parse_vitest,
            "pytest": self._parse_pytest,
            "playwright": self._parse_playwright,
            "cargo": self._parse_cargo,
        }

        parser = parsers.get(framework, self._parse_generic)
        passed, failed, skipped = parser(raw_output)

        return TestResult(
            test_type=test_type,
            command="",
            exit_code=0 if failed == 0 else 1,
            passed=passed,
            failed=failed,
            skipped=skipped,
            framework=framework,
        )

    def _detect_framework(self, output: str) -> str:
        """Auto-detect test framework from output patterns."""
        if "PASS" in output and "FAIL" in output and ("jest" in output.lower() or "●" in output):
            return "jest"
        if "Vitest" in output or "vitest" in output.lower():
            return "vitest"
        if "pytest" in output.lower() or ("=== " in output and "passed" in output):
            return "pytest"
        if "Playwright" in output or "pw:api" in output:
            return "playwright"
        if "test result:" in output and "passed" in output:
            return "cargo"
        return "generic"

    def _parse_jest(self, output: str) -> tuple:
        """Parse Jest output for pass/fail counts."""
        passed, failed, skipped = 0, 0, 0
        import re
        # "Tests: 5 passed, 1 failed, 2 skipped"
        match = re.search(r'Tests:\s+(\d+)\s+passed(?:,\s+(\d+)\s+failed)?(?:,\s+(\d+)\s+skipped)?', output)
        if match:
            passed = int(match.group(1))
            failed = int(match.group(2) or 0)
            skipped = int(match.group(3) or 0)
        return passed, failed, skipped

    def _parse_vitest(self, output: str) -> tuple:
        """Parse Vitest output."""
        passed, failed, skipped = 0, 0, 0
        import re
        passed_matches = re.findall(r'(\d+)\s+passed', output)
        failed_matches = re.findall(r'(\d+)\s+failed', output)
        if passed_matches:
            passed = int(passed_matches[-1])
        if failed_matches:
            failed = int(failed_matches[-1])
        return passed, failed, skipped

    def _parse_pytest(self, output: str) -> tuple:
        """Parse pytest output."""
        passed, failed, skipped = 0, 0, 0
        import re
        # "3 passed, 1 failed, 2 skipped in 0.5s"
        match = re.search(r'(\d+)\s+passed.*?(\d+)\s+failed.*?(\d+)\s+skipped', output)
        if match:
            passed = int(match.group(1))
            failed = int(match.group(2))
            skipped = int(match.group(3))
        else:
            # Try simpler pattern
            match = re.search(r'(\d+)\s+passed', output)
            if match:
                passed = int(match.group(1))
            match = re.search(r'(\d+)\s+failed', output)
            if match:
                failed = int(match.group(1))
            match = re.search(r'(\d+)\s+skipped', output)
            if match:
                skipped = int(match.group(1))
        return passed, failed, skipped

    def _parse_playwright(self, output: str) -> tuple:
        """Parse Playwright test output."""
        passed, failed, skipped = 0, 0, 0
        import re
        # "3 passed (5.2s)"
        match = re.search(r'(\d+)\s+passed', output)
        if match:
            passed = int(match.group(1))
        match = re.search(r'(\d+)\s+failed', output)
        if match:
            failed = int(match.group(1))
        return passed, failed, skipped

    def _parse_cargo(self, output: str) -> tuple:
        """Parse cargo test output."""
        passed, failed, skipped = 0, 0, 0
        import re
        # "test result: ok. 5 passed; 1 failed; 0 ignored"
        match = re.search(r'test result:.*?\.(\d+)\s+passed;\s+(\d+)\s+failed;\s+(\d+)\s+ignored', output)
        if match:
            passed = int(match.group(1))
            failed = int(match.group(2))
            skipped = int(match.group(3))
        return passed, failed, skipped

    def _parse_generic(self, output: str) -> tuple:
        """Generic parser — best effort extraction."""
        passed, failed, skipped = 0, 0, 0
        import re
        # Look for common patterns
        for pattern in [r'(\d+)\s+passed', r'(\d+)\s+success']:
            match = re.search(pattern, output, re.IGNORECASE)
            if match:
                passed = int(match.group(1))
                break
        for pattern in [r'(\d+)\s+failed', r'(\d+)\s+failure']:
            match = re.search(pattern, output, re.IGNORECASE)
            if match:
                failed = int(match.group(1))
                break
        return passed, failed, skipped

    # ------------------------------------------------------------------
    # Artifact Storage
    # ------------------------------------------------------------------

    def store_artifacts(
        self,
        session_id: str,
        test_results: Dict[str, Any],
        model_used: str = "",
    ) -> Path:
        """
        Store all test artifacts in a structured directory.

        Returns the path to the artifacts directory.
        """
        artifacts_dir = self.config.base_path / session_id
        artifacts_dir.mkdir(parents=True, exist_ok=True)

        # Write test results
        summary = TestSummary(
            session_id=session_id,
            overall_status=test_results.get("overall", {}).get("status", "unknown"),
            model_used=model_used,
            artifacts_path=str(artifacts_dir),
        )

        with open(artifacts_dir / "summary.json", "w") as f:
            json.dump(summary.to_dict(), f, indent=2)

        logger.info("Artifacts stored: %s", artifacts_dir)
        return artifacts_dir

    def collect_coverage(self, session_id: str, coverage_path: Path) -> Path:
        """Copy coverage report to artifacts directory."""
        artifacts_dir = self.config.base_path / session_id
        dest = artifacts_dir / "coverage"

        if coverage_path.is_file():
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(coverage_path, dest)
        elif coverage_path.is_dir():
            if dest.exists():
                shutil.rmtree(dest)
            shutil.copytree(coverage_path, dest)

        return dest

    def collect_screenshots(self, session_id: str, screenshot_dir: Path) -> List[Path]:
        """Copy E2E screenshots to artifacts directory."""
        artifacts_dir = self.config.base_path / session_id / "screenshots"
        artifacts_dir.mkdir(parents=True, exist_ok=True)

        screenshots = []
        if screenshot_dir.exists():
            for f in screenshot_dir.glob("*.png"):
                dest = artifacts_dir / f.name
                shutil.copy2(f, dest)
                screenshots.append(dest)

        return screenshots

    def generate_summary(self, session_id: str) -> Dict[str, Any]:
        """Generate a summary of all artifacts for a session."""
        artifacts_dir = self.config.base_path / session_id
        summary_file = artifacts_dir / "summary.json"

        if summary_file.exists():
            with open(summary_file) as f:
                return json.load(f)

        return {"session_id": session_id, "error": "No summary found"}

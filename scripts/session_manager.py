#!/usr/bin/env python3
"""
session_manager.py — Session Lifecycle Management for Agor Workflow

Tracks execution sessions from creation through completion,
enforces timeouts, and manages cleanup policies.

Usage:
    from session_manager import SessionManager, SessionStatus
    sm = SessionManager("/var/agor/sessions.jsonl")
    session = sm.create_session("JIRA-123")
    sm.update_status(session.session_id, SessionStatus.RUNNING)
"""

from __future__ import annotations

import fcntl
import json
import logging
import os
import time
import uuid
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from enum import Enum
from pathlib import Path
from typing import Any, Dict, List, Optional

from exceptions import SessionError, SessionNotFoundError, SessionAlreadyActiveError

logger = logging.getLogger(__name__)


# =============================================================================
# Session Status Enum
# =============================================================================

class SessionStatus(Enum):
    """Lifecycle states for an Agor execution session."""

    PENDING = "pending"           # Created, not yet started
    PLANNING = "planning"         # Cloud planner generating plan
    PLAN_READY = "plan_ready"     # Plan generated, awaiting validation
    VALIDATING = "validating"     # Policy engine validating plan
    PREPARING = "preparing"       # Creating worktree, spawning executor
    RUNNING = "running"           # Executor actively working
    TESTING = "testing"           # Running test layers
    REVIEWING = "reviewing"       # Agent review of diff
    COMPLETED = "completed"       # All checks passed, PR created
    FAILED = "failed"             # One or more checks failed
    TIMED_OUT = "timed_out"       # Exceeded maximum execution time
    ABORTED = "aborted"           # Manually aborted by operator
    ERROR = "error"               # Unexpected error occurred

    @property
    def is_terminal(self) -> bool:
        """True if the session has reached a final state."""
        return self in {
            SessionStatus.COMPLETED,
            SessionStatus.FAILED,
            SessionStatus.TIMED_OUT,
            SessionStatus.ABORTED,
            SessionStatus.ERROR,
        }

    @property
    def is_active(self) -> bool:
        """True if the session is currently executing work."""
        return self in {
            SessionStatus.PLANNING,
            SessionStatus.VALIDATING,
            SessionStatus.PREPARING,
            SessionStatus.RUNNING,
            SessionStatus.TESTING,
            SessionStatus.REVIEWING,
        }


# =============================================================================
# Session Dataclass
# =============================================================================

@dataclass
class Session:
    """
    Represents a single Agor execution session.

    Tracks the full lifecycle from ticket ingestion through PR creation
    or failure, including timing, resource usage, and model selection.
    """

    session_id: str
    ticket_ref: str
    plan_id: str = ""
    status: SessionStatus = SessionStatus.PENDING
    model_used: str | None = None  # Which Ollama model executed the work
    worktree_path: str = ""
    container_id: str = ""
    artifacts_path: str = ""
    created_at: str = field(default_factory=lambda: datetime.now(timezone.utc).isoformat())
    started_at: str = ""
    completed_at: str = ""
    error_message: str = ""
    metadata: Dict[str, Any] = field(default_factory=dict)

    @property
    def is_active(self) -> bool:
        return self.status.is_active

    @property
    def is_terminal(self) -> bool:
        return self.status.is_terminal

    @property
    def duration_seconds(self) -> float:
        """Calculate session duration if completed or still running."""
        if self.started_at and self.completed_at:
            start = datetime.fromisoformat(self.started_at)
            end = datetime.fromisoformat(self.completed_at)
            return (end - start).total_seconds()
        elif self.started_at:
            start = datetime.fromisoformat(self.started_at)
            now = datetime.now(timezone.utc)
            return (now - start).total_seconds()
        return 0.0

    def to_dict(self) -> Dict[str, Any]:
        data = asdict(self)
        data["status"] = self.status.value
        return data

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> Session:
        data = dict(data)  # copy
        data["status"] = SessionStatus(data.get("status", "pending"))
        return cls(**{k: v for k, v in data.items() if k in cls.__dataclass_fields__})


# =============================================================================
# Session Manager
# =============================================================================

class SessionManager:
    """
    Manages the lifecycle of Agor execution sessions.

    Stores sessions in a JSONL file for durability and simplicity.
    Uses file locking for thread-safe access.
    """

    def __init__(self, storage_path: str, max_active: int = 1, default_timeout: int = 600) -> None:
        self.storage_path = Path(storage_path)
        self.max_active = max_active
        self.default_timeout = default_timeout
        self._ensure_storage()

    # ------------------------------------------------------------------
    # Storage helpers
    # ------------------------------------------------------------------

    def _ensure_storage(self) -> None:
        """Create storage directory and file if they don't exist."""
        self.storage_path.parent.mkdir(parents=True, exist_ok=True)
        if not self.storage_path.exists():
            self.storage_path.touch()

    def _read_all_sessions(self) -> List[Session]:
        """Read all sessions from storage with file locking."""
        sessions: List[Session] = []
        if not self.storage_path.exists():
            return sessions

        lock_file = self.storage_path.with_suffix(".lock")
        with open(lock_file, "w") as lf:
            fcntl.flock(lf.fileno(), fcntl.LOCK_SH)
            try:
                with open(self.storage_path, "r") as f:
                    for line in f:
                        line = line.strip()
                        if not line:
                            continue
                        try:
                            data = json.loads(line)
                            sessions.append(Session.from_dict(data))
                        except (json.JSONDecodeError, ValueError) as e:
                            logger.warning("Skipping malformed session record: %s", e)
            finally:
                fcntl.flock(lf.fileno(), fcntl.LOCK_UN)

        return sessions

    def _write_all_sessions(self, sessions: List[Session]) -> None:
        """Write all sessions to storage with file locking."""
        lock_file = self.storage_path.with_suffix(".lock")
        with open(lock_file, "w") as lf:
            fcntl.flock(lf.fileno(), fcntl.LOCK_EX)
            try:
                with open(self.storage_path, "w") as f:
                    for session in sessions:
                        f.write(json.dumps(session.to_dict()) + "\n")
            finally:
                fcntl.flock(lf.fileno(), fcntl.LOCK_UN)

    def _append_session(self, session: Session) -> None:
        """Append a single session record."""
        lock_file = self.storage_path.with_suffix(".lock")
        with open(lock_file, "w") as lf:
            fcntl.flock(lf.fileno(), fcntl.LOCK_EX)
            try:
                with open(self.storage_path, "a") as f:
                    f.write(json.dumps(session.to_dict()) + "\n")
            finally:
                fcntl.flock(lf.fileno(), fcntl.LOCK_UN)

    # ------------------------------------------------------------------
    # CRUD operations
    # ------------------------------------------------------------------

    def create_session(self, ticket_ref: str) -> Session:
        """
        Create a new session for a ticket.

        Enforces the maximum active sessions limit.
        """
        active_count = len(self.list_active_sessions())
        if active_count >= self.max_active:
            raise SessionAlreadyActiveError(
                f"Maximum active sessions reached ({self.max_active}). "
                f"Complete or abort existing sessions before starting new ones."
            )

        session = Session(
            session_id=str(uuid.uuid4()),
            ticket_ref=ticket_ref,
        )
        self._append_session(session)
        logger.info("Session created: %s for ticket %s", session.session_id, ticket_ref)
        return session

    def update_status(
        self,
        session_id: str,
        status: SessionStatus,
        error_message: str = "",
        **kwargs: Any,
    ) -> Session:
        """Update the status of an existing session."""
        sessions = self._read_all_sessions()

        for session in sessions:
            if session.session_id == session_id:
                old_status = session.status
                session.status = status

                if error_message:
                    session.error_message = error_message

                # Track timing transitions
                if status.is_active and not session.started_at:
                    session.started_at = datetime.now(timezone.utc).isoformat()

                if status.is_terminal and not session.completed_at:
                    session.completed_at = datetime.now(timezone.utc).isoformat()

                # Update additional fields
                for key, value in kwargs.items():
                    if hasattr(session, key):
                        setattr(session, key, value)

                self._write_all_sessions(sessions)
                logger.info(
                    "Session %s: %s → %s",
                    session_id, old_status.value, status.value,
                )
                return session

        raise SessionNotFoundError(f"Session not found: {session_id}")

    def get_session(self, session_id: str) -> Session:
        """Retrieve a session by ID."""
        for session in self._read_all_sessions():
            if session.session_id == session_id:
                return session
        raise SessionNotFoundError(f"Session not found: {session_id}")

    def list_active_sessions(self) -> List[Session]:
        """List all currently active (non-terminal) sessions."""
        return [s for s in self._read_all_sessions() if not s.is_terminal]

    def list_sessions(self, ticket_ref: str | None = None) -> List[Session]:
        """List all sessions, optionally filtered by ticket."""
        sessions = self._read_all_sessions()
        if ticket_ref:
            sessions = [s for s in sessions if s.ticket_ref == ticket_ref]
        return sessions

    def archive_session(self, session_id: str, archive_dir: str) -> Path:
        """
        Archive a completed session's data to a separate directory.

        Returns the path to the archive file.
        """
        session = self.get_session(session_id)
        archive_path = Path(archive_dir) / f"{session_id}.json"
        archive_path.parent.mkdir(parents=True, exist_ok=True)

        with open(archive_path, "w") as f:
            json.dump(session.to_dict(), f, indent=2)

        logger.info("Session archived: %s → %s", session_id, archive_path)
        return archive_path

    # ------------------------------------------------------------------
    # Maintenance
    # ------------------------------------------------------------------

    def enforce_timeouts(self) -> List[Session]:
        """
        Find and mark sessions that have exceeded their timeout.

        Returns the list of timed-out sessions.
        """
        timed_out: List[Session] = []
        sessions = self._read_all_sessions()
        now = datetime.now(timezone.utc)

        for session in sessions:
            if not session.is_active:
                continue

            if not session.started_at:
                continue

            start = datetime.fromisoformat(session.started_at)
            elapsed = (now - start).total_seconds()

            timeout = session.metadata.get("timeout_seconds", self.default_timeout)

            if elapsed > timeout:
                session.status = SessionStatus.TIMED_OUT
                session.completed_at = now.isoformat()
                session.error_message = f"Exceeded timeout of {timeout}s"
                timed_out.append(session)
                logger.warning(
                    "Session %s timed out after %.0fs",
                    session.session_id, elapsed,
                )

        if timed_out:
            self._write_all_sessions(sessions)

        return timed_out

    def cleanup_old_sessions(self, retention_days: int = 30) -> int:
        """
        Remove sessions older than the retention period.

        Returns the number of sessions removed.
        """
        sessions = self._read_all_sessions()
        now = datetime.now(timezone.utc)
        cleaned = 0

        kept: List[Session] = []
        for session in sessions:
            created = datetime.fromisoformat(session.created_at)
            age_days = (now - created).total_seconds() / 86400

            if age_days > retention_days and session.is_terminal:
                cleaned += 1
                logger.debug("Cleaning up old session: %s", session.session_id)
            else:
                kept.append(session)

        if cleaned > 0:
            self._write_all_sessions(kept)
            logger.info("Cleaned up %d old sessions", cleaned)

        return cleaned

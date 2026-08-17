"""
Real-supervision-shape tests for run_concrete_runtime's presence authority
wiring, added during operationalization (2026-08-16). Uses fakes for
ownership/service/godot (same injection points the existing Ticket 3F tests
use) plus a new fake AuthorityProcess, so what's under test is purely the
*ordering* run_concrete_runtime enforces — not the real subprocess/HTTP
mechanics, which test_presence_authority_integration.py already covers with
a real authority subprocess.
"""

from __future__ import annotations

import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT_ROOT))

import pytest

from runtime_composition import run_concrete_runtime
from runtime_launcher import LauncherSupervisionError


class _CallLog:
    def __init__(self) -> None:
        self.events: list[str] = []


class _FakeAdapter:
    def __init__(self, log: _CallLog) -> None:
        self._log = log
        self.worker_state = "READY"

    def prepare(self) -> None:
        self._log.events.append("adapter.prepare")

    def process_once(self) -> bool:
        return False

    def request_stop(self) -> None:
        self._log.events.append("adapter.request_stop")
        self.worker_state = "STOPPED"


class _FakeOwnership:
    def __init__(self, log: _CallLog) -> None:
        self._log = log

    def acquire(self) -> None:
        self._log.events.append("ownership.acquire")

    def release(self) -> None:
        self._log.events.append("ownership.release")


class _FakeService:
    def __init__(self, log: _CallLog) -> None:
        self._log = log

    def start(self) -> None:
        self._log.events.append("service.start")

    def close(self, shutdown_budget_seconds: float) -> None:
        self._log.events.append("service.close")


class _FakeGodotProcess:
    def __init__(self, log: _CallLog) -> None:
        self._log = log

    def wait(self) -> int:
        self._log.events.append("godot.wait")
        return 0


class _FakeAuthority:
    def __init__(self, log: _CallLog, *, healthy: bool = True) -> None:
        self._log = log
        self._healthy = healthy

    def start(self) -> None:
        self._log.events.append("authority.start")

    def wait_until_healthy(self, timeout_seconds: float) -> None:
        self._log.events.append("authority.wait_until_healthy")
        if not self._healthy:
            raise LauncherSupervisionError("fake authority never became healthy")

    def stop(self, shutdown_budget_seconds: float) -> None:
        self._log.events.append("authority.stop")


def _run(log: _CallLog, *, authority_factory, expect_raise: bool = False) -> None:
    kwargs = dict(
        project_dir=Path("/tmp/does-not-matter"),
        godot_command="godot",
        shutdown_budget_seconds=5.0,
        adapter_factory=lambda project_dir: _FakeAdapter(log),
        ownership_factory=lambda project_dir: _FakeOwnership(log),
        service_factory=lambda adapter: _FakeService(log),
        godot_process_factory=lambda command, project_dir: _FakeGodotProcess(log),
        presence_authority_factory=authority_factory,
    )
    if expect_raise:
        with pytest.raises(LauncherSupervisionError):
            run_concrete_runtime(**kwargs)
    else:
        run_concrete_runtime(**kwargs)


def test_authority_starts_and_is_healthy_before_worker_prepares():
    log = _CallLog()
    _run(log, authority_factory=lambda: _FakeAuthority(log))
    assert log.events.index("authority.start") < log.events.index("adapter.prepare")
    assert log.events.index("authority.wait_until_healthy") < log.events.index("adapter.prepare")


def test_authority_stops_only_after_worker_reaches_stopped():
    """Step 5's exact ordering requirement: stop workers, then stop
    authority — never the reverse."""
    log = _CallLog()
    _run(log, authority_factory=lambda: _FakeAuthority(log))
    assert log.events.index("adapter.request_stop") < log.events.index("authority.stop")


def test_unhealthy_authority_prevents_the_worker_from_ever_starting():
    log = _CallLog()
    _run(log, authority_factory=lambda: _FakeAuthority(log, healthy=False), expect_raise=True)
    assert "authority.start" in log.events
    assert "authority.wait_until_healthy" in log.events
    assert "adapter.prepare" not in log.events
    assert "ownership.acquire" not in log.events


def test_omitting_the_authority_factory_supervises_nothing_by_default():
    """Opt-in only, per instruction — not a silent default."""
    log = _CallLog()
    _run(log, authority_factory=lambda: None)
    assert not any(event.startswith("authority.") for event in log.events)
    assert "adapter.prepare" in log.events  # the rest of the runtime still works

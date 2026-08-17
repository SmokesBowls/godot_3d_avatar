"""
Tests for the Godot-orphan-on-interrupt fix (2026-08-16): SIGINT/SIGTERM
used to leave the real Godot child running after the launcher process
exited via an uncaught KeyboardInterrupt. Covers, per the acceptance
criteria: normal Godot exit, SIGINT during wait(), already-dead Godot,
graceful-timeout escalation to a forced kill, repeated cleanup, and the
full stop-worker -> terminate-Godot -> release-ownership -> stop-authority
ordering under interruption, plus main()'s exit-status translation.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path
from typing import Any, Optional

PROJECT_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT_ROOT))

import pytest

import runtime_composition as rc
from runtime_launcher import LauncherSupervisionError, ShutdownRequested, run_runtime_generation


# ---------------------------------------------------------------------------
# terminate_and_reap_godot — unit-level, against a fake Popen-shaped double
# ---------------------------------------------------------------------------

class _FakeGodotPopen:
    """Controls exactly what the acceptance criteria need to distinguish:
    whether the process is already dead, whether terminate() alone is
    enough, and whether it has to escalate to kill()."""

    def __init__(
        self,
        *,
        already_exited_code: Optional[int] = None,
        exits_after_terminate: bool = True,
        exit_code: int = 0,
    ) -> None:
        self._already_exited_code = already_exited_code
        self._exits_after_terminate = exits_after_terminate
        self._exit_code = exit_code
        self.terminate_calls = 0
        self.kill_calls = 0
        self.wait_calls = 0
        self._alive = already_exited_code is None
        self._terminated = False
        self._killed = False

    def poll(self) -> Optional[int]:
        if self._already_exited_code is not None:
            return self._already_exited_code
        return None if self._alive else self._exit_code

    def terminate(self) -> None:
        self.terminate_calls += 1
        self._terminated = True
        if self._exits_after_terminate:
            self._alive = False

    def kill(self) -> None:
        self.kill_calls += 1
        self._killed = True
        self._alive = False

    def wait(self, timeout: Optional[float] = None) -> int:
        self.wait_calls += 1
        if self._already_exited_code is not None:
            return self._already_exited_code
        if self._alive:
            raise subprocess.TimeoutExpired(cmd="godot", timeout=timeout or 0)
        return self._exit_code


def test_already_dead_godot_is_reaped_not_signaled():
    process = _FakeGodotPopen(already_exited_code=0)
    result = rc.terminate_and_reap_godot(process, 1.0)
    assert result == 0
    assert process.terminate_calls == 0
    assert process.kill_calls == 0
    assert process.wait_calls == 1  # still reaped, even though already exited


def test_graceful_terminate_is_tried_first_and_suffices():
    process = _FakeGodotPopen(exits_after_terminate=True, exit_code=0)
    result = rc.terminate_and_reap_godot(process, 1.0)
    assert result == 0
    assert process.terminate_calls == 1
    assert process.kill_calls == 0  # never escalated — terminate() was enough


def test_graceful_timeout_escalates_to_kill():
    process = _FakeGodotPopen(exits_after_terminate=False, exit_code=0)
    result = rc.terminate_and_reap_godot(process, 0.01)
    assert result == 0
    assert process.terminate_calls == 1
    assert process.kill_calls == 1  # escalated only after the graceful wait timed out


def test_repeated_cleanup_is_idempotent():
    process = _FakeGodotPopen(exits_after_terminate=True, exit_code=0)
    first = rc.terminate_and_reap_godot(process, 1.0)
    second = rc.terminate_and_reap_godot(process, 1.0)
    assert first == second == 0
    assert process.terminate_calls == 1  # second call found it already dead via poll()
    assert process.kill_calls == 0


# ---------------------------------------------------------------------------
# run_runtime_generation — ordering under interruption
# ---------------------------------------------------------------------------

class _Log:
    def __init__(self) -> None:
        self.events: list[str] = []


class _FakeWorker:
    def __init__(self, log: _Log) -> None:
        self._log = log
        self.worker_state = "READY"

    def prepare(self) -> None:
        self._log.events.append("worker.prepare")

    def request_stop(self) -> None:
        self._log.events.append("worker.request_stop")
        self.worker_state = "STOPPED"


class _InterruptingGodotProcess:
    """wait() raises the given exception exactly once, standing in for a
    real SIGINT/SIGTERM arriving while the launcher blocks on Godot."""

    def __init__(self, log: _Log, exc: BaseException) -> None:
        self._log = log
        self._exc = exc

    def wait(self) -> int:
        raise self._exc


def _fake_terminator(log: _Log):
    def terminator(process, shutdown_budget_seconds: float) -> int:
        log.events.append("godot.terminate_and_reap")
        return 0

    return terminator


@pytest.mark.parametrize("exc_factory", [KeyboardInterrupt, ShutdownRequested])
def test_interrupt_stops_worker_before_terminating_godot_and_reraises(exc_factory):
    """Both SIGINT's KeyboardInterrupt and SIGTERM's ShutdownRequested must
    take the identical ordered path: worker stopped first, Godot terminated
    second, then re-raised so the caller preserves the interruption."""
    log = _Log()
    with pytest.raises(exc_factory):
        run_runtime_generation(
            worker_factory=lambda: _FakeWorker(log),
            godot_launcher=lambda: _InterruptingGodotProcess(log, exc_factory()),
            godot_terminator=_fake_terminator(log),
            shutdown_budget_seconds=1.0,
        )
    assert log.events == ["worker.prepare", "worker.request_stop", "godot.terminate_and_reap"]


def test_normal_godot_exit_never_calls_the_terminator():
    log = _Log()

    class _NormalGodotProcess:
        def wait(self) -> int:
            log.events.append("godot.wait_returned")
            return 0

    def terminator(process, shutdown_budget_seconds: float) -> int:
        log.events.append("UNEXPECTED_TERMINATE_CALL")
        return 0

    result = run_runtime_generation(
        worker_factory=lambda: _FakeWorker(log),
        godot_launcher=lambda: _NormalGodotProcess(),
        godot_terminator=terminator,
        shutdown_budget_seconds=1.0,
    )
    assert result == 0
    assert "UNEXPECTED_TERMINATE_CALL" not in log.events
    assert log.events == ["worker.prepare", "godot.wait_returned", "worker.request_stop"]


# ---------------------------------------------------------------------------
# run_concrete_runtime — full chain: worker -> godot -> ownership -> authority
# ---------------------------------------------------------------------------

class _FakeOwnership:
    def __init__(self, log: _Log) -> None:
        self._log = log

    def acquire(self) -> None:
        self._log.events.append("ownership.acquire")

    def release(self) -> None:
        self._log.events.append("ownership.release")


class _FakeService:
    def __init__(self, log: _Log) -> None:
        self._log = log

    def start(self) -> None:
        self._log.events.append("service.start")

    def close(self, shutdown_budget_seconds: float) -> None:
        self._log.events.append("service.close")


class _FakeAuthority:
    def __init__(self, log: _Log) -> None:
        self._log = log

    def start(self) -> None:
        self._log.events.append("authority.start")

    def wait_until_healthy(self, timeout_seconds: float) -> None:
        self._log.events.append("authority.wait_until_healthy")

    def stop(self, shutdown_budget_seconds: float) -> None:
        self._log.events.append("authority.stop")


def test_full_interrupt_chain_preserves_required_ordering_and_reraises():
    log = _Log()

    def adapter_factory(project_dir):
        return _FakeWorker(log)

    with pytest.raises(KeyboardInterrupt):
        rc.run_concrete_runtime(
            project_dir=Path("/tmp/does-not-matter"),
            godot_command="godot",
            shutdown_budget_seconds=1.0,
            adapter_factory=adapter_factory,
            ownership_factory=lambda project_dir: _FakeOwnership(log),
            service_factory=lambda adapter: _FakeService(log),
            godot_process_factory=lambda command, project_dir: _InterruptingGodotProcess(log, KeyboardInterrupt()),
            godot_terminator=_fake_terminator(log),
            presence_authority_factory=lambda: _FakeAuthority(log),
        )

    worker_stop_index = log.events.index("worker.request_stop")
    godot_terminate_index = log.events.index("godot.terminate_and_reap")
    ownership_release_index = log.events.index("ownership.release")
    authority_stop_index = log.events.index("authority.stop")

    assert worker_stop_index < godot_terminate_index < ownership_release_index < authority_stop_index


# ---------------------------------------------------------------------------
# main() — exit status translation
# ---------------------------------------------------------------------------

def test_main_translates_keyboard_interrupt_to_128_plus_sigint(monkeypatch):
    import signal

    monkeypatch.setattr(rc, "run_concrete_runtime", lambda **kwargs: (_ for _ in ()).throw(KeyboardInterrupt()))
    exit_code = rc.main(["--godot-command", "godot"])
    assert exit_code == 128 + signal.SIGINT


def test_main_translates_shutdown_requested_to_128_plus_sigterm(monkeypatch):
    import signal

    monkeypatch.setattr(rc, "run_concrete_runtime", lambda **kwargs: (_ for _ in ()).throw(ShutdownRequested()))
    exit_code = rc.main(["--godot-command", "godot"])
    assert exit_code == 128 + signal.SIGTERM


def test_main_restores_the_previous_sigterm_handler(monkeypatch):
    import signal

    sentinel = signal.getsignal(signal.SIGTERM)
    monkeypatch.setattr(rc, "run_concrete_runtime", lambda **kwargs: 0)
    rc.main(["--godot-command", "godot"])
    assert signal.getsignal(signal.SIGTERM) is sentinel

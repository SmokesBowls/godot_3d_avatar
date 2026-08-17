"""Own one prepared Hermes worker for one Godot runtime generation."""

from __future__ import annotations

import time
from typing import Any, Callable, Protocol


ENGAV3D_STAGE8_TICKET3E_LAUNCHER_SUPERVISION_V1 = True
ENGAV3D_LAUNCHER_INTERRUPT_LIFECYCLE_V1 = True


class LauncherSupervisionError(RuntimeError):
    """Raised when the runtime generation cannot satisfy its lifecycle contract."""


class ShutdownRequested(BaseException):
    """Raised by the SIGTERM handler installed in runtime_composition.main(),
    so SIGTERM funnels through the exact same exception-based shutdown path
    as SIGINT's default KeyboardInterrupt. Subclasses BaseException, like
    KeyboardInterrupt, so it is never accidentally swallowed by a bare
    `except Exception` somewhere upstream."""


class Worker(Protocol):
    worker_state: str

    def prepare(self) -> None: ...

    def request_stop(self) -> None: ...


class GodotProcess(Protocol):
    def poll(self) -> int | None: ...

    def wait(self, timeout: float | None = None) -> int: ...

    def terminate(self) -> None: ...

    def kill(self) -> None: ...


def _stop_worker(worker: Worker, shutdown_budget_seconds: float) -> None:
    if shutdown_budget_seconds <= 0:
        raise ValueError("shutdown bound must be positive")

    worker.request_stop()
    deadline = time.monotonic() + shutdown_budget_seconds
    while worker.worker_state != "STOPPED":
        if time.monotonic() >= deadline:
            raise LauncherSupervisionError(
                "worker did not reach STOPPED within the shutdown bound"
            )
        time.sleep(min(0.001, shutdown_budget_seconds))


def run_runtime_generation(
    *,
    worker_factory: Callable[[], Worker],
    godot_launcher: Callable[[], GodotProcess],
    godot_terminator: Callable[[GodotProcess, float], int],
    shutdown_budget_seconds: float,
) -> int:
    """Supervise exactly one injected worker and one injected Godot process.

    Interruption lifecycle (SIGINT/SIGTERM, both funneled to
    KeyboardInterrupt/ShutdownRequested — see runtime_composition.main()):
    the ordering this function enforces is stop worker (which, by waiting
    for the worker's own service loop to finish its current cycle, is also
    where any held session claim is released — see
    hermes_session_adapter.py's dispatch finally block) → terminate and
    reap the exact Godot child this generation launched → re-raise, so the
    caller preserves the interruption's exit status rather than reporting
    a normal return code. godot_terminator is always the caller's exact
    injected implementation, never a name/PID lookup — this function never
    discovers or touches any process other than the one godot_launcher()
    itself returned.
    """
    worker = worker_factory()
    worker.prepare()
    if worker.worker_state != "READY":
        raise LauncherSupervisionError("worker did not reach READY before Godot launch")

    try:
        godot_process = godot_launcher()
    except BaseException:
        _stop_worker(worker, shutdown_budget_seconds)
        raise

    godot_exit_code: Any
    try:
        godot_exit_code = godot_process.wait()
    except (KeyboardInterrupt, ShutdownRequested):
        _stop_worker(worker, shutdown_budget_seconds)
        godot_terminator(godot_process, shutdown_budget_seconds)
        raise
    else:
        _stop_worker(worker, shutdown_budget_seconds)

    if not isinstance(godot_exit_code, int):
        raise LauncherSupervisionError("Godot process returned a non-integer exit code")
    return godot_exit_code

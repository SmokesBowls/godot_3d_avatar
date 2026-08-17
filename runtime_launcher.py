"""Own one prepared Hermes worker for one Godot runtime generation."""

from __future__ import annotations

import time
from typing import Any, Callable, Protocol


ENGAV3D_STAGE8_TICKET3E_LAUNCHER_SUPERVISION_V1 = True


class LauncherSupervisionError(RuntimeError):
    """Raised when the runtime generation cannot satisfy its lifecycle contract."""


class Worker(Protocol):
    worker_state: str

    def prepare(self) -> None: ...

    def request_stop(self) -> None: ...


class GodotProcess(Protocol):
    def wait(self) -> int: ...


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
    shutdown_budget_seconds: float,
) -> int:
    """Supervise exactly one injected worker and one injected Godot process."""
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
    finally:
        _stop_worker(worker, shutdown_budget_seconds)

    if not isinstance(godot_exit_code, int):
        raise LauncherSupervisionError("Godot process returned a non-integer exit code")
    return godot_exit_code

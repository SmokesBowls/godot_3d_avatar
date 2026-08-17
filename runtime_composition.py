"""Compose one persistent Hermes worker with one non-editor Godot runtime."""

from __future__ import annotations

import argparse
from pathlib import Path
import subprocess
import threading
from typing import Any, Callable, Protocol, Sequence, cast

from hermes_session_adapter import AdapterConfig, HermesSessionAdapter, PidFileLock
from runtime_launcher import LauncherSupervisionError, run_runtime_generation


COMPOSITION_MARKER = "ENGAV3D_STAGE8_TICKET3F_CONCRETE_RUNTIME_COMPOSITION_V1"


class Adapter(Protocol):
    worker_state: str

    def prepare(self) -> None: ...

    def process_once(self) -> bool: ...

    def request_stop(self) -> None: ...


class Ownership(Protocol):
    def acquire(self) -> None: ...

    def release(self) -> None: ...


class Service(Protocol):
    def start(self) -> None: ...

    def close(self, shutdown_budget_seconds: float) -> None: ...


class PersistentAdapterService:
    """Run the adapter CLI's process-once loop on one bounded service thread."""

    def __init__(self, adapter: HermesSessionAdapter) -> None:
        self._adapter = adapter
        self._stop = threading.Event()
        self._thread = threading.Thread(
            target=self._serve,
            name="engain-hermes-mailbox-worker",
            daemon=True,
        )

    def start(self) -> None:
        self._thread.start()

    def _serve(self) -> None:
        while self._adapter.worker_state == "READY" and not self._stop.is_set():
            self._adapter.process_once()
            self._stop.wait(self._adapter.config.poll_seconds)

    def close(self, shutdown_budget_seconds: float) -> None:
        self._stop.set()
        self._thread.join(shutdown_budget_seconds)
        if self._thread.is_alive():
            raise LauncherSupervisionError(
                "adapter servicing did not terminate within the shutdown bound"
            )
        self._adapter._finish_stop()


class ComposedWorker:
    """Narrow Ticket 3E worker facade over one adapter and its service loop."""

    def __init__(self, adapter: Adapter, service: Service, shutdown_budget_seconds: float) -> None:
        self._adapter = adapter
        self._service = service
        self._shutdown_budget_seconds = shutdown_budget_seconds
        self._service_started = False

    @property
    def worker_state(self) -> str:
        return self._adapter.worker_state

    def prepare(self) -> None:
        self._adapter.prepare()
        if self._adapter.worker_state != "READY":
            return
        self._service.start()
        self._service_started = True

    def request_stop(self) -> None:
        self._adapter.request_stop()
        if self._service_started:
            self._service.close(self._shutdown_budget_seconds)
            self._service_started = False


def create_godot_process(command: str, project_dir: Path) -> subprocess.Popen[bytes]:
    """Start Godot against the project so project.godot selects its main scene."""
    return subprocess.Popen([command, "--path", str(project_dir)])


def _real_adapter(project_dir: Path) -> HermesSessionAdapter:
    return HermesSessionAdapter(AdapterConfig(project_dir=project_dir))


def _real_ownership(project_dir: Path) -> PidFileLock:
    return PidFileLock(project_dir / ".godot" / "engain_hermes_adapter.pid")


def _real_service(adapter: Adapter) -> Service:
    return PersistentAdapterService(cast(HermesSessionAdapter, adapter))


def run_concrete_runtime(
    *,
    project_dir: Path,
    godot_command: str,
    shutdown_budget_seconds: float,
    adapter_factory: Callable[[Path], Adapter] = _real_adapter,
    ownership_factory: Callable[[Path], Ownership] = _real_ownership,
    service_factory: Callable[[Adapter], Service] = _real_service,
    godot_process_factory: Callable[[str, Path], Any] = create_godot_process,
) -> int:
    """Own and supervise exactly one concrete worker/Godot generation."""
    if shutdown_budget_seconds <= 0:
        raise ValueError("shutdown bound must be positive")
    project_dir = Path(project_dir).resolve()
    adapter = adapter_factory(project_dir)
    ownership = ownership_factory(project_dir)
    service = service_factory(adapter)
    worker = ComposedWorker(adapter, service, shutdown_budget_seconds)

    ownership.acquire()
    try:
        return run_runtime_generation(
            worker_factory=cast(Any, lambda: worker),
            godot_launcher=lambda: godot_process_factory(godot_command, project_dir),
            shutdown_budget_seconds=shutdown_budget_seconds,
        )
    finally:
        if worker.worker_state == "STOPPED":
            ownership.release()


setattr(run_concrete_runtime, COMPOSITION_MARKER, True)


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run the canonical Godot project with its persistent Hermes worker"
    )
    parser.add_argument("--godot-command", required=True)
    parser.add_argument(
        "--project-dir",
        type=Path,
        default=Path(__file__).resolve().parent,
    )
    parser.add_argument("--shutdown-budget", type=float, default=5.0)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    return run_concrete_runtime(
        project_dir=args.project_dir,
        godot_command=args.godot_command,
        shutdown_budget_seconds=args.shutdown_budget,
    )


if __name__ == "__main__":
    raise SystemExit(main())

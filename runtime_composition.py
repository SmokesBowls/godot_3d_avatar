"""Compose one persistent Hermes worker with one non-editor Godot runtime."""

from __future__ import annotations

import argparse
import os
import signal
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
import subprocess
import threading
from typing import Any, Callable, Optional, Protocol, Sequence, cast

from hermes_session_adapter import AdapterConfig, HermesSessionAdapter, PidFileLock
from runtime_launcher import (
    LauncherSupervisionError,
    ShutdownRequested,
    run_runtime_generation,
)


COMPOSITION_MARKER = "ENGAV3D_STAGE8_TICKET3F_CONCRETE_RUNTIME_COMPOSITION_V1"
PRESENCE_AUTHORITY_SUPERVISION_MARKER = "ENGAV3D_PRESENCE_AUTHORITY_SUPERVISION_V1"


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


class AuthorityProcess(Protocol):
    def start(self) -> None: ...

    def wait_until_healthy(self, timeout_seconds: float) -> None: ...

    def stop(self, shutdown_budget_seconds: float) -> None: ...


class SupervisedPresenceAuthority:
    """Spawns and supervises the shared presence authority server as a real
    child process, health-checked before the worker is allowed to
    prepare()/register(). Its canonical implementation lives in the EngAIn
    checkout (tier1/engainos/server/presence_authority_server.py) — not
    vendored here, since exactly one instance of it should exist
    system-wide. This composition only needs to know how to launch and
    supervise it, the same way it already only knows how to launch Godot
    via --godot-command rather than embedding a Godot build.

    Prior to this, the authority had to be started manually for the claim
    protection added to hermes_session_adapter.py to do anything; both
    workers fell back to their fail-open compatibility path silently. This
    class is what turns that into real, supervised, always-on protection
    for any generation started through this launcher.
    """

    def __init__(self, python_command: str, script_path: Path, host: str, port: int) -> None:
        self._python_command = python_command
        self._script_path = script_path
        self._host = host
        self._port = port
        self._process: Optional[subprocess.Popen[bytes]] = None

    def start(self) -> None:
        if not self._script_path.exists():
            raise LauncherSupervisionError(
                f"presence authority script not found: {self._script_path}"
            )
        self._process = subprocess.Popen(
            [self._python_command, str(self._script_path), "--host", self._host, "--port", str(self._port)],
        )

    def wait_until_healthy(self, timeout_seconds: float) -> None:
        url = f"http://{self._host}:{self._port}/health"
        deadline = time.monotonic() + timeout_seconds
        last_error: Optional[Exception] = None
        while time.monotonic() < deadline:
            if self._process is not None and self._process.poll() is not None:
                raise LauncherSupervisionError(
                    f"presence authority process exited early with code {self._process.returncode}"
                )
            try:
                with urllib.request.urlopen(url, timeout=1.0) as resp:
                    if resp.status == 200:
                        return
            except (urllib.error.URLError, OSError, TimeoutError) as exc:
                last_error = exc
            time.sleep(0.05)
        raise LauncherSupervisionError(
            f"presence authority did not become healthy within {timeout_seconds}s: {last_error}"
        )

    def stop(self, shutdown_budget_seconds: float) -> None:
        if self._process is None:
            return
        self._process.terminate()
        try:
            self._process.wait(timeout=shutdown_budget_seconds)
        except subprocess.TimeoutExpired:
            self._process.kill()
            self._process.wait(timeout=shutdown_budget_seconds)


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


def terminate_and_reap_godot(process: subprocess.Popen[bytes], shutdown_budget_seconds: float) -> int:
    """The exact-child-only, always-reaped Godot shutdown this launcher was
    missing: request graceful termination, wait a bounded time, escalate to
    a forced kill only if still alive, and always call wait() so no zombie
    remains.

    Operates only on the one Popen object this launcher itself created via
    create_godot_process() — never a PID/name lookup, never a process
    group, so it can never reach a process this generation didn't start.

    Idempotent by construction: subprocess.Popen caches returncode after
    the first successful wait()/poll(), so calling this again (already
    exited, already killed, or called a second time by mistake) just
    returns that cached code immediately rather than erroring or trying to
    signal an already-reaped process."""
    if process.poll() is not None:
        return process.wait()

    process.terminate()  # graceful: SIGTERM
    try:
        return process.wait(timeout=shutdown_budget_seconds)
    except subprocess.TimeoutExpired:
        process.kill()  # forced: SIGKILL, only after the graceful attempt timed out
        return process.wait(timeout=shutdown_budget_seconds)


def _real_adapter(project_dir: Path) -> HermesSessionAdapter:
    return HermesSessionAdapter(AdapterConfig(project_dir=project_dir))


def _real_ownership(project_dir: Path) -> PidFileLock:
    return PidFileLock(project_dir / ".godot" / "engain_hermes_adapter.pid")


def _real_service(adapter: Adapter) -> Service:
    return PersistentAdapterService(cast(HermesSessionAdapter, adapter))


def _real_presence_authority(
    script_path: Optional[Path], python_command: str, host: str, port: int
) -> Optional[AuthorityProcess]:
    """None means "not supervised by this launcher" — an explicit,
    opt-in-only configuration, not a silent default. hermes_session_adapter
    itself still governs what happens if no authority is ever reachable
    (fail-closed by default; ENGAIN_PRESENCE_AUTHORITY_FAIL_OPEN_COMPAT=1
    for the named temporary compatibility path)."""
    if script_path is None:
        return None
    return SupervisedPresenceAuthority(python_command, script_path, host, port)


def run_concrete_runtime(
    *,
    project_dir: Path,
    godot_command: str,
    shutdown_budget_seconds: float,
    adapter_factory: Callable[[Path], Adapter] = _real_adapter,
    ownership_factory: Callable[[Path], Ownership] = _real_ownership,
    service_factory: Callable[[Adapter], Service] = _real_service,
    godot_process_factory: Callable[[str, Path], Any] = create_godot_process,
    godot_terminator: Callable[[Any, float], int] = terminate_and_reap_godot,
    presence_authority_factory: Callable[[], Optional[AuthorityProcess]] = lambda: None,
    presence_authority_ready_timeout_seconds: float = 15.0,
) -> int:
    """Own and supervise exactly one concrete worker/Godot generation.

    Shutdown order, both on normal exit and on interruption
    (SIGINT/SIGTERM, both funneled through main()'s signal handling into
    KeyboardInterrupt/ShutdownRequested): stop worker → release session/
    presence (a consequence of stopping the worker — its service loop
    finishes its current cycle before request_stop() returns, which is
    exactly where hermes_session_adapter.py's own dispatch finally block
    releases any held claim) → terminate and reap the exact Godot child
    this generation launched (run_runtime_generation's job, on
    interruption only — a normal exit has nothing left to terminate) →
    release ownership → stop the presence authority, last. Never the
    reverse: a worker or Godot process still alive after the authority
    stops could dispatch, or fail to release a claim, with nothing left
    enforcing exclusivity.
    """
    if shutdown_budget_seconds <= 0:
        raise ValueError("shutdown bound must be positive")
    project_dir = Path(project_dir).resolve()
    adapter = adapter_factory(project_dir)
    ownership = ownership_factory(project_dir)
    service = service_factory(adapter)
    worker = ComposedWorker(adapter, service, shutdown_budget_seconds)

    authority = presence_authority_factory()
    if authority is not None:
        authority.start()
        authority.wait_until_healthy(presence_authority_ready_timeout_seconds)

    ownership.acquire()
    try:
        return run_runtime_generation(
            worker_factory=cast(Any, lambda: worker),
            godot_launcher=lambda: godot_process_factory(godot_command, project_dir),
            godot_terminator=godot_terminator,
            shutdown_budget_seconds=shutdown_budget_seconds,
        )
    finally:
        if worker.worker_state == "STOPPED":
            ownership.release()
        if authority is not None:
            authority.stop(shutdown_budget_seconds)


setattr(run_concrete_runtime, COMPOSITION_MARKER, True)
setattr(run_concrete_runtime, PRESENCE_AUTHORITY_SUPERVISION_MARKER, True)


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
    parser.add_argument(
        "--presence-authority-script",
        type=Path,
        default=None,
        help=(
            "Path to EngAIn's tier1/engainos/server/presence_authority_server.py. "
            "Opt-in only — omitting this flag means no authority is supervised by this "
            "launcher, and workers fall back to their own fail-closed-by-default behavior "
            "(or ENGAIN_PRESENCE_AUTHORITY_FAIL_OPEN_COMPAT=1 if explicitly set)."
        ),
    )
    parser.add_argument("--presence-authority-python", default=sys.executable)
    parser.add_argument("--presence-authority-host", default="127.0.0.1")
    parser.add_argument("--presence-authority-port", type=int, default=8767)
    parser.add_argument("--presence-authority-ready-timeout", type=float, default=15.0)
    return parser.parse_args(argv)


def _raise_shutdown_requested(signum: int, frame: Any) -> None:
    raise ShutdownRequested()


def main(argv: Sequence[str] | None = None) -> int:
    """Catches SIGINT (via Python's default KeyboardInterrupt) and SIGTERM
    (via the handler installed below, which raises ShutdownRequested — the
    same exception shape, deliberately, so both signals funnel through the
    exact same shutdown path in run_runtime_generation/run_concrete_runtime)
    through one path, and preserves the interruption's exit status as the
    conventional 128+signum rather than letting an uncaught exception print
    a traceback and return a generic failure code."""
    args = parse_args(argv)
    previous_sigterm_handler = signal.signal(signal.SIGTERM, _raise_shutdown_requested)
    try:
        return run_concrete_runtime(
            project_dir=args.project_dir,
            godot_command=args.godot_command,
            shutdown_budget_seconds=args.shutdown_budget,
            presence_authority_factory=lambda: _real_presence_authority(
                args.presence_authority_script,
                args.presence_authority_python,
                args.presence_authority_host,
                args.presence_authority_port,
            ),
            presence_authority_ready_timeout_seconds=args.presence_authority_ready_timeout,
        )
    except KeyboardInterrupt:
        return 128 + signal.SIGINT
    except ShutdownRequested:
        return 128 + signal.SIGTERM
    finally:
        signal.signal(signal.SIGTERM, previous_sigterm_handler)


if __name__ == "__main__":
    raise SystemExit(main())

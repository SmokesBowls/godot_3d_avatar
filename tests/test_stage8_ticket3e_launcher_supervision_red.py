from __future__ import annotations

import ast
import importlib.util
import sys
from pathlib import Path
from types import ModuleType
from typing import Any, Callable

import pytest


PROJECT_ROOT = Path(__file__).resolve().parents[1]
CONTRACT_MARKER = "ENGAV3D_STAGE8_TICKET3E_LAUNCHER_SUPERVISION_V1"
ADAPTER_PATH = PROJECT_ROOT / "hermes_session_adapter.py"
PROTECTED_GODOT_PATHS = (
    PROJECT_ROOT / "scripts" / "EngAInBridge3D.gd",
    PROJECT_ROOT / "scripts" / "ControlHUD.gd",
    PROJECT_ROOT / "scripts" / "Main.gd",
)


def _production_python_paths() -> list[Path]:
    return sorted(
        path
        for path in PROJECT_ROOT.rglob("*.py")
        if ".git" not in path.parts
        and ".godot" not in path.parts
        and "tests" not in path.parts
        and path != ADAPTER_PATH
    )


def _launcher_module() -> ModuleType:
    candidates: list[Path] = []
    for path in _production_python_paths():
        source = path.read_text(encoding="utf-8")
        ast.parse(source, filename=str(path))
        if CONTRACT_MARKER in source:
            candidates.append(path)

    assert len(candidates) == 1, (
        "qualifying production launcher/supervision boundary does not exist; "
        "Ticket 3D requires exactly one production Python entry point marked "
        f"{CONTRACT_MARKER}, but found {len(candidates)}"
    )

    path = candidates[0]
    spec = importlib.util.spec_from_file_location("ticket3e_production_launcher", path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    try:
        spec.loader.exec_module(module)
    finally:
        sys.modules.pop(spec.name, None)
    assert callable(getattr(module, "run_runtime_generation", None)), (
        "qualifying launcher must expose run_runtime_generation"
    )
    return module


class WorkerDouble:
    def __init__(
        self,
        events: list[str],
        *,
        prepare_state: str = "READY",
        prepare_error: Exception | None = None,
        stop_reads_before_stopped: int = 0,
    ) -> None:
        self.events = events
        self.prepare_state = prepare_state
        self.prepare_error = prepare_error
        self.stop_reads_before_stopped = stop_reads_before_stopped
        self._state = "STOPPED"
        self.stop_calls = 0
        self.stop_requested = False

    @property
    def worker_state(self) -> str:
        if self.stop_requested and self._state == "STOPPING":
            if self.stop_reads_before_stopped <= 0:
                self._state = "STOPPED"
                self.events.append("worker:STOPPED")
            else:
                self.stop_reads_before_stopped -= 1
        return self._state

    def prepare(self) -> None:
        self.events.append("worker:prepare")
        if self.prepare_error is not None:
            raise self.prepare_error
        self._state = self.prepare_state
        self.events.append(f"worker:{self._state}")

    def request_stop(self) -> None:
        self.stop_calls += 1
        self.stop_requested = True
        self._state = "STOPPING"
        self.events.append("worker:request_stop")
        self.events.append("worker:STOPPING")


class GodotProcessDouble:
    def __init__(self, events: list[str], exit_code: int = 0) -> None:
        self.events = events
        self.exit_code = exit_code
        self.wait_calls = 0

    def wait(self) -> int:
        self.wait_calls += 1
        self.events.append("godot:exit")
        return self.exit_code


def _run(
    module: ModuleType,
    worker_factory: Callable[[], WorkerDouble],
    godot_launcher: Callable[[], GodotProcessDouble],
    *,
    shutdown_budget_seconds: float = 0.05,
) -> Any:
    return module.run_runtime_generation(
        worker_factory=worker_factory,
        godot_launcher=godot_launcher,
        shutdown_budget_seconds=shutdown_budget_seconds,
    )


def test_ticket3e_ready_precedes_godot_and_one_worker_owns_generation() -> None:
    module = _launcher_module()
    events: list[str] = []
    workers: list[WorkerDouble] = []
    godot_process = GodotProcessDouble(events)

    def worker_factory() -> WorkerDouble:
        events.append("worker:construct")
        worker = WorkerDouble(events)
        workers.append(worker)
        return worker

    def godot_launcher() -> GodotProcessDouble:
        events.append("godot:launch")
        return godot_process

    _run(module, worker_factory, godot_launcher)

    assert len(workers) == 1
    assert events.index("worker:READY") < events.index("godot:launch")
    assert workers[0].stop_calls == 1
    assert workers[0].worker_state == "STOPPED"
    assert events.index("godot:exit") < events.index("worker:request_stop")


def test_ticket3e_prepare_failure_prevents_godot_and_no_fallback_worker() -> None:
    module = _launcher_module()
    events: list[str] = []
    workers: list[WorkerDouble] = []
    godot_launches = 0

    def worker_factory() -> WorkerDouble:
        worker = WorkerDouble(events, prepare_error=RuntimeError("prepare rejected"))
        workers.append(worker)
        return worker

    def godot_launcher() -> GodotProcessDouble:
        nonlocal godot_launches
        godot_launches += 1
        return GodotProcessDouble(events)

    with pytest.raises(RuntimeError, match="prepare rejected"):
        _run(module, worker_factory, godot_launcher)

    assert len(workers) == 1
    assert godot_launches == 0


def test_ticket3e_non_ready_worker_prevents_godot_start() -> None:
    module = _launcher_module()
    events: list[str] = []
    worker = WorkerDouble(events, prepare_state="STOPPED")
    godot_launches = 0

    def godot_launcher() -> GodotProcessDouble:
        nonlocal godot_launches
        godot_launches += 1
        return GodotProcessDouble(events)

    with pytest.raises(Exception, match="READY"):
        _run(module, lambda: worker, godot_launcher)

    assert godot_launches == 0
    assert worker.stop_calls == 0


def test_ticket3e_godot_launch_failure_stops_the_same_ready_worker() -> None:
    module = _launcher_module()
    events: list[str] = []
    worker = WorkerDouble(events)

    def godot_launcher() -> GodotProcessDouble:
        events.append("godot:launch_failed")
        raise RuntimeError("Godot failed to start")

    with pytest.raises(RuntimeError, match="Godot failed to start"):
        _run(module, lambda: worker, godot_launcher)

    assert worker.stop_calls == 1
    assert worker.worker_state == "STOPPED"
    assert events.index("worker:READY") < events.index("godot:launch_failed")
    assert events.index("godot:launch_failed") < events.index("worker:request_stop")


def test_ticket3e_launcher_waits_boundedly_for_terminal_stopped() -> None:
    module = _launcher_module()
    events: list[str] = []
    worker = WorkerDouble(events, stop_reads_before_stopped=10**9)

    with pytest.raises(Exception, match="STOPPED|bound|timeout"):
        _run(
            module,
            lambda: worker,
            lambda: GodotProcessDouble(events),
            shutdown_budget_seconds=0.001,
        )

    assert worker.stop_calls == 1
    assert worker.worker_state == "STOPPING"


def test_ticket3e_godot_python_supervision_remains_forbidden() -> None:
    for path in PROTECTED_GODOT_PATHS:
        source = path.read_text(encoding="utf-8")
        assert "OS.create_process" not in source
        assert "request_stop" not in source
    scene_runner = (
        PROJECT_ROOT / "addons/godot_ollama_task_performer/scene_runner.gd"
    ).read_text(encoding="utf-8")
    assert CONTRACT_MARKER not in scene_runner


def test_ticket3e_existing_ticket2f_worker_stop_surface_is_preserved() -> None:
    source = ADAPTER_PATH.read_text(encoding="utf-8")
    tree = ast.parse(source, filename=str(ADAPTER_PATH))
    adapter_class = next(
        node
        for node in tree.body
        if isinstance(node, ast.ClassDef) and node.name == "HermesSessionAdapter"
    )
    method_names = {
        node.name for node in adapter_class.body if isinstance(node, ast.FunctionDef)
    }
    assert {"prepare", "request_stop", "_finish_stop"} <= method_names
    assert 'self.worker_state = "READY"' in source
    assert 'self.worker_state = "STOPPING"' in source
    assert 'self.worker_state = "STOPPED"' in source

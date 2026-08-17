from __future__ import annotations

import ast
import hashlib
import importlib.util
import sys
from pathlib import Path
from types import ModuleType
from typing import Any, Callable, cast

import pytest


PROJECT_ROOT = Path(__file__).resolve().parents[1]
COMPOSITION_MARKER = "ENGAV3D_STAGE8_TICKET3F_CONCRETE_RUNTIME_COMPOSITION_V1"
TICKET3E_MARKER = "ENGAV3D_STAGE8_TICKET3E_LAUNCHER_SUPERVISION_V1"
RUNTIME_LAUNCHER = PROJECT_ROOT / "runtime_launcher.py"
ADAPTER_PATH = PROJECT_ROOT / "hermes_session_adapter.py"
TICKET3E_TEST = PROJECT_ROOT / "tests" / "test_stage8_ticket3e_launcher_supervision_red.py"
RUNTIME_LAUNCHER_SHA256 = "e2388f74953a452f5626565fcde7d6e5abc4c92eb01187570d9cf03abd62ec96"
TICKET3E_TEST_SHA256 = "c89aa2153d2a7bb1db50a6b1cf901ef8cefa655f8d0244a1911b56e26e78d68d"
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
    )


def _composition_module() -> ModuleType:
    candidates: list[Path] = []
    for path in _production_python_paths():
        source = path.read_text(encoding="utf-8")
        ast.parse(source, filename=str(path))
        if COMPOSITION_MARKER in source:
            candidates.append(path)

    assert len(candidates) == 1, (
        "QUALIFYING_CONCRETE_RUNTIME_COMPOSITION_BOUNDARY_DOES_NOT_EXIST: "
        "Ticket 3F requires exactly one production Python composition boundary "
        f"marked {COMPOSITION_MARKER}, but found {len(candidates)}"
    )

    path = candidates[0]
    spec = importlib.util.spec_from_file_location("ticket3f_runtime_composition", path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    try:
        spec.loader.exec_module(module)
    finally:
        sys.modules.pop(spec.name, None)
    return module


def _composition_entry(module: ModuleType) -> Callable[..., int]:
    entries = [
        value
        for value in vars(module).values()
        if callable(value)
        and getattr(value, COMPOSITION_MARKER, False) is True
    ]
    assert len(entries) == 1, (
        "qualifying concrete composition must mark exactly one callable production "
        "entry without prescribing its implementation helper names"
    )
    return cast(Callable[..., int], entries[0])


class AdapterDouble:
    def __init__(self, events: list[str], *, ready: bool = True) -> None:
        self.events = events
        self.ready = ready
        self.worker_state = "STOPPED"
        self.prepare_calls = 0
        self.stop_calls = 0
        self.finish_calls = 0
        self.service_cycles = 0

    def prepare(self) -> None:
        self.prepare_calls += 1
        self.events.append("worker:prepare")
        self.worker_state = "READY" if self.ready else "STOPPED"
        self.events.append(f"worker:{self.worker_state}")

    def process_once(self) -> bool:
        assert self.worker_state == "READY"
        self.service_cycles += 1
        self.events.append("worker:service")
        return False

    def request_stop(self) -> None:
        self.stop_calls += 1
        if self.worker_state == "READY":
            self.worker_state = "STOPPING"
        self.events.append(f"worker:request_stop:{self.worker_state}")

    def finish_stop(self) -> None:
        self.finish_calls += 1
        assert self.worker_state == "STOPPING"
        self.worker_state = "STOPPED"
        self.events.append("worker:STOPPED")


class OwnershipDouble:
    def __init__(self, events: list[str]) -> None:
        self.events = events
        self.acquire_calls = 0
        self.release_calls = 0
        self.acquired = False

    def acquire(self) -> None:
        self.acquire_calls += 1
        assert not self.acquired
        self.acquired = True
        self.events.append("ownership:acquire")

    def release(self) -> None:
        self.release_calls += 1
        assert self.acquired
        self.acquired = False
        self.events.append("ownership:release")


class ServiceDouble:
    def __init__(self, adapter: AdapterDouble, events: list[str]) -> None:
        self.adapter = adapter
        self.events = events
        self.start_calls = 0
        self.close_calls = 0
        self.active = False

    def start(self) -> None:
        assert self.adapter.worker_state == "READY"
        self.start_calls += 1
        self.active = True
        self.events.append("service:start")
        self.adapter.process_once()

    def close(self, shutdown_budget_seconds: float) -> None:
        assert shutdown_budget_seconds > 0
        self.close_calls += 1
        self.active = False
        self.events.append("service:close")
        self.adapter.finish_stop()


class GodotProcessDouble:
    def __init__(self, events: list[str], service: ServiceDouble, exit_code: int = 0) -> None:
        self.events = events
        self.service = service
        self.exit_code = exit_code
        self.wait_calls = 0

    def wait(self) -> int:
        self.wait_calls += 1
        assert self.service.active
        self.events.append("godot:wait_while_service_active")
        return self.exit_code


def _invoke(
    module: ModuleType,
    *,
    project_dir: Path,
    adapter_factory: Callable[[Path], AdapterDouble],
    ownership_factory: Callable[[Path], OwnershipDouble],
    service_factory: Callable[[AdapterDouble], ServiceDouble],
    godot_process_factory: Callable[[str, Path], GodotProcessDouble],
    shutdown_budget_seconds: float = 0.05,
) -> int:
    entry = _composition_entry(module)
    return entry(
        project_dir=project_dir,
        godot_command="injected-godot-command",
        shutdown_budget_seconds=shutdown_budget_seconds,
        adapter_factory=adapter_factory,
        ownership_factory=ownership_factory,
        service_factory=service_factory,
        godot_process_factory=godot_process_factory,
    )


def test_ticket3f_concrete_binding_owns_one_real_adapter_shape_and_exclusive_generation(
    tmp_path: Path,
) -> None:
    module = _composition_module()
    assert module.__file__ is not None
    source = Path(module.__file__).read_text(encoding="utf-8")
    assert "AdapterConfig" in source
    assert "HermesSessionAdapter" in source
    assert "PidFileLock" in source
    assert "run_runtime_generation" in source

    events: list[str] = []
    adapters: list[AdapterDouble] = []
    ownerships: list[OwnershipDouble] = []

    def adapter_factory(project_dir: Path) -> AdapterDouble:
        assert project_dir == tmp_path
        adapter = AdapterDouble(events)
        adapters.append(adapter)
        return adapter

    def ownership_factory(project_dir: Path) -> OwnershipDouble:
        assert project_dir == tmp_path
        ownership = OwnershipDouble(events)
        ownerships.append(ownership)
        return ownership

    service: ServiceDouble | None = None

    def service_factory(adapter: AdapterDouble) -> ServiceDouble:
        nonlocal service
        assert adapter is adapters[0]
        service = ServiceDouble(adapter, events)
        return service

    def godot_factory(command: str, project_dir: Path) -> GodotProcessDouble:
        assert command == "injected-godot-command"
        assert project_dir == tmp_path
        assert service is not None
        events.append("godot:construct")
        return GodotProcessDouble(events, service)

    assert _invoke(
        module,
        project_dir=tmp_path,
        adapter_factory=adapter_factory,
        ownership_factory=ownership_factory,
        service_factory=service_factory,
        godot_process_factory=godot_factory,
    ) == 0
    assert len(adapters) == 1
    assert len(ownerships) == 1
    assert ownerships[0].acquire_calls == ownerships[0].release_calls == 1
    assert adapters[0].prepare_calls == adapters[0].stop_calls == adapters[0].finish_calls == 1
    assert adapters[0].worker_state == "STOPPED"


def test_ticket3f_ready_and_persistent_servicing_precede_and_outlive_godot(
    tmp_path: Path,
) -> None:
    module = _composition_module()
    events: list[str] = []
    adapter = AdapterDouble(events)
    ownership = OwnershipDouble(events)
    service = ServiceDouble(adapter, events)

    _invoke(
        module,
        project_dir=tmp_path,
        adapter_factory=lambda _path: adapter,
        ownership_factory=lambda _path: ownership,
        service_factory=lambda same_adapter: service if same_adapter is adapter else pytest.fail("worker changed"),
        godot_process_factory=lambda _command, _path: GodotProcessDouble(events, service),
    )

    assert events.index("ownership:acquire") < events.index("worker:READY")
    assert events.index("worker:READY") < events.index("service:start")
    assert events.index("service:start") < events.index("godot:wait_while_service_active")
    assert events.index("godot:wait_while_service_active") < events.index("worker:request_stop:STOPPING")
    assert events.index("worker:request_stop:STOPPING") < events.index("worker:STOPPED")
    assert events.index("worker:STOPPED") < events.index("ownership:release")
    assert adapter.service_cycles >= 1


def test_ticket3f_non_ready_generation_fails_closed_before_godot(
    tmp_path: Path,
) -> None:
    module = _composition_module()
    events: list[str] = []
    adapter = AdapterDouble(events, ready=False)
    ownership = OwnershipDouble(events)
    godot_calls = 0

    def forbidden_godot(_command: str, _path: Path) -> GodotProcessDouble:
        nonlocal godot_calls
        godot_calls += 1
        raise AssertionError("Godot construction occurred before READY")

    with pytest.raises(Exception, match="READY"):
        _invoke(
            module,
            project_dir=tmp_path,
            adapter_factory=lambda _path: adapter,
            ownership_factory=lambda _path: ownership,
            service_factory=lambda same_adapter: ServiceDouble(same_adapter, events),
            godot_process_factory=forbidden_godot,
        )
    assert godot_calls == 0
    assert adapter.stop_calls == 0
    assert ownership.release_calls == 1


def test_ticket3f_godot_launch_failure_completes_same_worker_stop_and_releases_ownership(
    tmp_path: Path,
) -> None:
    module = _composition_module()
    events: list[str] = []
    adapters: list[AdapterDouble] = []
    adapter = AdapterDouble(events)
    ownership = OwnershipDouble(events)
    service = ServiceDouble(adapter, events)

    def adapter_factory(_path: Path) -> AdapterDouble:
        adapters.append(adapter)
        return adapter

    def fail_launch(_command: str, _path: Path) -> GodotProcessDouble:
        events.append("godot:launch_failure")
        raise RuntimeError("Godot child construction failed")

    with pytest.raises(RuntimeError, match="Godot child construction failed"):
        _invoke(
            module,
            project_dir=tmp_path,
            adapter_factory=adapter_factory,
            ownership_factory=lambda _path: ownership,
            service_factory=lambda same_adapter: service if same_adapter is adapter else pytest.fail("worker changed"),
            godot_process_factory=fail_launch,
        )

    assert adapters == [adapter]
    assert adapter.stop_calls == 1
    assert adapter.finish_calls == 1
    assert adapter.worker_state == "STOPPED"
    assert service.close_calls == 1
    assert ownership.release_calls == 1
    assert events.index("godot:launch_failure") < events.index("worker:request_stop:STOPPING")
    assert events.index("worker:STOPPED") < events.index("ownership:release")


def test_ticket3f_non_editor_process_and_executable_entry_are_concrete_but_injected(
    tmp_path: Path,
) -> None:
    module = _composition_module()
    assert module.__file__ is not None
    source_path = Path(module.__file__)
    source = source_path.read_text(encoding="utf-8")
    tree = ast.parse(source, filename=str(source_path))
    assert callable(getattr(module, "main", None))
    assert any(
        isinstance(node, ast.If)
        and isinstance(node.test, ast.Compare)
        and "__name__" in ast.unparse(node.test)
        and "__main__" in ast.unparse(node.test)
        for node in tree.body
    )
    assert "editor_interface" not in source
    assert "play_current_scene" not in source
    assert "scene_runner.gd" not in source

    events: list[str] = []
    adapter = AdapterDouble(events)
    ownership = OwnershipDouble(events)
    service = ServiceDouble(adapter, events)
    process_calls: list[tuple[str, Path]] = []

    def godot_factory(command: str, project_dir: Path) -> GodotProcessDouble:
        process_calls.append((command, project_dir))
        return GodotProcessDouble(events, service)

    _invoke(
        module,
        project_dir=tmp_path,
        adapter_factory=lambda _path: adapter,
        ownership_factory=lambda _path: ownership,
        service_factory=lambda _adapter: service,
        godot_process_factory=godot_factory,
    )
    assert process_calls == [("injected-godot-command", tmp_path)]
    assert (PROJECT_ROOT / "project.godot").read_text(encoding="utf-8").count(
        'run/main_scene="res://scenes/Main.tscn"'
    ) == 1


def test_ticket3f_ticket3e_supervision_and_test_authority_are_byte_preserved() -> None:
    assert hashlib.sha256(RUNTIME_LAUNCHER.read_bytes()).hexdigest() == RUNTIME_LAUNCHER_SHA256
    assert hashlib.sha256(TICKET3E_TEST.read_bytes()).hexdigest() == TICKET3E_TEST_SHA256
    launcher_source = RUNTIME_LAUNCHER.read_text(encoding="utf-8")
    assert TICKET3E_MARKER in launcher_source
    assert "run_runtime_generation" in launcher_source


def test_ticket3f_godot_side_python_spawn_remains_forbidden() -> None:
    for path in PROTECTED_GODOT_PATHS:
        source = path.read_text(encoding="utf-8")
        assert "OS.create_process" not in source
        assert "request_stop" not in source
    scene_runner = (
        PROJECT_ROOT / "addons/godot_ollama_task_performer/scene_runner.gd"
    ).read_text(encoding="utf-8")
    assert COMPOSITION_MARKER not in scene_runner


def test_ticket3f_ticket2f_stopping_is_distinct_from_terminal_stopped() -> None:
    source = ADAPTER_PATH.read_text(encoding="utf-8")
    tree = ast.parse(source, filename=str(ADAPTER_PATH))
    adapter_class = next(
        node
        for node in tree.body
        if isinstance(node, ast.ClassDef) and node.name == "HermesSessionAdapter"
    )
    methods = {
        node.name: ast.get_source_segment(source, node) or ""
        for node in adapter_class.body
        if isinstance(node, ast.FunctionDef)
    }
    assert {"prepare", "request_stop", "_finish_stop"} <= set(methods)
    assert 'self.worker_state = "STOPPING"' in methods["request_stop"]
    assert 'self.worker_state = "STOPPED"' not in methods["request_stop"]
    assert 'self.worker_state = "STOPPED"' in methods["_finish_stop"]

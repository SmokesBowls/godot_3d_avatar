from __future__ import annotations

import json
import os
from pathlib import Path
import signal
import subprocess
import time
from typing import Any

import pytest


PROJECT_ROOT = Path(__file__).resolve().parents[1]
LAUNCHER = PROJECT_ROOT / "launch_dragon3d.sh"


def _write_fake_process(path: Path) -> None:
    path.write_text(
        """#!/usr/bin/env python3
import json
import os
from pathlib import Path
import signal
import sys
import time

role = "editor" if "--editor" in sys.argv else "runtime"
event_log = Path(os.environ["EVENT_LOG"])
exit_file = Path(os.environ[f"{role.upper()}_EXIT_FILE"])
exit_code = int(os.environ.get(f"{role.upper()}_EXIT_CODE", "0"))

def record(event):
    with event_log.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps({"role": role, "event": event, "pid": os.getpid(), "argv": sys.argv[1:]}) + "\\n")

def stop(signum, frame):
    record("terminated")
    raise SystemExit(0)

signal.signal(signal.SIGINT, stop)
signal.signal(signal.SIGTERM, stop)
record("started")
while not exit_file.exists():
    time.sleep(0.02)
record("natural_exit")
raise SystemExit(exit_code)
""",
        encoding="utf-8",
    )
    path.chmod(0o755)


def _events(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line]


def _wait_for(predicate, *, timeout: float = 5.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.02)
    raise AssertionError("condition did not become true before timeout")


def _start_launcher(tmp_path: Path, *, runtime_exit_code: int = 0) -> tuple[subprocess.Popen[str], Path, Path, Path]:
    fake_godot = tmp_path / "fake_godot"
    fake_python = tmp_path / "fake_python"
    _write_fake_process(fake_godot)
    _write_fake_process(fake_python)

    engain_root = tmp_path / "EngAIn"
    authority = engain_root / "tier1/engainos/server/presence_authority_server.py"
    authority.parent.mkdir(parents=True)
    authority.write_text("# test fixture only\n", encoding="utf-8")

    event_log = tmp_path / "events.jsonl"
    editor_exit = tmp_path / "editor.exit"
    runtime_exit = tmp_path / "runtime.exit"
    env = os.environ.copy()
    env.update(
        {
            "GODOT_COMMAND": str(fake_godot),
            "PYTHON_COMMAND": str(fake_python),
            "ENGAIN_REPO_ROOT": str(engain_root),
            "EVENT_LOG": str(event_log),
            "EDITOR_EXIT_FILE": str(editor_exit),
            "RUNTIME_EXIT_FILE": str(runtime_exit),
            "RUNTIME_EXIT_CODE": str(runtime_exit_code),
        }
    )
    process = subprocess.Popen(
        [str(LAUNCHER)],
        cwd=tmp_path,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    return process, event_log, editor_exit, runtime_exit


def _roles_started(event_log: Path) -> set[str]:
    return {
        str(event["role"])
        for event in _events(event_log)
        if event["event"] == "started"
    }


def _cleanup(process: subprocess.Popen[str]) -> None:
    if process.poll() is None:
        process.send_signal(signal.SIGTERM)
        process.communicate(timeout=5.0)


def test_one_invocation_starts_editor_and_existing_composed_runtime(tmp_path: Path) -> None:
    process, event_log, _, _ = _start_launcher(tmp_path)
    try:
        _wait_for(lambda: _roles_started(event_log) == {"editor", "runtime"})
        events = _events(event_log)
        editor = next(event for event in events if event["role"] == "editor" and event["event"] == "started")
        runtime = next(event for event in events if event["role"] == "runtime" and event["event"] == "started")

        assert editor["argv"] == ["--editor", "--path", str(PROJECT_ROOT)]
        assert runtime["argv"][0] == str(PROJECT_ROOT / "runtime_composition.py")
        assert "--godot-command" in runtime["argv"]
        assert str(PROJECT_ROOT) in runtime["argv"]
    finally:
        _cleanup(process)


def test_closing_editor_does_not_stop_composed_runtime(tmp_path: Path) -> None:
    process, event_log, editor_exit, runtime_exit = _start_launcher(tmp_path)
    try:
        _wait_for(lambda: _roles_started(event_log) == {"editor", "runtime"})
        editor_exit.touch()
        _wait_for(lambda: any(e["role"] == "editor" and e["event"] == "natural_exit" for e in _events(event_log)))
        time.sleep(0.1)
        assert process.poll() is None
        assert not any(e["role"] == "runtime" and e["event"] == "terminated" for e in _events(event_log))

        runtime_exit.touch()
        assert process.wait(timeout=5.0) == 0
    finally:
        _cleanup(process)


def test_closing_runtime_does_not_stop_editor(tmp_path: Path) -> None:
    process, event_log, editor_exit, runtime_exit = _start_launcher(tmp_path)
    try:
        _wait_for(lambda: _roles_started(event_log) == {"editor", "runtime"})
        runtime_exit.touch()
        _wait_for(lambda: any(e["role"] == "runtime" and e["event"] == "natural_exit" for e in _events(event_log)))
        time.sleep(0.1)
        assert process.poll() is None
        assert not any(e["role"] == "editor" and e["event"] == "terminated" for e in _events(event_log))

        editor_exit.touch()
        assert process.wait(timeout=5.0) == 0
    finally:
        _cleanup(process)


@pytest.mark.parametrize(
    ("shutdown_signal", "expected_status"),
    [(signal.SIGINT, 128 + signal.SIGINT), (signal.SIGTERM, 128 + signal.SIGTERM)],
)
def test_launcher_signal_terminates_and_reaps_both_owned_siblings(
    tmp_path: Path, shutdown_signal: signal.Signals, expected_status: int
) -> None:
    process, event_log, _, _ = _start_launcher(tmp_path)
    try:
        _wait_for(lambda: _roles_started(event_log) == {"editor", "runtime"})
        process.send_signal(shutdown_signal)
        assert process.wait(timeout=5.0) == expected_status
        _wait_for(
            lambda: {
                str(e["role"])
                for e in _events(event_log)
                if e["event"] == "terminated"
            }
            == {"editor", "runtime"}
        )
    finally:
        _cleanup(process)


def test_runtime_startup_failure_leaves_editor_available_and_is_final_exit_status(tmp_path: Path) -> None:
    process, event_log, editor_exit, runtime_exit = _start_launcher(tmp_path, runtime_exit_code=23)
    try:
        _wait_for(lambda: _roles_started(event_log) == {"editor", "runtime"})
        runtime_exit.touch()
        _wait_for(lambda: any(e["role"] == "runtime" and e["event"] == "natural_exit" for e in _events(event_log)))
        time.sleep(0.1)
        assert process.poll() is None

        editor_exit.touch()
        assert process.wait(timeout=5.0) == 23
    finally:
        _cleanup(process)

from __future__ import annotations

import hashlib
import http.client
import importlib.util
import json
import os
from pathlib import Path
import socket
import stat
import sys
from typing import Any, Callable, Iterator
import urllib.request

import pytest


PROJECT_ROOT = Path(__file__).resolve().parents[1]
ADAPTER_PATH = PROJECT_ROOT / "hermes_session_adapter.py"
STATE_RELATIVE_PATH = Path(".godot/engain_hermes_session.json")
STATE_KEYS = {
    "profile",
    "companion_ref",
    "provider",
    "model",
    "session_id",
    "processed_request_ids",
}
FROZEN_STATE: dict[str, Any] = {
    "profile": "default",
    "companion_ref": "hermes_b",
    "provider": "openai-codex",
    "model": "gpt-5.6-sol",
    "session_id": "20260731_065008_63a62d",
    "processed_request_ids": [],
}
VALID_REQUEST_ID = "req_0123456789abcdef0123456789abcdef"


def _load_adapter() -> Any:
    spec = importlib.util.spec_from_file_location("stage6b_state_adapter", ADAPTER_PATH)
    assert spec is not None
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    try:
        spec.loader.exec_module(module)
    finally:
        sys.modules.pop(spec.name, None)
    return module


@pytest.fixture
def adapter_module() -> Any:
    return _load_adapter()


@pytest.fixture
def project_root(tmp_path: Path) -> Iterator[Path]:
    root = tmp_path / "godot_engain_3d_avatar"
    (root / ".godot").mkdir(parents=True)
    yield root
    assert not (root / "engain_response.json").exists()


@pytest.fixture(autouse=True)
def zero_execution_guard(
    adapter_module: Any, monkeypatch: pytest.MonkeyPatch
) -> Iterator[list[str]]:
    calls: list[str] = []

    def forbidden(name: str) -> Callable[..., Any]:
        def fail(*args: Any, **kwargs: Any) -> Any:
            calls.append(name)
            pytest.fail(
                f"Stage 6B state bootstrap attempted forbidden execution: {name}"
            )

        return fail

    monkeypatch.setattr(
        adapter_module.HermesCLIClient,
        "_run_bounded",
        forbidden("HermesCLIClient._run_bounded"),
    )
    monkeypatch.setattr(
        adapter_module.HermesCLIClient,
        "chat",
        forbidden("HermesCLIClient.chat"),
    )
    monkeypatch.setattr(
        adapter_module.HermesSessionAdapter,
        "process_once",
        forbidden("HermesSessionAdapter.process_once"),
    )
    monkeypatch.setattr(
        adapter_module.HermesSessionAdapter,
        "_claim_request_file",
        forbidden("HermesSessionAdapter._claim_request_file"),
    )
    monkeypatch.setattr(
        adapter_module.HermesSessionAdapter,
        "_write_response",
        forbidden("HermesSessionAdapter._write_response"),
    )
    monkeypatch.setattr(
        adapter_module.subprocess,
        "Popen",
        forbidden("subprocess.Popen"),
    )
    monkeypatch.setattr(
        adapter_module.subprocess,
        "run",
        forbidden("subprocess.run"),
    )
    monkeypatch.setattr(socket, "socket", forbidden("socket.socket"))
    monkeypatch.setattr(urllib.request, "urlopen", forbidden("urllib.request.urlopen"))
    monkeypatch.setattr(
        http.client.HTTPConnection,
        "request",
        forbidden("http.client.HTTPConnection.request"),
    )
    monkeypatch.setattr(
        http.client.HTTPSConnection,
        "request",
        forbidden("http.client.HTTPSConnection.request"),
    )

    yield calls
    assert calls == []


def _state_path(root: Path) -> Path:
    return root / STATE_RELATIVE_PATH


def _state_bytes(value: dict[str, Any] | None = None) -> bytes:
    payload = FROZEN_STATE if value is None else value
    return (json.dumps(payload, indent=2, sort_keys=True) + "\n").encode("utf-8")


def _write_state(root: Path, value: dict[str, Any] | None = None) -> Path:
    path = _state_path(root)
    path.write_bytes(_state_bytes(value))
    return path


def _run_initialize(
    module: Any,
    monkeypatch: pytest.MonkeyPatch,
    root: Path,
    capsys: pytest.CaptureFixture[str],
) -> tuple[int, str, str]:
    monkeypatch.setattr(module, "MAILBOX_PROJECT_ROOT", root, raising=False)
    try:
        result = module.main(["--initialize-state"])
    except SystemExit as exc:
        pytest.fail(
            "STAGE6B_INTENTIONAL_RED: public provider-free --initialize-state "
            f"CLI is absent (argparse exited {exc.code})",
            pytrace=False,
        )
    captured = capsys.readouterr()
    return result, captured.out, captured.err


def _assert_invalid_unchanged(
    module: Any,
    monkeypatch: pytest.MonkeyPatch,
    root: Path,
    capsys: pytest.CaptureFixture[str],
    raw: bytes,
) -> None:
    path = _state_path(root)
    path.write_bytes(raw)
    before_hash = hashlib.sha256(raw).hexdigest()
    before_inode = path.stat().st_ino
    result, stdout, _ = _run_initialize(module, monkeypatch, root, capsys)
    assert result == 1
    assert "ENGAIN_SESSION_STATE_READY=1" not in stdout
    assert path.stat().st_ino == before_inode
    assert hashlib.sha256(path.read_bytes()).hexdigest() == before_hash
    assert path.read_bytes() == raw


def test_initialize_state_cli_is_public_and_provider_free(
    adapter_module: Any,
    monkeypatch: pytest.MonkeyPatch,
    project_root: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    result, stdout, stderr = _run_initialize(
        adapter_module, monkeypatch, project_root, capsys
    )
    assert result == 0
    assert stderr == ""
    assert "ENGAIN_SESSION_STATE_READY=1" in stdout
    assert "ENGAIN_SESSION_STATE_CREATED=1" in stdout


def test_missing_state_is_created_at_only_the_exact_project_state_path(
    adapter_module: Any,
    monkeypatch: pytest.MonkeyPatch,
    project_root: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    decoy = project_root / ".godot" / "session.json"
    decoy.write_bytes(b"preserve\n")
    result, _, _ = _run_initialize(adapter_module, monkeypatch, project_root, capsys)
    assert result == 0
    assert _state_path(project_root).is_file()
    assert decoy.read_bytes() == b"preserve\n"
    assert sorted(path.name for path in (project_root / ".godot").iterdir()) == [
        "engain_hermes_session.json",
        "session.json",
    ]


def test_created_state_has_exact_six_key_schema_and_frozen_initial_values(
    adapter_module: Any,
    monkeypatch: pytest.MonkeyPatch,
    project_root: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    result, _, _ = _run_initialize(adapter_module, monkeypatch, project_root, capsys)
    assert result == 0
    raw = _state_path(project_root).read_bytes()
    parsed = json.loads(raw.decode("utf-8"))
    assert set(parsed) == STATE_KEYS
    assert parsed == FROZEN_STATE
    assert parsed["processed_request_ids"] == []


def test_created_state_is_owner_read_write_only(
    adapter_module: Any,
    monkeypatch: pytest.MonkeyPatch,
    project_root: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    result, _, _ = _run_initialize(adapter_module, monkeypatch, project_root, capsys)
    assert result == 0
    assert stat.S_IMODE(_state_path(project_root).stat().st_mode) == 0o600


def test_creation_fsyncs_file_then_links_no_replace_and_fsyncs_cleanup(
    adapter_module: Any,
    monkeypatch: pytest.MonkeyPatch,
    project_root: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    events: list[tuple[str, str]] = []
    real_fsync = os.fsync
    real_link = os.link
    real_unlink = os.unlink

    def traced_fsync(descriptor: int) -> None:
        kind = "directory" if stat.S_ISDIR(os.fstat(descriptor).st_mode) else "file"
        events.append(("fsync", kind))
        real_fsync(descriptor)

    def traced_link(source: Any, destination: Any, *args: Any, **kwargs: Any) -> None:
        events.append(("link", f"{source}->{destination}"))
        real_link(source, destination, *args, **kwargs)

    def traced_unlink(path: Any, *args: Any, **kwargs: Any) -> None:
        events.append(("unlink", str(path)))
        real_unlink(path, *args, **kwargs)

    monkeypatch.setattr(adapter_module.os, "fsync", traced_fsync)
    monkeypatch.setattr(adapter_module.os, "link", traced_link)
    monkeypatch.setattr(adapter_module.os, "unlink", traced_unlink)

    result, _, _ = _run_initialize(adapter_module, monkeypatch, project_root, capsys)
    assert result == 0

    file_fsync = events.index(("fsync", "file"))
    link_index = next(index for index, event in enumerate(events) if event[0] == "link")
    directory_fsyncs = [
        index for index, event in enumerate(events) if event == ("fsync", "directory")
    ]
    unlink_index = next(index for index, event in enumerate(events) if event[0] == "unlink")
    assert file_fsync < link_index < directory_fsyncs[0]
    assert directory_fsyncs[0] < unlink_index < directory_fsyncs[-1]
    assert len(directory_fsyncs) >= 2


def test_publication_failure_cleans_private_temp_and_creates_no_final_state(
    adapter_module: Any,
    monkeypatch: pytest.MonkeyPatch,
    project_root: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    def fail_link(*args: Any, **kwargs: Any) -> None:
        raise OSError("injected no-replace publication failure")

    monkeypatch.setattr(adapter_module.os, "link", fail_link)
    result, stdout, _ = _run_initialize(adapter_module, monkeypatch, project_root, capsys)
    assert result == 1
    assert "ENGAIN_SESSION_STATE_READY=1" not in stdout
    assert not _state_path(project_root).exists()
    assert list((project_root / ".godot").iterdir()) == []


def test_atomic_collision_preserves_racing_final_state_and_cleans_temp(
    adapter_module: Any,
    monkeypatch: pytest.MonkeyPatch,
    project_root: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    collision = b'{"racing":"writer"}\n'

    def collide(*args: Any, **kwargs: Any) -> None:
        _state_path(project_root).write_bytes(collision)
        raise FileExistsError("injected final-state collision")

    monkeypatch.setattr(adapter_module.os, "link", collide)
    result, _, _ = _run_initialize(adapter_module, monkeypatch, project_root, capsys)
    assert result == 1
    assert _state_path(project_root).read_bytes() == collision
    assert sorted(path.name for path in (project_root / ".godot").iterdir()) == [
        "engain_hermes_session.json"
    ]


def test_final_state_symlink_is_rejected_without_target_mutation(
    adapter_module: Any,
    monkeypatch: pytest.MonkeyPatch,
    project_root: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    target = project_root / "outside-state.json"
    target.write_bytes(_state_bytes())
    target_hash = hashlib.sha256(target.read_bytes()).hexdigest()
    final = _state_path(project_root)
    final.symlink_to(target)

    result, stdout, _ = _run_initialize(adapter_module, monkeypatch, project_root, capsys)
    assert result == 1
    assert "ENGAIN_SESSION_STATE_READY=1" not in stdout
    assert final.is_symlink()
    assert hashlib.sha256(target.read_bytes()).hexdigest() == target_hash
    assert target.read_bytes() == _state_bytes()


def test_existing_valid_state_is_accepted_without_any_byte_or_inode_mutation(
    adapter_module: Any,
    monkeypatch: pytest.MonkeyPatch,
    project_root: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    path = _write_state(project_root)
    before = path.read_bytes()
    before_hash = hashlib.sha256(before).hexdigest()
    before_inode = path.stat().st_ino
    before_mtime_ns = path.stat().st_mtime_ns

    result, stdout, stderr = _run_initialize(
        adapter_module, monkeypatch, project_root, capsys
    )
    assert result == 0
    assert stderr == ""
    assert "ENGAIN_SESSION_STATE_READY=1" in stdout
    assert "ENGAIN_SESSION_STATE_CREATED=0" in stdout
    assert path.stat().st_ino == before_inode
    assert path.stat().st_mtime_ns == before_mtime_ns
    assert hashlib.sha256(path.read_bytes()).hexdigest() == before_hash
    assert path.read_bytes() == before


def test_malformed_existing_json_is_rejected_without_mutation(
    adapter_module: Any,
    monkeypatch: pytest.MonkeyPatch,
    project_root: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    _assert_invalid_unchanged(
        adapter_module, monkeypatch, project_root, capsys, b"not-json\n"
    )


def test_duplicate_existing_json_keys_are_rejected_without_mutation(
    adapter_module: Any,
    monkeypatch: pytest.MonkeyPatch,
    project_root: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    raw = (
        b'{"profile":"default","profile":"default","companion_ref":"hermes_b",'
        b'"provider":"openai-codex","model":"gpt-5.6-sol",'
        b'"session_id":"20260731_065008_63a62d","processed_request_ids":[]}\n'
    )
    _assert_invalid_unchanged(adapter_module, monkeypatch, project_root, capsys, raw)


def test_existing_state_with_unknown_or_missing_key_is_rejected_without_mutation(
    adapter_module: Any,
    monkeypatch: pytest.MonkeyPatch,
    project_root: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    value = dict(FROZEN_STATE)
    value.pop("model")
    value["unknown"] = "gpt-5.6-sol"
    _assert_invalid_unchanged(
        adapter_module, monkeypatch, project_root, capsys, _state_bytes(value)
    )


@pytest.mark.parametrize(
    ("field", "wrong_value"),
    [
        pytest.param("profile", "other", id="wrong-profile"),
        pytest.param("companion_ref", "not-hermes-b", id="wrong-companion"),
        pytest.param("provider", "other-provider", id="wrong-provider"),
        pytest.param("model", "other-model", id="wrong-model"),
        pytest.param("session_id", "20260731_065008_wrong", id="wrong-session"),
    ],
)
def test_wrong_frozen_identity_is_rejected_without_mutation(
    adapter_module: Any,
    monkeypatch: pytest.MonkeyPatch,
    project_root: Path,
    capsys: pytest.CaptureFixture[str],
    field: str,
    wrong_value: str,
) -> None:
    value = dict(FROZEN_STATE)
    value[field] = wrong_value
    _assert_invalid_unchanged(
        adapter_module, monkeypatch, project_root, capsys, _state_bytes(value)
    )


def test_duplicate_processed_request_ids_are_rejected_without_mutation(
    adapter_module: Any,
    monkeypatch: pytest.MonkeyPatch,
    project_root: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    value = dict(FROZEN_STATE)
    value["processed_request_ids"] = [VALID_REQUEST_ID, VALID_REQUEST_ID]
    _assert_invalid_unchanged(
        adapter_module, monkeypatch, project_root, capsys, _state_bytes(value)
    )


def test_malformed_processed_request_id_is_rejected_without_mutation(
    adapter_module: Any,
    monkeypatch: pytest.MonkeyPatch,
    project_root: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    value = dict(FROZEN_STATE)
    value["processed_request_ids"] = ["req_NOT_LOWERCASE_HEX"]
    _assert_invalid_unchanged(
        adapter_module, monkeypatch, project_root, capsys, _state_bytes(value)
    )


def test_more_than_256_processed_request_ids_are_rejected_without_mutation(
    adapter_module: Any,
    monkeypatch: pytest.MonkeyPatch,
    project_root: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    value = dict(FROZEN_STATE)
    value["processed_request_ids"] = [f"req_{index:032x}" for index in range(257)]
    _assert_invalid_unchanged(
        adapter_module, monkeypatch, project_root, capsys, _state_bytes(value)
    )


def test_initialization_does_not_claim_request_or_create_response(
    adapter_module: Any,
    monkeypatch: pytest.MonkeyPatch,
    project_root: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    request = project_root / "engain_request.json"
    request_bytes = b'{"sealed":"request-sentinel"}\n'
    request.write_bytes(request_bytes)
    request_inode = request.stat().st_ino

    result, _, _ = _run_initialize(adapter_module, monkeypatch, project_root, capsys)
    assert result == 0
    assert request.read_bytes() == request_bytes
    assert request.stat().st_ino == request_inode
    assert not (project_root / "engain_response.json").exists()
    assert not (project_root / ".godot" / "engain_hermes_replay").exists()

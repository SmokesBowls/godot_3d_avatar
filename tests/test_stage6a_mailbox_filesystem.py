from __future__ import annotations

import base64
import copy
import errno
import importlib.util
import json
import os
from pathlib import Path
import stat
import sys
from typing import Any, Callable

import pytest


PROJECT_ROOT = Path(__file__).resolve().parents[1]
ADAPTER_PATH = PROJECT_ROOT / "hermes_session_adapter.py"
REQUEST_ID = "req_0123456789abcdef0123456789abcdef"
CLIENT_REQUEST_ID = "dragon3d_0123456789abcdef0123456789abcdef_1"
CAPTURE_ID = "cap_0123456789abcdef0123456789abcdef_1"
TEMP_BASENAME = f".engain_request.{REQUEST_ID}.tmp"
FINAL_REQUEST_BASENAME = "engain_request.json"
FINAL_RESPONSE_BASENAME = "engain_response.json"


def _load_adapter() -> Any:
    spec = importlib.util.spec_from_file_location("stage6a_mailbox_adapter", ADAPTER_PATH)
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


@pytest.fixture(autouse=True)
def zero_execution_guard(adapter_module: Any, monkeypatch: pytest.MonkeyPatch) -> Any:
    calls: list[str] = []

    def forbidden(name: str) -> Callable[..., Any]:
        def fail(*args: Any, **kwargs: Any) -> Any:
            calls.append(name)
            pytest.fail(f"Stage 6A publication attempted forbidden execution: {name}")

        return fail

    monkeypatch.setattr(adapter_module.HermesCLIClient, "_run_bounded", forbidden("_run_bounded"))
    monkeypatch.setattr(adapter_module.HermesCLIClient, "chat", forbidden("chat"))
    monkeypatch.setattr(adapter_module.subprocess, "Popen", forbidden("subprocess.Popen"))
    monkeypatch.setattr(adapter_module.subprocess, "run", forbidden("subprocess.run"))
    yield calls
    assert calls == []


def _unavailable_request() -> dict[str, Any]:
    return {
        "player_input": "Stage 6A mailbox fixture",
        "game_state": {},
        "additional_context": {
            "client_request_id": CLIENT_REQUEST_ID,
            "companion_ref": "hermes_b",
            "perception": {
                "schema": "engain.runtime_perception.v1",
                "perception_state": "unavailable",
                "capture_id": CAPTURE_ID,
                "capture_event": "message_received",
                "capture_phase": "pre_dispatch_player_view.v1",
                "captured_at": 1.0,
                "project_id": "godot_3d_avatar",
                "scene_path": "res://scenes/Main.tscn",
                "snapshot": None,
                "viewport": {
                    "availability": "unavailable",
                    "image_path": None,
                    "image_sha256": None,
                    "media_type": None,
                    "width": None,
                    "height": None,
                    "reason": "viewport_unavailable",
                },
                "unavailable_reason": "viewport_unavailable",
            },
        },
        "timestamp": 1.0,
        "request_id": REQUEST_ID,
    }


def _request_bytes(payload: dict[str, Any] | None = None) -> bytes:
    value = _unavailable_request() if payload is None else payload
    return (json.dumps(value, separators=(",", ":"), allow_nan=False) + "\n").encode("utf-8")


def _write_temp(root: Path, raw: bytes | None = None, name: str = TEMP_BASENAME) -> Path:
    path = root / name
    path.write_bytes(_request_bytes() if raw is None else raw)
    return path


def _publication_function(module: Any) -> Callable[[Path], Any]:
    value = getattr(module, "publish_request", None)
    if not callable(value):
        pytest.fail(
            "STAGE6A_INTENTIONAL_RED: public provider-free publish_request helper is absent",
            pytrace=False,
        )
    return value


def _publish(
    module: Any,
    monkeypatch: pytest.MonkeyPatch,
    root: Path,
    temporary: Path,
) -> Any:
    monkeypatch.setattr(module, "MAILBOX_PROJECT_ROOT", root, raising=False)
    return _publication_function(module)(temporary)


def test_publish_request_cli_route_is_public_and_provider_free(
    adapter_module: Any,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    temporary = _write_temp(tmp_path)
    calls: list[Path] = []

    def fake_publish(path: Path) -> Path:
        calls.append(Path(path))
        return tmp_path / FINAL_REQUEST_BASENAME

    monkeypatch.setattr(adapter_module, "publish_request", fake_publish, raising=False)
    result = adapter_module.main(["--publish-request", str(temporary.resolve())])
    assert result == 0
    assert calls == [temporary.resolve()]


def test_exact_temp_basename_is_required(
    adapter_module: Any,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    temporary = _write_temp(tmp_path, name=f"engain_request.{REQUEST_ID}.tmp")
    with pytest.raises((OSError, ValueError, adapter_module.HermesAdapterError)):
        _publish(adapter_module, monkeypatch, tmp_path, temporary)
    assert not (tmp_path / FINAL_REQUEST_BASENAME).exists()


def test_temporary_path_must_be_absolute_and_confined_to_project_root(
    adapter_module: Any,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    project = tmp_path / "project"
    outside = tmp_path / "outside"
    project.mkdir()
    outside.mkdir()
    temporary = _write_temp(outside)
    with pytest.raises((OSError, ValueError, adapter_module.HermesAdapterError)):
        _publish(adapter_module, monkeypatch, project, temporary)
    assert temporary.exists()
    assert not (project / FINAL_REQUEST_BASENAME).exists()


def test_symlink_temporary_is_rejected_and_only_link_is_cleaned(
    adapter_module: Any,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    target = tmp_path / "target.json"
    target.write_bytes(_request_bytes())
    temporary = tmp_path / TEMP_BASENAME
    temporary.symlink_to(target)
    with pytest.raises((OSError, ValueError, adapter_module.HermesAdapterError)):
        _publish(adapter_module, monkeypatch, tmp_path, temporary)
    assert target.read_bytes() == _request_bytes()
    assert not temporary.exists()
    assert not (tmp_path / FINAL_REQUEST_BASENAME).exists()


def test_nonregular_temporary_is_rejected_and_cleaned(
    adapter_module: Any,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    temporary = tmp_path / TEMP_BASENAME
    os.mkfifo(temporary)
    with pytest.raises((OSError, ValueError, adapter_module.HermesAdapterError)):
        _publish(adapter_module, monkeypatch, tmp_path, temporary)
    assert not temporary.exists()
    assert not (tmp_path / FINAL_REQUEST_BASENAME).exists()


@pytest.mark.parametrize(
    "raw",
    [
        b"not-json\n",
        b'{"request_id":"a","request_id":"b"}\n',
        b'{"timestamp":NaN}\n',
        b"[]\n",
        (lambda: (
            json.dumps(
                {**_unavailable_request(), "unknown": True},
                separators=(",", ":"),
            )
            + "\n"
        ).encode("utf-8"))(),
    ],
)
def test_strict_request_json_is_required(
    adapter_module: Any,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    raw: bytes,
) -> None:
    temporary = _write_temp(tmp_path, raw=raw)
    with pytest.raises((OSError, ValueError, adapter_module.HermesAdapterError)):
        _publish(adapter_module, monkeypatch, tmp_path, temporary)
    assert not temporary.exists()
    assert not (tmp_path / FINAL_REQUEST_BASENAME).exists()


def test_request_id_must_match_temp_filename(
    adapter_module: Any,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    payload = _unavailable_request()
    payload["request_id"] = "req_ffffffffffffffffffffffffffffffff"
    temporary = _write_temp(tmp_path, raw=_request_bytes(payload))
    with pytest.raises((OSError, ValueError, adapter_module.HermesAdapterError)):
        _publish(adapter_module, monkeypatch, tmp_path, temporary)
    assert not temporary.exists()
    assert not (tmp_path / FINAL_REQUEST_BASENAME).exists()


def test_publication_fsyncs_before_atomic_hard_link_and_fsyncs_directory_twice(
    adapter_module: Any,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    temporary = _write_temp(tmp_path)
    events: list[str] = []
    real_fsync = os.fsync
    real_link = os.link
    real_unlink = os.unlink

    def traced_fsync(descriptor: int) -> None:
        mode = os.fstat(descriptor).st_mode
        events.append("fsync_dir" if stat.S_ISDIR(mode) else "fsync_file")
        real_fsync(descriptor)

    def traced_link(*args: Any, **kwargs: Any) -> None:
        events.append("link_no_replace")
        real_link(*args, **kwargs)

    def traced_unlink(*args: Any, **kwargs: Any) -> None:
        events.append("unlink_temp")
        real_unlink(*args, **kwargs)

    monkeypatch.setattr(adapter_module.os, "fsync", traced_fsync)
    monkeypatch.setattr(adapter_module.os, "link", traced_link)
    monkeypatch.setattr(adapter_module.os, "unlink", traced_unlink)
    _publish(adapter_module, monkeypatch, tmp_path, temporary)

    assert events.index("fsync_file") < events.index("link_no_replace")
    assert events.index("link_no_replace") < events.index("fsync_dir")
    assert events.index("fsync_dir") < events.index("unlink_temp")
    assert events.count("fsync_dir") >= 2


def test_finalized_request_is_the_exact_validated_inode_and_bytes(
    adapter_module: Any,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    expected = _request_bytes()
    temporary = _write_temp(tmp_path, raw=expected)
    temporary_inode = temporary.stat().st_ino
    _publish(adapter_module, monkeypatch, tmp_path, temporary)

    finalized = tmp_path / FINAL_REQUEST_BASENAME
    assert finalized.read_bytes() == expected
    assert finalized.stat().st_ino == temporary_inode
    assert not temporary.exists()


def test_final_request_collision_never_overwrites_and_cleans_new_temp(
    adapter_module: Any,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    finalized = tmp_path / FINAL_REQUEST_BASENAME
    original = b'{"preexisting":true}\n'
    finalized.write_bytes(original)
    original_inode = finalized.stat().st_ino
    temporary = _write_temp(tmp_path)

    with pytest.raises((FileExistsError, OSError, adapter_module.HermesAdapterError)):
        _publish(adapter_module, monkeypatch, tmp_path, temporary)
    assert finalized.read_bytes() == original
    assert finalized.stat().st_ino == original_inode
    assert not temporary.exists()


def test_publication_failure_cleans_only_exact_temp_and_never_creates_final(
    adapter_module: Any,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    temporary = _write_temp(tmp_path)
    unrelated = tmp_path / ".engain_request.unrelated.tmp"
    unrelated.write_text("preserve", encoding="utf-8")

    def fail_link(*args: Any, **kwargs: Any) -> None:
        raise OSError(errno.EIO, "injected publication failure")

    monkeypatch.setattr(adapter_module.os, "link", fail_link)
    with pytest.raises((OSError, adapter_module.HermesAdapterError)):
        _publish(adapter_module, monkeypatch, tmp_path, temporary)
    assert not temporary.exists()
    assert unrelated.read_text(encoding="utf-8") == "preserve"
    assert not (tmp_path / FINAL_REQUEST_BASENAME).exists()


def test_existing_claim_response_helper_remains_strict_and_usable(
    adapter_module: Any,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    response = tmp_path / FINAL_RESPONSE_BASENAME
    payload = {
        "request_id": REQUEST_ID,
        "client_request_id": CLIENT_REQUEST_ID,
        "narrative_response": "fixture",
    }
    response.write_text(json.dumps(payload), encoding="utf-8")

    assert adapter_module.main(["--claim-response", str(response)]) == 0
    output = capsys.readouterr().out.strip()
    assert output.startswith("ENGAIN_RESPONSE_JSON_BASE64=")
    decoded = base64.b64decode(output.split("=", 1)[1], validate=True).decode("utf-8")
    assert json.loads(decoded) == payload
    assert not response.exists()


def test_claim_response_rejects_duplicate_keys_without_provider_execution(
    adapter_module: Any,
    tmp_path: Path,
) -> None:
    response = tmp_path / FINAL_RESPONSE_BASENAME
    response.write_text('{"request_id":"a","request_id":"b"}', encoding="utf-8")
    assert adapter_module.main(["--claim-response", str(response)]) == 1
    assert not response.exists()

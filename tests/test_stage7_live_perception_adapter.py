from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import socket
import struct
import subprocess
import sys
import time
from typing import Any, Iterator
import urllib.request

import pytest


PROJECT_ROOT = Path(__file__).resolve().parents[1]
ADAPTER_PATH = PROJECT_ROOT / "hermes_session_adapter.py"
DRAGON_SCENE_PATH = "res://scenes/DragonAvatar3D.tscn"
SESSION_ID = "20260731_065008_63a62d"
REQUEST_ID = "req_11111111111111111111111111111111"
CLIENT_REQUEST_ID = "dragon3d_22222222222222222222222222222222_1"
CAPTURE_ID = "cap_33333333333333333333333333333333_1"


@pytest.fixture()
def adapter_module(monkeypatch: pytest.MonkeyPatch) -> Iterator[Any]:
    module_name = "hermes_session_adapter_stage7_red"
    spec = importlib.util.spec_from_file_location(module_name, ADAPTER_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    monkeypatch.setattr(module, "_verify_trusted_hermes_executable", lambda _path: None)
    yield module
    sys.modules.pop(module_name, None)


def _png(width: int = 2, height: int = 1) -> bytes:
    return (
        b"\x89PNG\r\n\x1a\n"
        + struct.pack(">I", 13)
        + b"IHDR"
        + struct.pack(">II", width, height)
        + bytes([8, 6, 0, 0, 0])
        + b"\x00\x00\x00\x00"
    )


def _full_payload(tmp_path: Path) -> tuple[dict[str, Any], dict[str, Any]]:
    snapshots = tmp_path / "snapshots"
    snapshots.mkdir(parents=True)
    image_name = f"perception_{CAPTURE_ID}.png"
    metadata_name = f"perception_{CAPTURE_ID}.json"
    image_path = snapshots / image_name
    metadata_path = snapshots / metadata_name
    image_bytes = _png()
    image_sha256 = hashlib.sha256(image_bytes).hexdigest()
    image_path.write_bytes(image_bytes)
    captured_at = time.time()
    viewport = {
        "availability": "available",
        "image_path": f"snapshots/{image_name}",
        "image_sha256": image_sha256,
        "media_type": "image/png",
        "width": 2,
        "height": 1,
        "reason": None,
    }
    metadata = {
        "schema": "engain.runtime_snapshot.v1",
        "capture_id": CAPTURE_ID,
        "client_request_id": CLIENT_REQUEST_ID,
        "capture_event": "message_received",
        "capture_phase": "pre_dispatch_player_view.v1",
        "captured_at": captured_at,
        "project_id": "godot_3d_avatar",
        "scene_path": "res://scenes/Main.tscn",
        "runtime": {
            "fps": 60.0,
            "current_location": "3D flight test world",
            "inventory": [],
            "player_position": "(0, 0, 0)",
        },
        "viewport": viewport,
    }
    metadata_bytes = json.dumps(metadata, separators=(",", ":")).encode("utf-8")
    metadata_path.write_bytes(metadata_bytes)
    metadata_sha256 = hashlib.sha256(metadata_bytes).hexdigest()
    payload = {
        "player_input": "Describe the current player viewport.",
        "game_state": {},
        "additional_context": {
            "client_request_id": CLIENT_REQUEST_ID,
            "companion_ref": "hermes_b",
            "perception": {
                "schema": "engain.runtime_perception.v1",
                "perception_state": "full",
                "capture_id": CAPTURE_ID,
                "capture_event": "message_received",
                "capture_phase": "pre_dispatch_player_view.v1",
                "captured_at": captured_at,
                "project_id": "godot_3d_avatar",
                "scene_path": "res://scenes/Main.tscn",
                "snapshot": {
                    "metadata_path": f"snapshots/{metadata_name}",
                    "metadata_sha256": metadata_sha256,
                    "metadata": metadata,
                },
                "viewport": viewport,
                "unavailable_reason": None,
            },
        },
        "timestamp": captured_at + 0.01,
        "request_id": REQUEST_ID,
    }
    expected = {
        "request_id": REQUEST_ID,
        "client_request_id": CLIENT_REQUEST_ID,
        "capture_id": CAPTURE_ID,
        "session_id": SESSION_ID,
        "image_path": str(image_path.resolve()),
        "image_sha256": image_sha256,
    }
    return payload, expected


def _unavailable_payload() -> dict[str, Any]:
    captured_at = time.time()
    return {
        "player_input": "Can you see the current viewport?",
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
                "captured_at": captured_at,
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
                    "reason": "capture_failed",
                },
                "unavailable_reason": "capture_failed",
            },
        },
        "timestamp": captured_at + 0.01,
        "request_id": REQUEST_ID,
    }


def _adapter(module: Any, tmp_path: Path) -> Any:
    config = module.AdapterConfig(project_dir=tmp_path)
    adapter = module.HermesSessionAdapter(config)
    adapter.client.session_id = SESSION_ID
    return adapter


def _run_claimed(adapter: Any, payload: dict[str, Any], tmp_path: Path) -> bool:
    claimed = tmp_path / ".engain_request.stage7.processing"
    claimed.write_text(json.dumps(payload), encoding="utf-8")
    return adapter._process_claimed_request(claimed)


def _preparation(expected: dict[str, Any]) -> dict[str, Any]:
    return {
        **expected,
        "contract_argv": ["hermes", "--image", expected["image_path"]],
        "executable_argv": ["hermes", "--image", expected["image_path"]],
        "project_id": "godot_3d_avatar",
        "scene_path": "res://scenes/Main.tscn",
        "dragon_scene_path": DRAGON_SCENE_PATH,
        "width": 2,
        "height": 1,
    }


def test_full_live_request_prepares_nested_dragon_before_provider_boundary(
    adapter_module: Any,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    payload, expected = _full_payload(tmp_path)
    adapter = _adapter(adapter_module, tmp_path)
    events: list[str] = []

    def prepare(value: Any, *, dragon_scene_path: str) -> dict[str, Any]:
        events.append("prepare")
        assert value == payload
        assert dragon_scene_path == DRAGON_SCENE_PATH
        return _preparation(expected)

    class OfflineDirector:
        def process_player_input(self, _text: str, _state: dict[str, Any]) -> dict[str, Any]:
            events.append("provider_boundary")
            return {}

    monkeypatch.setattr(adapter, "prepare_image_dispatch", prepare)
    adapter.director_bridge = OfflineDirector()
    assert _run_claimed(adapter, payload, tmp_path)
    assert events == ["prepare", "provider_boundary"], (
        "STAGE7_ADAPTER_RED: full live request did not prepare the exact image "
        "and nested Dragon identity before the provider boundary"
    )


def test_nested_dragon_identity_is_exact_and_not_serialized_in_mailbox(
    adapter_module: Any,
    tmp_path: Path,
) -> None:
    payload, _expected = _full_payload(tmp_path)
    assert adapter_module.DRAGON_SCENE_PATH == DRAGON_SCENE_PATH

    def contains_key(value: Any, key: str) -> bool:
        if isinstance(value, dict):
            return key in value or any(contains_key(item, key) for item in value.values())
        if isinstance(value, list):
            return any(contains_key(item, key) for item in value)
        return False

    assert not contains_key(payload, "dragon_scene_path")


def test_existing_preparation_boundary_remains_provider_free(
    adapter_module: Any,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    payload, expected = _full_payload(tmp_path)
    adapter = _adapter(adapter_module, tmp_path)
    calls: list[str] = []

    def forbidden(label: str) -> Any:
        def fail(*_args: Any, **_kwargs: Any) -> Any:
            calls.append(label)
            pytest.fail(f"provider-free preparation crossed {label}", pytrace=False)
        return fail

    monkeypatch.setattr(adapter_module.HermesCLIClient, "chat", forbidden("chat"))
    monkeypatch.setattr(adapter_module.HermesCLIClient, "_run_bounded", forbidden("run_bounded"))
    monkeypatch.setattr(adapter_module.subprocess, "Popen", forbidden("Popen"))
    monkeypatch.setattr(adapter_module.subprocess, "run", forbidden("run"))
    result = adapter.prepare_image_dispatch(payload, dragon_scene_path=DRAGON_SCENE_PATH)
    assert calls == []
    for key, value in expected.items():
        assert result[key] == value


@pytest.mark.parametrize(
    "field,bad_value",
    [
        ("request_id", "req_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
        ("client_request_id", "dragon3d_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb_2"),
        ("capture_id", "cap_cccccccccccccccccccccccccccccccc_2"),
        ("session_id", "wrong_session"),
        ("image_path", "/tmp/substitute.png"),
        ("image_sha256", "0" * 64),
    ],
)
def test_preparation_identity_mismatch_rejects_before_provider(
    adapter_module: Any,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    field: str,
    bad_value: str,
) -> None:
    payload, expected = _full_payload(tmp_path)
    adapter = _adapter(adapter_module, tmp_path)
    provider_calls: list[str] = []

    def mismatched(_value: Any, *, dragon_scene_path: str) -> dict[str, Any]:
        assert dragon_scene_path == DRAGON_SCENE_PATH
        result = _preparation(expected)
        result[field] = bad_value
        return result

    class ForbiddenDirector:
        def process_player_input(self, _text: str, _state: dict[str, Any]) -> dict[str, Any]:
            provider_calls.append("director")
            return {}

    monkeypatch.setattr(adapter, "prepare_image_dispatch", mismatched)
    monkeypatch.setattr(
        adapter_module.HermesCLIClient,
        "chat",
        lambda *_args, **_kwargs: provider_calls.append("chat"),
    )
    monkeypatch.setattr(
        adapter_module.HermesCLIClient,
        "_run_bounded",
        lambda *_args, **_kwargs: provider_calls.append("run_bounded"),
    )
    monkeypatch.setattr(
        adapter_module.subprocess,
        "Popen",
        lambda *_args, **_kwargs: provider_calls.append("Popen"),
    )
    adapter.director_bridge = ForbiddenDirector()
    assert _run_claimed(adapter, payload, tmp_path)
    assert provider_calls == [], (
        f"STAGE7_ADAPTER_RED: mismatched preparation field {field} reached provider boundary"
    )


def test_admitted_full_image_is_the_only_image_argument(
    adapter_module: Any,
    tmp_path: Path,
) -> None:
    payload, expected = _full_payload(tmp_path)
    adapter = _adapter(adapter_module, tmp_path)
    result = adapter.prepare_image_dispatch(payload, dragon_scene_path=DRAGON_SCENE_PATH)
    for argv_name in ("contract_argv", "executable_argv"):
        argv = result[argv_name]
        assert argv.count("--image") == 1
        image_index = argv.index("--image")
        assert argv[image_index + 1] == expected["image_path"]
    assert result["image_sha256"] == expected["image_sha256"]


def test_snapshot_validation_has_no_newest_image_or_fallback_search(
    adapter_module: Any,
) -> None:
    source = ADAPTER_PATH.read_text(encoding="utf-8")
    start = source.index("    def _read_snapshot_evidence_pair(")
    end = source.index("    def _read_evidence_from_root(", start)
    body = source[start:end]
    assert 'f"perception_{capture_id}.json"' in body
    assert 'f"perception_{capture_id}.png"' in body
    for forbidden in ("glob(", "rglob(", "iterdir(", "newest", "getmtime", "listdir"):
        assert forbidden not in body


def test_unavailable_live_request_skips_image_preparation_and_image_attachment(
    adapter_module: Any,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    payload = _unavailable_payload()
    adapter = _adapter(adapter_module, tmp_path)
    prepared: list[str] = []
    commands: list[list[str]] = []

    def forbidden_prepare(*_args: Any, **_kwargs: Any) -> dict[str, Any]:
        prepared.append("prepare")
        return {}

    class OfflineDirector:
        def process_player_input(self, text: str, _state: dict[str, Any]) -> dict[str, Any]:
            perception = adapter.client.pending_perception
            assert perception is not None
            commands.append(
                adapter.client.build_contract_command(
                    adapter_module.LocalObservationDirector.build_messages(text),
                    perception=perception,
                )
            )
            return {}

    monkeypatch.setattr(adapter, "prepare_image_dispatch", forbidden_prepare)
    adapter.director_bridge = OfflineDirector()
    assert _run_claimed(adapter, payload, tmp_path)
    assert prepared == []
    assert len(commands) == 1
    assert "--image" not in commands[0]


def test_offline_stage7_fixture_executes_zero_hermes_provider_network_or_http(
    adapter_module: Any,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    payload, _expected = _full_payload(tmp_path)
    adapter = _adapter(adapter_module, tmp_path)
    calls: list[str] = []

    def forbidden(label: str) -> Any:
        def fail(*_args: Any, **_kwargs: Any) -> Any:
            calls.append(label)
            pytest.fail(f"offline Stage 7 fixture crossed {label}", pytrace=False)
        return fail

    monkeypatch.setattr(adapter_module.HermesCLIClient, "chat", forbidden("chat"))
    monkeypatch.setattr(adapter_module.HermesCLIClient, "_run_bounded", forbidden("run_bounded"))
    monkeypatch.setattr(adapter_module.subprocess, "Popen", forbidden("Popen"))
    monkeypatch.setattr(adapter_module.subprocess, "run", forbidden("run"))
    monkeypatch.setattr(socket, "socket", forbidden("socket"))
    monkeypatch.setattr(urllib.request, "urlopen", forbidden("urlopen"))
    result = adapter.prepare_image_dispatch(payload, dragon_scene_path=DRAGON_SCENE_PATH)
    assert result["request_id"] == REQUEST_ID
    assert calls == []

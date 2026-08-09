from __future__ import annotations

import base64
import hashlib
import importlib
import importlib.util
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import time
from types import ModuleType
from typing import Any
import zlib

import pytest


PROJECT_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT_ROOT))

PROJECT_ID = "godot_3d_avatar"
SCENE_PATH = "res://scenes/Main.tscn"
DRAGON_SCENE_PATH = "res://scenes/DragonAvatar3D.tscn"
DRAGON_NODE_PATH = "World/DragonAvatar3D"
HERMES_PROFILE = "default"
PERSISTED_SESSION_ID = "20260731_065008_63a62d"
COMPANION_REF = "hermes_b"
PROVIDER = "openai-codex"
MODEL = "gpt-5.6-sol"
REQUEST_SCHEMA = "engain.hermes_mailbox_request.v1"
RESPONSE_SCHEMA = "engain.hermes_mailbox_response.v1"
PERCEPTION_SCHEMA = "engain.runtime_perception.v1"
SNAPSHOT_SCHEMA = "engain.runtime_snapshot.v1"
PERCEPTION_RESULT_SCHEMA = "engain.runtime_perception_result.v1"
CAPTURE_EVENT = "message_received"
CAPTURE_PHASE = "pre_dispatch_player_view.v1"
CAPTURED_AT = 1_800_000_000.0
REQUEST_ID = "req_0123456789abcdef0123456789abcdef"
CLIENT_REQUEST_ID = "dragon3d_0123456789abcdef0123456789abcdef_1"
CAPTURE_ID = "cap_0123456789abcdef0123456789abcdef_1"
REQUEST_ID_PATTERN = re.compile(r"^req_[0-9a-f]{32}$")
CLIENT_REQUEST_ID_PATTERN = re.compile(r"^dragon3d_[0-9a-f]{32}_[1-9][0-9]*$")
CAPTURE_ID_PATTERN = re.compile(r"^cap_[0-9a-f]{32}_[1-9][0-9]*$")
FROZEN_CONTRACT_SHA256 = "fcbc75f6a822b2cfdc5e068bbb905335253e8ce34ddb0b8b831d126d221ce0f7"
EXPECTED_RESPONSE_KEYS = {
    "request_id",
    "client_request_id",
    "narrative_response",
    "action_type",
    "state_changes",
    "director_analysis",
    "reasoning",
    "entropy_impact",
    "timestamp",
    "provider_session_ref",
    "perception_result",
}


def _adapter_module() -> ModuleType:
    """Load the wished-for production boundary inside each test.

    Stage 3 deliberately has no production adapter. Using pytest.fail here gives
    a real, expected RED failure rather than a collection error. Once Stage 4
    creates the module, the same tests continue into their behavioral assertions.
    """
    if importlib.util.find_spec("hermes_session_adapter") is None:
        pytest.fail(
            "STAGE3_RED: hermes_session_adapter.py is absent from the untouched 3D project",
            pytrace=False,
        )
    return importlib.import_module("hermes_session_adapter")


def _png_bytes(width: int = 1, height: int = 1) -> bytes:
    signature = b"\x89PNG\r\n\x1a\n"
    ihdr_data = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)

    def chunk(kind: bytes, data: bytes) -> bytes:
        return (
            struct.pack(">I", len(data))
            + kind
            + data
            + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
        )

    raw_scanline = b"\x00" + (b"\x00\x00\x00\x00" * width)
    return signature + chunk(b"IHDR", ihdr_data) + chunk(
        b"IDAT", zlib.compress(raw_scanline * height)
    ) + chunk(b"IEND", b"")


def _valid_session_state(processed: list[str] | None = None) -> dict[str, object]:
    return {
        "profile": HERMES_PROFILE,
        "companion_ref": COMPANION_REF,
        "provider": PROVIDER,
        "model": MODEL,
        "session_id": PERSISTED_SESSION_ID,
        "processed_request_ids": [] if processed is None else processed,
    }


def _valid_provider_response(narrative: str = "3D provider-bound narrative") -> str:
    return json.dumps(
        {
            "analysis": "provider analysis",
            "recommended_action": "OBSERVATION",
            "narrative_response": narrative,
            "state_modifications": {},
            "reasoning": "provider reasoning",
            "entropy_impact": 0.0,
        }
    )


def _build_request(project_dir: Path) -> dict[str, object]:
    snapshots = project_dir / "snapshots"
    snapshots.mkdir(parents=True)
    image_path = f"snapshots/perception_{CAPTURE_ID}.png"
    metadata_path = f"snapshots/perception_{CAPTURE_ID}.json"
    image_bytes = _png_bytes()
    (project_dir / image_path).write_bytes(image_bytes)
    image_sha256 = hashlib.sha256(image_bytes).hexdigest()
    viewport = {
        "availability": "available",
        "image_path": image_path,
        "image_sha256": image_sha256,
        "media_type": "image/png",
        "width": 1,
        "height": 1,
        "reason": None,
    }
    metadata = {
        "schema": SNAPSHOT_SCHEMA,
        "capture_id": CAPTURE_ID,
        "client_request_id": CLIENT_REQUEST_ID,
        "capture_event": CAPTURE_EVENT,
        "capture_phase": CAPTURE_PHASE,
        "captured_at": CAPTURED_AT,
        "project_id": PROJECT_ID,
        "scene_path": SCENE_PATH,
        "runtime": {
            "fps": 60.0,
            "current_location": "3D flight test world",
            "inventory": [],
            "player_position": "(0, 1.5, 0)",
        },
        "viewport": viewport,
    }
    metadata_bytes = (json.dumps(metadata, separators=(",", ":")) + "\n").encode()
    (project_dir / metadata_path).write_bytes(metadata_bytes)
    perception = {
        "schema": PERCEPTION_SCHEMA,
        "perception_state": "full",
        "capture_id": CAPTURE_ID,
        "capture_event": CAPTURE_EVENT,
        "capture_phase": CAPTURE_PHASE,
        "captured_at": CAPTURED_AT,
        "project_id": PROJECT_ID,
        "scene_path": SCENE_PATH,
        "snapshot": {
            "metadata_path": metadata_path,
            "metadata_sha256": hashlib.sha256(metadata_bytes).hexdigest(),
            "metadata": metadata,
        },
        "viewport": viewport,
        "unavailable_reason": None,
    }
    return {
        "player_input": "What do you see in the 3D world?",
        "game_state": {},
        "additional_context": {
            "client_request_id": CLIENT_REQUEST_ID,
            "companion_ref": COMPANION_REF,
            "perception": perception,
        },
        "timestamp": CAPTURED_AT + 0.5,
        "request_id": REQUEST_ID,
    }


def _perception(payload: dict[str, object]) -> dict[str, Any]:
    context = payload["additional_context"]
    assert isinstance(context, dict)
    perception = context["perception"]
    assert isinstance(perception, dict)
    return perception


def _snapshot(payload: dict[str, object]) -> dict[str, Any]:
    snapshot = _perception(payload)["snapshot"]
    assert isinstance(snapshot, dict)
    return snapshot


def _metadata(payload: dict[str, object]) -> dict[str, Any]:
    metadata = _snapshot(payload)["metadata"]
    assert isinstance(metadata, dict)
    return metadata


def _rewrite_metadata(project_dir: Path, payload: dict[str, object]) -> None:
    snapshot = _snapshot(payload)
    metadata = _metadata(payload)
    metadata_bytes = (json.dumps(metadata, separators=(",", ":")) + "\n").encode()
    (project_dir / snapshot["metadata_path"]).write_bytes(metadata_bytes)
    snapshot["metadata_sha256"] = hashlib.sha256(metadata_bytes).hexdigest()


def _retime_request(project_dir: Path, payload: dict[str, object]) -> None:
    current = time.time()
    payload["timestamp"] = current + 0.25
    _perception(payload)["captured_at"] = current
    _metadata(payload)["captured_at"] = current
    _rewrite_metadata(project_dir, payload)


def _adapter(tmp_path: Path) -> Any:
    module = _adapter_module()
    return module.HermesSessionAdapter(
        module.AdapterConfig(project_dir=tmp_path), director_bridge=object()
    )


def _assert_rejected(
    adapter: Any,
    payload: dict[str, object],
    code: str,
) -> None:
    module = _adapter_module()
    with pytest.raises(module.PerceptionValidationError) as caught:
        adapter._validate_request(payload, validation_time=CAPTURED_AT + 1.0)
    assert caught.value.code == code


# Fixture/contract self-checks. These pass during RED and prove the RED is not
# caused by malformed Stage 3 test data.


def test_frozen_contract_identity_and_schema_vectors_are_exact() -> None:
    assert PROJECT_ID == "godot_3d_avatar"
    assert SCENE_PATH == "res://scenes/Main.tscn"
    assert DRAGON_SCENE_PATH == "res://scenes/DragonAvatar3D.tscn"
    assert HERMES_PROFILE == "default"
    assert PERSISTED_SESSION_ID == "20260731_065008_63a62d"
    assert COMPANION_REF == "hermes_b"
    assert REQUEST_SCHEMA == "engain.hermes_mailbox_request.v1"
    assert RESPONSE_SCHEMA == "engain.hermes_mailbox_response.v1"
    assert PERCEPTION_SCHEMA == "engain.runtime_perception.v1"
    assert SNAPSHOT_SCHEMA == "engain.runtime_snapshot.v1"
    assert PERCEPTION_RESULT_SCHEMA == "engain.runtime_perception_result.v1"
    assert FROZEN_CONTRACT_SHA256 == (
        "fcbc75f6a822b2cfdc5e068bbb905335253e8ce34ddb0b8b831d126d221ce0f7"
    )


def test_frozen_identifier_vectors_match_exact_rules() -> None:
    assert REQUEST_ID_PATTERN.fullmatch(REQUEST_ID)
    assert CLIENT_REQUEST_ID_PATTERN.fullmatch(CLIENT_REQUEST_ID)
    assert CAPTURE_ID_PATTERN.fullmatch(CAPTURE_ID)
    assert len({REQUEST_ID, CLIENT_REQUEST_ID, CAPTURE_ID}) == 3


def test_png_fixture_has_sha256_png_ihdr_and_dimension_metadata(tmp_path: Path) -> None:
    payload = _build_request(tmp_path)
    viewport = _perception(payload)["viewport"]
    assert isinstance(viewport, dict)
    raw = (tmp_path / viewport["image_path"]).read_bytes()
    assert raw[:8] == b"\x89PNG\r\n\x1a\n"
    assert raw[12:16] == b"IHDR"
    assert struct.unpack(">II", raw[16:24]) == (viewport["width"], viewport["height"])
    assert hashlib.sha256(raw).hexdigest() == viewport["image_sha256"]
    assert re.fullmatch(r"[0-9a-f]{64}", viewport["image_sha256"])


def test_request_fixture_uses_exact_five_key_mailbox_shape(tmp_path: Path) -> None:
    payload = _build_request(tmp_path)
    assert set(payload) == {
        "player_input", "game_state", "additional_context", "timestamp", "request_id"
    }
    assert set(payload["additional_context"]) == {  # type: ignore[arg-type]
        "client_request_id", "companion_ref", "perception"
    }
    assert "schema" not in payload


def test_current_scene_bytes_freeze_actual_root_and_dragon_node_path() -> None:
    project = (PROJECT_ROOT / "project.godot").read_text()
    main_scene = (PROJECT_ROOT / "scenes/Main.tscn").read_text()
    dragon_scene = (PROJECT_ROOT / "scenes/DragonAvatar3D.tscn").read_text()
    assert 'run/main_scene="res://scenes/Main.tscn"' in project
    assert '[node name="DragonAvatar3D" parent="World" instance=ExtResource("1_dragon")]' in main_scene
    assert DRAGON_NODE_PATH == "World/DragonAvatar3D"
    assert 'path="res://scenes/DragonAvatar3D.tscn"' in main_scene
    assert '[node name="DragonAvatar3D" type="Node3D"]' in dragon_scene


# Adapter contract tests. On the untouched baseline these must fail RED because
# hermes_session_adapter.py does not yet exist.


def test_adapter_exports_exact_frozen_identity_constants() -> None:
    module = _adapter_module()
    assert module.PROJECT_ID == PROJECT_ID
    assert module.SCENE_PATH == SCENE_PATH
    assert module.DRAGON_SCENE_PATH == DRAGON_SCENE_PATH
    assert module.HERMES_PROFILE == HERMES_PROFILE
    assert module.PERSISTED_HERMES_B_SESSION_ID == PERSISTED_SESSION_ID
    assert module.COMPANION_REF == COMPANION_REF
    assert module.FROZEN_PROVIDER == PROVIDER
    assert module.FROZEN_MODEL == MODEL
    assert module.REQUEST_SCHEMA == REQUEST_SCHEMA
    assert module.RESPONSE_SCHEMA == RESPONSE_SCHEMA
    assert module.PERCEPTION_SCHEMA == PERCEPTION_SCHEMA
    assert module.SNAPSHOT_SCHEMA == SNAPSHOT_SCHEMA
    assert module.PERCEPTION_RESULT_SCHEMA == PERCEPTION_RESULT_SCHEMA


def test_adapter_config_owns_project_local_mailboxes_state_and_capture_root(
    tmp_path: Path,
) -> None:
    module = _adapter_module()
    config = module.AdapterConfig(project_dir=tmp_path)
    assert config.project_dir == tmp_path.resolve()
    assert config.request_file == tmp_path.resolve() / "engain_request.json"
    assert config.response_file == tmp_path.resolve() / "engain_response.json"
    assert config.state_file == tmp_path.resolve() / ".godot/engain_hermes_session.json"
    assert config.snapshot_root == tmp_path.resolve() / "snapshots"
    assert config.timeout_seconds == 180.0
    assert config.profile == HERMES_PROFILE


def test_strict_json_rejects_duplicate_nonfinite_and_overflow_numbers() -> None:
    module = _adapter_module()
    for document in ('{"x":1,"x":2}', '{"x":NaN}', '{"x":1e999}'):
        with pytest.raises((ValueError, json.JSONDecodeError)):
            module._strict_json_loads(document)


def test_valid_correlated_3d_full_request_is_accepted_with_image(tmp_path: Path) -> None:
    adapter = _adapter(tmp_path)
    payload = _build_request(tmp_path)
    validated = adapter._validate_request(payload, validation_time=CAPTURED_AT + 1.0)
    assert validated.request_id == REQUEST_ID
    assert validated.client_request_id == CLIENT_REQUEST_ID
    assert validated.companion_ref == COMPANION_REF
    assert validated.perception.capture_id == CAPTURE_ID
    assert validated.perception.requested_state == "full"
    assert validated.perception.effective_state == "full"
    assert validated.perception.viewport_image_attached is True
    assert validated.perception.metadata["project_id"] == PROJECT_ID
    assert validated.perception.metadata["scene_path"] == SCENE_PATH


@pytest.mark.parametrize(
    ("target", "value", "code"),
    [
        ("project_id", "engain_avatar", "PROJECT_ID_MISMATCH"),
        ("scene_path", DRAGON_SCENE_PATH, "SCENE_IDENTITY_MISMATCH"),
        ("capture_event", "ai_dragon_spoke", "CAPTURE_EVENT_INVALID"),
        ("capture_phase", "post_dispatch.v1", "CAPTURE_PHASE_INVALID"),
    ],
)
def test_wrong_host_event_or_phase_is_rejected(
    tmp_path: Path, target: str, value: str, code: str
) -> None:
    adapter = _adapter(tmp_path)
    payload = _build_request(tmp_path)
    _perception(payload)[target] = value
    _assert_rejected(adapter, payload, code)


def test_wrong_client_request_id_is_rejected(tmp_path: Path) -> None:
    adapter = _adapter(tmp_path)
    payload = _build_request(tmp_path)
    _metadata(payload)["client_request_id"] = (
        "dragon3d_ffffffffffffffffffffffffffffffff_2"
    )
    _rewrite_metadata(tmp_path, payload)
    _assert_rejected(adapter, payload, "CLIENT_REQUEST_ID_MISMATCH")


def test_wrong_capture_id_is_rejected(tmp_path: Path) -> None:
    adapter = _adapter(tmp_path)
    payload = _build_request(tmp_path)
    _metadata(payload)["capture_id"] = "cap_ffffffffffffffffffffffffffffffff_2"
    _rewrite_metadata(tmp_path, payload)
    _assert_rejected(adapter, payload, "CAPTURE_ID_MISMATCH")


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("request_id", "req_short"),
        ("client_request_id", "dragon_legacy_1"),
        ("capture_id", "cap_short"),
    ],
)
def test_nonconforming_identifier_is_schema_invalid(
    tmp_path: Path, field: str, value: str
) -> None:
    adapter = _adapter(tmp_path)
    payload = _build_request(tmp_path)
    if field == "request_id":
        payload[field] = value
    elif field == "client_request_id":
        payload["additional_context"][field] = value  # type: ignore[index]
    else:
        _perception(payload)[field] = value
    _assert_rejected(adapter, payload, "SCHEMA_INVALID")


def test_stale_capture_is_rejected_without_newest_substitution(tmp_path: Path) -> None:
    adapter = _adapter(tmp_path)
    payload = _build_request(tmp_path)
    payload["timestamp"] = CAPTURED_AT + 6.0
    newer = tmp_path / "snapshots/perception_cap_ffffffffffffffffffffffffffffffff_9.png"
    newer.write_bytes(_png_bytes())
    _assert_rejected(adapter, payload, "CAPTURE_STALE")


def test_metadata_hash_mismatch_is_rejected(tmp_path: Path) -> None:
    adapter = _adapter(tmp_path)
    payload = _build_request(tmp_path)
    metadata_path = tmp_path / _snapshot(payload)["metadata_path"]
    metadata_path.write_bytes(metadata_path.read_bytes() + b" ")
    _assert_rejected(adapter, payload, "METADATA_HASH_MISMATCH")


def test_image_hash_mismatch_is_rejected(tmp_path: Path) -> None:
    adapter = _adapter(tmp_path)
    payload = _build_request(tmp_path)
    image_path = tmp_path / _perception(payload)["viewport"]["image_path"]
    image_path.write_bytes(image_path.read_bytes() + b"tampered")
    _assert_rejected(adapter, payload, "IMAGE_HASH_MISMATCH")


def test_out_of_root_image_path_is_rejected(tmp_path: Path) -> None:
    adapter = _adapter(tmp_path)
    payload = _build_request(tmp_path)
    outside = tmp_path.parent / f"outside_{CAPTURE_ID}.png"
    outside.write_bytes(_png_bytes())
    viewport = _perception(payload)["viewport"]
    viewport["image_path"] = str(outside)
    _metadata(payload)["viewport"] = dict(viewport)
    _rewrite_metadata(tmp_path, payload)
    _assert_rejected(adapter, payload, "IMAGE_PATH_REJECTED")


def test_symlinked_capture_root_is_rejected(tmp_path: Path) -> None:
    adapter = _adapter(tmp_path)
    payload = _build_request(tmp_path)
    root = tmp_path / "snapshots"
    actual = tmp_path / "actual_snapshots"
    root.rename(actual)
    root.symlink_to(actual, target_is_directory=True)
    _assert_rejected(adapter, payload, "METADATA_PATH_REJECTED")


def test_unsupported_image_type_is_rejected_even_with_matching_hash(tmp_path: Path) -> None:
    adapter = _adapter(tmp_path)
    payload = _build_request(tmp_path)
    bad_bytes = b"not a png"
    viewport = _perception(payload)["viewport"]
    image_path = tmp_path / viewport["image_path"]
    image_path.write_bytes(bad_bytes)
    bad_hash = hashlib.sha256(bad_bytes).hexdigest()
    viewport["image_sha256"] = bad_hash
    _metadata(payload)["viewport"]["image_sha256"] = bad_hash
    _rewrite_metadata(tmp_path, payload)
    _assert_rejected(adapter, payload, "UNSUPPORTED_IMAGE_TYPE")


def test_png_ihdr_dimension_mismatch_is_rejected(tmp_path: Path) -> None:
    adapter = _adapter(tmp_path)
    payload = _build_request(tmp_path)
    _perception(payload)["viewport"]["width"] = 2
    _metadata(payload)["viewport"]["width"] = 2
    _rewrite_metadata(tmp_path, payload)
    _assert_rejected(adapter, payload, "IMAGE_DIMENSION_MISMATCH")


@pytest.mark.parametrize("field", ["width", "height"])
def test_boolean_or_out_of_range_dimensions_are_schema_invalid(
    tmp_path: Path, field: str
) -> None:
    adapter = _adapter(tmp_path)
    payload = _build_request(tmp_path)
    _perception(payload)["viewport"][field] = True
    _metadata(payload)["viewport"][field] = True
    _rewrite_metadata(tmp_path, payload)
    _assert_rejected(adapter, payload, "SCHEMA_INVALID")


def test_missing_image_downgrades_to_structured_only(tmp_path: Path) -> None:
    adapter = _adapter(tmp_path)
    payload = _build_request(tmp_path)
    image_path = tmp_path / _perception(payload)["viewport"]["image_path"]
    image_path.unlink()
    validated = adapter._validate_request(payload, validation_time=CAPTURED_AT + 1.0)
    assert validated.perception.effective_state == "structured_only"
    assert validated.perception.viewport_image_attached is False
    assert validated.perception.failure_code == "IMAGE_MISSING"


def test_missing_metadata_downgrades_to_unavailable(tmp_path: Path) -> None:
    adapter = _adapter(tmp_path)
    payload = _build_request(tmp_path)
    metadata_path = tmp_path / _snapshot(payload)["metadata_path"]
    metadata_path.unlink()
    validated = adapter._validate_request(payload, validation_time=CAPTURED_AT + 1.0)
    assert validated.perception.effective_state == "unavailable"
    assert validated.perception.viewport_image_attached is False
    assert validated.perception.failure_code == "METADATA_MISSING"


def test_unavailable_prompt_denies_structured_and_pixel_vision(tmp_path: Path) -> None:
    module = _adapter_module()
    payload = _build_request(tmp_path)
    perception = _perception(payload)
    perception.update(
        {
            "perception_state": "unavailable",
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
        }
    )
    adapter = _adapter(tmp_path)
    validated = adapter._validate_request(payload, validation_time=CAPTURED_AT + 1000.0)
    prompt = adapter.client._format_messages(
        [{"role": "user", "content": "What do you see?"}],
        perception=validated.perception,
    )
    assert "No current structured runtime snapshot is available" in prompt
    assert "No current viewport image is attached" in prompt
    assert "Do not claim to see current" in prompt
    assert "--image" not in prompt
    assert module.PERCEPTION_RESULT_SCHEMA == PERCEPTION_RESULT_SCHEMA


def test_hermes_command_explicitly_selects_profile_session_provider_model_and_image(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    module = _adapter_module()
    adapter = _adapter(tmp_path)
    validated = adapter._validate_request(
        _build_request(tmp_path), validation_time=CAPTURED_AT + 1.0
    )
    client = adapter.client
    client.session_id = PERSISTED_SESSION_ID
    captured_command: list[str] = []

    def fake_run(command: list[str]) -> subprocess.CompletedProcess[str]:
        captured_command.extend(command)
        return subprocess.CompletedProcess(
            command,
            0,
            f"Warning: Unknown toolsets: {module.HERMES_EMPTY_TOOLSET}\n"
            + _valid_provider_response()
            + "\n",
            f"session_id: {PERSISTED_SESSION_ID}\n",
        )

    monkeypatch.setattr(client, "_run_bounded", fake_run)
    client.chat(
        [{"role": "user", "content": "Describe the 3D viewport"}],
        perception=validated.perception,
    )
    assert captured_command.count("--profile") == 1
    assert captured_command[captured_command.index("--profile") + 1] == HERMES_PROFILE
    assert captured_command.count("--resume") == 1
    assert captured_command[captured_command.index("--resume") + 1] == PERSISTED_SESSION_ID
    assert captured_command[captured_command.index("--provider") + 1] == PROVIDER
    assert captured_command[captured_command.index("-m") + 1] == MODEL
    assert captured_command.count("--image") == 1
    assert captured_command[captured_command.index("--image") + 1] == str(
        (tmp_path / "snapshots" / f"perception_{CAPTURE_ID}.png").resolve()
    )


def test_session_substitution_is_rejected_without_replacing_identity(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    module = _adapter_module()
    client = module.HermesCLIClient(
        profile=HERMES_PROFILE,
        provider=PROVIDER,
        model=MODEL,
        timeout_seconds=180.0,
        session_id=PERSISTED_SESSION_ID,
    )
    monkeypatch.setattr(
        client,
        "_run_bounded",
        lambda command: subprocess.CompletedProcess(
            command,
            0,
            f"Warning: Unknown toolsets: {module.HERMES_EMPTY_TOOLSET}\n{{}}\n",
            "session_id: substituted_session\n",
        ),
    )
    with pytest.raises(module.HermesAdapterError, match="different session"):
        client.chat([{"role": "user", "content": "continue"}])
    assert client.session_id == PERSISTED_SESSION_ID


def test_prepare_requires_exact_project_local_shared_identity_state(tmp_path: Path) -> None:
    module = _adapter_module()
    state_path = tmp_path / ".godot/engain_hermes_session.json"
    state_path.parent.mkdir(parents=True)
    wrong = _valid_session_state()
    wrong["profile"] = "other"
    state_path.write_text(json.dumps(wrong))
    adapter = _adapter(tmp_path)
    with pytest.raises(module.HermesAdapterError, match="identity is missing or mismatched"):
        adapter.prepare()


def test_response_mailbox_backpressure_never_clobbers_unread_response(
    tmp_path: Path,
) -> None:
    module = _adapter_module()
    adapter = _adapter(tmp_path)
    adapter.config.response_file.write_text("first-response")
    with pytest.raises(FileExistsError):
        adapter._write_response({"request_id": "second"})
    assert adapter.config.response_file.read_text() == "first-response"
    assert module.RESPONSE_SCHEMA == RESPONSE_SCHEMA


class _RecordingDirector:
    def __init__(self, adapter: Any, module: ModuleType) -> None:
        self.adapter = adapter
        self.calls = 0
        self.seen_perception = None

        def provider_call(command: list[str]) -> subprocess.CompletedProcess[str]:
            return subprocess.CompletedProcess(
                command,
                0,
                f"Warning: Unknown toolsets: {module.HERMES_EMPTY_TOOLSET}\n"
                + _valid_provider_response()
                + "\n",
                f"session_id: {PERSISTED_SESSION_ID}\n",
            )

        self.adapter.client._run_bounded = provider_call

    def process_player_input(self, player_input: str, game_state: dict[str, object]) -> dict[str, str]:
        self.calls += 1
        self.seen_perception = self.adapter.client.pending_perception
        self.adapter.client.chat(
            [{"role": "user", "content": player_input}],
            perception=self.seen_perception,
        )
        return {"narrative_response": "local fallback must not be published"}


def test_process_once_emits_contract_exact_read_only_correlated_response(
    tmp_path: Path,
) -> None:
    module = _adapter_module()
    config = module.AdapterConfig(project_dir=tmp_path)
    adapter = module.HermesSessionAdapter(config, director_bridge=object())
    director = _RecordingDirector(adapter, module)
    adapter.director_bridge = director
    state_path = tmp_path / ".godot/engain_hermes_session.json"
    state_path.parent.mkdir(parents=True)
    state_path.write_text(json.dumps(_valid_session_state()))
    adapter.prepare()
    payload = _build_request(tmp_path)
    _retime_request(tmp_path, payload)
    config.request_file.write_text(json.dumps(payload))

    assert adapter.process_once() is True
    response = json.loads(config.response_file.read_text())
    assert director.calls == 1
    assert set(response) == EXPECTED_RESPONSE_KEYS
    assert response["request_id"] == REQUEST_ID
    assert response["client_request_id"] == CLIENT_REQUEST_ID
    assert response["narrative_response"] == "3D provider-bound narrative"
    assert response["action_type"] == "OBSERVATION"
    assert response["state_changes"] == {}
    assert response["entropy_impact"] == 0.0
    assert response["provider_session_ref"] == {
        "companion_ref": COMPANION_REF,
        "provider": PROVIDER,
        "model": MODEL,
        "session_id": PERSISTED_SESSION_ID,
    }
    assert response["perception_result"]["schema"] == PERCEPTION_RESULT_SCHEMA
    assert response["perception_result"]["effective_state"] == "full"
    assert response["perception_result"]["capture_id"] == CAPTURE_ID
    assert response["perception_result"]["viewport_image_attached"] is True
    assert not config.request_file.exists()


def test_timeout_defaults_and_failure_response_are_bounded_observation_only(
    tmp_path: Path,
) -> None:
    module = _adapter_module()
    assert module.MAX_HERMES_TIMEOUT_SECONDS == 180.0
    assert module.parse_args([]).timeout == 180.0
    adapter = _adapter(tmp_path)
    validated = adapter._validate_request(
        _build_request(tmp_path), validation_time=CAPTURED_AT + 1.0
    )
    response = adapter._error_response(
        "Hermes timed out. The dragon is still here; please try again.",
        REQUEST_ID,
        CLIENT_REQUEST_ID,
        perception=validated.perception,
        failure_code="PROVIDER_TIMEOUT",
    )
    assert response["action_type"] == "OBSERVATION"
    assert response["state_changes"] == {}
    assert response["entropy_impact"] == 0.0
    assert response["perception_result"]["effective_state"] == "rejected"
    assert response["perception_result"]["failure_code"] == "PROVIDER_TIMEOUT"
    assert response["perception_result"]["viewport_image_attached"] is False


def test_hard_correlation_rejection_skips_provider_and_reports_stable_code(
    tmp_path: Path,
) -> None:
    module = _adapter_module()
    config = module.AdapterConfig(project_dir=tmp_path)
    adapter = module.HermesSessionAdapter(config, director_bridge=object())
    director = _RecordingDirector(adapter, module)
    adapter.director_bridge = director
    payload = _build_request(tmp_path)
    _metadata(payload)["client_request_id"] = (
        "dragon3d_ffffffffffffffffffffffffffffffff_2"
    )
    _rewrite_metadata(tmp_path, payload)
    _retime_request(tmp_path, payload)
    config.request_file.write_text(json.dumps(payload))

    assert adapter.process_once() is True
    response = json.loads(config.response_file.read_text())
    assert director.calls == 0
    assert response["action_type"] == "OBSERVATION"
    assert response["state_changes"] == {}
    assert response["entropy_impact"] == 0.0
    assert response["perception_result"]["effective_state"] == "rejected"
    assert response["perception_result"]["failure_code"] == "CLIENT_REQUEST_ID_MISMATCH"
    assert response["perception_result"]["viewport_image_attached"] is False

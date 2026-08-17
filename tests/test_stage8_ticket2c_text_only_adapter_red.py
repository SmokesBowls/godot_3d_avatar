from __future__ import annotations

import copy
import importlib
import json
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest


PROJECT_ROOT = Path(__file__).resolve().parents[1]
AUDIT_ROOT = Path("/mnt/data-drive/engain-avatar-audit")
REQUEST_ID = "req_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
CLIENT_REQUEST_ID = "dragon3d_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb_1"
COMPANION_REF = "hermes_b"
MANDATORY_INPUT = (
    "Without using any current image, describe what you remember about the previous "
    "Dragon and the room/environment you saw before this latest scene."
)
TEXT_ONLY_REQUEST_BYTES = (
    b'{"additional_context":{"client_request_id":"dragon3d_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb_1",'
    b'"companion_ref":"hermes_b","routing_mode":"text_only"},"game_state":{},'
    b'"player_input":"Without using any current image, describe what you remember about '
    b'the previous Dragon and the room/environment you saw before this latest scene.",'
    b'"request_id":"req_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","timestamp":0.0}\n'
)
TEXT_ONLY_REQUEST_SHA256 = "5a5f856dcc157f885343c8d08bcfd9ebbf826a404bbab5fcf91c2a87fa69c4db"
FULL_REQUEST_PATH = (
    AUDIT_ROOT
    / "ENGAV3D-0021-STAGE7-LIVE-CURRENT-PERCEPTION"
    / "LIVE"
    / "request.json"
)
UNAVAILABLE_REQUEST_PATH = (
    AUDIT_ROOT / "ENGAV3D-0002-RUNTIME-PREFLIGHT" / "mailbox_request.raw.json"
)
FULL_REQUEST_SHA256 = "5701b7d0d1e11c1e9307ccb54ad85752166ec7a6e51bb3017180c7c26da511b7"
UNAVAILABLE_REQUEST_SHA256 = "b739f1658018611791c770eb869e8d116dbc112c2965d9219853f38d1753dd34"


def _adapter_module() -> ModuleType:
    return importlib.import_module("hermes_session_adapter")


def _adapter(tmp_path: Path) -> Any:
    module = _adapter_module()
    return module.HermesSessionAdapter(
        module.AdapterConfig(project_dir=tmp_path), director_bridge=object()
    )


def _text_only_request() -> dict[str, Any]:
    return json.loads(TEXT_ONLY_REQUEST_BYTES)


def _current_perception_stub() -> dict[str, Any]:
    return {
        "schema": "engain.runtime_perception.v1",
        "perception_state": "unavailable",
        "capture_id": "cap_cccccccccccccccccccccccccccccccc_1",
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
            "reason": "capture_failed",
        },
        "unavailable_reason": "capture_failed",
    }


def test_ticket2c_exact_text_only_request_fixture_is_self_consistent() -> None:
    import hashlib

    payload = _text_only_request()
    assert hashlib.sha256(TEXT_ONLY_REQUEST_BYTES).hexdigest() == TEXT_ONLY_REQUEST_SHA256
    assert payload["player_input"] == MANDATORY_INPUT
    assert set(payload) == {
        "request_id",
        "player_input",
        "game_state",
        "timestamp",
        "additional_context",
    }
    assert payload["additional_context"] == {
        "client_request_id": CLIENT_REQUEST_ID,
        "companion_ref": COMPANION_REF,
        "routing_mode": "text_only",
    }
    assert "perception" not in payload["additional_context"]


def test_ticket2c_stage7_request_fixture_bytes_and_admission_are_preserved() -> None:
    import hashlib

    module = _adapter_module()
    adapter = module.HermesSessionAdapter(
        module.AdapterConfig(project_dir=PROJECT_ROOT), director_bridge=object()
    )
    full_bytes = FULL_REQUEST_PATH.read_bytes()
    unavailable_bytes = UNAVAILABLE_REQUEST_PATH.read_bytes()
    assert hashlib.sha256(full_bytes).hexdigest() == FULL_REQUEST_SHA256
    assert hashlib.sha256(unavailable_bytes).hexdigest() == UNAVAILABLE_REQUEST_SHA256

    full = json.loads(full_bytes)
    unavailable = json.loads(unavailable_bytes)
    full_validated = adapter._validate_request(
        full,
        validation_time=float(full["additional_context"]["perception"]["captured_at"]) + 1.0,
    )
    unavailable_validated = adapter._validate_request(
        unavailable,
        validation_time=float(
            unavailable["additional_context"]["perception"]["captured_at"]
        )
        + 1.0,
    )

    # The sealed request bytes are admitted unchanged. Its copied snapshot
    # evidence is not re-homed into the repository by this offline RED gate, so
    # current production may conservatively downgrade the effective state.
    assert full_validated.perception.requested_state == "full"
    assert unavailable_validated.perception.requested_state == "unavailable"
    assert unavailable_validated.perception.effective_state == "unavailable"


def test_ticket2c_adapter_admits_exact_text_only_request(tmp_path: Path) -> None:
    adapter = _adapter(tmp_path)

    validated = adapter._validate_request(_text_only_request(), validation_time=1.0)

    assert validated.request_id == REQUEST_ID
    assert validated.client_request_id == CLIENT_REQUEST_ID
    assert validated.companion_ref == COMPANION_REF
    assert validated.player_input == MANDATORY_INPUT
    assert getattr(validated, "routing_mode", None) == "text_only"
    assert getattr(validated, "perception", None) is None


def test_ticket2c_text_only_dispatch_has_no_capture_preparation_or_image_argument(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    module = _adapter_module()
    adapter = _adapter(tmp_path)
    preparation_calls = 0

    def forbidden_prepare(*_args: Any, **_kwargs: Any) -> Any:
        nonlocal preparation_calls
        preparation_calls += 1
        pytest.fail("text_only attempted prepare_image_dispatch")

    monkeypatch.setattr(adapter, "prepare_image_dispatch", forbidden_prepare)

    def forbidden_provider(*_args: Any, **_kwargs: Any) -> Any:
        pytest.fail("Ticket 2C must not invoke Hermes")

    monkeypatch.setattr(adapter.client, "_run_bounded", forbidden_provider)

    validated = adapter._validate_request(_text_only_request(), validation_time=1.0)
    assert getattr(validated, "routing_mode", None) == "text_only"
    assert getattr(validated, "perception", None) is None

    adapter.client.session_id = module.PERSISTED_HERMES_B_SESSION_ID
    messages = module.LocalObservationDirector.build_messages(validated.player_input)
    argv = adapter.client.build_contract_command(messages, perception=None)

    assert preparation_calls == 0
    assert "--image" not in argv
    assert not any("perception_" in argument for argument in argv)


@pytest.mark.parametrize(
    "mutate",
    [
        lambda payload: payload["additional_context"].update(
            {"perception": _current_perception_stub()}
        ),
        lambda payload: payload["additional_context"].pop("routing_mode"),
        lambda payload: payload["additional_context"].update(
            {"routing_mode": "current_perception"}
        ),
    ],
    ids=(
        "text-only-plus-perception",
        "untagged-without-perception",
        "current-perception-routing-tag",
    ),
)
def test_ticket2c_adapter_rejects_invalid_request_union(
    tmp_path: Path,
    mutate: Any,
) -> None:
    module = _adapter_module()
    adapter = _adapter(tmp_path)
    payload = copy.deepcopy(_text_only_request())
    mutate(payload)

    with pytest.raises((ValueError, module.PerceptionValidationError)):
        adapter._validate_request(payload, validation_time=1.0)

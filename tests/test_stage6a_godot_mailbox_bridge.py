from __future__ import annotations

import copy
import math
from pathlib import Path
import re
from typing import Any

import pytest


PROJECT_ROOT = Path(__file__).resolve().parents[1]
BRIDGE_PATH = PROJECT_ROOT / "scripts/EngAInBridge3D.gd"
SOURCE = BRIDGE_PATH.read_text(encoding="utf-8")
REQUEST_ID = "req_0123456789abcdef0123456789abcdef"
CLIENT_REQUEST_ID = "dragon3d_0123456789abcdef0123456789abcdef_1"
SESSION_ID = "20260731_065008_63a62d"
REQUEST_PATH = "/mnt/data-drive/godot_engain_3d_avatar/engain_request.json"
RESPONSE_PATH = "/mnt/data-drive/godot_engain_3d_avatar/engain_response.json"
RESPONSE_KEYS = {
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
PROVIDER_REF = {
    "companion_ref": "hermes_b",
    "provider": "openai-codex",
    "model": "gpt-5.6-sol",
    "session_id": SESSION_ID,
}


def _require_all(*fragments: str) -> None:
    missing = [fragment for fragment in fragments if fragment not in SOURCE]
    assert not missing, f"Stage 6A bridge surface is missing: {missing}"


def _valid_response() -> dict[str, Any]:
    return {
        "request_id": REQUEST_ID,
        "client_request_id": CLIENT_REQUEST_ID,
        "narrative_response": "Observation-only fixture response.",
        "action_type": "OBSERVATION",
        "state_changes": {},
        "director_analysis": "fixture",
        "reasoning": "fixture",
        "entropy_impact": 0.0,
        "timestamp": 1.0,
        "provider_session_ref": copy.deepcopy(PROVIDER_REF),
        "perception_result": {
            "schema": "engain.runtime_perception_result.v1",
            "requested_state": "unavailable",
            "effective_state": "rejected",
            "capture_id": None,
            "capture_event": None,
            "capture_phase": None,
            "captured_at": None,
            "metadata_sha256": None,
            "image_sha256": None,
            "structured_snapshot_supplied": False,
            "viewport_image_attached": False,
            "failure_code": "PROVIDER_FAILURE",
        },
    }


def _response_fixture_is_accepted(
    value: Any,
    *,
    active_request_id: str | None = REQUEST_ID,
    active_client_request_id: str | None = CLIENT_REQUEST_ID,
) -> bool:
    if active_request_id is None or active_client_request_id is None:
        return False
    if not isinstance(value, dict) or set(value) != RESPONSE_KEYS:
        return False
    if value.get("request_id") != active_request_id:
        return False
    if value.get("client_request_id") != active_client_request_id:
        return False
    if value.get("provider_session_ref") != PROVIDER_REF:
        return False
    if value.get("action_type") != "OBSERVATION":
        return False
    if value.get("state_changes") != {}:
        return False
    entropy = value.get("entropy_impact")
    if isinstance(entropy, bool) or not isinstance(entropy, (int, float)):
        return False
    if not math.isfinite(float(entropy)) or float(entropy) != 0.0:
        return False
    narrative = value.get("narrative_response")
    if not isinstance(narrative, str) or not narrative.strip():
        return False
    perception = value.get("perception_result")
    if not isinstance(perception, dict):
        return False
    return perception.get("schema") == "engain.runtime_perception_result.v1"


def test_legacy_http_transport_is_completely_absent() -> None:
    forbidden = (
        "server_base_url",
        "HTTPRequest",
        "HTTPClient",
        "/v1/engain/parse",
        "http://127.0.0.1:8081",
    )
    present = [value for value in forbidden if value in SOURCE]
    assert present == [], f"legacy HTTP surface remains active: {present}"


def test_frozen_mailbox_paths_timeout_polling_and_session_are_explicit() -> None:
    _require_all(
        REQUEST_PATH,
        RESPONSE_PATH,
        SESSION_ID,
        "180.0",
        "0.1",
        "Time.get_ticks_msec",
    )


def test_bridge_local_timestamp_session_authority_is_absent() -> None:
    assert "_gen_session_id" not in SOURCE
    assert 'return "S_"' not in SOURCE
    assert "Time.get_datetime_dict_from_system" not in SOURCE


def test_submission_has_one_active_lifecycle_and_checks_both_mailboxes() -> None:
    _require_all(
        "_active_request_id",
        "_active_client_request_id",
        "MAILBOX_BUSY",
        "engain_request.json",
        "engain_response.json",
        ".engain_request.",
        "--publish-request",
    )
    assert SOURCE.count("_active_request_id") >= 3
    assert SOURCE.count("MAILBOX_BUSY") >= 2


def test_request_builder_contains_exact_frozen_wire_surface() -> None:
    _require_all(
        '"player_input"',
        '"game_state"',
        '"additional_context"',
        '"client_request_id"',
        '"companion_ref"',
        '"hermes_b"',
        '"perception"',
        '"timestamp"',
        '"request_id"',
        "req_",
        "dragon3d_",
    )
    assert not re.search(r'^\s*"session_id"\s*:\s*session_id\s*,?$', SOURCE, re.MULTILINE)
    assert '"actors"' not in SOURCE
    assert '"input"' not in SOURCE


def test_request_publication_never_overwrites_request_or_unread_response() -> None:
    _require_all(
        "FileAccess.file_exists",
        "engain_request.json",
        "engain_response.json",
        "MAILBOX_BUSY",
        "--publish-request",
    )
    assert "FileAccess.WRITE" in SOURCE
    assert "rename_absolute" not in SOURCE


def test_response_is_claimed_only_through_strict_local_helper() -> None:
    _require_all(
        "--claim-response",
        "ENGAIN_RESPONSE_JSON_BASE64=",
        "Marshalls.base64_to_raw",
        "engain_response.json",
    )
    assert not re.search(r"FileAccess\.open\([^\n]*engain_response", SOURCE)


def test_response_validator_names_every_exact_top_level_key() -> None:
    _require_all(*(f'"{key}"' for key in sorted(RESPONSE_KEYS)))
    _require_all("keys()", "size()")


def test_response_validator_correlates_request_and_client_ids() -> None:
    _require_all(
        '"request_id"',
        '"client_request_id"',
        "_active_request_id",
        "_active_client_request_id",
    )
    assert re.search(r"request_id[^\n]*(==|!=)[^\n]*_active_request_id", SOURCE)
    assert re.search(
        r"client_request_id[^\n]*(==|!=)[^\n]*_active_client_request_id", SOURCE
    )


def test_response_validator_freezes_provider_model_and_session() -> None:
    _require_all(
        '"provider_session_ref"',
        '"companion_ref"',
        '"hermes_b"',
        '"provider"',
        '"openai-codex"',
        '"model"',
        '"gpt-5.6-sol"',
        '"session_id"',
        SESSION_ID,
    )


def test_response_validator_enforces_observation_only_authority() -> None:
    _require_all(
        '"action_type"',
        '"OBSERVATION"',
        '"state_changes"',
        '"entropy_impact"',
        "is_finite",
    )


def test_malformed_and_unknown_response_content_is_rejected() -> None:
    _require_all(
        "JSON.new()",
        "get_error",
        "TYPE_DICTIONARY",
        "keys()",
        "RESPONSE_SCHEMA",
    )
    assert re.search(r"\.\s*parse\s*\(", SOURCE)
    assert "JSON.parse_string" not in SOURCE


def test_stale_and_late_responses_are_claimed_discarded_and_never_spoken() -> None:
    _require_all(
        "--claim-response",
        "stale",
        "_active_request_id",
        "dragon_speaking",
        "log_line",
    )
    assert SOURCE.lower().count("stale") >= 2


def test_timeout_ends_lifecycle_without_retry_or_file_overwrite() -> None:
    _require_all("180.0", "Time.get_ticks_msec", "dragon_speaking", "timeout")
    forbidden_retry_fragments = ("retry_request", "retry_provider", "automatic_retry")
    assert not any(fragment in SOURCE for fragment in forbidden_retry_fragments)


def test_bridge_has_no_world_movement_inventory_or_canon_mutation_surface() -> None:
    forbidden = (
        "global_position =",
        "position =",
        "orbit_radius =",
        "orbit_speed =",
        "inventory =",
        "canon =",
        "state_changes[",
        "set_meta(\"canon",
    )
    assert [fragment for fragment in forbidden if fragment in SOURCE] == []


def test_bridge_contains_no_provider_execution_route() -> None:
    forbidden = (
        "_run_bounded",
        "HermesCLIClient",
        "--resume",
        "--image",
        "hermes chat",
        "/v1/engain/parse",
    )
    assert [fragment for fragment in forbidden if fragment in SOURCE] == []
    if "OS.execute" in SOURCE:
        _require_all("hermes_session_adapter.py", "--publish-request", "--claim-response")


@pytest.mark.parametrize(
    ("mutation", "active_request_id", "active_client_request_id"),
    [
        (lambda value: value.__setitem__("request_id", "req_ffffffffffffffffffffffffffffffff"), REQUEST_ID, CLIENT_REQUEST_ID),
        (lambda value: value.__setitem__("client_request_id", "dragon3d_ffffffffffffffffffffffffffffffff_9"), REQUEST_ID, CLIENT_REQUEST_ID),
        (lambda value: value["provider_session_ref"].__setitem__("session_id", "wrong_session"), REQUEST_ID, CLIENT_REQUEST_ID),
        (lambda value: value["provider_session_ref"].__setitem__("provider", "wrong-provider"), REQUEST_ID, CLIENT_REQUEST_ID),
        (lambda value: value.__setitem__("action_type", "MOVE"), REQUEST_ID, CLIENT_REQUEST_ID),
        (lambda value: value.__setitem__("state_changes", {"world": "changed"}), REQUEST_ID, CLIENT_REQUEST_ID),
        (lambda value: value.__setitem__("entropy_impact", 1.0), REQUEST_ID, CLIENT_REQUEST_ID),
        (lambda value: value.__setitem__("unknown", True), REQUEST_ID, CLIENT_REQUEST_ID),
        (lambda value: None, None, None),
    ],
)
def test_response_fixture_matrix_rejects_wrong_stale_or_mutating_evidence(
    mutation: Any,
    active_request_id: str | None,
    active_client_request_id: str | None,
) -> None:
    response = _valid_response()
    mutation(response)
    assert not _response_fixture_is_accepted(
        response,
        active_request_id=active_request_id,
        active_client_request_id=active_client_request_id,
    )


def test_response_fixture_accepts_only_exact_correlated_observation() -> None:
    assert _response_fixture_is_accepted(_valid_response())

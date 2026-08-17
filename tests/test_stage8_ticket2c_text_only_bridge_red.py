from __future__ import annotations

import copy
import hashlib
import json
from pathlib import Path
import subprocess
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parents[1]
GODOT = Path("/home/mytruelove/.local/bin/godot")
AUDIT_ROOT = Path("/mnt/data-drive/engain-avatar-audit")
FULL_RESPONSE_PATH = (
    AUDIT_ROOT
    / "ENGAV3D-0021-STAGE7-LIVE-CURRENT-PERCEPTION"
    / "LIVE"
    / "response-observed.json"
)
UNAVAILABLE_RESPONSE_PATH = (
    AUDIT_ROOT / "ENGAV3D-0002-RUNTIME-PREFLIGHT" / "mailbox_response.raw.json"
)
FULL_RESPONSE_SHA256 = "5953bce251e8a8f684a175d5b43f13a82dcdf9d9c926f9aded127414472f35ad"
UNAVAILABLE_RESPONSE_SHA256 = "dc1a9a8e4b847f9531c0343b9e93b5e5ce470971498bc5f735c8a3c570ad3c00"
TEXT_REQUEST_ID = "req_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
TEXT_CLIENT_ID = "dragon3d_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb_1"


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _text_only_response() -> dict[str, Any]:
    return {
        "request_id": TEXT_REQUEST_ID,
        "client_request_id": TEXT_CLIENT_ID,
        "narrative_response": "Contract-only successful text response fixture.",
        "action_type": "OBSERVATION",
        "state_changes": {},
        "director_analysis": "Contract-only; provider not executed",
        "reasoning": "Current perception was intentionally not requested.",
        "entropy_impact": 0.0,
        "timestamp": 1.0,
        "provider_session_ref": {
            "companion_ref": "hermes_b",
            "provider": "openai-codex",
            "model": "gpt-5.6-sol",
            "session_id": "20260731_065008_63a62d",
        },
        "perception_result": {
            "schema": "engain.runtime_perception_result.v1",
            "requested_state": "not_requested",
            "effective_state": "not_requested",
            "capture_id": None,
            "capture_event": None,
            "capture_phase": None,
            "captured_at": None,
            "metadata_sha256": None,
            "image_sha256": None,
            "structured_snapshot_supplied": False,
            "viewport_image_attached": False,
            "failure_code": None,
        },
    }


def _correlate(response: dict[str, Any]) -> dict[str, Any]:
    correlated = copy.deepcopy(response)
    correlated["request_id"] = TEXT_REQUEST_ID
    correlated["client_request_id"] = TEXT_CLIENT_ID
    return correlated


def _run_bridge_matrix(tmp_path: Path, cases: list[dict[str, Any]]) -> dict[str, bool]:
    cases_path = tmp_path / "ticket2c-cases.json"
    cases_path.write_text(json.dumps(cases), encoding="utf-8")
    runner_path = tmp_path / "ticket2c_bridge_runner.gd"
    runner_path.write_text(
        """extends SceneTree

func _initialize() -> void:
    var bridge = load("res://scripts/EngAInBridge3D.gd").new()
    var raw := FileAccess.get_file_as_string("%s")
    var cases: Variant = JSON.parse_string(raw)
    var results := {}
    for item in cases:
        bridge._active_request_id = item["request_id"]
        bridge._active_client_request_id = item["client_request_id"]
        bridge._active_capture_id = item["active_capture_id"]
        results[item["name"]] = bridge._validate_correlated_response(item["response"])
    print("STAGE8_TICKET2C_BRIDGE_RESULTS=" + JSON.stringify(results))
    quit(0)
"""
        % str(cases_path).replace("\\", "\\\\").replace('"', '\\"'),
        encoding="utf-8",
    )
    completed = subprocess.run(
        [
            str(GODOT),
            "--headless",
            "--path",
            str(PROJECT_ROOT),
            "--script",
            str(runner_path),
        ],
        text=True,
        capture_output=True,
        timeout=30,
        check=False,
    )
    output = completed.stdout + completed.stderr
    assert completed.returncode == 0, output
    marker = "STAGE8_TICKET2C_BRIDGE_RESULTS="
    lines = [line for line in output.splitlines() if line.startswith(marker)]
    assert len(lines) == 1, output
    parsed = json.loads(lines[0][len(marker) :])
    assert isinstance(parsed, dict)
    return parsed


def _case(
    name: str,
    response: dict[str, Any],
    *,
    active_capture_id: str,
) -> dict[str, Any]:
    return {
        "name": name,
        "request_id": response["request_id"],
        "client_request_id": response["client_request_id"],
        "active_capture_id": active_capture_id,
        "response": response,
    }


def test_ticket2c_stage7_response_fixture_bytes_are_preserved() -> None:
    assert _sha256(FULL_RESPONSE_PATH) == FULL_RESPONSE_SHA256
    assert _sha256(UNAVAILABLE_RESPONSE_PATH) == UNAVAILABLE_RESPONSE_SHA256


def test_ticket2c_bridge_preserves_stage7_full_and_unavailable_responses(
    tmp_path: Path,
) -> None:
    full = json.loads(FULL_RESPONSE_PATH.read_bytes())
    unavailable = json.loads(UNAVAILABLE_RESPONSE_PATH.read_bytes())

    results = _run_bridge_matrix(
        tmp_path,
        [
            _case(
                "stage7_full",
                full,
                active_capture_id=full["perception_result"]["capture_id"],
            ),
            _case(
                "stage7_unavailable",
                unavailable,
                active_capture_id=unavailable["perception_result"]["capture_id"],
            ),
        ],
    )

    assert results == {"stage7_full": True, "stage7_unavailable": True}


def test_ticket2c_bridge_admits_correlated_text_only_success(
    tmp_path: Path,
) -> None:
    response = _text_only_response()

    results = _run_bridge_matrix(
        tmp_path,
        [_case("text_only_success", response, active_capture_id="")],
    )

    assert results == {"text_only_success": True}


def test_ticket2c_bridge_rejects_route_coupled_response_toxics(
    tmp_path: Path,
) -> None:
    text_success = _text_only_response()
    full = _correlate(json.loads(FULL_RESPONSE_PATH.read_bytes()))
    unavailable = _correlate(json.loads(UNAVAILABLE_RESPONSE_PATH.read_bytes()))
    current_plus_not_requested = copy.deepcopy(text_success)
    capture_toxic = copy.deepcopy(text_success)
    capture_toxic["perception_result"]["capture_id"] = (
        "cap_ffffffffffffffffffffffffffffffff_1"
    )
    image_toxic = copy.deepcopy(text_success)
    image_toxic["perception_result"]["image_sha256"] = "f" * 64

    results = _run_bridge_matrix(
        tmp_path,
        [
            _case("text_only_plus_full", full, active_capture_id=""),
            _case("text_only_plus_unavailable", unavailable, active_capture_id=""),
            _case(
                "current_plus_not_requested",
                current_plus_not_requested,
                active_capture_id="cap_eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee_1",
            ),
            _case("not_requested_plus_capture", capture_toxic, active_capture_id=""),
            _case("not_requested_plus_image", image_toxic, active_capture_id=""),
        ],
    )

    assert results == {
        "text_only_plus_full": False,
        "text_only_plus_unavailable": False,
        "current_plus_not_requested": False,
        "not_requested_plus_capture": False,
        "not_requested_plus_image": False,
    }

from __future__ import annotations

from pathlib import Path
import re

import pytest


PROJECT_ROOT = Path(__file__).resolve().parents[1]
CAPTURE_SOURCE = PROJECT_ROOT / "scripts" / "PerceptionCapture3D.gd"
BRIDGE_SOURCE = PROJECT_ROOT / "scripts" / "EngAInBridge3D.gd"
HUD_SOURCE = PROJECT_ROOT / "scripts" / "ControlHUD.gd"
MAIN_SOURCE = PROJECT_ROOT / "scripts" / "Main.gd"

RESULT_KEYS = {
    "status",
    "client_request_id",
    "capture_id",
    "captured_at",
    "failure_code",
    "perception",
}
PERCEPTION_KEYS = {
    "schema",
    "perception_state",
    "capture_id",
    "capture_event",
    "capture_phase",
    "captured_at",
    "project_id",
    "scene_path",
    "snapshot",
    "viewport",
    "unavailable_reason",
}
VIEWPORT_KEYS = {
    "availability",
    "image_path",
    "image_sha256",
    "media_type",
    "width",
    "height",
    "reason",
}
KNOWN_LOCAL_FAILURES = {
    "DRAGON_SCENE_UNAVAILABLE",
    "CAPTURE_ROOT_REJECTED",
    "PNG_DIMENSION_MISMATCH",
    "FINAL_CORRELATION_FAILED",
}


def _source(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def _function(source: str, name: str) -> str:
    match = re.search(rf"(?m)^func\s+{re.escape(name)}\s*\(", source)
    if match is None:
        pytest.fail(
            f"STAGE7_CAPTURE_RED: required production function {name}(...) is absent",
            pytrace=False,
        )
    following = re.search(r"(?m)^func\s+", source[match.end() :])
    end = len(source) if following is None else match.end() + following.start()
    return source[match.start() : end]


def _assert_order(body: str, *tokens: str) -> None:
    positions: list[int] = []
    for token in tokens:
        position = body.find(token)
        assert position >= 0, f"STAGE7_CAPTURE_RED: missing ordered token {token!r}"
        positions.append(position)
    assert positions == sorted(positions), (
        "STAGE7_CAPTURE_RED: lifecycle order differs: " + " -> ".join(tokens)
    )


def _dictionary_literal_keys(source: str, anchor: str) -> set[str]:
    start = source.find(anchor)
    assert start >= 0, f"STAGE7_CAPTURE_RED: missing dictionary anchor {anchor!r}"
    brace = source.find("{", start)
    assert brace >= 0
    depth = 0
    end = -1
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                end = index + 1
                break
    assert end > brace
    keys: set[str] = set()
    depth = 0
    for line in source[brace:end].splitlines():
        if depth == 1:
            match = re.match(r'^\s*"([^"]+)"\s*:', line)
            if match is not None:
                keys.add(match.group(1))
        depth += line.count("{") - line.count("}")
    return keys


def test_live_capture_api_is_added_without_removing_stage5a_capture_once() -> None:
    source = _source(CAPTURE_SOURCE)
    assert re.search(r"(?m)^func capture_once\(\) -> Dictionary:", source)
    assert re.search(
        r"(?m)^func capture_for_submission\(client_request_id: String\) -> Dictionary:",
        source,
    ), "STAGE7_CAPTURE_RED: capture_for_submission(client_request_id) is absent"


def test_live_capture_uses_external_client_id_and_allocates_only_capture_id() -> None:
    body = _function(_source(CAPTURE_SOURCE), "capture_for_submission")
    assert "_valid_client_request_id(client_request_id)" in body
    assert '_generate_id("dragon3d"' not in body
    assert '_generate_id("req"' not in body
    assert '_generate_id("cap", true)' in body
    assert body.count('_generate_id("cap", true)') == 1


def test_live_capture_returns_exact_six_key_contract() -> None:
    body = _function(_source(CAPTURE_SOURCE), "capture_for_submission")
    assert _dictionary_literal_keys(body, "return {") == RESULT_KEYS
    assert '"status": "full"' in body
    assert '"status": "unavailable"' in body
    assert '"client_request_id": client_request_id' in body
    assert '"capture_id": capture_id' in body
    assert '"captured_at": captured_at' in body


def test_successful_live_capture_contains_exact_frozen_full_perception() -> None:
    body = _function(_source(CAPTURE_SOURCE), "capture_for_submission")
    assert _dictionary_literal_keys(body, '"perception_state": "full"') == PERCEPTION_KEYS
    for token in (
        '"schema": PERCEPTION_SCHEMA',
        '"perception_state": "full"',
        '"capture_id": capture_id',
        '"capture_event": CAPTURE_EVENT',
        '"capture_phase": CAPTURE_PHASE',
        '"captured_at": captured_at',
        '"project_id": PROJECT_ID',
        '"scene_path": SCENE_PATH',
        '"unavailable_reason": null',
    ):
        assert token in body
    assert '"metadata_path"' in body
    assert '"metadata_sha256"' in body
    assert '"metadata"' in body


def test_failed_live_capture_contains_exact_frozen_unavailable_perception() -> None:
    body = _function(_source(CAPTURE_SOURCE), "capture_for_submission")
    assert _dictionary_literal_keys(body, '"perception_state": "unavailable"') == PERCEPTION_KEYS
    assert _dictionary_literal_keys(body, '"availability": "unavailable"') == VIEWPORT_KEYS
    assert '"perception_state": "unavailable"' in body
    assert body.count('"capture_failed"') >= 2
    assert '"snapshot": null' in body
    for key in ("image_path", "image_sha256", "media_type", "width", "height"):
        assert re.search(rf'"{key}"\s*:\s*null', body)


def test_known_capture_failures_remain_local_diagnostics_only() -> None:
    capture = _function(_source(CAPTURE_SOURCE), "capture_for_submission")
    bridge_builder = _function(_source(BRIDGE_SOURCE), "_build_mailbox_request")
    for failure in KNOWN_LOCAL_FAILURES:
        assert failure in capture
        assert failure not in bridge_builder
    assert '"failure_code"' not in bridge_builder
    assert '"perception": perception' in bridge_builder


def test_bridge_owns_client_and_request_ids_but_not_live_capture_id() -> None:
    body = _function(_source(BRIDGE_SOURCE), "submit")
    assert '"req_" + _random_hex_16()' in body
    assert '"dragon3d_%s_%d"' in body
    assert '"cap_%s_%d"' not in body
    assert "capture_for_submission(client_request_id)" in body
    _assert_order(body, "client_request_id :=", "capture_for_submission(client_request_id)")


def test_bridge_reserves_busy_before_first_await_and_starts_one_capture() -> None:
    body = _function(_source(BRIDGE_SOURCE), "submit")
    assert body.count("capture_for_submission(client_request_id)") == 1
    _assert_order(
        body,
        "client_request_id :=",
        "_busy = true",
        "_capture_pending = true",
        "await",
        "capture_for_submission(client_request_id)",
    )


def test_capture_pending_repeat_submit_is_silent_and_side_effect_free() -> None:
    body = _function(_source(BRIDGE_SOURCE), "submit")
    pending = body.find("if _capture_pending:")
    client = body.find("client_request_id :=")
    assert 0 <= pending < client
    pending_block = body[pending:client]
    assert "return" in pending_block
    for forbidden in (
        "_emit_err",
        "_emit_user",
        "dragon_speaking",
        "_random_hex_16",
        "_execute_adapter",
    ):
        assert forbidden not in pending_block


def test_no_accepted_user_or_speaking_mutation_occurs_before_capture_returns() -> None:
    body = _function(_source(BRIDGE_SOURCE), "submit")
    capture_return = body.find("capture_result")
    assert capture_return >= 0
    before_capture = body[:capture_return]
    assert "_emit_user" not in before_capture
    assert 'emit_signal("dragon_speaking", true)' not in before_capture
    assert "MAILBOX_BUSY" not in before_capture


def test_request_timestamp_follows_capture_and_full_perception_is_forwarded_directly() -> None:
    body = _function(_source(BRIDGE_SOURCE), "submit")
    _assert_order(
        body,
        "capture_for_submission(client_request_id)",
        "timestamp := Time.get_unix_time_from_system()",
        "_build_mailbox_request",
    )
    builder = _function(_source(BRIDGE_SOURCE), "_build_mailbox_request")
    assert "perception: Dictionary" in builder
    assert '"perception": perception' in builder
    assert '"perception_state": "unavailable"' not in builder


def test_valid_unavailable_result_publishes_once_and_invalid_result_aborts() -> None:
    body = _function(_source(BRIDGE_SOURCE), "submit")
    assert 'status not in ["full", "unavailable"]' in body
    assert 'capture_result["perception"]' in body
    assert body.count('PackedStringArray(["--publish-request", temporary_path])') == 1
    validation = body.find('status not in ["full", "unavailable"]')
    publication = body.find('PackedStringArray(["--publish-request", temporary_path])')
    assert 0 <= validation < publication
    invalid_branch = body[validation:publication]
    assert "_end_active_lifecycle()" in invalid_branch
    assert "return" in invalid_branch


def test_publication_failure_releases_lifecycle_without_adapter_processing() -> None:
    body = _function(_source(BRIDGE_SOURCE), "submit")
    failure_start = body.find('publication["code"] != 0')
    success_start = body.find("_active_request_id = request_id")
    assert 0 <= failure_start < success_start
    failure_branch = body[failure_start:success_start]
    assert "_end_active_lifecycle()" in failure_branch
    assert "submission_committed" not in failure_branch
    for forbidden in ("--once", "process_once", "HermesCLIClient", "provider"):
        assert forbidden not in failure_branch


def test_submission_committed_signal_follows_successful_publication_only() -> None:
    source = _source(BRIDGE_SOURCE)
    assert re.search(
        r'(?m)^signal submission_committed\(client_request_id: String, submitted_text: String\)',
        source,
    )
    body = _function(source, "submit")
    publication = body.find('publication["code"] != 0')
    active = body.find("_active_request_id = request_id")
    committed = body.find('emit_signal("submission_committed", client_request_id, msg)')
    assert 0 <= publication < active < committed
    _assert_order(body, "capture_for_submission", "ENGAIN_REQUEST_PUBLISHED=1", "submission_committed")


def test_hud_clears_only_matching_text_on_submission_committed() -> None:
    source = _source(HUD_SOURCE)
    submitted = _function(source, "_on_input_submitted")
    assert "input.clear()" not in submitted
    assert "submission_committed" in source
    committed = _function(source, "_on_submission_committed")
    assert "client_request_id" in committed
    assert "submitted_text" in committed
    _assert_order(committed, "if input.text == submitted_text:", "input.clear()")


def test_button_submission_never_clears_unrelated_typed_input() -> None:
    body = _function(_source(HUD_SOURCE), "_on_send_pressed")
    assert "input.clear()" not in body
    assert "input.text =" not in body
    assert "_bridge.call" in body or "_bridge.submit" in body


def test_main_remains_stage5a_only_and_outside_live_orchestration() -> None:
    source = _source(MAIN_SOURCE)
    assert "capture_once()" in source
    for forbidden in (
        "capture_for_submission",
        "submission_committed",
        "engain_request.json",
        "_capture_pending",
    ):
        assert forbidden not in source

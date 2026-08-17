from __future__ import annotations

from pathlib import Path
import re


PROJECT_ROOT = Path(__file__).resolve().parents[1]
BRIDGE_PATH = PROJECT_ROOT / "scripts" / "EngAInBridge3D.gd"
HUD_PATH = PROJECT_ROOT / "scripts" / "ControlHUD.gd"
BRIDGE = BRIDGE_PATH.read_text(encoding="utf-8")
HUD = HUD_PATH.read_text(encoding="utf-8")


def _function(source: str, name: str) -> str:
    match = re.search(rf"(?m)^func\s+{re.escape(name)}\s*\(", source)
    assert match is not None, f"Ticket 3B prerequisite function is absent: {name}"
    following = re.search(r"(?m)^func\s+", source[match.end() :])
    end = len(source) if following is None else match.end() + following.start()
    return source[match.start() : end]


def test_ticket3b_internal_looking_is_observable() -> None:
    submit = _function(BRIDGE, "submit")
    capture = submit.find("capture_for_submission(client_request_id)")
    assert capture >= 0
    before_capture = submit[:capture]

    assert "LOOKING" in before_capture.upper(), (
        "current-perception submission does not expose Ticket 3A LOOKING_INTERNAL"
    )
    assert "_set_lifecycle_status" in before_capture
    assert '"LOOKING_INTERNAL"' in before_capture


def test_ticket3b_visible_precapture_mutation_remains_forbidden() -> None:
    submit = _function(BRIDGE, "submit")
    capture = submit.find("capture_for_submission(client_request_id)")
    assert capture >= 0
    before_capture = submit[:capture]
    visible_tokens = (
        "Dragon is looking",
        "Dragon is thinking",
        "_emit_user",
        "_emit_dragon",
        'emit_signal("dragon_speaking", true)',
        "input.clear",
    )
    assert [token for token in visible_tokens if token in before_capture] == []


def test_ticket3b_thinking_begins_only_after_successful_request_commit() -> None:
    submit = _function(BRIDGE, "submit")
    publication_success = submit.find("ENGAIN_REQUEST_PUBLISHED=1")
    committed = submit.find('emit_signal("submission_committed"')
    assert 0 <= publication_success < committed

    post_commit = submit[committed:]
    status_surface = BRIDGE + HUD
    assert "THINKING" in status_surface.upper(), (
        "no observable route-aware thinking lifecycle exists after request commit"
    )
    thinking_position = submit.upper().find("THINKING")
    if thinking_position >= 0:
        assert committed < thinking_position
    assert '_set_lifecycle_status("THINKING")' in post_commit
    assert "status_changed" in BRIDGE
    assert "status_changed" in HUD
    assert "Dragon is thinking..." in HUD
    assert "capture_for_submission" not in _function(HUD, "_on_submission_committed")


def test_ticket3b_only_exact_correlated_response_can_clear_active_status() -> None:
    validator = _function(BRIDGE, "_validate_correlated_response")
    poll = _function(BRIDGE, "_poll_response_mailbox")

    assert 'request_id != _active_request_id' in validator
    assert 'client_request_id != _active_client_request_id' in validator
    rejected = poll.find("not _validate_correlated_response(parsed)")
    clear = poll.find("_end_active_lifecycle()")
    assert 0 <= rejected < clear
    rejection_branch = poll[rejected:clear]
    assert "return" in rejection_branch


def test_ticket3b_capture_and_publication_failure_release_active_lifecycle() -> None:
    submit = _function(BRIDGE, "submit")
    capture_failure = submit.find('status not in ["full", "unavailable"]')
    publication_failure = submit.find('publication["code"] != 0')
    committed = submit.find('emit_signal("submission_committed"')
    assert 0 <= capture_failure < publication_failure < committed
    assert "_end_active_lifecycle()" in submit[capture_failure:publication_failure]
    assert "_end_active_lifecycle()" in submit[publication_failure:committed]
    assert "THINKING" not in submit[:committed].upper()


def test_ticket3b_timeout_releases_active_lifecycle() -> None:
    process = _function(BRIDGE, "_process")
    assert "180.0" in BRIDGE
    assert process.count("_end_active_lifecycle()") >= 2


def test_ticket3b_runtime_shutdown_clears_transient_status() -> None:
    clear = _function(BRIDGE, "_end_active_lifecycle")
    assert "THINKING" in clear.upper(), (
        "runtime lifecycle cleanup has no observable thinking-status clearing"
    )
    shutdown_surface = BRIDGE + HUD
    assert any(token in shutdown_surface for token in ("_exit_tree", "NOTIFICATION_WM_CLOSE_REQUEST", "tree_exiting")), (
        "runtime shutdown has no transient HUD lifecycle cleanup boundary"
    )
    assert '_set_lifecycle_status("IDLE")' in clear

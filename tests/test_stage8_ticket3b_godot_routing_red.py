from __future__ import annotations

import json
from pathlib import Path
import re
import subprocess


PROJECT_ROOT = Path(__file__).resolve().parents[1]
BRIDGE_PATH = PROJECT_ROOT / "scripts" / "EngAInBridge3D.gd"
SOURCE = BRIDGE_PATH.read_text(encoding="utf-8")
GODOT = Path("/home/mytruelove/.local/bin/godot")
TEXT_ONLY_FIXTURE = (
    "Without using any current image, describe what you remember about the previous "
    "Dragon and the room/environment you saw before this latest scene."
)
CURRENT_FIXTURE = "What color is the Dragon right now?"
ROUTING_CASES = {
    TEXT_ONLY_FIXTURE: "text_only",
    CURRENT_FIXTURE: "current_perception",
    "What do you see?": "current_perception",
    "What did you see in the previous scene?": "text_only",
    "Explain this plan.": "text_only",
    "Do you remember this Dragon on the screen?": "current_perception",
}


def _function(source: str, name: str) -> str:
    match = re.search(rf"(?m)^func\s+{re.escape(name)}\s*\(", source)
    assert match is not None, f"Ticket 3B prerequisite function is absent: {name}"
    following = re.search(r"(?m)^func\s+", source[match.end() :])
    end = len(source) if following is None else match.end() + following.start()
    return source[match.start() : end]


def _text_only_submission_surface(body: str) -> bool:
    capture = body.find("capture_for_submission")
    if capture < 0:
        return False
    before_capture = body[:capture]
    route_is_locally_selected = (
        '"text_only"' in before_capture
        and ("routing_mode" in before_capture or "route" in before_capture)
        and ("current image" in SOURCE.lower() or "no-current-image" in SOURCE.lower())
    )
    capture_is_route_guarded = bool(
        re.search(
            r"(?s)if[^\n]*(current_perception|routing_mode|route)[^:]*:.*capture_for_submission",
            body,
        )
    )
    text_wire_is_reachable = (
        '"routing_mode"' in body
        and '"text_only"' in body
        and '"perception": perception' in SOURCE
    )
    return route_is_locally_selected and capture_is_route_guarded and text_wire_is_reachable


def _run_routing_matrix(tmp_path: Path) -> dict[str, object]:
    cases_path = tmp_path / "ticket3c-routing-cases.json"
    cases_path.write_text(json.dumps(ROUTING_CASES), encoding="utf-8")
    runner = tmp_path / "ticket3c_routing_runner.gd"
    runner.write_text(
        """extends SceneTree

func _initialize() -> void:
    var bridge = load("res://scripts/EngAInBridge3D.gd").new()
    var cases: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("%s"))
    var routes := {}
    for message in cases:
        routes[message] = bridge._classify_route(message)
    var current: Dictionary = bridge._build_mailbox_request(
        "current", "req_11111111111111111111111111111111",
        "dragon3d_22222222222222222222222222222222_1",
        {"schema": "engain.runtime_perception.v1"}, 1.0
    )
    var text_only: Dictionary = bridge._build_text_only_mailbox_request(
        "text", "req_33333333333333333333333333333333",
        "dragon3d_44444444444444444444444444444444_1", 2.0
    )
    print("STAGE8_TICKET3C_ROUTING=" + JSON.stringify({
        "routes": routes,
        "current_context": current["additional_context"],
        "text_context": text_only["additional_context"],
    }))
    quit(0)
"""
        % str(cases_path).replace("\\", "\\\\").replace('"', '\\"'),
        encoding="utf-8",
    )
    completed = subprocess.run(
        [str(GODOT), "--headless", "--path", str(PROJECT_ROOT), "--script", str(runner)],
        text=True,
        capture_output=True,
        timeout=30,
        check=False,
    )
    output = completed.stdout + completed.stderr
    assert completed.returncode == 0, output
    forbidden_diagnostics = (
        "SCRIPT ERROR",
        "Parse Error",
        "Failed to load script",
        "Cannot load source code",
    )
    assert not any(diagnostic in output for diagnostic in forbidden_diagnostics), output
    marker = "STAGE8_TICKET3C_ROUTING="
    lines = [line for line in output.splitlines() if line.startswith(marker)]
    assert len(lines) == 1, output
    result = json.loads(lines[0][len(marker) :])
    assert isinstance(result, dict)
    return result


def test_ticket3b_text_only_fixture_selects_text_wire_without_capture(tmp_path: Path) -> None:
    """The explicit no-current-image fixture must bypass capture before publication."""
    assert "Without using any current image" in TEXT_ONLY_FIXTURE
    assert _text_only_submission_surface(_function(SOURCE, "submit")), (
        "Godot submission has no reachable local text-only route that suppresses "
        "capture and publishes the admitted text-only mailbox representation"
    )
    result = _run_routing_matrix(tmp_path)
    assert result["routes"] == ROUTING_CASES
    assert result["text_context"] == {
        "client_request_id": "dragon3d_44444444444444444444444444444444_1",
        "companion_ref": "hermes_b",
        "routing_mode": "text_only",
    }
    current_context = result["current_context"]
    assert isinstance(current_context, dict)
    assert set(current_context) == {
        "client_request_id",
        "companion_ref",
        "perception",
    }


def test_ticket3b_current_perception_fixture_preserves_one_stage7_capture() -> None:
    """The current-view fixture retains the sealed single-capture publication order."""
    body = _function(SOURCE, "submit")
    assert "right now" in CURRENT_FIXTURE
    assert body.count("capture_for_submission(client_request_id)") == 1
    capture = body.find("capture_for_submission(client_request_id)")
    publication = body.find('PackedStringArray(["--publish-request", temporary_path])')
    assert 0 <= capture < publication
    builder = _function(SOURCE, "_build_mailbox_request")
    assert '"perception": perception' in builder
    assert '"capture_id": capture_id' not in builder


def test_ticket3b_routing_probe_has_no_provider_execution_surface() -> None:
    forbidden = ("--resume", "--image", "HermesCLIClient", "_run_bounded", "hermes chat")
    assert [token for token in forbidden if token in SOURCE] == []

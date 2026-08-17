from __future__ import annotations

from pathlib import Path
import re


PROJECT_ROOT = Path(__file__).resolve().parents[1]
MAIN_PATH = PROJECT_ROOT / "scripts" / "Main.gd"
BRIDGE_PATH = PROJECT_ROOT / "scripts" / "EngAInBridge3D.gd"
PROJECT_PATH = PROJECT_ROOT / "project.godot"
MAIN = MAIN_PATH.read_text(encoding="utf-8")
BRIDGE = BRIDGE_PATH.read_text(encoding="utf-8")
PROJECT = PROJECT_PATH.read_text(encoding="utf-8")
RUNTIME_SURFACE = MAIN + "\n" + BRIDGE + "\n" + PROJECT


def _function(source: str, name: str) -> str:
    match = re.search(rf"(?m)^func\s+{re.escape(name)}\s*\(", source)
    assert match is not None, f"Ticket 3B prerequisite function is absent: {name}"
    following = re.search(r"(?m)^func\s+", source[match.end() :])
    end = len(source) if following is None else match.end() + following.start()
    return source[match.start() : end]


def _has_worker_readiness_boundary() -> bool:
    worker_tokens = ("worker", "adapter")
    readiness_tokens = ("READY", "ready", "pid", "health")
    persistent_tokens = ("persistent", "watching", "engain_hermes_adapter.pid")
    lowered = RUNTIME_SURFACE.lower()
    return (
        any(token in lowered for token in worker_tokens)
        and any(token.lower() in lowered for token in readiness_tokens)
        and any(token.lower() in lowered for token in persistent_tokens)
    )


def test_ticket3b_runtime_boundary_makes_exactly_one_persistent_worker_available() -> None:
    """The RED permits either Godot-owned or launcher-owned process supervision."""
    assert _has_worker_readiness_boundary(), (
        "no Godot/launcher-facing persistent worker readiness and exclusive-ownership "
        "boundary is present; bounded mailbox helper execution is not worker availability"
    )
    assert "engain_hermes_adapter.pid" in RUNTIME_SURFACE


def test_ticket3b_multiple_submissions_share_one_observed_worker_identity() -> None:
    submit = _function(BRIDGE, "submit")
    assert "--once" not in submit
    assert "process_once" not in submit
    assert "worker" in RUNTIME_SURFACE.lower()
    assert any(token in RUNTIME_SURFACE for token in ("session_id", "FROZEN_SESSION_ID"))
    assert any(token in RUNTIME_SURFACE.lower() for token in ("worker_ready", "worker_state", "worker_pid")), (
        "runtime has no observable stable worker identity/state across submissions"
    )


def test_ticket3b_runtime_shutdown_requests_ticket2f_explicit_stop() -> None:
    shutdown_tokens = ("_exit_tree", "NOTIFICATION_WM_CLOSE_REQUEST", "tree_exiting")
    assert any(token in RUNTIME_SURFACE for token in shutdown_tokens), (
        "runtime/launcher exposes no shutdown lifecycle boundary"
    )
    assert any(token in RUNTIME_SURFACE for token in ("request_stop", "shutdown", '"stop"')), (
        "runtime/launcher shutdown does not request the Ticket 2F explicit stop lifecycle"
    )
    assert "STOPPED" in RUNTIME_SURFACE, (
        "runtime/launcher does not observe terminal worker STOPPED"
    )


def test_ticket3b_worker_red_does_not_force_godot_to_spawn_python() -> None:
    """No implementation spelling is required; this toxic freezes the choice open."""
    assert "OS.create_process" not in MAIN
    bridge_exec = _function(BRIDGE, "_execute_adapter")
    assert "--publish-request" not in bridge_exec
    assert "--claim-response" not in bridge_exec
    assert "--resume" not in RUNTIME_SURFACE
    assert "--image" not in RUNTIME_SURFACE

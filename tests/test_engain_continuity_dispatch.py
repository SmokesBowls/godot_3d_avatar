"""
Offline tests for the EngAIn-continuity-dispatch path added 2026-08-17:
engain_continuity_client.py itself, HermesSessionAdapter's new
ENGAIN_CONTINUITY_DISPATCH-gated binding/dispatch/response methods, and
the fact that unset (default) behavior remains exactly what it always was.

Exercises a small local fake /dispatch endpoint, not the real
presence_authority_server.py subprocess — that already has its own
offline tests in the EngAIn checkout (test_presence_authority_dispatch.py)
covering SharedSessionBridge correctness itself. This file's job is only
"does this repo's own worker code submit the right request body and
correctly consume the response," never re-proving the bridge.
"""

from __future__ import annotations

import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from typing import Any, Callable, Dict, List, Tuple

import pytest

PROJECT_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT_ROOT))

from hermes_session_adapter import AdapterConfig, HermesAdapterError, HermesSessionAdapter

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_hermes_session_adapter import (  # noqa: E402
    CAPTURED_AT,
    _build_request,
    _retime_request,
    _valid_session_state,
    _write_editor_report,
)

import engain_continuity_client

COMPAT_ENV = "ENGAIN_PRESENCE_AUTHORITY_FAIL_OPEN_COMPAT"
PERSISTED_SESSION_ID = "20260731_065008_63a62d"


class _RecordingDirector:
    """Minimal stand-in — same reasoning as test_presence_authority_integration
    .py's own copy: these tests only need to know whether Hermes was ever
    actually reached, not exercise the full local director."""

    def __init__(self) -> None:
        self.calls = 0

    def process_player_input(self, player_input: str, game_state: dict) -> dict:
        self.calls += 1
        return {"narrative_response": "should not have been reached"}


class _FakeDispatchHandler(BaseHTTPRequestHandler):
    response_builder: Callable[[Dict[str, Any]], Tuple[int, Dict[str, Any]]]
    received: List[Dict[str, Any]]

    def log_message(self, format: str, *args: Any) -> None:  # noqa: A002
        pass

    def _send(self, status: int, payload: Dict[str, Any]) -> None:
        data = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self) -> None:  # noqa: N802
        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(length).decode("utf-8")) if length else {}
        if self.path != "/dispatch":
            self._send(404, {"error": "not found"})
            return
        type(self).received.append(body)
        status, payload = type(self).response_builder(body)
        self._send(status, payload)


def _default_builder(body: Dict[str, Any]) -> Tuple[int, Dict[str, Any]]:
    return 200, {
        "session_id": body.get("shared_session_id"),
        "origin_body": body.get("origin_body"),
        "actor": body.get("provider_id"),
        "response": f"canned answer to: {body.get('player_input')}",
        "turn_id": 7,
    }


@pytest.fixture()
def fake_dispatch_server(monkeypatch):
    handler = type("_H", (_FakeDispatchHandler,), {})
    handler.received = []
    handler.response_builder = staticmethod(_default_builder)

    server = HTTPServer(("127.0.0.1", 0), handler)
    port = server.server_address[1]
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    base_url = f"http://127.0.0.1:{port}"
    monkeypatch.setenv("ENGAIN_PRESENCE_AUTHORITY_URL", base_url)
    try:
        yield base_url, handler
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def _prepared_adapter(tmp_path: Path) -> Tuple[HermesSessionAdapter, _RecordingDirector]:
    config = AdapterConfig(project_dir=tmp_path)
    adapter = HermesSessionAdapter(config, director_bridge=object())
    director = _RecordingDirector()
    adapter.director_bridge = director
    state_path = tmp_path / ".godot" / "engain_hermes_session.json"
    state_path.parent.mkdir(parents=True)
    state_path.write_text(json.dumps(_valid_session_state()))
    return adapter, director


# --- engain_continuity_client.py itself -----------------------------------


def test_client_sends_expected_fields_and_parses_response(fake_dispatch_server):
    base_url, handler = fake_dispatch_server
    result = engain_continuity_client.dispatch(
        shared_session_id="shared-x",
        origin_body="dragon_3d",
        player_input="hello there",
        provider_id="hermes",
        model_id="gpt-5.6-sol",
        provider_session_id=PERSISTED_SESSION_ID,
        agent_id="hermes",
        instance_id="dragon3d-123",
        launch_options={"provider": "openai-codex"},
        base_url=base_url,
        timeout=5.0,
    )
    assert len(handler.received) == 1
    sent = handler.received[0]
    assert sent["shared_session_id"] == "shared-x"
    assert sent["origin_body"] == "dragon_3d"
    assert sent["player_input"] == "hello there"
    assert sent["provider_id"] == "hermes"
    assert sent["provider_session_id"] == PERSISTED_SESSION_ID
    assert sent["agent_id"] == "hermes"
    assert sent["instance_id"] == "dragon3d-123"
    assert sent["launch_options"] == {"provider": "openai-codex"}
    assert result["response"] == "canned answer to: hello there"
    assert result["turn_id"] == 7


def test_client_raises_engain_continuity_error_on_non_200(fake_dispatch_server):
    base_url, handler = fake_dispatch_server
    handler.response_builder = staticmethod(
        lambda body: (409, {"error": "RESPONSE_ACTOR_MISMATCH", "detail": "x"})
    )
    with pytest.raises(engain_continuity_client.EngAinContinuityError) as excinfo:
        engain_continuity_client.dispatch(
            shared_session_id="shared-x",
            origin_body="dragon_3d",
            player_input="hi",
            provider_id="hermes",
            model_id="m",
            provider_session_id="s",
            base_url=base_url,
            timeout=5.0,
        )
    assert excinfo.value.code == "RESPONSE_ACTOR_MISMATCH"


def test_client_raises_when_server_unreachable():
    with pytest.raises(engain_continuity_client.EngAinContinuityError):
        engain_continuity_client.dispatch(
            shared_session_id="shared-x",
            origin_body="dragon_3d",
            player_input="hi",
            provider_id="hermes",
            model_id="m",
            provider_session_id="s",
            base_url="http://127.0.0.1:1",
            timeout=1.0,
        )


# --- HermesSessionAdapter's binding-field defaults/overrides --------------


def test_binding_fields_default_to_this_workers_frozen_hermes_identity(tmp_path, monkeypatch):
    monkeypatch.delenv("ENGAIN_CONTINUITY_PROVIDER_ID", raising=False)
    monkeypatch.delenv("ENGAIN_CONTINUITY_MODEL_ID", raising=False)
    monkeypatch.delenv("ENGAIN_CONTINUITY_PROVIDER_SESSION_ID", raising=False)
    monkeypatch.delenv("ENGAIN_CONTINUITY_LAUNCH_OPTIONS", raising=False)
    adapter, _director = _prepared_adapter(tmp_path)
    fields = adapter._engain_continuity_binding_fields()
    assert fields["provider_id"] == "hermes"
    assert fields["model_id"] == adapter.client.model
    assert fields["provider_session_id"] == adapter.client.session_id
    assert fields["launch_options"] == {"provider": adapter.client.provider}


def test_binding_fields_overridable_for_a_switched_provider(tmp_path, monkeypatch):
    monkeypatch.setenv("ENGAIN_CONTINUITY_PROVIDER_ID", "claude_code")
    monkeypatch.setenv("ENGAIN_CONTINUITY_MODEL_ID", "claude-x")
    monkeypatch.setenv("ENGAIN_CONTINUITY_PROVIDER_SESSION_ID", "claude-native-1")
    monkeypatch.setenv("ENGAIN_CONTINUITY_LAUNCH_OPTIONS", json.dumps({"foo": "bar"}))
    adapter, _director = _prepared_adapter(tmp_path)
    fields = adapter._engain_continuity_binding_fields()
    assert fields == {
        "provider_id": "claude_code",
        "model_id": "claude-x",
        "provider_session_id": "claude-native-1",
        "launch_options": {"foo": "bar"},
    }


def test_dispatch_via_engain_continuity_requires_shared_session_id(tmp_path, monkeypatch):
    monkeypatch.delenv("ENGAIN_CONTINUITY_SHARED_SESSION_ID", raising=False)
    adapter, _director = _prepared_adapter(tmp_path)
    validated = adapter._validate_request(_build_request(tmp_path), validation_time=CAPTURED_AT + 1.0)
    with pytest.raises(HermesAdapterError, match="ENGAIN_CONTINUITY_SHARED_SESSION_ID"):
        adapter._dispatch_via_engain_continuity(validated.player_input)


def test_engain_continuity_response_shape(tmp_path):
    adapter, _director = _prepared_adapter(tmp_path)
    validated = adapter._validate_request(_build_request(tmp_path), validation_time=CAPTURED_AT + 1.0)
    result = adapter._engain_continuity_response(
        {"actor": "claude_code", "response": "hi there", "turn_id": 3}, validated
    )
    assert result["narrative_response"] == "hi there"
    assert "claude_code" in result["director_analysis"]
    assert "3" in result["director_analysis"]
    assert result["action_type"] == "OBSERVATION"
    assert result["provider_session_ref"]["session_id"] == PERSISTED_SESSION_ID


# --- End-to-end through _process_claimed_request ---------------------------


def test_process_claimed_request_default_still_uses_director_bridge(tmp_path, monkeypatch):
    """Regression pin: ENGAIN_CONTINUITY_DISPATCH unset must leave today's
    behavior byte-for-byte unchanged."""
    monkeypatch.delenv("ENGAIN_CONTINUITY_DISPATCH", raising=False)
    monkeypatch.setenv(COMPAT_ENV, "1")
    adapter, director = _prepared_adapter(tmp_path)
    adapter.prepare()
    payload = _build_request(tmp_path)
    _retime_request(tmp_path, payload)
    adapter.config.request_file.write_bytes(json.dumps(payload).encode())

    completed = adapter.process_once()

    assert completed is True
    assert director.calls == 1


def test_process_claimed_request_uses_engain_continuity_when_enabled(
    tmp_path, monkeypatch, fake_dispatch_server
):
    base_url, handler = fake_dispatch_server
    monkeypatch.setenv(COMPAT_ENV, "1")  # this fake server doesn't implement register/claim
    monkeypatch.setenv("ENGAIN_CONTINUITY_DISPATCH", "1")
    monkeypatch.setenv("ENGAIN_CONTINUITY_SHARED_SESSION_ID", "shared-integration-test")
    adapter, director = _prepared_adapter(tmp_path)
    adapter.prepare()
    payload = _build_request(tmp_path)
    _retime_request(tmp_path, payload)
    adapter.config.request_file.write_bytes(json.dumps(payload).encode())

    completed = adapter.process_once()

    assert completed is True
    assert director.calls == 0  # the old direct-Hermes path was never touched
    assert len(handler.received) == 1
    assert handler.received[0]["shared_session_id"] == "shared-integration-test"
    assert handler.received[0]["origin_body"] == "dragon_3d"
    response = json.loads(adapter.config.response_file.read_text())
    assert response["narrative_response"].startswith("canned answer to:")
    assert "EngAIn shared continuity" in response["director_analysis"]


def test_pending_coordination_report_reaches_dispatch_and_is_marked_consumed(
    tmp_path, monkeypatch, fake_dispatch_server
):
    """A pending Editor coordination report combined with continuity
    dispatch is now a SUPPORTED combination (2026-09-12) — previously
    this refused outright with COORDINATION_UNSUPPORTED_ON_CONTINUITY_
    DISPATCH. Proves: (1) the report is sent to /dispatch as its own
    field, never folded into player_input; (2) a successful continuity
    turn marks the report delivered (moved to consumed/), not retried."""
    base_url, handler = fake_dispatch_server
    monkeypatch.setenv(COMPAT_ENV, "1")
    monkeypatch.setenv("ENGAIN_CONTINUITY_DISPATCH", "1")
    monkeypatch.setenv("ENGAIN_CONTINUITY_SHARED_SESSION_ID", "shared-coordination-test")
    adapter, director = _prepared_adapter(tmp_path)
    report_path = _write_editor_report(adapter.config, message_id="MSG_CONTINUITY_1")
    adapter.prepare()
    payload = _build_request(tmp_path)
    _retime_request(tmp_path, payload)
    adapter.config.request_file.write_bytes(json.dumps(payload).encode())

    completed = adapter.process_once()

    assert completed is True
    assert director.calls == 0
    assert len(handler.received) == 1
    sent = handler.received[0]
    assert sent["player_input"] == payload["player_input"]  # verbatim, unmodified
    assert sent["coordination_report"]["message_id"] == "MSG_CONTINUITY_1"
    assert sent["coordination_report"]["status"] == "applied"

    # Delivered on a successful turn -> moved to consumed/, not retried.
    assert not report_path.exists()
    consumed_path = adapter.config.coordination_consumed_dir / report_path.name
    assert consumed_path.exists()


def test_pending_coordination_report_dispatches_without_a_player_turn(
    tmp_path, monkeypatch, fake_dispatch_server
):
    """The exact gap the 2026-09-12 receipt named, now closed: Editor
    completion (a report landing in the coordination inbox) must not
    have to wait for a player to type something. Given a pending report
    and NO player request file at all, one process_once() poll — exactly
    what run()'s own `while True: process_once(); sleep(poll_seconds)`
    calls on a timer — dispatches it on its own."""
    base_url, handler = fake_dispatch_server
    monkeypatch.setenv(COMPAT_ENV, "1")
    monkeypatch.setenv("ENGAIN_CONTINUITY_DISPATCH", "1")
    monkeypatch.setenv("ENGAIN_CONTINUITY_SHARED_SESSION_ID", "shared-spontaneous-test")
    adapter, director = _prepared_adapter(tmp_path)
    report_path = _write_editor_report(adapter.config, message_id="MSG_SPONTANEOUS_1")
    adapter.prepare()
    # Deliberately NOT writing a request file -- no player turn exists.

    completed = adapter.process_once()

    assert completed is True
    assert director.calls == 0
    assert len(handler.received) == 1
    sent = handler.received[0]
    assert sent["player_input"] == ""
    assert sent["coordination_report"]["message_id"] == "MSG_SPONTANEOUS_1"
    assert sent["coordination_report"]["status"] == "applied"
    assert not adapter.config.response_file.exists()  # nothing in-game is left waiting

    assert not report_path.exists()
    consumed_path = adapter.config.coordination_consumed_dir / report_path.name
    assert consumed_path.exists()


def test_pending_coordination_report_stays_retryable_on_dispatch_failure(
    tmp_path, monkeypatch, fake_dispatch_server
):
    """Failure must not be silently dropped, and the SAME poll must not
    double-send: exactly one HTTP attempt per poll, and the report goes
    back to inbox/ at attempt+1 -- the same failure handling the
    player-turn path already has. A second poll then proves it is
    genuinely retryable, not stuck."""
    base_url, handler = fake_dispatch_server
    handler.response_builder = staticmethod(
        lambda body: (502, {"error": "PROVIDER_DISPATCH_FAILED"})
    )
    monkeypatch.setenv(COMPAT_ENV, "1")
    monkeypatch.setenv("ENGAIN_CONTINUITY_DISPATCH", "1")
    monkeypatch.setenv("ENGAIN_CONTINUITY_SHARED_SESSION_ID", "shared-spontaneous-fail-test")
    adapter, director = _prepared_adapter(tmp_path)
    report_path = _write_editor_report(adapter.config, message_id="MSG_SPONTANEOUS_FAIL")
    adapter.prepare()

    completed = adapter.process_once()

    assert completed is True
    assert len(handler.received) == 1  # exactly one attempt -- not double-sent
    assert not report_path.exists()  # moved, not left in place
    retried_path = (
        adapter.config.coordination_inbox_dir / "editor_report.MSG_SPONTANEOUS_FAIL.attempt1.json"
    )
    assert retried_path.exists()  # back in inbox/, retryable, attempt incremented
    assert not (adapter.config.coordination_consumed_dir / report_path.name).exists()

    handler.response_builder = staticmethod(_default_builder)
    completed_again = adapter.process_once()
    assert completed_again is True
    assert len(handler.received) == 2
    assert not retried_path.exists()
    assert (adapter.config.coordination_consumed_dir / retried_path.name).exists()


def _read_tool_events(config) -> list:
    events_dir = config.tool_events_dir
    if not events_dir.is_dir():
        return []
    events = []
    for path in sorted(events_dir.glob("*.json")):
        events.append(json.loads(path.read_text()))
    return events


def test_pending_coordination_report_publishes_tool_and_dragon_events(
    tmp_path, monkeypatch, fake_dispatch_server
):
    """The 2026-09-13 ask: Editor completion must show as [TOOL] in the
    live transcript, and Dragon's reaction to it must show as [DRAGON] --
    both via the separate, display-only tool_events channel, since this
    path writes no response.json at all (see
    _process_pending_coordination_report_without_player_turn()'s own
    doc for why response.json is the wrong channel here)."""
    base_url, handler = fake_dispatch_server
    handler.response_builder = staticmethod(
        lambda body: (200, {
            "session_id": body.get("shared_session_id"),
            "origin_body": body.get("origin_body"),
            "actor": body.get("provider_id"),
            "response": "The tower now stands ready.",
            "turn_id": 9,
        })
    )
    monkeypatch.setenv(COMPAT_ENV, "1")
    monkeypatch.setenv("ENGAIN_CONTINUITY_DISPATCH", "1")
    monkeypatch.setenv("ENGAIN_CONTINUITY_SHARED_SESSION_ID", "shared-tool-event-test")
    adapter, director = _prepared_adapter(tmp_path)
    _write_editor_report(adapter.config, message_id="MSG_TOOL_EVENT_1")
    adapter.prepare()

    completed = adapter.process_once()
    assert completed is True

    events = _read_tool_events(adapter.config)
    assert [e["kind"] for e in events] == ["tool", "dragon"]
    assert events[0]["text"].startswith("Proposal complete")
    assert "Modified 1 file(s)." in events[0]["text"]  # _write_editor_report()'s own execution_summary
    assert events[1]["text"] == "The tower now stands ready."


def test_pending_coordination_report_publishes_only_tool_event_on_dispatch_failure(
    tmp_path, monkeypatch, fake_dispatch_server
):
    """A [TOOL] line is honest regardless of delivery outcome -- the
    Editor's own work is a fact whether or not Dragon heard about it --
    but there must be no [DRAGON] line invented when there was no reply."""
    base_url, handler = fake_dispatch_server
    handler.response_builder = staticmethod(
        lambda body: (502, {"error": "PROVIDER_DISPATCH_FAILED"})
    )
    monkeypatch.setenv(COMPAT_ENV, "1")
    monkeypatch.setenv("ENGAIN_CONTINUITY_DISPATCH", "1")
    monkeypatch.setenv("ENGAIN_CONTINUITY_SHARED_SESSION_ID", "shared-tool-event-fail-test")
    adapter, director = _prepared_adapter(tmp_path)
    _write_editor_report(adapter.config, message_id="MSG_TOOL_EVENT_FAIL")
    adapter.prepare()

    completed = adapter.process_once()
    assert completed is True

    events = _read_tool_events(adapter.config)
    assert [e["kind"] for e in events] == ["tool"]
    assert events[0]["text"].startswith("Proposal complete")

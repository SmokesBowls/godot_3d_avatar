from __future__ import annotations

import copy
import importlib
import json
import os
from pathlib import Path
from types import ModuleType
from typing import Any, Callable

import pytest


SESSION_ID = "20260731_065008_63a62d"
REQUEST_A = "req_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1"
REQUEST_B = "req_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb2"
REQUEST_C = "req_ccccccccccccccccccccccccccccccc3"
REQUEST_M = "req_ddddddddddddddddddddddddddddddd4"
CLIENT_A = "dragon3d_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_1"
CLIENT_B = "dragon3d_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb_2"
CLIENT_C = "dragon3d_cccccccccccccccccccccccccccccccc_3"
CLIENT_M = "dragon3d_dddddddddddddddddddddddddddddddd_4"
CAPTURE_C = "cap_cccccccccccccccccccccccccccccccc_3"


def _module() -> ModuleType:
    return importlib.import_module("hermes_session_adapter")


@pytest.fixture(autouse=True)
def _forbid_real_provider(monkeypatch: pytest.MonkeyPatch) -> None:
    module = _module()

    def forbidden_provider(*_args: Any, **_kwargs: Any) -> Any:
        pytest.fail("Ticket 2E must not execute the Hermes provider")

    monkeypatch.setattr(module.HermesCLIClient, "_run_bounded", forbidden_provider)


def _state(module: ModuleType) -> dict[str, Any]:
    return {
        "profile": module.HERMES_PROFILE,
        "companion_ref": module.COMPANION_REF,
        "provider": module.FROZEN_PROVIDER,
        "model": module.FROZEN_MODEL,
        "session_id": module.PERSISTED_HERMES_B_SESSION_ID,
        "processed_request_ids": [],
    }


def _text_only(request_id: str, client_request_id: str, text: str) -> dict[str, Any]:
    return {
        "request_id": request_id,
        "player_input": text,
        "game_state": {},
        "timestamp": 1.0,
        "additional_context": {
            "client_request_id": client_request_id,
            "companion_ref": "hermes_b",
            "routing_mode": "text_only",
        },
    }


def _current_perception() -> dict[str, Any]:
    return {
        "request_id": REQUEST_C,
        "player_input": "Can you inspect the current player view?",
        "game_state": {},
        "timestamp": 1.1,
        "additional_context": {
            "client_request_id": CLIENT_C,
            "companion_ref": "hermes_b",
            "perception": {
                "schema": "engain.runtime_perception.v1",
                "perception_state": "unavailable",
                "capture_id": CAPTURE_C,
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
            },
        },
    }


class OfflineDirector:
    def __init__(self, module: ModuleType, adapter: Any) -> None:
        self.module = module
        self.adapter = adapter
        self.dispatches: list[dict[str, Any]] = []

    def process_player_input(self, text: str, _state: dict[str, Any]) -> dict[str, Any]:
        perception = self.adapter.client.pending_perception
        self.dispatches.append(
            {
                "text": text,
                "session_id": self.adapter.client.session_id,
                "route": "text_only" if perception is None else "current_perception",
            }
        )
        receipt = self.module.ProviderInvocationReceipt(
            session_id=SESSION_ID,
            response_sha256="0" * 64,
            narrative_response=f"Offline response {len(self.dispatches)}",
        )
        setattr(self.adapter.client, "_HermesCLIClient__pending_receipt", receipt)
        return {}


def _prepared_adapter(module: ModuleType, tmp_path: Path) -> tuple[Any, OfflineDirector]:
    config = module.AdapterConfig(project_dir=tmp_path, poll_seconds=0.001)
    config.state_file.parent.mkdir(parents=True, exist_ok=True)
    config.state_file.write_text(json.dumps(_state(module), indent=2) + "\n", encoding="utf-8")
    adapter = module.HermesSessionAdapter(config, director_bridge=object())
    director = OfflineDirector(module, adapter)
    adapter.director_bridge = director
    return adapter, director


def _run_main_lifecycle(
    module: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    adapter: Any,
    on_idle: Callable[[int], None],
) -> int:
    start_count = 0

    original_adapter_class = module.HermesSessionAdapter

    class AdapterFactory(original_adapter_class):
        def __new__(cls, _config: Any) -> Any:
            nonlocal start_count
            start_count += 1
            return adapter

        def __init__(self, _config: Any) -> None:
            pass

    monkeypatch.setattr(module, "HermesSessionAdapter", AdapterFactory)
    monkeypatch.setattr(module.os, "chdir", lambda _path: None)
    idle_count = 0

    def controlled_sleep(_seconds: float) -> None:
        nonlocal idle_count
        idle_count += 1
        on_idle(idle_count)

    monkeypatch.setattr(module.time, "sleep", controlled_sleep)
    result = module.main(["--project-dir", str(adapter.config.project_dir)])
    assert start_count == 1
    return result


def _publish(adapter: Any, payload: dict[str, Any]) -> None:
    assert not adapter.config.request_file.exists()
    adapter.config.request_file.write_text(json.dumps(payload), encoding="utf-8")


def _claim_response(adapter: Any) -> dict[str, Any]:
    response = json.loads(adapter.config.response_file.read_text(encoding="utf-8"))
    adapter.config.response_file.unlink()
    return response


def test_ticket2e_one_worker_processes_text_text_perception_and_survives_each(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    module = _module()
    adapter, director = _prepared_adapter(module, tmp_path)
    requests = [
        _text_only(REQUEST_A, CLIENT_A, "Remember our earlier conversation."),
        _text_only(REQUEST_B, CLIENT_B, "Continue that thought without looking."),
        _current_perception(),
    ]
    responses: list[dict[str, Any]] = []
    alive_after: list[bool] = []
    _publish(adapter, requests[0])

    def on_idle(cycle: int) -> None:
        responses.append(_claim_response(adapter))
        alive_after.append(True)
        assert not adapter.config.request_file.exists()
        if cycle < len(requests):
            _publish(adapter, requests[cycle])
            return
        raise KeyboardInterrupt

    assert _run_main_lifecycle(module, monkeypatch, adapter, on_idle) == 0
    assert [item["request_id"] for item in responses] == [REQUEST_A, REQUEST_B, REQUEST_C]
    assert [item["client_request_id"] for item in responses] == [CLIENT_A, CLIENT_B, CLIENT_C]
    assert [item["route"] for item in director.dispatches] == [
        "text_only",
        "text_only",
        "current_perception",
    ]
    assert len(director.dispatches) == 3
    assert {item["session_id"] for item in director.dispatches} == {SESSION_ID}
    assert alive_after == [True, True, True]
    assert adapter.processed_request_ids == [REQUEST_A, REQUEST_B, REQUEST_C]
    assert not adapter.config.request_file.exists()
    assert not adapter.config.response_file.exists()


def test_ticket2e_local_rejection_does_not_kill_worker_or_dispatch_provider(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    module = _module()
    adapter, director = _prepared_adapter(module, tmp_path)
    valid_a = _text_only(REQUEST_A, CLIENT_A, "First valid request.")
    malformed = _text_only(REQUEST_M, CLIENT_M, "Malformed request.")
    malformed["additional_context"]["routing_mode"] = "unknown"
    valid_b = _text_only(REQUEST_B, CLIENT_B, "Second valid request.")
    sequence = [valid_a, malformed, valid_b]
    responses: list[dict[str, Any]] = []
    _publish(adapter, sequence[0])

    def on_idle(cycle: int) -> None:
        responses.append(_claim_response(adapter))
        if cycle < len(sequence):
            _publish(adapter, sequence[cycle])
            return
        raise KeyboardInterrupt

    assert _run_main_lifecycle(module, monkeypatch, adapter, on_idle) == 0
    assert [item["request_id"] for item in responses] == [REQUEST_A, REQUEST_M, REQUEST_B]
    assert responses[1]["perception_result"]["failure_code"] == "SCHEMA_INVALID"
    assert len(director.dispatches) == 2
    assert [item["session_id"] for item in director.dispatches] == [SESSION_ID, SESSION_ID]
    assert adapter.processed_request_ids == [REQUEST_A, REQUEST_M, REQUEST_B]


def test_ticket2e_duplicate_request_is_exactly_once_and_worker_remains_alive(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    module = _module()
    adapter, director = _prepared_adapter(module, tmp_path)
    request = _text_only(REQUEST_A, CLIENT_A, "Process this exactly once.")
    _publish(adapter, request)
    duplicate_observed = False

    def on_idle(cycle: int) -> None:
        nonlocal duplicate_observed
        if cycle == 1:
            response = _claim_response(adapter)
            assert response["request_id"] == REQUEST_A
            _publish(adapter, copy.deepcopy(request))
            return
        assert not adapter.config.response_file.exists()
        duplicate_observed = True
        raise KeyboardInterrupt

    assert _run_main_lifecycle(module, monkeypatch, adapter, on_idle) == 0
    assert duplicate_observed is True
    assert len(director.dispatches) == 1
    assert adapter.processed_request_ids.count(REQUEST_A) == 1


def test_ticket2e_second_worker_fails_closed_while_first_retains_ownership(
    tmp_path: Path,
) -> None:
    module = _module()
    pid_file = tmp_path / ".godot" / "engain_hermes_adapter.pid"
    first = module.PidFileLock(pid_file)
    second = module.PidFileLock(pid_file)
    first.acquire()
    try:
        assert pid_file.read_text(encoding="utf-8") == f"{os.getpid()}\n"
        with pytest.raises(module.HermesAdapterError):
            second.acquire()
        assert first.acquired is True
        assert pid_file.read_text(encoding="utf-8") == f"{os.getpid()}\n"
    finally:
        first.release()
    assert not pid_file.exists()


def test_ticket2e_worker_exposes_explicit_stop_lifecycle_without_signal_injection(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    module = _module()
    adapter, director = _prepared_adapter(module, tmp_path)

    lifecycle_methods = {
        name
        for name in dir(adapter)
        if callable(getattr(adapter, name)) and name in {"request_stop", "stop", "shutdown"}
    }
    assert lifecycle_methods, "no explicit worker-stop behavior is exposed"
    stop = getattr(adapter, sorted(lifecycle_methods)[0])
    pid_file = Path(adapter.config.pid_file)
    request_after_stop = _text_only(
        REQUEST_A,
        CLIENT_A,
        "This request must not be admitted after stop was requested.",
    )
    observed_states: list[str] = []

    def on_idle(cycle: int) -> None:
        assert cycle == 1
        observed_states.append(adapter.worker_state)
        assert adapter.worker_state == "READY"
        assert pid_file.exists(), "ownership was released before authoritative service ended"
        stop()
        observed_states.append(adapter.worker_state)
        assert adapter.worker_state == "STOPPING"
        assert pid_file.exists(), "ownership was released during STOPPING"
        _publish(adapter, request_after_stop)

    assert _run_main_lifecycle(module, monkeypatch, adapter, on_idle) == 0
    observed_states.append(adapter.worker_state)

    assert observed_states == ["READY", "STOPPING", "STOPPED"]
    assert adapter.worker_state == "STOPPED"
    assert not pid_file.exists()
    assert adapter.config.request_file.exists()
    assert not adapter.config.response_file.exists()
    assert director.dispatches == []
    assert REQUEST_A not in adapter.processed_request_ids

    stop()
    assert adapter.worker_state == "STOPPED"
    assert adapter.process_once() is False
    assert adapter.config.request_file.exists()

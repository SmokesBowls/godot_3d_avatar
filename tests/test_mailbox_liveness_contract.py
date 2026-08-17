from __future__ import annotations

import json
from pathlib import Path

import pytest

import hermes_session_adapter as module


CALL_ID = "req_0123456789abcdef0123456789abcdef"


def _adapter(tmp_path: Path) -> module.HermesSessionAdapter:
    config = module.AdapterConfig(project_dir=tmp_path, mailbox_root=tmp_path / "runtime-mailboxes")
    return module.HermesSessionAdapter(config, director_bridge=object())


def _request(now: float) -> dict[str, object]:
    return {
        "call_id": CALL_ID,
        "expires_at": now + 185.0,
        "player_input": "hello",
        "game_state": {},
        "additional_context": {
            "client_request_id": "dragon3d_0123456789abcdef0123456789abcdef_1",
            "companion_ref": "hermes_b",
            "routing_mode": "text_only",
        },
        "timestamp": now,
        "request_id": CALL_ID,
    }


def test_3d_mailbox_is_caller_scoped(tmp_path: Path) -> None:
    adapter = _adapter(tmp_path)
    assert adapter.config.request_file == tmp_path / "runtime-mailboxes/dragon3d/request.json"
    assert adapter.config.response_file == tmp_path / "runtime-mailboxes/dragon3d/response.json"


def test_publication_rejects_immediately_without_live_listener(tmp_path: Path) -> None:
    adapter = _adapter(tmp_path)
    temporary = tmp_path / "request.tmp"
    temporary.write_text(json.dumps(_request(1000.0)))
    with pytest.raises(module.HermesAdapterError, match="LISTENER_ABSENT"):
        adapter.publish_request(temporary, now=1000.0)
    assert temporary.exists()
    assert not adapter.config.request_file.exists()


def test_busy_and_stale_are_distinct_and_stale_entry_is_removed(tmp_path: Path) -> None:
    adapter = _adapter(tmp_path)
    adapter.mark_listener_ready(now=1000.0)
    adapter.config.request_file.parent.mkdir(parents=True, exist_ok=True)
    adapter.config.request_file.write_text(json.dumps(_request(1000.0)))
    second = tmp_path / "second.tmp"
    second.write_text(json.dumps(_request(1001.0)))
    with pytest.raises(module.HermesAdapterError, match="MAILBOX_BUSY"):
        adapter.publish_request(second, now=1001.0)
    with pytest.raises(module.HermesAdapterError, match="MAILBOX_STALE"):
        adapter.publish_request(second, now=1200.0)
    assert not adapter.config.request_file.exists()


def test_request_requires_matching_call_id_and_future_expiry(tmp_path: Path) -> None:
    adapter = _adapter(tmp_path)
    payload = _request(1000.0)
    payload["call_id"] = "req_ffffffffffffffffffffffffffffffff"
    with pytest.raises(Exception, match="call_id"):
        adapter._validate_request(payload, validation_time=1000.0)
    payload = _request(1000.0)
    payload["expires_at"] = 999.0
    with pytest.raises(Exception, match="expired"):
        adapter._validate_request(payload, validation_time=1000.0)


def test_response_echoes_call_id(tmp_path: Path) -> None:
    adapter = _adapter(tmp_path)
    validated = adapter._validate_request(_request(1000.0), validation_time=1000.0)
    response = adapter._error_response("safe", validated.request_id, validated.client_request_id, call_id=validated.call_id)
    assert response["call_id"] == CALL_ID


def test_expired_processing_claim_is_cleared_as_stale(tmp_path: Path) -> None:
    adapter = _adapter(tmp_path)
    adapter.mark_listener_ready(now=1200.0)
    claimed = adapter.config.request_file.with_name(
        f".{adapter.config.request_file.name}.123.456.processing"
    )
    claimed.parent.mkdir(parents=True, exist_ok=True)
    claimed.write_text(json.dumps(_request(1000.0)))
    temporary = tmp_path / "next.tmp"
    temporary.write_text(json.dumps(_request(1200.0)))
    with pytest.raises(module.HermesAdapterError, match="MAILBOX_STALE"):
        adapter.publish_request(temporary, now=1200.0)
    assert not claimed.exists()

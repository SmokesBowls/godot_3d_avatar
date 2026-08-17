"""
Real integration tests for the presence-authority fail-closed behavior
added during operationalization (2026-08-16). Spawns the actual, unmodified
presence_authority_server.py from the EngAIn checkout as a real subprocess
on a scratch port — not a fake, not a mock of the HTTP contract — since
that is exactly what runtime_composition.py's SupervisedPresenceAuthority
does in production. conftest.py's autouse fixture defaults the rest of this
suite to compat mode; every test here explicitly controls the env var
itself instead, since fail-closed behavior is the thing under test.
"""

from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

import pytest

PROJECT_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT_ROOT))

from hermes_session_adapter import AdapterConfig, HermesAdapterError, HermesSessionAdapter
import presence_authority_client

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_hermes_session_adapter import _build_request, _retime_request, _valid_session_state  # noqa: E402

ENGAIN_AUTHORITY_SCRIPT = Path(
    os.environ.get(
        "ENGAIN_PRESENCE_AUTHORITY_SCRIPT_FOR_TESTS",
        "/home/mytruelove/Desktop/burdens_of_a_forgotten_past/EngAIn/"
        "tier1/engainos/server/presence_authority_server.py",
    )
)
COMPAT_ENV = "ENGAIN_PRESENCE_AUTHORITY_FAIL_OPEN_COMPAT"
PERSISTED_SESSION_ID = "20260731_065008_63a62d"


def _free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


@pytest.fixture()
def real_authority(monkeypatch):
    if not ENGAIN_AUTHORITY_SCRIPT.exists():
        pytest.skip(f"EngAIn presence authority script not found at {ENGAIN_AUTHORITY_SCRIPT}")
    port = _free_port()
    base_url = f"http://127.0.0.1:{port}"
    proc = subprocess.Popen(
        [sys.executable, str(ENGAIN_AUTHORITY_SCRIPT), "--port", str(port)],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    deadline = time.monotonic() + 10.0
    healthy = False
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(base_url + "/health", timeout=1.0) as resp:
                if resp.status == 200:
                    healthy = True
                    break
        except Exception:
            time.sleep(0.05)
    if not healthy:
        proc.terminate()
        pytest.fail("real presence authority subprocess did not become healthy")

    monkeypatch.setenv("ENGAIN_PRESENCE_AUTHORITY_URL", base_url)
    try:
        yield base_url
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()


class _RecordingDirector:
    """Minimal stand-in — this repo's test_hermes_session_adapter.py has a
    fuller version tied to its dynamic module-reload harness; these tests
    only need to know whether Hermes was ever actually reached."""

    def __init__(self) -> None:
        self.calls = 0

    def process_player_input(self, player_input: str, game_state: dict) -> dict:
        self.calls += 1
        return {"narrative_response": "should not have been reached"}


def _prepared_adapter(tmp_path: Path) -> tuple[HermesSessionAdapter, _RecordingDirector]:
    config = AdapterConfig(project_dir=tmp_path)
    adapter = HermesSessionAdapter(config, director_bridge=object())
    director = _RecordingDirector()
    adapter.director_bridge = director
    state_path = tmp_path / ".godot" / "engain_hermes_session.json"
    state_path.parent.mkdir(parents=True)
    state_path.write_text(json.dumps(_valid_session_state()))
    return adapter, director


def test_prepare_fails_closed_when_authority_unreachable_and_compat_disabled(tmp_path, monkeypatch):
    monkeypatch.delenv(COMPAT_ENV, raising=False)
    monkeypatch.setenv("ENGAIN_PRESENCE_AUTHORITY_URL", "http://127.0.0.1:1")
    adapter, _director = _prepared_adapter(tmp_path)
    with pytest.raises(HermesAdapterError, match="PRESENCE_AUTHORITY_UNAVAILABLE"):
        adapter.prepare()


def test_prepare_succeeds_when_authority_unreachable_and_compat_enabled(tmp_path, monkeypatch):
    monkeypatch.setenv(COMPAT_ENV, "1")
    monkeypatch.setenv("ENGAIN_PRESENCE_AUTHORITY_URL", "http://127.0.0.1:1")
    adapter, _director = _prepared_adapter(tmp_path)
    adapter.prepare()  # must not raise


def test_dispatch_never_reaches_hermes_when_authority_dies_between_register_and_claim(
    tmp_path, real_authority, monkeypatch
):
    """Step 7's exact scenario: available at REGISTER, gone by CLAIM.
    Neither worker may quietly continue into Hermes after losing contact
    with the mutex owner."""
    monkeypatch.delenv(COMPAT_ENV, raising=False)
    adapter, director = _prepared_adapter(tmp_path)
    adapter.prepare()  # succeeds — the real authority subprocess is up

    monkeypatch.setenv("ENGAIN_PRESENCE_AUTHORITY_URL", "http://127.0.0.1:1")  # standing in for "authority died"

    payload = _build_request(tmp_path)
    _retime_request(tmp_path, payload)
    adapter.config.request_file.write_bytes(json.dumps(payload).encode())

    completed = adapter.process_once()

    assert completed is True
    assert director.calls == 0
    response = json.loads(adapter.config.response_file.read_text())
    assert response["perception_result"]["failure_code"] == "PRESENCE_AUTHORITY_UNAVAILABLE"


def test_dispatch_is_rejected_with_session_occupied_against_a_real_competing_claim(tmp_path, real_authority):
    adapter, director = _prepared_adapter(tmp_path)
    adapter.prepare()

    presence_authority_client.claim(
        session_id=PERSISTED_SESSION_ID,
        agent_id="hermes",
        instance_id="a-different-worker-entirely",
        lease_seconds=30.0,
        base_url=real_authority,
    )

    payload = _build_request(tmp_path)
    _retime_request(tmp_path, payload)
    adapter.config.request_file.write_bytes(json.dumps(payload).encode())

    completed = adapter.process_once()

    assert completed is True
    assert director.calls == 0
    response = json.loads(adapter.config.response_file.read_text())
    assert response["perception_result"]["failure_code"] == "SESSION_OCCUPIED"

"""
engain_continuity_client.py - stdlib-only HTTP client for the shared
EngAIn continuity/dispatch authority (POST /dispatch on the same server
presence_authority_client.py already talks to).

Vendored deliberately, same reasoning as presence_authority_client.py: this
repo has no dependency relationship with the EngAIn tier1/tier2 package
tree. In particular, SharedSessionBridge, ContinuityCursorTracker, and
ContinuityContextBuilder are NOT imported or copied here — EngAIn is the
sole continuity authority; this client only carries bytes to it and back.
A second, private copy of those classes running inside this process would
have its own Ledger and cursor state that the 3D avatar's worker (a
different OS process, in godot_engain_3d_avatar) could never see or agree
with — the same "two truths" mistake presence_authority_client.py's own
docstring already describes for PresenceRegistry, one level up the stack.

Why this exists: hermes_session_adapter.py's own dispatch (director_bridge
.process_player_input(), still the default) talks to this worker's own
frozen native Hermes session directly and has no way to recall anything
that happened through a different provider or a different avatar body.
dispatch() here submits a bare player_input plus this worker's own
ProviderSessionBinding fields to EngAIn's central Ledger/cursor instead,
and gets back whatever EngAIn decides should have been said — built from
the shared history, dispatched through whichever provider is actually
named in the call, never reconstructed locally.
"""

from __future__ import annotations

import json
import os
import urllib.error
import urllib.request
from typing import Any, Dict, Optional, Tuple

_FALLBACK_BASE_URL = "http://127.0.0.1:8767"


def _default_base_url() -> str:
    """Read fresh on every call, not bound once at import time — same
    reasoning as presence_authority_client._default_base_url()."""
    return os.environ.get("ENGAIN_PRESENCE_AUTHORITY_URL", _FALLBACK_BASE_URL)


class EngAinContinuityError(RuntimeError):
    """The continuity authority was unreachable, rejected the request, or
    the dispatch it attempted failed. `code` is the server's own `error`
    field (MISSING_FIELDS, UNKNOWN_PROVIDER, PROVIDER_NOT_REGISTERED,
    RESPONSE_ACTOR_MISMATCH, PROVIDER_DISPATCH_FAILED, or None if the
    server itself was unreachable) — callers map this to their own
    player-facing failure_code rather than this client deciding one."""

    def __init__(self, message: str, code: Optional[str] = None) -> None:
        self.code = code
        super().__init__(message)


def _post(path: str, payload: Dict[str, Any], base_url: str, timeout: float) -> Tuple[int, Dict[str, Any]]:
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        base_url + path, data=data, method="POST", headers={"Content-Type": "application/json"}
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        return exc.code, json.loads(exc.read().decode("utf-8"))
    except (urllib.error.URLError, TimeoutError, ConnectionError, OSError, ValueError) as exc:
        raise EngAinContinuityError(f"POST {path} unreachable: {exc}") from exc


def dispatch(
    shared_session_id: str,
    origin_body: str,
    player_input: str,
    provider_id: str,
    model_id: str,
    provider_session_id: str,
    *,
    agent_id: Optional[str] = None,
    instance_id: Optional[str] = None,
    launch_options: Optional[Dict[str, Any]] = None,
    snapshot: Optional[Dict[str, Any]] = None,
    base_url: Optional[str] = None,
    timeout: float = 90.0,
) -> Dict[str, Any]:
    """Submits one bare request plus this worker's own ProviderSessionBinding
    fields to EngAIn's /dispatch. Returns SharedSessionBridge.handle_turn()'s
    own shape unmodified: {"session_id", "origin_body", "actor", "response",
    "turn_id"}. Raises EngAinContinuityError on any non-200 response or on
    an unreachable server — never returns a partial or guessed result."""
    base_url = base_url or _default_base_url()
    payload: Dict[str, Any] = {
        "shared_session_id": shared_session_id,
        "origin_body": origin_body,
        "player_input": player_input,
        "provider_id": provider_id,
        "model_id": model_id,
        "provider_session_id": provider_session_id,
    }
    if agent_id is not None:
        payload["agent_id"] = agent_id
    if instance_id is not None:
        payload["instance_id"] = instance_id
    if launch_options is not None:
        payload["launch_options"] = launch_options
    if snapshot is not None:
        payload["snapshot"] = snapshot

    status, body = _post("/dispatch", payload, base_url, timeout)
    if status != 200:
        raise EngAinContinuityError(
            f"dispatch failed: HTTP {status} {body}", code=body.get("error") if isinstance(body, dict) else None
        )
    return body

"""
presence_authority_client.py - stdlib-only HTTP client for the shared
EngAIn presence authority server.

Vendored deliberately, not imported from tier1.engainos: this repo has no
dependency relationship with the EngAIn tier1/tier2 package tree and
shouldn't gain a cross-repo Python import just for this. The server lives
at tier1/engainos/server/presence_authority_server.py in
burdens_of_a_forgotten_past/EngAIn and is started separately.

Why this exists: hermes_session_adapter.py used to have no way to know
whether a different worker process (the 3D avatar's own
hermes_session_adapter.py, in godot_engain_3d_avatar) was concurrently
talking to the same live, shared Hermes session. Both workers can invoke
`hermes chat --resume <same session_id>` at once with nothing stopping
them. This client is how a worker asks the one shared authority "is anyone
else currently claiming this session" before it dispatches, instead of
racing blind.
"""

from __future__ import annotations

import json
import os
import urllib.error
import urllib.request
from typing import Any, Dict, List, Optional, Tuple

_FALLBACK_BASE_URL = "http://127.0.0.1:8767"


def _default_base_url() -> str:
    """Read fresh on every call, not bound once at import time — a value
    fixed at import can never observe a later os.environ change (e.g. a
    test's monkeypatch.setenv, or a supervisor setting it before spawning
    a worker), which is exactly the bug this function exists to avoid."""
    return os.environ.get("ENGAIN_PRESENCE_AUTHORITY_URL", _FALLBACK_BASE_URL)


class PresenceAuthorityError(RuntimeError):
    """The authority was unreachable, or returned something unexpected.
    Callers should treat this as "cannot verify" and decide their own
    fail-open/fail-closed policy — this client does not decide that."""


class SessionOccupied(PresenceAuthorityError):
    """A genuine, real competing claim exists right now. Distinct from
    PresenceAuthorityError's "cannot verify" meaning: this means we asked,
    got a clear answer, and the answer was no."""

    def __init__(self, current_agent_id: str, current_instance_id: str, claim_expires_at: float):
        self.current_agent_id = current_agent_id
        self.current_instance_id = current_instance_id
        self.claim_expires_at = claim_expires_at
        super().__init__(
            f"SESSION_OCCUPIED: held by agent_id={current_agent_id!r} "
            f"instance_id={current_instance_id!r} until {claim_expires_at}"
        )


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
        raise PresenceAuthorityError(f"POST {path} unreachable: {exc}") from exc


def register(
    agent_id: str,
    instance_id: str,
    session_id: str,
    capabilities: Optional[List[str]] = None,
    endpoint: Optional[str] = None,
    requested_lease: float = 300.0,
    base_url: Optional[str] = None,
    timeout: float = 5.0,
) -> Dict[str, Any]:
    base_url = base_url or _default_base_url()
    status, body = _post(
        "/presence/register",
        {
            "agent_id": agent_id,
            "instance_id": instance_id,
            "session_id": session_id,
            "capabilities": capabilities or [],
            "endpoint": endpoint,
            "requested_lease": requested_lease,
        },
        base_url,
        timeout,
    )
    if status != 200:
        raise PresenceAuthorityError(f"register failed: HTTP {status} {body}")
    return body


def claim(
    session_id: str,
    agent_id: str,
    instance_id: str,
    lease_seconds: float = 200.0,
    base_url: Optional[str] = None,
    timeout: float = 5.0,
) -> Dict[str, Any]:
    base_url = base_url or _default_base_url()
    status, body = _post(
        "/claim",
        {"session_id": session_id, "agent_id": agent_id, "instance_id": instance_id, "lease_seconds": lease_seconds},
        base_url,
        timeout,
    )
    if status == 409:
        raise SessionOccupied(body["current_agent_id"], body["current_instance_id"], body["claim_expires_at"])
    if status != 200:
        raise PresenceAuthorityError(f"claim failed: HTTP {status} {body}")
    return body


def release(
    session_id: str,
    claim_token: str,
    base_url: Optional[str] = None,
    timeout: float = 5.0,
) -> bool:
    base_url = base_url or _default_base_url()
    status, body = _post("/release", {"session_id": session_id, "claim_token": claim_token}, base_url, timeout)
    if status != 200:
        raise PresenceAuthorityError(f"release failed: HTTP {status} {body}")
    return bool(body["released"])

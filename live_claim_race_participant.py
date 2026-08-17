#!/usr/bin/env python3
"""
live_claim_race_participant.py - 2D worker's side of the real cross-process
claim race proof.

Uses this repo's actual vendored presence_authority_client.py — the same
module hermes_session_adapter.py's _acquire_dispatch_claim() /
_release_dispatch_claim() call — against the real frozen session_id both
avatar repos share. Run as a genuinely separate OS process from
godot_engain_3d_avatar's equivalent script, launched at nearly the same
moment, to prove the mutex holds across real process boundaries, not just
across two objects in one test process.

PERSISTED_HERMES_B_SESSION_ID is hardcoded here to the same literal value as
hermes_session_adapter.py's own constant, rather than importing that module,
to avoid pulling in its full dependency chain (engain_dolphin, etc.) for a
script that only needs the one constant.
"""
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import presence_authority_client

PERSISTED_HERMES_B_SESSION_ID = "20260731_065008_63a62d"
INSTANCE_ID = f"dragon3d-{os.getpid()}"
HOLD_SECONDS = float(sys.argv[1]) if len(sys.argv) > 1 else 1.5

try:
    result = presence_authority_client.claim(
        session_id=PERSISTED_HERMES_B_SESSION_ID,
        agent_id="hermes",
        instance_id=INSTANCE_ID,
        lease_seconds=10.0,
    )
    print(json.dumps({"instance_id": INSTANCE_ID, "outcome": "CLAIMED", "claim_token": result["claim_token"]}), flush=True)
    time.sleep(HOLD_SECONDS)  # standing in for real Hermes dispatch in flight
    released = presence_authority_client.release(PERSISTED_HERMES_B_SESSION_ID, result["claim_token"])
    print(json.dumps({"instance_id": INSTANCE_ID, "outcome": "RELEASED", "released": released}), flush=True)
except presence_authority_client.SessionOccupied as exc:
    print(json.dumps({
        "instance_id": INSTANCE_ID,
        "outcome": "SESSION_OCCUPIED",
        "current_agent_id": exc.current_agent_id,
        "current_instance_id": exc.current_instance_id,
    }), flush=True)

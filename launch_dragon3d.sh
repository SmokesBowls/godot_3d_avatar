#!/usr/bin/env bash
# launch_dragon3d.sh — the canonical way to start the dragon_3d avatar.
#
# This is the ONLY supported entrypoint for running the real Godot 3D
# avatar. Launching `godot --path ...` directly skips runtime_composition.py
# entirely, which means the presence authority and the Hermes mailbox
# worker never start — every request will fail with
# `LISTENER_ABSENT: no live mailbox worker` even though Godot itself looks
# fine. See full-audit repo `08-17-2026-*` for the diagnosis. Use this
# script instead, every time.
#
# Does nothing but resolve real paths and hand off to the existing,
# already-tested runtime_composition.py CLI — no new supervision logic
# lives here, and ENGAIN_CONTINUITY_DISPATCH is left exactly as inherited
# from the caller's environment (unset by default), never forced on.
set -euo pipefail

# Resolve this script's own real location, not the caller's cwd, so it
# works no matter where it's invoked from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PROJECT_DIR="$SCRIPT_DIR"

# The canonical EngAIn checkout that owns presence_authority_server.py.
# Overridable via ENGAIN_REPO_ROOT for anyone working from a different
# checkout location; defaults to this project's known canonical path.
ENGAIN_REPO_ROOT="${ENGAIN_REPO_ROOT:-/home/mytruelove/Desktop/burdens_of_a_forgotten_past/EngAIn}"
PRESENCE_AUTHORITY_SCRIPT="$ENGAIN_REPO_ROOT/tier1/engainos/server/presence_authority_server.py"

if [[ ! -f "$PRESENCE_AUTHORITY_SCRIPT" ]]; then
    echo "launch_dragon3d.sh: presence authority script not found at $PRESENCE_AUTHORITY_SCRIPT" >&2
    echo "  (set ENGAIN_REPO_ROOT if the EngAIn checkout lives somewhere else)" >&2
    exit 1
fi

GODOT_COMMAND="${GODOT_COMMAND:-godot}"
if ! command -v "$GODOT_COMMAND" >/dev/null 2>&1; then
    echo "launch_dragon3d.sh: '$GODOT_COMMAND' not found on PATH" >&2
    exit 1
fi

# exec (not a plain call) so this process's PID becomes
# runtime_composition.py's PID directly — no intermediate shell left to
# forward signals through, and $? below never runs because exec never
# returns on success. runtime_composition.py's own main() already returns
# Godot's real exit code via SystemExit, so this script's exit code is
# that exit code, unmodified.
exec python3 "$SCRIPT_DIR/runtime_composition.py" \
    --godot-command "$GODOT_COMMAND" \
    --project-dir "$PROJECT_DIR" \
    --presence-authority-script "$PRESENCE_AUTHORITY_SCRIPT"

#!/usr/bin/env bash
# launch_dragon3d.sh — canonical 3D Dragon development session.
#
# One invocation opens two sibling views of the same project:
#
#   Godot editor (--editor)             existing composed runtime
#     -> Hermes Editor Dragon              -> presence authority
#     -> inspect/build the project          -> Hermes mailbox worker
#                                            -> live 3D game
#
# A bare `godot --path ...` remains unsupported for the real 3D runtime:
# it skips runtime_composition.py, so the presence authority and mailbox
# worker never start and runtime requests correctly fail LISTENER_ABSENT.
# The editor is a sidecar only; it does not start, duplicate, or own any
# EngAIn runtime service.
#
# Lifecycle contract:
# - this launcher owns the two exact child PIDs it starts;
# - closing either sibling manually leaves the other running;
# - the launcher exits only after both siblings have exited;
# - Ctrl+C/SIGTERM to the launcher terminates and reaps the composed
#   runtime first (allowing its existing ordered cleanup), then the editor;
# - if composition startup fails, the editor remains available, and the
#   launcher's eventual status preserves the runtime failure code.
#
# Do not press Play/F6 to create the authoritative Dragon runtime. The
# already-open composed runtime is the live body; editor Play would create
# a separate bare game process without the composed services.
set -euo pipefail

# Resolve this script's own real location, not the caller's cwd, so it
# works no matter where it is invoked from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PROJECT_DIR="$SCRIPT_DIR"

# The canonical EngAIn checkout that owns presence_authority_server.py.
# Overridable for another checkout without changing this launcher.
ENGAIN_REPO_ROOT="${ENGAIN_REPO_ROOT:-/home/mytruelove/Desktop/burdens_of_a_forgotten_past/EngAIn}"
PRESENCE_AUTHORITY_SCRIPT="$ENGAIN_REPO_ROOT/tier1/engainos/server/presence_authority_server.py"

if [[ ! -f "$PRESENCE_AUTHORITY_SCRIPT" ]]; then
    echo "launch_dragon3d.sh: presence authority script not found at $PRESENCE_AUTHORITY_SCRIPT" >&2
    echo "  (set ENGAIN_REPO_ROOT if the EngAIn checkout lives somewhere else)" >&2
    exit 1
fi

GODOT_COMMAND="${GODOT_COMMAND:-godot}"
PYTHON_COMMAND="${PYTHON_COMMAND:-python3}"
if ! command -v "$GODOT_COMMAND" >/dev/null 2>&1; then
    echo "launch_dragon3d.sh: '$GODOT_COMMAND' not found on PATH" >&2
    exit 1
fi
if ! command -v "$PYTHON_COMMAND" >/dev/null 2>&1; then
    echo "launch_dragon3d.sh: '$PYTHON_COMMAND' not found on PATH" >&2
    exit 1
fi

EDITOR_PID=""
RUNTIME_PID=""

shutdown_session() {
    local exit_code="$1"
    # Prevent a second signal from interrupting the ordered cleanup.
    trap - INT TERM

    # runtime_composition.py already owns the fail-closed shutdown order
    # within the runtime branch. Let that exact child finish first before
    # closing the independent editor sidecar.
    if [[ -n "$RUNTIME_PID" ]] && kill -0 "$RUNTIME_PID" 2>/dev/null; then
        kill -TERM "$RUNTIME_PID" 2>/dev/null || true
    fi
    if [[ -n "$RUNTIME_PID" ]]; then
        wait "$RUNTIME_PID" 2>/dev/null || true
    fi

    if [[ -n "$EDITOR_PID" ]] && kill -0 "$EDITOR_PID" 2>/dev/null; then
        kill -TERM "$EDITOR_PID" 2>/dev/null || true
    fi
    if [[ -n "$EDITOR_PID" ]]; then
        wait "$EDITOR_PID" 2>/dev/null || true
    fi

    exit "$exit_code"
}

trap 'shutdown_session 130' INT
trap 'shutdown_session 143' TERM

# Editor sidecar: same project root, normal editor mode, no runtime service
# flags. The enabled Hermes Editor addon therefore receives this project's
# res:// root while creating no authority or mailbox worker of its own.
"$GODOT_COMMAND" --editor --path "$PROJECT_DIR" &
EDITOR_PID=$!

# Existing composed-runtime path, unchanged in authority. It remains the
# only branch that starts EngAIn services and the live non-editor game.
"$PYTHON_COMMAND" "$SCRIPT_DIR/runtime_composition.py" \
    --godot-command "$GODOT_COMMAND" \
    --project-dir "$PROJECT_DIR" \
    --presence-authority-script "$PRESENCE_AUTHORITY_SCRIPT" &
RUNTIME_PID=$!

# Sibling independence is intentional: wait for both even if either one
# closes or fails first. Bash reaps completed background jobs while keeping
# their statuses available to these explicit waits.
set +e
wait "$EDITOR_PID"
EDITOR_STATUS=$?
wait "$RUNTIME_PID"
RUNTIME_STATUS=$?
set -e

# Runtime failure has priority because it means the authoritative live body
# or its fail-closed services did not start/finish successfully. Otherwise
# preserve any editor failure; zero means both ended normally.
if [[ "$RUNTIME_STATUS" -ne 0 ]]; then
    exit "$RUNTIME_STATUS"
fi
exit "$EDITOR_STATUS"

#!/usr/bin/env bash
# Request that the canonical development launcher replace only its owned
# composed-runtime child. This script never starts runtime services itself.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
LAUNCHER_PID="${DRAGON3D_LAUNCHER_PID:-}"
LAUNCHER_PROJECT="${DRAGON3D_PROJECT_DIR:-}"

if [[ "$LAUNCHER_PROJECT" != "$SCRIPT_DIR" ]]; then
    echo "restart_dragon3d_runtime.sh: this editor was not opened by this project's canonical launcher" >&2
    echo "  start with: $SCRIPT_DIR/launch_dragon3d.sh" >&2
    exit 2
fi

if [[ ! "$LAUNCHER_PID" =~ ^[0-9]+$ ]] || [[ "$LAUNCHER_PID" -le 1 ]]; then
    echo "restart_dragon3d_runtime.sh: canonical launcher identity is unavailable" >&2
    echo "  start with: $SCRIPT_DIR/launch_dragon3d.sh" >&2
    exit 2
fi

if [[ ! -r "/proc/$LAUNCHER_PID/cmdline" ]]; then
    echo "restart_dragon3d_runtime.sh: canonical launcher process is no longer running" >&2
    exit 3
fi

LAUNCHER_COMMAND="$(tr '\0' ' ' < "/proc/$LAUNCHER_PID/cmdline")"
if [[ "$LAUNCHER_COMMAND" != *"launch_dragon3d.sh"* ]]; then
    echo "restart_dragon3d_runtime.sh: inherited PID does not identify launch_dragon3d.sh" >&2
    exit 3
fi

kill -USR1 "$LAUNCHER_PID"
echo "Restart request sent to canonical composed-runtime launcher."

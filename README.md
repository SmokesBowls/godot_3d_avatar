# godot_3d_avatar

## Canonical development launch

Run:

```bash
./launch_dragon3d.sh
```

One invocation opens two sibling views of this project at the same time:

```text
launch_dragon3d.sh
    ├── Godot editor (`--editor`)
    │     └── Hermes Editor Dragon
    └── existing `runtime_composition.py`
          ├── presence authority
          ├── Hermes runtime mailbox worker
          └── live 3D game
```

The editor is a sidecar. It does not start or duplicate EngAIn runtime
services. The composed runtime remains the authoritative live Dragon body.
Do not press Play/F6 expecting another authoritative runtime: that creates a
bare game process without the composed services, and mailbox submission from
it correctly fails `LISTENER_ABSENT`.

### Lifecycle

- Closing only the editor leaves the composed runtime running.
- Closing only the game/runtime leaves the editor running.
- The launcher remains alive until both siblings have closed.
- Ctrl+C or SIGTERM sent to the launcher cleanly terminates and reaps the
  composed runtime first, then the editor.
- If runtime composition fails to start, the editor remains available; after
  the editor closes, the launcher returns the runtime failure status.

A bare `godot --path .` is not the canonical runtime launch because it skips
`runtime_composition.py` and its fail-closed readiness path.

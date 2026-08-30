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
- After saving an edit, use **Restart Composed Runtime** in the Hermes editor
  dock. It asks the still-running launcher to replace only its owned runtime
  branch; the editor and native Hermes Editor session remain open.
- The restart control also works after the runtime window has already closed.
  It fails closed if this editor was not opened by `launch_dragon3d.sh`.
- Ctrl+C or SIGTERM sent to the launcher cleanly terminates and reaps the
  composed runtime first, then the editor.
- If runtime composition fails to start, the editor remains available; after
  the editor closes, the launcher returns the runtime failure status.

A bare `godot --path .` is not the canonical runtime launch because it skips
`runtime_composition.py` and its fail-closed readiness path. Play/F6 remains a
bare preview path; use **Restart Composed Runtime** for the authoritative edit,
save, and rerun loop.

## Scene-understanding channels

The Runtime Dragon and Editor `@tool` lane provide independent evidence:

```text
@dragon -> current rendered pixels -> visual/perceptual truth
@tool   -> scene + correlated runtime artifacts -> structural/runtime truth
EngAIn  -> compares the independently obtained observations
```

The evidence boundary, `VIOLET-7319` baseline, Editor session-continuity
observation, and blind-relocation freshness test are documented in
[`DRAGON_SCENE_UNDERSTANDING_CHANNELS.md`](DRAGON_SCENE_UNDERSTANDING_CHANNELS.md).

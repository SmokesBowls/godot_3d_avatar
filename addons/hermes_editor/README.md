# Hermes Editor (First Milestone)

A real Hermes agent seated inside the Godot editor. This is the "editor
Dragon" — the third embodiment alongside the 2D and 3D runtime dragons —
built as a clean-start addon, using `addons/godot_ollama_task_performer/`
only as the reference for *how to make the seat* (bottom-dock
registration pattern), not as an architectural template. Nothing here
inherits that addon's operation allowlist, JSON command contract, or
read-only sandboxing — Hermes keeps its own native tool-calling (file
read/write, shell, search, tests), exactly as it has outside the editor.

## First milestone scope — what this proves and what it doesn't

```text
Godot Editor
    ↓
Hermes bottom dock
    ↓
real Hermes agent process
    ↓
cwd = current Godot project
    ↓
type message
    ↓
Hermes answers in dock
```

That, and only that. Deliberately **not** done in this pass:

- **EngAIn shared continuity (`:8767`)** — this dock talks to Hermes
  directly, the same way `hermes_session_adapter.py` does for the 2D/3D
  bodies' default path. Wiring the editor Dragon into
  `presence_authority_server.py`'s `/dispatch` (so it shares one
  `shared_session_id` with the other two bodies) is the deliberate next
  step, postponed until this milestone is proven by hand.
- **Hermes coding-tool exposure beyond what Hermes already does on its
  own** — there is no operation registry here at all, so this isn't
  "exposing" tools the way the Ollama addon did; Hermes simply has
  whatever it always has (file/shell/search/test) because nothing
  constrains it.

**What is NOT proven by this repo's own test suite**: that Hermes
actually sits inside a real, running Godot editor and can inspect/edit
the real project. That requires a human: enable the plugin, open the
"Hermes" bottom dock, type a message, confirm a real reply arrives. The
logic this addon's own code is responsible for (command construction,
output parsing, safe message delivery — see `test_hermes_bridge_logic.gd`)
is covered by a real, executed test; the editor-embedded, live-Hermes
part is not, and should not be reported as proven until someone does
that by hand.

## Security note — read before changing how a message reaches Hermes

`OS.execute()` in this Godot build performs its own shell-style
expansion (`$VAR`, `` `cmd` ``, `$(cmd)`) on **every element of its
`arguments` array**, before the target process ever runs. Verified
directly during this addon's own development, not assumed: a literal
`$HOME` argument came back substituted, and a literal backtick-wrapped
command was actually *executed*. That makes passing a player-typed
message straight through as a CLI argument a real command-injection
vector — not a theoretical one — and no amount of manual shell-quoting
on this addon's own side fixes it, because Godot's expansion happens on
the raw argument string *before* any bash of ours ever sees it.

The fix, implemented in `hermes_bridge.gd` and proven by
`test_hermes_bridge_logic.gd`'s end-to-end adversarial test: the
message never enters `OS.execute()`'s `arguments` array. It's written
to a plain temp file (`FileAccess` — no shell involvement, file content
is never touched by the expansion pass). A wrapper script — built
entirely from plugin-controlled strings (cwd, hermes path, temp paths;
never the message) — reads that file via `cat` inside its own single,
real bash parse. `OS.execute()` then runs *that script* with an
**empty** arguments array, so there is nothing left for Godot's own
expansion to find.

If this bridge is ever rewritten to pass content through `OS.execute()`
differently, re-run (or extend) `test_hermes_bridge_logic.gd`'s
adversarial check before trusting it.

## Known limitations

- **Stop doesn't kill the process.** There is no cooperative
  cancellation for a synchronous `OS.execute()` call, and no PID is
  exposed to signal. "Stop" discards the eventual reply when it
  arrives; the underlying `hermes` subprocess runs to completion
  regardless. Same honesty convention as the sibling addon's own
  `run_scene` "proof-of-launch only" limitation.
- **Linux-only as written.** The temp-file/wrapper-script approach uses
  `/bin/bash` explicitly. A Windows build of this dock would need a
  separate code path — not exercised anywhere in this project.
- **No native `cwd` parameter exists on Godot's `OS.execute()`/
  `OS.create_process()`** in this engine version (confirmed by
  enumerating `OS`'s own method list at runtime) — the wrapper script's
  own `cd` is the only way this addon achieves the right working
  directory for Hermes's file/shell tools.
- **No streaming.** Each turn is one blocking `hermes chat -Q -q "..."`
  call in a background thread; there is no live token-by-token display.

## Installation

Same as the sibling addon: place at `res://addons/hermes_editor/`, then
**Project > Project Settings > Plugins**, enable "Hermes Editor". A
"Hermes" dock appears in the bottom panel.

## Verifying the fix independently

```bash
cd <this project's root>
godot --headless --check-only -s addons/hermes_editor/<any .gd file>   # syntax
godot --headless -s addons/hermes_editor/test_hermes_bridge_logic.gd   # real, executed logic + injection-safety proof
```

Neither of those opens the editor UI or calls a real Hermes/LLM — they
prove the plumbing, not the seat itself.

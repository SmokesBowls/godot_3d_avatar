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

**Live-editor milestone: PROVEN, by hand, 2026-08-21.** The plugin
loads in a real Godot editor session, the "Hermes" dock appears, a real
Hermes session starts, and a real reply arrives through the dock. A
real cwd-reliability investigation (below) also confirmed Hermes's
native shell tool genuinely executes and reports the correct project
directory — 8/8 real runs across both `engain_avatar` and
`godot_engain_3d_avatar`, once a capable default model was configured
(see "Model reliability" below). Logic this addon's own code is
responsible for (command construction, output parsing, safe message
delivery, safe-mode enforcement — see `test_hermes_bridge_logic.gd`) is
covered by a real, executed test suite in addition to the live-editor
proof.

### Model reliability — a real finding, not a bridge defect

During the first live-editor pass, asking Hermes "what directory are
you in?" produced inconsistent answers, and a follow-up request to run
`pwd` via the shell tool sometimes returned only the *text* `pwd`
instead of executing it. This looked like a launch-boundary bug and was
investigated as one first — the bridge's own `cd` mechanism was
independently verified correct via a synthetic stand-in before any code
was touched. The actual cause: `~/.hermes/config.yaml`'s default model
was a small local `qwen3.5` (via Ollama), which was unreliable at tool
calling — sometimes narrating a shell command as text instead of
running it, sometimes reporting a plausible-but-wrong cwd. Configuring
`hermes config set model.provider openai-codex` /
`model.default gpt-5.6-sol` fixed it completely — 5/5 identical runs,
zero code changes to this bridge. **If Hermes in this dock seems to
"not really do anything," check `hermes status`'s reported model before
suspecting this addon.**

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

## SAFE/REVIEW mode — the only mode this addon implements

Per deliberate design decision (not a limitation to be worked around):
Hermes has full read/search/shell/test access to the live project, but
code changes never land in the live tree automatically. Every proposed
change goes to `.hermes_scratch/`, mirroring the live path (e.g. a
change to `scripts/Dragon.gd` becomes
`.hermes_scratch/scripts/Dragon.gd`) — a human reviews and applies it.
This is Phase 1 of a deliberate rollout (Phase 2: an isolated git
worktree/branch Hermes can freely edit, reviewed as a diff before
merge; Phase 3: narrowly-scoped direct edits; Phase 4: broader
autonomy, if the evidence from the earlier phases justifies it — none
of Phases 2–4 exist yet).

Enforcement is real, not a prompt asking politely:

1. **A safe-mode preamble is sent on EVERY turn**, not once at session
   start — see `build_safe_mode_preamble()` — so the rule can't fade out
   of a long conversation's effective context.
2. **A real SHA-256 content fingerprint of the entire live tree**
   (excluding `.hermes_scratch/` and `.git/`) is captured before and
   after every turn, and any path whose hash differs — or that was
   created or deleted — is surfaced to the dock as a hard, unmissable
   violation. See `_capture_tree_fingerprint()` /
   `diff_tree_fingerprints()` in `hermes_bridge.gd`.

**Correction (review, after the first implementation)**: the original
mechanism compared `git status --porcelain` *lines* before/after a
turn, flagging only newly-appearing lines. This had a real, proven
blind spot: a file that was already dirty (`M file.gd`) or already
untracked (`?? notes.txt`) *before* the turn produces the *identical*
status line after the turn even if its actual content changed — `git
status` classifies dirty/clean, not "did this turn touch it." Proven
with two real, executed regressions (an already-dirty tracked file and
an already-untracked file, both silently overwritable) before the fix
was written — not reasoned about, demonstrated. Real per-file content
hashing is now the authority; `git status` output is retained only as
an optional, non-authoritative human-display helper
(`diff_live_tree_changes()`).

This does **not** structurally prevent a write the way OS-level
sandboxing would — Hermes keeps real shell access, and a determined
agent could still write outside the scratch dir. What it does do: make
every turn self-check against real file content and make a violation
impossible to miss.

`.hermes_scratch/` and its `.gitignore` entry are set up **once, at
plugin activation** (`hermes_dock.gd`'s `_ready()`), not on every turn —
the bridge itself does not quietly mutate the live repository as a side
effect of every message sent, since that would be an unstated exception
to this whole mode's own "proposals only" contract.

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

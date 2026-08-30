# Dragon Scene-Understanding Channels

Status: observed architecture/evidence record
Repository: `godot_engain_3d_avatar`
Baseline scene: `res://scenes/Main.tscn`

## Purpose

Record two independent ways the shared Dragon system can understand a running
Godot scene, what each channel proves, and what neither channel is allowed to
claim by itself.

This is not a new runtime authority, a scene mutation instruction, or proof
that one historical observation remains fresh forever.

## The two channels

```text
WHAT ACTUALLY RENDERED?
        @dragon

HOW/WHERE IS IT REPRESENTED IN THE PROJECT?
        @tool

DO THOSE TWO AGREE?
        EngAIn comparison/reconciliation
```

### `@dragon`: visual/perceptual truth

`@dragon` receives a fresh request-correlated runtime viewport capture. It can
answer from the pixels that the live runtime actually produced.

For the baseline witness, it read:

```text
VIOLET-7319
```

This channel establishes rendered/perceptual evidence. It does not, by itself,
establish the node path, authored bounds, layout calculation, or canonical
project representation.

### `@tool`: structural/runtime truth

`@tool` independently inspected project and runtime artifacts:

```text
scenes/Main.tscn
    -> Label text and bounds

snapshots/perception_cap_803b5b45ecf5aab8915a05525b36570a_1.json
    -> actual captured viewport dimensions
```

It did not need the Runtime Dragon to state the label's region. It derived the
answer from current project/runtime evidence.

This channel establishes structural and artifact-backed runtime evidence. A
scene file alone does not establish what pixels rendered. Runtime metadata
alone does not establish which node authored a visible feature. Both artifacts
must be identified, and freshness/correlation must be checked when the question
is about the current run.

## Baseline witness: `VIOLET-7319`

`scenes/Main.tscn` records:

```text
Label bounds
left   = 1001
right  = 1127
top    = 434
bottom = 507
```

The correlated runtime capture metadata records:

```text
viewport width  = 1152
viewport height = 648
```

The label center is:

```text
center_x = (1001 + 1127) / 2 = 1064
center_y = (434 + 507) / 2   = 470.5

normalized_x = 1064 / 1152 = 0.923611...
normalized_y = 470.5 / 648 = 0.726080...
```

That center is in the bottom-right cell of a 3x3 viewport partition.

The stronger result is that the complete bounding rectangle is in that cell.
For a 1152x648 viewport:

```text
right column begins at x > 768
bottom row begins at y > 432
```

The rectangle begins at:

```text
left = 1001 > 768
top  = 434  > 432
```

Its right and bottom edges also remain within the viewport. Therefore the
entire label—not merely its center—falls inside the bottom-right cell.

## Evidence classification

| Evidence | Establishes | Does not establish alone |
|---|---|---|
| Correlated viewport PNG | What rendered in that captured frame | Node identity, authored bounds, canon |
| Runtime capture metadata | Actual viewport dimensions and capture correlation | Visual semantics or node ownership |
| `Main.tscn` | Authored node, text, and layout bounds | That the node rendered in a particular frame |
| Resumed Hermes Editor session | Conversation continuity across invocations | Fresh visual perception or current runtime state |
| Agreement between `@dragon` and `@tool` | Independent cross-channel corroboration | Canon promotion or permission to mutate |

Core distinction:

```text
rendered pixels != project structure
project structure != rendered truth
session continuity != sensory freshness
runtime artifact inspection != unrelated-session recall
agreement != canon promotion
```

## Editor-session continuity observation

The Editor Dragon transcript reported:

```text
Resumed session 20260823_122123_e96802
(2 user messages, 18 total messages)
```

This occurred on a later invocation after:

```text
Timeout — denying command
```

The observation supports this bounded conclusion:

```text
A denied/timed-out command did not destroy the native Editor Hermes
conversation. A later invocation resumed the same session with retained
conversation context.
```

It does not prove that a prior viewport remains current, that a runtime process
survived, or that session history can substitute for fresh project/runtime
inspection.

## Artifact-inspection legitimacy

When `@tool` obtains live dimensions from a runtime-generated metadata artifact
under `snapshots/`, that is project/runtime artifact inspection. It is not:

- a quotation from Runtime Dragon prose;
- an assumption about screen size;
- evidence taken from an unrelated Hermes session database;
- visual perception unless the corresponding PNG is separately inspected.

This is a legitimate route for the Editor agent to understand what the project
and its running capture path actually produced, provided artifact identity and
freshness are explicit.

## Next freshness proof: blind relocation

The next controlled test should move `VIOLET-7319` to a dramatically different
region, then run the composed project again without telling either channel the
new region.

Independent lanes:

```text
Lane A — @dragon
1. Receive one fresh request-correlated viewport capture.
2. Report where the label appears from pixels.
3. Do not inspect Main.tscn or consume @tool's answer.

Lane B — @tool
1. Inspect the current Main.tscn label bounds.
2. Inspect current-run capture metadata for actual viewport dimensions.
3. Derive the region mathematically.
4. Do not consume Runtime Dragon prose or @dragon's answer.

Comparison — EngAIn
1. Bind both answers to the same run/capture context.
2. Compare the independently obtained regions.
3. Report agreement or disagreement without rewriting either observation.
```

Acceptance requires both channels to follow the move independently. Repeating
the old bottom-right answer from history is a failure. Using stale capture
metadata is a failure. Passing one channel's answer into the other is a failure.

When a rectangle is wholly within one 3x3 cell, report the whole-rectangle
classification. When it crosses a boundary, report the overlap explicitly
instead of reducing it silently to center-only classification.

## Final invariant

```text
@dragon owns the question: what actually rendered in this correlated frame?
@tool owns the question: how and where is it represented by current project and
runtime artifacts?
EngAIn may compare the answers, but agreement does not create canon or mutation
authority.
```

# scripts/RuntimeSceneSync3D.gd
extends Node

## Runtime-side hot reload for scenes/WorldComposition.tscn.
##
## WHY THIS WATCHES WorldComposition.tscn AND NOT Main.tscn (2026-09-13
## correction): the first version of this script watched Main.tscn
## directly. A live DIRECT_WRITE test (two probes in a row —
## azure_cube_probe_09, then emerald_cube_probe_10) proved that unsafe in
## a completely different way than the Editor-reload SIGABRTs below: with
## Main.tscn open in the Editor, Godot keeps its OWN in-memory copy of
## the scene. Clicking "Ignore" on the "file changed externally" prompt
## (the only real option — see hermes_dock.gd's own reload-experiment
## doc for why "Reload from disk" itself crashes) leaves that in-memory
## copy stale. The NEXT time the Editor saves that scene for any reason —
## live-caught cause: Godot's own `run/auto_save/save_before_running`
## setting, which silently resaves every open modified scene on every
## Play press — it writes its stale copy back over Main.tscn, silently
## erasing whatever Hermes had just written externally. Verified with
## cryptographic certainty, not guessed: the tamper-evident
## EditReceiptStore's before/after SHA-256 for both of those turns shows
## Main.tscn's only real change was an unrelated DragonAvatar3D transform
## drift — the new probe's ext_resource/node entry was never in the file
## at all, on either turn, despite Hermes truthfully reporting the probe
## scene file itself as created.
##
## Root cause: Main.tscn was being used as BOTH the Editor's persistently
## open shell AND Dragon/Hermes's mutable world-composition target — two
## writers racing over one file with no merge. The fix is a single-writer
## boundary, not another guard on top of the race:
##   - Main.tscn: stable application shell, owned by the Editor. Holds
##     persistent runtime systems (DragonAvatar3D + its EngAInBridge,
##     ControlHUD, camera, light, ground) and instances
##     WorldComposition.tscn ONCE, under World. Dragon/Hermes never edits
##     Main.tscn during normal operation.
##   - WorldComposition.tscn: the mutable "what exists in this world
##     right now" file. Owned by Dragon/Hermes. This is the ONLY file
##     this script watches, and the only file DIRECT_WRITE edits are
##     expected to touch going forward. Since Main.tscn is never
##     rewritten by this loop any more, the Editor's in-memory copy of it
##     never goes stale relative to disk, and there is nothing for a
##     save-before-running (or any other Editor save) to clobber.
##
## Editor-side reload (the open Editor's own view of a scene catching up
## after an external edit) is a SEPARATE, harder problem, proven unsafe
## TWICE on Main.tscn itself — the manual "Reload from disk" dialog and
## the programmatic EditorInterface.reload_scene_from_path() call, both
## real SIGABRTs (see hermes_dock.gd's own
## _experimental_reload_edited_scene_via_api() doc for the full history).
## This script is not a workaround for that path, never touches
## EditorInterface, and is not affected by it — WorldComposition.tscn is
## never open as an Editor tab, only referenced by a PackedScene instance
## inside Main.tscn, so there's no in-memory Editor copy of it to go
## stale in the first place.
##
## SAFETY SHAPE, deliberately narrow, unchanged from the Main.tscn
## version other than which file and which parent it watches: every real
## DIRECT_WRITE edit run through this loop so far has taken the exact
## same shape — one new, self-contained sub-scene (no script, no
## external deps, per the standing [EDITOR_REQUEST] convention) added as
## one new ext_resource plus one new instanced
## `[node ... parent="." ... instance=ExtResource(...)]` entry directly
## under WorldComposition.tscn's own root, and nothing else. This script
## only ever detects and instantiates NEW entries of exactly that shape
## under the live WorldComposition node. It never modifies or removes an
## existing node, never re-instances or reloads WorldComposition.tscn
## itself, and never touches Main.tscn. Adding a freshly loaded
## PackedScene as a child of an already-running node is a completely
## ordinary Godot runtime operation — nothing like the Editor's own
## internal post-reload reconciliation that produced the two proven
## SIGABRTs, and nothing like a scene resave either.
##
## The text-parsing half below (find_new_instanced_nodes /
## _parse_ext_resource_paths) is a pure static function precisely so it
## can be proven correct against the real, current
## scenes/WorldComposition.tscn text without needing a live scene tree
## at all — see tests/test_runtime_scene_sync_parser.gd. The live
## add_child() half is proven separately, against a real project
## sub-scene file, in tests/test_runtime_scene_sync_apply.gd.

const COMPOSITION_SCENE_PATH := "res://scenes/WorldComposition.tscn"
const POLL_INTERVAL_SEC := 1.0

var _world_composition: Node3D = null
var _known_node_names: Dictionary = {}
var _last_seen_mtime: int = 0
var _poll_accumulator_sec: float = 0.0

signal node_hot_added(node_name: String, resource_path: String)


## Call once, with the live WorldComposition.tscn instance already
## sitting under World (NOT the World node itself — see this file's own
## doc for why Main.tscn's own content is out of scope for this script).
## Seeds "already known" from that instance's real boot-time children so
## nothing already on disk at process start is re-added as if new.
func start(world_composition: Node3D) -> void:
	_world_composition = world_composition
	_known_node_names.clear()
	for child in _world_composition.get_children():
		_known_node_names[child.name] = true
	_last_seen_mtime = FileAccess.get_modified_time(COMPOSITION_SCENE_PATH)


func _process(delta: float) -> void:
	if _world_composition == null:
		return
	_poll_accumulator_sec += delta
	if _poll_accumulator_sec < POLL_INTERVAL_SEC:
		return
	_poll_accumulator_sec = 0.0
	var mtime := FileAccess.get_modified_time(COMPOSITION_SCENE_PATH)
	if mtime == 0 or mtime == _last_seen_mtime:
		return
	_last_seen_mtime = mtime
	var reader := FileAccess.open(COMPOSITION_SCENE_PATH, FileAccess.READ)
	if reader == null:
		return
	var text := reader.get_as_text()
	reader.close()
	for addition in find_new_instanced_nodes(text, _known_node_names):
		_apply_addition(addition)


## Pure, side-effect-free: scans WorldComposition.tscn's own raw text for
## `[node name="X" ... parent="." ... instance=ExtResource("id")]`
## entries whose name is not already in known_names, resolves "id" back
## to its `[ext_resource ... id="id" path="res://..."]` declaration
## elsewhere in the same file, and captures that node block's own
## `transform = Transform3D(...)` line verbatim if present. Returns an
## Array of {name, path, transform_literal}. Anything that doesn't match
## this exact shape (no instance=, no matching ext_resource, any parent
## other than the composition's own root) is silently skipped — this
## function only ever reports the one shape this loop is built for,
## never guesses wider.
static func find_new_instanced_nodes(text: String, known_names: Dictionary) -> Array:
	var ext_resources := _parse_ext_resource_paths(text)
	var results: Array = []
	var node_re := RegEx.new()
	node_re.compile(
		"\\[node name=\"([^\"]+)\"[^\\]]*parent=\"\\.\"[^\\]]*instance=ExtResource\\(\"([^\"]+)\"\\)\\]"
	)
	for m in node_re.search_all(text):
		var node_name: String = m.get_string(1)
		var ext_id: String = m.get_string(2)
		if known_names.has(node_name):
			continue
		if not ext_resources.has(ext_id):
			continue
		var block_start: int = m.get_end()
		var next_bracket: int = text.find("\n[", block_start)
		var block_end: int = next_bracket if next_bracket != -1 else text.length()
		var block: String = text.substr(block_start, block_end - block_start)
		var transform_literal := ""
		var transform_re := RegEx.new()
		transform_re.compile("transform = (Transform3D\\([^\\)]*\\))")
		var tm := transform_re.search(block)
		if tm != null:
			transform_literal = tm.get_string(1)
		results.append({
			"name": node_name,
			"path": ext_resources[ext_id],
			"transform_literal": transform_literal,
		})
	return results


static func _parse_ext_resource_paths(text: String) -> Dictionary:
	var out := {}
	var re := RegEx.new()
	re.compile("\\[ext_resource type=\"PackedScene\"[^\\]]*path=\"([^\"]+)\"[^\\]]*id=\"([^\"]+)\"\\]")
	for m in re.search_all(text):
		out[m.get_string(2)] = m.get_string(1)
	# Godot doesn't always write path/id in the same order; cover both
	# rather than assuming one.
	var re2 := RegEx.new()
	re2.compile("\\[ext_resource type=\"PackedScene\"[^\\]]*id=\"([^\"]+)\"[^\\]]*path=\"([^\"]+)\"\\]")
	for m in re2.search_all(text):
		if not out.has(m.get_string(1)):
			out[m.get_string(1)] = m.get_string(2)
	return out


## Godot's own .tscn writer always emits the 12-float form
## `Transform3D(xx, xy, xz, yx, yy, yz, zx, zy, zz, ox, oy, oz)` — the
## exact form confirmed in the real project's own .tscn text this script
## reads. Expression.execute() was tried first and does NOT support that
## 12-float constructor form (verified live: it succeeds for the
## 2-argument Transform3D(Basis, Vector3) form but fails execution for
## the 12-float form Godot actually writes) — so this parses the twelve
## numbers directly with a regex and builds the Transform3D the same way
## normal GDScript source does, no Expression involved. Returns null
## (leaving the instance at its own default transform) if the literal
## doesn't contain exactly twelve numbers.
static func _parse_transform3d_literal(literal: String) -> Variant:
	# Slice to the parenthesized argument list FIRST — the number regex
	# below would otherwise also match the stray "3" inside the literal
	# text "Transform3D" itself (caught live: it produced 13 numbers
	# instead of 12 before this slice was added).
	var open_paren := literal.find("(")
	var close_paren := literal.rfind(")")
	if open_paren == -1 or close_paren == -1 or close_paren <= open_paren:
		return null
	var arguments := literal.substr(open_paren + 1, close_paren - open_paren - 1)
	var number_re := RegEx.new()
	number_re.compile("-?[0-9]*\\.?[0-9]+(?:e-?[0-9]+)?")
	var numbers: Array[float] = []
	for m in number_re.search_all(arguments):
		numbers.append(float(m.get_string()))
	if numbers.size() != 12:
		return null
	# Godot's own .tscn writer lays these twelve numbers out as
	# basis.x, basis.y, basis.z (each a Vector3 column), then origin —
	# there is no native 12-scalar Transform3D constructor in GDScript
	# (confirmed live: it fails to compile), so build it from the two
	# constructors that do exist instead.
	var basis := Basis(
		Vector3(numbers[0], numbers[1], numbers[2]),
		Vector3(numbers[3], numbers[4], numbers[5]),
		Vector3(numbers[6], numbers[7], numbers[8])
	)
	var origin := Vector3(numbers[9], numbers[10], numbers[11])
	return Transform3D(basis, origin)


func _apply_addition(addition: Dictionary) -> void:
	var node_name: String = addition["name"]
	if _known_node_names.has(node_name):
		return
	_known_node_names[node_name] = true
	var resource_path: String = addition["path"]
	var packed: Variant = ResourceLoader.load(resource_path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE)
	if packed == null or not (packed is PackedScene):
		return
	var instance: Node = (packed as PackedScene).instantiate()
	instance.name = node_name
	var transform_literal: String = addition.get("transform_literal", "")
	if transform_literal != "" and instance is Node3D:
		var parsed_transform: Variant = _parse_transform3d_literal(transform_literal)
		if typeof(parsed_transform) == TYPE_TRANSFORM3D:
			(instance as Node3D).transform = parsed_transform
	_world_composition.add_child(instance)
	emit_signal("node_hot_added", node_name, resource_path)

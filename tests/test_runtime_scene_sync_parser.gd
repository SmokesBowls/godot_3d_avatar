extends SceneTree

## Real, executed proof for RuntimeSceneSync3D.find_new_instanced_nodes()
## against the REAL, current scenes/WorldComposition.tscn file on disk —
## not a synthetic fixture. This is the mutable world-composition file
## (2026-09-13 ownership split: Main.tscn is the stable Editor-owned
## shell; WorldComposition.tscn is the Dragon/Hermes-owned mutable
## content file this script watches — see RuntimeSceneSync3D.gd's own
## doc for the live-evidenced reason Main.tscn itself was unsafe to
## watch). Exercises both directions:
##   1. every probe already instanced under WorldComposition's own root
##      today (there are several, added by real prior DIRECT_WRITE edits
##      this project actually ran, then moved into this file out of
##      Main.tscn during the ownership split) is correctly treated as
##      "already known" and produces zero additions — the idempotent
##      no-double-add case that matters most once this runs continuously
##      in the real game loop.
##   2. dropping exactly one real, already-on-disk probe's name out of
##      the known set makes it, and only it, come back as a detected
##      addition, with the exact ext_resource path and transform literal
##      WorldComposition.tscn's own text actually holds for that node —
##      proving the parser reads real project data correctly, not a
##      guessed shape.
##
## Run: godot --headless -s tests/test_runtime_scene_sync_parser.gd

const Sync := preload("res://scripts/RuntimeSceneSync3D.gd")

func _init() -> void:
	var reader := FileAccess.open("res://scenes/WorldComposition.tscn", FileAccess.READ)
	if reader == null:
		print("FAIL: could not open res://scenes/WorldComposition.tscn")
		quit(1)
		return
	var text := reader.get_as_text()
	reader.close()

	# --- Case 1: everything already known -> zero additions. ---
	var root_re := RegEx.new()
	root_re.compile("\\[node name=\"([^\"]+)\"[^\\]]*parent=\"\\.\"[^\\]]*instance=ExtResource\\(")
	var all_known := {}
	for m in root_re.search_all(text):
		all_known[m.get_string(1)] = true
	if all_known.size() < 1:
		print("FAIL: expected at least one real instanced node under WorldComposition's root, found none")
		quit(1)
		return
	var none_expected: Array = Sync.find_new_instanced_nodes(text, all_known)
	if none_expected.size() != 0:
		print("FAIL: expected zero additions when every real node is already known, got %s" % [none_expected])
		quit(1)
		return

	# --- Case 2: drop one real, known-on-disk probe; it alone reappears. ---
	var target_name := "AMBER_CUBE_PROBE_08"
	if not all_known.has(target_name):
		print("FAIL: expected %s to be present in the real WorldComposition.tscn for this probe" % target_name)
		quit(1)
		return
	var partially_known := all_known.duplicate()
	partially_known.erase(target_name)
	var additions: Array = Sync.find_new_instanced_nodes(text, partially_known)
	if additions.size() != 1:
		print("FAIL: expected exactly one addition after dropping %s, got %d: %s" % [target_name, additions.size(), additions])
		quit(1)
		return
	var found: Dictionary = additions[0]
	if found.get("name") != target_name:
		print("FAIL: addition name mismatch: %s" % [found])
		quit(1)
		return
	if found.get("path") != "res://scenes/AmberCubeProbe08.tscn":
		print("FAIL: addition path mismatch, expected res://scenes/AmberCubeProbe08.tscn got %s" % [found.get("path")])
		quit(1)
		return
	if not String(found.get("transform_literal", "")).begins_with("Transform3D("):
		print("FAIL: expected a real Transform3D literal, got %s" % [found.get("transform_literal")])
		quit(1)
		return

	print("OK all_known_nodes=%d reappeared=%s path=%s transform=%s" % [
		all_known.size(), found["name"], found["path"], found["transform_literal"]
	])
	quit(0)

extends SceneTree

## Real, executed proof for the 2026-09-13 ownership split: instances the
## REAL res://scenes/Main.tscn (not a fixture) and checks the actual live
## tree it produces, the same way the composed runtime would. Guards the
## two things that split was NOT allowed to break:
##   - World/DragonAvatar3D/EngAInBridge must still resolve exactly where
##     scripts/Main.gd, scripts/ControlHUD.gd, and
##     scripts/PerceptionCapture3D.gd all still hardcode it (grepped
##     before this change: nothing referenced the extracted probe nodes
##     by path, only this one).
##   - World/WorldComposition must exist, be the exact node
##     RuntimeSceneSync3D was start()-ed with, and already contain the
##     real probe nodes that used to live directly under Main.tscn's own
##     World node — proving the extraction preserved content instead of
##     losing it.
##
## Run: godot --headless -s tests/test_main_worldcomposition_split.gd

func _init() -> void:
	var packed: Variant = load("res://scenes/Main.tscn")
	if packed == null or not (packed is PackedScene):
		print("FAIL: res://scenes/Main.tscn did not load as a PackedScene")
		quit(1)
		return
	var main_instance: Node = (packed as PackedScene).instantiate()
	root.add_child(main_instance)
	# Main.gd's own _ready() (where it add_child()s the scene-sync node)
	# runs on tree entry, which Godot defers to the next idle frame, not
	# synchronously inside add_child() — confirmed live: checking
	# main_instance's children immediately after add_child() found only
	# World/UI, with "[MAIN] Loaded" printing only afterward. One
	# process_frame is enough for it to have run by the time we check.
	await process_frame

	var bridge := main_instance.get_node_or_null("World/DragonAvatar3D/EngAInBridge")
	if bridge == null:
		print("FAIL: World/DragonAvatar3D/EngAInBridge did not resolve — persistent runtime systems were disturbed")
		quit(1)
		return

	var composition := main_instance.get_node_or_null("World/WorldComposition")
	if composition == null:
		print("FAIL: World/WorldComposition did not resolve — the mutable composition scene is not instanced under World")
		quit(1)
		return

	var expected_children := [
		"FirstLightTower", "RETURN-01", "VERIFICATION_MONOLITH_04",
		"LOAD_PROBE_DIAMOND_05", "AMBER_CUBE_PROBE_08",
	]
	var actual_names: Array = []
	for child in composition.get_children():
		actual_names.append(String(child.name))
	for expected in expected_children:
		if expected not in actual_names:
			print("FAIL: expected pre-existing content node %s missing from WorldComposition, got %s" % [expected, actual_names])
			quit(1)
			return

	# The scene-sync node Main.gd wires up in _ready() must have been
	# start()-ed against WorldComposition specifically, not World itself
	# — check it already knows every real content node's name (that's
	# what start() seeds from the live tree), proving it was pointed at
	# the right node.
	var scene_sync := main_instance.get_node_or_null("RuntimeSceneSync3D")
	if scene_sync == null:
		# Main.gd adds it via add_child(_scene_sync) with no explicit
		# name override, so it takes the script's class-less default —
		# fall back to scanning children by script identity.
		for child in main_instance.get_children():
			if child.get_script() != null and String(child.get_script().resource_path).ends_with("RuntimeSceneSync3D.gd"):
				scene_sync = child
				break
	if scene_sync == null:
		print("FAIL: could not find the RuntimeSceneSync3D instance Main.gd is supposed to add")
		quit(1)
		return
	for expected in expected_children:
		if not scene_sync._known_node_names.has(expected):
			print("FAIL: RuntimeSceneSync3D's known-node seed is missing %s — it was not start()-ed against WorldComposition" % expected)
			quit(1)
			return

	print("OK bridge_path=%s composition_children=%s known_seed_size=%d" % [
		bridge.get_path(), actual_names, scene_sync._known_node_names.size()
	])
	quit(0)

extends SceneTree

## Real, executed proof for RuntimeSceneSync3D's live half: loading a
## real project sub-scene fresh (CACHE_MODE_IGNORE) and add_child()-ing
## it into an already-running Node3D, the same ordinary runtime
## operation the game's own submit()/capture flow already performs
## elsewhere — nothing like the Editor's own internal post-reload
## reconciliation that produced this project's two proven SIGABRTs (see
## RuntimeSceneSync3D.gd's own doc). Uses a REAL, already-on-disk,
## self-contained probe scene (res://scenes/LoadProbeDiamond05.tscn —
## confirmed no script, no external deps) exactly the way a real
## DIRECT_WRITE edit would reference one; never touches Main.tscn.
##
## Run: godot --headless -s tests/test_runtime_scene_sync_apply.gd

const Sync := preload("res://scripts/RuntimeSceneSync3D.gd")

func _init() -> void:
	var world := Node3D.new()
	root.add_child(world)

	var sync := Sync.new()
	root.add_child(sync)
	sync.start(world)

	if world.get_child_count() != 0:
		print("FAIL: expected an empty synthetic World before the hot-add")
		quit(1)
		return

	var received: Array = []
	sync.node_hot_added.connect(func(n, p): received.append([n, p]))

	sync._apply_addition({
		"name": "HOTLOAD_TEST_PROBE",
		"path": "res://scenes/LoadProbeDiamond05.tscn",
		"transform_literal": "Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 2.5, 0.5, -1.0)",
	})

	if world.get_child_count() != 1:
		print("FAIL: expected exactly one live child after hot-add, got %d" % world.get_child_count())
		quit(1)
		return
	var added: Node = world.get_child(0)
	if added.name != "HOTLOAD_TEST_PROBE":
		print("FAIL: hot-added node has wrong name: %s" % added.name)
		quit(1)
		return
	if not (added is Node3D):
		print("FAIL: hot-added node is not a Node3D: %s" % added)
		quit(1)
		return
	var t: Transform3D = (added as Node3D).transform
	if t.origin != Vector3(2.5, 0.5, -1.0):
		print("FAIL: transform was not applied to the hot-added node, origin=%s" % t.origin)
		quit(1)
		return
	if added.get_child_count() != 1 or added.get_child(0).name != "MeshInstance3D":
		print("FAIL: hot-added node did not bring its real real sub-scene content along: %s" % added.get_children())
		quit(1)
		return
	if received.size() != 1 or received[0][0] != "HOTLOAD_TEST_PROBE":
		print("FAIL: node_hot_added signal did not fire as expected: %s" % [received])
		quit(1)
		return

	# Idempotence: calling _apply_addition again for the same known name
	# must never add a second copy (mirrors the real poll loop calling
	# find_new_instanced_nodes repeatedly against an unchanged file).
	sync._apply_addition({
		"name": "HOTLOAD_TEST_PROBE",
		"path": "res://scenes/LoadProbeDiamond05.tscn",
		"transform_literal": "",
	})
	if world.get_child_count() != 1:
		print("FAIL: re-applying an already-known addition duplicated the node, count=%d" % world.get_child_count())
		quit(1)
		return

	print("OK hot_added=%s origin=%s child_count_after_replay=%d" % [
		added.name, t.origin, world.get_child_count()
	])
	quit(0)

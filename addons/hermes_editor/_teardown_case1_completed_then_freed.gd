extends SceneTree

## Case 1 of the teardown proof: a NORMAL COMPLETED turn, then the real
## dock is queue_free()'d (matching plugin.gd's own _exit_tree()). Not a
## standalone test — spawned as a subprocess by live_teardown_proof.gd,
## which asserts on this process's stdout/stderr for the absence of
## Godot's own Thread-destruction warning.

const HermesDockScript := preload("res://addons/hermes_editor/hermes_dock.gd")

var _dock: Control
var _stage: int = 0
var _frames_after_free: int = 0

func _init() -> void:
	_dock = HermesDockScript.new()
	get_root().add_child(_dock)

func _process(_delta: float) -> bool:
	match _stage:
		0:
			var bridge: Node = _dock.get("_bridge")
			if bridge == null:
				return false  # dock's real _ready() hasn't run yet
			var fake_path := ProjectSettings.globalize_path("res://addons/hermes_editor/fake_hermes_for_tests.sh")
			bridge._thread = Thread.new()
			bridge._thread.start(bridge._run_hermes.bind(fake_path, "hello", "", "", "", HermesDockScript.HermesBridgeScript.project_root()))
			bridge.turn_finished.connect(func(_result: Dictionary) -> void:
				print("CASE1_TURN_FINISHED")
				_dock.queue_free()
				_stage = 1
			)
			_stage = -1  # waiting on the signal now, not polling
			return false
		1:
			_frames_after_free += 1
			if _frames_after_free >= 5:
				print("CASE1_DONE")
				quit(0)
				return true
			return false
	return false

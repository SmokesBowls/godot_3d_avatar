extends SceneTree

## Case 3 of the teardown proof — the important destructor case: the
## real dock is queue_free()'d (matching a plugin disable / editor
## close) while a Hermes turn is GENUINELY still in flight. Before the
## NOTIFICATION_PREDELETE fix in hermes_bridge.gd, this reproduced both
## Godot's own "Thread object destroyed without completion" warning AND
## a "Cannot call method 'call_deferred' on a previously freed instance"
## SCRIPT ERROR when the orphaned background thread eventually tried to
## report its result back to the by-then-destroyed dock. Not a
## standalone test — spawned as a subprocess by live_teardown_proof.gd.

const HermesDockScript := preload("res://addons/hermes_editor/hermes_dock.gd")

var _dock: Control
var _stage: int = 0
var _elapsed: float = 0.0

const SLEEP_SECONDS := 1.5

func _init() -> void:
	OS.set_environment("FAKE_HERMES_SLEEP_SECONDS", str(SLEEP_SECONDS))
	_dock = HermesDockScript.new()
	get_root().add_child(_dock)

func _process(delta: float) -> bool:
	match _stage:
		0:
			var bridge: Node = _dock.get("_bridge")
			if bridge == null:
				return false
			var fake_slow_path := ProjectSettings.globalize_path("res://addons/hermes_editor/fake_hermes_slow_for_tests.sh")
			bridge._thread = Thread.new()
			bridge._thread.start(bridge._run_hermes.bind(fake_slow_path, "hello", "", "", "", HermesDockScript.HermesBridgeScript.project_root()))
			print("CASE3_TURN_STARTED_GENUINELY_IN_FLIGHT")
			# Free the dock RIGHT NOW, while the background thread is
			# still definitely running (SLEEP_SECONDS hasn't elapsed).
			_dock.queue_free()
			print("CASE3_QUEUE_FREE_CALLED")
			_stage = 1
			return false
		1:
			_elapsed += delta
			if _elapsed >= SLEEP_SECONDS + 2.0:
				print("CASE3_DONE")
				quit(0)
				return true
			return false
	return false

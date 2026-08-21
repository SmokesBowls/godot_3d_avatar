extends SceneTree

## Case 2 of the teardown proof: request_stop() pressed almost
## immediately after a turn starts, using the SLOW fake-hermes stand-in
## so there's a real window to interrupt before natural completion.
## Verifies (not assumes) the README's own claim: Stop does not kill
## the process; it only discards the eventual result. Not a standalone
## test — spawned as a subprocess by live_teardown_proof.gd.

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
			bridge.turn_finished.connect(func(_result: Dictionary) -> void:
				print("CASE2_UNEXPECTED_TURN_FINISHED")  # must NOT fire — Stop should discard it
			)
			bridge.request_stop()
			print("CASE2_STOP_REQUESTED thread_alive=%s" % bridge._thread.is_alive())
			_stage = 1
			return false
		1:
			_elapsed += delta
			if _elapsed >= SLEEP_SECONDS + 1.5:
				# Natural completion should have already happened by now
				# (SLEEP_SECONDS elapsed) — turn_finished must NOT have
				# printed above. Now free the dock, matching real
				# teardown, and confirm it's clean (thread already
				# finished naturally, should join instantly, no warning).
				print("CASE2_FREEING_AFTER_NATURAL_COMPLETION")
				_dock.queue_free()
				_stage = 2
				_elapsed = 0.0
			return false
		2:
			_elapsed += delta
			if _elapsed >= 1.0:
				print("CASE2_DONE")
				quit(0)
				return true
			return false
	return false

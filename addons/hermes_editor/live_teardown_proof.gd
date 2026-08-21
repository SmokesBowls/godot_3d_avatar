extends SceneTree

## live_teardown_proof.gd - The three-case process-lifecycle proof
## requested on review before Phase 1 could be called complete: does
## "clean process stop" actually mean clean, across (1) a normal
## completed turn followed by teardown, (2) Stop pressed during an
## active turn, and (3) the dock/plugin being torn down while a turn is
## GENUINELY still in flight (the real consequence of closing the
## editor mid-turn).
##
## Each case runs as a genuinely separate `godot --headless -s <case>.gd`
## subprocess (never a function call in this same process) so this
## proof observes real process/thread lifecycle, real stdout/stderr
## (including Godot's own engine-level warnings, which can't be
## captured any other way), and real wall-clock timing — exactly the
## standard this project's other live proofs already hold themselves to.
##
## Findings that shaped hermes_bridge.gd's own NOTIFICATION_PREDELETE
## handler (added because of what this exact investigation found, not
## before): freeing the bridge Node while its background Thread was
## still alive orphaned that thread — Godot does not auto-join it, only
## warns. The orphaned thread then ran to its own natural completion
## with `self` already destroyed and crashed calling `call_deferred` on
## a freed instance. The fix blocks NOTIFICATION_PREDELETE until the
## thread's own function body has actually returned — proven here to
## eliminate both symptoms, at the honest cost (documented in
## hermes_bridge.gd and this addon's README) that closing the editor
## while Hermes is genuinely still answering will make teardown wait for
## that answer, not detach or kill it.
##
## Run:
##   cd <this project's root>
##   godot --headless -s addons/hermes_editor/live_teardown_proof.gd

var _failures: int = 0
var _addon_dir: String


func _init() -> void:
	_addon_dir = ProjectSettings.globalize_path("res://addons/hermes_editor")
	_run_case(
		"Case 1: normal completed turn, then real dock.queue_free()",
		"_teardown_case1_completed_then_freed.gd",
		15.0,
		func(combined: String, elapsed: float) -> void:
			_assert(combined.contains("CASE1_TURN_FINISHED"), "the turn actually completed")
			_assert(combined.contains("CASE1_DONE"), "the subprocess ran to its own natural end")
			_assert(not combined.contains("A Thread object is being destroyed"), "NO Thread-destruction warning on a completed-then-freed turn")
			_assert(not combined.contains("Cannot call method 'call_deferred'"), "NO freed-instance error")
	)

	_run_case(
		"Case 2: Stop pressed during an active turn",
		"_teardown_case2_stop_mid_turn.gd",
		15.0,
		func(combined: String, elapsed: float) -> void:
			_assert(combined.contains("CASE2_STOP_REQUESTED thread_alive=true"), "the process was GENUINELY still running when Stop was pressed (not already finished)")
			_assert(not combined.contains("CASE2_UNEXPECTED_TURN_FINISHED"), "turn_finished correctly suppressed by Stop — the discard mechanism actually works")
			_assert(combined.contains("CASE2_FREEING_AFTER_NATURAL_COMPLETION"), "the underlying process ran to its own natural completion despite Stop — confirms the README's claim: Stop does not kill the process")
			_assert(not combined.contains("A Thread object is being destroyed"), "NO Thread-destruction warning once the naturally-completed thread is later torn down")
			_assert(combined.contains("CASE2_DONE"), "the subprocess ran to its own natural end")
	)

	_run_case(
		"Case 3: dock freed while a turn is GENUINELY still in flight (the real editor-close case)",
		"_teardown_case3_freed_mid_turn.gd",
		15.0,
		func(combined: String, elapsed: float) -> void:
			_assert(combined.contains("CASE3_TURN_STARTED_GENUINELY_IN_FLIGHT"), "the turn was confirmed started before freeing")
			_assert(combined.contains("CASE3_QUEUE_FREE_CALLED"), "queue_free() was actually invoked while the turn was still running")
			_assert(not combined.contains("A Thread object is being destroyed"), "NO Thread-destruction warning — NOTIFICATION_PREDELETE joined it properly")
			_assert(not combined.contains("Cannot call method 'call_deferred'"), "NO freed-instance crash when the thread's own deferred report fires")
			_assert(combined.contains("CASE3_DONE"), "the subprocess ran to its own natural end, proving teardown did not hang forever")
			# The documented, accepted cost of the fix: teardown BLOCKS
			# until the thread finishes, rather than detaching it. This
			# should take noticeably longer than an instant free — proves
			# the block genuinely happened, not that it was skipped.
			_assert(elapsed > 1.0, "wall-clock time confirms teardown actually waited for the in-flight turn, not an instant free: got %.2fs" % elapsed)
	)

	if _failures == 0:
		print("\nALL TEARDOWN CASES PASSED")
		quit(0)
	else:
		print("\n%d TEARDOWN CHECK(S) FAILED" % _failures)
		quit(1)


func _run_case(label: String, script_name: String, timeout_seconds: float, assertions: Callable) -> void:
	print("\n=== %s ===" % label)
	var script_path := _addon_dir.path_join(script_name)
	var start_usec := Time.get_ticks_usec()
	var output: Array = []
	# --path points the subprocess at this project explicitly, so
	# res:// resolves correctly regardless of the orchestrator's own cwd.
	OS.execute(
		OS.get_executable_path(),
		["--headless", "--path", ProjectSettings.globalize_path("res://"), "-s", script_path],
		output,
		true,
	)
	var elapsed := (Time.get_ticks_usec() - start_usec) / 1_000_000.0
	var combined := "\n".join(output)
	print(combined)
	print("(wall-clock: %.2fs)" % elapsed)
	assertions.call(combined, elapsed)


func _assert(condition: bool, label: String) -> void:
	if condition:
		print("  OK  " + label)
	else:
		print("  FAIL  " + label)
		_failures += 1

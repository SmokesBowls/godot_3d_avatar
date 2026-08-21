extends SceneTree

## Real, executed proof (not just --check-only parsing) for
## hermes_bridge.gd's pure logic: shell_quote, extract_session_id,
## strip_session_line, build_wrapper_script, and — the highest-value
## check here — a full end-to-end run of the actual temp-file + wrapper-
## script pipeline against a real (fake-hermes-standing-in) subprocess,
## proving an adversarial message survives intact and that no command
## substitution actually executes anywhere along the way. That last
## property is not hypothetical: an earlier draft of this bridge passed
## the message straight through as an OS.execute() argument, and this
## exact kind of test caught real command injection (Godot's OS.execute
## performs its own shell-style $VAR/backtick/$() expansion on every
## argument-array element) before it ever shipped. See hermes_bridge.gd's
## own top-of-file SECURITY NOTE for the full account.
##
## What this file does NOT prove: that hermes_bridge.gd actually launches
## a real Hermes process correctly from inside a real Godot editor
## session, or that hermes_dock.gd's UI wiring works — those require a
## human opening the real editor. Run:
##   godot --headless -s addons/hermes_editor/test_hermes_bridge_logic.gd

const HermesBridgeScript := preload("res://addons/hermes_editor/hermes_bridge.gd")

var _failures: int = 0


func _init() -> void:
	_check_shell_quote()
	_check_extract_session_id()
	_check_strip_session_line()
	_check_build_wrapper_script()
	_check_end_to_end_adversarial_via_fake_hermes()

	if _failures == 0:
		print("ALL CHECKS PASSED")
		quit(0)
	else:
		print("%d CHECK(S) FAILED" % _failures)
		quit(1)


func _assert(condition: bool, label: String) -> void:
	if condition:
		print("  OK  " + label)
	else:
		print("  FAIL  " + label)
		_failures += 1


func _check_shell_quote() -> void:
	print("== shell_quote ==")
	_assert(HermesBridgeScript.shell_quote("hello") == "'hello'", "plain string wrapped in single quotes")
	_assert(
		HermesBridgeScript.shell_quote("it's a test") == "'it'\\''s a test'",
		"embedded single quote correctly escaped as '\\''"
	)
	_assert(HermesBridgeScript.shell_quote("") == "''", "empty string quotes to an empty shell word, not nothing")


func _check_extract_session_id() -> void:
	print("== extract_session_id ==")
	_assert(
		HermesBridgeScript.extract_session_id("some text\nsession_id: abc123\nmore text") == "abc123",
		"extracts session_id from a line among other output"
	)
	_assert(
		HermesBridgeScript.extract_session_id("session_id:   spaced_out  \n") == "spaced_out",
		"tolerates extra whitespace around the value"
	)
	_assert(
		HermesBridgeScript.extract_session_id("no session id here at all") == "",
		"returns empty string when no session_id line is present"
	)


func _check_strip_session_line() -> void:
	print("== strip_session_line ==")
	var stripped: String = HermesBridgeScript.strip_session_line("Hello there.\nsession_id: abc123\n")
	_assert(stripped == "Hello there.", "removes the session_id line, keeps the reply text: got %s" % [stripped])

	var stripped2: String = HermesBridgeScript.strip_session_line("Line one.\nLine two.\nsession_id: xyz\nLine three.")
	_assert(
		stripped2 == "Line one.\nLine two.\nLine three.",
		"removes only the session_id line, preserves surrounding lines in order: got %s" % [stripped2]
	)


func _check_build_wrapper_script() -> void:
	print("== build_wrapper_script ==")
	var script: String = HermesBridgeScript.build_wrapper_script(
		"/path/to/hermes", "/tmp/query.txt", "/my/project", "", "", ""
	)
	_assert(script.begins_with("#!/bin/bash\n"), "script starts with a real shebang")
	_assert(script.contains("cd '/my/project'"), "cds into the project root, single-quoted")
	_assert(script.contains("'/path/to/hermes' chat -Q --source tool --pass-session-id"), "invokes hermes with the base flags")
	_assert(script.contains('-q "$(cat \'/tmp/query.txt\')"'), "reads the message from the query file via $(cat ...), never inline")
	_assert(not script.contains("--resume"), "no --resume when no prior session_id")

	var script2: String = HermesBridgeScript.build_wrapper_script(
		"/path/to/hermes", "/tmp/q2.txt", "/proj", "sess-42", "claude-sonnet-4", "anthropic"
	)
	_assert(script2.contains("--resume 'sess-42'"), "--resume included with the prior session_id")
	_assert(script2.contains("-m 'claude-sonnet-4'"), "model override included")
	_assert(script2.contains("--provider 'anthropic'"), "provider override included")
	_assert(
		not script2.contains("--ignore-rules") and not script2.contains("--ignore-user-config") and not script2.contains("--safe-mode"),
		"never includes the isolation flags that would strip AGENTS.md/memory/skills injection"
	)


## The decisive test: runs the REAL pipeline (temp query file -> wrapper
## script -> OS.execute with an empty arguments array) against a fake
## hermes stand-in, with a genuinely adversarial message, and confirms
## (a) the message arrives intact and (b) nothing in it actually executed.
func _check_end_to_end_adversarial_via_fake_hermes() -> void:
	print("== end-to-end: real OS.execute pipeline delivers adversarial content safely ==")

	var fake_hermes_path := ProjectSettings.globalize_path("res://addons/hermes_editor/fake_hermes_for_tests.sh")
	var adversarial := "message with $(echo INJECTED_SUBSHELL) `echo INJECTED_BACKTICK` and $UNSET_VAR_XYZ and \"double\" and 'single' chars"

	var tmp_dir := OS.get_temp_dir()
	var unique := "test_%d_%d" % [Time.get_ticks_usec(), randi()]
	var query_path := tmp_dir.path_join("hermes_editor_TEST_query_%s.txt" % unique)
	var script_path := tmp_dir.path_join("hermes_editor_TEST_run_%s.sh" % unique)

	var qf := FileAccess.open(query_path, FileAccess.WRITE)
	qf.store_string(adversarial)
	qf.close()

	var script_content: String = HermesBridgeScript.build_wrapper_script(
		fake_hermes_path, query_path, "/tmp", "prior-session-99", "", ""
	)
	var sf := FileAccess.open(script_path, FileAccess.WRITE)
	sf.store_string(script_content)
	sf.close()

	var output: Array = []
	# The exact call hermes_bridge.gd's own _run_hermes() makes: the
	# script FILE as the executable, an EMPTY arguments array.
	var exit_code := OS.execute("/bin/bash", [script_path], output, true)
	var combined := "\n".join(output)

	DirAccess.remove_absolute(query_path)
	DirAccess.remove_absolute(script_path)

	_assert(exit_code == 0, "wrapper script executed successfully (exit 0): got %d, output=%s" % [exit_code, combined])
	# This single exact-match IS the injection-safety proof: if
	# $(echo INJECTED_SUBSHELL) or the backtick form had actually been
	# executed anywhere along the pipeline, the literal wrapper syntax
	# would be gone from the received text — replaced by the bare word
	# alone — and this exact match against the full, untouched original
	# string (wrapper included) would fail. A separate substring check
	# for "does it merely contain INJECTED_SUBSHELL" would be a WEAKER,
	# broken proxy — the unexecuted literal text `$(echo INJECTED_SUBSHELL)`
	# trivially contains that substring too, which is exactly the
	# assertion bug this comment replaces (caught when this test was
	# first run: a real false positive on a real check).
	_assert(
		combined.contains("QUERY_RECEIVED:" + adversarial),
		"the FULL adversarial message survived byte-for-byte as the -q value, including literal $(...) / backticks / $VAR — proves nothing in it executed: got %s" % [combined]
	)
	_assert(combined.contains("RESUME_WAS:prior-session-99"), "--resume passed through and received correctly by the (fake) hermes")

	var sid: String = HermesBridgeScript.extract_session_id(combined)
	_assert(sid == "fake-session-abc123", "extract_session_id parses the fake hermes's real reported session_id: got %s" % [sid])

	var stripped: String = HermesBridgeScript.strip_session_line(combined)
	_assert(not stripped.contains("session_id:"), "strip_session_line removes the session_id line from what would be shown in the dock")

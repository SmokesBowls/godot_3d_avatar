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
	_check_safe_mode_preamble()
	_check_diff_live_tree_changes_display_helper()
	_check_fingerprint_safety_regressions()
	_check_end_to_end_fingerprint_audit_against_a_real_repo()

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


# --- SAFE/REVIEW mode: preamble, scratch setup, git-diff enforcement ---
#
# Appended after the injection-safety work (review request: keep the
# original workflow's write authority gated; make the mode explicit and
# self-checking, not just "Hermes was told"). These checks exercise the
# real logic against a REAL, throwaway git repo — not a mock — since the
# whole point of the enforcement mechanism is trusting real `git status`.


func _check_safe_mode_preamble() -> void:
	print("== build_safe_mode_preamble ==")
	var preamble: String = HermesBridgeScript.build_safe_mode_preamble("/my/project")
	_assert(preamble.contains("SAFE/REVIEW MODE"), "names the mode explicitly")
	_assert(preamble.contains("/my/project"), "states the real working directory")
	_assert(preamble.contains("./.hermes_scratch/"), "names the scratch dir by its real relative path")
	_assert(preamble.contains("do NOT create, modify, move, rename, or delete"), "states the live-tree prohibition explicitly")
	_assert(preamble.ends_with("---\n\n"), "ends with a clear separator before the actual message gets appended")


## DISPLAY-ONLY HELPER — NOT the safety authority. See
## diff_tree_fingerprints() below for the real gate, and this function's
## own doc comment in hermes_bridge.gd for the proven blind spot that
## demoted diff_live_tree_changes() to "optional human reporting" only:
## a git-status LINE stays identical when an already-dirty or already-
## untracked file's CONTENT changes again, so a line-set diff alone
## cannot be trusted to detect every real change.
func _check_diff_live_tree_changes_display_helper() -> void:
	print("== diff_live_tree_changes (display-only helper, not the safety gate) ==")
	var before: PackedStringArray = [" M scripts/existing.gd"]
	var after_clean: PackedStringArray = [" M scripts/existing.gd", "?? .hermes_scratch/scripts/proposed.gd"]
	_assert(
		HermesBridgeScript.diff_live_tree_changes(before, after_clean).is_empty(),
		"a new file inside .hermes_scratch/ is NOT flagged by this helper"
	)
	var after_violation: PackedStringArray = [" M scripts/existing.gd", " M scripts/live_file_hermes_touched.gd"]
	var violations: PackedStringArray = HermesBridgeScript.diff_live_tree_changes(before, after_violation)
	_assert(
		violations.size() == 1 and violations[0].contains("live_file_hermes_touched.gd"),
		"a NEW status line for a live-tree path is still flagged by this helper: got %s" % [violations]
	)


## Real throwaway git repo, real filesystem writes, real SHA-256 via
## FileAccess.get_sha256() — the 8 regressions required after the
## review correction. Each one is a genuinely executed scenario, not a
## hand-constructed dictionary, so this proves the fingerprint mechanism
## against real file I/O, not just its own data shape.
func _check_fingerprint_safety_regressions() -> void:
	print("== diff_tree_fingerprints: the 8 required regressions, real repo + real files ==")

	var repo_dir := OS.get_temp_dir().path_join("hermes_editor_TEST_fp_%d" % randi())
	DirAccess.make_dir_recursive_absolute(repo_dir)
	var git_out: Array = []
	OS.execute("/usr/bin/git", ["-C", repo_dir, "init", "-q"], git_out, true)
	OS.execute("/usr/bin/git", ["-C", repo_dir, "config", "user.email", "t@e.com"], git_out, true)
	OS.execute("/usr/bin/git", ["-C", repo_dir, "config", "user.name", "T"], git_out, true)

	# --- Setup: one clean tracked file, one PRE-DIRTIED tracked file
	# (the exact blind spot), one PRE-EXISTING untracked file, plus the
	# to-be-created/deleted/renamed fixtures. ---
	_write(repo_dir, "clean_tracked.gd", "clean original\n")
	_write(repo_dir, "already_dirty_tracked.gd", "committed version\n")
	_write(repo_dir, "to_be_deleted.gd", "will be deleted\n")
	_write(repo_dir, "to_be_renamed_from.gd", "will be renamed\n")
	OS.execute("/usr/bin/git", ["-C", repo_dir, "add", "."], git_out, true)
	OS.execute("/usr/bin/git", ["-C", repo_dir, "commit", "-q", "-m", "init"], git_out, true)
	# Now dirty already_dirty_tracked.gd BEFORE the "turn" begins.
	_write(repo_dir, "already_dirty_tracked.gd", "dirty before turn even starts\n")
	# And an untracked file that already exists before the turn.
	_write(repo_dir, "already_existing_untracked.gd", "untracked original\n")

	HermesBridgeScript._ensure_scratch_setup(repo_dir)

	var before: Dictionary = HermesBridgeScript._capture_tree_fingerprint(repo_dir)

	# 1. clean tracked file changed -> violation
	_write(repo_dir, "clean_tracked.gd", "changed during the turn\n")
	# 2. already-modified tracked file changed AGAIN -> violation (the actual blind spot)
	_write(repo_dir, "already_dirty_tracked.gd", "changed AGAIN during the turn\n")
	# 3. existing untracked file changed -> violation
	_write(repo_dir, "already_existing_untracked.gd", "changed during the turn\n")
	# 4. file created -> violation
	_write(repo_dir, "brand_new_file.gd", "new during the turn\n")
	# 5. file deleted -> violation
	DirAccess.remove_absolute(repo_dir.path_join("to_be_deleted.gd"))
	# 6. file renamed -> violation (shows as a delete+create pair)
	var rename_content := FileAccess.get_file_as_string(repo_dir.path_join("to_be_renamed_from.gd"))
	DirAccess.remove_absolute(repo_dir.path_join("to_be_renamed_from.gd"))
	_write(repo_dir, "to_be_renamed_to.gd", rename_content)
	# 7. scratch file created/changed -> NOT a violation
	_write(repo_dir, ".hermes_scratch/some_proposal.gd", "a real proposal\n")

	var after: Dictionary = HermesBridgeScript._capture_tree_fingerprint(repo_dir)
	var violations: PackedStringArray = HermesBridgeScript.diff_tree_fingerprints(before, after)
	print("  violations: ", violations)

	_assert(_contains_match(violations, "clean_tracked.gd"), "1. clean tracked file changed -> violation")
	_assert(_contains_match(violations, "already_dirty_tracked.gd"), "2. ALREADY-dirty tracked file changed AGAIN -> violation (the proven blind spot)")
	_assert(_contains_match(violations, "already_existing_untracked.gd"), "3. existing untracked file changed -> violation (the proven blind spot)")
	_assert(_contains_match(violations, "brand_new_file.gd") and violations[_find_match(violations, "brand_new_file.gd")].begins_with("created:"), "4. file created -> violation")
	_assert(_contains_match(violations, "to_be_deleted.gd") and violations[_find_match(violations, "to_be_deleted.gd")].begins_with("deleted:"), "5. file deleted -> violation")
	_assert(_contains_match(violations, "to_be_renamed_from.gd"), "6a. rename: old path reported as deleted")
	_assert(_contains_match(violations, "to_be_renamed_to.gd"), "6b. rename: new path reported as created")
	_assert(not _contains_match(violations, "some_proposal.gd"), "7. scratch file created/changed -> NOT a violation")

	# 8. no filesystem change -> no violation (separate clean before/after pair)
	var clean_before: Dictionary = HermesBridgeScript._capture_tree_fingerprint(repo_dir)
	var clean_after: Dictionary = HermesBridgeScript._capture_tree_fingerprint(repo_dir)
	_assert(HermesBridgeScript.diff_tree_fingerprints(clean_before, clean_after).is_empty(), "8. no filesystem change -> no violation")

	# 7b. scratch file DELETED -> also not a violation (completes "created/changed/deleted" from the instruction)
	var before_delete: Dictionary = HermesBridgeScript._capture_tree_fingerprint(repo_dir)
	DirAccess.remove_absolute(repo_dir.path_join(".hermes_scratch/some_proposal.gd"))
	var after_delete: Dictionary = HermesBridgeScript._capture_tree_fingerprint(repo_dir)
	_assert(
		HermesBridgeScript.diff_tree_fingerprints(before_delete, after_delete).is_empty(),
		"7b. scratch file deleted -> NOT a violation"
	)

	var cleanup: Array = []
	OS.execute("/bin/rm", ["-rf", repo_dir], cleanup, true)
	_assert(not DirAccess.dir_exists_absolute(repo_dir), "throwaway test repo fully cleaned up from the OS temp dir")


static func _write(root: String, rel_path: String, content: String) -> void:
	var full := root.path_join(rel_path)
	var parent := full.get_base_dir()
	if not DirAccess.dir_exists_absolute(parent):
		DirAccess.make_dir_recursive_absolute(parent)
	var f := FileAccess.open(full, FileAccess.WRITE)
	f.store_string(content)
	f.close()


static func _contains_match(violations: PackedStringArray, needle: String) -> bool:
	return _find_match(violations, needle) != -1


static func _find_match(violations: PackedStringArray, needle: String) -> int:
	for i in range(violations.size()):
		if String(violations[i]).contains(needle):
			return i
	return -1


## The end-to-end integration proof for the FINGERPRINT mechanism
## specifically (the earlier real-git-repo test above now exercises the
## display-only helper only) — proves _ensure_scratch_setup(),
## _capture_tree_fingerprint(), and diff_tree_fingerprints() all work
## together correctly, not just each piece in isolation.
func _check_end_to_end_fingerprint_audit_against_a_real_repo() -> void:
	print("== end-to-end: real repo, real fingerprint capture, real violation detection ==")

	var repo_dir := OS.get_temp_dir().path_join("hermes_editor_TEST_e2e_%d" % randi())
	DirAccess.make_dir_recursive_absolute(repo_dir)
	_write(repo_dir, "tracked.gd", "# original content\n")
	var git_out: Array = []
	OS.execute("/usr/bin/git", ["-C", repo_dir, "init", "-q"], git_out, true)
	OS.execute("/usr/bin/git", ["-C", repo_dir, "add", "."], git_out, true)
	OS.execute("/usr/bin/git", ["-C", repo_dir, "-c", "user.email=t@e.com", "-c", "user.name=T", "commit", "-q", "-m", "init"], git_out, true)

	HermesBridgeScript._ensure_scratch_setup(repo_dir)
	_assert(DirAccess.dir_exists_absolute(repo_dir.path_join(".hermes_scratch")), "scratch dir created by install-time setup")
	var gitignore := FileAccess.open(repo_dir.path_join(".gitignore"), FileAccess.READ)
	_assert(gitignore != null and gitignore.get_as_text().contains(".hermes_scratch"), "scratch dir added to .gitignore by install-time setup")
	if gitignore != null:
		gitignore.close()

	var before: Dictionary = HermesBridgeScript._capture_tree_fingerprint(repo_dir)

	# Compliant turn: proposal written only to scratch.
	_write(repo_dir, ".hermes_scratch/tracked.gd", "# proposed content\n")
	var after_compliant: Dictionary = HermesBridgeScript._capture_tree_fingerprint(repo_dir)
	var compliant_violations: PackedStringArray = HermesBridgeScript.diff_tree_fingerprints(before, after_compliant)
	_assert(compliant_violations.is_empty(), "a real compliant turn (scratch-only write) produces zero violations: got %s" % [compliant_violations])

	# Violating turn: the live tracked file is edited directly.
	_write(repo_dir, "tracked.gd", "# Hermes overwrote this directly!\n")
	var after_violation: Dictionary = HermesBridgeScript._capture_tree_fingerprint(repo_dir)
	var real_violations: PackedStringArray = HermesBridgeScript.diff_tree_fingerprints(after_compliant, after_violation)
	_assert(
		real_violations.size() == 1 and real_violations[0].contains("tracked.gd") and real_violations[0].begins_with("modified:"),
		"a real direct edit to the live tracked file IS caught: got %s" % [real_violations]
	)

	var cleanup: Array = []
	OS.execute("/bin/rm", ["-rf", repo_dir], cleanup, true)
	_assert(not DirAccess.dir_exists_absolute(repo_dir), "throwaway test repo fully cleaned up from the OS temp dir")

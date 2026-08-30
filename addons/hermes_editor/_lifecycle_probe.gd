@tool
extends RefCounted

## _lifecycle_probe.gd — INSTRUMENTATION ONLY, added to answer one
## question in the composed-editor SIGSEGV-on-external-reload
## investigation: does anything in the Hermes bridge/dock lifecycle
## (plugin.gd, hermes_dock.gd, hermes_bridge.gd) get touched — entered,
## torn down, reconstructed, or blocked on — when Main.tscn is
## externally modified and the human accepts Godot's "Reload from disk"
## dialog.
##
## Deliberately writes OUTSIDE the project tree (an absolute /tmp path,
## not res://) so tracing never shows up in hermes_bridge.gd's own
## live-tree fingerprint audit or in `git status` for this repo — running
## this experiment must not itself look like an unauthorized live-tree
## mutation, and the sealed Main.tscn baseline restore before/after each
## case stays meaningful.
##
## CORRECTION (after the first captured trace): launch_dragon3d.sh keeps
## more than one Godot process alive at once (editor sidecar + composed
## runtime), and every process shares this one log path. Without a
## per-line process identity, two processes' lifecycle events interleave
## in the file and a monotonic-looking t_usec column can appear to jump
## backward across the boundary — that is a real, observed failure mode,
## not a hypothetical one. Every line now carries OS.get_process_id() so
## a crashing process's timeline can be isolated from a surviving one's
## by filtering on pid alone.
##
## Every write does its own open/write/close (no buffered handle kept
## across calls) specifically so that whatever line was written most
## recently is durable even if the process SIGSEGVs immediately after —
## the last line in the log is the whole point.
##
## Not wired into any control flow decision anywhere else. Safe to
## delete this file (and the trace() call sites) once the question above
## is answered; nothing else depends on it.

const LOG_PATH := "/tmp/engain-debug-evidence/hermes_lifecycle_trace.log"

static var _mutex := Mutex.new()


static func trace(event: String) -> void:
	_mutex.lock()
	var dir := LOG_PATH.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var existing := ""
	if FileAccess.file_exists(LOG_PATH):
		var reader := FileAccess.open(LOG_PATH, FileAccess.READ)
		if reader != null:
			existing = reader.get_as_text()
			reader.close()
	var writer := FileAccess.open(LOG_PATH, FileAccess.WRITE)
	if writer != null:
		var wall_clock := Time.get_datetime_string_from_system(false, true)
		var line := "%s | pid=%d | t_usec=%d | %s\n" % [
			wall_clock, OS.get_process_id(), Time.get_ticks_usec(), event
		]
		writer.store_string(existing + line)
		writer.close()
	_mutex.unlock()

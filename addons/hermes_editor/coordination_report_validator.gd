@tool
extends SceneTree

## coordination_report_validator.gd — mechanical, headless disk validation
## for Phase 1C's editor_report.v1 "validation_result" field.
##
## Deliberately NOT "runtime_result": this only proves a changed .gd
## parses/loads, or a changed .tscn's PackedScene loads AND instantiates
## without error — disk-level facts about the edited resources. It proves
## nothing about whether the composed Dragon runtime actually started,
## displayed anything, or behaved correctly — see hermes_bridge.gd's
## write_editor_report() for that distinction and why runtime_result stays
## {"status": "not_checked"} until a real reload/health-check pipeline
## exists.
##
## Never trusts the editing model's own claim of having "tested" anything
## — every check here is a real load()/instantiate() call in a fresh
## headless Godot process, the same class of proof --check-only gives for
## a single script, extended to also cover scene instantiation (which
## --check-only alone cannot do — it parses and quits, never running this
## script's own _init(), so a scene's actual load/instantiate path is
## never exercised under --check-only).
##
## Invocation (spawned by hermes_bridge.gd's run_coordination_validation()):
##   godot --headless --path <project> -s
##     res://addons/hermes_editor/coordination_report_validator.gd --
##     <paths_json_file> <output_json_file>
##
## <paths_json_file>: a JSON array of res:// paths, already filtered by the
## caller to just the file types this validator knows how to check.
## Writes validation_result's own {status, checks} shape to
## <output_json_file>. Anything not writable there (bad args, unreadable
## input) exits non-zero with no output file — the caller treats a missing
## output file as "not_checked", never as a fabricated "passed".

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		printerr("coordination_report_validator: expected <paths_json_file> <output_json_file>")
		quit(2)
		return
	var paths_file := args[0]
	var output_file := args[1]

	var paths: Array = []
	if FileAccess.file_exists(paths_file):
		var reader := FileAccess.open(paths_file, FileAccess.READ)
		if reader != null:
			var parsed: Variant = JSON.parse_string(reader.get_as_text())
			reader.close()
			if typeof(parsed) == TYPE_ARRAY:
				paths = parsed

	var checks: Array = []
	var overall_status := "passed"
	for path_variant in paths:
		var path := String(path_variant)
		var check := _validate_one(path)
		checks.append(check)
		if String(check.get("status", "")) != "passed":
			overall_status = "failed"

	var result := {
		"status": overall_status if not checks.is_empty() else "not_checked",
		"checks": checks,
	}
	var writer := FileAccess.open(output_file, FileAccess.WRITE)
	if writer != null:
		writer.store_string(JSON.stringify(result, "  "))
		writer.close()
	quit(0)


func _validate_one(path: String) -> Dictionary:
	if path.ends_with(".tscn"):
		return _validate_scene(path)
	if path.ends_with(".gd"):
		return _validate_script(path)
	# Do not invent success for a type this validator has no meaningful
	# mechanical check for — never reached in practice since the caller
	# only sends .gd/.tscn paths, but defensive regardless.
	return {"path": path, "check": "unsupported_type", "status": "skipped"}


func _validate_scene(path: String) -> Dictionary:
	if not ResourceLoader.exists(path):
		return {
			"path": path, "check": "packed_scene_load_and_instantiate",
			"status": "failed", "error": "resource does not exist",
		}
	var resource: Variant = load(path)
	if resource == null or not (resource is PackedScene):
		return {
			"path": path, "check": "packed_scene_load_and_instantiate",
			"status": "failed", "error": "failed to load as PackedScene",
		}
	var instance: Node = (resource as PackedScene).instantiate()
	if instance == null:
		return {
			"path": path, "check": "packed_scene_load_and_instantiate",
			"status": "failed", "error": "instantiate() returned null",
		}
	instance.free()
	return {"path": path, "check": "packed_scene_load_and_instantiate", "status": "passed"}


## Deliberately NOT plain load(path) -- proven, not assumed, that load()
## does not reliably return null for a GDScript with a real parse error
## (a broken script printed "SCRIPT ERROR: Parse Error" to the console yet
## load() still handed back a non-null GDScript that passed an `is
## GDScript` check). GDScript.reload()'s own returned Error is the actual
## signal: source read directly from disk, handed to a fresh GDScript
## instance, reloaded, and its Error return value trusted instead of the
## resource's mere existence.
func _validate_script(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"path": path, "check": "script_load", "status": "failed", "error": "resource does not exist"}
	var reader := FileAccess.open(path, FileAccess.READ)
	if reader == null:
		return {
			"path": path, "check": "script_load", "status": "failed",
			"error": "could not open file: %s" % error_string(FileAccess.get_open_error()),
		}
	var source_code := reader.get_as_text()
	reader.close()
	var script := GDScript.new()
	script.source_code = source_code
	var reload_err := script.reload()
	if reload_err != OK:
		return {
			"path": path, "check": "script_load", "status": "failed",
			"error": "parse/reload failed: %s" % error_string(reload_err),
		}
	return {"path": path, "check": "script_load", "status": "passed"}

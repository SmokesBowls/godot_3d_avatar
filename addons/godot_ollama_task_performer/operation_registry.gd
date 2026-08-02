@tool
extends RefCounted

## Validates Ollama's response and dispatches actions deterministically.

const ProjectInspector = preload("res://addons/godot_ollama_task_performer/project_inspector.gd")
const SceneInspector = preload("res://addons/godot_ollama_task_performer/scene_inspector.gd")
const SceneRunner = preload("res://addons/godot_ollama_task_performer/scene_runner.gd")

## Parses and executes the validated operation.
## Returns a dictionary matching the RESULT CONTRACT:
## {
##   "status": "success | refused | error",
##   "operation": "inspect_project | inspect_scene | run_scene | refuse | unknown",
##   "started_at": "timestamp",
##   "finished_at": "timestamp",
##   "result": {},
##   "errors": []
## }
func process_response(raw_json: String, editor_interface: EditorInterface) -> Dictionary:
	var started_at = Time.get_datetime_string_from_system(false, true)
	var envelope = {
		"status": "error",
		"operation": "unknown",
		"started_at": started_at,
		"finished_at": "",
		"result": {},
		"errors": []
	}
	
	# 1. Parse JSON Response
	var parser = JSON.new()
	var parse_err = parser.parse(raw_json)
	if parse_err != OK:
		envelope["errors"].append("JSON Syntax Error: %s" % parser.get_error_message())
		envelope["finished_at"] = Time.get_datetime_string_from_system(false, true)
		return envelope
		
	var data = parser.get_data()
	if not data is Dictionary:
		envelope["errors"].append("Response content is not a valid JSON Object.")
		envelope["finished_at"] = Time.get_datetime_string_from_system(false, true)
		return envelope
		
	# 2. Reject unknown root-level keys
	var permitted_root_keys = ["operation", "arguments", "reason"]
	for key in data.keys():
		if not key in permitted_root_keys:
			envelope["errors"].append("Forbidden root key in response: '%s'" % key)
			envelope["finished_at"] = Time.get_datetime_string_from_system(false, true)
			return envelope
			
	# 3. Check for operation field
	if not data.has("operation"):
		envelope["errors"].append("Missing required field: 'operation'")
		envelope["finished_at"] = Time.get_datetime_string_from_system(false, true)
		return envelope
		
	var op_name = str(data["operation"])
	envelope["operation"] = op_name
	
	# 4. Reject unknown operations
	var permitted_operations = ["inspect_project", "inspect_scene", "run_scene", "refuse"]
	if not op_name in permitted_operations:
		envelope["errors"].append("Operation '%s' is not in the permitted operations list." % op_name)
		envelope["finished_at"] = Time.get_datetime_string_from_system(false, true)
		return envelope
		
	# 5. Check for arguments field
	if not data.has("arguments") or not data["arguments"] is Dictionary:
		envelope["errors"].append("Missing or invalid field: 'arguments' (must be a JSON object)")
		envelope["finished_at"] = Time.get_datetime_string_from_system(false, true)
		return envelope
		
	var args = data["arguments"]
	
	# 6. Validate arguments by operation type
	if op_name == "inspect_project":
		if not args.is_empty():
			envelope["errors"].append("Operation 'inspect_project' must have an empty arguments object.")
			envelope["finished_at"] = Time.get_datetime_string_from_system(false, true)
			return envelope
	elif op_name == "inspect_scene" or op_name == "run_scene":
		for arg_key in args.keys():
			if arg_key != "scope":
				envelope["errors"].append("Argument '%s' is forbidden for operation '%s'." % [arg_key, op_name])
				envelope["finished_at"] = Time.get_datetime_string_from_system(false, true)
				return envelope
			if str(args[arg_key]) != "currently_edited_scene":
				envelope["errors"].append("Argument 'scope' value '%s' is not permitted. Only 'currently_edited_scene' is allowed." % str(args[arg_key]))
				envelope["finished_at"] = Time.get_datetime_string_from_system(false, true)
				return envelope
	elif op_name == "refuse":
		# Refuse operation details are accepted freely (no scope check needed)
		pass

	# 7. Safe Dispatching (No eval, Expression.execute, OS.execute, or dynamic scripts)
	if op_name == "refuse":
		envelope["status"] = "refused"
		envelope["result"] = {
			"reason": data.get("reason", "Task refused without specified reason.")
		}
	elif op_name == "inspect_project":
		var inspector = ProjectInspector.new()
		var run_result = inspector.run(editor_interface)
		envelope["status"] = "success"
		envelope["result"] = run_result
	elif op_name == "inspect_scene":
		var inspector = SceneInspector.new()
		var run_result = inspector.run(editor_interface)
		if run_result.get("error", "") != "":
			envelope["status"] = "error"
			envelope["errors"].append(run_result["error"])
		else:
			envelope["status"] = "success"
			envelope["result"] = run_result
	elif op_name == "run_scene":
		var runner = SceneRunner.new()
		var run_result = runner.run(editor_interface)
		if run_result["status"] == "success":
			envelope["status"] = "success"
			envelope["result"] = run_result
		elif run_result["status"] == "refused":
			envelope["status"] = "refused"
			envelope["result"] = {
				"reason": run_result["message"]
			}
		else:
			envelope["status"] = "error"
			envelope["errors"].append(run_result["message"])
			
	# Record finishing timestamp
	envelope["finished_at"] = Time.get_datetime_string_from_system(false, true)
	return envelope

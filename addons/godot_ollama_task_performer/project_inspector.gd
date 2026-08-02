@tool
extends RefCounted

## Inspects the overall Godot project.
## Extracts version info, project configuration, autoloads, input actions, and whitelisted files.

func run(editor_interface: Object) -> Dictionary:
	var result = {}
	
	# 1. Godot Version
	result["godot_version"] = Engine.get_version_info()
	
	# 2. Project Name
	if ProjectSettings.has_setting("application/config/name"):
		result["project_name"] = ProjectSettings.get_setting("application/config/name")
	else:
		result["project_name"] = "Unknown"
		
	# 3. Project Path (Absolute)
	result["project_path"] = ProjectSettings.globalize_path("res://")
	
	# 4. Main Scene Setting
	if ProjectSettings.has_setting("application/run/main_scene"):
		result["main_scene"] = ProjectSettings.get_setting("application/run/main_scene")
	else:
		result["main_scene"] = ""
		
	# 5. Currently Edited Scene Path
	var edited_scene_path = ""
	if editor_interface:
		var root = editor_interface.get_edited_scene_root()
		if root:
			edited_scene_path = root.scene_file_path
	result["currently_edited_scene_path"] = edited_scene_path
	
	# 6. Autoload names and paths
	result["autoloads"] = _get_autoloads()
	
	# 7. Input Action names
	result["input_actions"] = _get_input_actions()
	
	# 8. Whitelisted files list
	var files = []
	var allowed_extensions = ["gd", "tscn", "tres", "res", "gdshader"]
	_scan_dir("res://", allowed_extensions, files)
	result["files"] = files
	
	return result

func _get_autoloads() -> Dictionary:
	var autoloads = {}
	for prop in ProjectSettings.get_property_list():
		var prop_name = prop["name"]
		if prop_name.begins_with("autoload/"):
			var autoload_name = prop_name.trim_prefix("autoload/")
			var path = ProjectSettings.get_setting(prop_name)
			autoloads[autoload_name] = path
	return autoloads

func _get_input_actions() -> Array:
	var actions = []
	for action in InputMap.get_actions():
		# Just stringify and append
		actions.append(str(action))
	return actions

func _scan_dir(path: String, allowed_extensions: Array, files_list: Array) -> void:
	var dir = DirAccess.open(path)
	if not dir:
		return
		
	var err = dir.list_dir_begin()
	if err != OK:
		return
		
	var file_name = dir.get_next()
	while file_name != "":
		# Skip current and parent dir markers
		if file_name == "." or file_name == "..":
			file_name = dir.get_next()
			continue
			
		# Exclude all hidden directories/files starting with '.' (like '.godot', '.git', etc.)
		if file_name.begins_with("."):
			file_name = dir.get_next()
			continue
			
		var full_path = path
		if not full_path.ends_with("/"):
			full_path += "/"
		full_path += file_name
		
		if dir.current_is_dir():
			# Recurse into subdirectory
			_scan_dir(full_path, allowed_extensions, files_list)
		else:
			# Check extension
			var ext = file_name.get_extension().to_lower()
			if ext in allowed_extensions:
				# Use relative path starting with res://
				files_list.append(full_path)
				
		file_name = dir.get_next()
	dir.list_dir_end()

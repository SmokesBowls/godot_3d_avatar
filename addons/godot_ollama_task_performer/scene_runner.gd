@tool
extends RefCounted

## Manages running the current scene within the editor context.

## Launches the currently active scene if it is saved.
func run(editor_interface: Object) -> Dictionary:
	var result = {
		"status": "refused",
		"message": "",
		"details": {}
	}
	
	if not editor_interface:
		result["status"] = "error"
		result["message"] = "EditorInterface is not available."
		return result
		
	var root = editor_interface.get_edited_scene_root()
	if not root:
		result["status"] = "refused"
		result["message"] = "No open scene to run."
		return result
		
	var scene_path = root.scene_file_path
	if scene_path.is_empty():
		result["status"] = "refused"
		result["message"] = "The open scene is unsaved. Please save the scene before running."
		return result
		
	# Request EditorInterface to play the current scene
	editor_interface.play_current_scene()
	
	result["status"] = "success"
	result["message"] = "Scene launch initiated."
	result["details"] = {
		"scene_path": scene_path,
		"note": "PROOF OF LAUNCH REQUEST ONLY. The editor dock has requested execution of this scene; runtime success or failure of the scene must be verified in the running viewport."
	}
	
	return result

## Stops any currently playing scene.
func stop(editor_interface: Object) -> Dictionary:
	if not editor_interface:
		return {
			"status": "error",
			"message": "EditorInterface is not available."
		}
		
	editor_interface.stop_playing()
	return {
		"status": "success",
		"message": "Stop request sent to Godot editor."
	}

@tool
extends RefCounted

## Inspects the currently edited scene.
## Traverses the node tree recursively and gathers paths, classes, scripts, and signals.

func run(editor_interface: Object) -> Dictionary:
	var result = {
		"scene_path": "",
		"root_node": {},
		"error": ""
	}
	
	if not editor_interface:
		result["error"] = "EditorInterface is not available."
		return result
		
	var root = editor_interface.get_edited_scene_root()
	if not root:
		result["error"] = "No scene is currently open in the editor."
		return result
		
	result["scene_path"] = root.scene_file_path
	result["root_node"] = _inspect_node(root, root)
	
	return result

func _inspect_node(node: Node, root: Node) -> Dictionary:
	var node_info = {
		"name": node.name,
		"path": str(root.get_path_to(node)) if node != root else ".",
		"class": node.get_class(),
		"script_path": ""
	}
	
	# Get script reference
	var script = node.get_script()
	if script is Script:
		node_info["script_path"] = script.resource_path
		
	# Get incoming signal connections
	var connections = []
	for conn in node.get_incoming_connections():
		var sig = conn.get("signal")
		var callable = conn.get("callable")
		if sig and callable:
			var source = sig.get_object()
			var target = callable.get_object()
			
			var conn_dict = {
				"signal_name": sig.get_name(),
				"source_name": source.name if source else "Unknown",
				"source_path": str(root.get_path_to(source)) if source is Node and root.is_ancestor_of(source) else "",
				"target_name": target.name if target else "Unknown",
				"target_path": str(root.get_path_to(target)) if target is Node and root.is_ancestor_of(target) else "",
				"method": callable.get_method()
			}
			connections.append(conn_dict)
			
	if not connections.is_empty():
		node_info["incoming_connections"] = connections
		
	# Process children recursively
	var children = []
	for i in range(node.get_child_count()):
		var child = node.get_child(i)
		children.append(_inspect_node(child, root))
		
	if not children.is_empty():
		node_info["children"] = children
		
	return node_info

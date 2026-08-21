@tool
extends EditorPlugin

## Registers the Hermes bottom dock. Follows the exact same bottom-dock
## registration pattern as the existing addons/godot_ollama_task_performer/
## plugin.gd (the reference for "how to make the seat") — the only
## difference here is the dock is built procedurally in hermes_dock.gd's
## _ready() rather than loaded from a .tscn, so there is no separate scene
## resource to keep in sync with this script.

const HermesDockScript := preload("res://addons/hermes_editor/hermes_dock.gd")

var dock_instance: Control

func _enter_tree() -> void:
	dock_instance = HermesDockScript.new()
	dock_instance.name = "Hermes"
	dock_instance.editor_interface = get_editor_interface()
	add_control_to_bottom_panel(dock_instance, "Hermes")


func _exit_tree() -> void:
	if is_instance_valid(dock_instance):
		remove_control_from_bottom_panel(dock_instance)
		dock_instance.queue_free()
	dock_instance = null

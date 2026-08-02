@tool
extends EditorPlugin

const ASSIST_DOCK_SCENE := preload(
    "res://addons/godot_ollama_task_performer/assist_dock.tscn"
)

var dock_instance: Control

func _enter_tree() -> void:
    dock_instance = ASSIST_DOCK_SCENE.instantiate()
    dock_instance.name = "Ollama Tasks"
    dock_instance.editor_interface = get_editor_interface()
    add_control_to_bottom_panel(dock_instance, "Ollama Tasks")


func _exit_tree() -> void:
    if is_instance_valid(dock_instance):
        remove_control_from_bottom_panel(dock_instance)
        dock_instance.queue_free()
    dock_instance = null

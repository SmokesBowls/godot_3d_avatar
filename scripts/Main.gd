extends Node3D

const PerceptionCapture := preload("res://scripts/PerceptionCapture3D.gd")
const RuntimeSceneSync := preload("res://scripts/RuntimeSceneSync3D.gd")

@onready var bridge = $World/DragonAvatar3D/EngAInBridge
@onready var _scene_sync := RuntimeSceneSync.new()

func _ready() -> void:
	# ControlHUD handles UI events and calls bridge.submit(...)
	print("[MAIN] Loaded. Bridge at:", bridge.get_path())
	add_child(_scene_sync)
	_scene_sync.node_hot_added.connect(_on_scene_sync_node_hot_added)
	_scene_sync.start($World/WorldComposition)
	if "--stage5a-capture" in OS.get_cmdline_user_args():
		call_deferred("_run_stage5a_capture")


## Relayed through the SAME log_line signal a "user"/"dragon"/"sys" line
## already uses — ControlHUD already listens to bridge.log_line, so this
## needs no new UI wiring. See RuntimeSceneSync3D.gd's own doc for why
## this is safe to do unconditionally (additive-only, WorldComposition-
## only — Main.tscn itself is never touched by this loop).
func _on_scene_sync_node_hot_added(node_name: String, resource_path: String) -> void:
	bridge.emit_signal("log_line", "sys", "[HOTLOAD] added %s from %s" % [node_name, resource_path])


func _run_stage5a_capture() -> void:
	var producer := PerceptionCapture.new()
	add_child(producer)
	var result: Dictionary = await producer.capture_once()
	if result.get("status") == "PASS":
		print("STAGE5A_RESULT=" + JSON.stringify(result))
		get_tree().quit(0)
	else:
		print("STAGE5A_FAILURE=" + JSON.stringify(result))
		get_tree().quit(1)

extends Node3D

const PerceptionCapture := preload("res://scripts/PerceptionCapture3D.gd")

@onready var bridge = $World/DragonAvatar3D/EngAInBridge

func _ready() -> void:
	# ControlHUD handles UI events and calls bridge.submit(...)
	print("[MAIN] Loaded. Bridge at:", bridge.get_path())
	if "--stage5a-capture" in OS.get_cmdline_user_args():
		call_deferred("_run_stage5a_capture")


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

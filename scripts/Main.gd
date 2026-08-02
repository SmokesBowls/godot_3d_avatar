extends Node3D

@onready var bridge = $DragonAvatar3D/EngAInBridge

func _ready():
	# ControlHUD handles UI events and calls bridge.submit(...)
	print("[MAIN] Loaded. Bridge at:", bridge.get_path())

extends Node3D

@export var pulse_enabled := true:
	set(value):
		pulse_enabled = value
		_sync_pulse()

@export var pulse_reversed := false:
	set(value):
		pulse_reversed = value
		_sync_pulse()

@onready var _pulse_animation: AnimationPlayer = $PulseAnimation


func _ready() -> void:
	_sync_pulse()


func _sync_pulse() -> void:
	if not is_node_ready():
		return
	if not pulse_enabled:
		_pulse_animation.stop()
		_pulse_animation.seek(0.0, true)
	elif pulse_reversed:
		_pulse_animation.play_backwards(&"pulse")
	else:
		_pulse_animation.play(&"pulse")

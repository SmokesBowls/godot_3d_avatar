# DragonAvatar3D.gd
# ------------------------------------------------------------
# A single, flexible script that controls the dragon avatar:
# • Horizontal back-and-forth flight with configurable endpoint pauses
# • Subtle vertical bobbing (configurable)
# • Optional “billboard‑like” sprite orientation
# • Pulse‑on‑AI‑response effect (yellow flash)
# • Works with any Node‑named bridge (EngAInBridge, EngAInBridge3D, …)
# ------------------------------------------------------------

@tool
extends Node3D

# ------------------------------------------------------------
# Exported / configurable parameters
# ------------------------------------------------------------
@export var bridge_path: NodePath = ^"EngAInBridge" # relative path to the AI‑bridge node
@export var sprite_path: NodePath = ^"AnimatedSprite3D" # relative path to the sprite

@export var horizontal_distance: float = 1.5 # distance to each side of the base position
@export var horizontal_speed: float = 0.9 # flight speed in units per second
@export var direction_pause: float = 3.0 # seconds to pause at each endpoint
@export var bob_height: float = 0.25 # vertical bob amplitude
@export var bob_speed: float = 1.2 # bob frequency (rad/s)

@export var pulse_duration: float = 0.18 # seconds the yellow flash lasts
@export var pulse_intensity: Color = Color(1, 1, 0.2, 1) # flash colour

# ------------------------------------------------------------
# Private runtime variables
# ------------------------------------------------------------
var _bridge: Node = null
var _sprite: AnimatedSprite3D = null

var _base_pos: Vector3 # static centre point (set in _ready)
var _t: float = 0.0 # elapsed time used for animation
var _horizontal_offset: float = 0.0
var _flight_direction: float = 1.0
var _pause_remaining: float = 0.0
var _pulse_tween: Tween = null # reference to the current pulse animation

# ------------------------------------------------------------
# Node lifecycle
# ------------------------------------------------------------
func _ready() -> void:
	# Cache the static centre point for the horizontal flight path.
	_base_pos = global_position

	# Grab the bridge and the sprite (if they exist).  Using get_node_or_null()
	# avoids runtime crashes when the nodes are missing.
	_bridge = get_node_or_null(bridge_path)
	_sprite = get_node_or_null(sprite_path) as AnimatedSprite3D

	# Connect the bridge signal – the exact signal name can vary, but most
	# implementations emit something like "log_line".  The script is tolerant
	# and will simply ignore the connection if the signal is absent.
	if _bridge and _bridge.has_signal("log_line"):
		_bridge.connect("log_line", _on_log_line)

	# Optional: start the sprite animation if an AnimatedSprite3D is present.
	if _sprite:
		_sprite.play("idle")


func _exit_tree() -> void:
	# Ensure we don’t leave a lingering tween when the node is freed.
	if _pulse_tween:
		_pulse_tween.kill()


# ------------------------------------------------------------
# Core animation loop
# ------------------------------------------------------------
func _process(delta: float) -> void:
	_t += delta

	# Fly horizontally between the two endpoints. At an endpoint the dragon
	# remains still for the configured pause before reversing direction.
	if _pause_remaining > 0.0:
		if delta + 0.000001 >= _pause_remaining:
			_pause_remaining = 0.0
			_flight_direction *= -1.0
		else:
			_pause_remaining -= delta
	else:
		_horizontal_offset += _flight_direction * horizontal_speed * delta
		if absf(_horizontal_offset) >= horizontal_distance:
			_horizontal_offset = clampf(_horizontal_offset, -horizontal_distance, horizontal_distance)
			_pause_remaining = direction_pause
			if is_zero_approx(_pause_remaining):
				_flight_direction *= -1.0

	# Subtle bobbing on the Y axis continues while flying or paused.
	var y: float = sin(_t * bob_speed) * bob_height

	# Keep Z fixed so the dragon no longer follows a circular path.
	global_position = _base_pos + Vector3(_horizontal_offset, y, 0.0)

	# (Optional) Keep the sprite facing the camera – comment out if you don’t want a billboard.
	if _sprite:
		# In 3‑D you usually set the sprite’s rotation to look at the camera.
		# Here we simply make sure it’s orthogonal to the global Z‑axis:
		_sprite.rotation = Vector3(deg_to_rad(90.0), 0.0, 0.0)


# ------------------------------------------------------------
# AI‑response handling (pulse effect)
# ------------------------------------------------------------
func _on_log_line(kind: String, text: String) -> void:
	"""
	This function receives whatever the bridge emits as `log_line`.
	Most bridges will pass:
		kind = "dragon" | "lore" | "player" | …
	The script only cares about the two kinds that should trigger a flash.
	"""
	if kind in ["dragon", "lore"]:
		_start_pulse()


func _start_pulse() -> void:
	"""
	Flashes the sprite for `pulse_duration` seconds using `pulse_intensity`.
	If no sprite is attached, the function does nothing – it is safe to call
	from any script that may be missing the AnimatedSprite3D node.
	"""
	if not _sprite:
		return

	# Kill any existing pulse animation so a new one restarts cleanly.
	if _pulse_tween:
		_pulse_tween.kill()

	# Remember the original colour (usually white) so we can restore it.
	var original_modulate: Color = _sprite.modulate

	# Create a short tween that flashes to `pulse_intensity` then back.
	var tween: Tween = create_tween()
	tween.tween_property(_sprite, "modulate", pulse_intensity, 0.0) # instant jump
	tween.tween_interval(pulse_duration)
	tween.tween_callback(func() -> void:
		if is_instance_valid(_sprite):
			_sprite.modulate = original_modulate
	)
	_pulse_tween = tween


# ------------------------------------------------------------
# Helper utilities (optional, kept for completeness)
# ------------------------------------------------------------
func set_pulse_color(col: Color) -> void:
	pulse_intensity = col

func set_flight_parameters(distance: float = -1, speed: float = -1,
						   pause: float = -1, new_bob_height: float = -1,
						   new_bob_speed: float = -1) -> void:
	"""
	Convenient way to tweak horizontal flight and bob values at runtime.
	"""
	if distance >= 0: horizontal_distance = distance
	if speed >= 0: horizontal_speed = speed
	if pause >= 0: direction_pause = pause
	if new_bob_height >= 0: bob_height = new_bob_height
	if new_bob_speed >= 0: bob_speed = new_bob_speed

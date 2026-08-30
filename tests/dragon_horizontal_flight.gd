extends SceneTree

var _failures := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var dragon_script := load("res://scripts/DragonAvatar3D.gd")
	_check(dragon_script != null, "Dragon flight controller loads")
	if dragon_script == null:
		_finish()
		return

	var dragon: Node3D = dragon_script.new()
	var required_properties := ["horizontal_distance", "horizontal_speed", "direction_pause"]
	for property_name: String in required_properties:
		_check(_has_property(dragon, property_name), "flight controller exposes %s" % property_name)
	if _failures > 0:
		dragon.free()
		_finish()
		return

	dragon.set_process(false)
	dragon.position = Vector3(10.0, 4.0, -2.0)
	dragon.horizontal_distance = 2.0
	dragon.horizontal_speed = 1.0
	dragon.direction_pause = 3.0
	dragon.bob_height = 0.0
	root.add_child(dragon)

	dragon.call("_process", 2.0)
	_check(is_equal_approx(dragon.global_position.x, 12.0), "dragon flies right to the horizontal endpoint")
	_check(is_equal_approx(dragon.global_position.z, -2.0), "horizontal flight does not circle on the Z axis")

	dragon.call("_process", 2.9)
	_check(is_equal_approx(dragon.global_position.x, 12.0), "dragon remains paused before three seconds elapse")
	dragon.call("_process", 0.1)
	_check(is_equal_approx(dragon.global_position.x, 12.0), "dragon changes direction only after the full three-second pause")

	dragon.call("_process", 1.0)
	_check(
		is_equal_approx(dragon.global_position.x, 11.0),
		"dragon flies left after pausing (actual x: %s, direction: %s, pause: %s)" % [
			dragon.global_position.x,
			dragon.get("_flight_direction"),
			dragon.get("_pause_remaining"),
		]
	)
	_check(is_equal_approx(dragon.global_position.z, -2.0), "leftward flight remains on the horizontal path")

	dragon.queue_free()
	_finish()


func _finish() -> void:
	if _failures == 0:
		print("DRAGON_HORIZONTAL_FLIGHT: PASS")
		quit(0)
	else:
		push_error("DRAGON_HORIZONTAL_FLIGHT: %d failure(s)" % _failures)
		quit(1)


func _check(condition: bool, message: String) -> void:
	if condition:
		print("PASS  " + message)
	else:
		_failures += 1
		push_error("FAIL  " + message)


func _has_property(object: Object, property_name: String) -> bool:
	for property: Dictionary in object.get_property_list():
		if property.get("name") == property_name:
			return true
	return false

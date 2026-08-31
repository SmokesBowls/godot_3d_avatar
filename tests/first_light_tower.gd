extends SceneTree

var _failures := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed := load("res://scenes/FirstLightTower.tscn") as PackedScene
	_check(packed != null, "FirstLightTower scene loads")
	if packed == null:
		_finish()
		return

	var tower := packed.instantiate() as Node3D
	root.add_child(tower)
	await process_frame

	_check(tower.get_node_or_null("StoneBody") is MeshInstance3D, "tower has a dark stone body")
	_check(tower.get_node_or_null("BaseRing") is MeshInstance3D, "tower has a cyan base ring")
	_check(tower.get_node_or_null("Crown/CrownBeacon") is MeshInstance3D, "tower has an amber crown beacon")
	_check(tower.get_node_or_null("StaticBody3D") is StaticBody3D, "tower has static collision")
	_check(tower.get_node_or_null("StaticBody3D/BodyCollision") is CollisionShape3D, "tower body has matching collision")
	_check(tower.get_node_or_null("PulseAnimation") is AnimationPlayer, "tower owns a reversible pulse animation")
	_check(_has_property(tower, "pulse_enabled"), "pulse can be disabled without deleting the tower")
	_check(_has_property(tower, "pulse_reversed"), "pulse direction can be reversed")

	if _has_property(tower, "pulse_enabled") and _has_property(tower, "pulse_reversed"):
		tower.set("pulse_enabled", false)
		_check(not (tower.get_node("PulseAnimation") as AnimationPlayer).is_playing(), "disabling pulse stops only the animation")
		tower.set("pulse_reversed", true)
		tower.set("pulse_enabled", true)
		_check((tower.get_node("PulseAnimation") as AnimationPlayer).get_playing_speed() < 0.0, "reversed pulse plays backwards")

	var main_packed := load("res://scenes/Main.tscn") as PackedScene
	_check(main_packed != null, "Main scene still loads")
	if main_packed != null:
		var main := main_packed.instantiate()
		_check(main.get_node_or_null("World/FirstLightTower") != null, "Main instances FirstLightTower")
		_check(main.get_node_or_null("World/DragonAvatar3D") != null, "dragon remains in Main")
		_check(main.get_node_or_null("UI/ControlHUD") != null, "ControlHUD remains in Main")
		_check(main.get_node_or_null("UI/BeaconGate") != null, "VIOLET-7319 beacon gate remains in Main")
		main.free()

	tower.queue_free()
	_finish()


func _has_property(object: Object, property_name: String) -> bool:
	for property: Dictionary in object.get_property_list():
		if property.get("name") == property_name:
			return true
	return false


func _check(condition: bool, message: String) -> void:
	if condition:
		print("PASS  " + message)
	else:
		_failures += 1
		push_error("FAIL  " + message)


func _finish() -> void:
	if _failures == 0:
		print("FIRST_LIGHT_TOWER: PASS")
		quit(0)
	else:
		push_error("FIRST_LIGHT_TOWER: %d failure(s)" % _failures)
		quit(1)

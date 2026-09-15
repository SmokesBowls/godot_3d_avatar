extends Node3D

const DRAGON_NODE_PATH := NodePath("World/DragonAvatar3D")
const VISUAL_ANCHOR_PATH := NodePath("AnimatedSprite3D")

@export var camera_offset := Vector3(0.0, 0.28, -0.42)

@onready var _camera: Camera3D = $DragonSightCamera
@onready var _cyan_white_light: SpotLight3D = $DragonSightCamera/CyanWhiteLight
@onready var _amber_center_light: SpotLight3D = $DragonSightCamera/AmberCenterLight
@onready var _indicator: CanvasLayer = $DragonSightIndicator

var _active := false
var _target_anchor: Node3D = null
var _orientation_source: Node3D = null
var _previous_camera: Camera3D = null


func _ready() -> void:
	_camera.current = false
	_cyan_white_light.visible = false
	_amber_center_light.visible = false
	_indicator.visible = false


func _input(event: InputEvent) -> void:
	if event is not InputEventKey:
		return
	var key_event := event as InputEventKey
	if key_event.keycode != KEY_F1 or not key_event.pressed or key_event.echo:
		return
	if _toggle_dragon_sight():
		get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	if not _active:
		return
	if not _update_camera_transform():
		_deactivate()


func _exit_tree() -> void:
	if _active:
		_deactivate()


func _toggle_dragon_sight() -> bool:
	if _active:
		_deactivate()
		return true
	return _activate()


func _activate() -> bool:
	var viewport := get_viewport()
	var previous_camera := viewport.get_camera_3d()
	if previous_camera == null or previous_camera == _camera:
		return false
	if not is_instance_valid(previous_camera) or not previous_camera.is_inside_tree():
		return false

	var current_scene := get_tree().current_scene
	if current_scene == null:
		return false
	var dragon := current_scene.get_node_or_null(DRAGON_NODE_PATH) as Node3D
	if dragon == null or not dragon.is_inside_tree():
		return false
	var anchor := dragon.get_node_or_null(VISUAL_ANCHOR_PATH) as Node3D
	if anchor == null or not anchor.is_inside_tree():
		return false

	_previous_camera = previous_camera
	_target_anchor = anchor
	_orientation_source = dragon
	if not _update_camera_transform():
		_clear_binding()
		return false

	_active = true
	_cyan_white_light.visible = true
	_amber_center_light.visible = true
	_indicator.visible = true
	_camera.make_current()
	return true


func _deactivate() -> void:
	_active = false
	_camera.current = false
	_cyan_white_light.visible = false
	_amber_center_light.visible = false
	_indicator.visible = false
	if is_instance_valid(_previous_camera) and _previous_camera.is_inside_tree():
		_previous_camera.make_current()
	_clear_binding()


func _update_camera_transform() -> bool:
	if not is_instance_valid(_previous_camera) or not _previous_camera.is_inside_tree():
		return false
	if not is_instance_valid(_target_anchor) or not _target_anchor.is_inside_tree():
		return false
	if not is_instance_valid(_orientation_source) or not _orientation_source.is_inside_tree():
		return false
	var forward_basis := _orientation_source.global_basis.orthonormalized()
	_camera.global_transform = Transform3D(
		forward_basis,
		_target_anchor.global_position + forward_basis * camera_offset
	)
	return true


func _clear_binding() -> void:
	_target_anchor = null
	_orientation_source = null
	_previous_camera = null

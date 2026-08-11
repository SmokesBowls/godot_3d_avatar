class_name PerceptionCapture3D
extends Node

const PROJECT_ID := "godot_3d_avatar"
const SCENE_PATH := "res://scenes/Main.tscn"
const DRAGON_SCENE_PATH := "res://scenes/DragonAvatar3D.tscn"
const DRAGON_NODE_PATH := NodePath("World/DragonAvatar3D")
const SESSION_ID := "20260731_065008_63a62d"

const CAPTURE_ROOT_ABSOLUTE := "/mnt/data-drive/godot_engain_3d_avatar/snapshots"
const CAPTURE_ROOT_RES := "res://snapshots"
const PERCEPTION_SCHEMA := "engain.runtime_perception.v1"
const SNAPSHOT_SCHEMA := "engain.runtime_snapshot.v1"
const PERCEPTION_RESULT_SCHEMA := "engain.runtime_perception_result.v1"
const CAPTURE_EVENT := "message_received"
const CAPTURE_PHASE := "pre_dispatch_player_view.v1"
const PNG_SIGNATURE := [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
const MAX_IMAGE_BYTES := 16777216
const MAX_DIMENSION := 8192

var _sequence: int = 0


func capture_once() -> Dictionary:
	_sequence += 1
	var request_id := _generate_id("req", false)
	var client_request_id := _generate_id("dragon3d", true)
	var capture_id := _generate_id("cap", true)
	if not _valid_request_id(request_id):
		return _failure("REQUEST_ID_INVALID")
	if not _valid_client_request_id(client_request_id):
		return _failure("CLIENT_REQUEST_ID_INVALID")
	if not _valid_capture_id(capture_id):
		return _failure("CAPTURE_ID_INVALID")
	if request_id == client_request_id or request_id == capture_id or client_request_id == capture_id:
		return _failure("IDENTIFIERS_NOT_DISTINCT")
	var captured_at := Time.get_unix_time_from_system()
	var capture_data: Dictionary = await _capture_persisted(
		client_request_id,
		capture_id,
		captured_at
	)
	if not capture_data.get("ok", false):
		return _failure(str(capture_data.get("failure_code", "CAPTURE_FAILED")))

	captured_at = float(capture_data["captured_at"])
	var request_timestamp := Time.get_unix_time_from_system()
	if request_timestamp < captured_at or request_timestamp - captured_at > 5.0:
		_cleanup_pair(
			"%s/perception_%s.png" % [CAPTURE_ROOT_ABSOLUTE, capture_id],
			"%s/perception_%s.json" % [CAPTURE_ROOT_ABSOLUTE, capture_id]
		)
		return _failure("CAPTURE_STALE")
	var perception: Dictionary = _full_perception(capture_id, captured_at, capture_data)
	var perception_result := {
		"schema": PERCEPTION_RESULT_SCHEMA,
		"requested_state": "full",
		"effective_state": "structured_only",
		"capture_id": capture_id,
		"capture_event": CAPTURE_EVENT,
		"capture_phase": CAPTURE_PHASE,
		"captured_at": captured_at,
		"metadata_sha256": capture_data["metadata_sha256"],
		"image_sha256": capture_data["image_sha256"],
		"structured_snapshot_supplied": false,
		"viewport_image_attached": false,
		"failure_code": null,
	}
	return {
		"status": "PASS",
		"request_id": request_id,
		"client_request_id": client_request_id,
		"capture_id": capture_id,
		"project_id": PROJECT_ID,
		"scene_path": SCENE_PATH,
		"dragon_scene_path": DRAGON_SCENE_PATH,
		"dragon_node_path": str(DRAGON_NODE_PATH),
		"session_id": SESSION_ID,
		"request_timestamp": request_timestamp,
		"metadata_path": capture_data["metadata_wire"],
		"metadata_sha256": capture_data["metadata_sha256"],
		"perception": perception,
		"perception_result": perception_result,
	}


func capture_for_submission(client_request_id: String) -> Dictionary:
	var client_request_id_valid := _valid_client_request_id(client_request_id)
	_sequence += 1
	var capture_id := _generate_id("cap", true)
	var captured_at := Time.get_unix_time_from_system()
	var failure_code: Variant = null
	# Success result contract: "status": "full"
	# Failure result contract: "status": "unavailable"
	var status := "full"
	var capture_data: Dictionary = {}
	var perception: Dictionary
	var known_failure_codes := [
		"DRAGON_SCENE_UNAVAILABLE",
		"CAPTURE_ROOT_REJECTED",
		"PNG_DIMENSION_MISMATCH",
		"FINAL_CORRELATION_FAILED",
	]

	if not client_request_id_valid:
		failure_code = "CLIENT_REQUEST_ID_INVALID"
	elif not _valid_capture_id(capture_id):
		failure_code = "CAPTURE_ID_INVALID"
	else:
		capture_data = await _capture_persisted(client_request_id, capture_id, captured_at)
		if not capture_data.get("ok", false):
			failure_code = str(capture_data.get("failure_code", "CAPTURE_FAILED"))

	if failure_code != null:
		status = "unavailable"
		if failure_code in known_failure_codes:
			failure_code = str(failure_code)
		# Frozen unavailable envelope discriminator: "perception_state": "unavailable"
		perception = {
			"schema": PERCEPTION_SCHEMA,
			"perception_state": "unavailable",
			"capture_id": capture_id,
			"capture_event": CAPTURE_EVENT,
			"capture_phase": CAPTURE_PHASE,
			"captured_at": captured_at,
			"project_id": PROJECT_ID,
			"scene_path": SCENE_PATH,
			"snapshot": null,
			# Frozen unavailable viewport discriminator: "availability": "unavailable"
			"viewport": {
				"availability": "unavailable",
				"image_path": null,
				"image_sha256": null,
				"media_type": null,
				"width": null,
				"height": null,
				"reason": "capture_failed",
			},
			"unavailable_reason": "capture_failed",
		}
	else:
		captured_at = float(capture_data["captured_at"])
		# Frozen full envelope discriminator: "perception_state": "full"
		perception = {
			"schema": PERCEPTION_SCHEMA,
			"perception_state": "full",
			"capture_id": capture_id,
			"capture_event": CAPTURE_EVENT,
			"capture_phase": CAPTURE_PHASE,
			"captured_at": captured_at,
			"project_id": PROJECT_ID,
			"scene_path": SCENE_PATH,
			"snapshot": {
				"metadata_path": capture_data["metadata_wire"],
				"metadata_sha256": capture_data["metadata_sha256"],
				"metadata": capture_data["metadata"],
			},
			"viewport": capture_data["metadata"]["viewport"],
			"unavailable_reason": null,
		}

	return {
		"status": status,
		"client_request_id": client_request_id,
		"capture_id": capture_id,
		"captured_at": captured_at,
		"failure_code": failure_code,
		"perception": perception,
	}


func _capture_persisted(
	client_request_id: String,
	capture_id: String,
	captured_at: float
) -> Dictionary:

	var current_scene := get_tree().current_scene
	if current_scene == null or current_scene.scene_file_path != SCENE_PATH:
		return _capture_failure("SCENE_UNAVAILABLE")
	var dragon := current_scene.get_node_or_null(DRAGON_NODE_PATH)
	if dragon == null or dragon.scene_file_path != DRAGON_SCENE_PATH:
		return _capture_failure("DRAGON_SCENE_UNAVAILABLE")

	var project_dir := DirAccess.open("res://")
	if project_dir == null:
		return _capture_failure("STORAGE_UNAVAILABLE")
	if project_dir.dir_exists("snapshots") and project_dir.is_link("snapshots"):
		return _capture_failure("CAPTURE_ROOT_REJECTED")
	var mkdir_error := DirAccess.make_dir_recursive_absolute(CAPTURE_ROOT_ABSOLUTE)
	if mkdir_error != OK:
		return _capture_failure("STORAGE_UNAVAILABLE")
	if ProjectSettings.globalize_path(CAPTURE_ROOT_RES) != CAPTURE_ROOT_ABSOLUTE:
		return _capture_failure("CAPTURE_ROOT_MISMATCH")

	var image_wire := "snapshots/perception_%s.png" % capture_id
	var metadata_wire := "snapshots/perception_%s.json" % capture_id
	var image_absolute := "%s/perception_%s.png" % [CAPTURE_ROOT_ABSOLUTE, capture_id]
	var metadata_absolute := "%s/perception_%s.json" % [CAPTURE_ROOT_ABSOLUTE, capture_id]
	var metadata_temporary := metadata_absolute + ".tmp"
	if (
		FileAccess.file_exists(image_absolute)
		or FileAccess.file_exists(metadata_absolute)
		or FileAccess.file_exists(metadata_temporary)
	):
		return _capture_failure("CAPTURE_ALREADY_EXISTS")

	await get_tree().process_frame
	await RenderingServer.frame_post_draw

	var viewport := get_viewport()
	if viewport == null:
		return _capture_failure("VIEWPORT_UNAVAILABLE")
	var viewport_size := viewport.get_visible_rect().size
	var viewport_width := int(viewport_size.x)
	var viewport_height := int(viewport_size.y)
	if not _valid_dimension(viewport_width) or not _valid_dimension(viewport_height):
		return _capture_failure("VIEWPORT_DIMENSIONS_INVALID")
	var image := viewport.get_texture().get_image()
	if image == null:
		return _capture_failure("VIEWPORT_UNAVAILABLE")
	if image.get_width() != viewport_width or image.get_height() != viewport_height:
		return _capture_failure("VIEWPORT_DIMENSION_MISMATCH")

	var save_error := image.save_png(image_absolute)
	image = null
	if save_error != OK:
		_delete_if_present(image_absolute)
		return _capture_failure("IMAGE_WRITE_FAILED")

	var persisted_bytes := FileAccess.get_file_as_bytes(image_absolute)
	if persisted_bytes.is_empty() or persisted_bytes.size() > MAX_IMAGE_BYTES:
		_delete_if_present(image_absolute)
		return _capture_failure("IMAGE_BYTES_INVALID")
	var png_dimensions := _validate_png(persisted_bytes)
	if not png_dimensions.get("ok", false):
		_delete_if_present(image_absolute)
		return _capture_failure(str(png_dimensions.get("error", "PNG_INVALID")))
	if (
		png_dimensions["width"] != viewport_width
		or png_dimensions["height"] != viewport_height
	):
		_delete_if_present(image_absolute)
		return _capture_failure("PNG_DIMENSION_MISMATCH")
	var image_sha256 := _sha256(persisted_bytes)
	if image_sha256.length() != 64:
		_delete_if_present(image_absolute)
		return _capture_failure("IMAGE_HASH_FAILED")

	var viewport_metadata := {
		"availability": "available",
		"image_path": image_wire,
		"image_sha256": image_sha256,
		"media_type": "image/png",
		"width": viewport_width,
		"height": viewport_height,
		"reason": null,
	}
	var metadata := {
		"schema": SNAPSHOT_SCHEMA,
		"capture_id": capture_id,
		"client_request_id": client_request_id,
		"capture_event": CAPTURE_EVENT,
		"capture_phase": CAPTURE_PHASE,
		"captured_at": captured_at,
		"project_id": PROJECT_ID,
		"scene_path": SCENE_PATH,
		"runtime": {
			"fps": float(Engine.get_frames_per_second()),
			"current_location": "3D flight test world",
			"inventory": [],
			"player_position": str(dragon.position),
		},
		"viewport": viewport_metadata,
	}
	var metadata_text := JSON.stringify(metadata) + "\n"
	var temporary := FileAccess.open(metadata_temporary, FileAccess.WRITE)
	if temporary == null:
		_delete_if_present(image_absolute)
		return _capture_failure("METADATA_WRITE_FAILED")
	temporary.store_string(metadata_text)
	temporary.flush()
	temporary.close()
	if not FileAccess.file_exists(metadata_temporary):
		_delete_if_present(image_absolute)
		return _capture_failure("METADATA_WRITE_FAILED")
	var rename_error := DirAccess.rename_absolute(metadata_temporary, metadata_absolute)
	if rename_error != OK:
		_delete_if_present(metadata_temporary)
		_delete_if_present(image_absolute)
		return _capture_failure("METADATA_WRITE_FAILED")

	var metadata_bytes := FileAccess.get_file_as_bytes(metadata_absolute)
	var metadata_sha256 := _sha256(metadata_bytes)
	var parser := JSON.new()
	if parser.parse(metadata_bytes.get_string_from_utf8()) != OK:
		_cleanup_pair(image_absolute, metadata_absolute)
		return _capture_failure("METADATA_PARSE_FAILED")
	var persisted_metadata: Variant = parser.data
	if (
		typeof(persisted_metadata) != TYPE_DICTIONARY
		or metadata_bytes.get_string_from_utf8() != metadata_text
	):
		_cleanup_pair(image_absolute, metadata_absolute)
		return _capture_failure("METADATA_CONTENT_MISMATCH")

	var reread_image := FileAccess.get_file_as_bytes(image_absolute)
	var reread_dimensions := _validate_png(reread_image)
	if (
		not reread_dimensions.get("ok", false)
		or _sha256(reread_image) != image_sha256
		or reread_dimensions["width"] != viewport_width
		or reread_dimensions["height"] != viewport_height
	):
		_cleanup_pair(image_absolute, metadata_absolute)
		return _capture_failure("FINAL_IMAGE_VERIFICATION_FAILED")
	var persisted_viewport: Variant = persisted_metadata.get("viewport")
	var persisted_captured_at := float(persisted_metadata.get("captured_at", 0.0))
	if (
		persisted_metadata.size() != 10
		or persisted_metadata.get("schema") != SNAPSHOT_SCHEMA
		or persisted_metadata.get("capture_id") != capture_id
		or persisted_metadata.get("client_request_id") != client_request_id
		or persisted_metadata.get("capture_event") != CAPTURE_EVENT
		or persisted_metadata.get("capture_phase") != CAPTURE_PHASE
		or persisted_captured_at <= 0.0
		or absf(persisted_captured_at - captured_at) > 0.001
		or persisted_metadata.get("project_id") != PROJECT_ID
		or persisted_metadata.get("scene_path") != SCENE_PATH
		or typeof(persisted_metadata.get("runtime")) != TYPE_DICTIONARY
		or typeof(persisted_viewport) != TYPE_DICTIONARY
		or persisted_viewport.size() != 7
		or persisted_viewport.get("availability") != "available"
		or persisted_viewport.get("image_path") != image_wire
		or persisted_viewport.get("image_sha256") != image_sha256
		or persisted_viewport.get("media_type") != "image/png"
		or int(persisted_viewport.get("width", 0)) != viewport_width
		or int(persisted_viewport.get("height", 0)) != viewport_height
		or persisted_viewport.get("reason") != null
	):
		_cleanup_pair(image_absolute, metadata_absolute)
		return _capture_failure("FINAL_CORRELATION_FAILED")
	# Godot's JSON parser materializes every JSON number as a float. Restore the
	# dimension fields to their frozen integer wire types before this exact
	# persisted metadata object is forwarded through the mailbox.
	persisted_viewport["width"] = viewport_width
	persisted_viewport["height"] = viewport_height
	captured_at = persisted_captured_at
	var completed_at := Time.get_unix_time_from_system()
	if completed_at < captured_at or completed_at - captured_at > 5.0:
		_cleanup_pair(image_absolute, metadata_absolute)
		return _capture_failure("CAPTURE_STALE")
	return {
		"ok": true,
		"captured_at": captured_at,
		"metadata_wire": metadata_wire,
		"metadata_sha256": metadata_sha256,
		"metadata": persisted_metadata,
		"image_sha256": image_sha256,
	}


func _full_perception(
	capture_id: String,
	captured_at: float,
	capture_data: Dictionary
) -> Dictionary:
	return {
		"schema": PERCEPTION_SCHEMA,
		"perception_state": "full",
		"capture_id": capture_id,
		"capture_event": CAPTURE_EVENT,
		"capture_phase": CAPTURE_PHASE,
		"captured_at": captured_at,
		"project_id": PROJECT_ID,
		"scene_path": SCENE_PATH,
		"snapshot": {
			"metadata_path": capture_data["metadata_wire"],
			"metadata_sha256": capture_data["metadata_sha256"],
			"metadata": capture_data["metadata"],
		},
		"viewport": capture_data["metadata"]["viewport"],
		"unavailable_reason": null,
	}


func _capture_failure(code: String) -> Dictionary:
	return {"ok": false, "failure_code": code}


func _generate_id(prefix: String, include_sequence: bool) -> String:
	var crypto := Crypto.new()
	var random_bytes := crypto.generate_random_bytes(16)
	if random_bytes.size() != 16:
		return ""
	var value := "%s_%s" % [prefix, random_bytes.hex_encode()]
	if include_sequence:
		value += "_%d" % _sequence
	return value


func _valid_request_id(value: String) -> bool:
	return _matches(value, "^req_[0-9a-f]{32}$")


func _valid_client_request_id(value: String) -> bool:
	return _matches(value, "^dragon3d_[0-9a-f]{32}_[1-9][0-9]*$")


func _valid_capture_id(value: String) -> bool:
	return _matches(value, "^cap_[0-9a-f]{32}_[1-9][0-9]*$")


func _matches(value: String, pattern: String) -> bool:
	var expression := RegEx.new()
	if expression.compile(pattern) != OK:
		return false
	return expression.search(value) != null


func _valid_dimension(value: int) -> bool:
	return value >= 1 and value <= MAX_DIMENSION


func _validate_png(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() < 33:
		return {"ok": false, "error": "PNG_TOO_SMALL"}
	for index in PNG_SIGNATURE.size():
		if bytes[index] != PNG_SIGNATURE[index]:
			return {"ok": false, "error": "PNG_SIGNATURE_INVALID"}
	var offset := 8
	var chunk_index := 0
	var ihdr_count := 0
	var width := 0
	var height := 0
	while offset < bytes.size():
		if offset + 12 > bytes.size():
			return {"ok": false, "error": "PNG_CHUNK_TRUNCATED"}
		var chunk_length := _u32_be(bytes, offset)
		var data_start := offset + 8
		var chunk_end := data_start + chunk_length + 4
		if chunk_length < 0 or chunk_end > bytes.size():
			return {"ok": false, "error": "PNG_CHUNK_INVALID"}
		var chunk_type := bytes.slice(offset + 4, offset + 8).get_string_from_ascii()
		if chunk_index == 0 and (chunk_type != "IHDR" or chunk_length != 13):
			return {"ok": false, "error": "PNG_IHDR_FIRST_INVALID"}
		if chunk_type == "IHDR":
			ihdr_count += 1
			if chunk_length != 13:
				return {"ok": false, "error": "PNG_IHDR_LENGTH_INVALID"}
			width = _u32_be(bytes, data_start)
			height = _u32_be(bytes, data_start + 4)
		offset = chunk_end
		chunk_index += 1
	if offset != bytes.size() or ihdr_count != 1:
		return {"ok": false, "error": "PNG_IHDR_COUNT_INVALID"}
	if not _valid_dimension(width) or not _valid_dimension(height):
		return {"ok": false, "error": "PNG_DIMENSIONS_INVALID"}
	return {"ok": true, "width": width, "height": height}


func _u32_be(bytes: PackedByteArray, offset: int) -> int:
	return (
		(int(bytes[offset]) << 24)
		| (int(bytes[offset + 1]) << 16)
		| (int(bytes[offset + 2]) << 8)
		| int(bytes[offset + 3])
	)


func _sha256(bytes: PackedByteArray) -> String:
	var hashing := HashingContext.new()
	if hashing.start(HashingContext.HASH_SHA256) != OK:
		return ""
	if hashing.update(bytes) != OK:
		return ""
	return hashing.finish().hex_encode()


func _cleanup_pair(image_path: String, metadata_path: String) -> void:
	_delete_if_present(metadata_path)
	_delete_if_present(image_path)


func _delete_if_present(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


func _failure(code: String) -> Dictionary:
	return {"status": "FAIL", "failure_code": code}

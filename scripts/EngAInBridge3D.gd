# scripts/EngAInBridge3D.gd
extends Node

signal log_line(kind: String, text: String)
signal dragon_speaking(active: bool)
signal submission_committed(client_request_id: String, submitted_text: String)
signal status_changed(status: String)

const PerceptionCapture := preload("res://scripts/PerceptionCapture3D.gd")

const PROJECT_ROOT := "/mnt/data-drive/godot_engain_3d_avatar"
const MAILBOX_ROOT := "/mnt/data-drive/engain-runtime-mailboxes/dragon3d"
const REQUEST_MAILBOX_PATH := MAILBOX_ROOT + "/request.json"
const RESPONSE_MAILBOX_PATH := MAILBOX_ROOT + "/response.json"
const ADAPTER_PATH := "/mnt/data-drive/godot_engain_3d_avatar/hermes_session_adapter.py"
const PYTHON_EXECUTABLE := "/usr/bin/python3"
const FROZEN_SESSION_ID := "20260731_065008_63a62d"
const FROZEN_COMPANION := "hermes_b"
const FROZEN_PROVIDER := "openai-codex"
const FROZEN_MODEL := "gpt-5.6-sol"
const WAIT_TIMEOUT_SEC := 180.0
const CALL_LIFETIME_SEC := 185.0
const POLL_INTERVAL_SEC := 0.1
const MAILBOX_BUSY := "MAILBOX_BUSY"
const MAILBOX_STALE := "MAILBOX_STALE"
const LISTENER_ABSENT := "LISTENER_ABSENT"
const REQUEST_SCHEMA: Array[String] = [
	"call_id",
	"expires_at",
	"player_input",
	"game_state",
	"additional_context",
	"timestamp",
	"request_id",
]
const CONTEXT_SCHEMA: Array[String] = [
	"client_request_id",
	"companion_ref",
	"perception",
]
const TEXT_ONLY_CONTEXT_SCHEMA: Array[String] = [
	"client_request_id",
	"companion_ref",
	"routing_mode",
]
const ROUTE_TEXT_ONLY := "text_only"
const ROUTE_CURRENT_PERCEPTION := "current_perception"
const STATUS_IDLE := "IDLE"
const STATUS_LOOKING_INTERNAL := "LOOKING_INTERNAL"
const STATUS_THINKING := "THINKING"
const NO_CURRENT_IMAGE_PHRASES: Array[String] = [
	"without using any current image", "without a current image",
	"do not use any current image", "do not use a current image",
	"don't use any current image", "don't use a current image",
	"no current image", "text only",
]
const CURRENT_VIEW_PHRASES: Array[String] = [
	"what do you see", "what can you see", "what is visible", "currently visible",
	"current viewport", "current view", "current screen", "current frame", "current scene",
	"current room", "right now", "in front of me", "left side of the screen",
	"right side of the screen", "left side of the frame", "right side of the frame",
	"look at this", "look here", "look around",
]
const HISTORY_SCOPES: Array[String] = [
	"in your memory", "from memory", "in the previous scene", "in the prior scene",
	"in the earlier scene", "last time", "previously",
]
const ROUTING_ANCHORS: Array[String] = [
	"this", "these", "here", "currently", "right now", "at the moment",
	"in front of me", "on the screen", "in the frame", "in the viewport",
]
const VISUAL_SPATIAL_TERMS: Array[String] = [
	"see", "look", "visible", "view", "screen", "frame", "viewport", "scene", "room",
	"object", "dragon", "color", "colour", "where", "location", "left", "right", "front",
	"behind", "above", "below", "near", "far", "different", "compare",
]
const RESPONSE_SCHEMA: Array[String] = [
	"call_id",
	"request_id",
	"client_request_id",
	"narrative_response",
	"action_type",
	"state_changes",
	"director_analysis",
	"reasoning",
	"entropy_impact",
	"timestamp",
	"provider_session_ref",
	"perception_result",
]
const PROVIDER_SESSION_SCHEMA: Array[String] = [
	"companion_ref",
	"provider",
	"model",
	"session_id",
]
const PERCEPTION_RESULT_SCHEMA: Array[String] = [
	"schema",
	"requested_state",
	"effective_state",
	"capture_id",
	"capture_event",
	"capture_phase",
	"captured_at",
	"metadata_sha256",
	"image_sha256",
	"structured_snapshot_supplied",
	"viewport_image_attached",
	"failure_code",
]
const CAPTURE_RESULT_SCHEMA: Array[String] = [
	"status",
	"client_request_id",
	"capture_id",
	"captured_at",
	"failure_code",
	"perception",
]
const PERCEPTION_SCHEMA: Array[String] = [
	"schema",
	"perception_state",
	"capture_id",
	"capture_event",
	"capture_phase",
	"captured_at",
	"project_id",
	"scene_path",
	"snapshot",
	"viewport",
	"unavailable_reason",
]
const VIEWPORT_SCHEMA: Array[String] = [
	"availability",
	"image_path",
	"image_sha256",
	"media_type",
	"width",
	"height",
	"reason",
]
const SNAPSHOT_SCHEMA: Array[String] = [
	"metadata_path",
	"metadata_sha256",
	"metadata",
]
const SNAPSHOT_METADATA_SCHEMA: Array[String] = [
	"schema",
	"capture_id",
	"client_request_id",
	"capture_event",
	"capture_phase",
	"captured_at",
	"project_id",
	"scene_path",
	"runtime",
	"viewport",
]
const RUNTIME_SCHEMA: Array[String] = [
	"fps",
	"current_location",
	"inventory",
	"player_position",
]

var user_name: String = "You"
var dragon_name: String = "Dragon"
var lore_name: String = "Mr. Lore"
var provider_execution_count: int = 0
var lifecycle_status: String = STATUS_IDLE

var _busy: bool = false
var _capture_pending: bool = false
var _dragon_speaking_active: bool = false
var _lifecycle_generation: int = 0
var _active_request_id: String = ""
var _active_call_id: String = ""
var _active_client_request_id: String = ""
var _active_capture_id: String = ""
var _active_route: String = ""
var _active_started_msec: int = 0
var _poll_accumulator_sec: float = 0.0
var _submission_counter: int = 0
var _crypto := Crypto.new()
var _capture_producer: Node = null


func _ready() -> void:
	_capture_producer = PerceptionCapture.new()
	add_child(_capture_producer)
	_emit_sys("Mailbox bridge ready. session_id=%s" % FROZEN_SESSION_ID)


func _exit_tree() -> void:
	_end_active_lifecycle()


func _process(delta: float) -> void:
	_poll_accumulator_sec += delta
	if _capture_pending:
		var capture_elapsed_sec := float(Time.get_ticks_msec() - _active_started_msec) / 1000.0
		if _busy and capture_elapsed_sec >= WAIT_TIMEOUT_SEC:
			_end_active_lifecycle()
			_emit_err("Mailbox timeout after 180.0 seconds.")
		return
	if _busy:
		var elapsed_sec := float(Time.get_ticks_msec() - _active_started_msec) / 1000.0
		if elapsed_sec >= WAIT_TIMEOUT_SEC:
			_end_active_lifecycle()
			_emit_err("Mailbox timeout after 180.0 seconds.")
	if _poll_accumulator_sec < POLL_INTERVAL_SEC:
		return
	_poll_accumulator_sec = fmod(_poll_accumulator_sec, POLL_INTERVAL_SEC)
	_poll_response_mailbox()


func submit(text: String) -> void:
	var msg := text.strip_edges()
	if msg == "":
		return
	if _capture_pending:
		return
	if _busy:
		_reject_busy("one request is already active.")
		return
	if FileAccess.file_exists(RESPONSE_MAILBOX_PATH):
		_reject_busy("engain_response.json is unread.")
		return

	_submission_counter += 1
	var client_request_id := "dragon3d_%s_%d" % [_random_hex_16(), _submission_counter]
	if not _matches_pattern(client_request_id, "^dragon3d_[0-9a-f]{32}_[1-9][0-9]*$"):
		_emit_err("Client request identity allocation failed.")
		return
	_lifecycle_generation += 1
	var lifecycle_generation := _lifecycle_generation
	var route := _classify_route(msg)
	_busy = true
	_active_client_request_id = client_request_id
	_active_route = route
	_active_started_msec = Time.get_ticks_msec()
	var capture_id := ""
	var perception: Dictionary = {}
	var capture_status := ""
	if route == "text_only":
		pass
	else:
		_capture_pending = true
		_set_lifecycle_status("LOOKING_INTERNAL")
		var capture_result: Variant = await _capture_producer.capture_for_submission(client_request_id)
		if lifecycle_generation != _lifecycle_generation:
			return
		if not _busy or _active_client_request_id != client_request_id:
			return
		if typeof(capture_result) != TYPE_DICTIONARY:
			_end_active_lifecycle()
			_emit_err("Live capture returned a non-object result.")
			return
		capture_status = capture_result.get("status")
		if capture_status not in ["full", "unavailable"]:
			_end_active_lifecycle()
			_emit_err("Live capture returned an invalid status.")
			return
		if not _validate_live_capture_result(capture_result as Dictionary, client_request_id):
			_end_active_lifecycle()
			_emit_err("Live capture failed its frozen result contract.")
			return
		capture_id = capture_result["capture_id"]
		perception = capture_result["perception"]
	var request_id := "req_" + _random_hex_16()
	if not _matches_pattern(request_id, "^req_[0-9a-f]{32}$"):
		_end_active_lifecycle()
		_emit_err("Mailbox request identity allocation failed.")
		return
	var timestamp := Time.get_unix_time_from_system()
	if capture_status == "full":
		var capture_age := timestamp - float(perception["captured_at"])
		if capture_age < 0.0 or capture_age > 5.0:
			_end_active_lifecycle()
			_emit_err("Live capture became stale before mailbox publication.")
			return
	var payload := _build_text_only_mailbox_request(msg, request_id, client_request_id, timestamp)
	if route == ROUTE_CURRENT_PERCEPTION:
		payload = _build_mailbox_request(msg, request_id, client_request_id, perception, timestamp)
	if not _has_exact_keys(payload, REQUEST_SCHEMA):
		_end_active_lifecycle()
		_emit_err("Generated request failed frozen request schema.")
		return
	var context: Variant = payload.get("additional_context")
	var context_schema := TEXT_ONLY_CONTEXT_SCHEMA if route == ROUTE_TEXT_ONLY else CONTEXT_SCHEMA
	if typeof(context) != TYPE_DICTIONARY or not _has_exact_keys(context, context_schema):
		_end_active_lifecycle()
		_emit_err("Generated request context failed frozen schema.")
		return
	if route == ROUTE_TEXT_ONLY and context.get("routing_mode") != "text_only":
		_end_active_lifecycle()
		_emit_err("Generated text-only request failed its frozen routing mode.")
		return

	var temporary_path := PROJECT_ROOT + "/.engain_request.%s.tmp" % request_id
	if FileAccess.file_exists(temporary_path):
		_end_active_lifecycle()
		_emit_err(MAILBOX_BUSY + ": exact request temporary already exists.")
		return
	var temporary := FileAccess.open(temporary_path, FileAccess.WRITE)
	if temporary == null:
		_end_active_lifecycle()
		_emit_err("Request temporary creation failed: %s" % error_string(FileAccess.get_open_error()))
		return
	temporary.store_string(JSON.stringify(payload))
	temporary.flush()
	temporary = null

	var publication := _execute_adapter(PackedStringArray(["--publish-request", temporary_path]))
	if publication["code"] != 0 or not publication["output"].contains("ENGAIN_REQUEST_PUBLISHED=1"):
		_end_active_lifecycle()
		_emit_err("Request publication failed: " + publication["output"])
		return

	_active_request_id = request_id
	_active_call_id = request_id
	_active_client_request_id = client_request_id
	_active_capture_id = capture_id
	_capture_pending = false
	_emit_user(msg)
	emit_signal("submission_committed", client_request_id, msg)
	_set_lifecycle_status("THINKING")
	_dragon_speaking_active = true
	emit_signal("dragon_speaking", true)


func _build_mailbox_request(
	msg: String,
	request_id: String,
	client_request_id: String,
	perception: Dictionary,
	timestamp: float
) -> Dictionary:
	return {
		"call_id": request_id,
		"expires_at": timestamp + CALL_LIFETIME_SEC,
		"player_input": msg,
		"game_state": {},
		"additional_context": {
			"client_request_id": client_request_id,
			"companion_ref": "hermes_b",
			"perception": perception,
		},
		"timestamp": timestamp,
		"request_id": request_id,
	}


func _classify_route(text: String) -> String:
	for phrase in NO_CURRENT_IMAGE_PHRASES:
		if text.containsn(phrase):
			return ROUTE_TEXT_ONLY
	for scope in HISTORY_SCOPES:
		if text.containsn(scope):
			return ROUTE_TEXT_ONLY
	for phrase in CURRENT_VIEW_PHRASES:
		if text.containsn(phrase):
			return ROUTE_CURRENT_PERCEPTION
	var has_current_anchor := false
	for anchor in ROUTING_ANCHORS:
		if text.containsn(anchor):
			has_current_anchor = true
			break
	if has_current_anchor:
		for term in VISUAL_SPATIAL_TERMS:
			if text.containsn(term):
				return ROUTE_CURRENT_PERCEPTION
	return ROUTE_TEXT_ONLY


func _build_text_only_mailbox_request(
	msg: String,
	request_id: String,
	client_request_id: String,
	timestamp: float
) -> Dictionary:
	return {
		"call_id": request_id,
		"expires_at": timestamp + CALL_LIFETIME_SEC,
		"player_input": msg,
		"game_state": {},
		"additional_context": {
			"client_request_id": client_request_id,
			"companion_ref": "hermes_b",
			"routing_mode": "text_only",
		},
		"timestamp": timestamp,
		"request_id": request_id,
	}


func _validate_live_capture_result(value: Dictionary, client_request_id: String) -> bool:
	if not _has_exact_keys(value, CAPTURE_RESULT_SCHEMA):
		return false
	if value.get("client_request_id") != client_request_id:
		return false
	var capture_id: Variant = value.get("capture_id")
	if typeof(capture_id) != TYPE_STRING or not _matches_pattern(
		capture_id,
		"^cap_[0-9a-f]{32}_[1-9][0-9]*$"
	):
		return false
	var captured_at: Variant = value.get("captured_at")
	if typeof(captured_at) != TYPE_FLOAT and typeof(captured_at) != TYPE_INT:
		return false
	if not is_finite(float(captured_at)) or float(captured_at) <= 0.0:
		return false
	var perception_value: Variant = value.get("perception")
	if typeof(perception_value) != TYPE_DICTIONARY:
		return false
	var perception: Dictionary = perception_value
	if not _has_exact_keys(perception, PERCEPTION_SCHEMA):
		return false
	var perception_captured_at: Variant = perception.get("captured_at")
	if typeof(perception_captured_at) != TYPE_FLOAT and typeof(perception_captured_at) != TYPE_INT:
		return false
	if (
		perception.get("schema") != "engain.runtime_perception.v1"
		or perception.get("capture_id") != capture_id
		or perception.get("capture_event") != "message_received"
		or perception.get("capture_phase") != "pre_dispatch_player_view.v1"
		or float(perception_captured_at) != float(captured_at)
		or perception.get("project_id") != "godot_3d_avatar"
		or perception.get("scene_path") != "res://scenes/Main.tscn"
	):
		return false
	var viewport_value: Variant = perception.get("viewport")
	if typeof(viewport_value) != TYPE_DICTIONARY:
		return false
	var viewport: Dictionary = viewport_value
	if not _has_exact_keys(viewport, VIEWPORT_SCHEMA):
		return false
	var status: String = value["status"]
	if status == "full":
		return (
			value.get("failure_code") == null
			and perception.get("perception_state") == "full"
			and perception.get("unavailable_reason") == null
			and _validate_full_perception(
				perception,
				viewport,
				capture_id,
				client_request_id,
				float(captured_at)
			)
		)
	var failure_code: Variant = value.get("failure_code")
	return (
		typeof(failure_code) == TYPE_STRING
		and not failure_code.is_empty()
		and perception.get("perception_state") == "unavailable"
		and perception.get("snapshot") == null
		and perception.get("unavailable_reason") == "capture_failed"
		and viewport.get("availability") == "unavailable"
		and viewport.get("image_path") == null
		and viewport.get("image_sha256") == null
		and viewport.get("media_type") == null
		and viewport.get("width") == null
		and viewport.get("height") == null
		and viewport.get("reason") == "capture_failed"
	)


func _validate_full_perception(
	perception: Dictionary,
	viewport: Dictionary,
	capture_id: String,
	client_request_id: String,
	captured_at: float
) -> bool:
	if (
		viewport.get("availability") != "available"
		or viewport.get("image_path") != "snapshots/perception_%s.png" % capture_id
		or not _matches_pattern(str(viewport.get("image_sha256", "")), "^[0-9a-f]{64}$")
		or viewport.get("media_type") != "image/png"
		or typeof(viewport.get("width")) != TYPE_INT
		or typeof(viewport.get("height")) != TYPE_INT
		or int(viewport.get("width")) < 1
		or int(viewport.get("width")) > 8192
		or int(viewport.get("height")) < 1
		or int(viewport.get("height")) > 8192
		or viewport.get("reason") != null
	):
		return false
	var snapshot_value: Variant = perception.get("snapshot")
	if typeof(snapshot_value) != TYPE_DICTIONARY:
		return false
	var snapshot: Dictionary = snapshot_value
	if not _has_exact_keys(snapshot, SNAPSHOT_SCHEMA):
		return false
	if (
		snapshot.get("metadata_path") != "snapshots/perception_%s.json" % capture_id
		or not _matches_pattern(str(snapshot.get("metadata_sha256", "")), "^[0-9a-f]{64}$")
	):
		return false
	var metadata_value: Variant = snapshot.get("metadata")
	if typeof(metadata_value) != TYPE_DICTIONARY:
		return false
	var metadata: Dictionary = metadata_value
	if not _has_exact_keys(metadata, SNAPSHOT_METADATA_SCHEMA):
		return false
	var metadata_captured_at: Variant = metadata.get("captured_at")
	if typeof(metadata_captured_at) != TYPE_FLOAT and typeof(metadata_captured_at) != TYPE_INT:
		return false
	if (
		metadata.get("schema") != "engain.runtime_snapshot.v1"
		or metadata.get("capture_id") != capture_id
		or metadata.get("client_request_id") != client_request_id
		or metadata.get("capture_event") != "message_received"
		or metadata.get("capture_phase") != "pre_dispatch_player_view.v1"
		or float(metadata_captured_at) != captured_at
		or metadata.get("project_id") != "godot_3d_avatar"
		or metadata.get("scene_path") != "res://scenes/Main.tscn"
		or metadata.get("viewport") != viewport
	):
		return false
	var runtime_value: Variant = metadata.get("runtime")
	if typeof(runtime_value) != TYPE_DICTIONARY:
		return false
	var runtime: Dictionary = runtime_value
	if not _has_exact_keys(runtime, RUNTIME_SCHEMA):
		return false
	var fps: Variant = runtime.get("fps")
	var player_position_value: Variant = runtime.get("player_position")
	return (
		(typeof(fps) == TYPE_FLOAT or typeof(fps) == TYPE_INT)
		and is_finite(float(fps))
		and float(fps) >= 0.0
		and float(fps) <= 1000.0
		and typeof(runtime.get("current_location")) == TYPE_STRING
		and typeof(runtime.get("inventory")) == TYPE_ARRAY
		and (typeof(player_position_value) == TYPE_STRING or player_position_value == null)
	)


func _poll_response_mailbox() -> void:
	if not FileAccess.file_exists(RESPONSE_MAILBOX_PATH):
		return
	var claim := _execute_adapter(PackedStringArray(["--claim-response", RESPONSE_MAILBOX_PATH]))
	if claim["code"] != 0:
		_emit_err("Response claim failed: " + claim["output"])
		return
	var parsed: Variant = _decode_claimed_response(claim["output"])
	if parsed == null:
		_emit_err("Claimed response is malformed; active lifecycle continues.")
		return
	if not _busy or _active_request_id == "":
		_emit_err("stale response claimed and discarded; no active lifecycle.")
		return
	if not _validate_correlated_response(parsed):
		_emit_err("Response rejected as malformed, mismatched, or stale; waiting continues.")
		return

	var narrative: String = parsed["narrative_response"].strip_edges()
	_end_active_lifecycle()
	_emit_dragon(narrative)


func _decode_claimed_response(output: String) -> Variant:
	var marker := "ENGAIN_RESPONSE_JSON_BASE64="
	var encoded := ""
	for line in output.split("\n", false):
		if line.begins_with(marker):
			encoded = line.substr(marker.length()).strip_edges()
			break
	if encoded == "":
		return null
	var raw := Marshalls.base64_to_raw(encoded)
	if raw.is_empty():
		return null
	var parser := JSON.new()
	var parse_result := parser.parse(raw.get_string_from_utf8())
	if parse_result != OK:
		_emit_err("Claimed response JSON error: %s" % parser.get_error_message())
		return null
	var parsed: Variant = parser.data
	if typeof(parsed) != TYPE_DICTIONARY:
		return null
	return parsed


func _validate_correlated_response(value: Dictionary) -> bool:
	var response_schema := RESPONSE_SCHEMA.duplicate()
	if _active_call_id == "":
		response_schema.erase("call_id")
	if not _has_exact_keys(value, response_schema):
		return false
	if _active_call_id != "" and value.get("call_id") != _active_call_id:
		return false
	var request_id: Variant = value.get("request_id")
	if request_id != _active_request_id:
		return false
	var client_request_id: Variant = value.get("client_request_id")
	if client_request_id != _active_client_request_id:
		return false
	if typeof(value.get("narrative_response")) != TYPE_STRING:
		return false
	if value["narrative_response"].strip_edges() == "":
		return false
	if typeof(value.get("director_analysis")) != TYPE_STRING:
		return false
	if typeof(value.get("reasoning")) != TYPE_STRING:
		return false
	if value.get("action_type") != "OBSERVATION":
		return false
	if typeof(value.get("state_changes")) != TYPE_DICTIONARY or value["state_changes"].size() != 0:
		return false
	var entropy: Variant = value.get("entropy_impact")
	if typeof(entropy) != TYPE_FLOAT and typeof(entropy) != TYPE_INT:
		return false
	if not is_finite(float(entropy)) or float(entropy) != 0.0:
		return false
	var response_timestamp: Variant = value.get("timestamp")
	if typeof(response_timestamp) != TYPE_FLOAT and typeof(response_timestamp) != TYPE_INT:
		return false
	if not is_finite(float(response_timestamp)):
		return false
	if not _validate_provider_session(value.get("provider_session_ref")):
		return false
	return _validate_perception_result(value.get("perception_result"))


func _validate_provider_session(value: Variant) -> bool:
	if typeof(value) != TYPE_DICTIONARY or not _has_exact_keys(value, PROVIDER_SESSION_SCHEMA):
		return false
	return (
		value.get("companion_ref") == "hermes_b"
		and value.get("provider") == "openai-codex"
		and value.get("model") == "gpt-5.6-sol"
		and value.get("session_id") == FROZEN_SESSION_ID
	)


func _validate_perception_result(value: Variant) -> bool:
	if typeof(value) != TYPE_DICTIONARY or not _has_exact_keys(value, PERCEPTION_RESULT_SCHEMA):
		return false
	if value.get("schema") != "engain.runtime_perception_result.v1":
		return false
	if value.get("requested_state") not in ["full", "structured_only", "unavailable", "not_requested"]:
		return false
	if value.get("effective_state") not in ["full", "structured_only", "unavailable", "rejected", "not_requested"]:
		return false
	if typeof(value.get("structured_snapshot_supplied")) != TYPE_BOOL:
		return false
	if typeof(value.get("viewport_image_attached")) != TYPE_BOOL:
		return false
	var originating_text_only := _active_capture_id == ""
	if value.get("requested_state") == "not_requested" or value.get("effective_state") == "not_requested":
		return (
			originating_text_only
			and value.get("requested_state") == "not_requested"
			and value.get("effective_state") == "not_requested"
			and value.get("capture_id") == null
			and value.get("capture_event") == null
			and value.get("capture_phase") == null
			and value.get("captured_at") == null
			and value.get("metadata_sha256") == null
			and value.get("image_sha256") == null
			and value.get("structured_snapshot_supplied") == false
			and value.get("viewport_image_attached") == false
			and value.get("failure_code") == null
		)
	if originating_text_only:
		return false
	if value.get("effective_state") == "rejected":
		return true
	return (
		value.get("capture_id") == _active_capture_id
		and value.get("capture_event") == "message_received"
		and value.get("capture_phase") == "pre_dispatch_player_view.v1"
	)


func _has_exact_keys(value: Dictionary, schema: Array[String]) -> bool:
	var keys := value.keys()
	if keys.size() != schema.size():
		return false
	for key in keys:
		if key not in schema:
			return false
	return true


func _matches_pattern(value: String, pattern: String) -> bool:
	var expression := RegEx.new()
	if expression.compile(pattern) != OK:
		return false
	return expression.search(value) != null


func _execute_adapter(arguments: PackedStringArray) -> Dictionary:
	var output: Array = []
	var args := PackedStringArray([ADAPTER_PATH])
	args.append_array(arguments)
	var code := OS.execute(PYTHON_EXECUTABLE, args, output, true)
	var combined := ""
	for item in output:
		combined += str(item)
	return {"code": code, "output": combined.strip_edges()}


func _set_lifecycle_status(status: String) -> void:
	if status not in [STATUS_IDLE, STATUS_LOOKING_INTERNAL, STATUS_THINKING]:
		return
	if lifecycle_status == status:
		return
	lifecycle_status = status
	emit_signal("status_changed", status)


func _end_active_lifecycle() -> void:
	var was_speaking := _dragon_speaking_active
	_lifecycle_generation += 1
	_busy = false
	_capture_pending = false
	_dragon_speaking_active = false
	_active_request_id = ""
	_active_call_id = ""
	_active_client_request_id = ""
	_active_capture_id = ""
	_active_route = ""
	_active_started_msec = 0
	_set_lifecycle_status("IDLE") # Clear LOOKING_INTERNAL or THINKING.
	if was_speaking:
		emit_signal("dragon_speaking", false)


func _reject_busy(detail: String) -> void:
	_emit_err(MAILBOX_BUSY + ": " + detail)


func _random_hex_16() -> String:
	var random_bytes := _crypto.generate_random_bytes(16)
	return random_bytes.hex_encode()


func _emit_user(text: String) -> void:
	emit_signal("log_line", "user", text)


func _emit_dragon(text: String) -> void:
	emit_signal("log_line", "dragon", text)


func _emit_lore(text: String) -> void:
	emit_signal("log_line", "lore", text)


func _emit_sys(text: String) -> void:
	emit_signal("log_line", "sys", text)


func _emit_err(text: String) -> void:
	emit_signal("log_line", "err", text)
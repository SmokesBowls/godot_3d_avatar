# scripts/EngAInBridge3D.gd
extends Node

signal log_line(kind: String, text: String) # "user" | "dragon" | "lore" | "sys" | "err"
signal dragon_speaking(active: bool)

@export var server_base_url: String = "http://127.0.0.1:8081"
@export var request_timeout_sec: float = 20.0

# Optional: set these from Main if you want.
var session_id: String = ""
var user_name: String = "You"
var dragon_name: String = "Dragon"
var lore_name: String = "Mr. Lore"

var _http: HTTPRequest
var _busy: bool = false

func _ready() -> void:
	_http = HTTPRequest.new()
	add_child(_http)
	_http.timeout = request_timeout_sec
	_http.request_completed.connect(_on_request_completed)

	if session_id.strip_edges() == "":
		session_id = _gen_session_id()

	_emit_sys("Bridge ready. session_id=%s server=%s" % [session_id, server_base_url])

func submit(text: String) -> void:
	var msg := text.strip_edges()
	if msg == "":
		return
	if _busy:
		_emit_err("Busy: wait for response.")
		return

	_emit_user(msg)

	var payload := _build_payload(msg)
	var json := JSON.stringify(payload)

	var headers := PackedStringArray([
		"Content-Type: application/json",
		"Accept: application/json",
	])

	_busy = true
	emit_signal("dragon_speaking", true)

	var url := server_base_url.rstrip("/") + "/v1/engain/parse"
	var err := _http.request(url, headers, HTTPClient.METHOD_POST, json)
	if err != OK:
		_busy = false
		emit_signal("dragon_speaking", false)
		_emit_err("HTTPRequest error=%s" % str(err))

func _build_payload(msg: String) -> Dictionary:
	# Protocol:
	# - "/..." means collaboration intent routed to Mr. Lore
	# - otherwise natural language routed to Dragon speech
	var is_command := msg.begins_with("/")

	return {
		"session_id": session_id,
		"client": {
			"engine": "godot",
			"bridge": "EngAInBridge3D",
			"version": "0.1.0"
		},
		"input": {
			"raw": msg,
			"type": "command" if is_command else "speech"
		},
		"actors": {
			"user": user_name,
			"dragon": dragon_name,
			"lore": lore_name
		},
		"ts_unix_ms": Time.get_unix_time_from_system() * 1000
	}

func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	_busy = false
	emit_signal("dragon_speaking", false)

	if result != HTTPRequest.RESULT_SUCCESS:
		_emit_err("HTTP failed result=%s code=%s" % [str(result), str(response_code)])
		return

	var body_text := body.get_string_from_utf8()
	var parsed: Variant = JSON.parse_string(body_text)
	if typeof(parsed) != TYPE_DICTIONARY:
		_emit_err("Invalid JSON from server.")
		return

	if response_code < 200 or response_code >= 300:
		var detail := ""
		if parsed.has("error"):
			detail = str(parsed["error"])
		_emit_err("Server error code=%s %s" % [str(response_code), detail])
		return

	# Expect:
	# {
	#   "ok": true,
	#   "route": "dragon"|"lore",
	#   "text": "...",
	#   "events": [... optional ...],
	#   "log": [... optional ...]
	# }
	var route := str(parsed.get("route", "dragon"))
	var text := str(parsed.get("text", ""))

	if text.strip_edges() == "":
		_emit_err("Empty response.")
		return

	if route == "lore":
		_emit_lore(text)
	else:
		_emit_dragon(text)

	# Optional: structured events for later expansion
	if parsed.has("events") and typeof(parsed["events"]) == TYPE_ARRAY:
		for ev in parsed["events"]:
			_emit_sys("event=" + JSON.stringify(ev))

func _emit_user(t: String) -> void:
	emit_signal("log_line", "user", t)

func _emit_dragon(t: String) -> void:
	emit_signal("log_line", "dragon", t)

func _emit_lore(t: String) -> void:
	emit_signal("log_line", "lore", t)

func _emit_sys(t: String) -> void:
	emit_signal("log_line", "sys", t)

func _emit_err(t: String) -> void:
	emit_signal("log_line", "err", t)

func _gen_session_id() -> String:
	var dt := Time.get_datetime_dict_from_system()
	var stamp := "%04d%02d%02d_%02d%02d%02d" % [dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second]
	var r := str(randi() % 100000).pad_zeros(5)
	return "S_" + stamp + "_" + r
@tool
extends Control

## hermes_dock.gd - The Hermes Editor dock's visible interface only:
## transcript, input, send, status/stop. Owns no Hermes process logic —
## all of that lives in hermes_bridge.gd; this file wires UI events to
## it and renders whatever it reports back. Built procedurally (no
## .tscn) so there is no separate scene resource to keep in sync with
## this script — see plugin.gd for why that's a safe substitution here.

var editor_interface: Object  # set by plugin.gd, matching godot_ollama_task_performer/assist_dock.gd's own convention

const HermesBridgeScript := preload("res://addons/hermes_editor/hermes_bridge.gd")

var _bridge: Node
var _busy: bool = false

var _transcript: TextEdit
var _input: LineEdit
var _send_button: Button
var _stop_button: Button
var _status_label: Label
var _model_input: LineEdit
var _provider_input: LineEdit


func _ready() -> void:
	_build_ui()
	_bridge = HermesBridgeScript.new()
	add_child(_bridge)
	_bridge.turn_finished.connect(_on_turn_finished)
	_status_label.text = "Ready. cwd = " + HermesBridgeScript.project_root()


func _build_ui() -> void:
	var root := VBoxContainer.new()
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.custom_minimum_size = Vector2(0, 280)
	add_child(root)

	var config_row := HBoxContainer.new()
	root.add_child(config_row)

	var model_label := Label.new()
	model_label.text = "Model:"
	config_row.add_child(model_label)
	_model_input = LineEdit.new()
	_model_input.placeholder_text = "(hermes default)"
	_model_input.custom_minimum_size = Vector2(200, 0)
	config_row.add_child(_model_input)

	var provider_label := Label.new()
	provider_label.text = "Provider:"
	config_row.add_child(provider_label)
	_provider_input = LineEdit.new()
	_provider_input.placeholder_text = "(hermes default)"
	_provider_input.custom_minimum_size = Vector2(160, 0)
	config_row.add_child(_provider_input)

	_transcript = TextEdit.new()
	_transcript.editable = false
	_transcript.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_transcript.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_transcript.custom_minimum_size = Vector2(0, 200)
	root.add_child(_transcript)

	var input_row := HBoxContainer.new()
	input_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(input_row)

	_input = LineEdit.new()
	_input.placeholder_text = "Message Hermes... (native tools: files, shell, search, tests)"
	_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_input.text_submitted.connect(func(_new_text: String) -> void: _on_send_pressed())
	input_row.add_child(_input)

	_send_button = Button.new()
	_send_button.text = "Send"
	_send_button.pressed.connect(_on_send_pressed)
	input_row.add_child(_send_button)

	_stop_button = Button.new()
	_stop_button.text = "Stop"
	_stop_button.disabled = true
	_stop_button.tooltip_text = "Discards the reply when it arrives. Cannot forcibly kill the Hermes process (see hermes_bridge.gd's request_stop() doc)."
	_stop_button.pressed.connect(_on_stop_pressed)
	input_row.add_child(_stop_button)

	_status_label = Label.new()
	root.add_child(_status_label)


func _on_send_pressed() -> void:
	if _busy:
		return
	var message := _input.text.strip_edges()
	if message.is_empty():
		return
	_append_transcript("you: " + message)
	_input.text = ""
	_busy = true
	_send_button.disabled = true
	_stop_button.disabled = false
	_status_label.text = "Waiting for Hermes..."
	_bridge.send(message, _model_input.text.strip_edges(), _provider_input.text.strip_edges())


func _on_stop_pressed() -> void:
	_bridge.request_stop()
	_status_label.text = "Discarding the in-flight reply when it returns (process keeps running — see Stop's tooltip)."
	_stop_button.disabled = true


func _on_turn_finished(result: Dictionary) -> void:
	_busy = false
	_send_button.disabled = false
	_stop_button.disabled = true

	if not result.get("success", false):
		_append_transcript("[error] " + String(result.get("error", "unknown error")))
		_status_label.text = "Error — see transcript."
		return

	_append_transcript("hermes: " + String(result.get("response", "")))
	var sid := String(result.get("session_id", ""))
	if sid.is_empty():
		_status_label.text = "Ready. (no session_id reported this turn)"
	else:
		_status_label.text = "Ready. session=" + sid


func _append_transcript(line: String) -> void:
	_transcript.text += line + "\n\n"
	_transcript.set_caret_line(_transcript.get_line_count())

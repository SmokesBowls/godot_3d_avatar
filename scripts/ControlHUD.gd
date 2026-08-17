extends CanvasLayer

@onready var output: RichTextLabel = $Output
@onready var input: LineEdit = $CollaborationInput
@onready var send_btn: Button = $SendLoreButton
@onready var lifecycle_status: Label = $LifecycleStatus

# Pod layout:
# Main
#  - World/DragonAvatar3D/EngAInBridge
#  - UI/ControlHUD (this)
@export var bridge_path: NodePath = ^"../../World/DragonAvatar3D/EngAInBridge"

var _bridge: Node = null

func _ready() -> void:
	_bridge = get_node_or_null(bridge_path)
	if _bridge == null:
		_append("err", "ControlHUD: bridge not found at %s" % str(bridge_path))
		return

	if _bridge.has_signal("log_line"):
		_bridge.connect("log_line", Callable(self, "_on_log_line"))
	if _bridge.has_signal("submission_committed"):
		_bridge.connect("submission_committed", Callable(self, "_on_submission_committed"))
	if _bridge.has_signal("status_changed"):
		_bridge.connect("status_changed", Callable(self, "_on_status_changed"))
		_on_status_changed(str(_bridge.get("lifecycle_status")))

	input.text_submitted.connect(_on_input_submitted)
	send_btn.pressed.connect(_on_send_pressed)

	_append("sys", "ControlHUD online. Enter=send. Button=/uplift test.")

func _on_input_submitted(text: String) -> void:
	var msg := text.strip_edges()
	if msg == "":
		return
	_bridge.call("submit", msg)

func _on_send_pressed() -> void:
	_bridge.call("submit", "/uplift ch22_3d_test")


func _on_submission_committed(client_request_id: String, submitted_text: String) -> void:
	if client_request_id.is_empty():
		return
	if input.text == submitted_text:
		input.clear()


func _on_log_line(kind: String, text: String) -> void:
	_append(kind, text)


func _on_status_changed(status: String) -> void:
	if status == "THINKING":
		lifecycle_status.text = "Dragon is thinking..."
	elif status == "IDLE":
		lifecycle_status.text = ""


func _append(kind: String, text: String) -> void:
	var color := "white"
	var label := kind

	match kind:
		"user":  color = "#FFD54A"; label = "YOU"
		"dragon": color = "#4DD0E1"; label = "DRAGON"
		"lore":  color = "#FFB74D"; label = "LORE"
		"sys":   color = "#B0BEC5"; label = "SYS"
		"err":   color = "#EF5350"; label = "ERR"
		_:       color = "white";   label = kind.to_upper()

	output.append_text("[color=%s][%s][/color] %s\n" % [color, label, text])
	output.scroll_to_line(output.get_line_count())

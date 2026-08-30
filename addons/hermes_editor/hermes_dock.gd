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
const LifecycleProbe := preload("res://addons/hermes_editor/_lifecycle_probe.gd")
const EditReceiptStore := preload("res://addons/hermes_editor/edit_receipt_store.gd")

var _bridge: Node
var _busy: bool = false
var _temporary_trial_ui_applied: bool = false

var _transcript: TextEdit
var _input: LineEdit
var _send_button: Button
var _stop_button: Button
var _status_label: Label
var _model_input: LineEdit
var _provider_input: LineEdit
var _mode_selector: OptionButton
var _restart_runtime_button: Button
var _receipts_list: VBoxContainer


func _ready() -> void:
	_dock_trace("_ready: begin")
	_build_ui()
	_bridge = HermesBridgeScript.new()
	add_child(_bridge)
	_bridge.turn_finished.connect(_on_turn_finished)
	# Install-time-only scratch setup (creates .hermes_scratch/, adds it
	# to .gitignore) — runs once here, when the plugin activates, NOT
	# per-turn inside the bridge. See hermes_bridge.gd's own doc on
	# _ensure_scratch_setup() for why this was moved out of _run_hermes().
	HermesBridgeScript._ensure_scratch_setup(HermesBridgeScript.project_root())
	_ensure_temporary_trial_ui()
	_dock_trace("_ready: end (bridge_id=%d)" % _bridge.get_instance_id())


## INSTRUMENTATION — routes every dock trace line through one place so
## dock_id is on EVERY line. pid is added by LifecycleProbe.trace()
## itself.
func _dock_trace(event: String) -> void:
	LifecycleProbe.trace("dock_id=%d | %s" % [get_instance_id(), event])


## See _lifecycle_probe.gd. Answers, for the dock Control itself (not
## the bridge Node — see hermes_bridge.gd's own _notification()),
## whether an external Main.tscn reload ever frees, exits, or unparents
## this dock.
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_dock_trace("_notification: NOTIFICATION_PREDELETE")
	elif what == NOTIFICATION_EXIT_TREE:
		_dock_trace("_notification: NOTIFICATION_EXIT_TREE")
	elif what == NOTIFICATION_UNPARENTED:
		_dock_trace("_notification: NOTIFICATION_UNPARENTED")


func _process(_delta: float) -> void:
	# Existing editor docks survive script hot reload. Upgrade the old,
	# disabled DIRECT WRITE row in place so the bridge node — and its
	# in-memory Hermes session_id — do not have to be destroyed/recreated.
	if not _temporary_trial_ui_applied and not _busy:
		_ensure_temporary_trial_ui()


func _ensure_temporary_trial_ui() -> void:
	if _mode_selector == null or _mode_selector.item_count < 2:
		return
	_mode_selector.set_item_text(1, "DIRECT WRITE — TEMPORARY LIVE TRIAL")
	_mode_selector.set_item_disabled(1, false)
	_mode_selector.disabled = false
	var callback := Callable(self, "_on_mode_selected")
	if not _mode_selector.item_selected.is_connected(callback):
		_mode_selector.item_selected.connect(callback)
	_mode_selector.select(1)
	_temporary_trial_ui_applied = true
	_on_mode_selected(1)


func _build_ui() -> void:
	var root := VBoxContainer.new()
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.custom_minimum_size = Vector2(0, 280)
	add_child(root)

	# Explicit, reversible mode indicator. DIRECT WRITE is temporarily
	# enabled for a user-authorized maturity experiment; SAFE/REVIEW stays
	# available so the safety boundary can be restored immediately.
	var mode_row := HBoxContainer.new()
	root.add_child(mode_row)
	var mode_label := Label.new()
	mode_label.text = "Mode:"
	mode_row.add_child(mode_label)
	_mode_selector = OptionButton.new()
	_mode_selector.add_item("SAFE / REVIEW — proposals only, in .hermes_scratch/", 0)
	_mode_selector.add_item("DIRECT WRITE — TEMPORARY LIVE TRIAL", 1)
	_mode_selector.select(1)
	_mode_selector.item_selected.connect(_on_mode_selected)
	_mode_selector.tooltip_text = "Temporary maturity test. DIRECT WRITE permits live project edits; SAFE/REVIEW restores scratch-only proposals. Per-turn fingerprints remain as an audit trail."
	mode_row.add_child(_mode_selector)

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

	_restart_runtime_button = Button.new()
	_restart_runtime_button.text = "Restart Composed Runtime"
	_restart_runtime_button.tooltip_text = "Save scene changes, then replace only the canonical launcher's composed-runtime child. The editor and Hermes session stay open; Play/F6 remains non-authoritative."
	_restart_runtime_button.pressed.connect(_on_restart_runtime_pressed)
	config_row.add_child(_restart_runtime_button)

	_transcript = TextEdit.new()
	_transcript.editable = false
	_transcript.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_transcript.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_transcript.custom_minimum_size = Vector2(0, 200)
	root.add_child(_transcript)

	# Mechanical, one-time revert per DIRECT_WRITE edit — see
	# edit_receipt_store.gd. Deliberately its own row per edit, not a
	# chat message: pressing it never sends anything to Hermes.
	var receipts_label := Label.new()
	receipts_label.text = "Edit receipts (one-time revert, no agent involved):"
	root.add_child(receipts_label)

	var receipts_scroll := ScrollContainer.new()
	receipts_scroll.custom_minimum_size = Vector2(0, 90)
	receipts_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(receipts_scroll)

	_receipts_list = VBoxContainer.new()
	_receipts_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	receipts_scroll.add_child(_receipts_list)

	var input_row := HBoxContainer.new()
	input_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(input_row)

	_input = LineEdit.new()
	_input.placeholder_text = "Message Hermes... (native tools: files, shell, search, tests — proposals go to .hermes_scratch/)"
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
	_mode_selector.disabled = true
	_status_label.text = "Waiting for Hermes..."
	var selected_mode := (
		HermesBridgeScript.MODE_DIRECT_WRITE
		if _mode_selector.get_selected_id() == 1
		else HermesBridgeScript.MODE_SAFE_REVIEW
	)
	_bridge.send(
		message,
		_model_input.text.strip_edges(),
		_provider_input.text.strip_edges(),
		selected_mode
	)


func _on_mode_selected(_index: int) -> void:
	if _mode_selector.get_selected_id() == 1:
		_input.placeholder_text = "Message Hermes... (TEMPORARY DIRECT WRITE: edits land in the live project)"
		_status_label.text = "⚠ DIRECT WRITE LIVE TRIAL armed. Live edits are enabled; fingerprints remain as audit evidence."
	else:
		_input.placeholder_text = "Message Hermes... (SAFE/REVIEW: proposals go to .hermes_scratch/)"
		_status_label.text = "SAFE/REVIEW restored. Proposals only; live edits are violations."


func _on_stop_pressed() -> void:
	_bridge.request_stop()
	_status_label.text = "Discarding the in-flight reply when it returns (process keeps running — see Stop's tooltip)."
	_stop_button.disabled = true


func _on_restart_runtime_pressed() -> void:
	var helper_path := ProjectSettings.globalize_path("res://restart_dragon3d_runtime.sh")
	var output: Array = []
	var exit_code := OS.execute(helper_path, PackedStringArray(), output, true)
	var detail := ""
	for line: Variant in output:
		detail += String(line)
	detail = detail.strip_edges()
	if exit_code == 0:
		_status_label.text = "Composed runtime restart requested. Editor and Hermes session remain open."
	else:
		_status_label.text = "Restart unavailable: " + (detail if not detail.is_empty() else "helper exited %d" % exit_code)


func _on_turn_finished(result: Dictionary) -> void:
	_busy = false
	_send_button.disabled = false
	_stop_button.disabled = true
	_mode_selector.disabled = false

	# Safe-mode audit — checked FIRST and regardless of success/error,
	# since a live-tree violation matters even on an otherwise-failed
	# turn. This is the "not just being told" enforcement: an automated
	# check against real `git status`, not trust in Hermes's own
	# compliance. See hermes_bridge.gd's diff_live_tree_changes().
	var changes: PackedStringArray = result.get("live_tree_changes", PackedStringArray())
	var turn_mode := String(result.get("mode", HermesBridgeScript.MODE_SAFE_REVIEW))
	var direct_turn := turn_mode == HermesBridgeScript.MODE_DIRECT_WRITE
	var safety_violation := not direct_turn and not changes.is_empty()
	if direct_turn and not changes.is_empty():
		var audit := "DIRECT WRITE AUDIT — live project changes observed this turn:\n"
		for change in changes:
			audit += "    " + String(change) + "\n"
		audit += "  Review this list against the exact request before restarting the runtime."
		_append_transcript(audit)
	elif safety_violation:
		var warning := "⚠ SAFETY VIOLATION — live project file(s) changed outside .hermes_scratch/ this turn:\n"
		for v in changes:
			warning += "    " + String(v) + "\n"
		warning += "  Review with `git diff` / `git status` before trusting anything else this session did."
		_append_transcript(warning)
	elif not result.get("safety_check_available", false):
		_append_transcript("⚠ Live-tree fingerprint audit unavailable this turn — changes were NOT verified. Check manually.")

	var edit_id := String(result.get("edit_id", ""))
	if not edit_id.is_empty():
		var receipt_state := String(result.get("edit_receipt_state", ""))
		if receipt_state == "AVAILABLE":
			_add_edit_receipt_row(edit_id, result.get("edit_receipt_paths", []))
		elif receipt_state == "ERROR":
			_append_transcript("⚠ Edit receipt for %s could not be fully backed up — Revert is unavailable for this edit. Inspect changes manually (git diff / git status)." % edit_id)

	if not result.get("success", false):
		_append_transcript("[error] " + String(result.get("error", "unknown error")))
		_status_label.text = "SAFETY VIOLATION + error — see transcript." if safety_violation else "Error — see transcript."
		return

	_append_transcript("hermes: " + String(result.get("response", "")))
	var sid := String(result.get("session_id", ""))
	var base_status := "Ready. session=%s" % sid if not sid.is_empty() else "Ready. (no session_id reported this turn)"
	if safety_violation:
		_status_label.text = "⚠ SAFETY VIOLATION last turn — " + base_status
	elif direct_turn:
		_status_label.text = "DIRECT WRITE trial turn complete — " + base_status
	else:
		_status_label.text = base_status


func _append_transcript(line: String) -> void:
	_transcript.text += line + "\n\n"
	_transcript.set_caret_line(_transcript.get_line_count())


## One row per DIRECT_WRITE turn that actually touched the live tree.
## The button is mechanical (EditReceiptStore.revert()) — pressing it
## never sends anything to Hermes and never runs a model.
func _add_edit_receipt_row(edit_id: String, paths: Array) -> void:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var summary := Label.new()
	summary.text = "%s — %d path(s) changed" % [edit_id, paths.size()]
	summary.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(summary)

	var revert_button := Button.new()
	revert_button.text = "Revert this edit"
	revert_button.tooltip_text = "Mechanical, one-time restore of the exact pre-edit bytes. No prompt, no model. Refuses automatically if a later edit touched any of these paths."
	revert_button.pressed.connect(func() -> void: _on_revert_pressed(edit_id, summary, revert_button))
	row.add_child(revert_button)

	_receipts_list.add_child(row)


func _on_revert_pressed(edit_id: String, summary_label: Label, button: Button) -> void:
	button.disabled = true
	var result: Dictionary = EditReceiptStore.revert(edit_id, HermesBridgeScript.project_root())
	var status := String(result.get("status", ""))
	var message := String(result.get("message", ""))
	var affected: PackedStringArray = result.get("affected_paths", PackedStringArray())
	if not affected.is_empty():
		message += "\n    " + "\n    ".join(affected)
	_append_transcript("[revert %s] %s" % [edit_id, message])

	match status:
		"reverted":
			summary_label.text += "  — reverted"
			button.text = "Reverted"
			_status_label.text = "Reverted edit %s." % edit_id
		"failed_unrecoverable":
			summary_label.text += "  — ERROR, manual review needed"
			button.text = "Error — see transcript"
			_status_label.text = "⚠ Revert of %s could not fully recover — see transcript." % edit_id
		_:
			# refused_mismatch / refused_missing / refused_state /
			# refused_prepare_failed / failed_recovered — receipt stays
			# AVAILABLE, so the button stays usable.
			button.disabled = false
			button.text = "Revert this edit"
			_status_label.text = message.split("\n")[0]

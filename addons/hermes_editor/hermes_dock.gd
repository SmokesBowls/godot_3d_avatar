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
var _dragon_requests_list: VBoxContainer
var _dragon_request_rows: Dictionary = {}  # outbox path (String) -> row Control
var _pending_dragon_request: Dictionary = {}  # {} when no coordination turn is in flight
var _pending_dragon_request_path: String = ""
var _dragon_poll_accumulator_sec: float = 0.0

# DISABLED (2026-09-14) — the automatic mtime-triggered call to
# _experimental_reload_edited_scene_via_api() that used to be armed and
# polled from here was proven unsafe, not merely unproven: a real live
# turn (amber_cube_probe_08) showed every project write finished cleanly
# BEFORE the call, the call itself returned normally, and Godot's editor
# still SIGABRTed moments later during its own asynchronous post-reload
# reconciliation. See that day's receipt for the full before/after mtime
# and Hermes-transcript triangulation. The arming/polling machinery
# (baseline mtime, poll accumulator, fired-this-turn flag) is removed
# entirely rather than left dormant, so nothing can silently re-trigger
# it. _experimental_reload_edited_scene_via_api() itself is left in
# place, disabled and clearly marked — see its own doc — as a record of
# what was tried, not as something to re-enable without a different
# mechanism. Editor/Main.tscn synchronization after a DIRECT_WRITE edit
# is treated as a separate, open problem, not solved by this file.
const _EXPERIMENTAL_RELOAD_SCENE_PATH := "res://scenes/Main.tscn"
const _DRAGON_POLL_INTERVAL_SEC := 1.0

# Additional recipient (Phase 0, human-relayed) — see hermes_bridge.gd's
# format_report_for_chatgpt_dragon() doc. Holds the most recent formatted
# block so the copy button always copies exactly what was last appended
# to the transcript, without re-deriving it from the (already-filed) report.
var _last_chatgpt_dragon_report: String = ""
var _copy_chatgpt_report_button: Button


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


func _process(delta: float) -> void:
	# Existing editor docks survive script hot reload. Upgrade the old,
	# disabled DIRECT WRITE row in place so the bridge node — and its
	# in-memory Hermes session_id — do not have to be destroyed/recreated.
	if not _temporary_trial_ui_applied and not _busy:
		_ensure_temporary_trial_ui()

	# Phase 1 sideband coordination lane: cheap, throttled discovery poll
	# of the shared outbox (see hermes_bridge.gd's own "Phase 1 sideband
	# coordination lane" block). Discovery is non-destructive — a request
	# only leaves the outbox once a human has actually executed it (see
	# _process_dragon_coordination_request()) — so polling repeatedly is
	# safe; _dragon_request_rows just prevents re-adding a row for one
	# already shown.
	_dragon_poll_accumulator_sec += delta
	if _dragon_poll_accumulator_sec >= _DRAGON_POLL_INTERVAL_SEC:
		_dragon_poll_accumulator_sec = 0.0
		for entry in HermesBridgeScript.list_pending_dragon_requests():
			var path: String = entry["path"]
			if not _dragon_request_rows.has(path):
				_add_dragon_request_row(entry["request"], path)

	# The mtime-triggered automatic call to
	# _experimental_reload_edited_scene_via_api() that used to live here
	# was removed 2026-09-14 -- proven unsafe, not just unproven. See
	# that function's own doc and that day's receipt.


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

	# Phase 1 sideband coordination lane. Human-confirm only, deliberately
	# — see hermes_bridge.gd's own list_pending_dragon_requests()/
	# write_editor_report() doc and _process_dragon_coordination_request()
	# below. A pending Dragon request never runs on its own; it only ever
	# runs because a human pressed this button, and it always runs as
	# DIRECT_WRITE — the request body itself never selects or escalates
	# authority mode.
	var dragon_requests_label := Label.new()
	dragon_requests_label.text = "Pending Dragon requests (human-confirm, DIRECT_WRITE):"
	root.add_child(dragon_requests_label)

	var dragon_requests_scroll := ScrollContainer.new()
	dragon_requests_scroll.custom_minimum_size = Vector2(0, 90)
	dragon_requests_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(dragon_requests_scroll)

	_dragon_requests_list = VBoxContainer.new()
	_dragon_requests_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dragon_requests_scroll.add_child(_dragon_requests_list)

	# Additional recipient (Phase 0, human-relayed) — see hermes_bridge.gd's
	# format_report_for_chatgpt_dragon() doc. Disabled until a coordinated
	# edit has actually produced a report; copies to the OS clipboard so it
	# can be pasted straight into the ChatGPT "avatar dragon" tab.
	_copy_chatgpt_report_button = Button.new()
	_copy_chatgpt_report_button.text = "Copy last report for ChatGPT Dragon"
	_copy_chatgpt_report_button.disabled = true
	_copy_chatgpt_report_button.tooltip_text = "Copies the most recent Editor->Dragon status block to the clipboard for pasting into the ChatGPT avatar-dragon conversation. No automated channel to that conversation exists yet — this is a manual handoff."
	_copy_chatgpt_report_button.pressed.connect(_on_copy_chatgpt_report_pressed)
	root.add_child(_copy_chatgpt_report_button)

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
		# An experimental automatic reload_scene_from_path() call used to
		# be wired here, then moved to an earlier mtime-triggered poll,
		# then removed entirely (2026-09-14) once that earlier call site
		# was shown to survive its own invocation but be followed by a
		# Godot-internal SIGABRT moments later. See
		# _experimental_reload_edited_scene_via_api()'s own doc.
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

	# Phase 1 sideband coordination lane: if this turn was executed via
	# _process_dragon_coordination_request(), file the Editor report
	# regardless of whether the turn succeeded or failed — the report's
	# whole job is to say what happened, including a failure, and Dragon
	# should hear about a failure just as much as a success. Captured and
	# cleared here, unconditionally, before either branch below returns.
	if not _pending_dragon_request.is_empty():
		var completed_request := _pending_dragon_request
		var completed_path := _pending_dragon_request_path
		_pending_dragon_request = {}
		_pending_dragon_request_path = ""
		# Built once, then written to the proven dragon3d<->Editor lane AND
		# formatted for the separate ChatGPT relay below, so a real
		# headless-validation spawn (inside build_editor_report()) never
		# runs twice for one edit.
		var report := HermesBridgeScript.build_editor_report(completed_request, result)
		var write_err := HermesBridgeScript.write_report_dict(report)
		if write_err != OK:
			_append_transcript("⚠ Could not file the Editor report back to Dragon (error %d) — the edit itself is unaffected, but Dragon will not hear about it this turn." % write_err)
		HermesBridgeScript.mark_dragon_request_handled(completed_path)
		var entry: Variant = _dragon_request_rows.get(completed_path)
		if typeof(entry) == TYPE_DICTIONARY:
			var row: Control = entry.get("row")
			if row != null and is_instance_valid(row):
				row.queue_free()
		_dragon_request_rows.erase(completed_path)
		_append_transcript("[editor→dragon] report filed for: " + String(completed_request.get("body", "")))

		# Additional recipient (Phase 0, human-relayed) — does not affect
		# the dragon3d<->Editor lane above in any way. See
		# format_report_for_chatgpt_dragon()'s own doc for why this is a
		# copy-paste handoff rather than an automated push.
		_last_chatgpt_dragon_report = HermesBridgeScript.format_report_for_chatgpt_dragon(report)
		_append_transcript(_last_chatgpt_dragon_report)
		_copy_chatgpt_report_button.disabled = false

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


func _on_copy_chatgpt_report_pressed() -> void:
	if _last_chatgpt_dragon_report.is_empty():
		return
	DisplayServer.clipboard_set(_last_chatgpt_dragon_report)
	_status_label.text = "Copied last Editor report to clipboard for ChatGPT Dragon."


func _append_transcript(line: String) -> void:
	_transcript.text += line + "\n\n"
	_transcript.set_caret_line(_transcript.get_line_count())


## DISABLED (2026-09-14) — PROVEN UNSAFE FOR THIS WORKFLOW, DO NOT RE-ENABLE
## the automatic mtime-triggered call this function used to receive
## without first finding a genuinely different mechanism. See
## _lifecycle_probe.gd's own doc and that day's design notes/receipts on
## the composed-editor SIGSEGV/SIGABRT-on-external-reload investigation
## for the full history. Kept in place, uncalled, as a record of what was
## tried and why it was rejected — not as something to wire back in.
##
## Decisive result (amber_cube_probe_08, 2026-09-14): triangulated via
## both raw filesystem mtimes and Hermes's own exported session
## transcript — every real project write (creating the new scene,
## patching Main.tscn) finished BEFORE this call fired; nothing changed
## afterward; this call itself returned normally
## ("reload_scene_from_path returned normally" is the last thing logged);
## and Godot's editor process still SIGABRTed moments later, during its
## own asynchronous post-reload reconciliation (confirmed by a
## `.godot/editor/*-editstate-*.cfg` write one second after the return,
## exactly the kind of internal engine bookkeeping a reload triggers).
## The "reloading while Hermes might still be writing" theory this
## function's own doc originally flagged as an open, accepted risk is
## therefore RULED OUT as the cause — the crash happens even when the
## write is already fully complete and stable on disk. The API avoids
## aborting synchronously inside the call (unlike the human "Reload from
## disk" dialog, which never returns at all), but something in Godot's
## own follow-on reconciliation is not survivable either way. Editor/
## Main.tscn synchronization after a live DIRECT_WRITE edit is an open
## problem this function does not solve; treat it separately, not by
## calling this again automatically.
##
## Question this function itself was written to answer, nothing broader:
## does calling
## EditorInterface.reload_scene_from_path() ourselves safely bring the
## already-open Main.tscn current WITHOUT going through the crash-
## correlated path (Godot's own async EditorFileSystem external-change
## detection -> the human-facing "Reload from disk" dialog -> the human
## accepting it)?
##
## History of call sites tried, in order — each ruled out by a real live
## crash, not by reasoning alone:
## 1. From _on_turn_finished(), which only runs once the ENTIRE (possibly
##    multi-minute) Hermes turn returns. Live-caught (load_probe_probe_
##    diamond_05-era test): Godot's own external-change dialog already
##    appeared while the request still said WORKING — the actual file
##    write happens deep inside the still-running background-thread
##    subprocess call, long before _on_turn_finished() ever fires. This
##    call site could never win the race against Godot's own async
##    detection.
## 2. Moved to a _process() poll watching Main.tscn's own mtime while a
##    DIRECT_WRITE turn was still in flight, firing the instant a change
##    was observed — deliberately accepting, as an open question, that
##    Hermes might still be actively writing when it fired. Live-caught
##    (amber_cube_probe_08): this call itself returned normally, ALL
##    project writes had already finished before it fired (proven via
##    both filesystem mtimes and Hermes's own exported session
##    transcript — see this function's own header comment above), and
##    Godot's editor still SIGABRTed moments later. This resolved the
##    open question from attempt 2: mid-write timing was not the cause.
## Both call sites removed. No third call site has been tried.
func _experimental_reload_edited_scene_via_api() -> void:
	if editor_interface == null:
		LifecycleProbe.trace("experimental_reload: editor_interface is null, skipping")
		return
	LifecycleProbe.trace("experimental_reload: about to call reload_scene_from_path(res://scenes/Main.tscn)")
	editor_interface.reload_scene_from_path("res://scenes/Main.tscn")
	LifecycleProbe.trace("experimental_reload: reload_scene_from_path returned normally")


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


## One row per pending Dragon coordination request discovered in the
## shared outbox. The Execute button is the ONLY thing that ever triggers
## _process_dragon_coordination_request() in Phase 1 — nothing here
## auto-runs a Dragon request.
##
## _dragon_request_rows[path] holds {row, summary, button, idle_text} —
## not just the row Control — so both the click handler below and
## _reset_dragon_request_row() can update/restore the row precisely
## without hunting through get_children().
func _add_dragon_request_row(request: Dictionary, path: String) -> void:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var summary := Label.new()
	var body := String(request.get("body", ""))
	var preview := "Dragon: " + (body if body.length() <= 120 else body.substr(0, 117) + "...")
	summary.text = preview
	summary.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row.add_child(summary)

	var execute_button := Button.new()
	execute_button.text = "Execute (DIRECT_WRITE)"
	execute_button.tooltip_text = "Runs this Dragon-recommended edit through the existing Editor DIRECT_WRITE path — same receipt/revert guarantees as any other edit. The request cannot select or escalate authority mode; DIRECT_WRITE is fixed for this first proof."
	row.add_child(execute_button)

	_dragon_requests_list.add_child(row)
	_dragon_request_rows[path] = {
		"row": row, "summary": summary, "button": execute_button, "idle_text": preview,
	}

	execute_button.pressed.connect(
		func() -> void:
			# Immediate, unmissable feedback the instant the button is
			# pressed — not only once the turn eventually finishes. A
			# real Hermes turn can run for minutes; a merely-disabled
			# button is too easy to miss, especially with the runtime
			# debug window often sitting on top of this dock. This was
			# the exact gap reported after the first live proof.
			execute_button.disabled = true
			execute_button.text = "Running..."
			summary.text = "⏳ WORKING — " + preview
			_process_dragon_coordination_request(request, path, HermesBridgeScript.MODE_DIRECT_WRITE)
	)


func _reset_dragon_request_row(path: String) -> void:
	var entry: Variant = _dragon_request_rows.get(path)
	if typeof(entry) != TYPE_DICTIONARY:
		return
	var button: Button = entry.get("button")
	var summary: Label = entry.get("summary")
	if button != null and is_instance_valid(button):
		button.disabled = false
		button.text = "Execute (DIRECT_WRITE)"
	if summary != null and is_instance_valid(summary):
		summary.text = String(entry.get("idle_text", summary.text))


## Reusable processing operation: Phase 1 calls this from the Execute
## button above; a future auto-run path calls exactly this same function
## with no human click in between. Human confirmation is a temporary
## Phase-1 trigger, not part of the message protocol — everything this
## function does is identical either way.
##
## Reuses the existing send()/turn_finished path rather than duplicating
## it: this is exactly the same call _on_send_pressed() makes, just with
## the message body and mode sourced from a Dragon request instead of the
## input field. mode is an explicit caller-supplied argument — never read
## from `request` — so a Dragon request can never choose or escalate its
## own authority mode.
func _process_dragon_coordination_request(request: Dictionary, path: String, mode: String) -> void:
	if _busy or not _pending_dragon_request.is_empty():
		_append_transcript("⚠ Dragon request ignored: a turn is already in flight. Try again once it finishes.")
		_reset_dragon_request_row(path)
		return
	var body := String(request.get("body", ""))
	if body.is_empty():
		_append_transcript("⚠ Dragon request has an empty body; refusing to execute.")
		_reset_dragon_request_row(path)
		return
	_pending_dragon_request = request
	_pending_dragon_request_path = path
	_append_transcript("[dragon→editor] " + body)
	_busy = true
	_send_button.disabled = true
	_stop_button.disabled = false
	_mode_selector.disabled = true
	_status_label.text = "⏳ Processing Dragon coordination request (DIRECT_WRITE)... a real Hermes turn can take a few minutes."
	_bridge.send(body, _model_input.text.strip_edges(), _provider_input.text.strip_edges(), mode)

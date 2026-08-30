extends SceneTree

var _failures := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await _check_human_transcript_toggle()
	await _check_capture_excludes_only_transcript()
	if _failures == 0:
		print("TRANSCRIPT_VISIBILITY_BOUNDARY: PASS")
		quit(0)
	else:
		push_error("TRANSCRIPT_VISIBILITY_BOUNDARY: %d failure(s)" % _failures)
		quit(1)


func _check_human_transcript_toggle() -> void:
	var packed := load("res://scenes/ControlHUD.tscn") as PackedScene
	_check(packed != null, "ControlHUD scene loads")
	if packed == null:
		return
	var hud := packed.instantiate()
	root.add_child(hud)
	await process_frame
	var output := hud.get_node_or_null("Output") as RichTextLabel
	var toggle := hud.get_node_or_null("TranscriptToggleButton") as Button
	_check(output != null, "conversation transcript node exists")
	_check(toggle != null, "visible transcript toggle exists")
	if output == null or toggle == null:
		hud.queue_free()
		await process_frame
		return
	var sibling_visibility := {}
	for child: Node in hud.get_children():
		if child is CanvasItem and child != output and child != toggle:
			sibling_visibility[child.name] = (child as CanvasItem).visible
	_check(hud.has_method("_on_transcript_toggle_pressed"), "HUD exposes transcript-only toggle behavior")
	if hud.has_method("_on_transcript_toggle_pressed"):
		hud.call("_on_transcript_toggle_pressed")
		_check(not output.visible, "first toggle hides conversation transcript")
		_check(toggle.text == "SHOW CHAT", "hidden state is visible on the toggle")
		for child: Node in hud.get_children():
			if child is CanvasItem and sibling_visibility.has(child.name):
				_check((child as CanvasItem).visible == sibling_visibility[child.name], "toggle preserves sibling %s visibility" % child.name)
		hud.call("_on_transcript_toggle_pressed")
		_check(output.visible, "second toggle restores conversation transcript")
		_check(toggle.text == "HIDE CHAT", "shown state is visible on the toggle")
	hud.queue_free()
	await process_frame


func _check_capture_excludes_only_transcript() -> void:
	var capture_script := load("res://scripts/PerceptionCapture3D.gd")
	var capture: Node = capture_script.new()
	root.add_child(capture)
	var canvas := CanvasLayer.new()
	root.add_child(canvas)

	var background := ColorRect.new()
	background.position = Vector2(0, 0)
	background.size = Vector2(220, 80)
	background.color = Color(0.1, 0.2, 0.3, 1.0)
	canvas.add_child(background)

	var retained_hud := ColorRect.new()
	retained_hud.position = Vector2(16, 16)
	retained_hud.size = Vector2(48, 48)
	retained_hud.color = Color(0.0, 1.0, 0.0, 1.0)
	canvas.add_child(retained_hud)

	var transcript := Control.new()
	transcript.position = Vector2(96, 16)
	transcript.size = Vector2(48, 48)
	canvas.add_child(transcript)
	var transcript_probe := ColorRect.new()
	transcript_probe.position = Vector2.ZERO
	transcript_probe.size = Vector2(48, 48)
	transcript_probe.color = Color(1.0, 0.0, 0.0, 1.0)
	transcript.add_child(transcript_probe)
	var conversation_input := LineEdit.new()
	conversation_input.position = Vector2(160, 16)
	conversation_input.size = Vector2(48, 48)
	conversation_input.text = "SECRET-CONVERSATION"
	canvas.add_child(conversation_input)

	await process_frame
	_check(capture.has_method("_capture_viewport_without_transcript"), "capture owns a transcript-exclusion frame boundary")
	if not capture.has_method("_capture_viewport_without_transcript"):
		canvas.queue_free()
		capture.queue_free()
		await process_frame
		return
	var capture_accepts_input := false
	for method: Dictionary in capture.get_method_list():
		if method.get("name") == "_capture_viewport_without_transcript":
			capture_accepts_input = (method.get("args") as Array).size() == 2
			break
	_check(capture_accepts_input, "capture boundary excludes transcript log and submitted input text")
	if not capture_accepts_input:
		canvas.queue_free()
		capture.queue_free()
		await process_frame
		return

	transcript.visible = true
	var input_observation := {"text": "NOT_OBSERVED"}
	RenderingServer.frame_post_draw.connect(
		func() -> void: input_observation["text"] = conversation_input.text,
		CONNECT_ONE_SHOT
	)
	var shown_result: Variant = await capture.call(
		"_capture_viewport_without_transcript",
		transcript,
		conversation_input
	)
	_check(typeof(shown_result) == TYPE_DICTIONARY and shown_result.get("ok", false), "capture succeeds while human transcript is shown")
	if typeof(shown_result) == TYPE_DICTIONARY and shown_result.get("ok", false):
		var image := shown_result.get("image") as Image
		_check(image != null, "capture returns an image")
		if image != null:
			var retained_pixel := image.get_pixel(32, 32)
			var transcript_pixel := image.get_pixel(112, 32)
			_check(retained_pixel.g > 0.8 and retained_pixel.r < 0.2, "non-transcript HUD remains in Dragon snapshot")
			_check(transcript_pixel.r < 0.8, "conversation transcript subtree is absent from Dragon snapshot")
	_check(transcript.visible, "capture restores a transcript that was shown to the human")
	_check(str(input_observation["text"]).is_empty(), "submitted conversation input is blank during Dragon snapshot")
	_check(conversation_input.text == "SECRET-CONVERSATION", "capture restores submitted conversation input text")
	_check(conversation_input.visible, "conversation input control remains on screen")

	transcript.visible = false
	var hidden_result: Variant = await capture.call(
		"_capture_viewport_without_transcript",
		transcript,
		conversation_input
	)
	_check(typeof(hidden_result) == TYPE_DICTIONARY and hidden_result.get("ok", false), "capture succeeds while human transcript is hidden")
	_check(not transcript.visible, "capture preserves an already-hidden human transcript")

	canvas.queue_free()
	capture.queue_free()
	await process_frame


func _check(condition: bool, message: String) -> void:
	if condition:
		print("PASS  " + message)
	else:
		_failures += 1
		push_error("FAIL  " + message)

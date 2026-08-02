@tool
extends Control

# Reference to EditorInterface passed by plugin.gd
var editor_interface: Object

@onready var task_input: TextEdit = %TaskInput
@onready var url_input: LineEdit = %UrlInput
@onready var model_input: LineEdit = %ModelInput
@onready var run_button: Button = %RunButton
@onready var stop_button: Button = %StopButton
@onready var status_label: Label = %StatusLabel
@onready var result_output: TextEdit = %ResultOutput

const OllamaClient = preload("res://addons/godot_ollama_task_performer/ollama_client.gd")
const OperationRegistry = preload("res://addons/godot_ollama_task_performer/operation_registry.gd")
const ProjectInspector = preload("res://addons/godot_ollama_task_performer/project_inspector.gd")
const SceneInspector = preload("res://addons/godot_ollama_task_performer/scene_inspector.gd")

var ollama_client: OllamaClient

func _ready() -> void:
	# Add OllamaClient as child node for HTTPRequest handling
	ollama_client = OllamaClient.new()
	add_child(ollama_client)
	
	run_button.pressed.connect(_on_run_button_pressed)
	stop_button.pressed.connect(_on_stop_button_pressed)
	
	status_label.text = "Ready"

func _on_run_button_pressed() -> void:
	var task_text = task_input.text.strip_edges()
	var base_url = url_input.text.strip_edges()
	var model_name = model_input.text.strip_edges()
	
	if task_text.is_empty():
		status_label.text = "Error: Task input is empty."
		return
		
	status_label.text = "Gathering project context..."
	run_button.disabled = true
	result_output.text = ""
	
	# Compile structured Godot project context for the prompt
	# This helps the model select the right operation.
	var project_inspector = ProjectInspector.new()
	var basic_project_info = project_inspector.run(editor_interface)
	
	var scene_inspector = SceneInspector.new()
	var basic_scene_info = scene_inspector.run(editor_interface)
	
	var context_dict = {
		"project_name": basic_project_info.get("project_name", ""),
		"godot_version": basic_project_info.get("godot_version", {}).get("string", ""),
		"currently_edited_scene": basic_project_info.get("currently_edited_scene_path", ""),
		"has_open_scene": basic_scene_info.get("error", "") == "",
		"files_in_project": basic_project_info.get("files", [])
	}
	
	var system_prompt = (
		"You are a constrained operation selector.\n" +
		"You do not write code.\n" +
		"You do not provide conversational answers.\n" +
		"Select exactly one permitted operation based on the user's task and provided context.\n" +
		"Return only JSON matching the response contract below.\n" +
		"Never invent file paths.\n\n" +
		"PERMITTED OPERATIONS:\n" +
		"- inspect_project (Takes empty arguments: {})\n" +
		"- inspect_scene (Permitted arguments: {\"scope\": \"currently_edited_scene\"})\n" +
		"- run_scene (Permitted arguments: {\"scope\": \"currently_edited_scene\"})\n\n" +
		"RESPONSE CONTRACT:\n" +
		"{\n" +
		"  \"operation\": \"inspect_project | inspect_scene | run_scene\",\n" +
		"  \"arguments\": {},\n" +
		"  \"reason\": \"short explanation\"\n" +
		"}\n\n" +
		"If the task cannot be fulfilled with an allowed operation (for example, trying to modify files, write code, run shell commands, delete files, etc.), return:\n" +
		"{\n" +
		"  \"operation\": \"refuse\",\n" +
		"  \"arguments\": {},\n" +
		"  \"reason\": \"The requested task is outside the permitted operations.\"\n" +
		"}"
	)
	
	var user_prompt_dict = {
		"task": task_text,
		"project_context": context_dict
	}
	var user_prompt = JSON.stringify(user_prompt_dict)
	
	status_label.text = "Querying Ollama API..."
	
	var response = await ollama_client.query_ollama(base_url, model_name, system_prompt, user_prompt)
	
	if not response["success"]:
		status_label.text = "Ollama connection failed."
		var error_result = {
			"status": "error",
			"operation": "unknown",
			"started_at": Time.get_datetime_string_from_system(false, true),
			"finished_at": Time.get_datetime_string_from_system(false, true),
			"result": {},
			"errors": [response["error"]]
		}
		result_output.text = JSON.stringify(error_result, "\t")
		run_button.disabled = false
		return
		
	status_label.text = "Validating and executing operation..."
	
	var registry = OperationRegistry.new()
	var execution_result = registry.process_response(response["content"], editor_interface)
	
	# Display formatted JSON result
	result_output.text = JSON.stringify(execution_result, "\t")
	
	if execution_result["status"] == "success":
		status_label.text = "Operation '%s' succeeded." % execution_result["operation"]
		if execution_result["operation"] == "run_scene":
			stop_button.disabled = false
	elif execution_result["status"] == "refused":
		status_label.text = "Task refused by policy."
	else:
		status_label.text = "Execution failed."
		
	run_button.disabled = false

func _on_stop_button_pressed() -> void:
	var scene_runner_class = preload("res://addons/godot_ollama_task_performer/scene_runner.gd")
	var runner = scene_runner_class.new()
	var stop_res = runner.stop(editor_interface)
	
	status_label.text = "Scene playback stopped."
	stop_button.disabled = true

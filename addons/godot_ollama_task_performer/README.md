# Godot Ollama Task Performer (Proof-of-Concept)

This is a Godot 4.6 EditorPlugin that acts as a constrained, read-only proof of a bounded task performer using a local Ollama instance. 

## Features & Safe Architecture
This plugin is **not a chatbot**. It is designed to act on a strict security boundary:
1. **No Autonomous Code Execution**: It parses and validates responses from Ollama, refusing any commands that aren't on the strict operations allowlist.
2. **Deterministic execution**: Operations select predefined, deterministic GDScript methods rather than running arbitrary code, scripts, or command line instructions.
3. **Strict Sandboxing**:
   - Ollama cannot write, edit, rename, or delete any files in the project.
   - Ollama cannot change project settings.
   - Ollama cannot execute arbitrary shell commands.
   - Ollama cannot supply arbitrary file paths.

---

## Installation
1. Ensure this folder is placed at `res://addons/godot_ollama_task_performer/`.
2. Open the Godot project in Godot 4.6 (or newer).
3. Go to **Project > Project Settings > Plugins** and check **Enable** next to "Godot Ollama Task Performer".
4. The dock "Ollama Task Performer" will appear in the right editor dock panel next to the Inspector.

---

## Setting Up local Ollama

### 1. Start Ollama
Make sure Ollama is installed and running on your local machine:
```bash
ollama run qwen2.5:7b-instruct
```

### 2. Verify Ollama API Connection
You can verify that Ollama is listening locally on port `11434` with the following `curl` command:
```bash
curl -s http://127.0.0.1:11434/api/tags
```
Ensure that `qwen2.5:7b-instruct` is in the returned list of models.

---

## Permitted Operations Allowlist

- **inspect_project**: Scans Godot project metadata, input maps, autoload configurations, and returns a listing of file paths under `res://` matching `.gd, .tscn, .tres, .res, .gdshader` extensions.
- **inspect_scene**: Traverses the currently open scene tree in the editor recursively. It outputs node hierarchy paths, class names, attached script paths, and signal connection details.
- **run_scene**: Triggers scene playback inside the Godot editor.
- **refuse**: Automatically triggered if the task request falls outside the permitted list.

---

## Known Limitations
* **`run_scene` proof-of-launch only**: The plugin starts scene playback via `EditorInterface.play_current_scene()`. The dock can confirm that the launch was requested, but cannot verify whether the scene succeeds or crashes at runtime. A **Stop Scene** button is provided to easily terminate playback.

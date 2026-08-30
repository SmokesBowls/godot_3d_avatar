@tool
extends EditorPlugin

## Registers the Hermes bottom dock. Follows the exact same bottom-dock
## registration pattern as the existing addons/godot_ollama_task_performer/
## plugin.gd (the reference for "how to make the seat") — the only
## difference here is the dock is built procedurally in hermes_dock.gd's
## _ready() rather than loaded from a .tscn, so there is no separate scene
## resource to keep in sync with this script.
##
## INSTRUMENTATION (temporary, diagnostic only — see _lifecycle_probe.gd):
## traces this plugin's own _enter_tree()/_exit_tree() and, best-effort,
## whatever EditorFileSystem reload-related signals this Godot build
## actually exposes — added to answer whether an external Main.tscn
## "Reload from disk" touches this plugin's lifecycle at all. Purely
## additive; no existing behavior below changes because of it.

const HermesDockScript := preload("res://addons/hermes_editor/hermes_dock.gd")
const LifecycleProbe := preload("res://addons/hermes_editor/_lifecycle_probe.gd")

var dock_instance: Control


func _enter_tree() -> void:
	LifecycleProbe.trace("plugin._enter_tree: begin")
	dock_instance = HermesDockScript.new()
	dock_instance.name = "Hermes"
	dock_instance.editor_interface = get_editor_interface()
	add_control_to_bottom_panel(dock_instance, "Hermes")
	_connect_reload_probes()
	LifecycleProbe.trace("plugin._enter_tree: end")


func _exit_tree() -> void:
	LifecycleProbe.trace("plugin._exit_tree: begin")
	if is_instance_valid(dock_instance):
		remove_control_from_bottom_panel(dock_instance)
		dock_instance.queue_free()
	dock_instance = null
	LifecycleProbe.trace("plugin._exit_tree: end")


## Connects, best-effort, to whatever EditorFileSystem signals this
## Godot build actually exposes that could correlate with an external
## Main.tscn modification being noticed / reloaded. Uses the dynamic
## Object.has_signal()/connect() string API rather than typed signal
## access specifically so a signal name that doesn't exist in this
## Godot version is a logged skip, not a script load failure.
func _connect_reload_probes() -> void:
	var efs: Object = get_editor_interface().get_resource_filesystem()
	if efs == null:
		LifecycleProbe.trace("plugin._connect_reload_probes: no EditorFileSystem available")
		return
	_connect_probe_signal(efs, "filesystem_changed", Callable(self, "_on_filesystem_changed"))
	_connect_probe_signal(efs, "sources_changed", Callable(self, "_on_sources_changed"))
	_connect_probe_signal(efs, "resources_reimported", Callable(self, "_on_resources_reimported"))
	_connect_probe_signal(efs, "resources_reload", Callable(self, "_on_resources_reload"))


func _connect_probe_signal(efs: Object, sig_name: String, cb: Callable) -> void:
	if not efs.has_signal(sig_name):
		LifecycleProbe.trace("plugin._connect_reload_probes: signal %s not present on this build" % sig_name)
		return
	if not efs.is_connected(sig_name, cb):
		efs.connect(sig_name, cb)
	LifecycleProbe.trace("plugin._connect_reload_probes: connected %s" % sig_name)


func _on_filesystem_changed() -> void:
	LifecycleProbe.trace("EditorFileSystem.filesystem_changed fired")


func _on_sources_changed(exist: bool) -> void:
	LifecycleProbe.trace("EditorFileSystem.sources_changed fired: exist=%s" % str(exist))


func _on_resources_reimported(resources: PackedStringArray) -> void:
	LifecycleProbe.trace("EditorFileSystem.resources_reimported fired: %s" % [resources])


func _on_resources_reload(resources: PackedStringArray) -> void:
	LifecycleProbe.trace("EditorFileSystem.resources_reload fired: %s" % [resources])

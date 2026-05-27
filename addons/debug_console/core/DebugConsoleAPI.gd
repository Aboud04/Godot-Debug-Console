@tool
extends Node
## Public API for third-party plugins to extend the Debug Console.
##
## This script is registered as the [code]DebugConsole[/code] autoload by the
## plugin, so any script in the project can call
## [code]DebugConsole.register_command(...)[/code] without importing or
## preloading anything. The autoload exists in both editor and runtime
## contexts (matching the rest of the Debug Console subsystem).
##
## Typical usage from a plugin author:
## [codeblock]
## func _enter_tree() -> void:
##     var debug_console: Node = get_node_or_null("/root/DebugConsole")
##     if not debug_console:
##         return # Debug Console plugin not installed/enabled
##     debug_console.register_command(
##         "my_cmd",
##         Callable(self, "_run_my_cmd"),
##         "Does my custom thing.",
##         "both"
##     )
##
## func _exit_tree() -> void:
##     var debug_console: Node = get_node_or_null("/root/DebugConsole")
##     if debug_console:
##         debug_console.unregister_command("my_cmd")
## [/codeblock]
##
## All public methods resolve the underlying [code]CommandRegistry[/code]
## autoload lazily, so they are safe to call from [code]_enter_tree[/code]
## and similar early hooks even if the registry is mid-startup.

## Emitted after a command is successfully registered via
## [method register_command] or [method register_resource_command]. The
## [param command_name] is the lowercased, trimmed name that was actually
## stored in the registry.
signal command_registered(command_name: String)

## Emitted after a command is successfully removed via
## [method unregister_command]. The [param command_name] is the lowercased,
## trimmed name that was removed.
signal command_unregistered(command_name: String)

## Emitted after every console command runs, regardless of whether it
## succeeded. [param command_name] is the first whitespace-separated token of
## the executed input (lowercased) - for a pipeline like
## [code]"echo hi | grep h"[/code] this is [code]"echo"[/code].
## [param args] is the remaining whitespace-separated tokens of the full
## input, as [Array] of [String]. [param result] is the final string the
## registry returned (which may be an error message).
signal command_executed(command_name: String, args: Array, result: String)

## Emitted when an editor or game console panel becomes visible (e.g. the
## user toggles the editor dock open or presses F12 in the running game).
## Fires once per visibility transition from hidden to visible.
signal console_opened()

## Emitted when an editor or game console panel becomes hidden. Fires once
## per visibility transition from visible to hidden.
signal console_closed()

const _COMMAND_REGISTRY_PATH: String = "/root/CommandRegistry"
const _DEBUG_CORE_PATH: String = "/root/DebugCore"
const _EDITOR_CONSOLE_SCRIPT_PATH: String = "res://addons/debug_console/editor/EditorConsole.gd"
const _GAME_CONSOLE_SCRIPT_PATH: String = "res://addons/debug_console/game/GameConsole.gd"
const _MAX_REGISTRY_CONNECT_ATTEMPTS: int = 30

var _registry_connected: bool = false
var _registry_connect_attempts: int = 0
# Maps Control.get_instance_id() -> last observed visibility (bool). Used to
# de-duplicate visibility_changed signals (a hidden->hidden flip should not
# re-fire console_closed).
var _watched_consoles: Dictionary = {}

func _ready() -> void:
	set_process_mode(Node.PROCESS_MODE_ALWAYS)
	# Registry lives at /root/CommandRegistry. The plugin registers it BEFORE
	# this autoload, so it should be present here - but we still tolerate it
	# missing (e.g. registry reload, future refactors) and retry a few frames.
	_connect_to_registry()
	# Consoles may not yet exist when we run (the editor dock is added later
	# in plugin.gd, and the game console only exists at runtime). Defer the
	# scan one frame and additionally watch for nodes that appear later.
	call_deferred("_setup_console_watchers")

func _exit_tree() -> void:
	# Best-effort disconnect so that, if the API is reloaded but the registry
	# survives, we don't leave a dangling Callable on the registry's signal.
	var registry: Node = _get_registry()
	if registry and _registry_connected and registry.has_signal("command_executed"):
		var callback: Callable = Callable(self, "_on_registry_command_executed")
		if registry.command_executed.is_connected(callback):
			registry.command_executed.disconnect(callback)
	_registry_connected = false
	var tree: SceneTree = get_tree()
	if tree and tree.node_added.is_connected(_on_node_added):
		tree.node_added.disconnect(_on_node_added)
	_watched_consoles.clear()

# --- Public API ---

## Register a new command in the Debug Console.
## [br][param name]: command word as it will be typed in the console. The
## value is trimmed of whitespace and lowercased before storage; if it is
## empty after trimming, registration fails.
## [br][param callable]: a [Callable] that accepts a single [Array] of
## [String] arguments and returns a value convertible to [String]. Must
## satisfy [code]callable.is_valid()[/code] at the time of registration.
## [br][param description]: human-readable description shown by the
## [code]help[/code] command.
## [br][param context]: where the command is available. One of
## [code]"editor"[/code], [code]"game"[/code], or [code]"both"[/code]
## (the default). Any other value causes registration to fail.
## [br]Returns [code]true[/code] on success. Returns [code]false[/code] if
## the name is empty, the callable is invalid, the context is unrecognized,
## the underlying [code]CommandRegistry[/code] autoload is not available,
## or a command with the same name is already registered. On success,
## emits [signal command_registered].
func register_command(name: String, callable: Callable, description: String = "", context: String = "both") -> bool:
	var normalized_name: String = name.strip_edges().to_lower()
	if normalized_name.is_empty():
		return false
	if not callable.is_valid():
		return false
	if context != "editor" and context != "game" and context != "both":
		return false
	var registry: Node = _get_registry()
	if not registry:
		return false
	if _registry_has_command(registry, normalized_name):
		return false
	registry.register_command(normalized_name, callable, description, context, false)
	command_registered.emit(normalized_name)
	return true

## Unregister a previously-registered command.
## [br][param name]: the command word to remove. Trimmed and lowercased
## before lookup.
## [br]Returns [code]true[/code] if a command with that name existed and was
## removed. Returns [code]false[/code] if the name is empty, if no command
## with that name is registered, or if the underlying registry autoload is
## not available. On success, emits [signal command_unregistered].
func unregister_command(name: String) -> bool:
	var normalized_name: String = name.strip_edges().to_lower()
	if normalized_name.is_empty():
		return false
	var registry: Node = _get_registry()
	if not registry:
		return false
	if not _registry_has_command(registry, normalized_name):
		return false
	registry.unregister_command(normalized_name)
	command_unregistered.emit(normalized_name)
	return true

## Print a message to the currently-active console (editor or game).
## [br][param message]: text to log. The message is timestamped and tagged
## by the underlying [code]DebugCore.Log[/code] routine.
## [br][param level]: severity tag. Case-insensitive; one of
## [code]"info"[/code], [code]"warning"[/code], [code]"error"[/code], or
## [code]"success"[/code]. Any other value is treated as [code]"info"[/code].
## [br]Has no effect if the [code]DebugCore[/code] autoload is not available;
## in that case a [code]push_warning[/code] is emitted instead.
func print_to_console(message: String, level: String = "info") -> void:
	var core: Node = _get_debug_core()
	if not core:
		push_warning("DebugConsole.print_to_console: DebugCore autoload not available")
		return
	var normalized_level: String = level.strip_edges().to_lower()
	var log_level: int = 0
	match normalized_level:
		"info":
			log_level = 0
		"warning":
			log_level = 1
		"error":
			log_level = 2
		"success":
			log_level = 3
		_:
			log_level = 0
	core.Log(message, log_level)

## Returns [code]true[/code] if a command with the given name is currently
## registered. [param command_name] is trimmed and lowercased before lookup.
## Returns [code]false[/code] if the underlying registry autoload is not
## available.
func has_command(command_name: String) -> bool:
	var registry: Node = _get_registry()
	if not registry:
		return false
	return _registry_has_command(registry, command_name.strip_edges().to_lower())

## Returns the names of every currently-registered command, sorted
## alphabetically. The list includes built-in commands (e.g. "help",
## "echo") as well as anything registered by plugins. Returns an empty
## [PackedStringArray] if the underlying registry autoload is not available.
func list_commands() -> PackedStringArray:
	var result: PackedStringArray = PackedStringArray()
	var registry: Node = _get_registry()
	if not registry:
		return result
	var names: Array = registry._commands.keys()
	names.sort()
	for n in names:
		result.append(String(n))
	return result

## Register a [ConsoleCommand] resource as a command. This is a convenience
## wrapper around [method register_command] for plugin authors who prefer
## a declarative, editor-editable representation.
## [br][param cmd]: a [ConsoleCommand] resource. The parameter is typed as
## [Resource] (rather than [code]ConsoleCommand[/code]) to keep this
## autoload script free of [code]class_name[/code] resolution requirements
## at parse time; the value must nevertheless be a ConsoleCommand.
## [br]Returns [code]true[/code] on success. Returns [code]false[/code] if
## [param cmd] is [code]null[/code], is not a [Resource], does not expose
## the expected [code]is_valid[/code] / [code]to_callable[/code] methods,
## fails its [method ConsoleCommand.is_valid] check, produces an invalid
## [Callable], or if the underlying [method register_command] call rejects
## it (for example, due to a duplicate name).
func register_resource_command(cmd: Resource) -> bool:
	if cmd == null:
		return false
	if not cmd.has_method("is_valid") or not cmd.has_method("to_callable"):
		return false
	if not cmd.is_valid():
		return false
	var callable: Callable = cmd.to_callable()
	if not callable.is_valid():
		return false
	var cmd_name: String = str(cmd.get("command_name"))
	var cmd_desc: String = str(cmd.get("description"))
	var cmd_ctx: String = str(cmd.get("context"))
	return register_command(cmd_name, callable, cmd_desc, cmd_ctx)

# --- Internal helpers ---

func _get_registry() -> Node:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if not tree:
		return null
	return tree.root.get_node_or_null(_COMMAND_REGISTRY_PATH)

func _get_debug_core() -> Node:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if not tree:
		return null
	return tree.root.get_node_or_null(_DEBUG_CORE_PATH)

func _registry_has_command(registry: Node, normalized_name: String) -> bool:
	# CommandRegistry stores commands in a public `_commands` Dictionary.
	# We read it directly rather than calling get_available_commands(), which
	# would filter by current context and miss e.g. an "editor"-only command
	# from a "game" context.
	var commands_dict: Variant = registry.get("_commands")
	if commands_dict is Dictionary:
		return (commands_dict as Dictionary).has(normalized_name)
	return false

func _connect_to_registry() -> void:
	if _registry_connected:
		return
	var registry: Node = _get_registry()
	if not registry:
		_registry_connect_attempts += 1
		if _registry_connect_attempts < _MAX_REGISTRY_CONNECT_ATTEMPTS:
			call_deferred("_connect_to_registry")
		return
	if not registry.has_signal("command_executed"):
		return
	var callback: Callable = Callable(self, "_on_registry_command_executed")
	if not registry.command_executed.is_connected(callback):
		registry.command_executed.connect(callback)
	_registry_connected = true

func _on_registry_command_executed(command: String, result: String) -> void:
	var trimmed: String = command.strip_edges()
	var first_segment: String = trimmed
	var pipe_index: int = trimmed.find("|")
	if pipe_index != -1:
		first_segment = trimmed.substr(0, pipe_index).strip_edges()
	var parts: PackedStringArray = first_segment.split(" ", false)
	var cmd_name: String = ""
	var args: Array = []
	if parts.size() > 0:
		cmd_name = String(parts[0]).to_lower()
		for i in range(1, parts.size()):
			args.append(String(parts[i]))
	command_executed.emit(cmd_name, args, result)

func _setup_console_watchers() -> void:
	var tree: SceneTree = get_tree()
	if not tree:
		return
	if not tree.node_added.is_connected(_on_node_added):
		tree.node_added.connect(_on_node_added)
	# Scan nodes that already exist at the time we run - the editor console
	# panel may already be parented under the editor dock by the time our
	# deferred call fires.
	_scan_for_consoles(tree.root)

func _scan_for_consoles(node: Node) -> void:
	if not is_instance_valid(node):
		return
	if _is_debug_console_panel(node):
		_watch_console_panel(node as Control)
	for child in node.get_children():
		_scan_for_consoles(child)

func _on_node_added(node: Node) -> void:
	if _is_debug_console_panel(node):
		_watch_console_panel(node as Control)

func _is_debug_console_panel(node: Node) -> bool:
	if not is_instance_valid(node):
		return false
	if not (node is Control):
		return false
	var script: Script = node.get_script() as Script
	if not script:
		return false
	var path: String = script.resource_path
	return path == _EDITOR_CONSOLE_SCRIPT_PATH or path == _GAME_CONSOLE_SCRIPT_PATH

func _watch_console_panel(panel: Control) -> void:
	if not is_instance_valid(panel):
		return
	var id: int = panel.get_instance_id()
	if _watched_consoles.has(id):
		return
	_watched_consoles[id] = panel.visible
	var visibility_callback: Callable = Callable(self, "_on_console_visibility_changed").bind(panel)
	if not panel.visibility_changed.is_connected(visibility_callback):
		panel.visibility_changed.connect(visibility_callback)
	var exit_callback: Callable = Callable(self, "_on_console_tree_exiting").bind(id)
	if not panel.tree_exiting.is_connected(exit_callback):
		panel.tree_exiting.connect(exit_callback, CONNECT_ONE_SHOT)

func _on_console_visibility_changed(panel: Control) -> void:
	if not is_instance_valid(panel):
		return
	var id: int = panel.get_instance_id()
	var prev: bool = bool(_watched_consoles.get(id, false))
	var now: bool = panel.visible
	if prev == now:
		return
	_watched_consoles[id] = now
	if now:
		console_opened.emit()
	else:
		console_closed.emit()

func _on_console_tree_exiting(id: int) -> void:
	_watched_consoles.erase(id)

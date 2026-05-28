@tool
class_name BuiltInCommands extends RefCounted

#region BuiltInCommands
var _registry: Node
var _core: Node
var _aliases: Dictionary = {}
var _registered_alias_names: Array[String] = []
var _active_alias_calls: Array[String] = []

# optional persistence hook injected by plugin.gd. When non-null its
# save_cwd(String) method is called after every successful `cd` so the working
# directory survives editor restarts. Tests that don't care about persistence
# leave this null and _change_directory behaves exactly as before.
var _state_saver: Object = null

# toggled by the `intercept on|off` command. Defaults OFF so the
# GameConsole never accidentally double-logs its own output (which would
# recurse infinitely once a usable logger hook is wired).
var _intercept_active: bool = false

const ALIAS_CONFIG_PATH := "user://debug_console_aliases.cfg"
const CONSOLE_CONFIG_PATH := "user://debug_console_config.cfg"
const CONSOLE_CONFIG_SECTION := "console"

const _DEFAULT_CONSOLE_CONFIG := {
	"opacity": 0.85,
	"font_size": 14,
	"height": 400,
}

func initialize(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core

# injection point for the persistence layer. Kept as a separate setter
# (not a parameter of initialize) so other call sites that just need
# command registration aren't forced to know about persistence.
func set_state_saver(saver: Object) -> void:
	_state_saver = saver

func _ensure_dependencies() -> void:
	if _registry and _core:
		return

	var tree := Engine.get_main_loop() as SceneTree
	if not tree:
		return

	if not _registry:
		_registry = tree.root.get_node_or_null("/root/CommandRegistry")
	if not _core:
		_core = tree.root.get_node_or_null("/root/DebugCore")

func register_editor_commands():
	_ensure_dependencies()
	register_universal_commands()
	if not _registry:
		return
	# Transient-instance protection (see register_universal_commands for details).
	if _registry._commands.has("ls"):
		var existing_ls: Callable = _registry._commands["ls"].get("callable", Callable())
		if existing_ls.is_valid() and existing_ls.get_object() != self:
			return
	
	_registry.register_command("scene", _get_current_scene, "Get current scene info", "editor")
	_registry.register_command("reload", _reload_scene, "Reload current scene", "editor")
	
	_registry.register_command("ls", _list_files, "List files in current directory", "editor", true)
	_registry.register_command("cd", _change_directory, "Change directory", "editor")
	_registry.register_command("pwd", _print_working_directory, "Print current working directory", "editor")
	_registry.register_command("mkdir", _make_directory, "Create directory", "editor")
	_registry.register_command("touch", _create_file, "Create file", "editor")
	_registry.register_command("rm", _remove_file, "Remove file or directory", "editor")
	_registry.register_command("rmdir", _remove_directory, "Remove directory", "editor")
	_registry.register_command("mv", _move_file, "Move/rename file", "editor")
	_registry.register_command("cp", _copy_file, "Copy file", "editor")
	_registry.register_command("cat", _view_file, "View file contents", "editor", true)
	_registry.register_command("refresh", _refresh_filesystem, "Refresh Godot filesystem", "editor")
	
	_registry.register_command("find", _find, "Find files by name in current or subdirectories", "editor")
	_registry.register_command("grep", _grep, "Search for text inside files", "editor", true)
	_registry.register_command("stat", _stat, "Display file information such as size, type, and modification time", "editor")
	_registry.register_command("head", _head, "Show first N lines of input or file", "editor", true)
	_registry.register_command("tail", _tail, "Show last N lines of input or file", "editor", true)

	# filesystem and developer convenience commands
	_registry.register_command("tree", _cmd_tree, "Visualize the filesystem tree under the current directory", "editor")
	_registry.register_command("wc", _cmd_wc, "Count lines, words, and characters in a file or piped input", "editor", true)
	_registry.register_command("reload_scripts", _cmd_reload_scripts, "Force-reload every GDScript file in the project", "editor")
	_registry.register_command("diff", _cmd_diff, "Line-level BBCode-colored diff of two files", "editor")

	
	_registry.register_command("new_script", _create_script, "Create new script file", "editor")
	_registry.register_command("new_scene", _create_scene, "Create new scene file", "editor")
	_registry.register_command("new_resource", _create_resource, "Create new resource file", "editor")
	_registry.register_command("open", _open_file, "Open file in editor", "editor")
	_registry.register_command("node_types", _list_node_types, "List available node types for extends", "editor")
	
	_registry.register_command("save_scenes", _save_scene, "Save all open scenes", "editor")
	_registry.register_command("run_project", _run_project, "Run the main scene or a specific scene of your choice", "editor")
	_registry.register_command("stop_project", _stop_project, "Stop the currently running scene or project", "editor")

	
	
	
	_registry.register_command("test_commands", _test_commands, "Test command functionality", "editor")
	_registry.register_command("test_autocomplete", _test_autocomplete, "Test autocomplete functionality", "editor")
	_registry.register_command("test_files", _test_file_operations, "Test file operations", "editor")
	_registry.register_command("test_pipes", _test_pipes, "Test command piping functionality", "editor")
	_registry.register_command("quick_test", _quick_test, "Run quick test", "editor")

func register_game_commands():
	_ensure_dependencies()
	register_universal_commands()
	if not _registry:
		return
	# Transient-instance protection (see register_universal_commands for details).
	if _registry._commands.has("fps"):
		var existing_fps: Callable = _registry._commands["fps"].get("callable", Callable())
		if existing_fps.is_valid() and existing_fps.get_object() != self:
			return
	
	_registry.register_command("fps", _show_fps, "Show FPS information", "game")
	_registry.register_command("nodes", _count_nodes, "Count nodes in scene tree", "game")
	_registry.register_command("pause", _toggle_pause, "Toggle game pause", "game")
	_registry.register_command("timescale", _set_time_scale, "Set engine time scale", "game")
	_registry.register_command("opacity", _cmd_opacity, "Set console background opacity (0-100 or 0.0-1.0)", "game")
	_registry.register_command("intercept", _cmd_intercept, "Toggle interception of global print/warning/error output (on|off|status)", "game")
	# New commands
	_registry.register_command("perf", _cmd_perf, "Show Performance.Monitor dashboard; optionally filter by name", "game")
	_registry.register_command("show_colliders", _cmd_show_colliders, "Toggle CollisionShape debug rendering: show_colliders [on|off]", "game")
	_registry.register_command("show_nav", _cmd_show_nav, "Toggle navigation polygon debug rendering: show_nav [on|off]", "game")
	_registry.register_command("show_paths", _cmd_show_paths, "Toggle PathFollow path debug rendering: show_paths [on|off]", "game")
	_registry.register_command("slowmo", _cmd_slowmo, "Slow-motion shortcut: slowmo [factor|off] (default 0.25)", "game")
	_registry.register_command("freeze", _cmd_freeze, "Freeze time (Engine.time_scale = 0); resume with 'slowmo off'", "game")
	_registry.register_command("physics_tps", _cmd_physics_tps, "Get/set Engine.physics_ticks_per_second (1-1000)", "game")

func register_universal_commands():
	_ensure_dependencies()
	if not _registry:
		return
	# Transient-instance protection: if echo is already registered with a
	if _registry._commands.has("echo"):
		var existing_echo: Callable = _registry._commands["echo"].get("callable", Callable())
		if existing_echo.is_valid() and existing_echo.get_object() != self:
			# Live registry already has this owner's universals. Skip overwriting
			# them but DO refresh T6 modules - they're stable in _t6_keepalive
			# so re-registration is cheap and idempotent.
			for module in _t6_keepalive:
				if module and module.has_method("register_commands"):
					module.register_commands(_registry, _core)
			_load_aliases_from_config()
			_register_alias_commands()
			return
	_registry.register_command("test", _run_tests, "Run all tests", "both")
	_registry.register_command("help", _help, "Show available commands", "both")
	_registry.register_command("clear", _clear, "Clear console output", "both")
	_registry.register_command("history", _show_history, "Show command history", "both")
	_registry.register_command("clear_history", _clear_history, "Clear command history", "both")
	_registry.register_command("echo", _echo, "Echo text back", "both", true)
	_registry.register_command("scene_tree", _cmd_scene_tree, "Print scene tree as ASCII tree", "both")
	_registry.register_command("watch", _cmd_watch, "Monitor Engine or node properties", "both")
	_registry.register_command("save_log", _save_log, "Export the current session log to a file", "both")
	_registry.register_command("inspect", _cmd_inspect, "Dump all properties of a node, autoload, or Engine", "both")
	_registry.register_command("get", _cmd_get, "Read a live property by selector: <target>.<property>", "both")
	_registry.register_command("set", _cmd_set, "Set a live property value: <target>.<property> <value>", "both")
	_registry.register_command("alias", _cmd_alias, "Create/list persistent aliases", "both")
	_registry.register_command("unalias", _cmd_unalias, "Remove a persistent alias", "both")
	_registry.register_command("benchmark", _cmd_benchmark, "Benchmark a command: benchmark [iterations] <command>", "both")
	_registry.register_command("config", _cmd_config, "Manage persistent console settings", "both")
	# live introspection commands (work in both editor and runtime)
	_registry.register_command("signals", _cmd_signals, "List signals defined on a live node, with connection counts", "both")
	_registry.register_command("properties", _cmd_properties, "List property names and types on a live target (no values)", "both")
	# pretty-print arbitrary JSON. Pipe-aware so `echo '...' | json` works.
	_registry.register_command("json", _cmd_json, "Pretty-print JSON: json <text> (also pipe-able)", "both", true)
	# New commands
	_registry.register_command("eval", _cmd_eval, "Evaluate a GDScript expression (sandboxed: no defs/assigns)", "both")
	_registry.register_command("mark", _cmd_mark, "Print a colored timestamped marker for log syncing", "both")
	_registry.register_command("crashtest", _cmd_crashtest, "Fire assert(false) to validate crash reporting", "both")
	# Live font-size tuning (user feedback: default too small).
	_registry.register_command("font_size", _cmd_font_size, "Get/set console font size: font_size [n] (8-32, default 15)", "both")
	_registry.register_command("line_spacing", _cmd_line_spacing, "Get/set console line spacing in pixels: line_spacing [n] (0-40)", "both")
	# Load external command modules (scene/runtime/UI). Modules are kept
	# alive in a static array; on a fresh registry we re-register against it.
	# Same pattern for the 11 new domain modules (physics/animation/camera/
	# timer/prefab/math/dialog/particles/data/shader/tilemap). Each appends to
	# the same array; the for-loop below re-registers all of them against the
	# current _registry on every call to register_universal_commands.
	#
	# Hot-reload guard: the static _t6_keepalive can survive a script reload
	# with a stale subset of modules (e.g. only the 3 T6 modules from a
	# previous plugin generation). We detect that by comparing sizes against
	# the canonical module_paths list and clear+reload if they mismatch.
	# Without this guard, the live registry would silently miss the T7 module
	# commands after any hot-reload that happened between T6 and T7 ship.
	var module_paths: Array[String] = [
		"res://addons/debug_console/core/SceneCommands.gd",
		"res://addons/debug_console/core/RuntimeCommands.gd",
		"res://addons/debug_console/core/UICommands.gd",
		"res://addons/debug_console/core/PhysicsCommands.gd",
		"res://addons/debug_console/core/AnimationCommands.gd",
		"res://addons/debug_console/core/CameraCommands.gd",
		"res://addons/debug_console/core/TimerCommands.gd",
		"res://addons/debug_console/core/PrefabCommands.gd",
		"res://addons/debug_console/core/MathCommands.gd",
		"res://addons/debug_console/core/DialogCommands.gd",
		"res://addons/debug_console/core/ParticleCommands.gd",
		"res://addons/debug_console/core/DataCommands.gd",
		"res://addons/debug_console/core/ShaderCommands.gd",
		"res://addons/debug_console/core/TilemapCommands.gd",
	]
	if _t6_keepalive.size() != module_paths.size():
		_t6_keepalive.clear()
		for path in module_paths:
			var script_res: GDScript = load(path) as GDScript
			if script_res:
				var module: RefCounted = script_res.new()
				if module:
					_t6_keepalive.append(module)
				else:
					push_error("Debug Console: %s loaded but .new() failed" % path)
			else:
				push_error("Debug Console: failed to load module %s" % path)
	# extensions auto-discovery. Any *Commands.gd dropped into
	# core/extensions/ at addon ship time is picked up automatically. Each is
	# instantiated once per plugin lifetime and kept alive in the static
	# _t8_extensions array (separate from _t6_keepalive so the size-mismatch
	# guard above doesn't false-alarm when an extension count changes).
	if _t8_extensions.is_empty():
		var ext_dir := DirAccess.open("res://addons/debug_console/core/extensions")
		if ext_dir:
			ext_dir.list_dir_begin()
			var file_name: String = ext_dir.get_next()
			while not file_name.is_empty():
				if file_name.ends_with("Commands.gd"):
					var ext_path := "res://addons/debug_console/core/extensions/%s" % file_name
					var ext_script: GDScript = load(ext_path) as GDScript
					if ext_script:
						var ext_module: RefCounted = ext_script.new()
						if ext_module:
							_t8_extensions.append(ext_module)
				file_name = ext_dir.get_next()
			ext_dir.list_dir_end()
	for module in _t6_keepalive:
		if module and module.has_method("register_commands"):
			module.register_commands(_registry, _core)
	for module in _t8_extensions:
		if module and module.has_method("register_commands"):
			module.register_commands(_registry, _core)
	_load_aliases_from_config()
	_register_alias_commands()

#region Universal commands
func _help(args: Array) -> String:
	_ensure_dependencies()
	var cmd_name = ""
	if args.size() > 0:
		cmd_name = str(args[0])
	return _registry.get_command_help(cmd_name)

func _clear(args: Array) -> String:
	_ensure_dependencies()
	_core.clear_history()
	if Engine.is_editor_hint() and _core.editor_output:
		_core.editor_output.clear_output()
	elif _core.game_output:
		_core.game_output.clear_output()
	
	return ""

func _echo(args: Array, input: String = "", is_pipe_context: bool = false) -> String:
	if not input.is_empty():
		return input
	return " ".join(args) if args.size() > 0 else "Usage: echo <message>"

func _cmd_watch(args: Array) -> String:
	_ensure_dependencies()
	if not _core:
		return "Error: DebugCore is unavailable"

	if args.is_empty() or str(args[0]).to_lower() == "list":
		return _watch_list()

	var subcommand := str(args[0]).to_lower()
	if subcommand == "clear":
		var cleared_count = _core.clear_watches()
		return "Cleared %d watch(es)" % cleared_count

	if subcommand == "remove":
		if args.size() < 2:
			return "Usage: watch remove <expression>"
		var expression_to_remove := " ".join(args.slice(1))
		if _core.remove_watch(expression_to_remove):
			return "Removed watch: %s" % expression_to_remove
		return "Watch not found: %s" % expression_to_remove

	if subcommand == "poll":
		var updates: Array[String] = _core.poll_watch_expressions(false)
		if updates.is_empty():
			return "No watch changes"
		return "\n".join(updates)

	var expression := " ".join(args).strip_edges()
	var add_result: Dictionary = _core.add_watch(expression)
	if not bool(add_result.get("ok", false)):
		return str(add_result.get("result", "Error: Failed to add watch"))

	return "Watching %s = %s" % [
		str(add_result.get("expression", expression)),
		str(add_result.get("value", ""))
	]

func _watch_list() -> String:
	var watches: Array[Dictionary] = _core.list_watches()
	if watches.is_empty():
		return "No active watches"

	var lines := ["Active watches:"]
	for watch_entry in watches:
		lines.append("  %s = %s" % [
			str(watch_entry.get("expression", "")),
			str(watch_entry.get("last_value", ""))
		])
	return "\n".join(lines)

func _cmd_inspect(args: Array) -> String:
	_ensure_dependencies()
	if not _core:
		return "Error: DebugCore is unavailable"
	if args.is_empty():
		return "Usage: inspect <node_path|autoload_name|Engine>"

	var path := " ".join(args).strip_edges()
	var result: Dictionary = _core.inspect_node(path)
	if not bool(result.get("ok", false)):
		return str(result.get("result", "Error: inspect failed"))

	var display_path := str(result.get("display_path", path))
	var class_name_str := str(result.get("class_name", "?"))
	var properties: Array = result.get("properties", [])

	var lines: Array[String] = []
	lines.append("=== %s ===" % display_path)
	lines.append("Class: %s  |  Properties: %d" % [class_name_str, properties.size()])
	lines.append("─────────────────────────────────────────────────")
	for prop in properties:
		lines.append("  [%-8s] %-24s = %s" % [
			_inspect_type_name(int(prop.get("type", 0))),
			str(prop.get("name", "")),
			str(prop.get("value", "null"))
		])
	return "\n".join(lines)

func _inspect_type_name(type_id: int) -> String:
	match type_id:
		TYPE_BOOL: return "Bool"
		TYPE_INT: return "Int"
		TYPE_FLOAT: return "Float"
		TYPE_STRING: return "String"
		TYPE_VECTOR2: return "Vector2"
		TYPE_VECTOR2I: return "Vector2i"
		TYPE_RECT2: return "Rect2"
		TYPE_VECTOR3: return "Vector3"
		TYPE_VECTOR3I: return "Vector3i"
		TYPE_TRANSFORM2D: return "Xform2D"
		TYPE_COLOR: return "Color"
		TYPE_STRING_NAME: return "SName"
		TYPE_NODE_PATH: return "NodePath"
		TYPE_RID: return "RID"
		TYPE_OBJECT: return "Object"
		TYPE_CALLABLE: return "Callable"
		TYPE_SIGNAL: return "Signal"
		TYPE_DICTIONARY: return "Dict"
		TYPE_ARRAY: return "Array"
		TYPE_PACKED_BYTE_ARRAY: return "ByteArr"
		TYPE_PACKED_STRING_ARRAY: return "StrArr"
		TYPE_TRANSFORM3D: return "Xform3D"
		TYPE_BASIS: return "Basis"
		_: return "Variant"

func _cmd_get(args: Array) -> String:
	_ensure_dependencies()
	if not _core:
		return "Error: DebugCore is unavailable"
	if args.is_empty():
		return "Usage: get <target>.<property_path>"

	var selector := " ".join(args).strip_edges()
	var result: Dictionary = _core.get_live_property(selector)
	if not bool(result.get("ok", false)):
		return str(result.get("result", "Error: get failed"))

	return "%s = %s" % [
		str(result.get("selector", selector)),
		str(result.get("value", "<null>"))
	]

func _cmd_set(args: Array) -> String:
	_ensure_dependencies()
	if not _core:
		return "Error: DebugCore is unavailable"
	if args.size() < 2:
		return "Usage: set <target>.<property_path> <value>"

	var selector := str(args[0]).strip_edges()
	var raw_value := " ".join(args.slice(1)).strip_edges()
	if raw_value.is_empty():
		return "Usage: set <target>.<property_path> <value>"

	var result: Dictionary = _core.set_live_property(selector, raw_value)
	if not bool(result.get("ok", false)):
		return str(result.get("result", "Error: set failed"))

	return "Set %s: %s -> %s" % [
		str(result.get("selector", selector)),
		str(result.get("old_value", "<null>")),
		str(result.get("new_value", "<null>"))
	]

func _cmd_alias(args: Array) -> String:
	_ensure_dependencies()
	if not _registry:
		return "Error: CommandRegistry is unavailable"

	if args.is_empty():
		if _aliases.is_empty():
			return "No aliases configured"
		var keys := _aliases.keys()
		keys.sort()
		var lines: Array[String] = ["Aliases:"]
		for key in keys:
			lines.append("  %s='%s'" % [str(key), str(_aliases[key])])
		return "\n".join(lines)

	if args.size() == 1:
		var lookup := str(args[0]).to_lower()
		if not _aliases.has(lookup):
			return "Alias not found: %s" % lookup
		return "%s='%s'" % [lookup, str(_aliases[lookup])]

	var alias_name := str(args[0]).strip_edges().to_lower()
	if alias_name.is_empty() or alias_name.contains(" ") or alias_name.contains("|"):
		return "Error: Invalid alias name"

	if alias_name == "alias" or alias_name == "unalias":
		return "Error: Reserved alias name: %s" % alias_name

	if _registry._commands.has(alias_name) and not _aliases.has(alias_name):
		return "Error: Command already exists: %s" % alias_name

	var expansion := " ".join(args.slice(1)).strip_edges()
	if expansion.is_empty():
		return "Usage: alias <name> <command>"

	# Prevent direct self-recursion at definition time.
	if expansion == alias_name or expansion.begins_with(alias_name + " "):
		return "Error: Alias cannot reference itself"

	_aliases[alias_name] = expansion
	_register_single_alias_command(alias_name)
	_save_aliases_to_config()
	return "Alias set: %s='%s'" % [alias_name, expansion]

func _cmd_unalias(args: Array) -> String:
	_ensure_dependencies()
	if args.is_empty():
		return "Usage: unalias <name>"

	var alias_name := str(args[0]).strip_edges().to_lower()
	if not _aliases.has(alias_name):
		return "Alias not found: %s" % alias_name

	_aliases.erase(alias_name)
	_unregister_single_alias_command(alias_name)
	_save_aliases_to_config()
	return "Alias removed: %s" % alias_name

func _execute_alias(args: Array, alias_name: String) -> String:
	if not _registry:
		return "Error: CommandRegistry is unavailable"
	if not _aliases.has(alias_name):
		return "Error: Alias not found: %s" % alias_name

	if _active_alias_calls.has(alias_name):
		return "Error: Alias recursion detected: %s" % alias_name

	_active_alias_calls.append(alias_name)
	var expansion := str(_aliases.get(alias_name, ""))
	var suffix := " ".join(args).strip_edges()
	var full_command := expansion if suffix.is_empty() else "%s %s" % [expansion, suffix]
	var result: String = _registry.execute_command(full_command)
	_active_alias_calls.erase(alias_name)
	return result

func _cmd_benchmark(args: Array) -> String:
	_ensure_dependencies()
	if not _registry:
		return "Error: CommandRegistry is unavailable"
	if args.is_empty():
		return "Usage: benchmark [iterations] <command>"

	var iterations := 10
	var command_parts := args.duplicate()
	if not command_parts.is_empty() and str(command_parts[0]).is_valid_int():
		iterations = int(str(command_parts[0]))
		command_parts = command_parts.slice(1)

	if iterations <= 0:
		return "Error: iterations must be > 0"
	if command_parts.is_empty():
		return "Usage: benchmark [iterations] <command>"

	var command_to_run := " ".join(command_parts).strip_edges()
	if command_to_run.begins_with("\"") and command_to_run.ends_with("\"") and command_to_run.length() >= 2:
		command_to_run = command_to_run.substr(1, command_to_run.length() - 2)
	if command_to_run.is_empty():
		return "Usage: benchmark [iterations] <command>"
	if command_to_run.begins_with("benchmark"):
		return "Error: benchmark cannot run benchmark recursively"

	var min_us := 9223372036854775807
	var max_us := 0
	var total_us := 0
	var last_result := ""

	for i in range(iterations):
		var started := Time.get_ticks_usec()
		last_result = _registry.execute_command(command_to_run)
		var elapsed := Time.get_ticks_usec() - started
		if elapsed < min_us:
			min_us = elapsed
		if elapsed > max_us:
			max_us = elapsed
		total_us += elapsed

	var avg_us := int(total_us / iterations)
	return "Benchmark '%s' iterations=%d avg=%.3fms min=%.3fms max=%.3fms%s" % [
		command_to_run,
		iterations,
		float(avg_us) / 1000.0,
		float(min_us) / 1000.0,
		float(max_us) / 1000.0,
		("\nLast result: %s" % last_result) if not last_result.is_empty() else ""
	]

func _cmd_config(args: Array) -> String:
	if args.is_empty():
		return _config_list()

	var action := str(args[0]).to_lower()
	match action:
		"list":
			return _config_list()
		"get":
			if args.size() < 2:
				return "Usage: config get <key>"
			var key := str(args[1]).to_lower()
			if not _DEFAULT_CONSOLE_CONFIG.has(key):
				return "Error: Unknown config key: %s" % key
			var values := _load_console_config_values()
			return "config %s = %s" % [key, str(values.get(key, _DEFAULT_CONSOLE_CONFIG[key]))]
		"set":
			if args.size() < 3:
				return "Usage: config set <key> <value>"
			var key := str(args[1]).to_lower()
			if not _DEFAULT_CONSOLE_CONFIG.has(key):
				return "Error: Unknown config key: %s" % key
			var raw_value := " ".join(args.slice(2)).strip_edges()
			var parsed := _parse_config_value(key, raw_value)
			if not bool(parsed.get("ok", false)):
				return str(parsed.get("result", "Error: Invalid value"))
			var values := _load_console_config_values()
			values[key] = parsed.get("value")
			_save_console_config_values(values)
			return "config %s set to %s" % [key, str(values[key])]
		"reset":
			if args.size() == 1:
				_save_console_config_values(_DEFAULT_CONSOLE_CONFIG.duplicate(true))
				return "config reset to defaults"
			var key := str(args[1]).to_lower()
			if not _DEFAULT_CONSOLE_CONFIG.has(key):
				return "Error: Unknown config key: %s" % key
			var values := _load_console_config_values()
			values[key] = _DEFAULT_CONSOLE_CONFIG[key]
			_save_console_config_values(values)
			return "config %s reset to %s" % [key, str(values[key])]
		_:
			return "Usage: config <list|get|set|reset> ..."

func _config_list() -> String:
	var values := _load_console_config_values()
	var keys := values.keys()
	keys.sort()
	var lines: Array[String] = ["Console config:"]
	for key_variant in keys:
		var key := str(key_variant)
		lines.append("  %s = %s" % [key, str(values[key])])
	return "\n".join(lines)

func _load_console_config_values() -> Dictionary:
	var values := _DEFAULT_CONSOLE_CONFIG.duplicate(true)
	var config := ConfigFile.new()
	if config.load(CONSOLE_CONFIG_PATH) != OK:
		return values
	if not config.has_section(CONSOLE_CONFIG_SECTION):
		return values
	for key_variant in _DEFAULT_CONSOLE_CONFIG.keys():
		var key := str(key_variant)
		if config.has_section_key(CONSOLE_CONFIG_SECTION, key):
			values[key] = config.get_value(CONSOLE_CONFIG_SECTION, key, _DEFAULT_CONSOLE_CONFIG[key])
	return values

func _save_console_config_values(values: Dictionary) -> void:
	var config := ConfigFile.new()
	for key_variant in _DEFAULT_CONSOLE_CONFIG.keys():
		var key := str(key_variant)
		config.set_value(CONSOLE_CONFIG_SECTION, key, values.get(key, _DEFAULT_CONSOLE_CONFIG[key]))
	config.save(CONSOLE_CONFIG_PATH)

func _parse_config_value(key: String, raw_value: String) -> Dictionary:
	var default_value = _DEFAULT_CONSOLE_CONFIG[key]
	if default_value is float:
		if not raw_value.is_valid_float():
			return {"ok": false, "result": "Error: %s expects a float" % key}
		return {"ok": true, "value": float(raw_value)}
	if default_value is int:
		if not raw_value.is_valid_int():
			return {"ok": false, "result": "Error: %s expects an int" % key}
		return {"ok": true, "value": int(raw_value)}
	return {"ok": true, "value": raw_value}

func _register_alias_commands() -> void:
	if not _registry:
		return
	for alias_name in _registered_alias_names:
		_registry.unregister_command(alias_name)
	_registered_alias_names.clear()

	for alias_name_variant in _aliases.keys():
		_register_single_alias_command(str(alias_name_variant))

func _register_single_alias_command(alias_name: String) -> void:
	if not _registry:
		return
	if alias_name.is_empty():
		return

	# Do not let aliases override built-in commands, except updating existing alias entries.
	if _registry._commands.has(alias_name) and not _registered_alias_names.has(alias_name):
		return

	var callable := Callable(self, "_execute_alias").bind(alias_name)
	_registry.register_command(alias_name, callable, "Alias for: %s" % str(_aliases.get(alias_name, "")), "both")
	if not _registered_alias_names.has(alias_name):
		_registered_alias_names.append(alias_name)

func _unregister_single_alias_command(alias_name: String) -> void:
	if not _registry:
		return
	_registry.unregister_command(alias_name)
	_registered_alias_names.erase(alias_name)

func _load_aliases_from_config() -> void:
	_aliases.clear()
	var config := ConfigFile.new()
	var err := config.load(ALIAS_CONFIG_PATH)
	if err != OK:
		return
	if not config.has_section("aliases"):
		return

	for key in config.get_section_keys("aliases"):
		var alias_name := str(key).to_lower()
		var expansion := str(config.get_value("aliases", key, "")).strip_edges()
		if alias_name.is_empty() or expansion.is_empty():
			continue
		_aliases[alias_name] = expansion

func _save_aliases_to_config() -> void:
	var config := ConfigFile.new()
	for alias_name_variant in _aliases.keys():
		var alias_name := str(alias_name_variant)
		config.set_value("aliases", alias_name, str(_aliases[alias_name]))
	config.save(ALIAS_CONFIG_PATH)
#endregion

#region Editor commands
func _get_current_scene(args: Array) -> String:
	if not Engine.is_editor_hint():
		return "Not in editor"
	
	var edited_scene = EditorInterface.get_edited_scene_root()
	if edited_scene:
		return "Current scene: %s (%s)" % [edited_scene.name, edited_scene.scene_file_path]
	else:
		return "No scene loaded"

func _reload_scene(args: Array) -> String:
	if not Engine.is_editor_hint():
		return "Not in editor"
	
	EditorInterface.reload_scene_from_path(EditorInterface.get_edited_scene_root().scene_file_path)
	return "Scene reloaded"

func _refresh_filesystem(args: Array) -> String:
	if not Engine.is_editor_hint():
		return "Not in editor"
	
	EditorInterface.get_resource_filesystem().scan()
	return "Filesystem refreshed"

#endregion

#region File system commands
var current_directory: String = "res://"

static var global_current_directory: String = "res://"

# keepalive for external command modules (SceneCommands, RuntimeCommands,
# UICommands). Each module is RefCounted and registers Callables bound to
# itself. If we stored these on the instance, a transient BuiltInCommands.new()
# would let the modules GC after register_universal_commands() returns,
# silently invalidating every registered Callable. The static array survives
# transient instances and survives autoload reload, while a fresh registry
# still gets re-registered on the next call (modules are stateless w.r.t.
# the registry identity).
static var _t6_keepalive: Array = []
# extensions: auto-discovered modules in core/extensions/. Separate from
# _t6_keepalive so the size-mismatch hot-reload guard above does not false-alarm
# when an extension is added or removed.
static var _t8_extensions: Array = []

static func get_current_directory() -> String:
	return global_current_directory

static func set_current_directory(path: String):
	global_current_directory = path

func _resolve_output_path(raw_path: String) -> String:
	var trimmed_path := raw_path.strip_edges()
	if trimmed_path.is_empty():
		return ""

	if trimmed_path.begins_with("res://") or trimmed_path.begins_with("user://"):
		return trimmed_path

	if Engine.is_editor_hint():
		return current_directory.path_join(trimmed_path)

	return "user://" + trimmed_path

func _list_files(args: Array, input: String = "", is_pipe_context: bool = false) -> String:
	# T2.2: detect the -l flag for the long-format table renderer. Anything
	# else in args is ignored (preserves the existing "no positional args"
	# contract of the original implementation).
	var long_format: bool = false
	for a in args:
		if str(a) == "-l":
			long_format = true
			break
	
	var dir = DirAccess.open(current_directory)
	if not dir:
		return "Error: Cannot access directory"
	
	# Capture is_dir per-entry DURING iteration. The pre-T2.2 code called
	var entries: Array = []
	dir.list_dir_begin()
	var file_name = dir.get_next()
	while file_name != "":
		if not file_name.begins_with("."):
			entries.append({"name": file_name, "is_dir": dir.current_is_dir()})
		file_name = dir.get_next()
	dir.list_dir_end()
	entries.sort_custom(func(a, b): return str(a["name"]) < str(b["name"]))
	
	if long_format:
		return _format_long_listing(entries)
	
	var colored_files: Array = []
	for e in entries:
		colored_files.append(_get_colored_filename(str(e["name"]), bool(e["is_dir"])))
	
	if is_pipe_context:
		return "\n".join(colored_files)
	
	return "Files in %s:\n%s" % [current_directory, "\t".join(colored_files)]

# long-format table renderer for `ls -l`. Columns are TYPE / NAME / SIZE /
# MODIFIED separated by spaces. NAME is padded based on the PLAIN-text length
# of the entry (BBCode tags add invisible chars that would throw off %-Ns
# padding), so emoji width is the only remaining source of column drift.
const _LS_NAME_WIDTH := 32

func _format_long_listing(entries: Array) -> String:
	var lines: Array = []
	lines.append("%-5s %-32s %-10s %s" % ["TYPE", "NAME", "SIZE", "MODIFIED"])
	for e in entries:
		var name: String = str(e["name"])
		var is_dir: bool = bool(e["is_dir"])
		var type_label: String = "DIR" if is_dir else "FILE"
		var display_name: String = name + ("/" if is_dir else "")
		var truncated_display: String = _truncate_name(display_name, _LS_NAME_WIDTH)
		var colored_name: String = _get_colored_filename(name, is_dir)
		var pad: int = max(0, _LS_NAME_WIDTH - truncated_display.length())
		var name_cell: String = colored_name + " ".repeat(pad)
		var path: String = current_directory.path_join(name)
		var size_str: String = "-" if is_dir else _human_size(_file_size(path))
		var mtime_str: String = _format_mtime(path)
		lines.append("%-5s %s %-10s %s" % [type_label, name_cell, size_str, mtime_str])
	return "\n".join(lines)

func _truncate_name(name: String, max_width: int) -> String:
	if name.length() <= max_width:
		return name
	return name.substr(0, max_width - 1) + "…"

func _file_size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if not f:
		return 0
	var size: int = f.get_length()
	f.close()
	return size

func _human_size(bytes: int) -> String:
	if bytes < 0:
		return "-"
	if bytes < 1024:
		return "%dB" % bytes
	if bytes < 1024 * 1024:
		return "%.1fKB" % (bytes / 1024.0)
	if bytes < 1024 * 1024 * 1024:
		return "%.1fMB" % (bytes / (1024.0 * 1024.0))
	return "%.1fGB" % (bytes / (1024.0 * 1024.0 * 1024.0))

func _format_mtime(path: String) -> String:
	var unix_time: int = int(FileAccess.get_modified_time(path))
	if unix_time <= 0:
		return "-"
	var dt: Dictionary = Time.get_datetime_dict_from_unix_time(unix_time)
	return "%04d-%02d-%02d" % [int(dt.get("year", 0)), int(dt.get("month", 0)), int(dt.get("day", 0))]

func _get_colored_filename(filename: String, is_dir: bool) -> String:
	if is_dir:
		return "[color=#4A90E2]📁 %s[/color]" % filename  
	var extension = filename.get_extension().to_lower()
	if extension in ["gd", "cs", "py", "sh", "bat", "exe"]:
		return "[color=#50C878]📄 %s[/color]" % filename 
	elif extension in ["zip", "tar", "gz", "rar", "7z", "bz2", "xz"]:
		return "[color=#FF6B6B]📦 %s[/color]" % filename
	elif extension in ["png", "jpg", "jpeg", "gif", "bmp", "svg", "webp", "ico", "tiff"]:
		return "[color=#FF69B4]🖼️ %s[/color]" % filename  
	elif extension in ["mp3", "wav", "ogg", "flac", "aac", "m4a", "wma"]:
		return "[color=#40E0D0]🎵 %s[/color]" % filename  
	elif extension in ["mp4", "avi", "mkv", "mov", "wmv", "flv", "webm", "ogv"]:
		return "[color=#FFD700]🎬 %s[/color]" % filename  
	elif extension in ["tscn", "tres", "godot", "import"]:
		return "[color=#87CEEB]🎮 %s[/color]" % filename  
	elif extension in ["json", "xml", "yaml", "yml", "toml", "ini", "cfg", "conf"]:
		return "[color=#FFA500]⚙️ %s[/color]" % filename  
	elif extension in ["txt", "md", "rst", "doc", "docx", "pdf", "rtf"]:
		return "[color=#F5F5F5]📝 %s[/color]" % filename  
	elif filename.ends_with("~") or filename.ends_with(".bak") or filename.ends_with(".backup"):
		return "[color=#696969]💾 %s[/color]" % filename 
	elif filename.begins_with("."):
		return "[color=#696969] %s[/color]" % filename  
	else:
		return "[color=#FFFFFF]📄 %s[/color]" % filename  

func _change_directory(args: Array) -> String:
	if args.size() == 0:
		return "Usage: cd <directory>"
	
	var target_dir = args[0]
	var new_path = current_directory
	
	if target_dir == "..":
		if current_directory == "res://":
			return "Already at root directory"
		var parent = current_directory.get_base_dir()
		if parent == "res:":
			parent = "res://"
		new_path = parent
	elif target_dir == ".":
		return "Current directory: %s" % current_directory
	elif target_dir == "/":
		new_path = "res://"
	else:
		if target_dir.begins_with("/"):
			new_path = "res://" + target_dir.substr(1)
		else:
			new_path = current_directory.path_join(target_dir)
	
	if DirAccess.dir_exists_absolute(new_path):
		current_directory = new_path
		set_current_directory(new_path)
		if _state_saver: _state_saver.save_cwd(current_directory)
		return "Changed to: %s" % current_directory
	else:
		return "Error: Directory not found"

func _print_working_directory(args: Array) -> String:
	return "Current directory: %s" % current_directory

func _make_directory(args: Array) -> String:
	if args.size() == 0:
		return "Usage: mkdir <directory_name>"
	
	var dir_name = args[0]
	var dir = DirAccess.open(current_directory)
	if not dir:
		return "Error: Cannot access directory"
	
	var result = dir.make_dir_recursive(dir_name)
	if result == OK:
		_refresh_filesystem([])
		return "Created directory: %s" % dir_name
	else:
		return "Error: Failed to create directory"

func _create_file(args: Array) -> String:
	if args.size() == 0:
		return "Usage: touch <filename>"
	
	var file_name = args[0]
	var full_path = current_directory.path_join(file_name)
	var file = FileAccess.open(full_path, FileAccess.WRITE)
	if file:
		file.close()
		_refresh_filesystem([])
		return "Created file: %s" % file_name
	else:
		return "Error: Failed to create file"

func _remove_file(args: Array) -> String:
	if args.size() == 0:
		return "Usage: rm <filename>"
	
	var file_name = args[0]
	var dir = DirAccess.open(current_directory)
	if not dir:
		return "Error: Cannot access directory"
	
	var result = dir.remove(file_name)
	if result == OK:
		_refresh_filesystem([])
		return "Removed: %s" % file_name
	else:
		return "Error: Failed to remove file"

func _remove_directory(args: Array) -> String:
	if args.size() == 0:
		return "Usage: rmdir <directory>"
	
	var dir_name = args[0]
	var dir = DirAccess.open(current_directory)
	if not dir:
		return "Error: Cannot access directory"
	
	var result = dir.remove(dir_name)
	if result == OK:
		_refresh_filesystem([])
		return "Removed directory: %s" % dir_name
	else:
		return "Error: Failed to remove directory"

func _move_file(args: Array) -> String:
	if args.size() < 2:
		return "Usage: mv <source> <destination>"
	
	var source = args[0]
	var dest = args[1]
	var dir = DirAccess.open(current_directory)
	if not dir:
		return "Error: Cannot access directory"
	
	var result = dir.rename(source, dest)
	if result == OK:
		_refresh_filesystem([])
		return "Moved %s to %s" % [source, dest]
	else:
		return "Error: Failed to move file"

func _copy_file(args: Array) -> String:
	if args.size() < 2:
		return "Usage: cp <source> <destination>"
	
	var source = args[0]
	var dest = args[1]
	
	var source_path = current_directory.path_join(source)
	var dest_path = current_directory.path_join(dest)
	
	var source_file = FileAccess.open(source_path, FileAccess.READ)
	if not source_file:
		return "Error: Cannot read source file"
	
	var dest_file = FileAccess.open(dest_path, FileAccess.WRITE)
	if not dest_file:
		source_file.close()
		return "Error: Cannot write destination file"
	
	dest_file.store_buffer(source_file.get_buffer(source_file.get_length()))
	source_file.close()
	dest_file.close()
	
	_refresh_filesystem([])
	return "Copied %s to %s" % [source, dest]

func _view_file(args: Array, input: String = "", is_pipe_context: bool = false) -> String:
	if args.size() == 0:
		return "Usage: cat <filename>"
	
	var file_name = args[0]
	var full_path = current_directory.path_join(file_name)
	
	if not FileAccess.file_exists(full_path):
		return "Error: File not found - %s" % full_path
	
	var file = FileAccess.open(full_path, FileAccess.READ)
	if not file:
		return "Error: Cannot read file - %s" % file_name
	
	var content = file.get_as_text()
	file.close()
	

	if is_pipe_context or not input.is_empty():
		return content
	
	var extension = file_name.get_extension().to_lower()
	if extension == "gd":
		content = _colorize_gdscript(content)
	
	# Limit output to prevent console overflow
	var limit: int = 3000
	if content.length() > limit:  
		var preview = content.substr(0, limit)
		return "%s:\n%s\n... (truncated)" % [file_name, preview]
	else:
		return "%s:\n%s" % [file_name, content]

func _colorize_gdscript(content: String) -> String:
	var lines = content.split("\n")
	var colored_lines = []
	
	for line in lines:
		var colored_line = line
		

		if line.strip_edges().begins_with("#"):
			colored_line = "[color=#999999]%s[/color]" % line
		else:

			colored_line = _color_strings(colored_line)
			

			colored_line = _color_comments(colored_line)
			
			
			if not _is_line_comment(line):
				colored_line = _color_keywords(colored_line)
				colored_line = _color_types(colored_line)
				colored_line = _color_functions(colored_line)
				colored_line = _color_numbers(colored_line)
				colored_line = _color_function_definitions(colored_line)
		
		colored_lines.append(colored_line)
	
	return "\n".join(colored_lines)

func _is_line_comment(line: String) -> bool:
	return line.strip_edges().begins_with("#")

func _color_strings(text: String) -> String:
	var result = text
	

	var i = 0
	while i < result.length():
		if result[i] == '"':
			var start = i
			i += 1
			var escaped = false
			while i < result.length():
				if escaped:
					escaped = false
				elif result[i] == '\\':
					escaped = true
				elif result[i] == '"':
					break
				i += 1
			if i < result.length():
				var string_content = result.substr(start, i - start + 1)
				var colored_string = "[color=#98D8C8]%s[/color]" % string_content
				result = result.substr(0, start) + colored_string + result.substr(i + 1)
				i = start + colored_string.length()
		else:
			i += 1
	

	i = 0
	while i < result.length():
		if result[i] == "'" and not _is_inside_color_tag(result, i):
			var start = i
			i += 1
			var escaped = false
			while i < result.length():
				if escaped:
					escaped = false
				elif result[i] == '\\':
					escaped = true
				elif result[i] == "'":
					break
				i += 1
			if i < result.length():
				var string_content = result.substr(start, i - start + 1)
				var colored_string = "[color=#98D8C8]%s[/color]" % string_content
				result = result.substr(0, start) + colored_string + result.substr(i + 1)
				i = start + colored_string.length()
		else:
			i += 1
	
	return result

func _color_comments(text: String) -> String:
	var hash_pos = text.find("#")
	if hash_pos != -1 and not _is_inside_color_tag(text, hash_pos):
		var before_comment = text.substr(0, hash_pos)
		var comment = text.substr(hash_pos)
		return before_comment + "[color=#999999]%s[/color]" % comment
	return text

func _color_keywords(text: String) -> String:
	var keywords = ["extends", "class_name", "func", "var", "const", "signal", "enum", 
					"if", "elif", "else", "for", "while", "match", "continue", "break", 
					"return", "pass", "and", "or", "not", "in", "is", "as", "self", 
					"true", "false", "null", "PI", "TAU", "INF", "NAN"]
	
	var result = text
	for keyword in keywords:
		result = _replace_whole_word(result, keyword, "[color=#FF6B9D]%s[/color]" % keyword)
	return result

func _color_types(text: String) -> String:
	var types = ["bool", "int", "float", "String", "Vector2", "Vector3", "Color", 
				 "Array", "Dictionary", "Node2D", "Node3D", "Node", "Control", "Resource"]
	
	var result = text
	for type in types:
		result = _replace_whole_word(result, type, "[color=#4ECDC4]%s[/color]" % type)
	return result

func _color_functions(text: String) -> String:
	var builtins = ["print", "printerr", "printt", "prints", "push_error", "push_warning",
					"len", "range", "abs", "min", "max", "clamp", "lerp", "sin", "cos", "tan"]
	
	var result = text
	for builtin in builtins:
		var pattern = builtin + "("
		var pos = result.find(pattern)
		while pos != -1:
			if _is_word_boundary_before(result, pos) and not _is_inside_color_tag(result, pos):
				var colored_func = "[color=#45B7D1]%s[/color](" % builtin
				result = result.substr(0, pos) + colored_func + result.substr(pos + pattern.length())
				pos = result.find(pattern, pos + colored_func.length())
			else:
				pos = result.find(pattern, pos + 1)
	return result

func _color_numbers(text: String) -> String:
	var result = text
	var i = 0
	while i < result.length():
		if result[i].is_valid_int() and not _is_inside_color_tag(result, i):
			if i == 0 or not result[i-1].is_valid_identifier():
				var start = i
				while i < result.length() and (result[i].is_valid_int() or result[i] == '.'):
					i += 1
				if i >= result.length() or not result[i].is_valid_identifier():
					var number = result.substr(start, i - start)
					var colored_number = "[color=#F7DC6F]%s[/color]" % number
					result = result.substr(0, start) + colored_number + result.substr(i)
					i = start + colored_number.length()
					continue
		i += 1
	return result

func _color_function_definitions(text: String) -> String:
	var func_pos = text.find("func ")
	if func_pos != -1 and not _is_inside_color_tag(text, func_pos):
		var after_func = func_pos + 5
		while after_func < text.length() and text[after_func] == ' ':
			after_func += 1
		
		var name_start = after_func
		var name_end = name_start
		while name_end < text.length() and (text[name_end].is_valid_identifier() or text[name_end] == '_'):
			name_end += 1
		
		if name_end > name_start:
			var func_name = text.substr(name_start, name_end - name_start)
			var colored_name = "[color=#FFB347]%s[/color]" % func_name
			return text.substr(0, name_start) + colored_name + text.substr(name_end)
	return text

func _replace_whole_word(text: String, word: String, replacement: String) -> String:
	var result = text
	var pos = 0
	while pos < result.length():
		pos = result.find(word, pos)
		if pos == -1:
			break
		
		if _is_word_boundary_before(result, pos) and _is_word_boundary_after(result, pos + word.length()) and not _is_inside_color_tag(result, pos):
			result = result.substr(0, pos) + replacement + result.substr(pos + word.length())
			pos += replacement.length()
		else:
			pos += 1
	return result

func _is_word_boundary_before(text: String, pos: int) -> bool:
	if pos == 0:
		return true
	var prev_char = text[pos - 1]
	return not (prev_char.is_valid_identifier() or prev_char == '_')

func _is_word_boundary_after(text: String, pos: int) -> bool:
	if pos >= text.length():
		return true
	var next_char = text[pos]
	return not (next_char.is_valid_identifier() or next_char == '_')

func _is_inside_color_tag(text: String, pos: int) -> bool:
	var check_pos = pos - 1
	while check_pos >= 0:
		if text.substr(check_pos, 8) == "[/color]":
			return false
		if text.substr(check_pos, 7) == "[color=":
			return true
		check_pos -= 1
	return false

func _create_script(args: Array) -> String:
	if args.size() == 0:
		return "Usage: new_script <filename> [extends_type] [class_name]"
	
	var file_name = args[0]
	if not file_name.ends_with(".gd"):
		file_name += ".gd"
	
	var extends_type = args[1] if args.size() > 1 else "Node"
	var classname = args[2] if args.size() > 2 else _sanitize_classname(file_name.get_basename().capitalize().replace(" ", ""))
	
	var valid_types = ["Node", "Node2D", "Node3D", "Control", "CanvasItem", "CanvasLayer", "Viewport", "Window", "SubViewport", "Area2D", "Area3D", "CollisionShape2D", "CollisionShape3D", "Sprite2D", "Sprite3D", "Label", "Button", "LineEdit", "TextEdit", "RichTextLabel", "Panel", "VBoxContainer", "HBoxContainer", "GridContainer", "CenterContainer", "MarginContainer", "ScrollContainer", "TabContainer", "SplitContainer", "AspectRatioContainer", "TextureRect", "ColorRect", "NinePatchRect", "ProgressBar", "Slider", "SpinBox", "CheckBox", "CheckButton", "OptionButton", "ItemList", "Tree", "TreeItem", "FileDialog", "ColorPicker", "ColorPickerButton", "MenuButton", "PopupMenu", "MenuBar", "ToolButton", "LinkButton", "TextureButton", "TextureProgressBar", "AnimationPlayer", "AnimationTree", "Tween", "Timer", "Camera2D", "Camera3D", "Light2D", "Light3D", "AudioStreamPlayer", "AudioStreamPlayer2D", "AudioStreamPlayer3D", "AudioListener2D", "AudioListener3D", "RigidBody2D", "RigidBody3D", "CharacterBody2D", "CharacterBody3D", "StaticBody2D", "StaticBody3D", "KinematicBody2D", "KinematicBody3D", "Path2D", "Path3D", "NavigationAgent2D", "NavigationAgent3D", "NavigationRegion2D", "NavigationRegion3D", "NavigationPolygon", "NavigationMesh", "NavigationLink2D", "NavigationLink3D", "NavigationObstacle2D", "NavigationObstacle3D", "NavigationPathQueryParameters2D", "NavigationPathQueryParameters3D", "NavigationPathQueryResult2D", "NavigationPathQueryResult3D", "NavigationMeshSourceGeometry2D", "NavigationMeshSourceGeometry3D", "NavigationMeshSourceGeometryData2D", "NavigationMeshSourceGeometryData3D"]
	
	if not valid_types.has(extends_type):
		return "Error: Invalid extends type '%s'. Use: %s" % [extends_type, ", ".join(valid_types.slice(0, 10)) + "..."]
	
	var script_content = """extends %s

class_name %s

func _ready():
	pass

func _process(delta):
	pass
""" % [extends_type, classname]
	
	var full_path = current_directory.path_join(file_name)
	var file = FileAccess.open(full_path, FileAccess.WRITE)
	if file:
		file.store_string(script_content)
		file.close()
		_refresh_filesystem([])
		return "Created script: %s (extends %s)" % [file_name, extends_type]
	else:
		return "Error: Failed to create script"

# Strips leading dots and replaces non-identifier chars with underscores,
func _sanitize_classname(raw: String) -> String:
	if raw.is_empty():
		return "GeneratedClass"
	var s := raw
	while not s.is_empty() and s[0] == ".":
		s = s.substr(1)
	var result := ""
	for i in range(s.length()):
		var c := s[i]
		# A letter has different upper- and lower-case forms; a digit doesn't.
		var is_letter := c.to_lower() != c.to_upper()
		var is_digit := c.is_valid_int()
		if is_letter or is_digit or c == "_":
			result += c
		else:
			result += "_"
	if result.is_empty():
		return "GeneratedClass"
	if result[0].is_valid_int():
		result = "_" + result
	return result

func _create_scene(args: Array) -> String:
	if args.size() == 0:
		return "Usage: new_scene <filename> [root_node_type]"
	
	var file_name = args[0]
	if not file_name.ends_with(".tscn"):
		file_name += ".tscn"
	
	var root_type = args[1] if args.size() > 1 else "Node"
	var script_name = file_name.replace(".tscn", ".gd")
	var classname = _sanitize_classname(file_name.get_basename().capitalize().replace(" ", ""))
	
	# Write both the script and the scene under current_directory so they sit
	var script_result = _create_script([script_name.get_basename(), root_type, classname])
	if not script_result.contains("Created script"):
		return "Error: " + script_result
	
	var script_full_path := current_directory.path_join(script_name)
	var scene_full_path := current_directory.path_join(file_name)
	
	var new_uid_int := ResourceUID.create_id()
	var new_uid_str := ResourceUID.id_to_text(new_uid_int)
	var scene_content = """[gd_scene load_steps=2 format=3 uid="%s"]

[ext_resource type="Script" path="%s" id="1_0"]

[node name="%s" type="%s"]
script = ExtResource("1_0")
""" % [new_uid_str, script_full_path, classname, root_type]
	
	var scene_file = FileAccess.open(scene_full_path, FileAccess.WRITE)
	if scene_file:
		scene_file.store_string(scene_content)
		scene_file.close()
		_refresh_filesystem([])
		return "Created scene: %s with script: %s" % [scene_full_path, script_full_path]
	else:
		return "Error: Failed to create scene file"

func _create_resource(args: Array) -> String:
	if args.size() == 0:
		return "Usage: new_resource <filename> [resource_type]"
	
	var file_name = args[0]
	if not file_name.ends_with(".tres"):
		file_name += ".tres"
	
	var resource_type = args[1] if args.size() > 1 else "Resource"
	
	var resource_content = """[gd_resource type="%s" format=3]
""" % resource_type
	
	var file = FileAccess.open("res://" + file_name, FileAccess.WRITE)
	if file:
		file.store_string(resource_content)
		file.close()
		_refresh_filesystem([])
		return "Created resource: %s" % file_name
	else:
		return "Error: Failed to create resource"

func _open_file(args: Array) -> String:
	if args.size() == 0:
		return "Usage: open <filename>"
	
	var file_name = args[0]
	var full_path = current_directory.path_join(file_name)
	
	if not FileAccess.file_exists(full_path):
		return "Error: File not found - %s" % full_path
	
	var extension = file_name.get_extension().to_lower()
	
	if extension == "tscn":
		EditorInterface.open_scene_from_path(full_path)
		return "Opened scene: %s" % file_name
	elif extension == "gd" or extension == "cs":
		var script = load(full_path)
		if script:
			EditorInterface.edit_script(script)
			return "Opened script: %s" % file_name
		else:
			return "Error: Could not load script - %s" % file_name
	elif extension == "tres":
		var resource = load(full_path)
		if resource:
			EditorInterface.edit_resource(resource)
			return "Opened resource: %s" % file_name
		else:
			return "Error: Could not load resource - %s" % file_name
	elif extension in ["txt", "md", "json", "xml", "yaml", "yml", "cfg", "ini", "log"]:
		var file = FileAccess.open(full_path, FileAccess.READ)
		if file:
			var content = file.get_as_text()
			file.close()
			var preview = content.substr(0, min(500, content.length()))
			if content.length() > 500:
				preview += "\n... (truncated, %d total characters)" % content.length()
			return "Content of %s:\n%s" % [file_name, preview]
		else:
			return "Error: Could not read file - %s" % file_name
	else:
		var file = FileAccess.open(full_path, FileAccess.READ)
		if file:
			var size = file.get_length()
			file.close()
			return "File info: %s (%d bytes)\nUse 'cat %s' to view content or open externally" % [file_name, size, file_name]
		else:
			return "Error: Cannot access file - %s" % file_name

func _list_node_types(args: Array) -> String:
	var valid_types = ["Node", "Node2D", "Node3D", "Control", "CanvasItem", "CanvasLayer", "Viewport", "Window", "SubViewport", "Area2D", "Area3D", "CollisionShape2D", "CollisionShape3D", "Sprite2D", "Sprite3D", "Label", "Button", "LineEdit", "TextEdit", "RichTextLabel", "Panel", "VBoxContainer", "HBoxContainer", "GridContainer", "CenterContainer", "MarginContainer", "ScrollContainer", "TabContainer", "SplitContainer", "AspectRatioContainer", "TextureRect", "ColorRect", "NinePatchRect", "ProgressBar", "Slider", "SpinBox", "CheckBox", "CheckButton", "OptionButton", "ItemList", "Tree", "TreeItem", "FileDialog", "ColorPicker", "ColorPickerButton", "MenuButton", "PopupMenu", "MenuBar", "ToolButton", "LinkButton", "TextureButton", "TextureProgressBar", "AnimationPlayer", "AnimationTree", "Tween", "Timer", "Camera2D", "Camera3D", "Light2D", "Light3D", "AudioStreamPlayer", "AudioStreamPlayer2D", "AudioStreamPlayer3D", "AudioListener2D", "AudioListener3D", "RigidBody2D", "RigidBody3D", "CharacterBody2D", "CharacterBody3D", "StaticBody2D", "StaticBody3D", "KinematicBody2D", "KinematicBody3D", "Path2D", "Path3D", "NavigationAgent2D", "NavigationAgent3D", "NavigationRegion2D", "NavigationRegion3D", "NavigationPolygon", "NavigationMesh", "NavigationLink2D", "NavigationLink3D", "NavigationObstacle2D", "NavigationObstacle3D", "NavigationPathQueryParameters2D", "NavigationPathQueryParameters3D", "NavigationPathQueryResult2D", "NavigationPathQueryResult3D", "NavigationMeshSourceGeometry2D", "NavigationMeshSourceGeometry3D", "NavigationMeshSourceGeometryData2D", "NavigationMeshSourceGeometryData3D"]
	
	return "Available node types:\n" + "\n".join(valid_types)
#endregion

#region Search and filter commands
func _find(args: Array) -> String:
	var dir = DirAccess.open(current_directory)
	if not dir:
		return "Error: Cannot access directory"
	
	var search_name = args[0] if args.size() > 0 else ""
	if search_name.is_empty():
		return "Usage: find <filename_pattern>"
	
	var results = []
	_find_recursive(dir, search_name, results)
	
	if results.is_empty():
		return "No files found matching: %s" % search_name
	else:
		return "Found %d files:\n%s" % [results.size(), "\n".join(results)]

func _find_recursive(dir: DirAccess, pattern: String, results: Array):
	dir.list_dir_begin()
	var file_name = dir.get_next()
	
	while file_name != "":
		if not file_name.begins_with("."):
			var full_path = dir.get_current_dir().path_join(file_name)
			if dir.current_is_dir():
				var subdir = DirAccess.open(full_path)
				if subdir:
					_find_recursive(subdir, pattern, results)
			elif file_name.contains(pattern):
				results.append(full_path)
		file_name = dir.get_next()
	
	dir.list_dir_end()

func _grep(args: Array, input: String = "", is_pipe_context: bool = false) -> String:
	var search_pattern = ""
	var search_path = current_directory
	
	if args.size() > 0:
		search_pattern = args[0]
	else:
		return "Usage: grep <pattern> [path] or use with pipe"
	
	if not input.is_empty():
		var lines = input.split("\n")
		var results = []
		for i in range(lines.size()):
			if lines[i].contains(search_pattern):
				results.append(lines[i])  
		return "\n".join(results) if not results.is_empty() else "No matches found"
	

	if args.size() > 1:
		search_path = current_directory.path_join(args[1])
	
	var results = []
	_grep_recursive(search_path, search_pattern, results)
	
	if results.is_empty():
		return "No matches found for: %s" % search_pattern
	else:
		return "Found %d matches:\n%s" % [results.size(), "\n".join(results)]

func _grep_recursive(path: String, pattern: String, results: Array):
	if FileAccess.file_exists(path):
		var file = FileAccess.open(path, FileAccess.READ)
		if file:
			var content = file.get_as_text()
			file.close()
			var lines = content.split("\n")
			for i in range(lines.size()):
				if lines[i].contains(pattern):
					results.append("%s:%d: %s" % [path, i + 1, lines[i]])
	elif DirAccess.dir_exists_absolute(path):
		var dir = DirAccess.open(path)
		if dir:
			dir.list_dir_begin()
			var file_name = dir.get_next()
			while file_name != "":
				if not file_name.begins_with("."):
					var full_path = path.path_join(file_name)
					_grep_recursive(full_path, pattern, results)
				file_name = dir.get_next()
			dir.list_dir_end()

func _stat(args: Array) -> String:
	if args.size() == 0:
		return "Usage: stat <filename>"
	
	var file_name = args[0]
	var full_path = current_directory.path_join(file_name)
	
	if not FileAccess.file_exists(full_path) and not DirAccess.dir_exists_absolute(full_path):
		return "Error: File or directory not found - %s" % full_path
	
	var info = []
	info.append("File: %s" % full_path)
	
	if FileAccess.file_exists(full_path):
		var file = FileAccess.open(full_path, FileAccess.READ)
		if file:
			var size = file.get_length()
			file.close()
			info.append("Type: File")
			info.append("Size: %d bytes" % size)
			info.append("Extension: %s" % file_name.get_extension())
	elif DirAccess.dir_exists_absolute(full_path):
		info.append("Type: Directory")
		var dir = DirAccess.open(full_path)
		if dir:
			var count = 0
			dir.list_dir_begin()
			var file_name_in_dir = dir.get_next()
			while file_name_in_dir != "":
				if not file_name_in_dir.begins_with("."):
					count += 1
				file_name_in_dir = dir.get_next()
			dir.list_dir_end()
			info.append("Items: %d" % count)
	
	return "\n".join(info)

func _head(args: Array, input: String = "", is_pipe_context: bool = false) -> String:
	var lines_to_show = 10
	var content = ""
	

	if not input.is_empty():
		content = input
		if args.size() > 0:
			lines_to_show = args[0].to_int()
	elif args.size() > 0:
		if args[0].is_valid_int():
			lines_to_show = args[0].to_int()
			if args.size() > 1:
				var file_name = args[1]
				var full_path = current_directory.path_join(file_name)
				if FileAccess.file_exists(full_path):
					var file = FileAccess.open(full_path, FileAccess.READ)
					if file:
						content = file.get_as_text()
						file.close()
				else:
					return "Error: File not found - %s" % full_path
			else:
				return "Usage: head [lines] [filename] or use with pipe"
		else:
			var file_name = args[0]
			var full_path = current_directory.path_join(file_name)
			if FileAccess.file_exists(full_path):
				var file = FileAccess.open(full_path, FileAccess.READ)
				if file:
					content = file.get_as_text()
					file.close()
			else:
				return "Error: File not found - %s" % full_path
	else:
		return "Usage: head [lines] [filename] or use with pipe"
	
	if content.is_empty():
		return "No content to process"
	
	var lines = content.split("\n")
	var result_lines = lines.slice(0, min(lines_to_show, lines.size()))
	return "\n".join(result_lines)

func _tail(args: Array, input: String = "", is_pipe_context: bool = false) -> String:
	var lines_to_show = 10
	var content = ""
	
	if not input.is_empty():
		content = input
		if args.size() > 0:
			lines_to_show = args[0].to_int()
	elif args.size() > 0:
		if args[0].is_valid_int():
			lines_to_show = args[0].to_int()
			if args.size() > 1:
				var file_name = args[1]
				var full_path = current_directory.path_join(file_name)
				if FileAccess.file_exists(full_path):
					var file = FileAccess.open(full_path, FileAccess.READ)
					if file:
						content = file.get_as_text()
						file.close()
				else:
					return "Error: File not found - %s" % full_path
			else:
				return "Usage: tail [lines] [filename] or use with pipe"
		else:
			# First argument is filename
			var file_name = args[0]
			var full_path = current_directory.path_join(file_name)
			if FileAccess.file_exists(full_path):
				var file = FileAccess.open(full_path, FileAccess.READ)
				if file:
					content = file.get_as_text()
					file.close()
			else:
				return "Error: File not found - %s" % full_path
	else:
		return "Usage: tail [lines] [filename] or use with pipe"
	
	if content.is_empty():
		return "No content to process"
	
	var lines = content.split("\n")
	var start_index = max(0, lines.size() - lines_to_show)
	var result_lines = lines.slice(start_index)
	return "\n".join(result_lines)

#endregion

#region Editor project commands
func _save_scene(args: Array) -> String:
	if not Engine.is_editor_hint():
		return "Not in editor"
	
	EditorInterface.save_all_scenes()
	return "All scenes saved successfully"


func _run_project(args: Array) -> String:
	if not Engine.is_editor_hint():
		return "Not in editor"
	
	var scene_path = ""
	if args.size() > 0:
		scene_path = args[0]
		if not scene_path.ends_with(".tscn"):
			scene_path += ".tscn"
		if not scene_path.begins_with("res://"):
			scene_path = "res://" + scene_path
	
	if scene_path.is_empty():
		EditorInterface.play_main_scene()
		return "Running main scene"
	else:
		EditorInterface.play_custom_scene(scene_path)
		return "Running scene: %s" % scene_path

func _stop_project(args: Array) -> String:
	if not Engine.is_editor_hint():
		return "Not in editor"
	
	EditorInterface.stop_playing_scene()
	return "Project stopped"

#endregion

#region History commands
func _show_history(args: Array) -> String:
	_ensure_dependencies()
	var history = _registry.get_command_history()
	if history.is_empty():
		return "Command history is empty"
	
	var result = "Command history:\n"
	for i in range(history.size()):
		result += "%d: %s\n" % [i + 1, history[i]]
	
	return result

func _clear_history(args: Array) -> String:
	_ensure_dependencies()
	_registry.clear_command_history()
	return "History cleared"

func _save_log(args: Array) -> String:
	_ensure_dependencies()
	if not _core:
		return "Error: DebugCore is unavailable"
	if args.is_empty():
		return "Usage: save_log <path>"

	var target_path := _resolve_output_path(" ".join(args))
	if target_path.is_empty():
		return "Usage: save_log <path>"

	var save_result: Dictionary = _core.save_history_to_file(target_path)
	if not bool(save_result.get("ok", false)):
		return str(save_result.get("result", "Error: Failed to save log"))

	if Engine.is_editor_hint() and target_path.begins_with("res://"):
		_refresh_filesystem([])

	return "Saved %d log entries to: %s" % [
		int(save_result.get("count", 0)),
		str(save_result.get("path", target_path))
	]
#endregion

#region Testing commands

func _new_test_framework():
	var script: GDScript = load("res://addons/debug_console/tests/TestFramework.gd")
	if not script:
		return null
	return script.new()

func _test_framework_error() -> String:
	return "Error: TestFramework could not be loaded. Open Godot's Output panel and check addons/debug_console/tests/TestFramework.gd for parse errors."

func _run_tests(args: Array) -> String:
	var test_framework = _new_test_framework()
	if not test_framework:
		return _test_framework_error()
	test_framework.run_all_tests()
	
	register_editor_commands()
	
	return "Comprehensive test suite completed! Check console for detailed results."

func _test_commands(args: Array) -> String:
	var test_framework = _new_test_framework()
	if not test_framework:
		return _test_framework_error()
	test_framework.run_command_registry_tests()
	
	register_editor_commands()
	
	return "Command registry tests completed! Check console for results."

func _test_autocomplete(args: Array) -> String:
	var test_framework = _new_test_framework()
	if not test_framework:
		return _test_framework_error()
	test_framework.run_autocomplete_tests()
	
	register_editor_commands()
	
	return "Autocomplete tests completed. Console reset. Check console for results."

func _test_file_operations(args: Array) -> String:
	var test_framework = _new_test_framework()
	if not test_framework:
		return _test_framework_error()
	test_framework.run_file_operation_tests()
	
	register_editor_commands()
	
	return "File operation tests completed! Check console for results."

func _test_pipes(args: Array) -> String:
	var test_framework = _new_test_framework()
	if not test_framework:
		return _test_framework_error()
	test_framework.run_piping_tests()
	
	# Re-register commands after test
	register_editor_commands()
	
	return "Piping tests completed. Check console for results."

func _quick_test(args: Array) -> String:
	var test_framework = _new_test_framework()
	if not test_framework:
		return _test_framework_error()
	test_framework.run_command_registry_tests()
	test_framework.run_builtin_commands_tests()
	return "Quick test completed - Command registry and built-in commands tested"
#endregion

#region Game commands
func _show_fps(args: Array) -> String:
	var fps = Engine.get_frames_per_second()
	return "FPS: %d" % fps

func _count_nodes(args: Array) -> String:
	var count = _count_nodes_recursive(Engine.get_main_loop().current_scene)
	return "Total nodes in scene: %d" % count

func _count_nodes_recursive(node: Node) -> int:
	var count = 1
	for child in node.get_children():
		count += _count_nodes_recursive(child)
	return count

func _toggle_pause(args: Array) -> String:
	var tree = Engine.get_main_loop()
	tree.paused = not tree.paused
	return "Game %s" % ("paused" if tree.paused else "unpaused")

func _set_time_scale(args: Array) -> String:
	if args.size() == 0:
		return "Current time scale: %.2f" % Engine.time_scale
	
	var scale = args[0].to_float()
	if scale <= 0:
		return "Time scale must be positive"
	
	Engine.time_scale = scale
	return "Time scale set to: %.2f" % scale

# set GameConsole background opacity. Accepts 0-100 (percent) or
# 0.0-1.0 (raw alpha). The actual visual update + clamp-to-floor lives on
# GameConsole.set_opacity(); we just route + persist. When no GameConsole
# is reachable (e.g., called from a test fixture before the manager has
# created one), we still update persisted config so the value applies on
# next console open.
func _cmd_opacity(args: Array) -> String:
	var gc: Node = _get_game_console_instance()
	if args.is_empty():
		if gc and gc.has_method("get_opacity"):
			var current: float = float(gc.call("get_opacity"))
			return "Current opacity: %d%% (%.2f). Usage: opacity <0-100>" % [int(round(current * 100.0)), current]
		return "Usage: opacity <0-100>"
	var raw: String = str(args[0]).strip_edges()
	if not raw.is_valid_float():
		return "Error: opacity expects a number between 0 and 100 (or 0.0 and 1.0), got: %s" % raw
	var raw_f: float = raw.to_float()
	# Accept both "50" and "0.5" - anything > 1.0 is treated as percent.
	var value: float = raw_f
	if value > 1.0:
		value = value / 100.0
	if value < 0.0 or value > 1.0:
		return "Error: opacity must be between 0 and 100 (or 0.0 and 1.0), got: %s" % raw
	var applied: float = value
	if gc and gc.has_method("set_opacity"):
		applied = float(gc.call("set_opacity", value))
	else:
		# Mirror the GameConsole floor so the persisted value matches what
		# the console would actually display next time it opens.
		applied = clamp(value, 0.1, 1.0)
	var values: Dictionary = _load_console_config_values()
	values["opacity"] = applied
	_save_console_config_values(values)
	return "Opacity set to %d%% (%.2f)" % [int(round(applied * 100.0)), applied]

# toggle global print interception. Uses Godot 4.5+ Logger API
# via GameConsoleLogger.gd; falls back to a no-op with an explanatory
# message on older engines (see GameConsole.set_intercept_enabled).
func _cmd_intercept(args: Array) -> String:
	if args.is_empty():
		return "Usage: intercept on|off|status"
	var sub: String = str(args[0]).to_lower()
	var gc: Node = _get_game_console_instance()
	match sub:
		"on":
			if gc and gc.has_method("is_intercept_available") and not gc.call("is_intercept_available"):
				_intercept_active = false
				return "Intercept unavailable: this Godot build does not expose the Logger API (requires 4.5+)"
			_intercept_active = true
			var ok: bool = true
			if gc and gc.has_method("set_intercept_enabled"):
				ok = bool(gc.call("set_intercept_enabled", true))
			if not ok:
				_intercept_active = false
				return "Intercept unavailable: GameConsole could not attach a logger on this engine"
			return "Intercept ON - global print/push_warning/push_error routed to console"
		"off":
			_intercept_active = false
			if gc and gc.has_method("set_intercept_enabled"):
				gc.call("set_intercept_enabled", false)
			return "Intercept OFF"
		"status":
			var avail: String = "available"
			if gc and gc.has_method("is_intercept_available") and not gc.call("is_intercept_available"):
				avail = "unavailable on this Godot version"
			return "Intercept: %s (%s)" % [("ON" if _intercept_active else "OFF"), avail]
		_:
			return "Usage: intercept on|off|status"

func _get_game_console_instance() -> Node:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if not tree:
		return null
	var gcm: Node = tree.root.get_node_or_null("/root/GameConsoleManager")
	if not gcm:
		return null
	# console_instance is a plain field on GameConsoleManager; use get() so
	# this @tool script doesn't take a parse-time dependency on the class.
	var inst: Variant = gcm.get("console_instance")
	if inst is Node and is_instance_valid(inst):
		return inst
	return null

#endregion

#region Scene Tree commands
func _cmd_scene_tree(args: Array) -> String:
	var tree := Engine.get_main_loop() as SceneTree
	if not tree:
		return "Error: Scene tree unavailable"

	var target_node: Node = tree.root
	if not args.is_empty():
		var target_query := str(args[0])
		target_node = tree.root.get_node_or_null(NodePath(target_query))
		if not target_node and not target_query.begins_with("/"):
			target_node = tree.root.find_child(target_query, true, false)
		if not target_node:
			return "Error: Node not found: %s" % target_query

	var tree_lines: Array[String] = []
	_build_tree_lines(target_node, "", true, tree_lines, true)
	return "\n".join(tree_lines)

func _build_tree_lines(node: Node, prefix: String, is_last: bool, output: Array[String], is_root: bool = false) -> void:
	var node_name = node.name if node.name else "<unnamed>"
	var classname = node.get_class()
	var branch := ""
	if not is_root:
		branch = "└─ " if is_last else "├─ "
	var line = "%s%s[%s] %s" % [prefix, branch, classname, node_name]
	output.append(line)

	var next_prefix := prefix
	if not is_root:
		next_prefix += "   " if is_last else "│  "

	var children = node.get_children()
	for i in range(children.size()):
		var child = children[i]
		var is_last_child = (i == children.size() - 1)
		_build_tree_lines(child, next_prefix, is_last_child, output)

#endregion

#region New commands

# tree [depth] - visualize the filesystem under current_directory using the
func _cmd_tree(args: Array) -> String:
	var depth: int = 3
	if args.size() > 0:
		var raw: String = str(args[0]).strip_edges()
		if not raw.is_valid_int():
			return "Usage: tree [depth]"
		depth = clamp(int(raw), 1, 10)

	var root_path: String = current_directory
	var dir := DirAccess.open(root_path)
	if not dir:
		return "Error: Cannot access directory: %s" % root_path

	var lines: Array[String] = [root_path]
	_build_fs_tree_lines(root_path, "", lines, depth, 1)
	return "\n".join(lines)

func _build_fs_tree_lines(path: String, prefix: String, output: Array[String], max_depth: int, current_depth: int) -> void:
	if current_depth > max_depth:
		return
	var dir := DirAccess.open(path)
	if not dir:
		return

	var entries: Array = []
	dir.list_dir_begin()
	var entry_name := dir.get_next()
	while entry_name != "":
		if not entry_name.begins_with("."):
			entries.append({"name": entry_name, "is_dir": dir.current_is_dir()})
		entry_name = dir.get_next()
	dir.list_dir_end()
	entries.sort_custom(func(a, b): return str(a["name"]) < str(b["name"]))

	for i in range(entries.size()):
		var item: Dictionary = entries[i]
		var is_last: bool = (i == entries.size() - 1)
		var branch: String = "└─ " if is_last else "├─ "
		var item_name: String = str(item["name"])
		output.append("%s%s%s" % [prefix, branch, item_name])
		if bool(item["is_dir"]):
			var next_prefix: String = prefix + ("   " if is_last else "│  ")
			_build_fs_tree_lines(path.path_join(item_name), next_prefix, output, max_depth, current_depth + 1)

# wc <file> - bash-style line/word/char count. Counts piped input when
func _cmd_wc(args: Array, input: String = "", is_pipe_context: bool = false) -> String:
	var content: String = ""
	var label: String = ""

	if is_pipe_context and not input.is_empty():
		content = input
	elif args.size() > 0:
		var file_name: String = str(args[0])
		var full_path: String = file_name
		if not (file_name.begins_with("res://") or file_name.begins_with("user://")):
			full_path = current_directory.path_join(file_name)
		if not FileAccess.file_exists(full_path):
			return "Error: File not found - %s" % full_path
		var f := FileAccess.open(full_path, FileAccess.READ)
		if not f:
			return "Error: Cannot read file - %s" % file_name
		content = f.get_as_text()
		f.close()
		label = file_name
	else:
		return "Usage: wc <file>"

	var line_count: int = content.split("\n").size()
	var normalized: String = content.replace("\t", " ").replace("\n", " ").replace("\r", " ")
	var tokens: PackedStringArray = normalized.split(" ", false)
	var word_count: int = tokens.size()
	var char_count: int = content.length()

	if label.is_empty():
		return "%5d %5d %5d" % [line_count, word_count, char_count]
	return "%5d %5d %5d %s" % [line_count, word_count, char_count, label]

# signals <node_path> - list signal definitions on a live target with current
func _cmd_signals(args: Array) -> String:
	_ensure_dependencies()
	if not _core:
		return "Error: DebugCore is unavailable"
	if args.is_empty():
		return "Usage: signals <node_path|autoload_name|Engine>"

	var path: String = " ".join(args).strip_edges()
	var target: Object = _core._resolve_inspect_target(path)
	if not is_instance_valid(target):
		return "Error: Target not found: %s" % path

	var display_path: String = path
	if target is Node:
		var node_target: Node = target
		display_path = str(node_target.get_path()) if node_target.is_inside_tree() else node_target.name

	var class_str: String = target.get_class()
	var signal_list: Array = target.get_signal_list()
	var suffix: String = "" if signal_list.size() == 1 else "s"

	var lines: Array[String] = []
	lines.append("%s [%s] - %d signal%s" % [display_path, class_str, signal_list.size(), suffix])
	for sig in signal_list:
		var sig_name: String = str(sig.get("name", ""))
		var arg_list: Array = sig.get("args", [])
		var arg_strs: Array[String] = []
		for a in arg_list:
			var aname: String = str(a.get("name", ""))
			var atype: int = int(a.get("type", TYPE_NIL))
			arg_strs.append("%s: %s" % [aname, _inspect_type_name(atype)])
		var connections: int = 0
		if target.has_signal(sig_name):
			connections = target.get_signal_connection_list(sig_name).size()
		lines.append("  %s(%s) - %d connection(s)" % [sig_name, ", ".join(arg_strs), connections])
	return "\n".join(lines)

# properties <node_path> - filtered view of `inspect`: names + types only,
func _cmd_properties(args: Array) -> String:
	_ensure_dependencies()
	if not _core:
		return "Error: DebugCore is unavailable"
	if args.is_empty():
		return "Usage: properties <node_path|autoload_name|Engine>"

	var path: String = " ".join(args).strip_edges()
	var target: Object = _core._resolve_inspect_target(path)
	if not is_instance_valid(target):
		return "Error: Target not found: %s" % path

	var display_path: String = path
	if target is Node:
		var node_target: Node = target
		display_path = str(node_target.get_path()) if node_target.is_inside_tree() else node_target.name

	var class_str: String = target.get_class()
	var collected: Array[Dictionary] = []
	for p in target.get_property_list():
		var usage: int = int(p.get("usage", 0))
		if usage & PROPERTY_USAGE_INTERNAL:
			continue
		if usage & (PROPERTY_USAGE_GROUP | PROPERTY_USAGE_SUBGROUP | PROPERTY_USAGE_CATEGORY):
			continue
		var pname: String = str(p.get("name", ""))
		if pname.is_empty():
			continue
		collected.append({"name": pname, "type": int(p.get("type", TYPE_NIL))})

	var lines: Array[String] = []
	lines.append("%s [%s] - %d property/properties" % [display_path, class_str, collected.size()])
	for prop in collected:
		lines.append("  [%-8s] %s" % [_inspect_type_name(int(prop["type"])), str(prop["name"])])
	return "\n".join(lines)

# reload_scripts - walk res:// and force-reload every .gd file via
# ResourceLoader with CACHE_MODE_REPLACE. Skips third-party addon trees
# (godot_mcp, godotiq) and the engine cache (.godot) for safety.
func _cmd_reload_scripts(args: Array) -> String:
	if not Engine.is_editor_hint():
		return "Not in editor"
	var reloaded_counter: Array[int] = [0]
	var failures: Array[String] = []
	_collect_and_reload_scripts("res://", reloaded_counter, failures)
	var msg: String = "Reloaded %d script(s). %d failure(s)." % [reloaded_counter[0], failures.size()]
	if failures.size() > 0:
		msg += "\nFailures:"
		for f in failures:
			msg += "\n  %s" % f
	return msg

func _collect_and_reload_scripts(path: String, reloaded_counter: Array[int], failures: Array[String]) -> void:
	if path.contains("/addons/godot_mcp") or path.contains("/addons/godotiq") or path.contains("/.godot"):
		return
	var dir := DirAccess.open(path)
	if not dir:
		return
	dir.list_dir_begin()
	var entry_name := dir.get_next()
	while entry_name != "":
		if not entry_name.begins_with("."):
			var full_path: String = path.path_join(entry_name)
			if dir.current_is_dir():
				_collect_and_reload_scripts(full_path, reloaded_counter, failures)
			elif entry_name.ends_with(".gd"):
				var loaded: Resource = ResourceLoader.load(full_path, "Script", ResourceLoader.CACHE_MODE_REPLACE)
				if loaded == null:
					failures.append(full_path)
				else:
					reloaded_counter[0] = reloaded_counter[0] + 1
		entry_name = dir.get_next()
	dir.list_dir_end()

# diff <file_a> <file_b> - naive line-level diff (no Myers/LCS), with BBCode
func _cmd_diff(args: Array) -> String:
	if args.size() < 2:
		return "Usage: diff <file_a> <file_b>"

	var path_a: String = _resolve_diff_path(str(args[0]))
	var path_b: String = _resolve_diff_path(str(args[1]))
	if not FileAccess.file_exists(path_a):
		return "Error: File not found: %s" % path_a
	if not FileAccess.file_exists(path_b):
		return "Error: File not found: %s" % path_b

	var fa := FileAccess.open(path_a, FileAccess.READ)
	if not fa:
		return "Error: Cannot read file: %s" % path_a
	var content_a: String = fa.get_as_text()
	fa.close()
	var fb := FileAccess.open(path_b, FileAccess.READ)
	if not fb:
		return "Error: Cannot read file: %s" % path_b
	var content_b: String = fb.get_as_text()
	fb.close()

	var lines_a: PackedStringArray = content_a.split("\n")
	var lines_b: PackedStringArray = content_b.split("\n")
	var max_len: int = max(lines_a.size(), lines_b.size())

	var out: Array[String] = []
	for i in range(max_len):
		var has_a: bool = i < lines_a.size()
		var has_b: bool = i < lines_b.size()
		if has_a and has_b:
			var la: String = lines_a[i]
			var lb: String = lines_b[i]
			if la == lb:
				out.append("  " + la)
			else:
				out.append("[color=#FF4444]- %s[/color]" % la)
				out.append("[color=#44FF44]+ %s[/color]" % lb)
		elif has_a:
			out.append("[color=#FF4444]- %s[/color]" % lines_a[i])
		else:
			out.append("[color=#44FF44]+ %s[/color]" % lines_b[i])
	return "\n".join(out)

func _resolve_diff_path(p: String) -> String:
	var s: String = p.strip_edges()
	if s.begins_with("res://") or s.begins_with("user://") or s.begins_with("/"):
		return s
	return current_directory.path_join(s)

#endregion

#region Output renderer helpers

const _DC_COLOR_PATH := "#5FBEE0"
const _DC_COLOR_NUMBER := "#F7DC6F"
const _DC_COLOR_ERROR_TOKEN := "#FF4444"
const _DC_COLOR_WARNING_TOKEN := "#FFAA00"
const _DC_COLOR_STRING := "#A0E0A0"
const _DC_COLOR_BOOLEAN := "#D670D6"
const _DC_COLOR_NULL := "#606060"
const _DC_COLOR_BRACKET := "#FFD700"
const _DC_COLOR_KEYWORD := "#FF6B9D"

const _DC_KEYWORDS: Array = [
	"func", "var", "const", "signal", "class_name", "extends", "enum",
	"return", "if", "else", "for", "while", "match",
	"pass", "break", "continue", "self", "super",
]

# Pretty-print arbitrary JSON. Reads input from `input` when piped, otherwise
# joins the positional args with spaces so `json {"a":1,"b":2}` works after
# the shell tokenizer splits on whitespace inside the braces.
func _cmd_json(args: Array, input: String = "", is_pipe_context: bool = false) -> String:
	var raw: String = ""
	if is_pipe_context and not input.is_empty():
		raw = input
	elif args.size() > 0:
		var parts: Array = []
		for a in args:
			parts.append(str(a))
		raw = " ".join(parts)
	raw = raw.strip_edges()
	if raw.is_empty():
		return "Usage: json <text> (or pipe input)"
	# Use the JSON instance API instead of `JSON.parse_string` so we can
	# distinguish "input is the literal `null`" (valid) from "parse failed"
	# (returns null too). parse_string can't tell those apart.
	var parser: JSON = JSON.new()
	var err: int = parser.parse(raw)
	if err != OK:
		return "Error: invalid JSON"
	return JSON.stringify(parser.data, "  ")

# Public test entry point. Self-contained - does not depend on _registry,
# _core, or any node tree. Safe to call from `BuiltInCommands.new()`.
func _colorize_message(message: String) -> String:
	# Pre-colored caller - early-return so we never layer a second category
	# color on top of the caller's choice. This also prevents accidentally
	# matching hex digits inside an existing [color=#...] tag as numbers.
	if message.contains("[color="):
		return message
	if message.is_empty():
		return message

	var edits: Array = []
	var skip_ranges: Array = []

	var prefix_edit: Array = _dc_detect_error_warning_prefix(message)
	if prefix_edit.size() == 3:
		edits.append(prefix_edit)
		skip_ranges.append([int(prefix_edit[0]), int(prefix_edit[1])])

	_dc_detect_paths(message, edits, skip_ranges)
	_dc_detect_strings(message, edits, skip_ranges)
	_dc_detect_brackets(message, edits, skip_ranges)
	_dc_detect_numbers(message, edits, skip_ranges)
	_dc_detect_word_tokens(message, ["true", "false"], _DC_COLOR_BOOLEAN, edits, skip_ranges, true)
	_dc_detect_word_tokens(message, ["null"], _DC_COLOR_NULL, edits, skip_ranges, true)
	_dc_detect_word_tokens(message, _DC_KEYWORDS, _DC_COLOR_KEYWORD, edits, skip_ranges, true)

	edits.sort_custom(func(a, b): return int(a[0]) > int(b[0]))
	var result: String = message
	for e in edits:
		var start: int = int(e[0])
		var end_pos: int = int(e[1])
		var repl: String = str(e[2])
		result = result.substr(0, start) + repl + result.substr(end_pos)
	return result

func _dc_detect_error_warning_prefix(message: String) -> Array:
	var candidates: Array = [
		{"token": "Error", "color": _DC_COLOR_ERROR_TOKEN},
		{"token": "ERROR", "color": _DC_COLOR_ERROR_TOKEN},
		{"token": "Warning", "color": _DC_COLOR_WARNING_TOKEN},
		{"token": "WARNING", "color": _DC_COLOR_WARNING_TOKEN},
	]
	for c in candidates:
		var token: String = str(c["token"])
		if not message.begins_with(token):
			continue
		var after: int = token.length()
		if after < message.length() and _dc_is_word_char(message[after]):
			continue
		return [0, after, "[color=%s]%s[/color]" % [str(c["color"]), token]]
	return []

func _dc_detect_paths(message: String, edits: Array, skip_ranges: Array) -> void:
	var prefixes: Array = ["res://", "user://"]
	var i: int = 0
	var n: int = message.length()
	while i < n:
		var matched_prefix: String = ""
		for p in prefixes:
			if message.substr(i, p.length()) == p:
				matched_prefix = p
				break
		if matched_prefix.is_empty():
			i += 1
			continue
		var end_pos: int = i + matched_prefix.length()
		while end_pos < n and _dc_is_path_char(message[end_pos]):
			end_pos += 1
		# Bail if we didn't capture at least one trailing char - bare `res://`
		# is technically syntax but not a useful link.
		if end_pos == i + matched_prefix.length():
			i = end_pos
			continue
		var path: String = message.substr(i, end_pos - i)
		edits.append([i, end_pos, "[color=%s]%s[/color]" % [_DC_COLOR_PATH, path]])
		skip_ranges.append([i, end_pos])
		i = end_pos

# Walks the message and wraps the next matching `"..."` or `'...'` pair in
func _dc_detect_strings(message: String, edits: Array, skip_ranges: Array) -> void:
	var n: int = message.length()
	var i: int = 0
	while i < n:
		if _dc_is_in_skip_range(i, skip_ranges):
			i += 1
			continue
		var c: String = message[i]
		if c != "\"" and c != "'":
			i += 1
			continue
		var close: int = i + 1
		while close < n and message[close] != c:
			close += 1
		# Unmatched opening quote - bail and keep scanning.
		if close >= n:
			i += 1
			continue
		var span_end: int = close + 1
		var token: String = message.substr(i, span_end - i)
		edits.append([i, span_end, "[color=%s]%s[/color]" % [_DC_COLOR_STRING, token]])
		skip_ranges.append([i, span_end])
		i = span_end

# Single-char detector for grouping symbols. Brackets get their own yellow
func _dc_detect_brackets(message: String, edits: Array, skip_ranges: Array) -> void:
	var n: int = message.length()
	for i in n:
		if _dc_is_in_skip_range(i, skip_ranges):
			continue
		var c: String = message[i]
		if c == "{" or c == "}" or c == "[" or c == "]" or c == "(" or c == ")":
			edits.append([i, i + 1, "[color=%s]%s[/color]" % [_DC_COLOR_BRACKET, c]])

func _dc_detect_numbers(message: String, edits: Array, skip_ranges: Array) -> void:
	var units: Array = ["ms", "s", "KB", "MB", "GB", "%"]
	var n: int = message.length()
	var i: int = 0
	while i < n:
		if not _dc_is_digit(message[i]):
			i += 1
			continue
		if _dc_is_in_skip_range(i, skip_ranges):
			i += 1
			continue
		if i > 0 and _dc_is_word_char(message[i - 1]):
			i += 1
			continue
		var start: int = i
		while i < n and _dc_is_digit(message[i]):
			i += 1
		if i < n - 1 and message[i] == "." and _dc_is_digit(message[i + 1]):
			i += 1
			while i < n and _dc_is_digit(message[i]):
				i += 1
		var unit_end: int = i
		var best_unit_len: int = 0
		for u in units:
			var ulen: int = str(u).length()
			if message.substr(i, ulen) == str(u) and ulen > best_unit_len:
				best_unit_len = ulen
		if best_unit_len > 0:
			unit_end = i + best_unit_len
		if unit_end < n and _dc_is_word_char(message[unit_end]):
			# Trailing word char like `42abc` - reject the whole token to
			# avoid visually splitting an identifier.
			i = unit_end
			while i < n and _dc_is_word_char(message[i]):
				i += 1
			continue
		i = unit_end
		var token: String = message.substr(start, i - start)
		edits.append([start, i, "[color=%s]%s[/color]" % [_DC_COLOR_NUMBER, token]])

# Word-bounded multi-token detector. Used by booleans, null, and keywords.
func _dc_detect_word_tokens(message: String, tokens: Array, color: String, edits: Array, skip_ranges: Array, claim_skip: bool) -> void:
	var n: int = message.length()
	var i: int = 0
	while i < n:
		if _dc_is_in_skip_range(i, skip_ranges):
			i += 1
			continue
		if i > 0 and _dc_is_word_char(message[i - 1]):
			i += 1
			continue
		var matched_len: int = 0
		var matched_token: String = ""
		for t in tokens:
			var ts: String = str(t)
			var tlen: int = ts.length()
			if tlen <= matched_len:
				continue
			if i + tlen > n:
				continue
			if message.substr(i, tlen) != ts:
				continue
			if i + tlen < n and _dc_is_word_char(message[i + tlen]):
				continue
			matched_len = tlen
			matched_token = ts
		if matched_len == 0:
			i += 1
			continue
		var end_pos: int = i + matched_len
		edits.append([i, end_pos, "[color=%s]%s[/color]" % [color, matched_token]])
		if claim_skip:
			skip_ranges.append([i, end_pos])
		i = end_pos

func _dc_is_path_char(c: String) -> bool:
	if c.length() != 1:
		return false
	if _dc_is_word_char(c):
		return true
	return c == "-" or c == "." or c == "/"

func _dc_is_word_char(c: String) -> bool:
	if c.length() != 1:
		return false
	if _dc_is_digit(c):
		return true
	if c == "_":
		return true
	var ch: int = c.unicode_at(0)
	return (ch >= 65 and ch <= 90) or (ch >= 97 and ch <= 122)

func _dc_is_digit(c: String) -> bool:
	if c.length() != 1:
		return false
	var ch: int = c.unicode_at(0)
	return ch >= 48 and ch <= 57

func _dc_is_in_skip_range(idx: int, ranges: Array) -> bool:
	for r in ranges:
		if idx >= int(r[0]) and idx < int(r[1]):
			return true
	return false

# Human-readable millisecond duration. Helper for benchmark/timer output;
func _format_duration_ms(ms: int) -> String:
	if ms < 0:
		ms = 0
	if ms < 1000:
		return "%dms" % ms
	if ms < 60000:
		return "%.1fs" % (ms / 1000.0)
	var total_seconds: int = ms / 1000
	var minutes: int = total_seconds / 60
	var seconds: int = total_seconds % 60
	return "%dm%ds" % [minutes, seconds]
#endregion

#region New commands

# REPL using the sandboxed Expression class. Cannot define functions or
# assign variables, but supports literals, operators, constructors, autoload
# refs, and (at runtime) `get_node("/root/...")` via the SceneTree root as
# base instance.
func _cmd_eval(args: Array) -> String:
	if args.is_empty():
		return "Usage: eval <gdscript expression>"
	var code: String = " ".join(args).strip_edges()
	if code.is_empty():
		return "Usage: eval <gdscript expression>"
	var expr := Expression.new()
	var err: int = expr.parse(code)
	if err != OK:
		return "Error: parse failed - " + expr.get_error_text()
	var base_instance: Object = null
	if not Engine.is_editor_hint():
		var tree := Engine.get_main_loop() as SceneTree
		if tree:
			base_instance = tree.root
	var result: Variant = expr.execute([], base_instance, false)
	if expr.has_execute_failed():
		return "Error: execute failed - " + expr.get_error_text()
	if result == null:
		return "null"
	return str(result)

# Performance.Monitor dashboard. Groups monitors into categories with
# BBCode-colored headers. Optional first arg filters by case-insensitive
# substring match against the display name.
func _cmd_perf(args: Array) -> String:
	var groups: Array = _dc_perf_monitor_groups()
	var filter: String = ""
	if args.size() > 0:
		filter = str(args[0]).strip_edges().to_lower()

	var lines: Array[String] = []
	var matched_any: bool = false
	for group in groups:
		var category: String = group[0]
		var monitors: Array = group[1]
		var category_lines: Array[String] = []
		for mon in monitors:
			var enum_val: int = int(mon[0])
			var display_name: String = String(mon[1])
			var unit: String = String(mon[2])
			var multiplier: float = float(mon[3]) if mon.size() > 3 else 1.0
			if not filter.is_empty() and not display_name.to_lower().contains(filter):
				continue
			var raw_value: float = 0.0
			# Performance.get_monitor() returns 0.0 for unsupported monitors
			# in headless or older builds; we still display them rather than
			# hide because zero is itself informative for most monitors.
			raw_value = Performance.get_monitor(enum_val)
			var formatted: String = _dc_format_perf_value(raw_value * multiplier, unit)
			category_lines.append("  %-42s = [color=#F7DC6F]%s[/color]" % [display_name, formatted])
			matched_any = true
		if not category_lines.is_empty():
			lines.append("[color=#5FBEE0]== %s ==[/color]" % category)
			lines.append_array(category_lines)
	if not matched_any:
		return "No performance monitors matched filter: %s" % filter
	return "\n".join(lines)

func _dc_perf_monitor_groups() -> Array:
	# Each row: [enum_value, display_name, unit_suffix, optional_multiplier]
	# Time monitors are seconds internally; multiplier 1000.0 converts to ms.
	return [
		["Time", [
			[Performance.TIME_FPS, "FPS", ""],
			[Performance.TIME_PROCESS, "Process Time", "ms", 1000.0],
			[Performance.TIME_PHYSICS_PROCESS, "Physics Process Time", "ms", 1000.0],
			[Performance.TIME_NAVIGATION_PROCESS, "Navigation Process Time", "ms", 1000.0],
		]],
		["Memory", [
			[Performance.MEMORY_STATIC, "Static Memory", "B"],
			[Performance.MEMORY_STATIC_MAX, "Static Memory Peak", "B"],
			[Performance.MEMORY_MESSAGE_BUFFER_MAX, "Message Buffer Peak", "B"],
		]],
		["Object", [
			[Performance.OBJECT_COUNT, "Object Count", ""],
			[Performance.OBJECT_RESOURCE_COUNT, "Resource Count", ""],
			[Performance.OBJECT_NODE_COUNT, "Node Count", ""],
			[Performance.OBJECT_ORPHAN_NODE_COUNT, "Orphan Node Count", ""],
		]],
		["Render", [
			[Performance.RENDER_TOTAL_OBJECTS_IN_FRAME, "Objects in Frame", ""],
			[Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME, "Primitives in Frame", ""],
			[Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME, "Draw Calls in Frame", ""],
			[Performance.RENDER_VIDEO_MEM_USED, "Video Memory", "B"],
			[Performance.RENDER_TEXTURE_MEM_USED, "Texture Memory", "B"],
			[Performance.RENDER_BUFFER_MEM_USED, "Buffer Memory", "B"],
		]],
		["Physics", [
			[Performance.PHYSICS_2D_ACTIVE_OBJECTS, "2D Active Objects", ""],
			[Performance.PHYSICS_2D_COLLISION_PAIRS, "2D Collision Pairs", ""],
			[Performance.PHYSICS_2D_ISLAND_COUNT, "2D Islands", ""],
			[Performance.PHYSICS_3D_ACTIVE_OBJECTS, "3D Active Objects", ""],
			[Performance.PHYSICS_3D_COLLISION_PAIRS, "3D Collision Pairs", ""],
			[Performance.PHYSICS_3D_ISLAND_COUNT, "3D Islands", ""],
		]],
		["Audio", [
			[Performance.AUDIO_OUTPUT_LATENCY, "Audio Output Latency", "s"],
		]],
		["Navigation", [
			[Performance.NAVIGATION_ACTIVE_MAPS, "Navigation Active Maps", ""],
			[Performance.NAVIGATION_REGION_COUNT, "Navigation Regions", ""],
			[Performance.NAVIGATION_AGENT_COUNT, "Navigation Agents", ""],
			[Performance.NAVIGATION_LINK_COUNT, "Navigation Links", ""],
			[Performance.NAVIGATION_POLYGON_COUNT, "Navigation Polygons", ""],
			[Performance.NAVIGATION_EDGE_COUNT, "Navigation Edges", ""],
			[Performance.NAVIGATION_EDGE_MERGE_COUNT, "Navigation Merged Edges", ""],
			[Performance.NAVIGATION_EDGE_CONNECTION_COUNT, "Navigation Connections", ""],
			[Performance.NAVIGATION_EDGE_FREE_COUNT, "Navigation Free Edges", ""],
		]],
		["Pipeline", [
			[Performance.PIPELINE_COMPILATIONS_CANVAS, "Canvas Pipeline Compilations", ""],
			[Performance.PIPELINE_COMPILATIONS_MESH, "Mesh Pipeline Compilations", ""],
			[Performance.PIPELINE_COMPILATIONS_SURFACE, "Surface Pipeline Compilations", ""],
			[Performance.PIPELINE_COMPILATIONS_DRAW, "Draw Pipeline Compilations", ""],
			[Performance.PIPELINE_COMPILATIONS_SPECIALIZATION, "Specialization Pipeline Compilations", ""],
		]],
	]

func _dc_format_perf_value(value: float, unit: String) -> String:
	if unit == "B":
		return _dc_format_bytes(value)
	if unit == "ms":
		return "%.2f ms" % value
	if unit == "s":
		return "%.4f s" % value
	# Integer-friendly display for counts/FPS where fractional parts are noise.
	if absf(value - round(value)) < 0.0001:
		return "%d" % int(round(value))
	return "%.2f" % value

func _dc_format_bytes(bytes: float) -> String:
	var b: float = bytes
	if b < 1024.0:
		return "%d B" % int(b)
	if b < 1024.0 * 1024.0:
		return "%.1f KiB" % (b / 1024.0)
	if b < 1024.0 * 1024.0 * 1024.0:
		return "%.2f MiB" % (b / (1024.0 * 1024.0))
	return "%.2f GiB" % (b / (1024.0 * 1024.0 * 1024.0))

# Toggle CollisionShape debug rendering. Editor-mode is rejected because
# enabling it on the editor's SceneTree would affect the editor viewport, not
# the running game. Nodes redraw their debug shapes on the next physics step.
func _cmd_show_colliders(args: Array) -> String:
	return _dc_toggle_scene_tree_flag(args, "debug_collisions_hint", "Collision shape rendering", "show_colliders")

func _cmd_show_nav(args: Array) -> String:
	return _dc_toggle_scene_tree_flag(args, "debug_navigation_hint", "Navigation polygon rendering", "show_nav")

func _cmd_show_paths(args: Array) -> String:
	return _dc_toggle_scene_tree_flag(args, "debug_paths_hint", "Path rendering", "show_paths")

func _dc_toggle_scene_tree_flag(args: Array, flag_name: String, label: String, cmd_name: String) -> String:
	if Engine.is_editor_hint():
		return "Error: %s only works in runtime" % cmd_name
	var tree := Engine.get_main_loop() as SceneTree
	if not tree:
		return "Error: %s requires an active SceneTree" % cmd_name
	var current: bool = bool(tree.get(flag_name))
	var target: bool = not current
	if args.size() > 0:
		var sub: String = str(args[0]).strip_edges().to_lower()
		match sub:
			"on", "true", "1", "yes":
				target = true
			"off", "false", "0", "no":
				target = false
			_:
				return "Usage: %s [on|off]" % cmd_name
	tree.set(flag_name, target)
	return "%s: %s" % [label, ("ON" if target else "OFF")]

# Colored timestamped sync marker. Useful for matching console output
# against external recordings, log dumps, or screen captures.
func _cmd_mark(args: Array) -> String:
	var label: String = " ".join(args).strip_edges()
	if label.is_empty():
		label = "MARK"
	var ts: String = Time.get_time_string_from_system()
	return "[color=#FFD700]===== %s ===== %s ===== %s =====[/color]" % [ts, label, ts]

# Slow-motion shortcut. `slowmo` defaults to 0.25; `slowmo off` resets to
# 1.0. Negative or zero values are rejected (use `freeze` for 0.0).
func _cmd_slowmo(args: Array) -> String:
	if Engine.is_editor_hint():
		return "Error: slowmo only works in runtime"
	if args.size() > 0:
		var sub: String = str(args[0]).strip_edges().to_lower()
		if sub == "off" or sub == "reset":
			Engine.time_scale = 1.0
			return "Time scale: 1.0 (normal speed)"
		if not sub.is_valid_float():
			return "Error: slowmo expects a positive number or 'off', got: %s" % sub
		var factor: float = sub.to_float()
		if factor <= 0.0:
			return "Error: slowmo factor must be > 0 (use 'freeze' for 0)"
		Engine.time_scale = factor
		return "Time scale: %.3f (slow motion)" % factor
	Engine.time_scale = 0.25
	return "Time scale: 0.25 (slow motion)"

# Freeze time without using the pause flag. Useful for inspecting a live
# scene without disabling _process callbacks that depend on time_scale.
func _cmd_freeze(args: Array) -> String:
	if Engine.is_editor_hint():
		return "Error: freeze only works in runtime"
	Engine.time_scale = 0.0
	return "Time scale: 0.0 (frozen). Use 'timescale 1.0' or 'slowmo off' to resume."

# Get/set the physics tick rate. Valid range 1-1000 matches Godot's own
# project setting bounds. Reading is allowed in editor mode; writing is too,
# since Engine.physics_ticks_per_second has no SceneTree dependency.
func _cmd_physics_tps(args: Array) -> String:
	if args.is_empty():
		return "Physics TPS: %d" % Engine.physics_ticks_per_second
	var raw: String = str(args[0]).strip_edges()
	if not raw.is_valid_int():
		return "Error: physics_tps takes an integer"
	var n: int = raw.to_int()
	if n < 1 or n > 1000:
		return "Error: physics_tps must be between 1 and 1000, got: %d" % n
	Engine.physics_ticks_per_second = n
	return "Physics TPS: %d" % Engine.physics_ticks_per_second

# Fire assert(false) to validate crash reporting. In debug builds the
# assert halts execution; in release builds assert is a no-op and only the
# returned string is observable.
func _cmd_crashtest(args: Array) -> String:
	var msg: String = "Crashtest fired. If you see this in the console but no crash, asserts are disabled in release mode."
	assert(false, "crashtest fired via debug console")
	return msg

# Live font-size tuning for the console output panels. Walks both the editor
func _cmd_font_size(args: Array) -> String:
	if args.is_empty():
		var current_editor: int = _get_console_font_size("EditorConsole")
		var current_game: int = _get_console_font_size("GameConsole")
		var lines: Array[String] = []
		if current_editor > 0:
			lines.append("Editor console: %d px" % current_editor)
		if current_game > 0:
			lines.append("Game console: %d px" % current_game)
		if lines.is_empty():
			return "No console found to query."
		return "\n".join(lines)
	var raw: String = str(args[0]).strip_edges()
	if not raw.is_valid_int():
		return "Error: font_size takes an integer 8-32"
	var n: int = raw.to_int()
	if n < 8 or n > 32:
		return "Error: font_size must be between 8 and 32 (got %d)" % n
	var applied: Array[String] = []
	if _apply_console_font_size("EditorConsole", n):
		applied.append("editor")
	if _apply_console_font_size("GameConsole", n):
		applied.append("game")
	if applied.is_empty():
		return "Error: no console found to apply font_size to"
	return "[color=#A0E0A0]Font size set to %d px (%s)[/color]" % [n, ", ".join(applied)]

func _get_console_font_size(group_name: String) -> int:
	var tree := Engine.get_main_loop() as SceneTree
	if not tree:
		return 0
	var nodes: Array[Node] = tree.get_nodes_in_group(group_name)
	for n in nodes:
		var out: Node = n.get_node_or_null("VBox/OutputText")
		if not out:
			out = n.get_node_or_null("VBox/OutputPanel/OutputText")
		if out and out.has_theme_font_size_override("normal_font_size"):
			return out.get_theme_font_size("normal_font_size")
	return 0

func _apply_console_font_size(group_name: String, n: int) -> bool:
	var tree := Engine.get_main_loop() as SceneTree
	if not tree:
		return false
	var any_applied: bool = false
	# Per-spacing scale: line_separation roughly 2/3 of font_size keeps the
	# bash-terminal feel across sizes without overspacing at high values.
	var line_sep: int = max(4, int(round(float(n) * 0.66)))
	var nodes: Array[Node] = tree.get_nodes_in_group(group_name)
	for node_ref in nodes:
		var out: Node = node_ref.get_node_or_null("VBox/OutputText")
		if not out:
			out = node_ref.get_node_or_null("VBox/OutputPanel/OutputText")
		if out:
			out.add_theme_font_size_override("normal_font_size", n)
			out.add_theme_constant_override("line_separation", line_sep)
			any_applied = true
		var input_node: Node = node_ref.get_node_or_null("VBox/InputContainer/InputLine")
		if not input_node:
			input_node = node_ref.get_node_or_null("VBox/InputLine")
		if input_node and input_node is Control:
			input_node.add_theme_font_size_override("font_size", n)
	return any_applied

# Live line-spacing tuning. The font_size command bumps line_separation as a
# side effect, but the user may want to tune it independently (for example
# to add extra breathing room with a small font, or tighten high-DPI text).
func _cmd_line_spacing(args: Array) -> String:
	if args.is_empty():
		var current_editor: int = _get_console_line_separation("EditorConsole")
		var current_game: int = _get_console_line_separation("GameConsole")
		var lines: Array[String] = []
		if current_editor >= 0:
			lines.append("Editor console: %d px" % current_editor)
		if current_game >= 0:
			lines.append("Game console: %d px" % current_game)
		if lines.is_empty():
			return "No console found to query."
		return "\n".join(lines)
	var raw: String = str(args[0]).strip_edges()
	if not raw.is_valid_int():
		return "Error: line_spacing takes an integer 0-40"
	var n: int = raw.to_int()
	if n < 0 or n > 40:
		return "Error: line_spacing must be between 0 and 40 (got %d)" % n
	var applied: Array[String] = []
	if _apply_console_line_separation("EditorConsole", n):
		applied.append("editor")
	if _apply_console_line_separation("GameConsole", n):
		applied.append("game")
	if applied.is_empty():
		return "Error: no console found to apply line_spacing to"
	return "[color=#A0E0A0]Line spacing set to %d px (%s)[/color]" % [n, ", ".join(applied)]

func _get_console_line_separation(group_name: String) -> int:
	var tree := Engine.get_main_loop() as SceneTree
	if not tree:
		return -1
	var nodes: Array[Node] = tree.get_nodes_in_group(group_name)
	for n in nodes:
		var out: Node = n.get_node_or_null("VBox/OutputText")
		if not out:
			out = n.get_node_or_null("VBox/OutputPanel/OutputText")
		if out and out.has_theme_constant_override("line_separation"):
			return out.get_theme_constant("line_separation")
	return -1

func _apply_console_line_separation(group_name: String, n: int) -> bool:
	var tree := Engine.get_main_loop() as SceneTree
	if not tree:
		return false
	var any_applied: bool = false
	var nodes: Array[Node] = tree.get_nodes_in_group(group_name)
	for node_ref in nodes:
		var out: Node = node_ref.get_node_or_null("VBox/OutputText")
		if not out:
			out = node_ref.get_node_or_null("VBox/OutputPanel/OutputText")
		if out:
			out.add_theme_constant_override("line_separation", n)
			any_applied = true
	return any_applied

#endregion

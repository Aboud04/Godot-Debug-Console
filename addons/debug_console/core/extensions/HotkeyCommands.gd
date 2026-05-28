@tool
class_name DebugConsoleHotkeyCommands extends RefCounted

# Tier 6 extension - keyboard hotkeys for the debug console. Binds key specs
# like "F1", "Ctrl+S", or "Ctrl+Shift+P" to arbitrary console command lines
# and fires them through the registry. Inspired by Panku's KeyboardShortcuts.
#
# All commands are registered under the "game" context. The editor dock's
# Ctrl+key handlers already own the editor-side input space; intercepting
# _unhandled_input there would steal shortcuts from the editor at large.
# At runtime we install a Node child on _core that hooks _unhandled_input
# and dispatches matching events back through _registry.execute_command.
#
# Bindings persist to user://hotkeys.json. Every bind/unbind triggers an
# implicit save; hotkey_save / hotkey_load expose the same operations
# explicitly for scripts and tests.

const _COLOR_ERROR := "#FF4444"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_KEY := "#F7DC6F"
const _COLOR_CMD := "#5FBEE0"

const _HOTKEYS_PATH := "user://hotkeys.json"
const _HOOK_NAME := "DebugConsoleHotkeyHook"

# Inner Node that lives in the scene tree and forwards _unhandled_input
# back into this module. We keep a back-reference to the module rather
# than storing state on the hook so all logic stays in one place.
class _HotkeyHook extends Node:
	var module: RefCounted

	func _unhandled_input(event: InputEvent) -> void:
		if module and event is InputEventKey:
			module._on_key_event(event)

var _registry: Node
var _core: Node
var _hook: Node
var _enabled: bool = true

# Each entry: { "spec": String (normalized), "keycode": int,
#               "ctrl": bool, "shift": bool, "alt": bool, "meta": bool,
#               "command": String }
# Keyed by normalized spec so re-binding the same combo overwrites cleanly.
var _bindings: Dictionary = {}

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("hotkey_bind", _cmd_bind, "Bind a key to a console command: hotkey_bind <key_spec> <command...>", "game")
	_registry.register_command("hotkey_unbind", _cmd_unbind, "Remove a binding (or all): hotkey_unbind <key_spec|all>", "game")
	_registry.register_command("hotkey_list", _cmd_list, "List active hotkey bindings: hotkey_list", "game")
	_registry.register_command("hotkey_save", _cmd_save, "Persist bindings to user://hotkeys.json: hotkey_save", "game")
	_registry.register_command("hotkey_load", _cmd_load, "Reload bindings from user://hotkeys.json: hotkey_load", "game")
	_registry.register_command("hotkey_disable", _cmd_disable, "Disable all hotkeys without losing bindings: hotkey_disable", "game")
	_registry.register_command("hotkey_enable", _cmd_enable, "Re-enable hotkey dispatch: hotkey_enable", "game")
	_registry.register_command("hotkey_trigger", _cmd_trigger, "Fire a binding by spec (for testing): hotkey_trigger <key_spec>", "game")

	# The editor console owns its own modifier handlers; only install the
	# input hook when the plugin is actually running inside a game.
	if not Engine.is_editor_hint():
		_install_hook()
		_load_from_disk()

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_uninstall_hook()

#region Command implementations

func _cmd_bind(args: Array, _piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: hotkey_bind <key_spec> <command...>")
	var spec_raw := str(args[0]).strip_edges()
	var command_parts: Array[String] = []
	for i in range(1, args.size()):
		command_parts.append(str(args[i]))
	var command_line := " ".join(command_parts).strip_edges()
	if command_line.is_empty():
		return _format_error("Command cannot be empty")

	var parsed := _parse_spec(spec_raw)
	if parsed.is_empty():
		return _format_error("Invalid key spec: %s" % spec_raw)
	var spec_key: String = parsed["spec"]
	parsed["command"] = command_line
	_bindings[spec_key] = parsed
	_save_to_disk()
	return _format_success("Bound %s -> %s" % [_color_key(spec_key), _color_cmd(command_line)])

func _cmd_unbind(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: hotkey_unbind <key_spec|all>")
	var target := str(args[0]).strip_edges()
	if target.to_lower() == "all":
		var n: int = _bindings.size()
		_bindings.clear()
		_save_to_disk()
		return _format_success("Cleared %d binding(s)" % n)
	var parsed := _parse_spec(target)
	if parsed.is_empty():
		return _format_error("Invalid key spec: %s" % target)
	var spec_key: String = parsed["spec"]
	if not _bindings.has(spec_key):
		return _format_error("No binding for %s" % spec_key)
	_bindings.erase(spec_key)
	_save_to_disk()
	return _format_success("Unbound %s" % _color_key(spec_key))

func _cmd_list(_args: Array, _piped_input: String = "") -> String:
	if _bindings.is_empty():
		return "No hotkey bindings. Master: %s" % ("enabled" if _enabled else "disabled")
	var lines: Array[String] = []
	lines.append("Hotkey bindings (master: %s):" % ("enabled" if _enabled else "disabled"))
	var keys: Array = _bindings.keys()
	keys.sort()
	for k in keys:
		var entry: Dictionary = _bindings[k]
		lines.append("  %s -> %s" % [_color_key(str(k)), _color_cmd(str(entry.get("command", "")))])
	return "\n".join(lines)

func _cmd_save(_args: Array, _piped_input: String = "") -> String:
	if _save_to_disk():
		return _format_success("Saved %d binding(s) to %s" % [_bindings.size(), _HOTKEYS_PATH])
	return _format_error("Failed to write %s" % _HOTKEYS_PATH)

func _cmd_load(_args: Array, _piped_input: String = "") -> String:
	var loaded := _load_from_disk()
	if loaded < 0:
		return _format_error("Failed to read %s" % _HOTKEYS_PATH)
	return _format_success("Loaded %d binding(s) from %s" % [loaded, _HOTKEYS_PATH])

func _cmd_disable(_args: Array, _piped_input: String = "") -> String:
	_enabled = false
	return _format_success("Hotkeys disabled")

func _cmd_enable(_args: Array, _piped_input: String = "") -> String:
	_enabled = true
	return _format_success("Hotkeys enabled")

func _cmd_trigger(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: hotkey_trigger <key_spec>")
	var spec_raw := str(args[0]).strip_edges()
	var parsed := _parse_spec(spec_raw)
	if parsed.is_empty():
		return _format_error("Invalid key spec: %s" % spec_raw)
	var spec_key: String = parsed["spec"]
	if not _bindings.has(spec_key):
		return _format_error("No binding for %s" % spec_key)
	var entry: Dictionary = _bindings[spec_key]
	var command_line: String = str(entry.get("command", ""))
	var result: String = _execute(command_line)
	return "%s -> %s\n%s" % [_color_key(spec_key), _color_cmd(command_line), result]

#endregion

#region Input dispatch

func _on_key_event(event: InputEventKey) -> void:
	if not _enabled:
		return
	if not event.pressed or event.echo:
		return
	var keycode: int = int(event.physical_keycode if event.physical_keycode != 0 else event.keycode)
	for spec_key in _bindings.keys():
		var entry: Dictionary = _bindings[spec_key]
		if int(entry.get("keycode", 0)) != keycode:
			continue
		if bool(entry.get("ctrl", false)) != event.ctrl_pressed:
			continue
		if bool(entry.get("shift", false)) != event.shift_pressed:
			continue
		if bool(entry.get("alt", false)) != event.alt_pressed:
			continue
		if bool(entry.get("meta", false)) != event.meta_pressed:
			continue
		var command_line: String = str(entry.get("command", ""))
		if command_line.is_empty():
			continue
		var result: String = _execute(command_line)
		_emit_result("[hotkey %s] %s\n%s" % [str(spec_key), command_line, result])
		var viewport := _hook.get_viewport() if _hook else null
		if viewport:
			viewport.set_input_as_handled()
		return

func _execute(command_line: String) -> String:
	if _registry and _registry.has_method("execute_command"):
		return str(_registry.execute_command(command_line))
	return _format_error("Registry missing execute_command")

func _emit_result(msg: String) -> void:
	if _core and is_instance_valid(_core):
		if _core.has_method("print_to_console"):
			_core.call("print_to_console", msg)
			return
		if _core.has_method("info"):
			_core.call("info", msg)
			return
	print(msg)

#endregion

#region Hook lifecycle

func _install_hook() -> void:
	if _hook and is_instance_valid(_hook):
		return
	if not _core or not is_instance_valid(_core):
		return
	# Reuse an existing hook node if BuiltInCommands already added one (e.g.
	# after a hot-reload that re-instantiated this module).
	var existing := _core.get_node_or_null(_HOOK_NAME)
	if existing is Node:
		_hook = existing
		(_hook as Object).set("module", self)
		return
	var hook := _HotkeyHook.new()
	hook.name = _HOOK_NAME
	hook.module = self
	if _core.is_inside_tree():
		_core.add_child(hook)
	else:
		_core.call_deferred("add_child", hook)
	_hook = hook

func _uninstall_hook() -> void:
	if _hook and is_instance_valid(_hook):
		(_hook as Object).set("module", null)
		_hook.queue_free()
	_hook = null

#endregion

#region Spec parsing

func _parse_spec(raw: String) -> Dictionary:
	var s := raw.strip_edges()
	if s.is_empty():
		return {}
	var parts: PackedStringArray = s.split("+", false)
	if parts.size() == 0:
		return {}
	var ctrl: bool = false
	var shift: bool = false
	var alt: bool = false
	var meta: bool = false
	var key_token: String = ""
	for i in range(parts.size()):
		var token := String(parts[i]).strip_edges()
		if token.is_empty():
			continue
		var lower := token.to_lower()
		if i < parts.size() - 1 and (lower == "ctrl" or lower == "control" or lower == "shift" or lower == "alt" or lower == "meta" or lower == "cmd" or lower == "command" or lower == "super" or lower == "win"):
			match lower:
				"ctrl", "control": ctrl = true
				"shift": shift = true
				"alt": alt = true
				"meta", "cmd", "command", "super", "win": meta = true
			continue
		# Last token, or first-and-only token, is the key itself.
		key_token = token
	if key_token.is_empty():
		return {}
	var keycode: int = OS.find_keycode_from_string(key_token)
	if keycode == 0:
		return {}
	var canonical_name: String = OS.get_keycode_string(keycode)
	if canonical_name.is_empty():
		canonical_name = key_token
	var spec_parts: Array[String] = []
	if ctrl: spec_parts.append("Ctrl")
	if shift: spec_parts.append("Shift")
	if alt: spec_parts.append("Alt")
	if meta: spec_parts.append("Meta")
	spec_parts.append(canonical_name)
	return {
		"spec": "+".join(spec_parts),
		"keycode": keycode,
		"ctrl": ctrl,
		"shift": shift,
		"alt": alt,
		"meta": meta,
	}

#endregion

#region Persistence

func _save_to_disk() -> bool:
	var out: Array = []
	for spec_key in _bindings.keys():
		var entry: Dictionary = _bindings[spec_key]
		out.append({
			"spec": str(spec_key),
			"command": str(entry.get("command", "")),
		})
	var file := FileAccess.open(_HOTKEYS_PATH, FileAccess.WRITE)
	if not file:
		return false
	file.store_string(JSON.stringify({"version": 1, "bindings": out}, "\t"))
	file.close()
	return true

# Returns the number of bindings loaded, or -1 on read/parse failure.
func _load_from_disk() -> int:
	if not FileAccess.file_exists(_HOTKEYS_PATH):
		return 0
	var file := FileAccess.open(_HOTKEYS_PATH, FileAccess.READ)
	if not file:
		return -1
	var text := file.get_as_text()
	file.close()
	if text.strip_edges().is_empty():
		_bindings.clear()
		return 0
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return -1
	var data: Dictionary = parsed
	var list_variant: Variant = data.get("bindings", [])
	if typeof(list_variant) != TYPE_ARRAY:
		return -1
	_bindings.clear()
	var list: Array = list_variant
	for item in list:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var item_dict: Dictionary = item
		var spec_raw: String = str(item_dict.get("spec", ""))
		var command: String = str(item_dict.get("command", ""))
		if spec_raw.is_empty() or command.is_empty():
			continue
		var entry := _parse_spec(spec_raw)
		if entry.is_empty():
			continue
		entry["command"] = command
		_bindings[entry["spec"]] = entry
	return _bindings.size()

#endregion

#region Formatting

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_key(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_KEY, s]

func _color_cmd(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_CMD, s]

#endregion

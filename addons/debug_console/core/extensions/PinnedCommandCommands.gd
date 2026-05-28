@tool
class_name DebugConsolePinnedCommandCommands extends RefCounted

# Pinned-command system. Users can star a command string for one-shot recall
# (`pin "spawn res://enemy.tscn"`), list them by index (`pins`), invoke them
# by index (`run_pin 2`), and attach a friendly label so the list reads as
# something other than raw command text. The pin list survives between
# sessions via user://pinned_commands.json; pin/unpin/pin_label all auto-save
# so callers don't have to remember pins_save. The file is loaded lazily on
# the first call to register_commands so repeated plugin instantiations in
# the editor don't repeatedly hit the disk.
#
# Mirrors the shape of SceneCommands.gd / SaveSlotCommands.gd: same color
# palette, _format_error / _format_success / _color_* helpers, "both"
# context registration so commands work in editor and runtime. The
# orchestrator (BuiltInCommands.register_universal_commands) instantiates
# one of these and keeps a strong reference so the Callables stay valid for
# the plugin's lifetime.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"

const _PINS_PATH := "user://pinned_commands.json"
const _PINS_VERSION := 1

var _registry: Node
var _core: Node
var _pins: Array = []
var _loaded: bool = false

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	if not _loaded:
		_load_pins_silent()
		_loaded = true
	_registry.register_command("pin", _cmd_pin, "Star a command for quick recall: pin <cmd_string>", "both")
	_registry.register_command("unpin", _cmd_unpin, "Remove a pinned command by full string or 1-based index: unpin <cmd_string|index>", "both")
	_registry.register_command("pins", _cmd_pins, "List pinned commands with their indexes and labels: pins", "both")
	_registry.register_command("run_pin", _cmd_run_pin, "Execute a pinned command by 1-based index: run_pin <index>", "both")
	_registry.register_command("pin_label", _cmd_pin_label, "Attach a friendly label to a pinned command: pin_label <index> <label>", "both")
	_registry.register_command("pins_save", _cmd_pins_save, "Persist the current pin list to user://pinned_commands.json", "both")
	_registry.register_command("pins_load", _cmd_pins_load, "Reload the pin list from user://pinned_commands.json, discarding unsaved changes", "both")

#region Command implementations

func _cmd_pin(args: Array, _piped_input: String = "") -> String:
	var cmd_string := _join_args(args).strip_edges()
	if cmd_string.is_empty():
		return _format_error("Usage: pin <cmd_string>")
	for entry in _pins:
		if entry is Dictionary and str(entry.get("command", "")) == cmd_string:
			return _format_error("Already pinned: %s" % cmd_string)
	_pins.append({"command": cmd_string, "label": ""})
	var save_err := _save_pins()
	if not save_err.is_empty():
		return _format_error(save_err)
	return _format_success("Pinned [%s] %s" % [
		_color_number(str(_pins.size())),
		_color_path(cmd_string),
	])

func _cmd_unpin(args: Array, _piped_input: String = "") -> String:
	var raw := _join_args(args).strip_edges()
	if raw.is_empty():
		return _format_error("Usage: unpin <cmd_string|index>")
	var idx := _resolve_index(raw)
	if idx < 0:
		for i in range(_pins.size()):
			var entry: Dictionary = _pins[i]
			if str(entry.get("command", "")) == raw:
				idx = i
				break
	if idx < 0 or idx >= _pins.size():
		return _format_error("No pin matches: %s" % raw)
	var removed: Dictionary = _pins[idx]
	_pins.remove_at(idx)
	var save_err := _save_pins()
	if not save_err.is_empty():
		return _format_error(save_err)
	return _format_success("Unpinned [%s] %s" % [
		_color_number(str(idx + 1)),
		_color_path(str(removed.get("command", ""))),
	])

func _cmd_pins(_args: Array, _piped_input: String = "") -> String:
	if _pins.is_empty():
		return "No pinned commands. Use 'pin <cmd_string>' to add one."
	var lines: Array[String] = []
	lines.append("Pinned commands (%s):" % _color_number(str(_pins.size())))
	for i in range(_pins.size()):
		var entry: Dictionary = _pins[i]
		var cmd: String = str(entry.get("command", ""))
		var label: String = str(entry.get("label", ""))
		var idx_str: String = _color_number(str(i + 1).pad_zeros(2))
		if label.is_empty():
			lines.append("  [%s] %s" % [idx_str, _color_path(cmd)])
		else:
			lines.append("  [%s] %s -- %s" % [idx_str, label, _color_path(cmd)])
	return "\n".join(lines)

func _cmd_run_pin(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: run_pin <index>")
	var idx := _resolve_index(str(args[0]).strip_edges())
	if idx < 0 or idx >= _pins.size():
		return _format_error("Pin index out of range (1..%d): %s" % [_pins.size(), str(args[0])])
	var entry: Dictionary = _pins[idx]
	var cmd: String = str(entry.get("command", "")).strip_edges()
	if cmd.is_empty():
		return _format_error("Pin %d has an empty command" % (idx + 1))
	if not _registry or not _registry.has_method("execute_command"):
		return _format_error("Registry cannot execute commands")
	var result: Variant = _registry.execute_command(cmd) if piped_input.is_empty() else _registry.execute_command("%s %s" % [cmd, piped_input])
	return str(result)

func _cmd_pin_label(args: Array, _piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: pin_label <index> <label>")
	var idx := _resolve_index(str(args[0]).strip_edges())
	if idx < 0 or idx >= _pins.size():
		return _format_error("Pin index out of range (1..%d): %s" % [_pins.size(), str(args[0])])
	var label_parts: Array = []
	for i in range(1, args.size()):
		label_parts.append(str(args[i]))
	var label: String = " ".join(label_parts).strip_edges()
	var entry: Dictionary = _pins[idx]
	entry["label"] = label
	_pins[idx] = entry
	var save_err := _save_pins()
	if not save_err.is_empty():
		return _format_error(save_err)
	if label.is_empty():
		return _format_success("Cleared label on pin [%s]" % _color_number(str(idx + 1)))
	return _format_success("Pin [%s] labelled: %s" % [
		_color_number(str(idx + 1)),
		_color_path(label),
	])

func _cmd_pins_save(_args: Array, _piped_input: String = "") -> String:
	var err := _save_pins()
	if not err.is_empty():
		return _format_error(err)
	return _format_success("Saved %s pin(s) -> %s" % [
		_color_number(str(_pins.size())),
		_color_path(_PINS_PATH),
	])

func _cmd_pins_load(_args: Array, _piped_input: String = "") -> String:
	var err := _load_pins()
	if not err.is_empty():
		return _format_error(err)
	return _format_success("Loaded %s pin(s) from %s" % [
		_color_number(str(_pins.size())),
		_color_path(_PINS_PATH),
	])

#endregion

#region Helpers

func _join_args(args: Array) -> String:
	var parts: Array = []
	for a in args:
		parts.append(str(a))
	return " ".join(parts)

func _resolve_index(raw: String) -> int:
	var s := raw.strip_edges()
	if s.is_empty() or not s.is_valid_int():
		return -1
	var n: int = s.to_int()
	if n <= 0:
		return -1
	return n - 1

func _load_pins_silent() -> void:
	var _err := _load_pins()

func _load_pins() -> String:
	_pins = []
	if not FileAccess.file_exists(_PINS_PATH):
		return ""
	var f := FileAccess.open(_PINS_PATH, FileAccess.READ)
	if not f:
		return "Cannot open %s (err %d)" % [_PINS_PATH, FileAccess.get_open_error()]
	var text: String = f.get_as_text()
	f.close()
	if text.strip_edges().is_empty():
		return ""
	var parsed: Variant = JSON.parse_string(text)
	if parsed == null:
		return "%s is not valid JSON" % _PINS_PATH
	if not (parsed is Dictionary):
		return "%s root must be a JSON object" % _PINS_PATH
	var raw_pins: Variant = (parsed as Dictionary).get("pins", [])
	if not (raw_pins is Array):
		return "%s 'pins' must be an array" % _PINS_PATH
	for item in raw_pins:
		if not (item is Dictionary):
			continue
		var d: Dictionary = item
		var cmd: String = str(d.get("command", "")).strip_edges()
		if cmd.is_empty():
			continue
		_pins.append({
			"command": cmd,
			"label": str(d.get("label", "")),
		})
	return ""

func _save_pins() -> String:
	var payload: Dictionary = {
		"version": _PINS_VERSION,
		"timestamp": int(Time.get_unix_time_from_system()),
		"pins": _pins,
	}
	var f := FileAccess.open(_PINS_PATH, FileAccess.WRITE)
	if not f:
		return "Cannot open %s for write (err %d)" % [_PINS_PATH, FileAccess.get_open_error()]
	f.store_string(JSON.stringify(payload, "  "))
	f.close()
	return ""

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

#endregion

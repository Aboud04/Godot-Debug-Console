@tool
class_name DebugConsoleScriptBufferCommands extends RefCounted

# Extension module - multi-line GDScript paste buffer.
#
# The buffer (`_lines`) is owned by this extension instance, which is kept
# alive by the BuiltInCommands keepalive array (see extensions/README.md).
# `buf_start` flips `_paste_mode` on; the console dispatcher is expected to
# check `is_paste_mode()` and route raw input through `append_line(line)`
# instead of dispatching it as a command until `buf_end` clears the flag.
# This file owns only the state and the seven commands; the dispatcher hook
# is intentionally not wired here so we do not have to touch other files.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_MUTED := "#888888"

var _registry: Node
var _core: Node
var _lines: Array[String] = []
var _paste_mode: bool = false

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("buf_start", _cmd_buf_start, "Enter paste mode; subsequent input lines append to the script buffer until buf_end", "both")
	_registry.register_command("buf_end", _cmd_buf_end, "Exit paste mode without clearing the buffer", "both")
	_registry.register_command("buf_show", _cmd_buf_show, "Show the current script buffer with line numbers", "both")
	_registry.register_command("buf_clear", _cmd_buf_clear, "Clear the script buffer and exit paste mode", "both")
	_registry.register_command("buf_run", _cmd_buf_run, "Wrap the buffer in static func _run(): and execute via GDScript.new().reload()", "both")
	_registry.register_command("buf_save", _cmd_buf_save, "Save the buffer to a .gd file: buf_save <res://path.gd>", "both")
	_registry.register_command("buf_load", _cmd_buf_load, "Load a .gd file into the buffer: buf_load <res://path.gd>", "both")

#region Dispatcher hooks

func is_paste_mode() -> bool:
	return _paste_mode

func append_line(line: String) -> void:
	_lines.append(line)

func get_lines() -> Array[String]:
	return _lines.duplicate()

#endregion

#region Command implementations

func _cmd_buf_start(_args: Array, _piped_input: String = "") -> String:
	_paste_mode = true
	return _format_success("Paste mode ON (%s line(s) in buffer). Use buf_end to finish, buf_clear to discard." % _color_number(str(_lines.size())))

func _cmd_buf_end(_args: Array, _piped_input: String = "") -> String:
	_paste_mode = false
	return _format_success("Paste mode OFF. Buffer holds %s line(s)." % _color_number(str(_lines.size())))

func _cmd_buf_show(_args: Array, _piped_input: String = "") -> String:
	var header := "[color=%s]-- buffer (%s line(s), paste_mode=%s) --[/color]" % [_COLOR_MUTED, str(_lines.size()), str(_paste_mode)]
	if _lines.is_empty():
		return header + "\n[color=%s](empty)[/color]" % _COLOR_MUTED
	var width: int = str(_lines.size()).length()
	var rows: PackedStringArray = PackedStringArray()
	for i in _lines.size():
		var num := str(i + 1).pad_zeros(width)
		rows.append("[color=%s]%s[/color] %s" % [_COLOR_MUTED, num, _lines[i]])
	return header + "\n" + "\n".join(rows)

func _cmd_buf_clear(_args: Array, _piped_input: String = "") -> String:
	var prev: int = _lines.size()
	_lines.clear()
	_paste_mode = false
	return _format_success("Cleared %s line(s); paste mode OFF." % _color_number(str(prev)))

func _cmd_buf_run(_args: Array, _piped_input: String = "") -> String:
	if _lines.is_empty():
		return _format_error("Buffer is empty.")
	var source := _wrap_source(_lines)
	var script := GDScript.new()
	script.source_code = source
	var err: int = script.reload()
	if err != OK:
		return _format_error("Compile failed (err=%s). Run buf_show to inspect." % str(err))
	var result: Variant = script.call("_run")
	var line_count: String = _color_number(str(_lines.size()))
	if result == null:
		return _format_success("Ran %s line(s)." % line_count)
	return _format_success("Ran %s line(s) -> %s" % [line_count, str(result)])

func _cmd_buf_save(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: buf_save <res://path.gd>")
	var path := str(args[0]).strip_edges()
	if path.is_empty():
		return _format_error("Path is empty.")
	if _lines.is_empty():
		return _format_error("Buffer is empty; nothing to save.")
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return _format_error("Cannot open for write: %s (err=%s)" % [path, str(FileAccess.get_open_error())])
	f.store_string("\n".join(_lines) + "\n")
	f.close()
	return _format_success("Saved %s line(s) to %s" % [_color_number(str(_lines.size())), _color_path(path)])

func _cmd_buf_load(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: buf_load <res://path.gd>")
	var path := str(args[0]).strip_edges()
	if path.is_empty():
		return _format_error("Path is empty.")
	if not FileAccess.file_exists(path):
		return _format_error("File not found: %s" % path)
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return _format_error("Cannot open for read: %s (err=%s)" % [path, str(FileAccess.get_open_error())])
	var text := f.get_as_text()
	f.close()
	_lines.clear()
	for line in text.split("\n", true):
		_lines.append(line)
	while _lines.size() > 0 and _lines[_lines.size() - 1] == "":
		_lines.remove_at(_lines.size() - 1)
	return _format_success("Loaded %s line(s) from %s" % [_color_number(str(_lines.size())), _color_path(path)])

#endregion

#region Helpers

func _wrap_source(lines: Array[String]) -> String:
	# If the user already wrote their own `static func _run():` (or made the
	# whole buffer a full script with class members), do not double-wrap.
	for line in lines:
		var stripped := line.strip_edges()
		if stripped.begins_with("static func _run("):
			return "\n".join(lines) + "\n"
	var indented: PackedStringArray = PackedStringArray()
	for line in lines:
		if line == "":
			indented.append("")
		else:
			indented.append("\t" + line)
	return "static func _run():\n" + "\n".join(indented) + "\n"

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

#endregion

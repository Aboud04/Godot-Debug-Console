@tool
class_name DebugConsoleActionRecorderCommands extends RefCounted

# Extension module - Blender Info-editor style command recorder.
#
# Every command executed through CommandRegistry is appended to `_buffer`
# while `_recording` is true, then can be exported as either:
#   * a runnable .gd script (record_save) holding `static func _run(registry):`
#     which replays each line through `registry.execute_command(line)`, or
#   * a plain .txt transcript (record_save_text).
#
# Capture path: in `register_commands`, if `_registry` exposes the
# `command_executed(command, result)` signal we connect to it. If the signal
# is absent (older registries / custom hosts) callers must invoke the public
# `record(cmd_str)` method from BuiltInCommands or a dispatcher shim.
#
# Reentrancy guards:
#   * `record_*` control commands are never written to the buffer.
#   * While `_replaying` is true the capture hook ignores incoming commands,
#     so a recording can be replayed without poisoning the buffer.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_MUTED := "#888888"

var _registry: Node
var _core: Node
var _buffer: Array[String] = []
var _recording: bool = false
var _session_name: String = ""
var _replaying: bool = false
var _hook_connected: bool = false

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("record_start", _cmd_record_start, "Begin recording executed commands into the buffer: record_start [name]", "both")
	_registry.register_command("record_stop", _cmd_record_stop, "Stop recording without clearing the buffer", "both")
	_registry.register_command("record_show", _cmd_record_show, "Show the last N recorded lines (default 50): record_show [n]", "both")
	_registry.register_command("record_save", _cmd_record_save, "Save buffer as a runnable .gd script: record_save <res://path.gd>", "both")
	_registry.register_command("record_save_text", _cmd_record_save_text, "Save buffer as plain text: record_save_text <user://path.txt>", "both")
	_registry.register_command("record_replay", _cmd_record_replay, "Re-run a saved recording through the registry: record_replay <res://path.gd>", "both")
	_registry.register_command("record_clear", _cmd_record_clear, "Clear the recorder buffer and stop recording", "both")
	_try_connect_hook()

#region Public API

func record(cmd_str: String) -> void:
	if not _recording or _replaying:
		return
	var trimmed := cmd_str.strip_edges()
	if trimmed.is_empty():
		return
	if trimmed.begins_with("record_"):
		return
	_buffer.append(cmd_str)

func is_recording() -> bool:
	return _recording

func get_buffer() -> Array[String]:
	return _buffer.duplicate()

#endregion

#region Capture hook

func _try_connect_hook() -> void:
	if _hook_connected or _registry == null:
		return
	if not _registry.has_signal("command_executed"):
		return
	if _registry.is_connected("command_executed", _on_command_executed):
		_hook_connected = true
		return
	var err: int = _registry.connect("command_executed", _on_command_executed)
	if err == OK:
		_hook_connected = true

func _on_command_executed(command: String, _result: String) -> void:
	record(command)

#endregion

#region Command implementations

func _cmd_record_start(args: Array, _piped_input: String = "") -> String:
	_session_name = str(args[0]).strip_edges() if args.size() > 0 else ""
	if _session_name.is_empty():
		_session_name = "session_%s" % str(int(Time.get_unix_time_from_system()))
	_recording = true
	_try_connect_hook()
	var hook_note := "" if _hook_connected else " %s" % _color_muted("(no command_executed signal; call record(cmd) manually)")
	return _format_success("Recording ON [%s] - buffer holds %s line(s).%s" % [
		_color_path(_session_name),
		_color_number(str(_buffer.size())),
		hook_note,
	])

func _cmd_record_stop(_args: Array, _piped_input: String = "") -> String:
	_recording = false
	return _format_success("Recording OFF. Buffer holds %s line(s)." % _color_number(str(_buffer.size())))

func _cmd_record_show(args: Array, _piped_input: String = "") -> String:
	var n: int = 50
	if args.size() > 0:
		var v: Variant = args[0]
		if typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT:
			n = int(v)
		else:
			n = int(str(v))
	if n <= 0:
		n = 50
	if _buffer.is_empty():
		return _format_muted("(buffer empty)")
	var start: int = maxi(0, _buffer.size() - n)
	var out: PackedStringArray = PackedStringArray()
	out.append("%s %s line(s) [%s, recording=%s]:" % [
		_color_muted("Showing last"),
		_color_number(str(_buffer.size() - start)),
		_color_path(_session_name if not _session_name.is_empty() else "<unnamed>"),
		_color_number("true" if _recording else "false"),
	])
	for i in range(start, _buffer.size()):
		out.append("%s  %s" % [_color_muted("%4d" % (i + 1)), _buffer[i]])
	return "\n".join(out)

func _cmd_record_save(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: record_save <res://path.gd>")
	var path := str(args[0]).strip_edges()
	if path.is_empty():
		return _format_error("Path is empty.")
	if _buffer.is_empty():
		return _format_error("Buffer is empty; nothing to save.")
	var src := _wrap_as_script(_buffer, _session_name)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return _format_error("Cannot open for write: %s (err=%s)" % [path, str(FileAccess.get_open_error())])
	f.store_string(src)
	f.close()
	return _format_success("Saved %s line(s) to %s" % [_color_number(str(_buffer.size())), _color_path(path)])

func _cmd_record_save_text(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: record_save_text <user://path.txt>")
	var path := str(args[0]).strip_edges()
	if path.is_empty():
		return _format_error("Path is empty.")
	if _buffer.is_empty():
		return _format_error("Buffer is empty; nothing to save.")
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return _format_error("Cannot open for write: %s (err=%s)" % [path, str(FileAccess.get_open_error())])
	f.store_string("\n".join(_buffer) + "\n")
	f.close()
	return _format_success("Saved %s line(s) to %s" % [_color_number(str(_buffer.size())), _color_path(path)])

func _cmd_record_replay(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: record_replay <res://path.gd>")
	var path := str(args[0]).strip_edges()
	if path.is_empty():
		return _format_error("Path is empty.")
	if not FileAccess.file_exists(path):
		return _format_error("File not found: %s" % path)
	if _registry == null:
		return _format_error("No registry bound; cannot replay.")
	var script: GDScript = load(path) as GDScript
	if script == null:
		return _format_error("Failed to load as GDScript: %s" % path)
	var target: Object = script
	if not target.has_method("_run"):
		if not script.can_instantiate():
			return _format_error("Script has no `_run(registry)` function (expected `static func _run(registry):` at top of file).")
		target = script.new()
		if target == null or not target.has_method("_run"):
			return _format_error("Script has no `_run(registry)` function (expected `static func _run(registry):` at top of file).")
	var was_replaying := _replaying
	_replaying = true
	@warning_ignore("unsafe_method_access")
	target.call("_run", _registry)
	_replaying = was_replaying
	return _format_success("Replayed %s" % _color_path(path))

func _cmd_record_clear(_args: Array, _piped_input: String = "") -> String:
	var prev: int = _buffer.size()
	_buffer.clear()
	_recording = false
	_session_name = ""
	return _format_success("Cleared %s recorded line(s); recording OFF." % _color_number(str(prev)))

#endregion

#region Helpers

func _wrap_as_script(lines: Array[String], session_name: String) -> String:
	var header := "# Debug Console recording - session \"%s\" - %d line(s)\n" % [session_name, lines.size()]
	var body := PackedStringArray()
	body.append("extends RefCounted")
	body.append("")
	body.append("static func _run(registry) -> void:")
	body.append("\tvar cmds: Array[String] = [")
	for line in lines:
		body.append("\t\t%s," % _gdscript_string_literal(line))
	body.append("\t]")
	body.append("\tfor c in cmds:")
	body.append("\t\tif registry == null:")
	body.append("\t\t\tcontinue")
	body.append("\t\tif registry.has_method(\"execute_command\"):")
	body.append("\t\t\tregistry.execute_command(c)")
	body.append("")
	return header + "\n".join(body)

func _gdscript_string_literal(s: String) -> String:
	var escaped := s.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")
	return "\"%s\"" % escaped

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _format_muted(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_MUTED, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

func _color_muted(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_MUTED, s]

#endregion

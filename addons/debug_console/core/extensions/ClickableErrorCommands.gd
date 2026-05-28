@tool
class_name DebugConsoleClickableErrorCommands extends RefCounted

# Extension - turns Godot-style error text into BBCode [url=...] links so
# clicking a path in the console output opens the script in the editor.
# In game mode (no EditorInterface available) the commands still emit a
# coloured, machine-readable "path:line" string so external tooling can parse
# them, but the [url] wrapper is dropped because nothing will handle the click.
#
# Auto-discovered by BuiltInCommands._t8_extensions; do not add this file to
# the bundled extension list elsewhere.

const _COLOR_ERROR := "#FF4444"
const _COLOR_LINK := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_HINT := "#888888"

# Matches `res://relative/path.gd:NN` anywhere in the input. Path may not
# contain whitespace or another ':' so it stops at the line-number separator.
const _ERROR_PATTERN := "(res://[^\\s:]+\\.gd):(\\d+)"
const _URL_SCHEME := "err_open://"

var _registry: Node
var _core: Node
var _error_regex: RegEx

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_error_regex = RegEx.new()
	var compile_err := _error_regex.compile(_ERROR_PATTERN)
	if compile_err != OK:
		push_error("ClickableErrorCommands: failed to compile regex (err=%d)" % compile_err)
		return
	_registry.register_command("err_format", _cmd_err_format, "Wrap res://path.gd:line refs in clickable BBCode: err_format <text>", "both")
	_registry.register_command("err_format_pipe", _cmd_err_format_pipe, "Same as err_format but reads from piped input: <producer> | err_format_pipe", "both")
	_registry.register_command("err_link", _cmd_err_link, "Build a single clickable link: err_link <res://path.gd> <line>", "both")
	_registry.register_command("err_test", _cmd_err_test, "Emit a sample error and show the formatted output", "both")
	_registry.register_command("err_open", _cmd_err_open, "Open a script at a line via EditorInterface: err_open <res://path.gd:line>", "both")

#region Command implementations

func _cmd_err_format(args: Array, piped_input: String = "") -> String:
	var text := ""
	if not piped_input.is_empty():
		text = piped_input
	elif not args.is_empty():
		text = " ".join(args)
	if text.is_empty():
		return _format_error("Usage: err_format <text>  (or pipe text in)")
	return _format_with_links(text)

func _cmd_err_format_pipe(args: Array, piped_input: String = "") -> String:
	if piped_input.is_empty():
		return _format_error("err_format_pipe expects piped input. Try: <producer> | err_format_pipe")
	return _format_with_links(piped_input)

func _cmd_err_link(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: err_link <res://path.gd> <line>")
	var path := str(args[0]).strip_edges()
	var line_str := str(args[1]).strip_edges()
	if not line_str.is_valid_int():
		return _format_error("Line must be an integer, got '%s'" % line_str)
	if not path.begins_with("res://"):
		return _format_error("Path must start with res:// , got '%s'" % path)
	return _build_link(path, line_str.to_int())

func _cmd_err_test(args: Array, piped_input: String = "") -> String:
	var sample_path := "res://scripts/example.gd"
	var sample_line := 42
	var sample := "SCRIPT ERROR: Parse Error (sample, not real)\n   at: _ready (%s:%d)\n   chained from: res://scripts/other.gd:117" % [sample_path, sample_line]
	push_error("err_test sample (not a real failure): %s:%d" % [sample_path, sample_line])
	var formatted := _format_with_links(sample)
	var mode_label := "editor" if Engine.is_editor_hint() else "game"
	return "[color=%s]err_test - emitted sample via push_error (mode: %s).[/color]\n%s" % [_COLOR_HINT, mode_label, formatted]

func _cmd_err_open(args: Array, piped_input: String = "") -> String:
	var raw := ""
	if not piped_input.is_empty():
		raw = piped_input.strip_edges()
	elif not args.is_empty():
		raw = str(args[0]).strip_edges()
	if raw.is_empty():
		return _format_error("Usage: err_open <res://path.gd:line>")
	var parsed := _split_path_line(raw)
	if parsed.is_empty():
		return _format_error("Could not parse '%s' as <path:line>" % raw)
	var path := parsed[0] as String
	var line := int(parsed[1])
	if not ResourceLoader.exists(path):
		return _format_error("Script not found: %s" % path)
	if not Engine.is_editor_hint():
		return "[color=%s]Game mode - editor unavailable. Raw target:[/color] %s:%d" % [_COLOR_HINT, path, line]
	if not Engine.has_singleton("EditorInterface"):
		return _format_error("EditorInterface singleton not available")
	var script_res := load(path)
	if not (script_res is Script):
		return _format_error("Not a Script resource: %s" % path)
	var editor: Object = Engine.get_singleton("EditorInterface")
	editor.edit_script(script_res, line)
	return _format_success("Opened %s at line %d" % [path, line])

#endregion

#region Helpers

func _format_with_links(text: String) -> String:
	if text.is_empty() or _error_regex == null:
		return text
	var in_editor := Engine.is_editor_hint()
	var result := ""
	var cursor := 0
	var matches := _error_regex.search_all(text)
	for m in matches:
		var start: int = m.get_start()
		var end: int = m.get_end()
		if start > cursor:
			result += text.substr(cursor, start - cursor)
		var path := m.get_string(1)
		var line_str := m.get_string(2)
		var line_num := line_str.to_int()
		if in_editor:
			result += _wrap_url(path, line_num)
		else:
			result += "[color=%s]%s:%d[/color]" % [_COLOR_LINK, path, line_num]
		cursor = end
	if cursor < text.length():
		result += text.substr(cursor, text.length() - cursor)
	return result

func _build_link(path: String, line: int) -> String:
	if Engine.is_editor_hint():
		return _wrap_url(path, line)
	return "[color=%s]%s:%d[/color]" % [_COLOR_LINK, path, line]

func _wrap_url(path: String, line: int) -> String:
	return "[url=%s%s:%d][color=%s]%s:%d[/color][/url]" % [_URL_SCHEME, path, line, _COLOR_LINK, path, line]

func _split_path_line(raw: String) -> Array:
	var s := raw
	if s.begins_with(_URL_SCHEME):
		s = s.substr(_URL_SCHEME.length(), s.length() - _URL_SCHEME.length())
	var colon := s.rfind(":")
	if colon <= 0:
		return []
	var path := s.substr(0, colon)
	var line_part := s.substr(colon + 1, s.length() - colon - 1)
	if not line_part.is_valid_int():
		return []
	if not path.begins_with("res://"):
		return []
	return [path, line_part.to_int()]

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

#endregion

@tool
class_name DebugConsoleOutputSearchCommands extends RefCounted

# Extension module - Ctrl+F-style search across captured console output.
# Mirrors the structure of core/SceneCommands.gd: the orchestrator
# (BuiltInCommands.register_universal_commands) instantiates this once,
# holds a strong reference, and calls register_commands(registry, core)
# so the Callables here remain valid for the lifetime of the plugin.
#
# Lines are pulled from DebugCore.get_history() on every search so the
# match set always reflects whatever is currently in the console buffer.
# Per-instance state holds the last query, its mode (text|regex), the
# matching line indices, and a cursor used by find_next / find_prev.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_DIM := "#808080"
const _HIGHLIGHT_BG := "#665500"
const _HIGHLIGHT_FG := "#FFF066"

const _CONTEXT_LINES: int = 1
const _MODE_TEXT: String = "text"
const _MODE_REGEX: String = "regex"

var _registry: Node
var _core: Node

var _last_query: String = ""
var _last_mode: String = ""
var _last_matches: Array[int] = []
var _cursor: int = -1

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("find", _cmd_find, "Find first occurrence of <text> in DebugCore history with surrounding context: find <text>", "both")
	_registry.register_command("find_re", _cmd_find_re, "Find first regex match in DebugCore history with surrounding context: find_re <pattern>", "both")
	_registry.register_command("find_next", _cmd_find_next, "Jump to the next match of the last query (wraps): find_next", "both")
	_registry.register_command("find_prev", _cmd_find_prev, "Jump to the previous match of the last query (wraps): find_prev", "both")
	_registry.register_command("find_clear", _cmd_find_clear, "Reset search state (query, matches, cursor): find_clear", "both")
	_registry.register_command("find_count", _cmd_find_count, "Count occurrences of <text> without storing search state: find_count <text>", "both")

#region Command implementations

func _cmd_find(args: Array, _piped_input: String = "") -> String:
	var query := _join_args(args)
	if query.is_empty():
		return _format_error("Usage: find <text>")
	return _run_search(query, _MODE_TEXT)

func _cmd_find_re(args: Array, _piped_input: String = "") -> String:
	var query := _join_args(args)
	if query.is_empty():
		return _format_error("Usage: find_re <pattern>")
	var probe := RegEx.new()
	if probe.compile(query) != OK:
		return _format_error("Invalid regex: %s" % query)
	return _run_search(query, _MODE_REGEX)

func _cmd_find_next(_args: Array, _piped_input: String = "") -> String:
	if _last_query.is_empty() or _last_matches.is_empty():
		return _format_error("No active search. Run 'find <text>' or 'find_re <pattern>' first.")
	_cursor = (_cursor + 1) % _last_matches.size()
	return _render_current()

func _cmd_find_prev(_args: Array, _piped_input: String = "") -> String:
	if _last_query.is_empty() or _last_matches.is_empty():
		return _format_error("No active search. Run 'find <text>' or 'find_re <pattern>' first.")
	_cursor = (_cursor - 1 + _last_matches.size()) % _last_matches.size()
	return _render_current()

func _cmd_find_clear(_args: Array, _piped_input: String = "") -> String:
	_last_query = ""
	_last_mode = ""
	_last_matches.clear()
	_cursor = -1
	return _format_success("Search state cleared.")

func _cmd_find_count(args: Array, _piped_input: String = "") -> String:
	var query := _join_args(args)
	if query.is_empty():
		return _format_error("Usage: find_count <text>")
	var history := _get_history()
	var line_hits: int = 0
	var total_hits: int = 0
	for line in history:
		var c: int = line.count(query)
		if c > 0:
			line_hits += 1
			total_hits += c
	return "%s occurrence(s) across %s line(s) (searched %s history line(s))" % [
		_color_number(str(total_hits)),
		_color_number(str(line_hits)),
		_color_number(str(history.size())),
	]

#endregion

#region Search core

func _run_search(query: String, mode: String) -> String:
	var history := _get_history()
	var matches: Array[int] = []
	if mode == _MODE_REGEX:
		var rx := RegEx.new()
		if rx.compile(query) != OK:
			return _format_error("Invalid regex: %s" % query)
		for i in range(history.size()):
			if rx.search(history[i]) != null:
				matches.append(i)
	else:
		for i in range(history.size()):
			if history[i].contains(query):
				matches.append(i)

	_last_query = query
	_last_mode = mode
	_last_matches = matches
	_cursor = 0 if not matches.is_empty() else -1

	if matches.is_empty():
		return "No matches for %s (searched %s line(s))" % [
			_color_path(query),
			_color_number(str(history.size())),
		]
	return _render_current()

func _render_current() -> String:
	var history := _get_history()
	if _cursor < 0 or _cursor >= _last_matches.size():
		return _format_error("Cursor out of range.")
	var line_idx: int = _last_matches[_cursor]
	if line_idx < 0 or line_idx >= history.size():
		return _format_error("History changed since last search; re-run find.")

	var start_idx: int = max(0, line_idx - _CONTEXT_LINES)
	var end_idx: int = min(history.size() - 1, line_idx + _CONTEXT_LINES)

	var out: PackedStringArray = []
	out.append("Match %s/%s at line %s of %s for %s" % [
		_color_number(str(_cursor + 1)),
		_color_number(str(_last_matches.size())),
		_color_number(str(line_idx + 1)),
		_color_number(str(history.size())),
		_color_path(_last_query),
	])
	for i in range(start_idx, end_idx + 1):
		var marker: String = ">" if i == line_idx else " "
		var gutter := "[color=%s]%s %s[/color]" % [_COLOR_DIM, marker, str(i + 1).pad_zeros(4)]
		out.append("%s  %s" % [gutter, _highlight(history[i])])
	return "\n".join(out)

func _highlight(line: String) -> String:
	if _last_query.is_empty():
		return line
	if _last_mode == _MODE_REGEX:
		return _highlight_regex(line)
	return _highlight_text(line)

func _highlight_text(line: String) -> String:
	var out: String = ""
	var idx: int = 0
	var qlen: int = _last_query.length()
	while idx < line.length():
		var hit: int = line.find(_last_query, idx)
		if hit == -1:
			out += line.substr(idx, line.length() - idx)
			break
		out += line.substr(idx, hit - idx)
		out += _wrap_highlight(line.substr(hit, qlen))
		idx = hit + qlen
	return out

func _highlight_regex(line: String) -> String:
	var rx := RegEx.new()
	if rx.compile(_last_query) != OK:
		return line
	var matches := rx.search_all(line)
	if matches.is_empty():
		return line
	var out: String = ""
	var pos: int = 0
	for m in matches:
		var s: int = m.get_start()
		var e: int = m.get_end()
		if s < pos or e <= s:
			continue
		out += line.substr(pos, s - pos)
		out += _wrap_highlight(line.substr(s, e - s))
		pos = e
	out += line.substr(pos, line.length() - pos)
	return out

func _wrap_highlight(s: String) -> String:
	return "[bgcolor=%s][color=%s]%s[/color][/bgcolor]" % [_HIGHLIGHT_BG, _HIGHLIGHT_FG, s]

func _get_history() -> Array[String]:
	var out: Array[String] = []
	if _core and _core.has_method("get_history"):
		var raw: Variant = _core.get_history()
		if raw is Array:
			for v in (raw as Array):
				out.append(str(v))
	return out

func _join_args(args: Array) -> String:
	var parts: PackedStringArray = []
	for a in args:
		parts.append(str(a))
	return " ".join(parts).strip_edges()

#endregion

#region Formatting helpers

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

#endregion

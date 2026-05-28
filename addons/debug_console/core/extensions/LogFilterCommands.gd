@tool
class_name DebugConsoleLogFilterCommands extends RefCounted

# Extension module - log capture, filtering, and search.
# Mirrors the structure of core/SceneCommands.gd: the orchestrator
# (BuiltInCommands.register_universal_commands) instantiates this once,
# holds a strong reference, and calls register_commands(registry, core)
# so the Callables here remain valid for the lifetime of the plugin.
#
# Other modules can push log entries into this module via the public
# capture(level, msg) method. Entries are stored in a bounded ring
# buffer; filter/exclude regexes and the minimum severity threshold
# control which entries are retained.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_DIM := "#808080"

const _BUFFER_CAP: int = 5000
const _DEFAULT_TAIL: int = 50
const _DEFAULT_GREP_LIMIT: int = 100

const LEVEL_OFF: int = 0
const LEVEL_ERROR: int = 1
const LEVEL_WARN: int = 2
const LEVEL_INFO: int = 3
const LEVEL_DEBUG: int = 4
const LEVEL_TRACE: int = 5

const _LEVEL_NAMES: PackedStringArray = ["off", "error", "warn", "info", "debug", "trace"]

var _registry: Node
var _core: Node

var _filters: Array = []
var _excludes: Array = []
var _min_level: int = LEVEL_INFO
var _buffer: Array = []

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("log_level", _cmd_log_level, "Set the minimum captured severity: log_level <off|error|warn|info|debug|trace>", "both")
	_registry.register_command("log_filter_add", _cmd_log_filter_add, "Only retain log lines matching <regex>: log_filter_add <regex>", "both")
	_registry.register_command("log_filter_remove", _cmd_log_filter_remove, "Remove a previously added include regex: log_filter_remove <regex>", "both")
	_registry.register_command("log_filter_clear", _cmd_log_filter_clear, "Clear all include and exclude regex filters: log_filter_clear", "both")
	_registry.register_command("log_exclude_add", _cmd_log_exclude_add, "Drop log lines matching <regex>: log_exclude_add <regex>", "both")
	_registry.register_command("log_exclude_remove", _cmd_log_exclude_remove, "Remove a previously added exclude regex: log_exclude_remove <regex>", "both")
	_registry.register_command("log_grep", _cmd_log_grep, "Search captured log entries by regex: log_grep <regex> [limit]", "both")
	_registry.register_command("log_tail", _cmd_log_tail, "Print the last n captured log entries: log_tail [n]", "both")

#region Public capture API

func capture(level: int, msg: String) -> void:
	if _min_level <= LEVEL_OFF:
		return
	if level <= LEVEL_OFF or level > _min_level:
		return
	if not _passes_filters(msg):
		return
	var entry: Dictionary = {
		"level": level,
		"msg": msg,
		"ts": Time.get_unix_time_from_system(),
	}
	_buffer.append(entry)
	if _buffer.size() > _BUFFER_CAP:
		var overflow: int = _buffer.size() - _BUFFER_CAP
		_buffer = _buffer.slice(overflow)

#endregion

#region Command implementations

func _cmd_log_level(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_success("log_level = %s" % _color_path(_level_name(_min_level)))
	var name: String = str(args[0]).strip_edges().to_lower()
	var level: int = _parse_level(name)
	if level < 0:
		return _format_error("Unknown level '%s' (expected off|error|warn|info|debug|trace)" % name)
	_min_level = level
	return _format_success("log_level set to %s" % _color_path(_level_name(level)))

func _cmd_log_filter_add(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: log_filter_add <regex>")
	var pattern: String = str(args[0])
	if _find_regex_index(_filters, pattern) != -1:
		return _format_error("Filter already present: %s" % pattern)
	var rx := RegEx.new()
	var err: int = rx.compile(pattern)
	if err != OK:
		return _format_error("Invalid regex: %s" % pattern)
	_filters.append(rx)
	return _format_success("Added include filter %s (%s active)" % [_color_path(pattern), _color_number(str(_filters.size()))])

func _cmd_log_filter_remove(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: log_filter_remove <regex>")
	var pattern: String = str(args[0])
	var idx: int = _find_regex_index(_filters, pattern)
	if idx == -1:
		return _format_error("No matching filter: %s" % pattern)
	_filters.remove_at(idx)
	return _format_success("Removed include filter %s (%s active)" % [_color_path(pattern), _color_number(str(_filters.size()))])

func _cmd_log_filter_clear(args: Array, piped_input: String = "") -> String:
	var total: int = _filters.size() + _excludes.size()
	_filters.clear()
	_excludes.clear()
	return _format_success("Cleared %s regex filters" % _color_number(str(total)))

func _cmd_log_exclude_add(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: log_exclude_add <regex>")
	var pattern: String = str(args[0])
	if _find_regex_index(_excludes, pattern) != -1:
		return _format_error("Exclude already present: %s" % pattern)
	var rx := RegEx.new()
	var err: int = rx.compile(pattern)
	if err != OK:
		return _format_error("Invalid regex: %s" % pattern)
	_excludes.append(rx)
	return _format_success("Added exclude filter %s (%s active)" % [_color_path(pattern), _color_number(str(_excludes.size()))])

func _cmd_log_exclude_remove(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: log_exclude_remove <regex>")
	var pattern: String = str(args[0])
	var idx: int = _find_regex_index(_excludes, pattern)
	if idx == -1:
		return _format_error("No matching exclude: %s" % pattern)
	_excludes.remove_at(idx)
	return _format_success("Removed exclude filter %s (%s active)" % [_color_path(pattern), _color_number(str(_excludes.size()))])

func _cmd_log_grep(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: log_grep <regex> [limit]")
	var pattern: String = str(args[0])
	var limit: int = _DEFAULT_GREP_LIMIT
	if args.size() > 1:
		var parsed: int = int(str(args[1]).strip_edges())
		if parsed > 0:
			limit = parsed
	var rx := RegEx.new()
	var err: int = rx.compile(pattern)
	if err != OK:
		return _format_error("Invalid regex: %s" % pattern)
	if _buffer.is_empty():
		return _format_success("(log buffer empty)")

	var matches: Array = []
	for entry in _buffer:
		var msg: String = str(entry.get("msg", ""))
		if rx.search(msg) != null:
			matches.append(entry)

	if matches.is_empty():
		return _format_success("No matches for /%s/ in %s entries" % [pattern, _color_number(str(_buffer.size()))])

	var start: int = max(0, matches.size() - limit)
	var slice: Array = matches.slice(start)
	var header: String = "Matched %s of %s entries (showing last %s):" % [
		_color_number(str(matches.size())),
		_color_number(str(_buffer.size())),
		_color_number(str(slice.size())),
	]
	return header + "\n" + _format_entries(slice)

func _cmd_log_tail(args: Array, piped_input: String = "") -> String:
	var count: int = _DEFAULT_TAIL
	if not args.is_empty():
		var parsed: int = int(str(args[0]).strip_edges())
		if parsed > 0:
			count = parsed
	if _buffer.is_empty():
		return _format_success("(log buffer empty)")
	var start: int = max(0, _buffer.size() - count)
	var slice: Array = _buffer.slice(start)
	var header: String = "Last %s of %s entries:" % [
		_color_number(str(slice.size())),
		_color_number(str(_buffer.size())),
	]
	return header + "\n" + _format_entries(slice)

#endregion

#region Helpers

func _passes_filters(msg: String) -> bool:
	for rx in _excludes:
		if rx is RegEx and (rx as RegEx).search(msg) != null:
			return false
	if _filters.is_empty():
		return true
	for rx in _filters:
		if rx is RegEx and (rx as RegEx).search(msg) != null:
			return true
	return false

func _find_regex_index(list: Array, pattern: String) -> int:
	for i in list.size():
		var rx = list[i]
		if rx is RegEx and (rx as RegEx).get_pattern() == pattern:
			return i
	return -1

func _parse_level(name: String) -> int:
	var idx: int = _LEVEL_NAMES.find(name)
	return idx

func _level_name(level: int) -> String:
	if level < 0 or level >= _LEVEL_NAMES.size():
		return "unknown"
	return _LEVEL_NAMES[level]

func _format_entries(entries: Array) -> String:
	var lines: PackedStringArray = []
	for entry in entries:
		var level: int = int(entry.get("level", LEVEL_INFO))
		var msg: String = str(entry.get("msg", ""))
		var ts: float = float(entry.get("ts", 0.0))
		var ts_str: String = "[color=%s]%s[/color]" % [_COLOR_DIM, _format_timestamp(ts)]
		var lvl_str: String = "[color=%s]%-5s[/color]" % [_level_color(level), _level_name(level).to_upper()]
		lines.append("%s %s %s" % [ts_str, lvl_str, msg])
	return "\n".join(lines)

func _format_timestamp(ts: float) -> String:
	if ts <= 0.0:
		return "--:--:--"
	var dt: Dictionary = Time.get_time_dict_from_unix_time(int(ts))
	return "%02d:%02d:%02d" % [int(dt.get("hour", 0)), int(dt.get("minute", 0)), int(dt.get("second", 0))]

func _level_color(level: int) -> String:
	match level:
		LEVEL_ERROR: return _COLOR_ERROR
		LEVEL_WARN: return _COLOR_NUMBER
		LEVEL_INFO: return _COLOR_SUCCESS
		LEVEL_DEBUG: return _COLOR_PATH
		LEVEL_TRACE: return _COLOR_DIM
		_: return _COLOR_DIM

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

#endregion

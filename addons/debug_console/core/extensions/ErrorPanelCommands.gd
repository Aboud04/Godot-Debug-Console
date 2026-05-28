@tool
class_name DebugConsoleErrorPanelCommands extends RefCounted

# Captured-error panel module. Other modules push entries via capture(level, msg);
# this module owns the in-memory ring buffer and exposes 8 console commands for
# querying, filtering, grouping, persisting and jumping into the editor.
#
# Source resolution is best-effort via get_stack() (debug builds only). When
# unavailable the entry still records level/msg/ts so the panel stays useful in
# exported builds.
#
# capture() also forwards a formatted line to DebugCore.print_to_console (when
# that method exists) so captured errors surface in the console UI alongside
# the user's own output. Tests rely on that hook to assert wiring.

const _COLOR_ERROR := "#FF4444"
const _COLOR_WARN := "#F7DC6F"
const _COLOR_INFO := "#5FBEE0"
const _COLOR_DEBUG := "#AAAAAA"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_DIM := "#888888"

const _MAX_ENTRIES := 500
const _GROUP_PREFIX_LEN := 40

var _registry: Node
var _core: Node
var _errors: Array[Dictionary] = []

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("errors_show", _cmd_errors_show, "Show the last N captured errors: errors_show [limit=20]", "both")
	_registry.register_command("errors_clear", _cmd_errors_clear, "Clear the captured-error buffer: errors_clear", "both")
	_registry.register_command("errors_filter", _cmd_errors_filter, "Filter captured errors by substring (case-insensitive): errors_filter <substring>", "both")
	_registry.register_command("errors_grep", _cmd_errors_grep, "Filter captured errors by regex: errors_grep <regex>", "both")
	_registry.register_command("errors_save", _cmd_errors_save, "Save captured errors as JSON: errors_save <res://path.json>", "both")
	_registry.register_command("errors_count", _cmd_errors_count, "Count captured errors, broken down by level: errors_count", "both")
	_registry.register_command("errors_group", _cmd_errors_group, "Group captured errors by message prefix with counts: errors_group", "both")
	_registry.register_command("errors_jump", _cmd_errors_jump, "Emit a clickable [url=...] meta for an entry's source: errors_jump <index>", "both")

#region Public API

func capture(level: String, msg: String) -> void:
	var lvl := level.strip_edges().to_lower()
	if lvl.is_empty():
		lvl = "error"
	var entry: Dictionary = {
		"level": lvl,
		"msg": msg,
		"ts": Time.get_unix_time_from_system(),
		"source": _resolve_caller_source(),
	}
	_errors.append(entry)
	if _errors.size() > _MAX_ENTRIES:
		_errors = _errors.slice(_errors.size() - _MAX_ENTRIES)
	_echo_to_console(entry)

#endregion

#region Command implementations

func _cmd_errors_show(args: Array, _piped_input: String = "") -> String:
	if _errors.is_empty():
		return _format_dim("No captured errors.")
	var limit: int = 20
	if args.size() > 0:
		var raw := str(args[0]).strip_edges()
		if not raw.is_valid_int():
			return _format_error("Usage: errors_show [limit]")
		limit = max(1, raw.to_int())
	var start: int = max(0, _errors.size() - limit)
	var lines: PackedStringArray = []
	for i in range(start, _errors.size()):
		lines.append(_format_entry(i, _errors[i]))
	return "\n".join(lines)

func _cmd_errors_clear(_args: Array, _piped_input: String = "") -> String:
	var removed: int = _errors.size()
	_errors.clear()
	return _format_success("Cleared %s captured errors." % _color_number(str(removed)))

func _cmd_errors_filter(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: errors_filter <substring>")
	var needle := str(args[0]).to_lower()
	var lines: PackedStringArray = []
	for i in _errors.size():
		var entry: Dictionary = _errors[i]
		if str(entry.get("msg", "")).to_lower().find(needle) != -1:
			lines.append(_format_entry(i, entry))
	if lines.is_empty():
		return _format_dim("No matches for substring: %s" % needle)
	return "\n".join(lines)

func _cmd_errors_grep(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: errors_grep <regex>")
	var pattern := str(args[0])
	var re := RegEx.new()
	if re.compile(pattern) != OK:
		return _format_error("Invalid regex: %s" % pattern)
	var lines: PackedStringArray = []
	for i in _errors.size():
		var entry: Dictionary = _errors[i]
		if re.search(str(entry.get("msg", ""))) != null:
			lines.append(_format_entry(i, entry))
	if lines.is_empty():
		return _format_dim("No matches for regex: %s" % pattern)
	return "\n".join(lines)

func _cmd_errors_save(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: errors_save <res://path.json>")
	var path := str(args[0]).strip_edges()
	if not (path.begins_with("res://") or path.begins_with("user://")):
		return _format_error("Path must start with res:// or user://: %s" % path)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if not file:
		return _format_error("Failed to open: %s (err=%s)" % [path, FileAccess.get_open_error()])
	file.store_string(JSON.stringify(_errors, "  "))
	file.close()
	return _format_success("Saved %s entries -> %s" % [_color_number(str(_errors.size())), _color_path(path)])

func _cmd_errors_count(_args: Array, _piped_input: String = "") -> String:
	var by_level: Dictionary = {}
	for entry in _errors:
		var lvl := str(entry.get("level", "error"))
		by_level[lvl] = int(by_level.get(lvl, 0)) + 1
	var parts: PackedStringArray = ["Total: %s" % _color_number(str(_errors.size()))]
	var levels: Array = by_level.keys()
	levels.sort()
	for lvl in levels:
		parts.append("%s=%s" % [_colorize_level(lvl), _color_number(str(by_level[lvl]))])
	return " ".join(parts)

func _cmd_errors_group(_args: Array, _piped_input: String = "") -> String:
	if _errors.is_empty():
		return _format_dim("No captured errors.")
	var buckets: Dictionary = {}
	for entry in _errors:
		var msg := str(entry.get("msg", ""))
		var prefix: String = msg.substr(0, min(msg.length(), _GROUP_PREFIX_LEN))
		buckets[prefix] = int(buckets.get(prefix, 0)) + 1
	var rows: Array = []
	for prefix in buckets.keys():
		rows.append({"prefix": prefix, "count": int(buckets[prefix])})
	rows.sort_custom(func(a, b): return int(a["count"]) > int(b["count"]))
	var lines: PackedStringArray = []
	for row in rows:
		lines.append("%s × %s" % [_color_number(str(row["count"]).pad_zeros(3)), row["prefix"]])
	return "\n".join(lines)

func _cmd_errors_jump(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: errors_jump <index>")
	var raw := str(args[0]).strip_edges()
	if not raw.is_valid_int():
		return _format_error("Index must be an integer: %s" % raw)
	var idx: int = raw.to_int()
	if idx < 0 or idx >= _errors.size():
		return _format_error("Index out of range [0..%d]: %d" % [_errors.size() - 1, idx])
	var entry: Dictionary = _errors[idx]
	var source := str(entry.get("source", "")).strip_edges()
	if source.is_empty():
		return _format_error("Entry #%d has no source to jump to." % idx)
	var msg := str(entry.get("msg", ""))
	return "[color=%s]#%d[/color] [url=%s]%s[/url] %s" % [
		_COLOR_DIM, idx, source, _color_path(source), msg,
	]

#endregion

#region Helpers

func _resolve_caller_source() -> String:
	if not OS.is_debug_build():
		return ""
	var stack: Array = get_stack()
	# Frame 0 is this helper, frame 1 is capture(), frame 2+ is the original caller.
	for i in range(2, stack.size()):
		var frame: Dictionary = stack[i]
		var src := str(frame.get("source", ""))
		if src.is_empty():
			continue
		if src.ends_with("/ErrorPanelCommands.gd"):
			continue
		return "%s:%d" % [src, int(frame.get("line", 0))]
	if stack.size() > 0:
		var f: Dictionary = stack[stack.size() - 1]
		return "%s:%d" % [str(f.get("source", "")), int(f.get("line", 0))]
	return ""

func _echo_to_console(entry: Dictionary) -> void:
	if not _core or not _core.has_method("print_to_console"):
		return
	var line := "[%s] %s" % [_colorize_level(str(entry.get("level", "error"))), str(entry.get("msg", ""))]
	_core.call("print_to_console", line)

func _format_entry(idx: int, entry: Dictionary) -> String:
	var ts_unix: float = float(entry.get("ts", 0.0))
	var ts_str := _format_ts(ts_unix)
	var lvl := _colorize_level(str(entry.get("level", "error")))
	var msg := str(entry.get("msg", ""))
	var source := str(entry.get("source", ""))
	var trailer := ""
	if not source.is_empty():
		trailer = " [color=%s](%s)[/color]" % [_COLOR_DIM, source]
	return "[color=%s]#%s[/color] [color=%s]%s[/color] [%s] %s%s" % [
		_COLOR_DIM, str(idx).pad_zeros(3), _COLOR_DIM, ts_str, lvl, msg, trailer,
	]

func _format_ts(unix_seconds: float) -> String:
	if unix_seconds <= 0.0:
		return "--:--:--"
	var dt: Dictionary = Time.get_time_dict_from_unix_time(int(unix_seconds))
	return "%02d:%02d:%02d" % [int(dt.get("hour", 0)), int(dt.get("minute", 0)), int(dt.get("second", 0))]

func _colorize_level(level: String) -> String:
	var color := _COLOR_ERROR
	match level:
		"warn", "warning":
			color = _COLOR_WARN
		"info":
			color = _COLOR_INFO
		"debug":
			color = _COLOR_DEBUG
		_:
			color = _COLOR_ERROR
	return "[color=%s]%s[/color]" % [color, level.to_upper()]

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _format_dim(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_DIM, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

#endregion

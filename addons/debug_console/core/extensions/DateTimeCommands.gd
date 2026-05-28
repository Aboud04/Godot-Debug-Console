@tool
class_name DebugConsoleDateTimeCommands extends RefCounted

# Date/time utilities for log correlation and timestamps. Thin wrappers over
# the engine's `Time` singleton plus a small format/parse layer so users can
# stamp logs, normalize ISO 8601 strings, compute deltas between events, and
# track session uptime from the console without writing a script.
#
# Mirrors the SceneCommands.gd pattern: orchestrator instantiates one of these,
# holds a strong reference, and calls register_commands(registry, core). All
# Callables are bound to this strong-referenced instance so they stay valid
# for the lifetime of the plugin.
#
# Every command runs in both editor and game context - the `Time` singleton is
# globally available and these calls are read-only, so there is no scene-state
# concern that would force a single context.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_MUTED := "#888888"

var _registry: Node
var _core: Node

# Captured at module instantiation so dt_session_start reflects when the
# console wired this command set up, regardless of when the user first calls
# it. _session_start_ticks_msec lets us report monotonic elapsed time even
# if the system wall-clock is adjusted mid-session.
var _session_start_unix: float = 0.0
var _session_start_ticks_msec: int = 0

func _init() -> void:
	_session_start_unix = Time.get_unix_time_from_system()
	_session_start_ticks_msec = Time.get_ticks_msec()

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("dt_now", _cmd_dt_now, "Current datetime, default ISO 8601 UTC: dt_now [format]", "both")
	_registry.register_command("dt_parse", _cmd_dt_parse, "Parse an ISO 8601 string to normalized form + Unix ts: dt_parse <iso_string>", "both")
	_registry.register_command("dt_format", _cmd_dt_format, "Format a Unix timestamp: dt_format <unix_ts> [format]", "both")
	_registry.register_command("dt_diff", _cmd_dt_diff, "Difference between two datetime strings (hr/min/sec): dt_diff <a> <b>", "both")
	_registry.register_command("dt_add", _cmd_dt_add, "Add amount of a unit to an ISO datetime: dt_add <iso> <amount> <unit>", "both")
	_registry.register_command("dt_unix", _cmd_dt_unix, "Current Unix timestamp (seconds + nanoseconds)", "both")
	_registry.register_command("dt_uptime", _cmd_dt_uptime, "Process uptime via Time.get_ticks_msec()", "both")
	_registry.register_command("dt_session_start", _cmd_dt_session_start, "When this console session started (module instantiation)", "both")

#region Command implementations

func _cmd_dt_now(args: Array, _piped_input: String = "") -> String:
	var fmt: String = "iso"
	if not args.is_empty():
		fmt = str(args[0]).strip_edges()
		if fmt.is_empty():
			fmt = "iso"
	var use_utc: bool = not (fmt == "iso_local" or fmt == "local")
	var dict: Dictionary = Time.get_datetime_dict_from_system(use_utc)
	var formatted: String = _format_datetime(dict, fmt, use_utc)
	return _format_success(_color_path(formatted))

func _cmd_dt_parse(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: dt_parse <iso_string>")
	var raw: String = str(args[0]).strip_edges()
	if raw.is_empty():
		return _format_error("Usage: dt_parse <iso_string>")
	var normalized_input: String = _normalize_iso(raw)
	var unix_f: float = Time.get_unix_time_from_datetime_string(normalized_input)
	var unix: int = int(unix_f)
	if unix == 0 and not _looks_like_epoch(normalized_input):
		return _format_error("Could not parse as ISO 8601: %s" % raw)
	var dict: Dictionary = Time.get_datetime_dict_from_unix_time(unix)
	var iso: String = _format_datetime(dict, "iso", true)
	var lines: PackedStringArray = PackedStringArray()
	lines.append("input:      %s" % _color_path(raw))
	lines.append("normalized: %s" % _color_path(iso))
	lines.append("unix:       %s" % _color_number(str(unix)))
	return "\n".join(lines)

func _cmd_dt_format(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: dt_format <unix_ts> [format]")
	var ts_str: String = str(args[0]).strip_edges()
	if not (ts_str.is_valid_int() or ts_str.is_valid_float()):
		return _format_error("Not a Unix timestamp: %s" % ts_str)
	var unix: float = ts_str.to_float()
	var fmt: String = "iso"
	if args.size() > 1:
		fmt = str(args[1]).strip_edges()
		if fmt.is_empty():
			fmt = "iso"
	var use_utc: bool = not (fmt == "iso_local" or fmt == "local")
	var dict: Dictionary = Time.get_datetime_dict_from_unix_time(int(unix)) if use_utc \
		else _local_dict_from_unix(unix)
	var formatted: String = _format_datetime(dict, fmt, use_utc)
	return _format_success(_color_path(formatted))

func _cmd_dt_diff(args: Array, _piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: dt_diff <a> <b>")
	var a_str: String = str(args[0]).strip_edges()
	var b_str: String = str(args[1]).strip_edges()
	var a_unix: float = _to_unix_seconds(a_str)
	var b_unix: float = _to_unix_seconds(b_str)
	if is_nan(a_unix):
		return _format_error("Could not parse: %s" % a_str)
	if is_nan(b_unix):
		return _format_error("Could not parse: %s" % b_str)
	var delta: float = b_unix - a_unix
	var sign_str: String = "-" if delta < 0.0 else ""
	var abs_delta: float = absf(delta)
	var total_secs: int = int(abs_delta)
	var hours: int = total_secs / 3600
	var minutes: int = (total_secs % 3600) / 60
	var seconds: int = total_secs % 60
	var frac_ms: int = int(round((abs_delta - float(total_secs)) * 1000.0))
	var pretty: String = "%s%dh %02dm %02ds %03dms" % [sign_str, hours, minutes, seconds, frac_ms]
	var lines: PackedStringArray = PackedStringArray()
	lines.append("a:     %s" % _color_path(a_str))
	lines.append("b:     %s" % _color_path(b_str))
	lines.append("delta: %s" % _color_number(pretty))
	lines.append("total: %s seconds" % _color_number(String.num(delta, 3)))
	return "\n".join(lines)

func _cmd_dt_add(args: Array, _piped_input: String = "") -> String:
	if args.size() < 3:
		return _format_error("Usage: dt_add <iso> <amount> <unit>")
	var iso: String = str(args[0]).strip_edges()
	var amount_str: String = str(args[1]).strip_edges()
	var unit: String = str(args[2]).strip_edges().to_lower()
	if not (amount_str.is_valid_int() or amount_str.is_valid_float()):
		return _format_error("Amount must be numeric: %s" % amount_str)
	var amount: float = amount_str.to_float()
	var seconds: float = _unit_to_seconds(amount, unit)
	if is_nan(seconds):
		return _format_error("Unknown unit '%s' (use ms, s/sec, m/min, h/hr, d/day, w/week)" % unit)
	var base_unix: float = _to_unix_seconds(iso)
	if is_nan(base_unix):
		return _format_error("Could not parse: %s" % iso)
	var result_unix: int = int(base_unix + seconds)
	var dict: Dictionary = Time.get_datetime_dict_from_unix_time(result_unix)
	var out_iso: String = _format_datetime(dict, "iso", true)
	var lines: PackedStringArray = PackedStringArray()
	lines.append("base:   %s" % _color_path(iso))
	lines.append("offset: %s %s" % [_color_number(amount_str), _color_muted(unit)])
	lines.append("result: %s" % _color_path(out_iso))
	lines.append("unix:   %s" % _color_number(str(result_unix)))
	return "\n".join(lines)

func _cmd_dt_unix(_args: Array, _piped_input: String = "") -> String:
	var now_float: float = Time.get_unix_time_from_system()
	var seconds: int = int(floor(now_float))
	var nanos: int = int(round((now_float - float(seconds)) * 1_000_000_000.0))
	if nanos >= 1_000_000_000:
		seconds += 1
		nanos -= 1_000_000_000
	var lines: PackedStringArray = PackedStringArray()
	lines.append("seconds: %s" % _color_number(str(seconds)))
	lines.append("nanos:   %s" % _color_number(str(nanos)))
	lines.append("float:   %s" % _color_number(String.num(now_float, 6)))
	return "\n".join(lines)

func _cmd_dt_uptime(_args: Array, _piped_input: String = "") -> String:
	var ticks_ms: int = Time.get_ticks_msec()
	var total_secs: int = ticks_ms / 1000
	var ms: int = ticks_ms % 1000
	var hours: int = total_secs / 3600
	var minutes: int = (total_secs % 3600) / 60
	var seconds: int = total_secs % 60
	var pretty: String = "%dh %02dm %02ds %03dms" % [hours, minutes, seconds, ms]
	var lines: PackedStringArray = PackedStringArray()
	lines.append("ticks_msec: %s" % _color_number(str(ticks_ms)))
	lines.append("uptime:     %s" % _color_number(pretty))
	return "\n".join(lines)

func _cmd_dt_session_start(_args: Array, _piped_input: String = "") -> String:
	var start_unix: int = int(_session_start_unix)
	var dict: Dictionary = Time.get_datetime_dict_from_unix_time(start_unix)
	var iso: String = _format_datetime(dict, "iso", true)
	var session_ticks_ms: int = Time.get_ticks_msec() - _session_start_ticks_msec
	var total_secs: int = session_ticks_ms / 1000
	var ms: int = session_ticks_ms % 1000
	var hours: int = total_secs / 3600
	var minutes: int = (total_secs % 3600) / 60
	var seconds: int = total_secs % 60
	var elapsed: String = "%dh %02dm %02ds %03dms" % [hours, minutes, seconds, ms]
	var lines: PackedStringArray = PackedStringArray()
	lines.append("started:  %s" % _color_path(iso))
	lines.append("unix:     %s" % _color_number(str(start_unix)))
	lines.append("elapsed:  %s" % _color_number(elapsed))
	return "\n".join(lines)

#endregion

#region Formatting / parsing helpers

func _format_datetime(dict: Dictionary, fmt: String, is_utc: bool) -> String:
	var year: int = int(dict.get("year", 0))
	var month: int = int(dict.get("month", 0))
	var day: int = int(dict.get("day", 0))
	var hour: int = int(dict.get("hour", 0))
	var minute: int = int(dict.get("minute", 0))
	var second: int = int(dict.get("second", 0))
	match fmt:
		"iso":
			return "%04d-%02d-%02dT%02d:%02d:%02dZ" % [year, month, day, hour, minute, second]
		"iso_local", "local":
			return "%04d-%02d-%02dT%02d:%02d:%02d" % [year, month, day, hour, minute, second]
		"date":
			return "%04d-%02d-%02d" % [year, month, day]
		"time":
			return "%02d:%02d:%02d" % [hour, minute, second]
		"log":
			return "%04d-%02d-%02d %02d:%02d:%02d" % [year, month, day, hour, minute, second]
		"unix":
			return str(int(Time.get_unix_time_from_datetime_dict(dict)))
		_:
			# Treat fmt as a printf-style template with %Y %m %d %H %M %S %z tokens.
			var out: String = fmt
			out = out.replace("%Y", "%04d" % year)
			out = out.replace("%m", "%02d" % month)
			out = out.replace("%d", "%02d" % day)
			out = out.replace("%H", "%02d" % hour)
			out = out.replace("%M", "%02d" % minute)
			out = out.replace("%S", "%02d" % second)
			out = out.replace("%z", "Z" if is_utc else "")
			return out

func _normalize_iso(raw: String) -> String:
	var s: String = raw.strip_edges()
	# Time.get_unix_time_from_datetime_string does not accept the trailing 'Z'
	# zone designator in every engine build; strip it and tolerate the common
	# "+00:00" / "-00:00" tail so callers can paste real ISO 8601.
	if s.ends_with("Z"):
		s = s.substr(0, s.length() - 1)
	if s.length() >= 6:
		var tail: String = s.substr(s.length() - 6, 6)
		if tail == "+00:00" or tail == "-00:00":
			s = s.substr(0, s.length() - 6)
	# Allow space separator (common log format) as well as 'T'.
	if s.contains(" ") and not s.contains("T"):
		s = s.replace(" ", "T")
	return s

func _to_unix_seconds(raw: String) -> float:
	var s: String = raw.strip_edges()
	if s.is_empty():
		return NAN
	if s.is_valid_int() or s.is_valid_float():
		return s.to_float()
	var normalized_input: String = _normalize_iso(s)
	var unix_f: float = Time.get_unix_time_from_datetime_string(normalized_input)
	var unix: int = int(unix_f)
	if unix == 0 and not _looks_like_epoch(normalized_input):
		return NAN
	return float(unix)

func _looks_like_epoch(s: String) -> bool:
	# Distinguish a genuine 1970-01-01 result from a parse failure that also
	# returned 0. Anything starting with "1970-01-01" we accept as epoch.
	return s.begins_with("1970-01-01")

func _unit_to_seconds(amount: float, unit: String) -> float:
	match unit:
		"ms", "milli", "millis", "millisecond", "milliseconds":
			return amount / 1000.0
		"s", "sec", "secs", "second", "seconds":
			return amount
		"m", "min", "mins", "minute", "minutes":
			return amount * 60.0
		"h", "hr", "hrs", "hour", "hours":
			return amount * 3600.0
		"d", "day", "days":
			return amount * 86400.0
		"w", "wk", "week", "weeks":
			return amount * 604800.0
		_:
			return NAN

func _local_dict_from_unix(unix: float) -> Dictionary:
	# Approximate local-time conversion by offsetting from UTC by the current
	# system timezone bias (minutes). Avoids depending on engine version-
	# specific overloads of Time.get_datetime_dict_from_unix_time.
	var tz: Dictionary = Time.get_time_zone_from_system()
	var bias_sec: int = int(tz.get("bias", 0)) * 60
	return Time.get_datetime_dict_from_unix_time(int(unix) + bias_sec)

#endregion

#region Color helpers

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

func _color_muted(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_MUTED, s]

#endregion

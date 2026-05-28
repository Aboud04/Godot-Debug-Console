@tool
class_name DebugConsoleErrorGroupCommands extends RefCounted

# Tier 7 extension - clusters captured ERROR-level log messages by a normalized
# fingerprint (numbers + paths stripped) so recurring errors can be inspected
# in aggregate instead of as a noisy stream. The module subscribes to
# DebugCore.message_logged, keeps its own _groups dictionary, and exposes a
# small command surface. Mirrors the SceneCommands.gd pattern: RefCounted held
# by the orchestrator, register_commands(registry, core), shared color helpers.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_MUTED := "#888888"

const _MAX_EXAMPLES_PER_GROUP := 3
const _MAX_OCCURRENCES_PER_GROUP := 200
const _DEFAULT_TOP_N := 10

var _registry: Node
var _core: Node
var _groups: Dictionary = {}
var _listener: Callable
var _num_re: RegEx
var _path_re: RegEx
var _prefix_re: RegEx

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	_compile_regex()

	if _core and _core.has_signal("message_logged"):
		_listener = Callable(self, "_on_message_logged")
		if not _core.is_connected("message_logged", _listener):
			_core.connect("message_logged", _listener)

	if not _registry:
		return
	_registry.register_command("err_group", _cmd_err_group, "List captured error clusters with count and first-seen timestamp.", "both")
	_registry.register_command("err_group_clear", _cmd_err_group_clear, "Clear all captured error clusters.", "both")
	_registry.register_command("err_top", _cmd_err_top, "Show the top N most-frequent error clusters: err_top [n]", "both")
	_registry.register_command("err_unique", _cmd_err_unique, "Show one representative example per unique error fingerprint.", "both")
	_registry.register_command("err_diff", _cmd_err_diff, "List error clusters with occurrences since a unix timestamp: err_diff <since_ts>", "both")
	_registry.register_command("err_export", _cmd_err_export, "Write the grouped error data as JSON: err_export <res://path.json>", "both")

#region Signal capture

func _on_message_logged(message: String, level: String) -> void:
	if level != "ERROR":
		return
	var body := _strip_prefix(message)
	var fp := _fingerprint(body)
	var key: int = fp.hash()
	var now: float = Time.get_unix_time_from_system()

	var entry: Dictionary = _groups.get(key, {})
	if entry.is_empty():
		entry = {
			"fingerprint": fp,
			"first_seen": now,
			"last_seen": now,
			"count": 0,
			"examples": [],
			"occurrences": [],
		}
		_groups[key] = entry

	entry["count"] = int(entry["count"]) + 1
	entry["last_seen"] = now

	var examples: Array = entry["examples"]
	if examples.size() < _MAX_EXAMPLES_PER_GROUP:
		examples.append(message)

	var occurrences: Array = entry["occurrences"]
	occurrences.append(now)
	if occurrences.size() > _MAX_OCCURRENCES_PER_GROUP:
		occurrences = occurrences.slice(-_MAX_OCCURRENCES_PER_GROUP)
		entry["occurrences"] = occurrences

#endregion

#region Command implementations

func _cmd_err_group(_args: Array, _piped_input: String = "") -> String:
	if _groups.is_empty():
		return _format_muted("No errors captured.")
	var rows: Array = _sorted_entries_by_first_seen()
	var lines: Array[String] = []
	lines.append("[b]Error clusters[/b] (%s total)" % _color_number(str(rows.size())))
	for entry in rows:
		lines.append("%s  x%s  first=%s" % [
			_color_path(entry["fingerprint"]),
			_color_number(str(entry["count"])),
			_color_number(_format_ts(entry["first_seen"])),
		])
	return "\n".join(lines)

func _cmd_err_group_clear(_args: Array, _piped_input: String = "") -> String:
	var removed: int = _groups.size()
	_groups.clear()
	return _format_success("Cleared %d error cluster(s)." % removed)

func _cmd_err_top(args: Array, _piped_input: String = "") -> String:
	var n: int = _DEFAULT_TOP_N
	if args.size() > 0:
		var raw := str(args[0]).strip_edges()
		if raw.is_valid_int():
			n = max(1, raw.to_int())
	if _groups.is_empty():
		return _format_muted("No errors captured.")
	var rows: Array = _groups.values()
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["count"]) > int(b["count"])
	)
	var slice_count: int = min(n, rows.size())
	var lines: Array[String] = []
	lines.append("[b]Top %s error cluster(s)[/b]" % _color_number(str(slice_count)))
	for i in slice_count:
		var entry: Dictionary = rows[i]
		lines.append("%s. x%s  %s" % [
			_color_number(str(i + 1)),
			_color_number(str(entry["count"])),
			_color_path(entry["fingerprint"]),
		])
	return "\n".join(lines)

func _cmd_err_unique(_args: Array, _piped_input: String = "") -> String:
	if _groups.is_empty():
		return _format_muted("No errors captured.")
	var rows: Array = _sorted_entries_by_first_seen()
	var lines: Array[String] = []
	lines.append("[b]Unique errors[/b] (%s)" % _color_number(str(rows.size())))
	for entry in rows:
		var example: String = entry["fingerprint"]
		var examples: Array = entry["examples"]
		if examples.size() > 0:
			example = str(examples[0])
		lines.append("- %s" % example)
	return "\n".join(lines)

func _cmd_err_diff(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: err_diff <since_ts>")
	var raw := str(args[0]).strip_edges()
	if not (raw.is_valid_float() or raw.is_valid_int()):
		return _format_error("since_ts must be a unix timestamp (seconds).")
	var since: float = raw.to_float()
	if _groups.is_empty():
		return _format_muted("No errors captured.")
	var hits: Array = []
	for entry in _groups.values():
		var occurrences: Array = entry["occurrences"]
		var since_count: int = 0
		for ts in occurrences:
			if float(ts) >= since:
				since_count += 1
		if since_count > 0:
			hits.append({
				"fingerprint": entry["fingerprint"],
				"since_count": since_count,
				"total": int(entry["count"]),
				"last_seen": float(entry["last_seen"]),
			})
	if hits.is_empty():
		return _format_muted("No error occurrences since %s." % _format_ts(since))
	hits.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["since_count"]) > int(b["since_count"])
	)
	var lines: Array[String] = []
	lines.append("[b]Errors since %s[/b] (%s cluster(s))" % [
		_color_number(_format_ts(since)),
		_color_number(str(hits.size())),
	])
	for h in hits:
		lines.append("%s  +%s (of %s)  last=%s" % [
			_color_path(h["fingerprint"]),
			_color_number(str(h["since_count"])),
			_color_number(str(h["total"])),
			_color_number(_format_ts(h["last_seen"])),
		])
	return "\n".join(lines)

func _cmd_err_export(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: err_export <res://path.json>")
	var path := str(args[0]).strip_edges()
	if path.is_empty():
		return _format_error("Export path is empty.")

	var base_dir := path.get_base_dir()
	if not base_dir.is_empty() and base_dir != "res://" and base_dir != "user://":
		var ensure_result := DirAccess.make_dir_recursive_absolute(base_dir)
		if ensure_result != OK and ensure_result != ERR_ALREADY_EXISTS:
			return _format_error("Failed to create directory: %s" % base_dir)

	var payload: Dictionary = {
		"exported_at": Time.get_unix_time_from_system(),
		"group_count": _groups.size(),
		"groups": [],
	}
	var rows: Array = _sorted_entries_by_first_seen()
	for entry in rows:
		(payload["groups"] as Array).append({
			"fingerprint": entry["fingerprint"],
			"first_seen": float(entry["first_seen"]),
			"last_seen": float(entry["last_seen"]),
			"count": int(entry["count"]),
			"examples": (entry["examples"] as Array).duplicate(),
			"occurrences": (entry["occurrences"] as Array).duplicate(),
		})

	var file := FileAccess.open(path, FileAccess.WRITE)
	if not file:
		return _format_error("Failed to open file for write: %s (err=%d)" % [path, FileAccess.get_open_error()])
	file.store_string(JSON.stringify(payload, "  "))
	file.close()
	return _format_success("Exported %s cluster(s) to %s" % [
		_color_number(str(_groups.size())),
		_color_path(path),
	])

#endregion

#region Helpers

func _compile_regex() -> void:
	_num_re = RegEx.new()
	_num_re.compile("\\d+(?:\\.\\d+)?")
	_path_re = RegEx.new()
	# res://..., user://..., Windows-style C:\..., POSIX absolute paths.
	_path_re.compile("(?:res|user)://[^\\s\\]\\)]+|[A-Za-z]:[\\\\/][^\\s\\]\\)]+|/[\\w./-]+")
	_prefix_re = RegEx.new()
	_prefix_re.compile("^\\[\\d{2}:\\d{2}:\\d{2}\\]\\s*\\[[A-Z]+\\]\\s*")

func _strip_prefix(message: String) -> String:
	if _prefix_re == null:
		return message
	var m := _prefix_re.search(message)
	if m:
		return message.substr(m.get_end())
	return message

func _fingerprint(body: String) -> String:
	var s := body
	if _path_re:
		s = _path_re.sub(s, "<PATH>", true)
	if _num_re:
		s = _num_re.sub(s, "<N>", true)
	return s.strip_edges()

func _sorted_entries_by_first_seen() -> Array:
	var rows: Array = _groups.values()
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["first_seen"]) < float(b["first_seen"])
	)
	return rows

func _format_ts(unix_seconds: float) -> String:
	# Local wall-clock for readability; raw unix value still in the JSON export.
	return Time.get_datetime_string_from_unix_time(int(unix_seconds))

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

#endregion

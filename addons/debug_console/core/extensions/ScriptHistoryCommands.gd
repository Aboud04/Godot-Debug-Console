@tool
class_name DebugConsoleScriptHistoryCommands extends RefCounted

# Tier 6 extension - in-memory script versioning across the session.
# Modeled on SceneCommands.gd: the orchestrator instantiates one of these and
# holds a strong reference so the Callables stay valid. All snapshots live in
# this instance's _snapshots array and disappear when the session ends, which
# is intentional: this is a scratch undo-buffer, not a persistent VCS.
#
# Snapshot shape: {id: int, path: String, content: String, ts: int, tag: String}
#   - id        monotonic counter assigned on snap
#   - path      original res:// or user:// path of the captured file
#   - content   full text contents at capture time
#   - ts        Time.get_unix_time_from_system() at capture
#   - tag       optional user label (may be empty)

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_TAG := "#C39BD3"
const _COLOR_DIFF_ADD := "#7FE07F"
const _COLOR_DIFF_DEL := "#FF8080"

var _registry: Node
var _core: Node
var _snapshots: Array = []
var _next_id: int = 1

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("snap", _cmd_snap, "Snapshot a script's contents in memory: snap <res://path.gd> [tag]", "both")
	_registry.register_command("snaps", _cmd_snaps, "List in-memory snapshots, newest first: snaps [path_filter]", "both")
	_registry.register_command("snap_diff", _cmd_snap_diff, "Diff two snapshots by id: snap_diff <id_a> <id_b>", "both")
	_registry.register_command("snap_restore", _cmd_snap_restore, "Restore a snapshot's content to its original path: snap_restore <id>", "both")
	_registry.register_command("snap_drop", _cmd_snap_drop, "Drop a snapshot by id, or 'all' to clear them: snap_drop <id|all>", "both")
	_registry.register_command("snap_export_all", _cmd_snap_export_all, "Export every snapshot to JSON: snap_export_all <user://out.json>", "both")

#region Command implementations

func _cmd_snap(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: snap <res://path.gd> [tag]")
	var path := str(args[0]).strip_edges()
	var tag := str(args[1]).strip_edges() if args.size() > 1 else ""
	if path.is_empty():
		return _format_error("Snapshot path is empty")
	if not FileAccess.file_exists(path):
		return _format_error("File not found: %s" % path)

	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		return _format_error("Could not open %s (err=%d)" % [path, FileAccess.get_open_error()])
	var content := file.get_as_text()
	file.close()

	var snap := {
		"id": _next_id,
		"path": path,
		"content": content,
		"ts": int(Time.get_unix_time_from_system()),
		"tag": tag,
	}
	_next_id += 1
	_snapshots.append(snap)

	var summary := "Snapped #%s %s (%s bytes)" % [
		_color_number(str(snap["id"])),
		_color_path(path),
		_color_number(str(content.length())),
	]
	if not tag.is_empty():
		summary += " " + _color_tag("[" + tag + "]")
	return _format_success(summary)

func _cmd_snaps(args: Array, piped_input: String = "") -> String:
	var filter := str(args[0]).strip_edges() if not args.is_empty() else ""
	if _snapshots.is_empty():
		return _format_success("No snapshots yet. Use 'snap <res://path.gd> [tag]' to capture one.")

	var matches: Array = []
	for s in _snapshots:
		if filter.is_empty() or String(s["path"]).findn(filter) != -1:
			matches.append(s)
	if matches.is_empty():
		return _format_error("No snapshots match filter: %s" % filter)

	matches.sort_custom(func(a, b): return int(a["ts"]) > int(b["ts"]))

	var lines: PackedStringArray = []
	lines.append("%s snapshot(s):" % _color_number(str(matches.size())))
	for s in matches:
		var ts_str := _format_timestamp(int(s["ts"]))
		var line := "  #%-4s %s  %s  (%s bytes)" % [
			_color_number(str(s["id"])),
			ts_str,
			_color_path(str(s["path"])),
			_color_number(str(String(s["content"]).length())),
		]
		var tag := String(s["tag"])
		if not tag.is_empty():
			line += " " + _color_tag("[" + tag + "]")
		lines.append(line)
	return "\n".join(lines)

func _cmd_snap_diff(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: snap_diff <id_a> <id_b>")
	var id_a_str := str(args[0]).strip_edges()
	var id_b_str := str(args[1]).strip_edges()
	if not id_a_str.is_valid_int() or not id_b_str.is_valid_int():
		return _format_error("Snapshot ids must be integers")
	var a := _find_snapshot(id_a_str.to_int())
	var b := _find_snapshot(id_b_str.to_int())
	if a.is_empty():
		return _format_error("Snapshot not found: #%s" % id_a_str)
	if b.is_empty():
		return _format_error("Snapshot not found: #%s" % id_b_str)

	var a_lines: PackedStringArray = String(a["content"]).split("\n")
	var b_lines: PackedStringArray = String(b["content"]).split("\n")

	var lines: PackedStringArray = []
	lines.append("--- #%s %s" % [_color_number(str(a["id"])), _color_path(str(a["path"]))])
	lines.append("+++ #%s %s" % [_color_number(str(b["id"])), _color_path(str(b["path"]))])

	var max_len: int = max(a_lines.size(), b_lines.size())
	var i: int = 0
	var changed: int = 0
	while i < max_len:
		var la := a_lines[i] if i < a_lines.size() else null
		var lb := b_lines[i] if i < b_lines.size() else null
		if la == lb:
			i += 1
			continue
		if la != null:
			lines.append(_color_diff_del("- %4d  %s" % [i + 1, String(la)]))
		if lb != null:
			lines.append(_color_diff_add("+ %4d  %s" % [i + 1, String(lb)]))
		changed += 1
		i += 1

	if changed == 0:
		lines.append(_format_success("Snapshots are identical."))
	else:
		lines.append("%s line(s) differ." % _color_number(str(changed)))
	return "\n".join(lines)

func _cmd_snap_restore(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: snap_restore <id>")
	var id_str := str(args[0]).strip_edges()
	if not id_str.is_valid_int():
		return _format_error("Snapshot id must be an integer")
	var snap := _find_snapshot(id_str.to_int())
	if snap.is_empty():
		return _format_error("Snapshot not found: #%s" % id_str)

	var path := String(snap["path"])
	var content := String(snap["content"])
	var file := FileAccess.open(path, FileAccess.WRITE)
	if not file:
		return _format_error("Could not write %s (err=%d)" % [path, FileAccess.get_open_error()])
	file.store_string(content)
	file.close()

	if Engine.is_editor_hint() and path.begins_with("res://"):
		var fs := EditorInterface.get_resource_filesystem()
		if fs:
			fs.update_file(path)

	return _format_success("Restored #%s -> %s (%s bytes)" % [
		_color_number(str(snap["id"])),
		_color_path(path),
		_color_number(str(content.length())),
	])

func _cmd_snap_drop(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: snap_drop <id|all>")
	var target := str(args[0]).strip_edges().to_lower()
	if target == "all":
		var n: int = _snapshots.size()
		_snapshots.clear()
		_next_id = 1
		return _format_success("Dropped %s snapshot(s)." % _color_number(str(n)))
	if not target.is_valid_int():
		return _format_error("Snapshot id must be an integer or 'all'")
	var id := target.to_int()
	for i in range(_snapshots.size()):
		if int(_snapshots[i]["id"]) == id:
			var path := String(_snapshots[i]["path"])
			_snapshots.remove_at(i)
			return _format_success("Dropped #%s (%s)" % [_color_number(str(id)), _color_path(path)])
	return _format_error("Snapshot not found: #%s" % str(id))

func _cmd_snap_export_all(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: snap_export_all <user://out.json>")
	var out_path := str(args[0]).strip_edges()
	if out_path.is_empty():
		return _format_error("Export path is empty")

	var dir_part := out_path.get_base_dir()
	if not dir_part.is_empty() and not DirAccess.dir_exists_absolute(dir_part):
		var mk := DirAccess.make_dir_recursive_absolute(dir_part)
		if mk != OK:
			return _format_error("Could not create directory %s (err=%d)" % [dir_part, mk])

	var payload := {
		"exported_at": int(Time.get_unix_time_from_system()),
		"count": _snapshots.size(),
		"snapshots": _snapshots,
	}
	var file := FileAccess.open(out_path, FileAccess.WRITE)
	if not file:
		return _format_error("Could not write %s (err=%d)" % [out_path, FileAccess.get_open_error()])
	file.store_string(JSON.stringify(payload, "\t"))
	file.close()

	return _format_success("Exported %s snapshot(s) to %s" % [
		_color_number(str(_snapshots.size())),
		_color_path(out_path),
	])

#endregion

#region Helpers

func _find_snapshot(id: int) -> Dictionary:
	for s in _snapshots:
		if int(s["id"]) == id:
			return s
	return {}

func _format_timestamp(unix_ts: int) -> String:
	var dt := Time.get_datetime_dict_from_unix_time(unix_ts)
	return "%04d-%02d-%02d %02d:%02d:%02d" % [
		int(dt.get("year", 0)),
		int(dt.get("month", 0)),
		int(dt.get("day", 0)),
		int(dt.get("hour", 0)),
		int(dt.get("minute", 0)),
		int(dt.get("second", 0)),
	]

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

func _color_tag(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_TAG, s]

func _color_diff_add(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_DIFF_ADD, s]

func _color_diff_del(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_DIFF_DEL, s]

#endregion

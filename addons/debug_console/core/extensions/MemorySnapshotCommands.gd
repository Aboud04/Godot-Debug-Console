@tool
class_name DebugConsoleMemorySnapshotCommands extends RefCounted

# Memory snapshot extension. Captures Performance monitor values into named
# snapshots so a developer can compare two points in time (before/after a
# scene load, leak hunt, etc.) without leaving the console. Snapshots live
# in a static dictionary so they survive command invocations as long as the
# plugin instance is alive; the orchestrator (BuiltInCommands) holds the
# strong reference to this RefCounted instance.
#
# Registered under the standard "both" context so the commands work in both
# the editor and a running game build, mirroring the SceneCommands pattern.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_UP := "#FF6B6B"
const _COLOR_DOWN := "#7CFC8C"
const _COLOR_DIM := "#888888"

const _BASELINE_KEY := "__baseline__"

static var _snapshots: Dictionary = {}

var _registry: Node
var _core: Node

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("mem_snap", _cmd_mem_snap, "Capture a memory snapshot: mem_snap [name]", "both")
	_registry.register_command("mem_list", _cmd_mem_list, "List saved memory snapshots: mem_list", "both")
	_registry.register_command("mem_diff", _cmd_mem_diff, "Delta between two snapshots: mem_diff <a> <b>", "both")
	_registry.register_command("mem_drop", _cmd_mem_drop, "Delete a snapshot or all: mem_drop <name|all>", "both")
	_registry.register_command("mem_baseline", _cmd_mem_baseline, "Capture the current state as the baseline: mem_baseline", "both")
	_registry.register_command("mem_diff_baseline", _cmd_mem_diff_baseline, "Diff current memory against the baseline: mem_diff_baseline", "both")
	_registry.register_command("mem_export", _cmd_mem_export, "Export all snapshots to JSON: mem_export <res://path.json>", "both")

#region Command implementations

func _cmd_mem_snap(args: Array, piped_input: String = "") -> String:
	var snap_name: String = " ".join(args).strip_edges() if not args.is_empty() else ""
	if snap_name.is_empty():
		snap_name = _default_name()
	if snap_name == _BASELINE_KEY:
		return _format_error("Reserved name; use 'mem_baseline' instead")

	var data: Dictionary = _capture()
	_snapshots[snap_name] = data
	return _format_success("Captured %s" % _color_path(snap_name)) + "\n" + _format_summary(data)

func _cmd_mem_list(args: Array, piped_input: String = "") -> String:
	var names: Array = _snapshots.keys()
	if names.is_empty():
		return "[color=%s](no snapshots; use 'mem_snap' to capture one)[/color]" % _COLOR_DIM

	names.sort_custom(func(a, b):
		var sa: String = str(a)
		var sb: String = str(b)
		if sa == _BASELINE_KEY:
			return true
		if sb == _BASELINE_KEY:
			return false
		var ta: float = float(_snapshots[a].get("timestamp", 0.0))
		var tb: float = float(_snapshots[b].get("timestamp", 0.0))
		return ta < tb
	)

	var lines: Array[String] = []
	lines.append("Snapshots (%s)" % _color_number(str(names.size())))
	for n in names:
		var data: Dictionary = _snapshots[n]
		var display_name: String = "baseline" if str(n) == _BASELINE_KEY else str(n)
		var static_mem: int = int(data.get("static", 0))
		var nodes: int = int(data.get("nodes", 0))
		lines.append("  %s - static=%s nodes=%s" % [
			_color_path(display_name),
			_color_number(_format_bytes(static_mem)),
			_color_number(str(nodes))
		])
	return "\n".join(lines)

func _cmd_mem_diff(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: mem_diff <a> <b>")
	var name_a: String = str(args[0]).strip_edges()
	var name_b: String = str(args[1]).strip_edges()
	if not _snapshots.has(name_a):
		return _format_error("Snapshot not found: %s" % name_a)
	if not _snapshots.has(name_b):
		return _format_error("Snapshot not found: %s" % name_b)

	var a: Dictionary = _snapshots[name_a]
	var b: Dictionary = _snapshots[name_b]
	return _format_diff(a, b, name_a, name_b)

func _cmd_mem_drop(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: mem_drop <name|all>")
	var target: String = str(args[0]).strip_edges()
	if target == "all":
		var count: int = _snapshots.size()
		_snapshots.clear()
		return _format_success("Dropped %s snapshot(s)" % _color_number(str(count)))
	if not _snapshots.has(target):
		return _format_error("Snapshot not found: %s" % target)
	_snapshots.erase(target)
	return _format_success("Dropped %s" % _color_path(target))

func _cmd_mem_baseline(args: Array, piped_input: String = "") -> String:
	var data: Dictionary = _capture()
	_snapshots[_BASELINE_KEY] = data
	return _format_success("Baseline set") + "\n" + _format_summary(data)

func _cmd_mem_diff_baseline(args: Array, piped_input: String = "") -> String:
	if not _snapshots.has(_BASELINE_KEY):
		return _format_error("No baseline; use 'mem_baseline' first")
	var current: Dictionary = _capture()
	var baseline: Dictionary = _snapshots[_BASELINE_KEY]
	return _format_diff(baseline, current, "baseline", "current")

func _cmd_mem_export(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: mem_export <res://path.json>")
	var path: String = str(args[0]).strip_edges()
	if path.is_empty():
		return _format_error("Empty path")
	if _snapshots.is_empty():
		return _format_error("No snapshots to export")

	var payload: Dictionary = {
		"exported_at": Time.get_datetime_string_from_system(),
		"engine_version": Engine.get_version_info(),
		"snapshots": _snapshots,
	}
	var text: String = JSON.stringify(payload, "\t")

	var file := FileAccess.open(path, FileAccess.WRITE)
	if not file:
		var err: int = FileAccess.get_open_error()
		return _format_error("Cannot open '%s' for write (err=%d)" % [path, err])
	file.store_string(text)
	file.close()
	return _format_success("Exported %s snapshot(s) to %s" % [
		_color_number(str(_snapshots.size())),
		_color_path(path)
	])

#endregion

#region Capture / format helpers

func _capture() -> Dictionary:
	return {
		"timestamp": Time.get_unix_time_from_system(),
		"datetime": Time.get_datetime_string_from_system(),
		"static": int(Performance.get_monitor(Performance.MEMORY_STATIC)),
		"objects": int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		"resources": int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)),
		"nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"orphans": int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)),
		"video_mem": int(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)),
		"texture_mem": int(Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED)),
		"buffer_mem": int(Performance.get_monitor(Performance.RENDER_BUFFER_MEM_USED)),
	}

func _format_summary(data: Dictionary) -> String:
	var lines: Array[String] = []
	lines.append("  static_mem  = %s" % _color_number(_format_bytes(int(data.get("static", 0)))))
	lines.append("  objects     = %s" % _color_number(str(int(data.get("objects", 0)))))
	lines.append("  resources   = %s" % _color_number(str(int(data.get("resources", 0)))))
	lines.append("  nodes       = %s" % _color_number(str(int(data.get("nodes", 0)))))
	lines.append("  orphans     = %s" % _color_number(str(int(data.get("orphans", 0)))))
	lines.append("  video_mem   = %s" % _color_number(_format_bytes(int(data.get("video_mem", 0)))))
	lines.append("  texture_mem = %s" % _color_number(_format_bytes(int(data.get("texture_mem", 0)))))
	lines.append("  buffer_mem  = %s" % _color_number(_format_bytes(int(data.get("buffer_mem", 0)))))
	return "\n".join(lines)

func _format_diff(a: Dictionary, b: Dictionary, name_a: String, name_b: String) -> String:
	# Memory/object metrics: an increase from a -> b is "bad" (red), a decrease is "good" (green).
	var rows: Array = [
		["static_mem", int(a.get("static", 0)), int(b.get("static", 0)), true],
		["objects", int(a.get("objects", 0)), int(b.get("objects", 0)), false],
		["resources", int(a.get("resources", 0)), int(b.get("resources", 0)), false],
		["nodes", int(a.get("nodes", 0)), int(b.get("nodes", 0)), false],
		["orphans", int(a.get("orphans", 0)), int(b.get("orphans", 0)), false],
		["video_mem", int(a.get("video_mem", 0)), int(b.get("video_mem", 0)), true],
		["texture_mem", int(a.get("texture_mem", 0)), int(b.get("texture_mem", 0)), true],
		["buffer_mem", int(a.get("buffer_mem", 0)), int(b.get("buffer_mem", 0)), true],
	]

	var lines: Array[String] = []
	lines.append("Diff %s -> %s" % [_color_path(name_a), _color_path(name_b)])
	for row in rows:
		var label: String = row[0]
		var av: int = row[1]
		var bv: int = row[2]
		var as_bytes: bool = row[3]
		var delta: int = bv - av
		var av_str: String = _format_bytes(av) if as_bytes else str(av)
		var bv_str: String = _format_bytes(bv) if as_bytes else str(bv)
		var delta_str: String = _format_delta(delta, as_bytes)
		lines.append("  %s: %s -> %s  (%s)" % [
			label.rpad(11),
			_color_dim(av_str),
			_color_number(bv_str),
			delta_str
		])
	return "\n".join(lines)

func _format_delta(delta: int, as_bytes: bool) -> String:
	if delta == 0:
		return _color_dim("0")
	var sign_char: String = "+" if delta > 0 else "-"
	var magnitude: int = absi(delta)
	var body: String = _format_bytes(magnitude) if as_bytes else str(magnitude)
	var color: String = _COLOR_UP if delta > 0 else _COLOR_DOWN
	return "[color=%s]%s%s[/color]" % [color, sign_char, body]

func _format_bytes(n: int) -> String:
	var bytes: float = float(n)
	if bytes < 1024.0:
		return "%d B" % n
	if bytes < 1024.0 * 1024.0:
		return "%.1f KB" % (bytes / 1024.0)
	if bytes < 1024.0 * 1024.0 * 1024.0:
		return "%.1f MB" % (bytes / (1024.0 * 1024.0))
	return "%.2f GB" % (bytes / (1024.0 * 1024.0 * 1024.0))

func _default_name() -> String:
	return Time.get_datetime_string_from_system().replace(":", "-")

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

func _color_dim(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_DIM, s]

#endregion

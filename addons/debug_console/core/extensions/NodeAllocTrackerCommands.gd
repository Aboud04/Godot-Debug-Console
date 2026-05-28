@tool
class_name DebugConsoleNodeAllocTrackerCommands extends RefCounted

# Extension module - per-class node allocation tracker.
# Surfaces six "alloc_*" commands that snapshot node counts grouped by
# Object.get_class(), diff them against a baseline, and continuously sample
# pinned classes via a recurring SceneTreeTimer chain so the user can read
# growth trends as sparklines without leaving the in-game console.
#
# The orchestrator (BuiltInCommands.register_universal_commands) instantiates
# this once and keeps a strong reference; we mirror the SceneCommands.gd
# pattern so Callables stay valid for the lifetime of the plugin.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_UP := "#FF8C8C"
const _COLOR_DOWN := "#A0E0A0"
const _COLOR_MUTED := "#888888"

const _SPARK_CHARS: Array[String] = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
const _SAMPLE_PERIOD_SECS: float = 1.0
const _MAX_SAMPLES: int = 120

var _registry: Node
var _core: Node

var _baseline: Dictionary = {}
var _baseline_time_msec: int = 0
var _recording: bool = false

# class_name_key (String) -> Array[int] rolling history of node counts
var _pinned: Dictionary = {}
var _sampling: bool = false

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("alloc_record_start", _cmd_record_start,
		"Capture a per-class node count baseline: alloc_record_start", "game")
	_registry.register_command("alloc_record_stop", _cmd_record_stop,
		"Report delta vs baseline with arrows: alloc_record_stop", "game")
	_registry.register_command("alloc_growth", _cmd_growth,
		"Show classes that grew the most over the recording window: alloc_growth [n]", "game")
	_registry.register_command("alloc_pin", _cmd_pin,
		"Track that class's count every second: alloc_pin <ClassName>", "game")
	_registry.register_command("alloc_unpin", _cmd_unpin,
		"Stop tracking a class (or all): alloc_unpin <ClassName|all>", "game")
	_registry.register_command("alloc_chart", _cmd_chart,
		"Sparkline of the last N counts: alloc_chart <ClassName> [duration_secs]", "game")

#region Command implementations

func _cmd_record_start(args: Array, piped_input: String = "") -> String:
	var root: Node = _get_scene_root()
	if not root:
		return _format_error("No scene root available")
	_baseline = _snapshot_counts(root)
	_baseline_time_msec = Time.get_ticks_msec()
	_recording = true
	var total: int = 0
	for v in _baseline.values():
		total += int(v)
	return _format_success("Baseline captured: %s classes / %s nodes" % [
		_color_number(str(_baseline.size())),
		_color_number(str(total)),
	])

func _cmd_record_stop(args: Array, piped_input: String = "") -> String:
	if not _recording or _baseline.is_empty():
		return _format_error("No active recording. Run alloc_record_start first.")
	var root: Node = _get_scene_root()
	if not root:
		return _format_error("No scene root available")
	var current: Dictionary = _snapshot_counts(root)
	var deltas: Array = _compute_deltas(_baseline, current)
	var elapsed_secs: float = float(Time.get_ticks_msec() - _baseline_time_msec) / 1000.0
	_recording = false

	if deltas.is_empty():
		var base_total: int = 0
		for v in _baseline.values():
			base_total += int(v)
		_baseline.clear()
		return _format_success("No changes over %ss (baseline %s nodes)" % [
			_color_number("%.1f" % elapsed_secs),
			_color_number(str(base_total)),
		])

	deltas.sort_custom(func(a, b): return absi(int(a[1])) > absi(int(b[1])))
	var lines: Array[String] = []
	lines.append("Delta over %ss (%d classes changed):" % [
		_color_number("%.1f" % elapsed_secs),
		deltas.size(),
	])
	for row in deltas:
		lines.append("  %s  %-32s %s -> %s" % [
			_delta_arrow(int(row[1])),
			str(row[0]),
			_color_number(str(int(row[2]))),
			_color_number(str(int(row[3]))),
		])
	_baseline.clear()
	return "\n".join(lines)

func _cmd_growth(args: Array, piped_input: String = "") -> String:
	if not _recording or _baseline.is_empty():
		return _format_error("No active recording. Run alloc_record_start first.")
	var top_n: int = 10
	if args.size() > 0:
		top_n = maxi(1, int(str(args[0])))
	var root: Node = _get_scene_root()
	if not root:
		return _format_error("No scene root available")
	var current: Dictionary = _snapshot_counts(root)
	var deltas: Array = _compute_deltas(_baseline, current)
	var grown: Array = deltas.filter(func(r): return int(r[1]) > 0)
	if grown.is_empty():
		return "No growth detected"
	grown.sort_custom(func(a, b): return int(a[1]) > int(b[1]))
	var show: int = mini(top_n, grown.size())
	var lines: Array[String] = []
	lines.append("Top %s growth classes (window: %ss):" % [
		_color_number(str(show)),
		_color_number("%.1f" % (float(Time.get_ticks_msec() - _baseline_time_msec) / 1000.0)),
	])
	for i in range(show):
		var row: Array = grown[i]
		lines.append("  %s  %-32s %s -> %s" % [
			_color_up("+%d" % int(row[1])),
			str(row[0]),
			_color_number(str(int(row[2]))),
			_color_number(str(int(row[3]))),
		])
	return "\n".join(lines)

func _cmd_pin(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: alloc_pin <ClassName>")
	var class_name_arg: String = str(args[0]).strip_edges()
	if class_name_arg.is_empty():
		return _format_error("ClassName is empty")
	if not _pinned.has(class_name_arg):
		_pinned[class_name_arg] = []
	var sample: int = _count_of_class(class_name_arg)
	_push_sample(class_name_arg, sample)
	_ensure_sampling()
	return _format_success("Pinned %s (current count: %s, sample period: %ss)" % [
		_color_path(class_name_arg),
		_color_number(str(sample)),
		_color_number("%.1f" % _SAMPLE_PERIOD_SECS),
	])

func _cmd_unpin(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: alloc_unpin <ClassName|all>")
	var target: String = str(args[0]).strip_edges()
	if target.to_lower() == "all":
		var n: int = _pinned.size()
		_pinned.clear()
		return _format_success("Unpinned all (%s classes)" % _color_number(str(n)))
	if not _pinned.has(target):
		return _format_error("Not pinned: %s" % target)
	_pinned.erase(target)
	return _format_success("Unpinned %s (%s classes remain)" % [
		_color_path(target),
		_color_number(str(_pinned.size())),
	])

func _cmd_chart(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: alloc_chart <ClassName> [duration_secs]")
	var class_name_arg: String = str(args[0]).strip_edges()
	if not _pinned.has(class_name_arg):
		return _format_error("Not pinned: %s (use alloc_pin first)" % class_name_arg)
	var history: Array = _pinned[class_name_arg]
	if history.is_empty():
		return "No samples yet for %s" % _color_path(class_name_arg)
	var take: int = history.size()
	if args.size() > 1:
		var duration: float = maxf(_SAMPLE_PERIOD_SECS, float(str(args[1])))
		take = clampi(int(ceil(duration / _SAMPLE_PERIOD_SECS)), 1, history.size())
	var window: Array = history.slice(history.size() - take, history.size())
	var spark: String = _sparkline(window)
	var lo: int = int(window[0])
	var hi: int = int(window[0])
	for v in window:
		lo = mini(lo, int(v))
		hi = maxi(hi, int(v))
	return "%s [%s] last %s samples (%.1fs)  min=%s max=%s now=%s" % [
		_color_path(class_name_arg),
		spark,
		_color_number(str(window.size())),
		float(window.size()) * _SAMPLE_PERIOD_SECS,
		_color_number(str(lo)),
		_color_number(str(hi)),
		_color_number(str(int(window[window.size() - 1]))),
	]

#endregion

#region Periodic sampling (SceneTreeTimer chain)

func _ensure_sampling() -> void:
	if _sampling:
		return
	var tree: SceneTree = _get_scene_tree()
	if not tree:
		return
	_sampling = true
	_schedule_next_sample(tree)

func _schedule_next_sample(tree: SceneTree) -> void:
	if _pinned.is_empty():
		_sampling = false
		return
	var timer: SceneTreeTimer = tree.create_timer(_SAMPLE_PERIOD_SECS)
	if not timer:
		_sampling = false
		return
	timer.timeout.connect(_on_sample_tick, CONNECT_ONE_SHOT)

func _on_sample_tick() -> void:
	if _pinned.is_empty():
		_sampling = false
		return
	var root: Node = _get_scene_root()
	if root:
		var counts: Dictionary = _snapshot_counts(root)
		for class_name_key in _pinned.keys():
			var c: int = int(counts.get(class_name_key, 0))
			_push_sample(class_name_key, c)
	var tree: SceneTree = _get_scene_tree()
	if tree:
		_schedule_next_sample(tree)
	else:
		_sampling = false

func _push_sample(class_name_key: String, value: int) -> void:
	var history: Array = _pinned.get(class_name_key, [])
	history.append(value)
	while history.size() > _MAX_SAMPLES:
		history.remove_at(0)
	_pinned[class_name_key] = history

#endregion

#region Helpers

func _get_scene_tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree

func _get_scene_root() -> Node:
	var tree: SceneTree = _get_scene_tree()
	if not tree:
		return null
	if tree.current_scene:
		return tree.current_scene
	return tree.root

func _snapshot_counts(root: Node) -> Dictionary:
	var counts: Dictionary = {}
	_walk_counts(root, counts)
	return counts

func _walk_counts(node: Node, counts: Dictionary) -> void:
	var c: String = node.get_class()
	counts[c] = int(counts.get(c, 0)) + 1
	for child in node.get_children():
		_walk_counts(child, counts)

func _count_of_class(class_name_key: String) -> int:
	var root: Node = _get_scene_root()
	if not root:
		return 0
	var counts: Dictionary = _snapshot_counts(root)
	return int(counts.get(class_name_key, 0))

func _compute_deltas(before: Dictionary, after: Dictionary) -> Array:
	var keys: Dictionary = {}
	for k in before.keys():
		keys[k] = true
	for k in after.keys():
		keys[k] = true
	var rows: Array = []
	for k in keys.keys():
		var b: int = int(before.get(k, 0))
		var a: int = int(after.get(k, 0))
		var d: int = a - b
		if d != 0:
			rows.append([k, d, b, a])
	return rows

func _sparkline(values: Array) -> String:
	if values.is_empty():
		return ""
	var lo: int = int(values[0])
	var hi: int = int(values[0])
	for v in values:
		lo = mini(lo, int(v))
		hi = maxi(hi, int(v))
	var range_span: int = hi - lo
	var bucket_max: int = _SPARK_CHARS.size() - 1
	var out: String = ""
	for v in values:
		var idx: int = 0
		if range_span > 0:
			idx = clampi(int(round(float(int(v) - lo) / float(range_span) * float(bucket_max))), 0, bucket_max)
		out += _SPARK_CHARS[idx]
	return out

func _delta_arrow(d: int) -> String:
	if d > 0:
		return _color_up("↑ +%d" % d)
	if d < 0:
		return _color_down("↓ %d" % d)
	return _color_muted("· 0")

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

func _color_up(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_UP, s]

func _color_down(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_DOWN, s]

func _color_muted(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_MUTED, s]

#endregion

@tool
class_name DebugConsoleDrawCallCommands extends RefCounted

# Tier 6 extension - rendering performance commands. Surfaces the
# Performance.RENDER_* monitors and adds two derived helpers:
#   * draw_history - rolling sparkline of recent draw-call counts
#   * draw_alarm   - persistent threshold watchdog (>1s sustained breach)
#
# RefCounted has no _process, so a tiny inner Node ticker is attached to
# the SceneTree root on first need. The ticker weakref's back into this
# extension; the extension is kept alive by BuiltInCommands._t6_keepalive,
# so the weakref stays valid for the plugin's lifetime.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_WARN := "#F5B041"

const _HISTORY_CAPACITY := 600
const _ALARM_TRIGGER_SECONDS := 1.0
const _SPARK_GLYPHS := ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]

var _registry: Node
var _core: Node

var _ticker: Node = null
var _history: PackedInt32Array = PackedInt32Array()
var _alarms: Array = []

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("draw_calls", _cmd_draw_calls, "Show current frame draw-call count (Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME).", "both")
	_registry.register_command("draw_primitives", _cmd_draw_primitives, "Show current frame primitive count (Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME).", "both")
	_registry.register_command("draw_objects", _cmd_draw_objects, "Show current frame rendered-object count (Performance.RENDER_TOTAL_OBJECTS_IN_FRAME).", "both")
	_registry.register_command("draw_breakdown", _cmd_draw_breakdown, "Table of all RENDER_* monitors for the current frame.", "both")
	_registry.register_command("draw_video_mem", _cmd_draw_video_mem, "Show RENDER_VIDEO_MEM_USED with texture/buffer split.", "both")
	_registry.register_command("draw_alarm", _cmd_draw_alarm, "Warn when a metric exceeds threshold for >1s: draw_alarm <metric> <threshold> | draw_alarm | draw_alarm clear", "both")
	_registry.register_command("draw_history", _cmd_draw_history, "Sparkline of recent frame draw-call counts: draw_history [n]", "both")

#region Command implementations

func _cmd_draw_calls(args: Array, piped_input: String = "") -> String:
	var value: int = int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	return "Draw calls (frame): %s" % _color_number(str(value))

func _cmd_draw_primitives(args: Array, piped_input: String = "") -> String:
	var value: int = int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	return "Primitives (frame): %s" % _color_number(str(value))

func _cmd_draw_objects(args: Array, piped_input: String = "") -> String:
	var value: int = int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))
	return "Rendered objects (frame): %s" % _color_number(str(value))

func _cmd_draw_breakdown(args: Array, piped_input: String = "") -> String:
	var lines: Array[String] = []
	lines.append("RENDER_* monitors:")
	for entry in _all_render_monitors():
		var id: int = entry[0]
		var label: String = entry[1]
		var is_mem: bool = entry[2]
		var raw: float = Performance.get_monitor(id)
		var pretty: String = _format_mem(int(raw)) if is_mem else _color_number(str(int(raw)))
		lines.append("  %-32s %s" % [label, pretty])
	return "\n".join(lines)

func _cmd_draw_video_mem(args: Array, piped_input: String = "") -> String:
	var total: int = int(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED))
	var tex: int = int(Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED))
	var buf: int = int(Performance.get_monitor(Performance.RENDER_BUFFER_MEM_USED))
	var other: int = max(total - tex - buf, 0)
	var lines: Array[String] = []
	lines.append("Video memory: %s" % _format_mem(total))
	lines.append("  textures  %s" % _format_mem(tex))
	lines.append("  buffers   %s" % _format_mem(buf))
	lines.append("  other     %s" % _format_mem(other))
	return "\n".join(lines)

func _cmd_draw_alarm(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _list_alarms()

	var first := str(args[0]).strip_edges().to_lower()
	if first == "clear" or first == "reset":
		var n: int = _alarms.size()
		_alarms.clear()
		return _format_success("Cleared %s alarm(s)." % _color_number(str(n)))

	if args.size() < 2:
		return _format_error("Usage: draw_alarm <metric> <threshold> | draw_alarm | draw_alarm clear")

	var metric_id: int = _metric_id_from_name(first)
	if metric_id < 0:
		return _format_error("Unknown metric: %s (try: %s)" % [first, ", ".join(_known_metric_names())])

	var threshold_str := str(args[1]).strip_edges()
	if not threshold_str.is_valid_float():
		return _format_error("Threshold must be a number: %s" % threshold_str)
	var threshold: float = threshold_str.to_float()

	for existing in _alarms:
		if int(existing["metric_id"]) == metric_id:
			existing["threshold"] = threshold
			existing["elapsed"] = 0.0
			existing["fired"] = false
			existing["last_value"] = 0.0
			_ensure_ticker()
			return _format_success("Updated alarm: %s > %s" % [_metric_name_from_id(metric_id), _color_number(str(threshold))])

	_alarms.append({
		"metric_id": metric_id,
		"metric_name": _metric_name_from_id(metric_id),
		"threshold": threshold,
		"elapsed": 0.0,
		"fired": false,
		"last_value": 0.0,
		"fire_count": 0,
	})
	_ensure_ticker()
	return _format_success("Armed alarm: %s > %s (warns after %ss sustained)" % [
		_metric_name_from_id(metric_id),
		_color_number(str(threshold)),
		_color_number(str(_ALARM_TRIGGER_SECONDS)),
	])

func _cmd_draw_history(args: Array, piped_input: String = "") -> String:
	_ensure_ticker()
	var requested: int = _HISTORY_CAPACITY
	if not args.is_empty():
		var raw := str(args[0]).strip_edges()
		if not raw.is_valid_int():
			return _format_error("History length must be an integer: %s" % raw)
		requested = max(int(raw.to_int()), 1)

	var available: int = _history.size()
	if available == 0:
		return "Draw-call history: %s (no frames sampled yet; ticker running)" % _color_path("(empty)")

	var count: int = min(requested, available)
	var start: int = available - count
	var slice: PackedInt32Array = _history.slice(start, available)

	var min_v: int = slice[0]
	var max_v: int = slice[0]
	var sum: int = 0
	for v in slice:
		if v < min_v: min_v = v
		if v > max_v: max_v = v
		sum += v
	var avg: int = int(round(float(sum) / float(count)))

	var spark: String = _sparkline(slice, min_v, max_v)
	return "Draw calls (last %s of %s frames):\n%s\n  min %s  avg %s  max %s" % [
		_color_number(str(count)),
		_color_number(str(available)),
		spark,
		_color_number(str(min_v)),
		_color_number(str(avg)),
		_color_number(str(max_v)),
	]

#endregion

#region Ticker

func _ensure_ticker() -> void:
	if is_instance_valid(_ticker):
		return
	var tree := Engine.get_main_loop() as SceneTree
	if not tree or not tree.root:
		return
	var TickerClass := _DrawCallTicker
	var t: Node = TickerClass.new()
	t.name = "DebugConsole_DrawCallTicker"
	t.owner_ref = weakref(self)
	tree.root.add_child(t)
	_ticker = t

func _on_tick(delta: float) -> void:
	var calls: int = int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	_history.push_back(calls)
	if _history.size() > _HISTORY_CAPACITY:
		_history = _history.slice(_history.size() - _HISTORY_CAPACITY, _history.size())

	for alarm in _alarms:
		var value: float = Performance.get_monitor(int(alarm["metric_id"]))
		alarm["last_value"] = value
		var threshold: float = float(alarm["threshold"])
		if value > threshold:
			alarm["elapsed"] = float(alarm["elapsed"]) + delta
			if float(alarm["elapsed"]) >= _ALARM_TRIGGER_SECONDS and not bool(alarm["fired"]):
				alarm["fired"] = true
				alarm["fire_count"] = int(alarm["fire_count"]) + 1
				var msg: String = "[DebugConsole] Draw alarm: %s=%s exceeded threshold %s for %ss" % [
					alarm["metric_name"], value, threshold, _ALARM_TRIGGER_SECONDS,
				]
				push_warning(msg)
				print(msg)
		else:
			alarm["elapsed"] = 0.0
			alarm["fired"] = false

#endregion

#region Helpers

func _list_alarms() -> String:
	if _alarms.is_empty():
		return "No alarms armed. Usage: draw_alarm <metric> <threshold>"
	var lines: Array[String] = []
	lines.append("Armed alarms (%s):" % _color_number(str(_alarms.size())))
	for a in _alarms:
		var state: String = "[color=%s]FIRING[/color]" % _COLOR_WARN if bool(a["fired"]) else "ok"
		lines.append("  %-14s > %-10s  current=%s  fired=%s  state=%s" % [
			str(a["metric_name"]),
			str(a["threshold"]),
			_color_number(str(int(float(a["last_value"])))),
			_color_number(str(int(a["fire_count"]))),
			state,
		])
	return "\n".join(lines)

func _all_render_monitors() -> Array:
	return [
		[Performance.RENDER_TOTAL_OBJECTS_IN_FRAME, "objects", false],
		[Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME, "primitives", false],
		[Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME, "draw_calls", false],
		[Performance.RENDER_VIDEO_MEM_USED, "video_mem_total", true],
		[Performance.RENDER_TEXTURE_MEM_USED, "video_mem_textures", true],
		[Performance.RENDER_BUFFER_MEM_USED, "video_mem_buffers", true],
	]

func _known_metric_names() -> Array:
	return ["draw_calls", "primitives", "objects", "video_mem", "texture_mem", "buffer_mem"]

func _metric_id_from_name(name: String) -> int:
	match name:
		"draw_calls", "calls", "drawcalls":
			return Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME
		"primitives", "prims", "tris":
			return Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME
		"objects", "objs":
			return Performance.RENDER_TOTAL_OBJECTS_IN_FRAME
		"video_mem", "vmem", "vram":
			return Performance.RENDER_VIDEO_MEM_USED
		"texture_mem", "tex_mem", "tmem":
			return Performance.RENDER_TEXTURE_MEM_USED
		"buffer_mem", "buf_mem", "bmem":
			return Performance.RENDER_BUFFER_MEM_USED
	return -1

func _metric_name_from_id(id: int) -> String:
	if id == Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME: return "draw_calls"
	if id == Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME: return "primitives"
	if id == Performance.RENDER_TOTAL_OBJECTS_IN_FRAME: return "objects"
	if id == Performance.RENDER_VIDEO_MEM_USED: return "video_mem"
	if id == Performance.RENDER_TEXTURE_MEM_USED: return "texture_mem"
	if id == Performance.RENDER_BUFFER_MEM_USED: return "buffer_mem"
	return "monitor_%d" % id

func _format_mem(bytes: int) -> String:
	if bytes <= 0:
		return _color_number("0 B")
	var units := ["B", "KB", "MB", "GB"]
	var idx: int = 0
	var value: float = float(bytes)
	while value >= 1024.0 and idx < units.size() - 1:
		value /= 1024.0
		idx += 1
	if idx == 0:
		return _color_number("%d B" % int(value))
	return _color_number("%.2f %s" % [value, units[idx]])

func _sparkline(values: PackedInt32Array, min_v: int, max_v: int) -> String:
	if values.is_empty():
		return ""
	var span: int = max_v - min_v
	var glyph_count: int = _SPARK_GLYPHS.size()
	var out := ""
	for v in values:
		var idx: int = 0
		if span > 0:
			idx = int(floor(float(v - min_v) / float(span) * float(glyph_count - 1)))
			idx = clamp(idx, 0, glyph_count - 1)
		out += _SPARK_GLYPHS[idx]
	return "[color=%s]%s[/color]" % [_COLOR_PATH, out]

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

#endregion

#region Inner classes

class _DrawCallTicker extends Node:
	var owner_ref: WeakRef

	func _process(delta: float) -> void:
		if owner_ref == null:
			return
		var owner: Object = owner_ref.get_ref()
		if owner == null:
			queue_free()
			return
		owner.call("_on_tick", delta)

#endregion

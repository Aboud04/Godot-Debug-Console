@tool
class_name DebugConsolePerformanceOverlayCommands extends RefCounted

# Tier 7 - always-on performance HUD commands. Mirrors the structure of
# core/SceneCommands.gd: BuiltInCommands instantiates this class, holds a
# strong reference to it, and calls register_commands(registry, core). All
# overlay state lives on a lazy CanvasLayer added under /root so the HUD
# survives scene changes for the lifetime of the running game.
#
# Commands are registered with the "game" context only because the overlay
# pulls live values from Performance.get_monitor() and renders against the
# running viewport.

const _COLOR_ERROR := "#FF4444"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_PATH := "#5FBEE0"

const _OVERLAY_NAME := "__DebugConsolePerfOverlay__"
const _HISTORY_SAMPLES := 60
const _DEFAULT_METRICS := ["fps", "ms", "draw_calls", "objs", "mem"]

const _CORNER_PRESETS := {
	"tl": Vector2(8, 8),
	"tr": Vector2(-8, 8),
	"bl": Vector2(8, -8),
	"br": Vector2(-8, -8),
}

var _registry: Node
var _core: Node

var _metrics: PackedStringArray = PackedStringArray(_DEFAULT_METRICS)
var _corner: String = "tr"
var _alpha: float = 0.75
var _history_enabled: bool = false
var _history: Dictionary = {}

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("perf_overlay_show", _cmd_show,
		"Show the always-on performance HUD: perf_overlay_show [metric...] (default: fps ms draw_calls objs mem)", "game")
	_registry.register_command("perf_overlay_hide", _cmd_hide,
		"Hide the performance HUD: perf_overlay_hide", "game")
	_registry.register_command("perf_overlay_corner", _cmd_corner,
		"Position the HUD in a screen corner: perf_overlay_corner <tl|tr|bl|br>", "game")
	_registry.register_command("perf_overlay_alpha", _cmd_alpha,
		"Set HUD opacity 0-100: perf_overlay_alpha <0-100>", "game")
	_registry.register_command("perf_overlay_metrics", _cmd_metrics,
		"Replace the displayed metric list: perf_overlay_metrics <metric...>", "game")
	_registry.register_command("perf_overlay_history", _cmd_history,
		"Toggle the 60-sample sparkline strip for the first metric: perf_overlay_history", "game")

#region Command implementations

func _cmd_show(args: Array, _piped_input: String = "") -> String:
	if Engine.is_editor_hint():
		return _format_error("perf_overlay_show requires a running game context")
	if args.size() > 0:
		var requested: PackedStringArray = PackedStringArray()
		for raw in args:
			var name_str := str(raw).strip_edges().to_lower()
			if name_str.is_empty():
				continue
			if not _is_known_metric(name_str):
				return _format_error("Unknown metric: %s (known: %s)" % [name_str, ", ".join(_known_metrics())])
			requested.append(name_str)
		if requested.size() > 0:
			_metrics = requested
			_history.clear()
	var overlay := _ensure_overlay()
	if not overlay:
		return _format_error("Failed to create overlay (no SceneTree root)")
	overlay.visible = true
	_apply_alpha()
	_apply_corner()
	_refresh()
	return _format_success("Performance overlay shown: %s" % _color_path(", ".join(_metrics)))

func _cmd_hide(_args: Array, _piped_input: String = "") -> String:
	var overlay := _find_overlay()
	if not overlay:
		return _format_success("Overlay already hidden")
	overlay.visible = false
	return _format_success("Performance overlay hidden")

func _cmd_corner(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: perf_overlay_corner <tl|tr|bl|br>")
	var key := str(args[0]).strip_edges().to_lower()
	if not _CORNER_PRESETS.has(key):
		return _format_error("Unknown corner: %s (use tl, tr, bl, br)" % key)
	_corner = key
	if _find_overlay():
		_apply_corner()
	return _format_success("Overlay corner set to %s" % _color_path(key))

func _cmd_alpha(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: perf_overlay_alpha <0-100>")
	var raw := str(args[0]).strip_edges()
	if not raw.is_valid_float():
		return _format_error("Alpha must be a number 0-100: %s" % raw)
	var pct: float = clampf(raw.to_float(), 0.0, 100.0)
	_alpha = pct / 100.0
	if _find_overlay():
		_apply_alpha()
	return _format_success("Overlay alpha set to %s" % _color_number("%d%%" % int(pct)))

func _cmd_metrics(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: perf_overlay_metrics <metric...> (known: %s)" % ", ".join(_known_metrics()))
	var requested: PackedStringArray = PackedStringArray()
	for raw in args:
		var name_str := str(raw).strip_edges().to_lower()
		if name_str.is_empty():
			continue
		if not _is_known_metric(name_str):
			return _format_error("Unknown metric: %s (known: %s)" % [name_str, ", ".join(_known_metrics())])
		requested.append(name_str)
	if requested.is_empty():
		return _format_error("No metrics provided")
	_metrics = requested
	_history.clear()
	if _find_overlay():
		_refresh()
	return _format_success("Overlay metrics set to %s" % _color_path(", ".join(_metrics)))

func _cmd_history(_args: Array, _piped_input: String = "") -> String:
	_history_enabled = not _history_enabled
	if not _history_enabled:
		_history.clear()
	var overlay := _find_overlay()
	if overlay:
		var strip: Control = overlay.get_node_or_null("Sparkline") as Control
		if strip:
			strip.visible = _history_enabled
			strip.queue_redraw()
		_apply_corner()
		_refresh()
	return _format_success("Sparkline %s" % _color_path("enabled" if _history_enabled else "disabled"))

#endregion

#region Overlay lifecycle

func _ensure_overlay() -> CanvasLayer:
	var existing := _find_overlay()
	if existing:
		return existing
	var tree := Engine.get_main_loop() as SceneTree
	if not tree or not tree.root:
		return null

	var overlay := CanvasLayer.new()
	overlay.name = _OVERLAY_NAME
	overlay.layer = 128

	var label := Label.new()
	label.name = "Label"
	label.add_theme_color_override("font_color", Color(1, 1, 1, 1))
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	label.add_theme_constant_override("outline_size", 4)
	label.add_theme_font_size_override("font_size", 14)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(label)

	var spark := Control.new()
	spark.name = "Sparkline"
	spark.custom_minimum_size = Vector2(220, 36)
	spark.size = Vector2(220, 36)
	spark.visible = _history_enabled
	spark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var spark_script := GDScript.new()
	spark_script.source_code = "extends Control\n" \
		+ "var samples: Array = []\n" \
		+ "var line_color: Color = Color(0.4, 0.9, 1.0, 0.9)\n" \
		+ "func _draw() -> void:\n" \
		+ "\tvar sz: Vector2 = size\n" \
		+ "\tdraw_rect(Rect2(Vector2.ZERO, sz), Color(0, 0, 0, 0.35), true)\n" \
		+ "\tif samples.is_empty():\n" \
		+ "\t\treturn\n" \
		+ "\tvar lo: float = INF\n" \
		+ "\tvar hi: float = -INF\n" \
		+ "\tfor v in samples:\n" \
		+ "\t\tvar f: float = float(v)\n" \
		+ "\t\tif f < lo: lo = f\n" \
		+ "\t\tif f > hi: hi = f\n" \
		+ "\tif not is_finite(lo) or not is_finite(hi):\n" \
		+ "\t\treturn\n" \
		+ "\tif hi - lo < 0.0001:\n" \
		+ "\t\thi = lo + 1.0\n" \
		+ "\tvar w: float = sz.x\n" \
		+ "\tvar h: float = sz.y\n" \
		+ "\tvar n: int = samples.size()\n" \
		+ "\tvar denom: float = float(max(n - 1, 1))\n" \
		+ "\tvar prev: Vector2 = Vector2.ZERO\n" \
		+ "\tfor i in n:\n" \
		+ "\t\tvar f: float = float(samples[i])\n" \
		+ "\t\tvar x: float = (float(i) / denom) * w\n" \
		+ "\t\tvar y: float = h - ((f - lo) / (hi - lo)) * h\n" \
		+ "\t\tvar pt: Vector2 = Vector2(x, y)\n" \
		+ "\t\tif i > 0:\n" \
		+ "\t\t\tdraw_line(prev, pt, line_color, 1.5)\n" \
		+ "\t\tprev = pt\n"
	spark_script.reload()
	spark.set_script(spark_script)
	overlay.add_child(spark)

	var helper := Node.new()
	helper.name = "Refresher"
	var helper_script := GDScript.new()
	helper_script.source_code = "extends Node\n" \
		+ "var target: Callable\n" \
		+ "func _process(_delta: float) -> void:\n" \
		+ "\tif target.is_valid():\n" \
		+ "\t\ttarget.call()\n"
	helper_script.reload()
	helper.set_script(helper_script)
	helper.set("target", Callable(self, "_refresh"))
	overlay.add_child(helper)

	tree.root.add_child(overlay)
	return overlay

func _find_overlay() -> CanvasLayer:
	var tree := Engine.get_main_loop() as SceneTree
	if not tree or not tree.root:
		return null
	var node := tree.root.get_node_or_null(_OVERLAY_NAME)
	return node as CanvasLayer

func _apply_alpha() -> void:
	var overlay := _find_overlay()
	if not overlay:
		return
	var label: Label = overlay.get_node_or_null("Label") as Label
	if label:
		label.modulate = Color(1, 1, 1, _alpha)
	var spark: Control = overlay.get_node_or_null("Sparkline") as Control
	if spark:
		spark.modulate = Color(1, 1, 1, _alpha)

func _apply_corner() -> void:
	var overlay := _find_overlay()
	if not overlay:
		return
	var label: Label = overlay.get_node_or_null("Label") as Label
	var spark: Control = overlay.get_node_or_null("Sparkline") as Control
	var viewport := overlay.get_viewport()
	var screen: Vector2 = Vector2(640, 360)
	if viewport:
		screen = viewport.get_visible_rect().size

	var offset: Vector2 = _CORNER_PRESETS.get(_corner, Vector2(-8, 8))
	var label_size: Vector2 = Vector2(220, 110)
	var spark_size: Vector2 = Vector2(220, 36)

	if label:
		var lp: Vector2 = _corner_anchor(_corner, label_size, screen, offset)
		label.position = lp
		label.size = label_size
		label.horizontal_alignment = (HORIZONTAL_ALIGNMENT_RIGHT if _corner.ends_with("r") else HORIZONTAL_ALIGNMENT_LEFT)

	if spark:
		var sp: Vector2 = _corner_anchor(_corner, spark_size, screen, offset)
		if _corner.begins_with("t"):
			sp.y += label_size.y + 4
		else:
			sp.y -= spark_size.y + 4
		spark.position = sp
		spark.size = spark_size

func _corner_anchor(corner: String, ctrl_size: Vector2, screen: Vector2, offset: Vector2) -> Vector2:
	var x: float = 0.0
	var y: float = 0.0
	if corner.ends_with("l"):
		x = offset.x
	else:
		x = screen.x - ctrl_size.x + offset.x
	if corner.begins_with("t"):
		y = offset.y
	else:
		y = screen.y - ctrl_size.y + offset.y
	return Vector2(x, y)

#endregion

#region Refresh + metric sampling

func _refresh() -> void:
	var overlay := _find_overlay()
	if not overlay or not overlay.visible:
		return
	var label: Label = overlay.get_node_or_null("Label") as Label
	if not label:
		return
	var lines: PackedStringArray = PackedStringArray()
	for metric in _metrics:
		var value: float = _sample_metric(metric)
		lines.append("%s: %s" % [_metric_label(metric), _format_metric(metric, value)])
		if _history_enabled:
			_push_sample(metric, value)
	label.text = "\n".join(lines)

	if _history_enabled and _metrics.size() > 0:
		var spark: Control = overlay.get_node_or_null("Sparkline") as Control
		if spark:
			var first := String(_metrics[0])
			var samples: Array = _history.get(first, [])
			spark.set("samples", samples)
			spark.queue_redraw()

func _push_sample(metric: String, value: float) -> void:
	var samples: Array = _history.get(metric, [])
	samples.append(value)
	while samples.size() > _HISTORY_SAMPLES:
		samples.remove_at(0)
	_history[metric] = samples

func _sample_metric(metric: String) -> float:
	var id := _metric_id(metric)
	if id < 0:
		return 0.0
	return float(Performance.get_monitor(id))

func _format_metric(metric: String, value: float) -> String:
	match metric:
		"fps":
			return "%d" % int(round(value))
		"ms", "physics":
			return "%.2f ms" % (value * 1000.0)
		"mem", "gpu":
			return _format_bytes(value)
		_:
			if value == floor(value):
				return "%d" % int(value)
			return "%.2f" % value

func _format_bytes(bytes: float) -> String:
	var kb: float = bytes / 1024.0
	if kb < 1024.0:
		return "%.1f KB" % kb
	var mb: float = kb / 1024.0
	if mb < 1024.0:
		return "%.1f MB" % mb
	return "%.2f GB" % (mb / 1024.0)

func _metric_label(metric: String) -> String:
	match metric:
		"fps": return "FPS"
		"ms": return "Process"
		"physics": return "Physics"
		"draw_calls": return "Draws"
		"objs": return "Objects"
		"nodes": return "Nodes"
		"mem": return "Mem"
		"gpu": return "VRAM"
		_: return metric

func _metric_id(metric: String) -> int:
	match metric:
		"fps": return Performance.TIME_FPS
		"ms": return Performance.TIME_PROCESS
		"physics": return Performance.TIME_PHYSICS_PROCESS
		"draw_calls": return Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME
		"objs": return Performance.OBJECT_COUNT
		"nodes": return Performance.OBJECT_NODE_COUNT
		"mem": return Performance.MEMORY_STATIC
		"gpu": return Performance.RENDER_VIDEO_MEM_USED
		_: return -1

func _is_known_metric(metric: String) -> bool:
	return _metric_id(metric) >= 0

func _known_metrics() -> Array:
	return ["fps", "ms", "physics", "draw_calls", "objs", "nodes", "mem", "gpu"]

#endregion

#region Formatting helpers

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

#endregion

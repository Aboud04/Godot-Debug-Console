@tool
class_name DebugConsoleFrameCaptureCommands extends RefCounted

# Tier 6 (game context) - frame snapshots, periodic recording, snap-to-snap
# diffing, CSV export, and viewport screenshots. Mirrors the structure of
# core/SceneCommands.gd: orchestrator holds a strong reference and calls
# register_commands(registry, core). All snapshot state lives on this
# instance so the Callables stay valid for the plugin lifetime.
#
# A snapshot captures, at the moment frame_snap is invoked:
#   * every built-in Performance monitor (id 0..MONITOR_MAX-1)
#   * total Node count under the active scene root
#   * Engine.get_frames_per_second()
#   * Time.get_ticks_msec() (for CSV correlation)
#
# Recording adds a Timer under the scene root that re-captures at the
# requested rate. Snapshots are stored in _snaps keyed by name; recorded
# snaps are auto-named "rec_NNNN".

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"

var _registry: Node
var _core: Node
var _snaps: Dictionary = {}
var _snap_counter: int = 0
var _record_timer: Timer = null
var _record_index: int = 0
var _record_hz: float = 0.0

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("frame_snap", _cmd_frame_snap, "Snapshot Performance counters + scene-tree node count + fps: frame_snap [name]", "game")
	_registry.register_command("frame_record_start", _cmd_frame_record_start, "Start recording snapshots at hz frames/sec (default 1): frame_record_start [hz]", "game")
	_registry.register_command("frame_record_stop", _cmd_frame_record_stop, "Stop the running snapshot recorder: frame_record_stop", "game")
	_registry.register_command("frame_compare", _cmd_frame_compare, "Diff two frame snaps: frame_compare <a> <b>", "game")
	_registry.register_command("frame_export", _cmd_frame_export, "Dump all snaps as CSV: frame_export <res://path.csv>", "game")
	_registry.register_command("frame_screenshot", _cmd_frame_screenshot, "Snap + save viewport PNG: frame_screenshot [name]", "game")

#region Command implementations

func _cmd_frame_snap(args: Array, piped_input: String = "") -> String:
	var snap_name := str(args[0]).strip_edges() if args.size() > 0 else ""
	if snap_name.is_empty():
		snap_name = _auto_name()
	var snap := _capture_snapshot()
	_snaps[snap_name] = snap
	var counters: Dictionary = snap.get("counters", {})
	return _format_success("Snapped %s (fps=%s, nodes=%s, counters=%s)" % [
		_color_path(snap_name),
		_color_number(str(snap.get("fps", 0))),
		_color_number(str(snap.get("node_count", 0))),
		_color_number(str(counters.size())),
	])

func _cmd_frame_record_start(args: Array, piped_input: String = "") -> String:
	var hz: float = 1.0
	if args.size() > 0:
		var raw := str(args[0]).strip_edges()
		if raw.is_valid_float():
			hz = raw.to_float()
	if hz <= 0.0:
		return _format_error("hz must be > 0 (got %s)" % str(hz))
	if _record_timer and is_instance_valid(_record_timer):
		return _format_error("Recording already in progress at %s Hz. Use frame_record_stop first." % str(_record_hz))
	var parent := _get_scene_root()
	if not parent:
		return _format_error("No scene root available to host the recorder timer.")

	var timer := Timer.new()
	timer.name = "_DebugConsole_FrameRecorder"
	timer.wait_time = 1.0 / hz
	timer.one_shot = false
	timer.autostart = false
	timer.process_mode = Node.PROCESS_MODE_ALWAYS
	parent.add_child(timer)
	timer.timeout.connect(_on_record_tick)
	timer.start()
	_record_timer = timer
	_record_index = 0
	_record_hz = hz
	return _format_success("Recording at %s Hz (interval %s s) under %s" % [
		_color_number(str(hz)),
		_color_number(str(1.0 / hz)),
		_color_path(str(parent.get_path()) if parent.is_inside_tree() else parent.name),
	])

func _cmd_frame_record_stop(args: Array, piped_input: String = "") -> String:
	if not (_record_timer and is_instance_valid(_record_timer)):
		return _format_error("No active recording.")
	_record_timer.stop()
	if _record_timer.timeout.is_connected(_on_record_tick):
		_record_timer.timeout.disconnect(_on_record_tick)
	_record_timer.queue_free()
	_record_timer = null
	var ticks := _record_index
	_record_index = 0
	_record_hz = 0.0
	return _format_success("Stopped recording after %s tick(s). Total snaps in buffer: %s" % [
		_color_number(str(ticks)),
		_color_number(str(_snaps.size())),
	])

func _cmd_frame_compare(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: frame_compare <a> <b>")
	var a_name := str(args[0]).strip_edges()
	var b_name := str(args[1]).strip_edges()
	if not _snaps.has(a_name):
		return _format_error("Snap not found: %s" % a_name)
	if not _snaps.has(b_name):
		return _format_error("Snap not found: %s" % b_name)
	var a: Dictionary = _snaps[a_name]
	var b: Dictionary = _snaps[b_name]

	var lines: PackedStringArray = []
	lines.append("Compare %s -> %s" % [_color_path(a_name), _color_path(b_name)])
	lines.append("  fps: %s -> %s (Δ %s)" % [
		_color_number(str(a.get("fps", 0))),
		_color_number(str(b.get("fps", 0))),
		_color_number(str(float(b.get("fps", 0)) - float(a.get("fps", 0)))),
	])
	lines.append("  node_count: %s -> %s (Δ %s)" % [
		_color_number(str(a.get("node_count", 0))),
		_color_number(str(b.get("node_count", 0))),
		_color_number(str(int(b.get("node_count", 0)) - int(a.get("node_count", 0)))),
	])
	var dt: int = int(b.get("timestamp_ms", 0)) - int(a.get("timestamp_ms", 0))
	lines.append("  Δt_ms: %s" % _color_number(str(dt)))

	var ca: Dictionary = a.get("counters", {})
	var cb: Dictionary = b.get("counters", {})
	var keys: Array = []
	for k in ca.keys():
		if not keys.has(k):
			keys.append(k)
	for k in cb.keys():
		if not keys.has(k):
			keys.append(k)
	keys.sort()
	var diffs: int = 0
	for k in keys:
		var has_a: bool = ca.has(k)
		var has_b: bool = cb.has(k)
		var va: float = float(ca.get(k, 0.0))
		var vb: float = float(cb.get(k, 0.0))
		var delta: float = vb - va
		if has_a and has_b and absf(delta) < 0.0001:
			continue
		diffs += 1
		lines.append("  %s: %s -> %s (Δ %s)" % [
			str(k),
			_color_number(str(va) if has_a else "-"),
			_color_number(str(vb) if has_b else "-"),
			_color_number(str(delta)),
		])
	if diffs == 0:
		lines.append("  (all counters identical)")
	return "\n".join(lines)

func _cmd_frame_export(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: frame_export <res://path.csv>")
	var path := str(args[0]).strip_edges()
	if path.is_empty():
		return _format_error("Empty path.")
	if _snaps.is_empty():
		return _format_error("No snaps to export.")

	var counter_keys: Array = []
	for snap_name in _snaps.keys():
		var snap: Dictionary = _snaps[snap_name]
		var counters: Dictionary = snap.get("counters", {})
		for k in counters.keys():
			if not counter_keys.has(k):
				counter_keys.append(k)
	counter_keys.sort()

	var header: PackedStringArray = ["name", "timestamp_ms", "fps", "node_count"]
	for k in counter_keys:
		header.append(_csv_escape(str(k)))
	var rows: PackedStringArray = [",".join(header)]

	for snap_name in _snaps.keys():
		var snap: Dictionary = _snaps[snap_name]
		var row: PackedStringArray = [
			_csv_escape(str(snap_name)),
			str(snap.get("timestamp_ms", 0)),
			str(snap.get("fps", 0)),
			str(snap.get("node_count", 0)),
		]
		var counters: Dictionary = snap.get("counters", {})
		for k in counter_keys:
			row.append(_csv_escape(str(counters.get(k, ""))))
		rows.append(",".join(row))

	var file := FileAccess.open(path, FileAccess.WRITE)
	if not file:
		return _format_error("Cannot open %s for write (err %d)" % [path, FileAccess.get_open_error()])
	file.store_string("\n".join(rows) + "\n")
	file.close()
	return _format_success("Wrote %s row(s) to %s" % [
		_color_number(str(_snaps.size())),
		_color_path(path),
	])

func _cmd_frame_screenshot(args: Array, piped_input: String = "") -> String:
	var snap_name := str(args[0]).strip_edges() if args.size() > 0 else ""
	if snap_name.is_empty():
		snap_name = _auto_name()
	var snap := _capture_snapshot()
	_snaps[snap_name] = snap

	var tree := Engine.get_main_loop() as SceneTree
	if not tree or not tree.root:
		return _format_error("No SceneTree/root available for screenshot.")
	var viewport: Viewport = tree.root
	var texture := viewport.get_texture()
	if not texture:
		return _format_error("Viewport has no texture.")
	var image := texture.get_image()
	if not image:
		return _format_error("Failed to read viewport image.")

	var png_path := "user://frame_screenshot_%s.png" % snap_name
	var err := image.save_png(png_path)
	if err != OK:
		return _format_error("save_png failed (err %d) at %s" % [err, png_path])
	snap["screenshot_path"] = png_path
	return _format_success("Screenshot %s -> %s (fps=%s, nodes=%s)" % [
		_color_path(snap_name),
		_color_path(png_path),
		_color_number(str(snap.get("fps", 0))),
		_color_number(str(snap.get("node_count", 0))),
	])

#endregion

#region Helpers

func _on_record_tick() -> void:
	_record_index += 1
	var snap_name := "rec_%04d" % _record_index
	_snaps[snap_name] = _capture_snapshot()

func _capture_snapshot() -> Dictionary:
	var counters: Dictionary = {}
	for id in range(Performance.MONITOR_MAX):
		var key := _performance_monitor_name(id)
		counters[key] = Performance.get_monitor(id)
	var root := _get_scene_root()
	var node_count: int = 0
	if root:
		node_count = _count_nodes(root)
	return {
		"timestamp_ms": Time.get_ticks_msec(),
		"fps": Engine.get_frames_per_second(),
		"node_count": node_count,
		"counters": counters,
	}

func _performance_monitor_name(id: int) -> String:
	match id:
		Performance.TIME_FPS: return "time_fps"
		Performance.TIME_PROCESS: return "time_process"
		Performance.TIME_PHYSICS_PROCESS: return "time_physics_process"
		Performance.TIME_NAVIGATION_PROCESS: return "time_navigation_process"
		Performance.MEMORY_STATIC: return "memory_static"
		Performance.MEMORY_STATIC_MAX: return "memory_static_max"
		Performance.MEMORY_MESSAGE_BUFFER_MAX: return "memory_message_buffer_max"
		Performance.OBJECT_COUNT: return "object_count"
		Performance.OBJECT_RESOURCE_COUNT: return "object_resource_count"
		Performance.OBJECT_NODE_COUNT: return "object_node_count"
		Performance.OBJECT_ORPHAN_NODE_COUNT: return "object_orphan_node_count"
		Performance.RENDER_TOTAL_OBJECTS_IN_FRAME: return "render_total_objects_in_frame"
		Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME: return "render_total_primitives_in_frame"
		Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME: return "render_total_draw_calls_in_frame"
		Performance.RENDER_VIDEO_MEM_USED: return "render_video_mem_used"
		Performance.RENDER_TEXTURE_MEM_USED: return "render_texture_mem_used"
		Performance.RENDER_BUFFER_MEM_USED: return "render_buffer_mem_used"
		Performance.PHYSICS_2D_ACTIVE_OBJECTS: return "physics_2d_active_objects"
		Performance.PHYSICS_2D_COLLISION_PAIRS: return "physics_2d_collision_pairs"
		Performance.PHYSICS_2D_ISLAND_COUNT: return "physics_2d_island_count"
		Performance.PHYSICS_3D_ACTIVE_OBJECTS: return "physics_3d_active_objects"
		Performance.PHYSICS_3D_COLLISION_PAIRS: return "physics_3d_collision_pairs"
		Performance.PHYSICS_3D_ISLAND_COUNT: return "physics_3d_island_count"
		Performance.AUDIO_OUTPUT_LATENCY: return "audio_output_latency"
		_: return "monitor_%d" % id

func _count_nodes(node: Node) -> int:
	var total: int = 1
	for child in node.get_children():
		total += _count_nodes(child)
	return total

func _get_scene_root() -> Node:
	if Engine.is_editor_hint():
		return EditorInterface.get_edited_scene_root()
	var tree := Engine.get_main_loop() as SceneTree
	if not tree:
		return null
	if tree.current_scene:
		return tree.current_scene
	return tree.root

func _auto_name() -> String:
	_snap_counter += 1
	return "snap_%04d" % _snap_counter

func _csv_escape(s: String) -> String:
	if s.contains(",") or s.contains("\"") or s.contains("\n") or s.contains("\r"):
		return "\"" + s.replace("\"", "\"\"") + "\""
	return s

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

#endregion

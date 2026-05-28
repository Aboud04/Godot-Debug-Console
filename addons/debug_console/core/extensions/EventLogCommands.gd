@tool
class_name DebugConsoleEventLogCommands extends RefCounted

# Extension module - InputEvent stream recorder and replayer.
#
# Mirrors the ActionRecorder pattern (capture / show / save / load / replay)
# but operates on raw `InputEvent` objects instead of executed commands. The
# goal is to make input-driven bugs reproducible: hit `event_record_start`,
# play through the buggy sequence, then `event_save` / `event_replay` to
# trigger the same sequence again with identical timing via
# `Input.parse_input_event()`.
#
# Architecture:
#   * `_Hook` is an inner Node attached to the SceneTree root. Its
#     `_unhandled_input` callback feeds every event into `_capture_event()`
#     on this module via a WeakRef back-pointer. We use a Node (not a signal)
#     because `_unhandled_input` is the canonical, low-overhead capture point
#     and lets us forward through `Input.parse_input_event()` during replay
#     without re-entering our own hook.
#   * `_replaying` is set during replay so captured events triggered by
#     `Input.parse_input_event()` do not poison the buffer.
#   * The buffer holds plain Dictionaries (`{t: float, type: String, ...}`)
#     so the same in-memory representation round-trips through JSON without
#     any extra translation layer.
#
# Filter granularity matches Godot's InputEvent hierarchy:
#   "key"     -> InputEventKey
#   "mouse"   -> InputEventMouseButton + InputEventMouseMotion
#   "joypad"  -> InputEventJoypadButton + InputEventJoypadMotion
#   "gesture" -> InputEventGesture + InputEventScreenTouch + InputEventScreenDrag
#   "all"/"" -> everything

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_MUTED := "#888888"

var _registry: Node
var _core: Node
var _hook: Node = null
var _recording: bool = false
var _replaying: bool = false
var _start_time_us: int = 0
var _buffer: Array = []
var _filter: String = "all"

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("event_record_start", _cmd_event_record_start, "Begin capturing InputEvents via an _unhandled_input hook: event_record_start", "both")
	_registry.register_command("event_record_stop", _cmd_event_record_stop, "Stop capturing InputEvents (buffer retained): event_record_stop", "both")
	_registry.register_command("event_show", _cmd_event_show, "Show last N captured events with timestamps + details: event_show [limit]", "both")
	_registry.register_command("event_replay", _cmd_event_replay, "Replay captured events via Input.parse_input_event with original timing: event_replay [speed]", "both")
	_registry.register_command("event_save", _cmd_event_save, "Save event buffer to JSON: event_save <user://path.json>", "both")
	_registry.register_command("event_load", _cmd_event_load, "Load event buffer from JSON: event_load <user://path.json>", "both")
	_registry.register_command("event_filter", _cmd_event_filter, "Only record events of a given type: event_filter <key|mouse|joypad|gesture|all>", "both")

#region Inner Node helper

class _Hook extends Node:
	var owner_ref: WeakRef = null

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS

	func _unhandled_input(event: InputEvent) -> void:
		if owner_ref == null:
			return
		var m: Object = owner_ref.get_ref()
		if m and m.has_method("_capture_event"):
			m.call("_capture_event", event)

	func run_replay(events: Array, speed: float, on_done: Callable) -> void:
		var prev_t: float = 0.0
		for i in range(events.size()):
			var entry: Dictionary = events[i]
			var t: float = float(entry.get("t", 0.0))
			var dt: float = maxf(0.0, t - prev_t)
			prev_t = t
			if dt > 0.0:
				await get_tree().create_timer(dt / speed).timeout
			var ev: InputEvent = _build_event(entry)
			if ev != null:
				Input.parse_input_event(ev)
		if on_done.is_valid():
			on_done.call()

	static func _build_event(d: Dictionary) -> InputEvent:
		var type_name: String = str(d.get("type", ""))
		match type_name:
			"InputEventKey":
				var ev := InputEventKey.new()
				ev.keycode = int(d.get("keycode", 0))
				ev.physical_keycode = int(d.get("physical_keycode", 0))
				ev.key_label = int(d.get("key_label", 0))
				ev.unicode = int(d.get("unicode", 0))
				ev.pressed = bool(d.get("pressed", false))
				ev.echo = bool(d.get("echo", false))
				ev.shift_pressed = bool(d.get("shift", false))
				ev.ctrl_pressed = bool(d.get("ctrl", false))
				ev.alt_pressed = bool(d.get("alt", false))
				ev.meta_pressed = bool(d.get("meta", false))
				return ev
			"InputEventMouseButton":
				var ev := InputEventMouseButton.new()
				ev.button_index = int(d.get("button_index", 0))
				ev.pressed = bool(d.get("pressed", false))
				ev.double_click = bool(d.get("double_click", false))
				ev.position = _dict_to_vec2(d.get("position", null))
				ev.global_position = _dict_to_vec2(d.get("global_position", null))
				ev.factor = float(d.get("factor", 1.0))
				return ev
			"InputEventMouseMotion":
				var ev := InputEventMouseMotion.new()
				ev.position = _dict_to_vec2(d.get("position", null))
				ev.global_position = _dict_to_vec2(d.get("global_position", null))
				ev.relative = _dict_to_vec2(d.get("relative", null))
				ev.velocity = _dict_to_vec2(d.get("velocity", null))
				ev.pressure = float(d.get("pressure", 0.0))
				return ev
			"InputEventJoypadButton":
				var ev := InputEventJoypadButton.new()
				ev.device = int(d.get("device", 0))
				ev.button_index = int(d.get("button_index", 0))
				ev.pressed = bool(d.get("pressed", false))
				ev.pressure = float(d.get("pressure", 0.0))
				return ev
			"InputEventJoypadMotion":
				var ev := InputEventJoypadMotion.new()
				ev.device = int(d.get("device", 0))
				ev.axis = int(d.get("axis", 0))
				ev.axis_value = float(d.get("axis_value", 0.0))
				return ev
			"InputEventScreenTouch":
				var ev := InputEventScreenTouch.new()
				ev.index = int(d.get("index", 0))
				ev.pressed = bool(d.get("pressed", false))
				ev.position = _dict_to_vec2(d.get("position", null))
				ev.double_tap = bool(d.get("double_tap", false))
				return ev
			"InputEventScreenDrag":
				var ev := InputEventScreenDrag.new()
				ev.index = int(d.get("index", 0))
				ev.position = _dict_to_vec2(d.get("position", null))
				ev.relative = _dict_to_vec2(d.get("relative", null))
				ev.velocity = _dict_to_vec2(d.get("velocity", null))
				ev.pressure = float(d.get("pressure", 0.0))
				return ev
			"InputEventMagnifyGesture":
				var ev := InputEventMagnifyGesture.new()
				ev.position = _dict_to_vec2(d.get("position", null))
				ev.factor = float(d.get("factor", 1.0))
				return ev
			"InputEventPanGesture":
				var ev := InputEventPanGesture.new()
				ev.position = _dict_to_vec2(d.get("position", null))
				ev.delta = _dict_to_vec2(d.get("delta", null))
				return ev
			"InputEventAction":
				var ev := InputEventAction.new()
				ev.action = StringName(str(d.get("action", "")))
				ev.pressed = bool(d.get("pressed", false))
				ev.strength = float(d.get("strength", 1.0))
				return ev
		return null

	static func _dict_to_vec2(value: Variant) -> Vector2:
		if value is Vector2:
			return value
		if value is Dictionary:
			var d: Dictionary = value
			return Vector2(float(d.get("x", 0.0)), float(d.get("y", 0.0)))
		if value is Array and (value as Array).size() >= 2:
			var a: Array = value
			return Vector2(float(a[0]), float(a[1]))
		return Vector2.ZERO

#endregion

#region Public API

func _capture_event(event: InputEvent) -> void:
	if not _recording or _replaying or event == null:
		return
	if not _filter_passes(event):
		return
	var t: float = float(Time.get_ticks_usec() - _start_time_us) / 1_000_000.0
	var entry: Dictionary = _serialize_event(event)
	entry["t"] = t
	_buffer.append(entry)

func is_recording() -> bool:
	return _recording

func get_buffer() -> Array:
	return _buffer.duplicate(true)

#endregion

#region Command implementations

func _cmd_event_record_start(_args: Array, _piped_input: String = "") -> String:
	var hook := _ensure_hook()
	if hook == null:
		return _format_error("No SceneTree available; cannot install input hook.")
	_buffer.clear()
	_start_time_us = Time.get_ticks_usec()
	_recording = true
	return _format_success("Event recording ON (filter=%s). Hook attached at %s." % [
		_color_path(_filter),
		_color_path(str(hook.get_path())),
	])

func _cmd_event_record_stop(_args: Array, _piped_input: String = "") -> String:
	_recording = false
	return _format_success("Event recording OFF. Buffer holds %s event(s)." % _color_number(str(_buffer.size())))

func _cmd_event_show(args: Array, _piped_input: String = "") -> String:
	var n: int = 50
	if args.size() > 0:
		var v: Variant = args[0]
		if typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT:
			n = int(v)
		else:
			n = int(str(v))
	if n <= 0:
		n = 50
	if _buffer.is_empty():
		return _format_muted("(buffer empty)")
	var start: int = maxi(0, _buffer.size() - n)
	var out: PackedStringArray = PackedStringArray()
	out.append("%s %s of %s event(s) [filter=%s, recording=%s]:" % [
		_color_muted("Showing last"),
		_color_number(str(_buffer.size() - start)),
		_color_number(str(_buffer.size())),
		_color_path(_filter),
		_color_number("true" if _recording else "false"),
	])
	for i in range(start, _buffer.size()):
		var entry: Dictionary = _buffer[i]
		var t: float = float(entry.get("t", 0.0))
		out.append("%s  %s  %s  %s" % [
			_color_muted("%4d" % (i + 1)),
			_color_number("%8.3fs" % t),
			_color_path(str(entry.get("type", "?"))),
			_format_event_details(entry),
		])
	return "\n".join(out)

func _cmd_event_replay(args: Array, _piped_input: String = "") -> String:
	var speed: float = 1.0
	if args.size() > 0:
		var v: Variant = args[0]
		if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
			speed = float(v)
		else:
			var s := str(v).strip_edges()
			if s.is_valid_float() or s.is_valid_int():
				speed = s.to_float()
	if speed <= 0.0:
		speed = 1.0
	if _buffer.is_empty():
		return _format_error("Buffer is empty; nothing to replay.")
	var hook := _ensure_hook()
	if hook == null:
		return _format_error("No SceneTree available; cannot replay.")
	if _replaying:
		return _format_error("Replay already in progress.")
	_replaying = true
	var snapshot: Array = _buffer.duplicate(true)
	hook.call_deferred("run_replay", snapshot, speed, Callable(self, "_on_replay_done"))
	return _format_success("Replaying %s event(s) at %sx..." % [
		_color_number(str(snapshot.size())),
		_color_number(str(speed)),
	])

func _cmd_event_save(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: event_save <user://path.json>")
	var path := str(args[0]).strip_edges()
	if path.is_empty():
		return _format_error("Path is empty.")
	if _buffer.is_empty():
		return _format_error("Buffer is empty; nothing to save.")
	var payload: Dictionary = {
		"version": 1,
		"filter": _filter,
		"event_count": _buffer.size(),
		"events": _buffer,
	}
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return _format_error("Cannot open for write: %s (err=%s)" % [path, str(FileAccess.get_open_error())])
	f.store_string(JSON.stringify(payload, "\t"))
	f.close()
	return _format_success("Saved %s event(s) to %s" % [
		_color_number(str(_buffer.size())),
		_color_path(path),
	])

func _cmd_event_load(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: event_load <user://path.json>")
	var path := str(args[0]).strip_edges()
	if path.is_empty():
		return _format_error("Path is empty.")
	if not FileAccess.file_exists(path):
		return _format_error("File not found: %s" % path)
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return _format_error("Cannot open for read: %s (err=%s)" % [path, str(FileAccess.get_open_error())])
	var text := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	if parsed == null:
		return _format_error("Invalid JSON in: %s" % path)
	var events: Array = []
	if parsed is Dictionary and (parsed as Dictionary).has("events"):
		events = (parsed as Dictionary).get("events", [])
		var loaded_filter: String = str((parsed as Dictionary).get("filter", _filter))
		if not loaded_filter.is_empty():
			_filter = loaded_filter
	elif parsed is Array:
		events = parsed
	else:
		return _format_error("Unrecognised JSON shape (expected {events:[...]} or [...]).")
	_buffer = events.duplicate(true)
	_recording = false
	return _format_success("Loaded %s event(s) from %s (filter=%s)." % [
		_color_number(str(_buffer.size())),
		_color_path(path),
		_color_path(_filter),
	])

func _cmd_event_filter(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: event_filter <key|mouse|joypad|gesture|all>")
	var f := str(args[0]).strip_edges().to_lower()
	match f:
		"key", "mouse", "joypad", "gesture", "all", "":
			_filter = "all" if f.is_empty() else f
			return _format_success("Event filter set to %s." % _color_path(_filter))
		_:
			return _format_error("Unknown filter: %s (expected key|mouse|joypad|gesture|all)" % f)

#endregion

#region Helpers

func _ensure_hook() -> Node:
	if is_instance_valid(_hook) and _hook.is_inside_tree():
		_hook.set("owner_ref", weakref(self))
		return _hook
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	var node: Node = _Hook.new()
	node.name = "_DebugConsoleEventLogHook"
	node.set("owner_ref", weakref(self))
	tree.root.add_child(node)
	_hook = node
	return _hook

func _on_replay_done() -> void:
	_replaying = false

func _filter_passes(event: InputEvent) -> bool:
	match _filter:
		"", "all":
			return true
		"key":
			return event is InputEventKey
		"mouse":
			return event is InputEventMouseButton or event is InputEventMouseMotion
		"joypad":
			return event is InputEventJoypadButton or event is InputEventJoypadMotion
		"gesture":
			return event is InputEventGesture \
				or event is InputEventScreenTouch \
				or event is InputEventScreenDrag \
				or event is InputEventMagnifyGesture \
				or event is InputEventPanGesture
		_:
			return true

func _serialize_event(event: InputEvent) -> Dictionary:
	var d: Dictionary = {"type": event.get_class()}
	if event is InputEventKey:
		var ev: InputEventKey = event
		d["keycode"] = int(ev.keycode)
		d["physical_keycode"] = int(ev.physical_keycode)
		d["key_label"] = int(ev.key_label)
		d["unicode"] = int(ev.unicode)
		d["pressed"] = ev.pressed
		d["echo"] = ev.echo
		d["shift"] = ev.shift_pressed
		d["ctrl"] = ev.ctrl_pressed
		d["alt"] = ev.alt_pressed
		d["meta"] = ev.meta_pressed
	elif event is InputEventMouseButton:
		var ev: InputEventMouseButton = event
		d["button_index"] = int(ev.button_index)
		d["pressed"] = ev.pressed
		d["double_click"] = ev.double_click
		d["position"] = _vec2_to_dict(ev.position)
		d["global_position"] = _vec2_to_dict(ev.global_position)
		d["factor"] = float(ev.factor)
	elif event is InputEventMouseMotion:
		var ev: InputEventMouseMotion = event
		d["position"] = _vec2_to_dict(ev.position)
		d["global_position"] = _vec2_to_dict(ev.global_position)
		d["relative"] = _vec2_to_dict(ev.relative)
		d["velocity"] = _vec2_to_dict(ev.velocity)
		d["pressure"] = float(ev.pressure)
	elif event is InputEventJoypadButton:
		var ev: InputEventJoypadButton = event
		d["device"] = int(ev.device)
		d["button_index"] = int(ev.button_index)
		d["pressed"] = ev.pressed
		d["pressure"] = float(ev.pressure)
	elif event is InputEventJoypadMotion:
		var ev: InputEventJoypadMotion = event
		d["device"] = int(ev.device)
		d["axis"] = int(ev.axis)
		d["axis_value"] = float(ev.axis_value)
	elif event is InputEventScreenTouch:
		var ev: InputEventScreenTouch = event
		d["index"] = int(ev.index)
		d["pressed"] = ev.pressed
		d["position"] = _vec2_to_dict(ev.position)
		d["double_tap"] = ev.double_tap
	elif event is InputEventScreenDrag:
		var ev: InputEventScreenDrag = event
		d["index"] = int(ev.index)
		d["position"] = _vec2_to_dict(ev.position)
		d["relative"] = _vec2_to_dict(ev.relative)
		d["velocity"] = _vec2_to_dict(ev.velocity)
		d["pressure"] = float(ev.pressure)
	elif event is InputEventMagnifyGesture:
		var ev: InputEventMagnifyGesture = event
		d["position"] = _vec2_to_dict(ev.position)
		d["factor"] = float(ev.factor)
	elif event is InputEventPanGesture:
		var ev: InputEventPanGesture = event
		d["position"] = _vec2_to_dict(ev.position)
		d["delta"] = _vec2_to_dict(ev.delta)
	elif event is InputEventAction:
		var ev: InputEventAction = event
		d["action"] = str(ev.action)
		d["pressed"] = ev.pressed
		d["strength"] = float(ev.strength)
	else:
		d["as_text"] = event.as_text()
	return d

func _format_event_details(entry: Dictionary) -> String:
	var type_name: String = str(entry.get("type", ""))
	match type_name:
		"InputEventKey":
			var key := int(entry.get("keycode", 0))
			var key_name: String = OS.get_keycode_string(key) if key != 0 else "?"
			return "%s key=%s unicode=%d%s%s" % [
				"DOWN" if bool(entry.get("pressed", false)) else "UP  ",
				key_name,
				int(entry.get("unicode", 0)),
				" echo" if bool(entry.get("echo", false)) else "",
				_mods_suffix(entry),
			]
		"InputEventMouseButton":
			return "%s btn=%d pos=%s%s" % [
				"DOWN" if bool(entry.get("pressed", false)) else "UP  ",
				int(entry.get("button_index", 0)),
				_vec_str(entry.get("position", null)),
				" double" if bool(entry.get("double_click", false)) else "",
			]
		"InputEventMouseMotion":
			return "pos=%s rel=%s" % [
				_vec_str(entry.get("position", null)),
				_vec_str(entry.get("relative", null)),
			]
		"InputEventJoypadButton":
			return "%s dev=%d btn=%d" % [
				"DOWN" if bool(entry.get("pressed", false)) else "UP  ",
				int(entry.get("device", 0)),
				int(entry.get("button_index", 0)),
			]
		"InputEventJoypadMotion":
			return "dev=%d axis=%d value=%.3f" % [
				int(entry.get("device", 0)),
				int(entry.get("axis", 0)),
				float(entry.get("axis_value", 0.0)),
			]
		"InputEventScreenTouch":
			return "%s idx=%d pos=%s" % [
				"DOWN" if bool(entry.get("pressed", false)) else "UP  ",
				int(entry.get("index", 0)),
				_vec_str(entry.get("position", null)),
			]
		"InputEventScreenDrag":
			return "idx=%d pos=%s rel=%s" % [
				int(entry.get("index", 0)),
				_vec_str(entry.get("position", null)),
				_vec_str(entry.get("relative", null)),
			]
		"InputEventMagnifyGesture":
			return "pos=%s factor=%.3f" % [
				_vec_str(entry.get("position", null)),
				float(entry.get("factor", 1.0)),
			]
		"InputEventPanGesture":
			return "pos=%s delta=%s" % [
				_vec_str(entry.get("position", null)),
				_vec_str(entry.get("delta", null)),
			]
		"InputEventAction":
			return "%s action=%s strength=%.3f" % [
				"DOWN" if bool(entry.get("pressed", false)) else "UP  ",
				str(entry.get("action", "")),
				float(entry.get("strength", 0.0)),
			]
	return str(entry.get("as_text", ""))

func _mods_suffix(entry: Dictionary) -> String:
	var parts: PackedStringArray = PackedStringArray()
	if bool(entry.get("shift", false)):
		parts.append("shift")
	if bool(entry.get("ctrl", false)):
		parts.append("ctrl")
	if bool(entry.get("alt", false)):
		parts.append("alt")
	if bool(entry.get("meta", false)):
		parts.append("meta")
	if parts.is_empty():
		return ""
	return " [%s]" % "+".join(parts)

func _vec2_to_dict(v: Vector2) -> Dictionary:
	return {"x": v.x, "y": v.y}

func _vec_str(value: Variant) -> String:
	if value is Dictionary:
		var d: Dictionary = value
		return "(%.1f,%.1f)" % [float(d.get("x", 0.0)), float(d.get("y", 0.0))]
	if value is Vector2:
		var v: Vector2 = value
		return "(%.1f,%.1f)" % [v.x, v.y]
	return "?"

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

func _color_muted(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_MUTED, s]

#endregion

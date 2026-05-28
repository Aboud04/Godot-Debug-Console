@tool
class_name DebugConsoleRuntimeCommands extends RefCounted

# Engine/input/viewport/asset commands. Shipped as a separate module
# from BuiltInCommands.gd to keep that file manageable. Owned by the live
# plugin instance, which holds a strong reference so Callables stay valid.

const _COLOR_HEADER := "#5FBEE0"
const _COLOR_VALUE := "#F7DC6F"
const _COLOR_HIGHLIGHT := "#7EE787"
const _COLOR_WARN := "#FFD700"
const _COLOR_ERROR := "#FF6B6B"
const _COLOR_DIM := "#909090"

const _SKIP_DIRS: Array[String] = [".git", ".godot", "addons/godot_mcp", "addons/godotiq"]
const _ASSET_LIMIT: int = 200
const _FIND_LIMIT: int = 100
const _SAVE_DIR := "user://saves"

var _registry: Node
var _core: Node

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("input_action", _cmd_input_action, "Trigger an InputEvent: input_action <name> [press|release|tap]", "game")
	_registry.register_command("input_dump", _cmd_input_dump, "List configured input actions and their bindings; optional substring filter", "both")
	_registry.register_command("bind", _cmd_bind, "Add a key binding: bind <action> <key> (key like 'Space' or 'Ctrl+S')", "both")
	_registry.register_command("unbind", _cmd_unbind, "Remove bindings: unbind <action> [key] (no key = remove all bindings)", "both")
	_registry.register_command("step", _cmd_step, "Advance N physics frames while paused: step [n] (default 1)", "game")
	_registry.register_command("viewport", _cmd_viewport, "Query/set viewport: viewport [<WxH>|borderless|fullscreen|windowed]", "game")
	_registry.register_command("fullscreen", _cmd_fullscreen, "Toggle or set fullscreen: fullscreen [on|off]", "game")
	_registry.register_command("assets", _cmd_assets, "List all resource files in res:// (optional substring filter)", "both")
	_registry.register_command("find_asset", _cmd_find_asset, "Search res:// for files matching a glob pattern", "both")
	_registry.register_command("goto_scene", _cmd_goto_scene, "Change current scene at runtime: goto_scene <res://scene.tscn>", "game")
	_registry.register_command("save_world", _cmd_save_world, "Save exported properties of scene-tree nodes to user://saves/world_<name>.json (limited: only @export vars on existing nodes)", "game")
	_registry.register_command("load_world", _cmd_load_world, "Load a save_world snapshot by name", "game")
	_registry.register_command("tick_rate", _cmd_tick_rate, "Get/set engine tick rate: tick_rate [physics_tps] [render_fps] (1-1000)", "game")
	_registry.register_command("vsync", _cmd_vsync, "Get/set window vsync mode: vsync [on|off|adaptive]", "game")
	_registry.register_command("audio_bus", _cmd_audio_bus, "Inspect or modify audio buses: audio_bus [<bus>] [<vol_db>|mute|unmute]", "game")

#region Helpers

func _format_error(msg: String) -> String:
	return "[color=%s]Error:[/color] %s" % [_COLOR_ERROR, msg]

func _format_header(text: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_HEADER, text]

func _format_value(text: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_VALUE, text]

func _format_event(event: InputEvent) -> String:
	if event is InputEventKey:
		return _format_keycode(event)
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		var btn: String = _mouse_button_name(mb.button_index)
		return "Mouse:%s" % btn
	if event is InputEventJoypadButton:
		var jb := event as InputEventJoypadButton
		return "JoyButton:%d" % jb.button_index
	if event is InputEventJoypadMotion:
		var jm := event as InputEventJoypadMotion
		return "JoyAxis:%d=%.2f" % [jm.axis, jm.axis_value]
	return event.as_text()

func _format_keycode(event: InputEventKey) -> String:
	var parts: Array[String] = []
	if event.ctrl_pressed:
		parts.append("Ctrl")
	if event.alt_pressed:
		parts.append("Alt")
	if event.shift_pressed:
		parts.append("Shift")
	if event.meta_pressed:
		parts.append("Meta")
	# physical_keycode is reliable across locales; fall back to keycode.
	var kc: int = event.physical_keycode if event.physical_keycode != 0 else event.keycode
	var name: String = OS.get_keycode_string(kc) if kc != 0 else "<unbound>"
	parts.append(name if not name.is_empty() else "<unknown>")
	return "+".join(parts)

func _mouse_button_name(idx: int) -> String:
	match idx:
		MOUSE_BUTTON_LEFT: return "Left"
		MOUSE_BUTTON_RIGHT: return "Right"
		MOUSE_BUTTON_MIDDLE: return "Middle"
		MOUSE_BUTTON_WHEEL_UP: return "WheelUp"
		MOUSE_BUTTON_WHEEL_DOWN: return "WheelDown"
		MOUSE_BUTTON_XBUTTON1: return "XButton1"
		MOUSE_BUTTON_XBUTTON2: return "XButton2"
	return "Button%d" % idx

# Parses key specs like "Space", "F1", "Ctrl+S", "Ctrl+Shift+P".
# Returns null on parse failure.
func _parse_key_spec(spec: String) -> InputEventKey:
	var trimmed: String = spec.strip_edges()
	if trimmed.is_empty():
		return null
	var tokens: PackedStringArray = trimmed.split("+", false)
	var event := InputEventKey.new()
	var base_token: String = ""
	for raw in tokens:
		var t: String = raw.strip_edges()
		var t_low: String = t.to_lower()
		match t_low:
			"ctrl", "control":
				event.ctrl_pressed = true
			"alt":
				event.alt_pressed = true
			"shift":
				event.shift_pressed = true
			"meta", "cmd", "command", "super":
				event.meta_pressed = true
			_:
				base_token = t
	if base_token.is_empty():
		return null
	var kc: int = OS.find_keycode_from_string(base_token)
	if kc == 0:
		# Try title-case fallback so "space" still resolves like "Space".
		kc = OS.find_keycode_from_string(base_token.capitalize())
	if kc == 0:
		return null
	event.physical_keycode = kc
	event.keycode = kc
	return event

# Walks res:// applying callback to every file path encountered. Skips the
# documented hidden + addon dirs so the console never surfaces vendored MCP
# code or .godot import junk.
func _walk_res(callback: Callable) -> void:
	_walk_res_recursive("res://", callback)

func _walk_res_recursive(path: String, callback: Callable) -> void:
	var rel: String = path.trim_prefix("res://").rstrip("/")
	for skip in _SKIP_DIRS:
		if rel == skip or rel.begins_with(skip + "/"):
			return
	var dir := DirAccess.open(path)
	if not dir:
		return
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while entry != "":
		if entry == "." or entry == "..":
			entry = dir.get_next()
			continue
		var sep: String = "" if path.ends_with("/") else "/"
		var full: String = path + sep + entry
		if dir.current_is_dir():
			_walk_res_recursive(full, callback)
		else:
			callback.call(full)
		entry = dir.get_next()
	dir.list_dir_end()

func _ensure_save_dir() -> bool:
	if DirAccess.dir_exists_absolute(_SAVE_DIR):
		return true
	return DirAccess.make_dir_recursive_absolute(_SAVE_DIR) == OK

# Format value as a string suitable for JSON round-trip. Vectors/Colors/etc.
# become arrays; primitives pass through; complex objects degrade to str().
func _serialize_value(v: Variant) -> Variant:
	var t: int = typeof(v)
	match t:
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING, TYPE_STRING_NAME:
			return v
		TYPE_VECTOR2:
			return {"__type": "Vector2", "x": v.x, "y": v.y}
		TYPE_VECTOR2I:
			return {"__type": "Vector2i", "x": v.x, "y": v.y}
		TYPE_VECTOR3:
			return {"__type": "Vector3", "x": v.x, "y": v.y, "z": v.z}
		TYPE_VECTOR3I:
			return {"__type": "Vector3i", "x": v.x, "y": v.y, "z": v.z}
		TYPE_COLOR:
			return {"__type": "Color", "r": v.r, "g": v.g, "b": v.b, "a": v.a}
		TYPE_RECT2:
			return {"__type": "Rect2", "x": v.position.x, "y": v.position.y, "w": v.size.x, "h": v.size.y}
		TYPE_ARRAY:
			var out: Array = []
			for item in v:
				out.append(_serialize_value(item))
			return out
		TYPE_DICTIONARY:
			var dict_out: Dictionary = {}
			for key in v.keys():
				dict_out[str(key)] = _serialize_value(v[key])
			return dict_out
	return str(v)

func _deserialize_value(v: Variant) -> Variant:
	if typeof(v) == TYPE_DICTIONARY and v.has("__type"):
		var marker: String = str(v["__type"])
		match marker:
			"Vector2":
				return Vector2(float(v.get("x", 0.0)), float(v.get("y", 0.0)))
			"Vector2i":
				return Vector2i(int(v.get("x", 0)), int(v.get("y", 0)))
			"Vector3":
				return Vector3(float(v.get("x", 0.0)), float(v.get("y", 0.0)), float(v.get("z", 0.0)))
			"Vector3i":
				return Vector3i(int(v.get("x", 0)), int(v.get("y", 0)), int(v.get("z", 0)))
			"Color":
				return Color(float(v.get("r", 0.0)), float(v.get("g", 0.0)), float(v.get("b", 0.0)), float(v.get("a", 1.0)))
			"Rect2":
				return Rect2(float(v.get("x", 0.0)), float(v.get("y", 0.0)), float(v.get("w", 0.0)), float(v.get("h", 0.0)))
	if typeof(v) == TYPE_ARRAY:
		var out: Array = []
		for item in v:
			out.append(_deserialize_value(item))
		return out
	return v

func _format_bytes(bytes: int) -> String:
	var b: float = float(bytes)
	if b < 1024.0:
		return "%d B" % bytes
	if b < 1024.0 * 1024.0:
		return "%.1f KiB" % (b / 1024.0)
	if b < 1024.0 * 1024.0 * 1024.0:
		return "%.2f MiB" % (b / (1024.0 * 1024.0))
	return "%.2f GiB" % (b / (1024.0 * 1024.0 * 1024.0))

func _get_scene_tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree

#endregion

#region Input commands

func _cmd_input_action(args: Array) -> String:
	if args.is_empty():
		return "Usage: input_action <name> [press|release|tap]"
	var action_name: String = str(args[0])
	if not InputMap.has_action(action_name):
		return _format_error("unknown action: %s" % action_name)
	var mode: String = "tap"
	if args.size() > 1:
		mode = str(args[1]).strip_edges().to_lower()
	match mode:
		"press":
			Input.action_press(action_name)
		"release":
			Input.action_release(action_name)
		"tap":
			Input.action_press(action_name)
			Input.action_release(action_name)
		_:
			return _format_error("mode must be press|release|tap, got: %s" % mode)
	return "Triggered %s: %s" % [_format_value(action_name), mode]

func _cmd_input_dump(args: Array) -> String:
	var filter: String = ""
	if args.size() > 0:
		filter = str(args[0]).strip_edges().to_lower()
	var actions: Array[StringName] = InputMap.get_actions()
	var rows: Array[Array] = []
	for raw in actions:
		var action: String = String(raw)
		if not filter.is_empty() and not action.to_lower().contains(filter):
			continue
		var events: Array[InputEvent] = InputMap.action_get_events(action)
		var parts: Array[String] = []
		for e in events:
			parts.append(_format_event(e))
		var bindings: String = ", ".join(parts) if parts.size() > 0 else "(no bindings)"
		rows.append([action, bindings])
	if rows.is_empty():
		if filter.is_empty():
			return "No input actions registered"
		return "No actions matched filter: %s" % filter
	rows.sort_custom(func(a, b): return String(a[0]) < String(b[0]))
	var max_name: int = 4
	for row in rows:
		max_name = max(max_name, String(row[0]).length())
	var lines: Array[String] = []
	lines.append(_format_header("== Input Actions (%d) ==" % rows.size()))
	for row in rows:
		var name_padded: String = String(row[0]).rpad(max_name)
		lines.append("  %s  [color=%s]%s[/color]" % [name_padded, _COLOR_VALUE, row[1]])
	return "\n".join(lines)

func _cmd_bind(args: Array) -> String:
	if args.size() < 2:
		return "Usage: bind <action> <key>   (e.g. bind jump Space, bind save Ctrl+S)"
	var action: String = str(args[0])
	var key_spec: String = " ".join(args.slice(1)).strip_edges()
	var event := _parse_key_spec(key_spec)
	if not event:
		return _format_error("could not parse key spec: '%s' (try 'Space', 'F1', 'Ctrl+S')" % key_spec)
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	InputMap.action_add_event(action, event)
	var count: int = InputMap.action_get_events(action).size()
	return "Bound %s -> %s (%d binding%s)" % [
		_format_value(action),
		_format_event(event),
		count,
		"" if count == 1 else "s",
	]

func _cmd_unbind(args: Array) -> String:
	if args.is_empty():
		return "Usage: unbind <action> [key]"
	var action: String = str(args[0])
	if not InputMap.has_action(action):
		return _format_error("unknown action: %s" % action)
	if args.size() == 1:
		InputMap.action_erase_events(action)
		return "Cleared all bindings for %s" % _format_value(action)
	var key_spec: String = " ".join(args.slice(1)).strip_edges()
	var target := _parse_key_spec(key_spec)
	if not target:
		return _format_error("could not parse key spec: '%s'" % key_spec)
	var events: Array[InputEvent] = InputMap.action_get_events(action)
	var removed: int = 0
	for e in events:
		if e is InputEventKey:
			var ek := e as InputEventKey
			var matches_kc: bool = (ek.physical_keycode == target.physical_keycode) or (ek.keycode == target.keycode and target.keycode != 0)
			if matches_kc \
					and ek.ctrl_pressed == target.ctrl_pressed \
					and ek.alt_pressed == target.alt_pressed \
					and ek.shift_pressed == target.shift_pressed \
					and ek.meta_pressed == target.meta_pressed:
				InputMap.action_erase_event(action, e)
				removed += 1
	if removed == 0:
		return "No matching binding removed from %s (spec: %s)" % [action, key_spec]
	return "Removed %d binding%s from %s" % [removed, "" if removed == 1 else "s", _format_value(action)]

#endregion

#region Runtime control

func _cmd_step(args: Array) -> String:
	if Engine.is_editor_hint():
		return _format_error("step only works in runtime")
	var tree := _get_scene_tree()
	if not tree:
		return _format_error("step requires an active SceneTree")
	if not tree.paused:
		return _format_error("step requires the tree to be paused first (run 'pause' to pause)")
	var n: int = 1
	if args.size() > 0:
		var raw: String = str(args[0]).strip_edges()
		if not raw.is_valid_int():
			return _format_error("step takes an integer count, got: %s" % raw)
		n = raw.to_int()
		if n < 1:
			return _format_error("step count must be >= 1")
		if n > 10000:
			return _format_error("step count too large (max 10000)")
	var prev_scale: float = Engine.time_scale
	Engine.time_scale = 1.0
	tree.paused = false
	var tps: int = max(Engine.physics_ticks_per_second, 1)
	var sleep_ms: int = int(ceil(float(n) * 1000.0 / float(tps)))
	OS.delay_msec(sleep_ms)
	tree.paused = true
	Engine.time_scale = prev_scale
	return "Stepped %d physics frame%s (~%d ms)" % [n, "" if n == 1 else "s", sleep_ms]

func _cmd_viewport(args: Array) -> String:
	if Engine.is_editor_hint():
		return _format_error("viewport only works in runtime")
	if args.is_empty():
		var size: Vector2i = DisplayServer.window_get_size()
		var mode: int = DisplayServer.window_get_mode()
		var borderless: bool = DisplayServer.window_get_flag(DisplayServer.WINDOW_FLAG_BORDERLESS)
		var dpi: int = DisplayServer.screen_get_dpi()
		var mode_str: String = _window_mode_name(mode)
		var lines: Array[String] = []
		lines.append(_format_header("== Viewport =="))
		lines.append("  size       = [color=%s]%dx%d[/color]" % [_COLOR_VALUE, size.x, size.y])
		lines.append("  mode       = [color=%s]%s[/color]" % [_COLOR_VALUE, mode_str])
		lines.append("  borderless = [color=%s]%s[/color]" % [_COLOR_VALUE, "true" if borderless else "false"])
		lines.append("  dpi        = [color=%s]%d[/color]" % [_COLOR_VALUE, dpi])
		return "\n".join(lines)
	var spec: String = str(args[0]).strip_edges().to_lower()
	match spec:
		"borderless":
			DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, true)
			return "Viewport: borderless ON"
		"bordered":
			DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, false)
			return "Viewport: borderless OFF"
		"fullscreen":
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN)
			return "Viewport: fullscreen (exclusive)"
		"windowed":
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
			return "Viewport: windowed"
		_:
			if spec.contains("x"):
				var parts: PackedStringArray = spec.split("x")
				if parts.size() != 2 or not String(parts[0]).is_valid_int() or not String(parts[1]).is_valid_int():
					return _format_error("size must look like 1920x1080, got: %s" % spec)
				var w: int = String(parts[0]).to_int()
				var h: int = String(parts[1]).to_int()
				if w < 1 or h < 1 or w > 16384 or h > 16384:
					return _format_error("size out of range (1-16384), got: %dx%d" % [w, h])
				DisplayServer.window_set_size(Vector2i(w, h))
				return "Viewport: %dx%d" % [w, h]
			return _format_error("unknown viewport arg: %s (try <WxH>, borderless, fullscreen, windowed)" % spec)

func _window_mode_name(mode: int) -> String:
	match mode:
		DisplayServer.WINDOW_MODE_WINDOWED: return "windowed"
		DisplayServer.WINDOW_MODE_MINIMIZED: return "minimized"
		DisplayServer.WINDOW_MODE_MAXIMIZED: return "maximized"
		DisplayServer.WINDOW_MODE_FULLSCREEN: return "fullscreen"
		DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN: return "exclusive_fullscreen"
	return "mode_%d" % mode

func _cmd_fullscreen(args: Array) -> String:
	if Engine.is_editor_hint():
		return _format_error("fullscreen only works in runtime")
	var target_full: bool
	if args.is_empty():
		var cur: int = DisplayServer.window_get_mode()
		var is_full: bool = cur == DisplayServer.WINDOW_MODE_FULLSCREEN or cur == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN
		target_full = not is_full
	else:
		var sub: String = str(args[0]).strip_edges().to_lower()
		match sub:
			"on", "true", "1", "yes":
				target_full = true
			"off", "false", "0", "no":
				target_full = false
			_:
				return _format_error("fullscreen takes on|off, got: %s" % sub)
	if target_full:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN)
		return "Fullscreen: ON"
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	return "Fullscreen: OFF"

#endregion

#region Asset commands

func _cmd_assets(args: Array) -> String:
	var filter: String = ""
	if args.size() > 0:
		filter = str(args[0]).strip_edges().to_lower()
	var entries: Array[Array] = []
	_walk_res(func(p: String) -> void:
		# Skip Godot's import metadata + crash-prone meta files.
		if p.ends_with(".import") or p.ends_with(".uid"):
			return
		if not filter.is_empty() and not p.to_lower().contains(filter):
			return
		var size: int = 0
		var f := FileAccess.open(p, FileAccess.READ)
		if f:
			size = int(f.get_length())
			f.close()
		var ext: String = p.get_extension().to_lower()
		if ext.is_empty():
			ext = "(none)"
		entries.append([p, size, ext])
	)
	if entries.is_empty():
		if filter.is_empty():
			return "No assets found under res://"
		return "No assets matched filter: %s" % filter
	var by_ext: Dictionary = {}
	for e in entries:
		var ext: String = String(e[2])
		if not by_ext.has(ext):
			by_ext[ext] = []
		(by_ext[ext] as Array).append(e)
	var ext_keys: Array = by_ext.keys()
	ext_keys.sort()
	var lines: Array[String] = []
	var total: int = entries.size()
	var shown: int = 0
	var truncated: bool = false
	lines.append(_format_header("== Assets in res:// (%d) ==" % total))
	for ext_key in ext_keys:
		var bucket: Array = by_ext[ext_key]
		bucket.sort_custom(func(a, b): return String(a[0]) < String(b[0]))
		lines.append("[color=%s].%s (%d)[/color]" % [_COLOR_HIGHLIGHT, ext_key, bucket.size()])
		for row in bucket:
			if shown >= _ASSET_LIMIT:
				truncated = true
				break
			lines.append("  %s  [color=%s]%s[/color]" % [String(row[0]), _COLOR_DIM, _format_bytes(int(row[1]))])
			shown += 1
		if truncated:
			break
	if truncated:
		lines.append("[color=%s]... output capped at %d entries (total %d). Use a filter to narrow.[/color]" % [_COLOR_WARN, _ASSET_LIMIT, total])
	return "\n".join(lines)

func _cmd_find_asset(args: Array) -> String:
	if args.is_empty():
		return "Usage: find_asset <glob-pattern>   (e.g. find_asset *.tscn, find_asset *icon*)"
	var pattern: String = str(args[0])
	var matches: Array[String] = []
	var capped: bool = false
	_walk_res(func(p: String) -> void:
		if capped:
			return
		if p.ends_with(".import") or p.ends_with(".uid"):
			return
		# Match against both the full path and the basename so simple globs
		# like '*.tscn' work without the user prefixing 'res://'.
		var basename: String = p.get_file()
		if basename.match(pattern) or p.match(pattern):
			matches.append(p)
			if matches.size() >= _FIND_LIMIT:
				capped = true
	)
	if matches.is_empty():
		return "No assets matched: %s" % pattern
	matches.sort()
	var lines: Array[String] = []
	lines.append(_format_header("== %d match%s for '%s' ==" % [matches.size(), "" if matches.size() == 1 else "es", pattern]))
	for m in matches:
		lines.append("  [color=%s]%s[/color]" % [_COLOR_HIGHLIGHT, m])
	if capped:
		lines.append("[color=%s]... capped at %d matches.[/color]" % [_COLOR_WARN, _FIND_LIMIT])
	return "\n".join(lines)

#endregion

#region Scene / world state

func _cmd_goto_scene(args: Array) -> String:
	if Engine.is_editor_hint():
		return _format_error("goto_scene only works in runtime; use 'reload' in editor")
	if args.is_empty():
		return "Usage: goto_scene <res://scene.tscn>"
	var path: String = str(args[0])
	if not path.begins_with("res://"):
		return _format_error("scene path must start with res:// (got: %s)" % path)
	if not FileAccess.file_exists(path):
		return _format_error("scene not found: %s" % path)
	var tree := _get_scene_tree()
	if not tree:
		return _format_error("goto_scene requires an active SceneTree")
	var err: int = tree.change_scene_to_file(path)
	if err != OK:
		return _format_error("change_scene_to_file failed (code %d)" % err)
	return "Loaded scene: %s" % _format_value(path)

func _cmd_save_world(args: Array) -> String:
	if Engine.is_editor_hint():
		return _format_error("save_world only works in runtime")
	var tree := _get_scene_tree()
	if not tree or not tree.current_scene:
		return _format_error("save_world requires an active current_scene")
	var name: String = ""
	if args.size() > 0:
		name = str(args[0]).strip_edges()
	if name.is_empty():
		name = Time.get_datetime_string_from_system().replace(":", "-")
	if not _ensure_save_dir():
		return _format_error("could not create save dir: %s" % _SAVE_DIR)
	var snapshot: Dictionary = {
		"version": 1,
		"scene": tree.current_scene.scene_file_path,
		"saved_at": Time.get_datetime_string_from_system(),
		"nodes": _snapshot_node(tree.current_scene, tree.current_scene),
	}
	var json: String = JSON.stringify(snapshot, "  ")
	var path: String = "%s/world_%s.json" % [_SAVE_DIR, name]
	var f := FileAccess.open(path, FileAccess.WRITE)
	if not f:
		return _format_error("could not open file for write: %s" % path)
	f.store_string(json)
	var size: int = int(f.get_length())
	f.close()
	return "Saved world '%s' -> %s (%s)" % [name, _format_value(path), _format_bytes(size)]

# Recursively snapshots a node and its descendants. Only properties with
# PROPERTY_USAGE_STORAGE are emitted (matches what @export marks for save).
func _snapshot_node(node: Node, root: Node) -> Dictionary:
	var entry: Dictionary = {
		"path": str(root.get_path_to(node)),
		"class": node.get_class(),
		"properties": {},
		"children": [],
	}
	for prop in node.get_property_list():
		var usage: int = int(prop.get("usage", 0))
		var pname: String = str(prop.get("name", ""))
		# Only persist @export-style storage props; skip Godot built-ins like
		# 'script' and grouped headers that have no real value.
		if (usage & PROPERTY_USAGE_STORAGE) == 0:
			continue
		if (usage & PROPERTY_USAGE_SCRIPT_VARIABLE) == 0:
			continue
		var val: Variant = node.get(pname)
		entry["properties"][pname] = _serialize_value(val)
	for child in node.get_children():
		entry["children"].append(_snapshot_node(child, root))
	return entry

func _cmd_load_world(args: Array) -> String:
	if Engine.is_editor_hint():
		return _format_error("load_world only works in runtime")
	if args.is_empty():
		return "Usage: load_world <name>"
	var name: String = str(args[0]).strip_edges()
	var path: String = "%s/world_%s.json" % [_SAVE_DIR, name]
	if not FileAccess.file_exists(path):
		return _format_error("no save found: %s" % path)
	var tree := _get_scene_tree()
	if not tree or not tree.current_scene:
		return _format_error("load_world requires an active current_scene")
	var f := FileAccess.open(path, FileAccess.READ)
	if not f:
		return _format_error("could not open save: %s" % path)
	var text: String = f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return _format_error("save file is not valid JSON: %s" % path)
	var snapshot: Dictionary = parsed
	var root_entry: Dictionary = snapshot.get("nodes", {})
	if root_entry.is_empty():
		return _format_error("save file is missing 'nodes' section")
	var counts: Dictionary = {"applied": 0, "missing": 0, "props": 0}
	_apply_snapshot(tree.current_scene, root_entry, counts)
	return "Loaded world '%s': %d node%s, %d property value%s restored, %d missing node%s" % [
		name,
		int(counts["applied"]), "" if int(counts["applied"]) == 1 else "s",
		int(counts["props"]), "" if int(counts["props"]) == 1 else "s",
		int(counts["missing"]), "" if int(counts["missing"]) == 1 else "s",
	]

func _apply_snapshot(root: Node, entry: Dictionary, counts: Dictionary) -> void:
	var rel_path: String = str(entry.get("path", "."))
	var node: Node = root if rel_path == "." else root.get_node_or_null(rel_path)
	if not node:
		counts["missing"] = int(counts["missing"]) + 1
		push_warning("[debug_console] load_world: missing node at '%s'" % rel_path)
		return
	counts["applied"] = int(counts["applied"]) + 1
	var props: Dictionary = entry.get("properties", {})
	for pname in props.keys():
		var pname_str: String = str(pname)
		node.set(pname_str, _deserialize_value(props[pname]))
		counts["props"] = int(counts["props"]) + 1
	for child_entry in entry.get("children", []):
		if typeof(child_entry) == TYPE_DICTIONARY:
			_apply_snapshot(root, child_entry, counts)

#endregion

#region Engine / display / audio

func _cmd_tick_rate(args: Array) -> String:
	if args.is_empty():
		return "Tick rate: physics=%s render_fps=%s" % [
			_format_value(str(Engine.physics_ticks_per_second)),
			_format_value(str(Engine.max_fps)),
		]
	var raw_phys: String = str(args[0]).strip_edges()
	if not raw_phys.is_valid_int():
		return _format_error("tick_rate physics arg must be an integer, got: %s" % raw_phys)
	var phys: int = raw_phys.to_int()
	if phys < 1 or phys > 1000:
		return _format_error("physics tps must be 1-1000, got: %d" % phys)
	Engine.physics_ticks_per_second = phys
	if args.size() >= 2:
		var raw_fps: String = str(args[1]).strip_edges()
		if not raw_fps.is_valid_int():
			return _format_error("tick_rate render_fps arg must be an integer, got: %s" % raw_fps)
		var fps: int = raw_fps.to_int()
		if fps < 1 or fps > 1000:
			return _format_error("render_fps must be 1-1000, got: %d" % fps)
		Engine.max_fps = fps
	return "Tick rate: physics=%s render_fps=%s" % [
		_format_value(str(Engine.physics_ticks_per_second)),
		_format_value(str(Engine.max_fps)),
	]

func _cmd_vsync(args: Array) -> String:
	if Engine.is_editor_hint():
		return _format_error("vsync only works in runtime")
	if args.is_empty():
		var mode: int = DisplayServer.window_get_vsync_mode()
		return "VSync: %s" % _format_value(_vsync_name(mode))
	var sub: String = str(args[0]).strip_edges().to_lower()
	var target: int
	match sub:
		"on", "enabled", "true", "1":
			target = DisplayServer.VSYNC_ENABLED
		"off", "disabled", "false", "0":
			target = DisplayServer.VSYNC_DISABLED
		"adaptive":
			target = DisplayServer.VSYNC_ADAPTIVE
		"mailbox":
			target = DisplayServer.VSYNC_MAILBOX
		_:
			return _format_error("vsync takes on|off|adaptive|mailbox, got: %s" % sub)
	DisplayServer.window_set_vsync_mode(target)
	return "VSync: %s" % _format_value(_vsync_name(target))

func _vsync_name(mode: int) -> String:
	match mode:
		DisplayServer.VSYNC_DISABLED: return "off"
		DisplayServer.VSYNC_ENABLED: return "on"
		DisplayServer.VSYNC_ADAPTIVE: return "adaptive"
		DisplayServer.VSYNC_MAILBOX: return "mailbox"
	return "mode_%d" % mode

func _cmd_audio_bus(args: Array) -> String:
	if args.is_empty():
		var lines: Array[String] = []
		lines.append(_format_header("== Audio Buses (%d) ==" % AudioServer.bus_count))
		var max_name: int = 4
		for i in AudioServer.bus_count:
			max_name = max(max_name, String(AudioServer.get_bus_name(i)).length())
		for i in AudioServer.bus_count:
			var bname: String = AudioServer.get_bus_name(i)
			var db: float = AudioServer.get_bus_volume_db(i)
			var muted: bool = AudioServer.is_bus_mute(i)
			var solo: bool = AudioServer.is_bus_solo(i)
			lines.append("  %s  [color=%s]%+6.1f dB[/color]  %s%s" % [
				bname.rpad(max_name),
				_COLOR_VALUE,
				db,
				("[color=%s]MUTE[/color] " % _COLOR_ERROR) if muted else "",
				("[color=%s]SOLO[/color]" % _COLOR_WARN) if solo else "",
			])
		return "\n".join(lines)
	var bus_name: String = str(args[0])
	var idx: int = AudioServer.get_bus_index(bus_name)
	if idx < 0:
		return _format_error("unknown audio bus: %s" % bus_name)
	if args.size() == 1:
		var db: float = AudioServer.get_bus_volume_db(idx)
		var muted: bool = AudioServer.is_bus_mute(idx)
		return "%s: %+.2f dB (%s)" % [
			_format_value(bus_name),
			db,
			"muted" if muted else "audible",
		]
	var op: String = str(args[1]).strip_edges().to_lower()
	match op:
		"mute":
			AudioServer.set_bus_mute(idx, true)
			return "%s: muted" % _format_value(bus_name)
		"unmute":
			AudioServer.set_bus_mute(idx, false)
			return "%s: unmuted" % _format_value(bus_name)
	# Otherwise treat second arg as a dB value (can be negative or float).
	if not op.is_valid_float():
		return _format_error("audio_bus second arg must be a dB number or mute/unmute, got: %s" % op)
	var db_target: float = op.to_float()
	if db_target < -80.0 or db_target > 24.0:
		return _format_error("volume must be between -80 and 24 dB, got: %.2f" % db_target)
	AudioServer.set_bus_volume_db(idx, db_target)
	return "%s: %+.2f dB" % [_format_value(bus_name), db_target]

#endregion

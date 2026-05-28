@tool
class_name DebugConsoleTweenAdvancedCommands extends RefCounted

# Extension - advanced tween commands that build on the single-property
# `tween` command from SceneCommands.gd. Auto-discovered by the loader in
# BuiltInCommands._register_t6_extensions and kept alive in the static
# _t8_extensions array, so this module survives plugin reloads and its
# tracking dictionary persists for the lifetime of the editor / game session.
#
# All tweens this module creates are recorded in _tweens, keyed by the
# resolved node path string. That lets tween_kill/pause/resume/list operate
# on real Tween instances without walking the SceneTree (Godot's Tween
# objects are not children of any node).
#
# Both contexts: the commands work in editor (no SceneTree pause-mode
# guarantees, but Tween.create_tween on the edited scene's tree still ticks)
# and at runtime.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"

var _registry: Node
var _core: Node

# Tween bookkeeping: node_path_string -> Array[Tween]. We hold strong refs
# here so tweens are not garbage collected mid-flight even if the caller
# discards the return value. Dead entries are pruned lazily on access.
var _tweens: Dictionary = {}

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("tween_chain", _cmd_tween_chain, "3-keyframe tween from->via->to: tween_chain <path>.<property> <from> <via> <to> <total_secs>", "both")
	_registry.register_command("tween_parallel", _cmd_tween_parallel, "Run tweens in parallel; specs joined by ';': tween_parallel <path>.<prop> <from> <to> <dur>; <path>.<prop> <from> <to> <dur>; ...", "both")
	_registry.register_command("tween_loop", _cmd_tween_loop, "Ping-pong a property between two values: tween_loop <path>.<property> <a> <b> <duration> [loops|inf]", "both")
	_registry.register_command("tween_kill", _cmd_tween_kill, "Kill all module-tracked tweens on a node: tween_kill <path>", "both")
	_registry.register_command("tween_pause", _cmd_tween_pause, "Pause all module-tracked tweens on a node: tween_pause <path>", "both")
	_registry.register_command("tween_resume", _cmd_tween_resume, "Resume all module-tracked tweens on a node: tween_resume <path>", "both")
	_registry.register_command("tween_list", _cmd_tween_list, "List all active module-tracked tweens: tween_list", "both")

#region Command implementations

func _cmd_tween_chain(args: Array, piped_input: String = "") -> String:
	if args.size() < 5:
		return _format_error("Usage: tween_chain <path>.<property> <from> <via> <to> <total_secs>")
	var selector := str(args[0]).strip_edges()
	var split := _split_selector(selector)
	if split.is_empty():
		return _format_error("Selector must be <path>.<property>: %s" % selector)

	var node := _resolve_node(split[0])
	if not node:
		return _format_error("Node not found: %s" % split[0])
	var property_path: String = split[1]
	var from_val: Variant = _parse_value(str(args[1]))
	var via_val: Variant = _parse_value(str(args[2]))
	var to_val: Variant = _parse_value(str(args[3]))
	var total: float = str(args[4]).to_float()
	if total <= 0.0:
		return _format_error("total_secs must be > 0")

	var tween := _make_tween(node)
	if not tween:
		return _format_error("No SceneTree available for tweening")
	var leg: float = total * 0.5
	node.set_indexed(property_path, from_val)
	tween.tween_property(node, property_path, via_val, leg)
	tween.tween_callback(Callable(self, "_chain_keyframe_marker").bind(node, property_path, via_val))
	tween.tween_property(node, property_path, to_val, leg)

	_track(node, tween)
	return _format_success("Tween chain: %s %s -> %s -> %s over %ss" % [
		_color_path("%s.%s" % [_node_path_str(node), property_path]),
		_color_number(str(from_val)),
		_color_number(str(via_val)),
		_color_number(str(to_val)),
		_color_number(str(total)),
	])

func _cmd_tween_parallel(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: tween_parallel <path>.<prop> <from> <to> <dur>; <path>.<prop> <from> <to> <dur>; ...")
	var joined := " ".join(_stringify_args(args))
	var specs: PackedStringArray = joined.split(";", false)
	if specs.size() < 1:
		return _format_error("No specs parsed; separate each tween with ';'")

	var parsed: Array = []
	for raw_spec in specs:
		var spec_str: String = str(raw_spec).strip_edges()
		if spec_str.is_empty():
			continue
		var parts: PackedStringArray = _split_whitespace(spec_str)
		if parts.size() < 4:
			return _format_error("Spec needs 4 fields '<path>.<prop> <from> <to> <dur>': %s" % spec_str)
		var sel: String = parts[0]
		var split := _split_selector(sel)
		if split.is_empty():
			return _format_error("Selector must be <path>.<property>: %s" % sel)
		var node := _resolve_node(split[0])
		if not node:
			return _format_error("Node not found: %s" % split[0])
		var dur: float = parts[3].to_float()
		if dur <= 0.0:
			return _format_error("Duration must be > 0 in spec: %s" % spec_str)
		parsed.append({
			"node": node,
			"prop": split[1],
			"from": _parse_value(parts[1]),
			"to": _parse_value(parts[2]),
			"dur": dur,
		})

	if parsed.is_empty():
		return _format_error("No usable specs found")

	var anchor: Node = parsed[0]["node"]
	var tween := _make_tween(anchor)
	if not tween:
		return _format_error("No SceneTree available for tweening")
	tween.set_parallel(true)

	var lines: Array[String] = []
	for entry in parsed:
		var n: Node = entry["node"]
		var prop: String = entry["prop"]
		n.set_indexed(prop, entry["from"])
		tween.tween_property(n, prop, entry["to"], entry["dur"])
		_track(n, tween)
		lines.append("  %s %s -> %s (%ss)" % [
			_color_path("%s.%s" % [_node_path_str(n), prop]),
			_color_number(str(entry["from"])),
			_color_number(str(entry["to"])),
			_color_number(str(entry["dur"])),
		])

	return "%s\n%s" % [_format_success("Parallel tween started (%d legs):" % parsed.size()), "\n".join(lines)]

func _cmd_tween_loop(args: Array, piped_input: String = "") -> String:
	if args.size() < 4:
		return _format_error("Usage: tween_loop <path>.<property> <a> <b> <duration> [loops|inf]")
	var selector := str(args[0]).strip_edges()
	var split := _split_selector(selector)
	if split.is_empty():
		return _format_error("Selector must be <path>.<property>: %s" % selector)

	var node := _resolve_node(split[0])
	if not node:
		return _format_error("Node not found: %s" % split[0])
	var property_path: String = split[1]
	var a_val: Variant = _parse_value(str(args[1]))
	var b_val: Variant = _parse_value(str(args[2]))
	var duration: float = str(args[3]).to_float()
	if duration <= 0.0:
		return _format_error("Duration must be > 0")

	var loops_arg: String = str(args[4]).strip_edges().to_lower() if args.size() > 4 else "inf"
	var loops: int = 0
	if loops_arg == "inf" or loops_arg == "infinite" or loops_arg == "-1":
		loops = 0
	elif loops_arg.is_valid_int():
		loops = max(0, loops_arg.to_int())
	else:
		return _format_error("loops must be a positive integer or 'inf'")

	var tween := _make_tween(node)
	if not tween:
		return _format_error("No SceneTree available for tweening")
	tween.set_loops(loops)
	node.set_indexed(property_path, a_val)
	tween.tween_property(node, property_path, b_val, duration)
	tween.tween_property(node, property_path, a_val, duration)

	_track(node, tween)
	var loops_label: String = "inf" if loops == 0 else str(loops)
	return _format_success("Tween loop: %s ping-pong %s <-> %s, %ss per leg, loops=%s" % [
		_color_path("%s.%s" % [_node_path_str(node), property_path]),
		_color_number(str(a_val)),
		_color_number(str(b_val)),
		_color_number(str(duration)),
		_color_number(loops_label),
	])

func _cmd_tween_kill(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: tween_kill <path>")
	var node_path := str(args[0]).strip_edges()
	var node := _resolve_node(node_path)
	if not node:
		return _format_error("Node not found: %s" % node_path)
	var key := _node_path_str(node)
	var killed: int = 0
	if _tweens.has(key):
		var arr: Array = _tweens[key]
		for t in arr:
			if t is Tween and t.is_valid():
				t.kill()
				killed += 1
		_tweens.erase(key)
	return _format_success("Killed %s tween(s) on %s" % [_color_number(str(killed)), _color_path(key)])

func _cmd_tween_pause(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: tween_pause <path>")
	var node_path := str(args[0]).strip_edges()
	var node := _resolve_node(node_path)
	if not node:
		return _format_error("Node not found: %s" % node_path)
	var key := _node_path_str(node)
	var paused: int = 0
	if _tweens.has(key):
		var alive: Array = []
		for t in (_tweens[key] as Array):
			if t is Tween and t.is_valid():
				t.pause()
				alive.append(t)
				paused += 1
		_tweens[key] = alive
	return _format_success("Paused %s tween(s) on %s" % [_color_number(str(paused)), _color_path(key)])

func _cmd_tween_resume(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: tween_resume <path>")
	var node_path := str(args[0]).strip_edges()
	var node := _resolve_node(node_path)
	if not node:
		return _format_error("Node not found: %s" % node_path)
	var key := _node_path_str(node)
	var resumed: int = 0
	if _tweens.has(key):
		var alive: Array = []
		for t in (_tweens[key] as Array):
			if t is Tween and t.is_valid():
				t.play()
				alive.append(t)
				resumed += 1
		_tweens[key] = alive
	return _format_success("Resumed %s tween(s) on %s" % [_color_number(str(resumed)), _color_path(key)])

func _cmd_tween_list(args: Array, piped_input: String = "") -> String:
	_prune_dead()
	if _tweens.is_empty():
		return "No active module-tracked tweens."
	var keys: Array = _tweens.keys()
	keys.sort()
	var lines: Array[String] = []
	var total: int = 0
	for k in keys:
		var arr: Array = _tweens[k]
		if arr.is_empty():
			continue
		var running: int = 0
		for t in arr:
			if t is Tween and t.is_valid() and t.is_running():
				running += 1
		total += arr.size()
		lines.append("  %s  tweens=%s (running=%s)" % [
			_color_path(str(k)),
			_color_number(str(arr.size())),
			_color_number(str(running)),
		])
	var header: String = "Tracked tweens: %s across %s node(s)" % [_color_number(str(total)), _color_number(str(lines.size()))]
	return "%s\n%s" % [header, "\n".join(lines)]

#endregion

#region Helpers

func _make_tween(node: Node) -> Tween:
	var tree: SceneTree = node.get_tree() if node.is_inside_tree() else (Engine.get_main_loop() as SceneTree)
	if not tree:
		return null
	return tree.create_tween()

func _track(node: Node, tween: Tween) -> void:
	if not tween:
		return
	var key := _node_path_str(node)
	var arr: Array = _tweens.get(key, [])
	if not arr.has(tween):
		arr.append(tween)
	_tweens[key] = arr

func _prune_dead() -> void:
	var stale_keys: Array = []
	for k in _tweens.keys():
		var alive: Array = []
		for t in (_tweens[k] as Array):
			if t is Tween and t.is_valid():
				alive.append(t)
		if alive.is_empty():
			stale_keys.append(k)
		else:
			_tweens[k] = alive
	for k in stale_keys:
		_tweens.erase(k)

func _chain_keyframe_marker(_node: Node, _prop: String, _value: Variant) -> void:
	# Hook point. Kept as a tween_callback so the chain demonstrably routes
	# through the callback path required by the spec, and so a future
	# instrumentation pass (logging, breadcrumb push, signal emit) can
	# extend the keyframe behaviour without changing the command surface.
	pass

func _node_path_str(node: Node) -> String:
	if node and node.is_inside_tree():
		return str(node.get_path())
	return node.name if node else ""

func _get_scene_root() -> Node:
	if Engine.is_editor_hint():
		return EditorInterface.get_edited_scene_root()
	var tree := Engine.get_main_loop() as SceneTree
	if not tree:
		return null
	if tree.current_scene:
		return tree.current_scene
	return tree.root

func _resolve_node(path: String) -> Node:
	var p := path.strip_edges()
	if p.is_empty():
		return null

	if Engine.is_editor_hint():
		var root := _get_scene_root()
		if not root:
			return null
		if p == "/root":
			return root
		if p.begins_with("/root/"):
			p = p.substr(6)
		elif p.begins_with("/"):
			p = p.substr(1)
		if p == root.name:
			return root
		if p.begins_with(root.name + "/"):
			p = p.substr(root.name.length() + 1)
		if p.is_empty():
			return root
		return root.get_node_or_null(p)

	var tree := Engine.get_main_loop() as SceneTree
	if not tree:
		return null
	if p.begins_with("/"):
		return tree.root.get_node_or_null(p)
	var scene: Node = tree.current_scene if tree.current_scene else tree.root
	return scene.get_node_or_null(p)

func _split_selector(selector: String) -> Array:
	var idx := selector.rfind(".")
	if idx <= 0 or idx >= selector.length() - 1:
		return []
	return [selector.substr(0, idx), selector.substr(idx + 1)]

func _stringify_args(args: Array) -> Array:
	var out: Array = []
	for a in args:
		out.append(str(a))
	return out

func _split_whitespace(s: String) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var buf: String = ""
	for i in s.length():
		var c: String = s[i]
		if c == " " or c == "\t":
			if buf.length() > 0:
				out.append(buf)
				buf = ""
		else:
			buf += c
	if buf.length() > 0:
		out.append(buf)
	return out

func _parse_value(raw: String) -> Variant:
	var s := raw.strip_edges()
	if s.is_empty():
		return ""
	if s == "null":
		return null
	if s == "true":
		return true
	if s == "false":
		return false
	if (s.begins_with("\"") and s.ends_with("\"")) or (s.begins_with("'") and s.ends_with("'")):
		return s.substr(1, s.length() - 2)
	if s.contains(","):
		var parts: PackedStringArray = s.split(",")
		var nums: Array[float] = []
		var all_num: bool = true
		for p in parts:
			var t := p.strip_edges()
			if not (t.is_valid_float() or t.is_valid_int()):
				all_num = false
				break
			nums.append(t.to_float())
		if all_num:
			match nums.size():
				2: return Vector2(nums[0], nums[1])
				3: return Vector3(nums[0], nums[1], nums[2])
				4: return Vector4(nums[0], nums[1], nums[2], nums[3])
	if s.is_valid_int():
		return s.to_int()
	if s.is_valid_float():
		return s.to_float()
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

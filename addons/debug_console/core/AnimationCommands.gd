@tool
class_name DebugConsoleAnimationCommands extends RefCounted

# Runtime AnimationPlayer / AnimationTree control commands. Shipped
# as a separate module from BuiltInCommands.gd to keep that file under
# control as the command surface grows. The orchestrator instantiates one of
# these, holds a strong reference, and calls register_commands(registry,
# core); all commands route through that strong-referenced instance so their
# Callables stay valid for the lifetime of the plugin.
#
# All commands are "both" context: AnimationPlayer and AnimationTree work the
# same way in the editor as at runtime (the editor edits the currently-open
# scene, runtime mutates the live tree) so the same path resolution and
# property access patterns apply to either side.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_DIM := "#909090"

var _registry: Node
var _core: Node

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("anim_play", _cmd_anim_play, "Play an animation: anim_play <ap_path> <anim_name> [speed] [from_pos]", "both")
	_registry.register_command("anim_stop", _cmd_anim_stop, "Stop playback on an AnimationPlayer: anim_stop <ap_path>", "both")
	_registry.register_command("anim_pause", _cmd_anim_pause, "Pause playback on an AnimationPlayer: anim_pause <ap_path>", "both")
	_registry.register_command("anim_queue", _cmd_anim_queue, "Queue an animation after the current one: anim_queue <ap_path> <anim_name>", "both")
	_registry.register_command("anim_list", _cmd_anim_list, "List animations on an AnimationPlayer with length, loop flag, and current marker: anim_list <ap_path>", "both")
	_registry.register_command("anim_seek", _cmd_anim_seek, "Seek the current animation to a time in seconds: anim_seek <ap_path> <time_secs>", "both")
	_registry.register_command("anim_speed", _cmd_anim_speed, "Get or set the AnimationPlayer speed_scale (negative reverses): anim_speed <ap_path> [speed_scale]", "both")
	_registry.register_command("anim_blend", _cmd_anim_blend, "Play A and queue B with a blend between them: anim_blend <ap_path> <anim_a> <anim_b> <blend_time>", "both")
	_registry.register_command("tree_set", _cmd_tree_set, "Set an AnimationTree parameter (state machine condition, blend amount, ...): tree_set <at_path> <param_path> <value>", "both")
	_registry.register_command("tree_get", _cmd_tree_get, "Read an AnimationTree parameter: tree_get <at_path> <param_path>", "both")
	_registry.register_command("tree_travel", _cmd_tree_travel, "Travel a state machine to a state via parameters/playback: tree_travel <at_path> <state_name>", "both")
	_registry.register_command("anim_loop", _cmd_anim_loop, "Toggle the loop flag on an Animation resource: anim_loop <ap_path> <anim_name> <on|off>", "both")

#region Command implementations

func _cmd_anim_play(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: anim_play <ap_path> <anim_name> [speed] [from_pos]")
	var ap_path := str(args[0]).strip_edges()
	var anim_name := str(args[1]).strip_edges()
	var speed: float = 1.0
	var from_pos: float = 0.0
	var has_from: bool = false
	if args.size() > 2:
		var raw_speed := str(args[2]).strip_edges()
		if not (raw_speed.is_valid_float() or raw_speed.is_valid_int()):
			return _format_error("Invalid speed: %s" % raw_speed)
		speed = raw_speed.to_float()
	if args.size() > 3:
		var raw_from := str(args[3]).strip_edges()
		if not (raw_from.is_valid_float() or raw_from.is_valid_int()):
			return _format_error("Invalid from_pos: %s" % raw_from)
		from_pos = raw_from.to_float()
		has_from = true

	var ap := _resolve_animation_player(ap_path)
	if not ap:
		return _format_error(_class_mismatch_error(ap_path, "AnimationPlayer"))
	if not ap.has_animation(anim_name):
		return _format_error("Animation not found: %s on %s" % [anim_name, ap_path])

	ap.play(anim_name, -1, speed, false)
	if has_from:
		ap.seek(from_pos, true)

	var msg: String = "Playing %s on %s @ speed %s" % [anim_name, _color_path(ap_path), _color_number(str(speed))]
	if has_from:
		msg += " from %ss" % _color_number(_format_seconds(from_pos))
	return _format_success(msg)

func _cmd_anim_stop(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: anim_stop <ap_path>")
	var ap_path := " ".join(args).strip_edges()
	var ap := _resolve_animation_player(ap_path)
	if not ap:
		return _format_error(_class_mismatch_error(ap_path, "AnimationPlayer"))
	ap.stop()
	return _format_success("Stopped %s" % _color_path(ap_path))

func _cmd_anim_pause(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: anim_pause <ap_path>")
	var ap_path := " ".join(args).strip_edges()
	var ap := _resolve_animation_player(ap_path)
	if not ap:
		return _format_error(_class_mismatch_error(ap_path, "AnimationPlayer"))
	ap.pause()
	return _format_success("Paused %s" % _color_path(ap_path))

func _cmd_anim_queue(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: anim_queue <ap_path> <anim_name>")
	var ap_path := str(args[0]).strip_edges()
	var anim_name := str(args[1]).strip_edges()
	var ap := _resolve_animation_player(ap_path)
	if not ap:
		return _format_error(_class_mismatch_error(ap_path, "AnimationPlayer"))
	if not ap.has_animation(anim_name):
		return _format_error("Animation not found: %s on %s" % [anim_name, ap_path])
	ap.queue(anim_name)
	return _format_success("Queued %s on %s" % [anim_name, _color_path(ap_path)])

func _cmd_anim_list(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: anim_list <ap_path>")
	var ap_path := " ".join(args).strip_edges()
	var ap := _resolve_animation_player(ap_path)
	if not ap:
		return _format_error(_class_mismatch_error(ap_path, "AnimationPlayer"))

	var names: PackedStringArray = ap.get_animation_list()
	var current: String = ap.current_animation
	var lines: Array[String] = []
	lines.append("%s [AnimationPlayer] %s animation(s)" % [_color_path(ap_path), _color_number(str(names.size()))])
	if names.is_empty():
		lines.append("  (no animations)")
		return "\n".join(lines)

	# Sort for deterministic output; the AnimationPlayer's own order is
	# library-insertion order which is not meaningful for the user.
	var sorted: Array = []
	for n in names:
		sorted.append(n)
	sorted.sort()

	for n in sorted:
		var marker: String = "[color=%s]>[/color] " % _COLOR_SUCCESS if n == current else "  "
		var anim: Animation = ap.get_animation(n)
		if not anim:
			lines.append("%s%s  [color=%s](missing resource)[/color]" % [marker, n, _COLOR_ERROR])
			continue
		var loop_str: String = "loop" if anim.loop_mode != Animation.LOOP_NONE else "once"
		lines.append("%s%-32s  %ss  [color=%s]%s[/color]" % [
			marker,
			n,
			_color_number(_format_seconds(anim.length)),
			_COLOR_DIM,
			loop_str,
		])
	return "\n".join(lines)

func _cmd_anim_seek(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: anim_seek <ap_path> <time_secs>")
	var ap_path := str(args[0]).strip_edges()
	var raw_time := str(args[1]).strip_edges()
	if not (raw_time.is_valid_float() or raw_time.is_valid_int()):
		return _format_error("Invalid time: %s" % raw_time)
	var ap := _resolve_animation_player(ap_path)
	if not ap:
		return _format_error(_class_mismatch_error(ap_path, "AnimationPlayer"))
	var t: float = raw_time.to_float()
	# update=true forces the tracks to apply at the seek point so the visible
	# state reflects the new position immediately, even when paused.
	ap.seek(t, true)
	return _format_success("Seeked %s to %ss" % [_color_path(ap_path), _color_number(_format_seconds(t))])

func _cmd_anim_speed(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: anim_speed <ap_path> [speed_scale]")
	var ap_path := str(args[0]).strip_edges()
	var ap := _resolve_animation_player(ap_path)
	if not ap:
		return _format_error(_class_mismatch_error(ap_path, "AnimationPlayer"))
	if args.size() < 2:
		return "%s.speed_scale = %s" % [_color_path(ap_path), _color_number(str(ap.speed_scale))]
	var raw := str(args[1]).strip_edges()
	if not (raw.is_valid_float() or raw.is_valid_int()):
		return _format_error("Invalid speed: %s" % raw)
	var speed: float = raw.to_float()
	ap.speed_scale = speed
	return _format_success("%s.speed_scale = %s" % [_color_path(ap_path), _color_number(str(speed))])

func _cmd_anim_blend(args: Array, piped_input: String = "") -> String:
	if args.size() < 4:
		return _format_error("Usage: anim_blend <ap_path> <anim_a> <anim_b> <blend_time>")
	var ap_path := str(args[0]).strip_edges()
	var anim_a := str(args[1]).strip_edges()
	var anim_b := str(args[2]).strip_edges()
	var raw_blend := str(args[3]).strip_edges()
	if not (raw_blend.is_valid_float() or raw_blend.is_valid_int()):
		return _format_error("Invalid blend_time: %s" % raw_blend)
	var blend_time: float = raw_blend.to_float()
	if blend_time < 0.0:
		return _format_error("blend_time must be >= 0")

	var ap := _resolve_animation_player(ap_path)
	if not ap:
		return _format_error(_class_mismatch_error(ap_path, "AnimationPlayer"))
	if not ap.has_animation(anim_a):
		return _format_error("Animation not found: %s on %s" % [anim_a, ap_path])
	if not ap.has_animation(anim_b):
		return _format_error("Animation not found: %s on %s" % [anim_b, ap_path])

	# play_with_blend pattern: register the A->B blend duration, start A, and
	# queue B so the transition happens automatically when A completes.
	ap.set_blend_time(anim_a, anim_b, blend_time)
	ap.play(anim_a)
	ap.queue(anim_b)
	return _format_success("Playing %s, queued %s with %ss blend on %s" % [
		anim_a,
		anim_b,
		_color_number(_format_seconds(blend_time)),
		_color_path(ap_path),
	])

func _cmd_tree_set(args: Array, piped_input: String = "") -> String:
	if args.size() < 3:
		return _format_error("Usage: tree_set <at_path> <param_path> <value>")
	var at_path := str(args[0]).strip_edges()
	var param_path := str(args[1]).strip_edges()
	# Re-join remaining args so vector literals like "1, 0, 0" survive the
	# console's whitespace split.
	var raw_parts: Array = []
	for i in range(2, args.size()):
		raw_parts.append(str(args[i]))
	var raw_value := " ".join(raw_parts).strip_edges()

	var at := _resolve_animation_tree(at_path)
	if not at:
		return _format_error(_class_mismatch_error(at_path, "AnimationTree"))

	var value: Variant = _parse_value(raw_value)
	at.set(param_path, value)
	return _format_success("%s[%s] = %s" % [_color_path(at_path), param_path, _color_number(str(value))])

func _cmd_tree_get(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: tree_get <at_path> <param_path>")
	var at_path := str(args[0]).strip_edges()
	var param_path := str(args[1]).strip_edges()
	var at := _resolve_animation_tree(at_path)
	if not at:
		return _format_error(_class_mismatch_error(at_path, "AnimationTree"))
	var value: Variant = at.get(param_path)
	var rendered: String = str(value) if value != null else "<null>"
	return "%s[%s] = %s" % [_color_path(at_path), param_path, _color_number(rendered)]

func _cmd_tree_travel(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: tree_travel <at_path> <state_name>")
	var at_path := str(args[0]).strip_edges()
	var state_name := str(args[1]).strip_edges()
	var at := _resolve_animation_tree(at_path)
	if not at:
		return _format_error(_class_mismatch_error(at_path, "AnimationTree"))
	# parameters/playback is the canonical access point for the root state
	# machine's playback handle. Nested state machines require a longer path
	# (parameters/SubSM/playback); callers pass that as part of at_path
	# inspection separately via tree_get if needed.
	var playback: AnimationNodeStateMachinePlayback = at.get("parameters/playback") as AnimationNodeStateMachinePlayback
	if not playback:
		return _format_error("No StateMachinePlayback at parameters/playback on %s" % at_path)
	playback.travel(state_name)
	return _format_success("Traveling to %s on %s" % [state_name, _color_path(at_path)])

func _cmd_anim_loop(args: Array, piped_input: String = "") -> String:
	if args.size() < 3:
		return _format_error("Usage: anim_loop <ap_path> <anim_name> <on|off>")
	var ap_path := str(args[0]).strip_edges()
	var anim_name := str(args[1]).strip_edges()
	var toggle := str(args[2]).strip_edges().to_lower()
	var should_loop: bool
	match toggle:
		"on", "true", "1", "yes":
			should_loop = true
		"off", "false", "0", "no":
			should_loop = false
		_:
			return _format_error("Toggle must be on|off (got %s)" % toggle)

	var ap := _resolve_animation_player(ap_path)
	if not ap:
		return _format_error(_class_mismatch_error(ap_path, "AnimationPlayer"))
	if not ap.has_animation(anim_name):
		return _format_error("Animation not found: %s on %s" % [anim_name, ap_path])
	var anim: Animation = ap.get_animation(anim_name)
	if not anim:
		return _format_error("Animation resource missing: %s" % anim_name)
	# LOOP_LINEAR is the most common loop mode; users wanting LOOP_PINGPONG
	# can drive it directly via tree_set or by editing the .tres resource.
	anim.loop_mode = Animation.LOOP_LINEAR if should_loop else Animation.LOOP_NONE
	return _format_success("%s.%s loop = %s" % [_color_path(ap_path), anim_name, "on" if should_loop else "off"])

#endregion

#region Helpers

func _resolve_node(path: String) -> Node:
	var p := path.strip_edges()
	if p.is_empty():
		return null

	if Engine.is_editor_hint():
		# Editor mode: all paths are relative to the edited scene root.
		# Accept "/root/..." and strip it for convenience.
		var root: Node = EditorInterface.get_edited_scene_root()
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

	# Runtime mode: absolute paths resolve via tree.root; relative paths
	# resolve under the current scene (or /root when there is none).
	var tree := Engine.get_main_loop() as SceneTree
	if not tree:
		return null
	if p.begins_with("/"):
		return tree.root.get_node_or_null(p)
	var scene: Node = tree.current_scene if tree.current_scene else tree.root
	return scene.get_node_or_null(p)

func _resolve_animation_player(path: String) -> AnimationPlayer:
	var node := _resolve_node(path)
	if node is AnimationPlayer:
		return node as AnimationPlayer
	return null

func _resolve_animation_tree(path: String) -> AnimationTree:
	var node := _resolve_node(path)
	if node is AnimationTree:
		return node as AnimationTree
	return null

func _class_mismatch_error(path: String, expected: String) -> String:
	# Called only on the error path to distinguish "node missing" from "wrong
	# class" without forcing every successful command to do a second lookup.
	var node := _resolve_node(path)
	if not node:
		return "%s not found: %s" % [expected, path]
	return "Not a %s: %s [%s]" % [expected, path, node.get_class()]

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
	# Quoted string (single or double).
	if (s.begins_with("\"") and s.ends_with("\"")) or (s.begins_with("'") and s.ends_with("'")):
		return s.substr(1, s.length() - 2)
	# Comma-separated numeric => Vector2/3/4 for convenience (blend positions
	# on AnimationTree blend spaces are Vector2, for example).
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

func _format_seconds(t: float) -> String:
	# Compact display: trim trailing zeros so "1.500" prints as "1.5" and
	# "2.000" prints as "2". Three-decimal precision is enough for any
	# animation we are likely to see in the wild.
	var s := "%.3f" % t
	while s.ends_with("0"):
		s = s.substr(0, s.length() - 1)
	if s.ends_with("."):
		s = s.substr(0, s.length() - 1)
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

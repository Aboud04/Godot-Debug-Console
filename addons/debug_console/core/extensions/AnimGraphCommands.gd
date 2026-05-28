@tool
class_name DebugConsoleAnimGraphCommands extends RefCounted

# AnimationTree introspection commands. Ships separately from
# BuiltInCommands.gd to keep that file manageable as the command surface
# grows. The orchestrator instantiates one of these, holds a strong
# reference, and calls register_commands(registry, core). All commands
# route through the strong-referenced instance so their Callables stay
# valid for the lifetime of the plugin.
#
# Commands here intentionally avoid touching the file-based test runner,
# the editor-dock plugin glue, or BuiltInCommands.gd; everything they need
# (registry + core) is passed in. Recording state lives on the instance
# and is keyed by the AnimationTree's node path so concurrent recordings
# on different trees coexist cleanly.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_MUTED := "#888888"

const _PARAM_PREFIX := "parameters/"
const _DEFAULT_RECORD_SECS := 2.0
const _MAX_BLEND_TREE_DEPTH := 6

var _registry: Node
var _core: Node

# at_path -> { tree: WeakRef, params: PackedStringArray,
#              frames: Array[Dictionary], times: Array[float],
#              duration: float, start_msec: int, callable: Callable }
var _recordings: Dictionary = {}
# at_path -> { tree: WeakRef, params: PackedStringArray,
#              frames: Array[Dictionary], times: Array[float],
#              index: int, start_msec: int, callable: Callable }
var _playbacks: Dictionary = {}

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("ag_dump", _cmd_ag_dump, "Print all AnimationTree parameter paths and values: ag_dump <at_path>", "both")
	_registry.register_command("ag_states", _cmd_ag_states, "List StateMachinePlayback states and current: ag_states <at_path> [playback_param]", "both")
	_registry.register_command("ag_travel", _cmd_ag_travel, "Travel a StateMachinePlayback to a target state: ag_travel <at_path> <state> [playback_param]", "both")
	_registry.register_command("ag_set", _cmd_ag_set, "Set an AnimationTree parameter (auto-parses value): ag_set <at_path> <param_path> <value>", "both")
	_registry.register_command("ag_blend_tree", _cmd_ag_blend_tree, "List BlendTree child node names and types: ag_blend_tree <at_path>", "both")
	_registry.register_command("ag_record", _cmd_ag_record, "Record AnimationTree parameter values for N seconds: ag_record <at_path> [seconds]", "both")
	_registry.register_command("ag_replay", _cmd_ag_replay, "Replay a previously recorded session: ag_replay <at_path>", "both")

#region Command implementations

func _cmd_ag_dump(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: ag_dump <at_path>")
	var at_path := str(args[0]).strip_edges()
	var tree := _get_animation_tree(at_path)
	if not tree:
		return _format_error("AnimationTree not found: %s" % at_path)

	var params := _list_param_paths(tree)
	if params.is_empty():
		return "%s [%s] - no parameters (tree_root may be empty)" % [_color_path(at_path), tree.get_class()]

	var lines: Array[String] = []
	lines.append("%s [%s] - %s parameter(s)" % [_color_path(at_path), tree.get_class(), _color_number(str(params.size()))])
	params.sort()
	for p in params:
		var val: Variant = tree.get(p)
		lines.append("  %s = %s" % [p, _format_value(val)])
	return "\n".join(lines)

func _cmd_ag_states(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: ag_states <at_path> [playback_param]")
	var at_path := str(args[0]).strip_edges()
	var playback_param := str(args[1]).strip_edges() if args.size() > 1 else ""
	var tree := _get_animation_tree(at_path)
	if not tree:
		return _format_error("AnimationTree not found: %s" % at_path)

	var resolved: Dictionary = _resolve_playback(tree, playback_param)
	if not bool(resolved.get("ok", false)):
		return _format_error(str(resolved.get("error", "playback not found")))
	var playback: AnimationNodeStateMachinePlayback = resolved["playback"]
	var state_machine: AnimationNodeStateMachine = resolved["state_machine"]
	var used_param: String = resolved["param"]

	var state_list: PackedStringArray = state_machine.get_node_list() if state_machine else PackedStringArray()
	var current: StringName = playback.get_current_node() if playback.is_playing() else StringName("")
	var travel_path: PackedStringArray = playback.get_travel_path()

	var lines: Array[String] = []
	lines.append("%s [StateMachine via %s] - %s state(s)" % [_color_path(at_path), used_param, _color_number(str(state_list.size()))])
	lines.append("  current: %s" % (_color_success(String(current)) if String(current) != "" else "[color=%s]<not playing>[/color]" % _COLOR_MUTED))
	if travel_path.size() > 0:
		lines.append("  travel:  %s" % " -> ".join(travel_path))
	lines.append("  playing: %s  pos: %s" % [str(playback.is_playing()), _color_number(str(playback.get_current_play_position()).pad_decimals(3))])
	if state_list.size() == 0:
		lines.append("  [color=%s](no states)[/color]" % _COLOR_MUTED)
	else:
		for s in state_list:
			var marker: String = " *" if String(s) == String(current) else ""
			lines.append("  - %s%s" % [String(s), marker])
	return "\n".join(lines)

func _cmd_ag_travel(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: ag_travel <at_path> <state> [playback_param]")
	var at_path := str(args[0]).strip_edges()
	var target_state := str(args[1]).strip_edges()
	var playback_param := str(args[2]).strip_edges() if args.size() > 2 else ""
	var tree := _get_animation_tree(at_path)
	if not tree:
		return _format_error("AnimationTree not found: %s" % at_path)

	var resolved: Dictionary = _resolve_playback(tree, playback_param)
	if not bool(resolved.get("ok", false)):
		return _format_error(str(resolved.get("error", "playback not found")))
	var playback: AnimationNodeStateMachinePlayback = resolved["playback"]
	var state_machine: AnimationNodeStateMachine = resolved["state_machine"]

	if state_machine and not state_machine.get_node_list().has(target_state):
		return _format_error("State not found in StateMachine: %s" % target_state)

	playback.travel(target_state)
	return _format_success("Travel queued: %s -> %s" % [_color_path(at_path), target_state])

func _cmd_ag_set(args: Array, piped_input: String = "") -> String:
	if args.size() < 3:
		return _format_error("Usage: ag_set <at_path> <param_path> <value>")
	var at_path := str(args[0]).strip_edges()
	var raw_param := str(args[1]).strip_edges()
	var raw_value := str(args[2]).strip_edges()
	var tree := _get_animation_tree(at_path)
	if not tree:
		return _format_error("AnimationTree not found: %s" % at_path)

	var param_path := raw_param if raw_param.begins_with(_PARAM_PREFIX) else _PARAM_PREFIX + raw_param
	var existing_params := _list_param_paths(tree)
	if not existing_params.has(param_path):
		return _format_error("Unknown parameter: %s (use ag_dump to list)" % param_path)

	var old_value: Variant = tree.get(param_path)
	var new_value: Variant = _parse_value(raw_value)
	tree.set(param_path, new_value)
	var applied: Variant = tree.get(param_path)
	return _format_success("Set %s : %s -> %s" % [
		_color_path("%s.%s" % [at_path, param_path]),
		_format_value(old_value),
		_format_value(applied),
	])

func _cmd_ag_blend_tree(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: ag_blend_tree <at_path>")
	var at_path := str(args[0]).strip_edges()
	var tree := _get_animation_tree(at_path)
	if not tree:
		return _format_error("AnimationTree not found: %s" % at_path)
	var root: AnimationNode = tree.tree_root
	if not root:
		return _format_error("AnimationTree has no tree_root assigned")

	var lines: Array[String] = []
	lines.append("%s - blend tree introspection" % _color_path(at_path))
	_walk_blend_tree(root, "<root>", lines, 0)
	if lines.size() == 1:
		lines.append("  [color=%s](no inspectable children)[/color]" % _COLOR_MUTED)
	return "\n".join(lines)

func _cmd_ag_record(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: ag_record <at_path> [seconds]")
	var at_path := str(args[0]).strip_edges()
	var duration: float = _DEFAULT_RECORD_SECS
	if args.size() > 1:
		var raw_dur := str(args[1]).strip_edges()
		if raw_dur.is_valid_float() or raw_dur.is_valid_int():
			duration = raw_dur.to_float()
	if duration <= 0.0:
		return _format_error("Duration must be > 0")
	var tree := _get_animation_tree(at_path)
	if not tree:
		return _format_error("AnimationTree not found: %s" % at_path)
	var scene_tree: SceneTree = tree.get_tree() if tree.is_inside_tree() else (Engine.get_main_loop() as SceneTree)
	if not scene_tree:
		return _format_error("No SceneTree available for recording")

	var key := _record_key(tree, at_path)
	_stop_recording(key)
	_stop_playback(key)

	var params: PackedStringArray = _list_param_paths(tree)
	if params.is_empty():
		return _format_error("AnimationTree has no parameters to record")

	var cb := Callable(self, "_on_record_frame").bind(key)
	scene_tree.process_frame.connect(cb)

	_recordings[key] = {
		"tree": weakref(tree),
		"params": params,
		"frames": [],
		"times": [],
		"duration": duration,
		"start_msec": Time.get_ticks_msec(),
		"callable": cb,
		"at_path": at_path,
		"recording": true,
	}
	return _format_success("Recording %s for %s seconds (%s params)" % [
		_color_path(at_path),
		_color_number(str(duration)),
		_color_number(str(params.size())),
	])

func _cmd_ag_replay(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: ag_replay <at_path>")
	var at_path := str(args[0]).strip_edges()
	var tree := _get_animation_tree(at_path)
	if not tree:
		return _format_error("AnimationTree not found: %s" % at_path)
	var key := _record_key(tree, at_path)
	if not _recordings.has(key):
		return _format_error("No recording for %s (run ag_record first)" % at_path)
	var rec: Dictionary = _recordings[key]
	if rec.get("recording", false):
		return _format_error("Recording still in progress for %s" % at_path)
	var frames: Array = rec.get("frames", [])
	if frames.is_empty():
		return _format_error("Recording for %s has no captured frames" % at_path)

	var scene_tree: SceneTree = tree.get_tree() if tree.is_inside_tree() else (Engine.get_main_loop() as SceneTree)
	if not scene_tree:
		return _format_error("No SceneTree available for replay")

	_stop_playback(key)
	var cb := Callable(self, "_on_replay_frame").bind(key)
	scene_tree.process_frame.connect(cb)
	_playbacks[key] = {
		"tree": weakref(tree),
		"params": rec.get("params", PackedStringArray()),
		"frames": frames.duplicate(),
		"times": Array(rec.get("times", [])).duplicate(),
		"index": 0,
		"start_msec": Time.get_ticks_msec(),
		"callable": cb,
		"at_path": at_path,
	}
	return _format_success("Replaying %s (%s frames, ~%ss)" % [
		_color_path(at_path),
		_color_number(str(frames.size())),
		_color_number(str(rec.get("duration", 0.0))),
	])

#endregion

#region Recording / replay callbacks

func _on_record_frame(key: String) -> void:
	if not _recordings.has(key):
		return
	var rec: Dictionary = _recordings[key]
	var weak: WeakRef = rec.get("tree")
	var tree: AnimationTree = weak.get_ref() if weak else null
	if not tree:
		_stop_recording(key)
		return
	var elapsed_ms: int = Time.get_ticks_msec() - int(rec["start_msec"])
	var elapsed_s: float = float(elapsed_ms) / 1000.0
	var params: PackedStringArray = rec["params"]
	var snap: Dictionary = {}
	for p in params:
		snap[p] = tree.get(p)
	(rec["frames"] as Array).append(snap)
	(rec["times"] as Array).append(elapsed_s)
	if elapsed_s >= float(rec["duration"]):
		_stop_recording(key)

func _on_replay_frame(key: String) -> void:
	if not _playbacks.has(key):
		return
	var pb: Dictionary = _playbacks[key]
	var weak: WeakRef = pb.get("tree")
	var tree: AnimationTree = weak.get_ref() if weak else null
	if not tree:
		_stop_playback(key)
		return
	var frames: Array = pb["frames"]
	var idx: int = int(pb["index"])
	if idx >= frames.size():
		_stop_playback(key)
		return
	var snap: Dictionary = frames[idx]
	for k in snap.keys():
		tree.set(str(k), snap[k])
	pb["index"] = idx + 1

func _stop_recording(key: String) -> void:
	if not _recordings.has(key):
		return
	var rec: Dictionary = _recordings[key]
	var cb: Variant = rec.get("callable")
	if cb is Callable:
		var weak: WeakRef = rec.get("tree")
		var tree: AnimationTree = weak.get_ref() if weak else null
		var scene_tree: SceneTree = null
		if tree and tree.is_inside_tree():
			scene_tree = tree.get_tree()
		if not scene_tree:
			scene_tree = Engine.get_main_loop() as SceneTree
		if scene_tree and scene_tree.process_frame.is_connected(cb):
			scene_tree.process_frame.disconnect(cb)
	rec["recording"] = false
	rec["callable"] = null

func _stop_playback(key: String) -> void:
	if not _playbacks.has(key):
		return
	var pb: Dictionary = _playbacks[key]
	var cb: Variant = pb.get("callable")
	if cb is Callable:
		var weak: WeakRef = pb.get("tree")
		var tree: AnimationTree = weak.get_ref() if weak else null
		var scene_tree: SceneTree = null
		if tree and tree.is_inside_tree():
			scene_tree = tree.get_tree()
		if not scene_tree:
			scene_tree = Engine.get_main_loop() as SceneTree
		if scene_tree and scene_tree.process_frame.is_connected(cb):
			scene_tree.process_frame.disconnect(cb)
	_playbacks.erase(key)

#endregion

#region Helpers

func _get_animation_tree(path: String) -> AnimationTree:
	var node := _resolve_node(path)
	if not node:
		return null
	if node is AnimationTree:
		return node
	return null

func _list_param_paths(tree: AnimationTree) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for prop in tree.get_property_list():
		var pname: String = str(prop.get("name", ""))
		if pname.begins_with(_PARAM_PREFIX):
			out.append(pname)
	return out

func _resolve_playback(tree: AnimationTree, explicit_param: String) -> Dictionary:
	var candidates: PackedStringArray = PackedStringArray()
	if not explicit_param.is_empty():
		candidates.append(explicit_param if explicit_param.begins_with(_PARAM_PREFIX) else _PARAM_PREFIX + explicit_param)
	else:
		candidates.append("parameters/playback")
		for p in _list_param_paths(tree):
			if p.ends_with("/playback") and not candidates.has(p):
				candidates.append(p)

	for cand in candidates:
		var pb_val: Variant = tree.get(cand)
		if pb_val is AnimationNodeStateMachinePlayback:
			var sm := _find_state_machine_for(tree, cand)
			return {
				"ok": true,
				"playback": pb_val,
				"state_machine": sm,
				"param": cand,
			}
	return {"ok": false, "error": "No AnimationNodeStateMachinePlayback found (tried %s)" % ", ".join(candidates)}

func _find_state_machine_for(tree: AnimationTree, playback_param: String) -> AnimationNodeStateMachine:
	# parameters/foo/bar/playback -> walk tree_root by 'foo','bar'
	var stripped := playback_param.trim_prefix(_PARAM_PREFIX).trim_suffix("/playback").trim_suffix("playback")
	stripped = stripped.trim_suffix("/")
	var node: AnimationNode = tree.tree_root
	if not node:
		return null
	if stripped.is_empty():
		return node as AnimationNodeStateMachine
	for seg in stripped.split("/"):
		if node is AnimationNodeBlendTree:
			node = (node as AnimationNodeBlendTree).get_node(seg)
		elif node is AnimationNodeStateMachine:
			node = (node as AnimationNodeStateMachine).get_node(seg)
		else:
			return null
		if not node:
			return null
	return node as AnimationNodeStateMachine

func _walk_blend_tree(node: AnimationNode, label: String, out: Array[String], depth: int) -> void:
	if depth > _MAX_BLEND_TREE_DEPTH:
		out.append("%s%s ... (max depth)" % ["  ".repeat(depth), label])
		return
	var indent := "  ".repeat(depth + 1)
	if node is AnimationNodeBlendTree:
		var bt: AnimationNodeBlendTree = node
		var names: PackedStringArray = bt.get_node_list()
		out.append("%s%s [BlendTree] (%s nodes)" % [indent, _color_path(label), _color_number(str(names.size()))])
		for n in names:
			var child: AnimationNode = bt.get_node(n)
			if not child:
				out.append("%s  - %s [color=%s]<missing>[/color]" % [indent, n, _COLOR_MUTED])
				continue
			out.append("%s  - %s [color=%s][%s][/color]" % [indent, n, _COLOR_MUTED, child.get_class()])
			if child is AnimationNodeBlendTree or child is AnimationNodeStateMachine:
				_walk_blend_tree(child, n, out, depth + 1)
	elif node is AnimationNodeStateMachine:
		var sm: AnimationNodeStateMachine = node
		var names: PackedStringArray = sm.get_node_list()
		out.append("%s%s [StateMachine] (%s states)" % [indent, _color_path(label), _color_number(str(names.size()))])
		for n in names:
			var child: AnimationNode = sm.get_node(n)
			if not child:
				out.append("%s  - %s [color=%s]<missing>[/color]" % [indent, n, _COLOR_MUTED])
				continue
			out.append("%s  - %s [color=%s][%s][/color]" % [indent, n, _COLOR_MUTED, child.get_class()])
			if child is AnimationNodeBlendTree or child is AnimationNodeStateMachine:
				_walk_blend_tree(child, n, out, depth + 1)
	else:
		out.append("%s%s [color=%s][%s][/color]" % [indent, _color_path(label), _COLOR_MUTED, node.get_class()])

func _record_key(tree: AnimationTree, fallback: String) -> String:
	if tree.is_inside_tree():
		return str(tree.get_path())
	return fallback

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

func _format_value(value: Variant) -> String:
	if value == null:
		return "[color=%s]<null>[/color]" % _COLOR_MUTED
	if value is float:
		return _color_number(str(value).pad_decimals(3))
	if value is int or value is bool:
		return _color_number(str(value))
	if value is StringName:
		return "&\"%s\"" % String(value)
	if value is Object:
		return "[color=%s]%s[/color]" % [_COLOR_MUTED, (value as Object).get_class()]
	return str(value)

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

func _color_success(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, s]

#endregion

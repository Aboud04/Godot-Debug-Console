@tool
class_name DebugConsoleSceneCommands extends RefCounted

# Live scene/node manipulation commands. This module ships separately
# from BuiltInCommands.gd to keep that file under control as the command
# surface grows. The orchestrator (BuiltInCommands.register_universal_commands)
# instantiates one of these, holds a strong reference to it, and calls
# register_commands(registry, core). All commands route through that
# strong-referenced instance so their Callables stay valid for the lifetime
# of the plugin.
#
# The commands here intentionally avoid touching the file-based test runner,
# the editor-dock plugin glue, or BuiltInCommands.gd; everything they need
# (registry + core) is passed in.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"

var _registry: Node
var _core: Node

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("spawn", _cmd_spawn, "Instance a scene at runtime: spawn <res://scene.tscn> [parent_path] [x,y,z]", "both")
	_registry.register_command("instance_scene", _cmd_instance_scene, "Instance a scene without setting a position: instance_scene <res://scene.tscn> [parent_path]", "both")
	_registry.register_command("create_node", _cmd_create_node, "Create a node by class name: create_node <type> [parent_path] [name]", "both")
	_registry.register_command("delete_node", _cmd_delete_node, "Queue-free a node by path: delete_node <path>", "both")
	_registry.register_command("reparent", _cmd_reparent, "Move a node under a new parent: reparent <from_path> <to_parent_path>", "both")
	_registry.register_command("duplicate_node", _cmd_duplicate_node, "Duplicate a node as a sibling: duplicate_node <path> [new_name]", "both")
	_registry.register_command("call", _cmd_call, "Invoke a method on a node: call <path>.<method> [args...]", "both")
	_registry.register_command("methods", _cmd_methods, "List methods on a node: methods <path> [-a]", "both")
	_registry.register_command("class_db", _cmd_class_db, "Dump ClassDB info: class_db <class_name>", "both")
	_registry.register_command("signal_emit", _cmd_signal_emit, "Emit a signal: signal_emit <path>.<signal_name> [args...]", "both")
	_registry.register_command("signal_connect", _cmd_signal_connect, "Connect a signal: signal_connect <src_path>.<signal> <dst_path>.<method>", "both")
	_registry.register_command("signal_disconnect", _cmd_signal_disconnect, "Disconnect a signal: signal_disconnect <src_path>.<signal> <dst_path>.<method>", "both")
	_registry.register_command("tween", _cmd_tween, "Tween a property: tween <path>.<property> <from> <to> <duration_secs> [trans] [ease]", "both")
	_registry.register_command("find_node", _cmd_find_node, "Glob-search nodes by name: find_node <pattern> [root_path]", "both")
	_registry.register_command("count_nodes", _cmd_count_nodes, "Count nodes under root, grouped by class: count_nodes [root_path]", "both")

#region Command implementations

func _cmd_spawn(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: spawn <res://scene.tscn> [parent_path] [x,y,z]")
	var scene_path := str(args[0]).strip_edges()
	var parent_path := str(args[1]).strip_edges() if args.size() > 1 else ""
	var pos_str := str(args[2]).strip_edges() if args.size() > 2 else ""

	if not ResourceLoader.exists(scene_path):
		return _format_error("Scene not found: %s" % scene_path)
	var packed := load(scene_path) as PackedScene
	if not packed:
		return _format_error("Not a PackedScene: %s" % scene_path)

	var instance := packed.instantiate()
	if not instance:
		return _format_error("Failed to instantiate: %s" % scene_path)

	var parent: Node = null
	if parent_path.is_empty():
		parent = _get_default_parent()
	else:
		parent = _resolve_node(parent_path)
	if not parent:
		instance.free()
		return _format_error("Parent not found: %s" % (parent_path if not parent_path.is_empty() else "<default>"))

	parent.add_child(instance)
	if Engine.is_editor_hint():
		var root := _get_scene_root()
		if root:
			instance.owner = root

	if not pos_str.is_empty():
		var pos_value: Variant = _parse_value(pos_str)
		if instance is Node3D and pos_value is Vector3:
			(instance as Node3D).position = pos_value
		elif instance is Node2D and pos_value is Vector2:
			(instance as Node2D).position = pos_value
		elif instance is Control and pos_value is Vector2:
			(instance as Control).position = pos_value

	var spawned_path: String = str(instance.get_path()) if instance.is_inside_tree() else instance.name
	return _format_success("Spawned %s" % _color_path(spawned_path))

func _cmd_instance_scene(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: instance_scene <res://scene.tscn> [parent_path]")
	var forwarded: Array = [args[0]]
	if args.size() > 1:
		forwarded.append(args[1])
	return _cmd_spawn(forwarded)

func _cmd_create_node(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: create_node <type> [parent_path] [name]")
	var type_name := str(args[0]).strip_edges()
	var parent_path := str(args[1]).strip_edges() if args.size() > 1 else ""
	var desired_name := str(args[2]).strip_edges() if args.size() > 2 else ""

	if not ClassDB.class_exists(type_name):
		return _format_error("Unknown class: %s" % type_name)
	if not ClassDB.can_instantiate(type_name):
		return _format_error("Class is not instantiable: %s" % type_name)

	var created: Object = ClassDB.instantiate(type_name)
	if not (created is Node):
		return _format_error("Class is not a Node: %s" % type_name)

	var node: Node = created
	if not desired_name.is_empty():
		node.name = desired_name

	var parent: Node = null
	if parent_path.is_empty():
		parent = _get_default_parent()
	else:
		parent = _resolve_node(parent_path)
	if not parent:
		node.free()
		return _format_error("Parent not found: %s" % (parent_path if not parent_path.is_empty() else "<default>"))

	parent.add_child(node)
	if Engine.is_editor_hint():
		var root := _get_scene_root()
		if root:
			node.owner = root

	var created_path: String = str(node.get_path()) if node.is_inside_tree() else node.name
	return _format_success("Created %s [%s]" % [_color_path(created_path), node.get_class()])

func _cmd_delete_node(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: delete_node <path>")
	var path := " ".join(args).strip_edges()
	var node := _resolve_node(path)
	if not node:
		return _format_error("Node not found: %s" % path)

	# Refuse deleting tree.root or autoload nodes. Autoloads are children of
	# tree.root that are NOT the current scene; deleting them would crash any
	# code that holds a reference to the singleton.
	if not Engine.is_editor_hint():
		var tree := Engine.get_main_loop() as SceneTree
		if tree:
			if node == tree.root:
				return _format_error("Refusing to delete /root")
			if node.get_parent() == tree.root and node != tree.current_scene:
				return _format_error("Refusing to delete autoload: %s" % node.name)

	var node_name := node.name
	var node_class := node.get_class()
	node.queue_free()
	return _format_success("Deleted %s [%s]" % [node_name, node_class])

func _cmd_reparent(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: reparent <from_path> <to_parent_path>")
	var from_path := str(args[0]).strip_edges()
	var to_path := str(args[1]).strip_edges()

	var node := _resolve_node(from_path)
	if not node:
		return _format_error("Node not found: %s" % from_path)
	var new_parent := _resolve_node(to_path)
	if not new_parent:
		return _format_error("Parent not found: %s" % to_path)
	if node == new_parent:
		return _format_error("Cannot reparent a node onto itself")
	if node.is_ancestor_of(new_parent):
		return _format_error("Cannot reparent into a descendant")

	var old_parent := node.get_parent()
	if old_parent:
		old_parent.remove_child(node)
	new_parent.add_child(node)
	if Engine.is_editor_hint():
		var root := _get_scene_root()
		if root:
			node.owner = root

	var new_path: String = str(node.get_path()) if node.is_inside_tree() else node.name
	return _format_success("Reparented to %s" % _color_path(new_path))

func _cmd_duplicate_node(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: duplicate_node <path> [new_name]")
	var path := str(args[0]).strip_edges()
	var new_name := str(args[1]).strip_edges() if args.size() > 1 else ""

	var node := _resolve_node(path)
	if not node:
		return _format_error("Node not found: %s" % path)
	var parent := node.get_parent()
	if not parent:
		return _format_error("Cannot duplicate a node with no parent: %s" % path)

	var copy: Node = node.duplicate(Node.DUPLICATE_USE_INSTANTIATION)
	if not copy:
		return _format_error("Duplicate failed: %s" % path)
	if not new_name.is_empty():
		copy.name = new_name

	parent.add_child(copy)
	if Engine.is_editor_hint():
		var root := _get_scene_root()
		if root:
			copy.owner = root

	var copy_path: String = str(copy.get_path()) if copy.is_inside_tree() else copy.name
	return _format_success("Duplicated to %s" % _color_path(copy_path))

func _cmd_call(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: call <path>.<method> [args...]")
	var selector := str(args[0]).strip_edges()
	var split := _split_selector(selector)
	if split.is_empty():
		return _format_error("Selector must be <path>.<method>: %s" % selector)

	var node := _resolve_node(split[0])
	if not node:
		return _format_error("Node not found: %s" % split[0])
	var method: String = split[1]
	if not node.has_method(method):
		return _format_error("Method not found: %s on %s" % [method, node.get_class()])

	var call_args: Array = []
	for i in range(1, args.size()):
		call_args.append(_parse_value(str(args[i])))
	var result: Variant = node.callv(method, call_args)
	return "%s = %s" % [_color_path("%s.%s" % [split[0], method]), str(result) if result != null else "<null>"]

func _cmd_methods(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: methods <path> [-a]")
	var include_private := false
	var path_parts: Array[String] = []
	for a in args:
		var t := str(a).strip_edges()
		if t == "-a":
			include_private = true
		else:
			path_parts.append(t)
	var path := " ".join(path_parts).strip_edges()
	if path.is_empty():
		return _format_error("Usage: methods <path> [-a]")

	var node := _resolve_node(path)
	if not node:
		return _format_error("Node not found: %s" % path)

	var method_list: Array = node.get_method_list()
	var lines: Array[String] = []
	lines.append("%s [%s] - methods" % [_color_path(path), node.get_class()])
	method_list.sort_custom(func(a, b): return str(a.get("name", "")) < str(b.get("name", "")))
	var shown: int = 0
	for m in method_list:
		var mname: String = str(m.get("name", ""))
		if mname.is_empty():
			continue
		if not include_private and mname.begins_with("_"):
			continue
		var ret: int = int(m.get("return", {}).get("type", TYPE_NIL))
		var ret_name: String = _type_name(ret)
		var arg_strs: Array[String] = []
		for a in m.get("args", []):
			arg_strs.append(_type_name(int(a.get("type", TYPE_NIL))))
		lines.append("  %s %s(%s)" % [ret_name, mname, ", ".join(arg_strs)])
		shown += 1
	if shown == 0:
		lines.append("  (no methods; pass -a to include underscore-prefixed)")
	return "\n".join(lines)

func _cmd_class_db(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: class_db <class_name>")
	var cls := str(args[0]).strip_edges()
	if not ClassDB.class_exists(cls):
		return _format_error("Unknown class: %s" % cls)

	var inheriters: PackedStringArray = ClassDB.get_inheriters_from_class(cls)
	var methods: Array = ClassDB.class_get_method_list(cls, true)
	var properties: Array = ClassDB.class_get_property_list(cls, true)
	var signals: Array = ClassDB.class_get_signal_list(cls, true)

	var lines: Array[String] = []
	lines.append("[color=%s]=== %s ===[/color]" % [_COLOR_PATH, cls])
	lines.append("Instantiable: %s  |  Inheriters: %d" % [str(ClassDB.can_instantiate(cls)), inheriters.size()])
	lines.append("Methods: %d  |  Properties: %d  |  Signals: %d" % [methods.size(), properties.size(), signals.size()])
	if inheriters.size() > 0:
		var preview: Array[String] = []
		var limit: int = mini(inheriters.size(), 8)
		for i in range(limit):
			preview.append(inheriters[i])
		var suffix: String = "" if inheriters.size() <= 8 else " ... (+%d more)" % (inheriters.size() - 8)
		lines.append("  Inheriters: %s%s" % [", ".join(preview), suffix])
	if signals.size() > 0:
		lines.append("[color=%s]Signals:[/color]" % _COLOR_PATH)
		for s in signals:
			lines.append("  %s" % str(s.get("name", "")))
	return "\n".join(lines)

func _cmd_signal_emit(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: signal_emit <path>.<signal_name> [args...]")
	var selector := str(args[0]).strip_edges()
	var split := _split_selector(selector)
	if split.is_empty():
		return _format_error("Selector must be <path>.<signal_name>: %s" % selector)

	var node := _resolve_node(split[0])
	if not node:
		return _format_error("Node not found: %s" % split[0])
	var sig: String = split[1]
	if not node.has_signal(sig):
		return _format_error("Signal not found: %s on %s" % [sig, node.get_class()])

	var emit_args: Array = [sig]
	for i in range(1, args.size()):
		emit_args.append(_parse_value(str(args[i])))
	node.callv("emit_signal", emit_args)
	return _format_success("Emitted %s.%s" % [_color_path(split[0]), sig])

func _cmd_signal_connect(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: signal_connect <src_path>.<signal> <dst_path>.<method>")
	var src_split := _split_selector(str(args[0]).strip_edges())
	var dst_split := _split_selector(str(args[1]).strip_edges())
	if src_split.is_empty() or dst_split.is_empty():
		return _format_error("Both arguments must be <path>.<name>")

	var source := _resolve_node(src_split[0])
	if not source:
		return _format_error("Source not found: %s" % src_split[0])
	var target := _resolve_node(dst_split[0])
	if not target:
		return _format_error("Target not found: %s" % dst_split[0])
	var sig: String = src_split[1]
	var method: String = dst_split[1]
	if not source.has_signal(sig):
		return _format_error("Signal not found: %s on %s" % [sig, source.get_class()])
	if not target.has_method(method):
		return _format_error("Method not found: %s on %s" % [method, target.get_class()])

	var callable := Callable(target, method)
	if source.is_connected(sig, callable):
		return _format_error("Already connected: %s.%s -> %s.%s" % [src_split[0], sig, dst_split[0], method])
	var err: int = source.connect(sig, callable)
	if err != OK:
		return _format_error("connect() returned error %d" % err)
	return _format_success("Connected %s.%s -> %s.%s" % [_color_path(src_split[0]), sig, _color_path(dst_split[0]), method])

func _cmd_signal_disconnect(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: signal_disconnect <src_path>.<signal> <dst_path>.<method>")
	var src_split := _split_selector(str(args[0]).strip_edges())
	var dst_split := _split_selector(str(args[1]).strip_edges())
	if src_split.is_empty() or dst_split.is_empty():
		return _format_error("Both arguments must be <path>.<name>")

	var source := _resolve_node(src_split[0])
	if not source:
		return _format_error("Source not found: %s" % src_split[0])
	var target := _resolve_node(dst_split[0])
	if not target:
		return _format_error("Target not found: %s" % dst_split[0])
	var sig: String = src_split[1]
	var method: String = dst_split[1]

	var callable := Callable(target, method)
	if not source.is_connected(sig, callable):
		return _format_error("Not connected: %s.%s -> %s.%s" % [src_split[0], sig, dst_split[0], method])
	source.disconnect(sig, callable)
	return _format_success("Disconnected %s.%s -> %s.%s" % [_color_path(src_split[0]), sig, _color_path(dst_split[0]), method])

func _cmd_tween(args: Array, piped_input: String = "") -> String:
	if args.size() < 4:
		return _format_error("Usage: tween <path>.<property> <from> <to> <duration_secs> [trans] [ease]")
	var selector := str(args[0]).strip_edges()
	var split := _split_selector(selector)
	if split.is_empty():
		return _format_error("Selector must be <path>.<property>: %s" % selector)

	var node := _resolve_node(split[0])
	if not node:
		return _format_error("Node not found: %s" % split[0])
	var property_path: String = split[1]
	var from_val: Variant = _parse_value(str(args[1]))
	var to_val: Variant = _parse_value(str(args[2]))
	var duration: float = str(args[3]).to_float()
	if duration <= 0.0:
		return _format_error("Duration must be > 0")

	var trans_arg: String = str(args[4]).strip_edges().to_lower() if args.size() > 4 else ""
	var ease_arg: String = str(args[5]).strip_edges().to_lower() if args.size() > 5 else ""

	var tree: SceneTree = node.get_tree() if node.is_inside_tree() else (Engine.get_main_loop() as SceneTree)
	if not tree:
		return _format_error("No SceneTree available for tweening")
	var tween: Tween = tree.create_tween()
	if not tween:
		return _format_error("Failed to create Tween")

	node.set_indexed(property_path, from_val)
	var tweener: PropertyTweener = tween.tween_property(node, property_path, to_val, duration)
	var trans_type: int = _parse_trans(trans_arg)
	if trans_type >= 0:
		tweener.set_trans(trans_type)
	var ease_type: int = _parse_ease(ease_arg)
	if ease_type >= 0:
		tweener.set_ease(ease_type)

	return _format_success("Tween started: %s %s -> %s over %ss" % [
		_color_path("%s.%s" % [split[0], property_path]),
		_color_number(str(from_val)),
		_color_number(str(to_val)),
		_color_number(str(duration)),
	])

func _cmd_find_node(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: find_node <pattern> [root_path]")
	var pattern := str(args[0]).strip_edges()
	var root_path := str(args[1]).strip_edges() if args.size() > 1 else ""

	var root: Node = null
	if root_path.is_empty():
		root = _get_scene_root()
	else:
		root = _resolve_node(root_path)
	if not root:
		return _format_error("Root not found: %s" % (root_path if not root_path.is_empty() else "<scene root>"))

	var matches: Array[String] = []
	_collect_matches(root, pattern, matches, 100)
	if matches.is_empty():
		return "No matches for %s" % pattern
	var header: String = "%d match(es) under %s:" % [matches.size(), _color_path(str(root.get_path()) if root.is_inside_tree() else root.name)]
	if matches.size() >= 100:
		header += "  (limit reached)"
	return "%s\n%s" % [header, "\n".join(matches)]

func _cmd_count_nodes(args: Array, piped_input: String = "") -> String:
	var root_path := " ".join(args).strip_edges() if args.size() > 0 else ""
	var root: Node = null
	if root_path.is_empty():
		root = _get_scene_root()
	else:
		root = _resolve_node(root_path)
	if not root:
		return _format_error("Root not found: %s" % (root_path if not root_path.is_empty() else "<scene root>"))

	var counts: Dictionary = {}
	var total: int = _walk_counts(root, counts)
	var class_names: Array = counts.keys()
	class_names.sort()

	var lines: Array[String] = []
	lines.append("Total: %s under %s" % [_color_number(str(total)), _color_path(str(root.get_path()) if root.is_inside_tree() else root.name)])
	for c in class_names:
		lines.append("  %-32s %s" % [str(c), _color_number(str(counts[c]))])
	return "\n".join(lines)

#endregion

#region Helpers

func _get_scene_root() -> Node:
	if Engine.is_editor_hint():
		return EditorInterface.get_edited_scene_root()
	var tree := Engine.get_main_loop() as SceneTree
	if not tree:
		return null
	if tree.current_scene:
		return tree.current_scene
	return tree.root

func _get_default_parent() -> Node:
	return _get_scene_root()

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

func _parse_trans(name: String) -> int:
	match name:
		"linear": return Tween.TRANS_LINEAR
		"sine": return Tween.TRANS_SINE
		"quad": return Tween.TRANS_QUAD
		"cubic": return Tween.TRANS_CUBIC
		"quart": return Tween.TRANS_QUART
		"quint": return Tween.TRANS_QUINT
		"expo": return Tween.TRANS_EXPO
		"elastic": return Tween.TRANS_ELASTIC
		"back": return Tween.TRANS_BACK
		"bounce": return Tween.TRANS_BOUNCE
		_: return -1

func _parse_ease(name: String) -> int:
	match name:
		"in": return Tween.EASE_IN
		"out": return Tween.EASE_OUT
		"in_out": return Tween.EASE_IN_OUT
		"out_in": return Tween.EASE_OUT_IN
		_: return -1

func _collect_matches(node: Node, pattern: String, out: Array[String], limit: int) -> void:
	if out.size() >= limit:
		return
	if node.name.match(pattern):
		out.append(str(node.get_path()) if node.is_inside_tree() else node.name)
	for child in node.get_children():
		if out.size() >= limit:
			return
		_collect_matches(child, pattern, out, limit)

func _walk_counts(node: Node, counts: Dictionary) -> int:
	var cls := node.get_class()
	counts[cls] = int(counts.get(cls, 0)) + 1
	var total: int = 1
	for child in node.get_children():
		total += _walk_counts(child, counts)
	return total

func _type_name(type_id: int) -> String:
	match type_id:
		TYPE_NIL: return "void"
		TYPE_BOOL: return "bool"
		TYPE_INT: return "int"
		TYPE_FLOAT: return "float"
		TYPE_STRING: return "String"
		TYPE_STRING_NAME: return "StringName"
		TYPE_VECTOR2: return "Vector2"
		TYPE_VECTOR2I: return "Vector2i"
		TYPE_VECTOR3: return "Vector3"
		TYPE_VECTOR3I: return "Vector3i"
		TYPE_VECTOR4: return "Vector4"
		TYPE_COLOR: return "Color"
		TYPE_NODE_PATH: return "NodePath"
		TYPE_RID: return "RID"
		TYPE_OBJECT: return "Object"
		TYPE_CALLABLE: return "Callable"
		TYPE_SIGNAL: return "Signal"
		TYPE_DICTIONARY: return "Dictionary"
		TYPE_ARRAY: return "Array"
		TYPE_PACKED_BYTE_ARRAY: return "PackedByteArray"
		TYPE_PACKED_STRING_ARRAY: return "PackedStringArray"
		TYPE_TRANSFORM2D: return "Transform2D"
		TYPE_TRANSFORM3D: return "Transform3D"
		TYPE_BASIS: return "Basis"
		_: return "Variant"

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

#endregion

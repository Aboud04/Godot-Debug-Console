@tool
class_name DebugConsoleWatchpointCommands extends RefCounted

# Extension module: property watchpoints. Mirrors the SceneCommands shape -
# instantiated by the orchestrator with a strong reference, then
# register_commands(registry, core) wires Callables on this RefCounted.
#
# Watchpoints poll a node property every frame and react to changes:
#   - log         : write each change to the console
#   - break       : pause the SceneTree (and breakpoint) on change
#   - log_to      : mirror change log to a file
#   - compare     : assertion mode - push_error when value != expected
#
# Polling requires a Node in the tree (RefCounted has no _process), so we
# instantiate an inner Node subclass and parent it under `core` (which the
# orchestrator owns). The poller calls back via a WeakRef to avoid keeping
# this RefCounted alive past plugin shutdown.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_WARN := "#F5B041"

const _MAX_HISTORY := 256
const _POLLER_NAME := "DebugConsoleWatchpointPoller"

var _registry: Node
var _core: Node
var _next_id: int = 1
var _watchpoints: Dictionary = {}
var _poller: Node = null

class _WatchpointPoller extends Node:
	var owner_ref: WeakRef

	func _process(_delta: float) -> void:
		if owner_ref == null:
			return
		var owner: Object = owner_ref.get_ref()
		if owner == null:
			return
		owner.call("_poll")


func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("wp_add", _cmd_wp_add, "Add watchpoint that logs every change: wp_add <path>.<property>", "game")
	_registry.register_command("wp_break", _cmd_wp_break, "Add watchpoint that pauses the scene on change: wp_break <path>.<property>", "game")
	_registry.register_command("wp_list", _cmd_wp_list, "List active watchpoints: wp_list", "game")
	_registry.register_command("wp_remove", _cmd_wp_remove, "Remove a watchpoint: wp_remove <id|all>", "game")
	_registry.register_command("wp_history", _cmd_wp_history, "Show value-change log for a watchpoint: wp_history <id> [limit]", "game")
	_registry.register_command("wp_log_to", _cmd_wp_log_to, "Mirror changes to a file: wp_log_to <id> <file>", "game")
	_registry.register_command("wp_compare", _cmd_wp_compare, "Assertion mode - push_error if value != expected: wp_compare <id> <expected>", "game")
	_ensure_poller()


#region Command implementations

func _cmd_wp_add(args: Array, piped_input: String = "") -> String:
	return _create_watchpoint(args, false, "wp_add")

func _cmd_wp_break(args: Array, piped_input: String = "") -> String:
	return _create_watchpoint(args, true, "wp_break")

func _cmd_wp_list(args: Array, piped_input: String = "") -> String:
	if _watchpoints.is_empty():
		return "No active watchpoints."
	var ids: Array = _watchpoints.keys()
	ids.sort()
	var lines: Array[String] = []
	lines.append("Active watchpoints: %s" % _color_number(str(_watchpoints.size())))
	for id in ids:
		var wp: Dictionary = _watchpoints[id]
		var node: Node = _wp_node(wp)
		var alive: String = "alive" if node != null else "dead"
		var flags: Array[String] = []
		if bool(wp.get("log", false)):
			flags.append("log")
		if bool(wp.get("break", false)):
			flags.append("break")
		if not String(wp.get("log_file_path", "")).is_empty():
			flags.append("log_to=%s" % wp["log_file_path"])
		if bool(wp.get("has_expected", false)):
			flags.append("expect=%s" % str(wp.get("expected")))
		lines.append("  #%s %s.%s  [%s]  last=%s  history=%s  (%s)" % [
			_color_number(str(id)),
			_color_path(String(wp.get("node_path", ""))),
			String(wp.get("prop", "")),
			", ".join(flags) if not flags.is_empty() else "-",
			str(wp.get("last_value")),
			_color_number(str((wp.get("history", []) as Array).size())),
			alive,
		])
	return "\n".join(lines)

func _cmd_wp_remove(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: wp_remove <id|all>")
	var token := str(args[0]).strip_edges().to_lower()
	if token == "all":
		var n: int = _watchpoints.size()
		for id in _watchpoints.keys():
			_close_log(_watchpoints[id])
		_watchpoints.clear()
		return _format_success("Removed %d watchpoint(s)" % n)
	if not token.is_valid_int():
		return _format_error("Expected integer id or 'all', got: %s" % token)
	var id: int = token.to_int()
	if not _watchpoints.has(id):
		return _format_error("No watchpoint with id %d" % id)
	_close_log(_watchpoints[id])
	_watchpoints.erase(id)
	return _format_success("Removed watchpoint #%d" % id)

func _cmd_wp_history(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: wp_history <id> [limit]")
	var id_token := str(args[0]).strip_edges()
	if not id_token.is_valid_int():
		return _format_error("Expected integer id, got: %s" % id_token)
	var id: int = id_token.to_int()
	if not _watchpoints.has(id):
		return _format_error("No watchpoint with id %d" % id)
	var limit: int = 20
	if args.size() > 1 and str(args[1]).strip_edges().is_valid_int():
		limit = maxi(1, str(args[1]).to_int())

	var wp: Dictionary = _watchpoints[id]
	var history: Array = wp.get("history", []) as Array
	if history.is_empty():
		return "Watchpoint #%d has no recorded changes yet." % id

	var start_idx: int = maxi(0, history.size() - limit)
	var lines: Array[String] = []
	lines.append("History for #%s %s.%s  (showing %s of %s)" % [
		_color_number(str(id)),
		_color_path(String(wp.get("node_path", ""))),
		String(wp.get("prop", "")),
		_color_number(str(history.size() - start_idx)),
		_color_number(str(history.size())),
	])
	for i in range(start_idx, history.size()):
		var entry: Dictionary = history[i]
		lines.append("  [t=%ss] %s -> %s" % [
			_color_number(_format_time(float(entry.get("time", 0.0)))),
			str(entry.get("old")),
			str(entry.get("new")),
		])
	return "\n".join(lines)

func _cmd_wp_log_to(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: wp_log_to <id> <file>")
	var id_token := str(args[0]).strip_edges()
	if not id_token.is_valid_int():
		return _format_error("Expected integer id, got: %s" % id_token)
	var id: int = id_token.to_int()
	if not _watchpoints.has(id):
		return _format_error("No watchpoint with id %d" % id)
	var file_path: String = " ".join(args.slice(1)).strip_edges()
	if file_path.is_empty():
		return _format_error("File path is empty")

	var wp: Dictionary = _watchpoints[id]
	_close_log(wp)

	var f: FileAccess = FileAccess.open(file_path, FileAccess.WRITE)
	if f == null:
		var err: int = FileAccess.get_open_error()
		return _format_error("Could not open '%s' (FileAccess error %d)" % [file_path, err])
	var header := "# Debug Console watchpoint #%d  %s.%s  started_at=%s" % [
		id,
		String(wp.get("node_path", "")),
		String(wp.get("prop", "")),
		Time.get_datetime_string_from_system(false, true),
	]
	f.store_line(header)
	f.flush()

	wp["log_file_path"] = file_path
	wp["log_file_handle"] = f
	_watchpoints[id] = wp
	return _format_success("Mirroring #%d to %s" % [id, _color_path(file_path)])

func _cmd_wp_compare(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: wp_compare <id> <expected>")
	var id_token := str(args[0]).strip_edges()
	if not id_token.is_valid_int():
		return _format_error("Expected integer id, got: %s" % id_token)
	var id: int = id_token.to_int()
	if not _watchpoints.has(id):
		return _format_error("No watchpoint with id %d" % id)
	var raw: String = " ".join(args.slice(1)).strip_edges()
	var expected: Variant = _parse_value(raw)
	var wp: Dictionary = _watchpoints[id]
	wp["expected"] = expected
	wp["has_expected"] = true
	_watchpoints[id] = wp
	return _format_success("Watchpoint #%d will assert == %s" % [id, _color_number(str(expected))])

#endregion

#region Internal

func _create_watchpoint(args: Array, break_on_change: bool, cmd_name: String) -> String:
	if args.is_empty():
		return _format_error("Usage: %s <path>.<property>" % cmd_name)
	var selector := str(args[0]).strip_edges()
	var split := _split_selector(selector)
	if split.is_empty():
		return _format_error("Selector must be <path>.<property>: %s" % selector)
	var path: String = split[0]
	var prop: String = split[1]

	var node := _resolve_node(path)
	if node == null:
		return _format_error("Node not found: %s" % path)
	var initial: Variant = node.get_indexed(prop)
	if initial == null and not _property_exists(node, prop):
		return _format_error("Property not found: %s on %s" % [prop, node.get_class()])

	var id: int = _next_id
	_next_id += 1
	var wp: Dictionary = {
		"id": id,
		"node_ref": weakref(node),
		"node_path": path,
		"prop": prop,
		"last_value": initial,
		"history": [],
		"log": true,
		"break": break_on_change,
		"log_file_path": "",
		"log_file_handle": null,
		"expected": null,
		"has_expected": false,
	}
	_watchpoints[id] = wp
	_ensure_poller()

	var mode_label: String = "break" if break_on_change else "log"
	return _format_success("Watchpoint #%s [%s] on %s.%s  initial=%s" % [
		_color_number(str(id)),
		mode_label,
		_color_path(path),
		prop,
		str(initial),
	])

func _poll() -> void:
	if _watchpoints.is_empty():
		return
	var dead_ids: Array = []
	for id in _watchpoints.keys():
		var wp: Dictionary = _watchpoints[id]
		var node: Node = _wp_node(wp)
		if node == null:
			dead_ids.append(id)
			continue
		var prop: String = String(wp.get("prop", ""))
		var cur: Variant = node.get_indexed(prop)
		var last: Variant = wp.get("last_value")
		if _values_differ(cur, last):
			wp["last_value"] = cur
			_record_change(wp, last, cur)
			_watchpoints[id] = wp
	for id in dead_ids:
		_close_log(_watchpoints[id])
		_watchpoints.erase(id)
		push_warning("Watchpoint #%d removed: target node is no longer valid" % id)

func _record_change(wp: Dictionary, old_value: Variant, new_value: Variant) -> void:
	var history: Array = wp.get("history", []) as Array
	var entry: Dictionary = {
		"time": _now(),
		"old": old_value,
		"new": new_value,
	}
	history.append(entry)
	while history.size() > _MAX_HISTORY:
		history.pop_front()
	wp["history"] = history

	var label: String = "%s.%s" % [String(wp.get("node_path", "")), String(wp.get("prop", ""))]

	if bool(wp.get("log", false)):
		print("[wp #%d] %s: %s -> %s" % [int(wp.get("id", 0)), label, str(old_value), str(new_value)])

	var fh: Variant = wp.get("log_file_handle")
	if fh != null and fh is FileAccess:
		var f: FileAccess = fh
		f.store_line("%s\t%s\t%s\t%s" % [_format_time(entry["time"]), label, str(old_value), str(new_value)])
		f.flush()

	if bool(wp.get("has_expected", false)):
		var expected: Variant = wp.get("expected")
		if _values_differ(new_value, expected):
			push_error("[wp #%d] ASSERTION FAILED: %s = %s, expected %s" % [int(wp.get("id", 0)), label, str(new_value), str(expected)])
		else:
			print("[wp #%d] assertion OK: %s == %s" % [int(wp.get("id", 0)), label, str(expected)])

	if bool(wp.get("break", false)):
		push_error("[wp #%d] BREAK on change: %s = %s (was %s)" % [int(wp.get("id", 0)), label, str(new_value), str(old_value)])
		var tree := Engine.get_main_loop() as SceneTree
		if tree:
			tree.paused = true
		breakpoint

func _wp_node(wp: Dictionary) -> Node:
	var ref: Variant = wp.get("node_ref")
	if ref == null or not (ref is WeakRef):
		return null
	var obj: Object = (ref as WeakRef).get_ref()
	if obj == null or not (obj is Node):
		return null
	var node: Node = obj
	if not is_instance_valid(node):
		return null
	return node

func _close_log(wp: Dictionary) -> void:
	var fh: Variant = wp.get("log_file_handle")
	if fh != null and fh is FileAccess:
		(fh as FileAccess).flush()
	wp["log_file_handle"] = null

func _ensure_poller() -> void:
	if _poller != null and is_instance_valid(_poller) and _poller.is_inside_tree():
		return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	var parent: Node = null
	if _core != null and is_instance_valid(_core) and _core.is_inside_tree():
		parent = _core
	else:
		parent = tree.root
	if parent == null:
		return
	var poller := _WatchpointPoller.new()
	poller.name = _POLLER_NAME
	poller.owner_ref = weakref(self)
	poller.process_mode = Node.PROCESS_MODE_ALWAYS
	parent.add_child(poller)
	_poller = poller

func _property_exists(node: Node, prop: String) -> bool:
	var head: String = prop.split(":")[0].split(".")[0]
	for p in node.get_property_list():
		if String(p.get("name", "")) == head:
			return true
	return false

func _values_differ(a: Variant, b: Variant) -> bool:
	if typeof(a) != typeof(b):
		return true
	return a != b

func _now() -> float:
	var tree := Engine.get_main_loop() as SceneTree
	if tree:
		return float(Time.get_ticks_msec()) / 1000.0
	return 0.0

func _format_time(t: float) -> String:
	return "%.3f" % t

#endregion

#region Helpers (mirror SceneCommands shape)

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

func _get_scene_root() -> Node:
	if Engine.is_editor_hint():
		return EditorInterface.get_edited_scene_root()
	var tree := Engine.get_main_loop() as SceneTree
	if not tree:
		return null
	if tree.current_scene:
		return tree.current_scene
	return tree.root

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

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

#endregion

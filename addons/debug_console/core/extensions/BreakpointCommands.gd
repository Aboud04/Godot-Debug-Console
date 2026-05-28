@tool
class_name DebugConsoleBreakpointCommands extends RefCounted

# Poll-based breakpoint commands. Godot 4 exposes no public hook to register
# native debugger breakpoints from script, so this module emulates them at the
# SceneTree level: an expression breakpoint is re-evaluated every _process
# frame by a helper Node and pauses the tree on the rising edge (false ->
# true). A method breakpoint wraps a Callable-typed property on a target node
# so that invoking it bumps the hit counter, pauses the tree, then forwards
# to the original Callable.
#
# These are best-effort hooks intended for live debugging from the console.
# They cannot pause arbitrary script lines like the native debugger does.
#
# Registration parallels SceneCommands: the orchestrator holds a strong
# reference to this RefCounted, then calls register_commands(registry, core).
# Commands are registered with context "game" because pausing the SceneTree
# only makes sense at runtime.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_DIM := "#888888"

const _POLLER_SCRIPT_SOURCE: String = """
extends Node
var commands_ref = null
func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
func _process(_delta: float) -> void:
	if commands_ref and commands_ref.has_method(\"_poll_tick\"):
		commands_ref._poll_tick()
"""

var _registry: Node
var _core: Node

var _breakpoints: Dictionary = {}
var _next_id: int = 1
var _poller: Node = null

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("bp_add", _cmd_bp_add, "Add expression breakpoint - pauses tree when expr becomes true: bp_add <expr>", "game")
	_registry.register_command("bp_list", _cmd_bp_list, "List all breakpoints with id, type, state, and hit count", "game")
	_registry.register_command("bp_remove", _cmd_bp_remove, "Remove a breakpoint: bp_remove <id|all>", "game")
	_registry.register_command("bp_enable", _cmd_bp_enable, "Enable a breakpoint: bp_enable <id>", "game")
	_registry.register_command("bp_disable", _cmd_bp_disable, "Disable a breakpoint: bp_disable <id>", "game")
	_registry.register_command("bp_hit_count", _cmd_bp_hit_count, "Show hit count for a breakpoint: bp_hit_count <id>", "game")
	_registry.register_command("bp_at_method", _cmd_bp_at_method, "Pause on call of a Callable-typed property: bp_at_method <node_path>.<method>", "game")
	_registry.register_command("bp_clear_all", _cmd_bp_clear_all, "Remove every registered breakpoint", "game")

#region Command implementations

func _cmd_bp_add(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: bp_add <expr>")
	var expr_string := " ".join(args).strip_edges()
	if expr_string.is_empty():
		return _format_error("Usage: bp_add <expr>")

	var expr := Expression.new()
	var parse_err := expr.parse(expr_string, [])
	if parse_err != OK:
		return _format_error("Parse failed: %s" % expr.get_error_text())

	var bp_id := _next_id
	_next_id += 1
	var bp: Dictionary = {
		"id": bp_id,
		"type": "expr",
		"expr_string": expr_string,
		"expr": expr,
		"last_value": false,
		"enabled": true,
		"hit_count": 0,
	}
	_breakpoints[bp_id] = bp
	_ensure_poller()
	return _format_success("Breakpoint #%d added: %s" % [bp_id, _color_path(expr_string)])

func _cmd_bp_list(args: Array, piped_input: String = "") -> String:
	if _breakpoints.is_empty():
		return "[color=%s]<no breakpoints>[/color]" % _COLOR_DIM
	var ids: Array = _breakpoints.keys()
	ids.sort()
	var lines: Array[String] = []
	lines.append("%s breakpoint(s):" % _color_number(str(ids.size())))
	for id in ids:
		var bp: Dictionary = _breakpoints[id]
		var state := "on" if bool(bp.get("enabled", true)) else "off"
		var hit: int = int(bp.get("hit_count", 0))
		var detail: String = ""
		if bp.get("type", "") == "expr":
			detail = "expr=%s" % _color_path(str(bp.get("expr_string", "")))
		else:
			detail = "method=%s" % _color_path("%s.%s" % [bp.get("node_path", ""), bp.get("method", "")])
		lines.append("  #%s [%s] hits=%s %s" % [
			_color_number(str(id)),
			state,
			_color_number(str(hit)),
			detail,
		])
	return "\n".join(lines)

func _cmd_bp_remove(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: bp_remove <id|all>")
	var arg := str(args[0]).strip_edges().to_lower()
	if arg == "all":
		return _cmd_bp_clear_all([])
	if not arg.is_valid_int():
		return _format_error("Expected an integer id or 'all', got: %s" % arg)
	var id := arg.to_int()
	if not _breakpoints.has(id):
		return _format_error("No breakpoint with id %d" % id)
	_dispose_breakpoint(_breakpoints[id])
	_breakpoints.erase(id)
	return _format_success("Removed breakpoint #%d" % id)

func _cmd_bp_enable(args: Array, piped_input: String = "") -> String:
	return _set_enabled(args, true, "bp_enable")

func _cmd_bp_disable(args: Array, piped_input: String = "") -> String:
	return _set_enabled(args, false, "bp_disable")

func _cmd_bp_hit_count(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: bp_hit_count <id>")
	var raw := str(args[0]).strip_edges()
	if not raw.is_valid_int():
		return _format_error("Expected an integer id, got: %s" % raw)
	var id := raw.to_int()
	if not _breakpoints.has(id):
		return _format_error("No breakpoint with id %d" % id)
	var bp: Dictionary = _breakpoints[id]
	return "Breakpoint #%d hits = %s" % [id, _color_number(str(int(bp.get("hit_count", 0))))]

func _cmd_bp_at_method(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: bp_at_method <node_path>.<method>")
	var selector := str(args[0]).strip_edges()
	var split := _split_selector(selector)
	if split.is_empty():
		return _format_error("Selector must be <path>.<method>: %s" % selector)
	var node := _resolve_node(split[0])
	if not node:
		return _format_error("Node not found: %s" % split[0])
	var method_name: String = split[1]

	var current_value: Variant = node.get(method_name)
	if not (current_value is Callable):
		return _format_error("Property '%s' on %s is not a Callable (poll-based bp can only wrap Callable-typed properties)" % [method_name, node.get_class()])

	var original_callable: Callable = current_value
	var bp_id := _next_id
	_next_id += 1
	var bp: Dictionary = {
		"id": bp_id,
		"type": "method",
		"node_path": split[0],
		"method": method_name,
		"original": original_callable,
		"target": node,
		"enabled": true,
		"hit_count": 0,
	}
	_breakpoints[bp_id] = bp
	bp["wrapper"] = _make_method_wrapper(bp_id)
	node.set(method_name, bp["wrapper"])
	_ensure_poller()
	return _format_success("Method breakpoint #%d on %s.%s" % [bp_id, _color_path(split[0]), method_name])

func _cmd_bp_clear_all(args: Array, piped_input: String = "") -> String:
	var n: int = _breakpoints.size()
	for id in _breakpoints.keys():
		_dispose_breakpoint(_breakpoints[id])
	_breakpoints.clear()
	return _format_success("Cleared %d breakpoint(s)" % n)

#endregion

#region Polling and pause

func _poll_tick() -> void:
	if _breakpoints.is_empty():
		return
	var tree := Engine.get_main_loop() as SceneTree
	if not tree or tree.paused:
		return
	var base: Object = _get_scene_root()
	for id in _breakpoints.keys():
		var bp: Dictionary = _breakpoints[id]
		if bp.get("type", "") != "expr":
			continue
		if not bool(bp.get("enabled", true)):
			bp["last_value"] = false
			continue
		var expr: Expression = bp.get("expr")
		if expr == null:
			continue
		var result: Variant = expr.execute([], base, false)
		if expr.has_execute_failed():
			bp["last_value"] = false
			continue
		var truthy: bool = _is_truthy(result)
		var prev: bool = bool(bp.get("last_value", false))
		bp["last_value"] = truthy
		if truthy and not prev:
			bp["hit_count"] = int(bp.get("hit_count", 0)) + 1
			_trigger_pause("expr bp #%d: %s" % [id, str(bp.get("expr_string", ""))])

func _trigger_pause(reason: String) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if not tree:
		return
	tree.paused = true
	print("[DebugConsole] Breakpoint hit -> tree paused (%s)" % reason)

func _make_method_wrapper(bp_id: int) -> Callable:
	var bps: Dictionary = _breakpoints
	var pauser: Callable = Callable(self, "_trigger_pause")
	return func(a0 = null, a1 = null, a2 = null, a3 = null):
		var bp: Dictionary = bps.get(bp_id, {})
		if bp.is_empty():
			return null
		if bool(bp.get("enabled", true)):
			bp["hit_count"] = int(bp.get("hit_count", 0)) + 1
			pauser.call("method bp #%d %s.%s" % [bp_id, str(bp.get("node_path", "")), str(bp.get("method", ""))])
		var orig: Callable = bp.get("original", Callable())
		if not orig.is_valid():
			return null
		var collected: Array = []
		for v in [a0, a1, a2, a3]:
			if v == null:
				break
			collected.append(v)
		return orig.callv(collected)

func _set_enabled(args: Array, value: bool, cmd: String) -> String:
	if args.is_empty():
		return _format_error("Usage: %s <id>" % cmd)
	var raw := str(args[0]).strip_edges()
	if not raw.is_valid_int():
		return _format_error("Expected an integer id, got: %s" % raw)
	var id := raw.to_int()
	if not _breakpoints.has(id):
		return _format_error("No breakpoint with id %d" % id)
	var bp: Dictionary = _breakpoints[id]
	bp["enabled"] = value
	if not value:
		bp["last_value"] = false
	return _format_success("Breakpoint #%d %s" % [id, "enabled" if value else "disabled"])

func _dispose_breakpoint(bp: Dictionary) -> void:
	if bp.get("type", "") != "method":
		return
	var target = bp.get("target")
	if target == null or not is_instance_valid(target):
		return
	var method_name: String = str(bp.get("method", ""))
	if method_name.is_empty():
		return
	var current: Variant = target.get(method_name)
	if current is Callable and current == bp.get("wrapper"):
		target.set(method_name, bp.get("original", Callable()))

func _ensure_poller() -> Node:
	if is_instance_valid(_poller):
		return _poller
	var tree := Engine.get_main_loop() as SceneTree
	if not tree or not tree.root:
		return null
	var script := GDScript.new()
	script.source_code = _POLLER_SCRIPT_SOURCE
	var reload_err := script.reload()
	if reload_err != OK:
		return null
	var node := Node.new()
	node.name = "DebugConsoleBreakpointPoller"
	node.set_script(script)
	node.set("commands_ref", self)
	tree.root.add_child(node)
	_poller = node
	return _poller

#endregion

#region Helpers

func _get_scene_root() -> Node:
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

func _is_truthy(value: Variant) -> bool:
	if value == null:
		return false
	var t := typeof(value)
	if t == TYPE_BOOL:
		return bool(value)
	if t == TYPE_INT:
		return int(value) != 0
	if t == TYPE_FLOAT:
		return float(value) != 0.0
	if t == TYPE_STRING or t == TYPE_STRING_NAME:
		return not str(value).is_empty()
	if t == TYPE_ARRAY:
		return not (value as Array).is_empty()
	if t == TYPE_DICTIONARY:
		return not (value as Dictionary).is_empty()
	return true

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

#endregion

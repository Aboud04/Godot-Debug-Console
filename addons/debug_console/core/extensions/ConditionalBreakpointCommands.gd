@tool
class_name DebugConsoleConditionalBreakpointCommands extends RefCounted

# Conditional breakpoints: extend the basic poll-based BreakpointCommands with a
# hit-count threshold and an additional gating expression. Modeled after GDB's
# `condition`, `ignore`, and `tbreak`, and the equivalent IDE features in
# Visual Studio and IntelliJ. Each frame a helper Node calls _poll_tick which
# re-evaluates the primary expression for every registered breakpoint; on a
# false -> true edge the hit counter advances. When hit_count >= hit_threshold
# AND the optional `--when` gate expression evaluates truthy the SceneTree is
# paused via get_tree().paused = true. Temp breakpoints auto-remove themselves
# right after their first effective pause.
#
# Limitations parallel BreakpointCommands: this cannot pause arbitrary script
# lines the way the native debugger does. It is a best-effort hook intended for
# live debugging from the console at SceneTree granularity. Game context only,
# because pausing the tree from inside the editor is not meaningful.
#
# Registration parallels SceneCommands / BreakpointCommands: the orchestrator
# instantiates this RefCounted, retains a strong reference, then calls
# register_commands(registry, core).

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
	_registry.register_command("bpc_add", _cmd_bpc_add, "Add conditional breakpoint: bpc_add <expr> [--hit N] [--when <cond_expr>]", "game")
	_registry.register_command("bpc_list", _cmd_bpc_list, "List conditional breakpoints with hit counters", "game")
	_registry.register_command("bpc_remove", _cmd_bpc_remove, "Remove a conditional breakpoint: bpc_remove <id|all>", "game")
	_registry.register_command("bpc_hit_count", _cmd_bpc_hit_count, "Show hit count for a conditional bp: bpc_hit_count <id>", "game")
	_registry.register_command("bpc_reset_count", _cmd_bpc_reset_count, "Reset hit count to zero: bpc_reset_count <id>", "game")
	_registry.register_command("bpc_temp", _cmd_bpc_temp, "One-shot conditional bp, auto-removes on first hit: bpc_temp <expr>", "game")

#region Command implementations

func _cmd_bpc_add(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: bpc_add <expr> [--hit N] [--when <cond_expr>]")

	var parsed: Dictionary = _parse_conditional_args(args)
	if parsed.has("error"):
		return _format_error(str(parsed["error"]))

	var expr_string: String = str(parsed.get("expr", ""))
	if expr_string.is_empty():
		return _format_error("Primary expression is empty. Usage: bpc_add <expr> [--hit N] [--when <cond_expr>]")

	var hit_threshold: int = int(parsed.get("hit", 1))
	var when_string: String = str(parsed.get("when", ""))

	var expr := Expression.new()
	var parse_err := expr.parse(expr_string, [])
	if parse_err != OK:
		return _format_error("Parse failed on <expr>: %s" % expr.get_error_text())

	var when_expr: Expression = null
	if not when_string.is_empty():
		when_expr = Expression.new()
		var w_err := when_expr.parse(when_string, [])
		if w_err != OK:
			return _format_error("Parse failed on --when expression: %s" % when_expr.get_error_text())

	var bp_id := _register_breakpoint(expr_string, expr, when_string, when_expr, hit_threshold, false)
	return _format_success("Conditional breakpoint #%d added: %s%s%s" % [
		bp_id,
		_color_path(expr_string),
		(" when=%s" % _color_path(when_string)) if not when_string.is_empty() else "",
		" hit>=" + _color_number(str(hit_threshold)) if hit_threshold > 1 else "",
	])

func _cmd_bpc_list(args: Array, piped_input: String = "") -> String:
	if _breakpoints.is_empty():
		return "[color=%s]<no conditional breakpoints>[/color]" % _COLOR_DIM
	var ids: Array = _breakpoints.keys()
	ids.sort()
	var lines: Array[String] = []
	lines.append("%s conditional breakpoint(s):" % _color_number(str(ids.size())))
	for id in ids:
		var bp: Dictionary = _breakpoints[id]
		var hit: int = int(bp.get("hit_count", 0))
		var threshold: int = int(bp.get("hit_threshold", 1))
		var temp_tag: String = " (temp)" if bool(bp.get("is_temp", false)) else ""
		var when_part: String = ""
		var when_string: String = str(bp.get("when_string", ""))
		if not when_string.is_empty():
			when_part = " when=%s" % _color_path(when_string)
		lines.append("  #%s%s hits=%s/%s expr=%s%s" % [
			_color_number(str(id)),
			temp_tag,
			_color_number(str(hit)),
			_color_number(str(threshold)),
			_color_path(str(bp.get("expr_string", ""))),
			when_part,
		])
	return "\n".join(lines)

func _cmd_bpc_remove(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: bpc_remove <id|all>")
	var arg := str(args[0]).strip_edges().to_lower()
	if arg == "all":
		var n: int = _breakpoints.size()
		_breakpoints.clear()
		return _format_success("Cleared %d conditional breakpoint(s)" % n)
	if not arg.is_valid_int():
		return _format_error("Expected an integer id or 'all', got: %s" % arg)
	var id := arg.to_int()
	if not _breakpoints.has(id):
		return _format_error("No conditional breakpoint with id %d" % id)
	_breakpoints.erase(id)
	return _format_success("Removed conditional breakpoint #%d" % id)

func _cmd_bpc_hit_count(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: bpc_hit_count <id>")
	var raw := str(args[0]).strip_edges()
	if not raw.is_valid_int():
		return _format_error("Expected an integer id, got: %s" % raw)
	var id := raw.to_int()
	if not _breakpoints.has(id):
		return _format_error("No conditional breakpoint with id %d" % id)
	var bp: Dictionary = _breakpoints[id]
	return "Conditional breakpoint #%d hits = %s (threshold=%s)" % [
		id,
		_color_number(str(int(bp.get("hit_count", 0)))),
		_color_number(str(int(bp.get("hit_threshold", 1)))),
	]

func _cmd_bpc_reset_count(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: bpc_reset_count <id>")
	var raw := str(args[0]).strip_edges()
	if not raw.is_valid_int():
		return _format_error("Expected an integer id, got: %s" % raw)
	var id := raw.to_int()
	if not _breakpoints.has(id):
		return _format_error("No conditional breakpoint with id %d" % id)
	var bp: Dictionary = _breakpoints[id]
	bp["hit_count"] = 0
	bp["last_value"] = false
	return _format_success("Conditional breakpoint #%d hit count reset to 0" % id)

func _cmd_bpc_temp(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: bpc_temp <expr>")
	var expr_string := " ".join(args).strip_edges()
	if expr_string.is_empty():
		return _format_error("Usage: bpc_temp <expr>")

	var expr := Expression.new()
	var parse_err := expr.parse(expr_string, [])
	if parse_err != OK:
		return _format_error("Parse failed: %s" % expr.get_error_text())

	var bp_id := _register_breakpoint(expr_string, expr, "", null, 1, true)
	return _format_success("Temp conditional breakpoint #%d (one-shot): %s" % [bp_id, _color_path(expr_string)])

#endregion

#region Polling and pause

func _poll_tick() -> void:
	if _breakpoints.is_empty():
		return
	var tree := Engine.get_main_loop() as SceneTree
	if not tree or tree.paused:
		return
	var base: Object = _get_scene_root()
	var to_remove: Array[int] = []
	for id in _breakpoints.keys():
		var bp: Dictionary = _breakpoints[id]
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

		if not (truthy and not prev):
			continue

		bp["hit_count"] = int(bp.get("hit_count", 0)) + 1
		var hit_count: int = int(bp["hit_count"])
		var threshold: int = int(bp.get("hit_threshold", 1))
		if hit_count < threshold:
			continue

		var when_expr: Expression = bp.get("when_expr")
		var gate_ok: bool = true
		if when_expr != null:
			var w_result: Variant = when_expr.execute([], base, false)
			if when_expr.has_execute_failed():
				gate_ok = false
			else:
				gate_ok = _is_truthy(w_result)
		if not gate_ok:
			continue

		_trigger_pause("bpc #%d hit %d/%d: %s" % [
			id,
			hit_count,
			threshold,
			str(bp.get("expr_string", "")),
		])
		if bool(bp.get("is_temp", false)):
			to_remove.append(int(id))

	for id in to_remove:
		_breakpoints.erase(id)

func _trigger_pause(reason: String) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if not tree:
		return
	tree.paused = true
	print("[DebugConsole] Conditional breakpoint hit -> tree paused (%s)" % reason)

func _register_breakpoint(expr_string: String, expr: Expression, when_string: String, when_expr: Expression, hit_threshold: int, is_temp: bool) -> int:
	var bp_id := _next_id
	_next_id += 1
	var bp: Dictionary = {
		"id": bp_id,
		"expr_string": expr_string,
		"expr": expr,
		"when_string": when_string,
		"when_expr": when_expr,
		"hit_threshold": hit_threshold,
		"hit_count": 0,
		"last_value": false,
		"is_temp": is_temp,
	}
	_breakpoints[bp_id] = bp
	_ensure_poller()
	return bp_id

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
	node.name = "DebugConsoleConditionalBreakpointPoller"
	node.set_script(script)
	node.set("commands_ref", self)
	tree.root.add_child(node)
	_poller = node
	return _poller

#endregion

#region Helpers

func _parse_conditional_args(args: Array) -> Dictionary:
	var expr_tokens: Array[String] = []
	var when_tokens: Array[String] = []
	var hit_threshold: int = 1
	var section: String = "expr"
	var i: int = 0
	while i < args.size():
		var token := str(args[i])
		if token == "--hit":
			if i + 1 >= args.size():
				return {"error": "--hit requires an integer value"}
			var n_str := str(args[i + 1]).strip_edges()
			if not n_str.is_valid_int():
				return {"error": "--hit value must be an integer, got: %s" % n_str}
			hit_threshold = n_str.to_int()
			if hit_threshold < 1:
				return {"error": "--hit must be >= 1, got: %d" % hit_threshold}
			i += 2
			section = "post"
			continue
		if token == "--when":
			section = "when"
			i += 1
			continue
		if section == "expr":
			expr_tokens.append(token)
		elif section == "when":
			when_tokens.append(token)
		i += 1
	return {
		"expr": " ".join(expr_tokens).strip_edges(),
		"when": " ".join(when_tokens).strip_edges(),
		"hit": hit_threshold,
	}

func _get_scene_root() -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if not tree:
		return null
	if tree.current_scene:
		return tree.current_scene
	return tree.root

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

@tool
class_name DebugConsoleAssertCommands extends RefCounted

# Tier 7 - runtime assertion / contract commands. Ships separately from
# BuiltInCommands.gd to keep that file manageable as the command surface grows.
# The orchestrator instantiates one of these, holds a strong reference, and
# calls register_commands(registry, core). All commands route through the
# strong-referenced instance so their Callables stay valid for the lifetime
# of the plugin.
#
# Commands here intentionally avoid touching the file-based test runner,
# the editor-dock plugin glue, or BuiltInCommands.gd; everything they need
# (registry + core) is passed in. The module is self-contained: invariants
# and pending postconditions are stored on the instance and torn down by
# disconnecting the signals we connected.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_MUTED := "#888888"

var _registry: Node
var _core: Node

# name -> { "expr": String, "last_value": Variant, "last_ok": bool, "violations": int, "last_error": String }
var _invariants: Dictionary = {}
var _invariants_connected: bool = false

# Pending postcondition state. We connect to CommandRegistry.command_executed
# and use a skip counter so the very emit caused by `log_postcondition`
# itself does not trigger evaluation.
var _pending_postcondition: String = ""
var _pending_postcondition_skip: int = 0
var _postcondition_connected: bool = false

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("log_assert", _cmd_log_assert, "Assert an expression is truthy: log_assert <expr>", "both")
	_registry.register_command("log_expect", _cmd_log_expect, "Compare two expressions: log_expect <a> <op> <b>  (op: == != < > <= >=)", "both")
	_registry.register_command("log_invariant", _cmd_log_invariant, "Register a named invariant tracked every frame: log_invariant <name> <expr>", "both")
	_registry.register_command("log_postcondition", _cmd_log_postcondition, "Evaluate an expression after the next command runs: log_postcondition <expr>", "both")
	_registry.register_command("assert_node", _cmd_assert_node, "Error if the node at <path> is null: assert_node <path>", "both")
	_registry.register_command("assert_type", _cmd_assert_type, "Validate that <path> 'is' the given class: assert_type <path> <ClassName>", "both")
	_registry.register_command("invariants", _cmd_invariants, "List active invariants and their last-known truth values", "both")

#region Command implementations

func _cmd_log_assert(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: log_assert <expr>")
	var expr_str := _join_args(args)
	var eval: Dictionary = _evaluate(expr_str)
	if not bool(eval["ok"]):
		return _format_error("log_assert parse/eval failed: %s | %s" % [expr_str, str(eval["error"])])
	var value: Variant = eval["value"]
	if _is_truthy(value):
		return _format_success("assert ok: %s = %s" % [expr_str, _color_number(_stringify(value))])
	var stack_text := _format_stack()
	var msg := "log_assert FAILED: %s = %s" % [expr_str, _stringify(value)]
	push_error(msg + (("\n" + stack_text) if not stack_text.is_empty() else ""))
	var out := _format_error(msg)
	if not stack_text.is_empty():
		out += "\n" + _color_muted(stack_text)
	return out

func _cmd_log_expect(args: Array, piped_input: String = "") -> String:
	if args.size() < 3:
		return _format_error("Usage: log_expect <a> <op> <b>  (op: == != < > <= >=)")

	# The operator is always one of a small fixed set. Find it; everything before
	# is <a>, everything after is <b>. This lets users pass multi-token
	# expressions on either side without quoting.
	var op_idx: int = -1
	for i in range(args.size()):
		if _is_compare_op(str(args[i])):
			op_idx = i
			break
	if op_idx <= 0 or op_idx >= args.size() - 1:
		return _format_error("Could not locate operator. Usage: log_expect <a> <op> <b>")

	var op := str(args[op_idx]).strip_edges()
	var a_str := " ".join(args.slice(0, op_idx)).strip_edges()
	var b_str := " ".join(args.slice(op_idx + 1)).strip_edges()

	var a_eval: Dictionary = _evaluate(a_str)
	if not bool(a_eval["ok"]):
		return _format_error("log_expect: failed to evaluate <a>: %s | %s" % [a_str, str(a_eval["error"])])
	var b_eval: Dictionary = _evaluate(b_str)
	if not bool(b_eval["ok"]):
		return _format_error("log_expect: failed to evaluate <b>: %s | %s" % [b_str, str(b_eval["error"])])

	var a_val: Variant = a_eval["value"]
	var b_val: Variant = b_eval["value"]
	var compare: Dictionary = _compare(a_val, op, b_val)
	if not bool(compare["ok"]):
		return _format_error(str(compare["error"]))

	var passed := bool(compare["result"])
	var rendered := "%s %s %s  =>  %s vs %s" % [a_str, op, b_str, _stringify(a_val), _stringify(b_val)]
	if passed:
		return _format_success("expect ok: " + rendered)
	var stack_text := _format_stack()
	var msg := "log_expect FAILED: " + rendered
	push_error(msg + (("\n" + stack_text) if not stack_text.is_empty() else ""))
	var out := _format_error(msg)
	if not stack_text.is_empty():
		out += "\n" + _color_muted(stack_text)
	return out

func _cmd_log_invariant(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: log_invariant <name> <expr>")
	var name := str(args[0]).strip_edges()
	if name.is_empty():
		return _format_error("Invariant name cannot be empty")
	var expr_str := " ".join(args.slice(1)).strip_edges()
	if expr_str.is_empty():
		return _format_error("Invariant expression cannot be empty")

	# Validate the expression parses now so the user gets immediate feedback,
	# rather than discovering the typo on the first frame tick.
	var probe := Expression.new()
	var parse_err: int = probe.parse(expr_str, [])
	if parse_err != OK:
		return _format_error("Invariant '%s' parse error: %s" % [name, probe.get_error_text()])

	_invariants[name] = {
		"expr": expr_str,
		"last_value": null,
		"last_ok": true,
		"violations": 0,
		"last_error": "",
	}
	_ensure_invariants_hooked()
	# Evaluate once immediately so the user sees a useful initial value.
	_tick_invariant(name)
	var entry: Dictionary = _invariants[name]
	var initial: String = _stringify(entry.get("last_value", null))
	return _format_success("Invariant '%s' registered: %s  (initial: %s)" % [name, expr_str, initial])

func _cmd_log_postcondition(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: log_postcondition <expr>")
	var expr_str := _join_args(args)

	var probe := Expression.new()
	var parse_err: int = probe.parse(expr_str, [])
	if parse_err != OK:
		return _format_error("Postcondition parse error: %s" % probe.get_error_text())

	_pending_postcondition = expr_str
	# The registry will emit command_executed for THIS command after we return;
	# skip that one emit so the postcondition fires after the user's NEXT command.
	_pending_postcondition_skip = 1
	_ensure_postcondition_hooked()
	return _format_success("Postcondition armed; will evaluate after next command: %s" % expr_str)

func _cmd_assert_node(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: assert_node <path>")
	var path := _join_args(args)
	var node := _resolve_node(path)
	if not node:
		var msg := "assert_node FAILED: node not found at '%s'" % path
		push_error(msg)
		var stack_text := _format_stack()
		var out := _format_error(msg)
		if not stack_text.is_empty():
			out += "\n" + _color_muted(stack_text)
		return out
	return _format_success("assert_node ok: %s [%s]" % [_color_path(path), node.get_class()])

func _cmd_assert_type(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: assert_type <path> <ClassName>")
	# The class name is the LAST argument so the path may contain spaces. We
	# also tolerate the documented two-argument form.
	var class_name_arg := str(args[args.size() - 1]).strip_edges()
	var path := " ".join(args.slice(0, args.size() - 1)).strip_edges()
	if path.is_empty() or class_name_arg.is_empty():
		return _format_error("Usage: assert_type <path> <ClassName>")

	var node := _resolve_node(path)
	if not node:
		var miss_msg := "assert_type FAILED: node not found at '%s'" % path
		push_error(miss_msg)
		return _format_error(miss_msg)

	var matches: bool = _node_is_class(node, class_name_arg)
	if matches:
		return _format_success("assert_type ok: %s is %s" % [_color_path(path), class_name_arg])
	var actual := node.get_class()
	var script_name := _script_global_name(node)
	if not script_name.is_empty():
		actual = "%s (script: %s)" % [actual, script_name]
	var msg := "assert_type FAILED: %s is %s, expected %s" % [path, actual, class_name_arg]
	push_error(msg)
	var stack_text := _format_stack()
	var out := _format_error(msg)
	if not stack_text.is_empty():
		out += "\n" + _color_muted(stack_text)
	return out

func _cmd_invariants(args: Array, piped_input: String = "") -> String:
	if _invariants.is_empty():
		return "No invariants registered. Use 'log_invariant <name> <expr>' to add one."
	var names: Array = _invariants.keys()
	names.sort()
	var lines: Array[String] = []
	lines.append("Active invariants (%s):" % _color_number(str(names.size())))
	for n in names:
		var entry: Dictionary = _invariants[n]
		var last_value: Variant = entry.get("last_value", null)
		var last_ok: bool = bool(entry.get("last_ok", true))
		var violations: int = int(entry.get("violations", 0))
		var expr_str: String = str(entry.get("expr", ""))
		var last_error: String = str(entry.get("last_error", ""))
		var status_color: String = _COLOR_SUCCESS if (last_ok and _is_truthy(last_value)) else _COLOR_ERROR
		var status_text: String
		if not last_ok:
			status_text = "ERROR"
		elif _is_truthy(last_value):
			status_text = "TRUE"
		else:
			status_text = "FALSE"
		lines.append("  [color=%s]%s[/color]  %s  value=%s  violations=%s" % [
			status_color,
			n,
			expr_str,
			_color_number(_stringify(last_value)),
			_color_number(str(violations)),
		])
		if not last_ok and not last_error.is_empty():
			lines.append("    [color=%s]eval error: %s[/color]" % [_COLOR_ERROR, last_error])
		lines.append("    " + _color_muted("status: " + status_text))
	return "\n".join(lines)

#endregion

#region Invariant tracking

func _ensure_invariants_hooked() -> void:
	if _invariants_connected:
		return
	var tree := Engine.get_main_loop() as SceneTree
	if not tree:
		return
	if not tree.process_frame.is_connected(_on_process_frame):
		tree.process_frame.connect(_on_process_frame)
	_invariants_connected = true

func _on_process_frame() -> void:
	if _invariants.is_empty():
		return
	for n in _invariants.keys():
		_tick_invariant(n)

func _tick_invariant(name: String) -> void:
	if not _invariants.has(name):
		return
	var entry: Dictionary = _invariants[name]
	var expr_str: String = str(entry.get("expr", ""))
	var eval: Dictionary = _evaluate(expr_str)
	if not bool(eval["ok"]):
		var err_text: String = str(eval["error"])
		var prev_error: String = str(entry.get("last_error", ""))
		entry["last_ok"] = false
		entry["last_error"] = err_text
		# Only log the same parse/eval error once to avoid spamming each frame.
		if err_text != prev_error:
			push_error("[invariant '%s'] eval error: %s" % [name, err_text])
		_invariants[name] = entry
		return
	var value: Variant = eval["value"]
	var was_true: bool = bool(entry.get("last_ok", true)) and _is_truthy(entry.get("last_value", null))
	var is_true: bool = _is_truthy(value)
	entry["last_value"] = value
	entry["last_ok"] = true
	entry["last_error"] = ""
	if was_true and not is_true:
		entry["violations"] = int(entry.get("violations", 0)) + 1
		push_error("[invariant '%s'] VIOLATED: %s = %s" % [name, expr_str, _stringify(value)])
	_invariants[name] = entry

#endregion

#region Postcondition tracking

func _ensure_postcondition_hooked() -> void:
	if _postcondition_connected or not _registry:
		return
	if not _registry.has_signal("command_executed"):
		return
	if not _registry.command_executed.is_connected(_on_command_executed):
		_registry.command_executed.connect(_on_command_executed)
	_postcondition_connected = true

func _on_command_executed(command: String, _result: String) -> void:
	if _pending_postcondition.is_empty():
		return
	if _pending_postcondition_skip > 0:
		_pending_postcondition_skip -= 1
		return
	var expr_str := _pending_postcondition
	# Clear before evaluating so a postcondition that itself runs commands
	# (or another log_postcondition) cannot recurse.
	_pending_postcondition = ""
	var eval: Dictionary = _evaluate(expr_str)
	if not bool(eval["ok"]):
		push_error("[postcondition] eval failed after '%s': %s | %s" % [command, expr_str, str(eval["error"])])
		print_rich("[color=%s]postcondition eval failed: %s | %s[/color]" % [_COLOR_ERROR, expr_str, str(eval["error"])])
		return
	var value: Variant = eval["value"]
	if _is_truthy(value):
		print_rich("[color=%s]postcondition ok after '%s': %s = %s[/color]" % [_COLOR_SUCCESS, command, expr_str, _stringify(value)])
	else:
		push_error("[postcondition] FAILED after '%s': %s = %s" % [command, expr_str, _stringify(value)])
		print_rich("[color=%s]postcondition FAILED after '%s': %s = %s[/color]" % [_COLOR_ERROR, command, expr_str, _stringify(value)])

#endregion

#region Evaluation helpers

func _evaluate(expression_text: String) -> Dictionary:
	var expr := Expression.new()
	var parse_err: int = expr.parse(expression_text, [])
	if parse_err != OK:
		return {"ok": false, "error": "parse: " + expr.get_error_text(), "value": null}
	var base: Object = _get_scene_root()
	var value: Variant = expr.execute([], base, false)
	if expr.has_execute_failed():
		return {"ok": false, "error": "execute: " + expr.get_error_text(), "value": null}
	return {"ok": true, "error": "", "value": value}

func _is_truthy(v: Variant) -> bool:
	if v == null:
		return false
	if v is bool:
		return v
	if v is int or v is float:
		return v != 0
	if v is String or v is StringName:
		return not String(v).is_empty()
	if v is Array:
		return not (v as Array).is_empty()
	if v is Dictionary:
		return not (v as Dictionary).is_empty()
	if v is Object:
		return is_instance_valid(v)
	return true

func _compare(a: Variant, op: String, b: Variant) -> Dictionary:
	match op:
		"==": return {"ok": true, "result": a == b}
		"!=": return {"ok": true, "result": a != b}
	# Ordering comparisons require numerically comparable values. GDScript will
	# happily compare strings lexically, so we permit String/StringName here too.
	if not _is_orderable(a) or not _is_orderable(b):
		return {"ok": false, "error": "Operator '%s' requires numeric or string operands" % op, "result": false}
	match op:
		"<": return {"ok": true, "result": a < b}
		">": return {"ok": true, "result": a > b}
		"<=": return {"ok": true, "result": a <= b}
		">=": return {"ok": true, "result": a >= b}
		_: return {"ok": false, "error": "Unknown operator: %s" % op, "result": false}

func _is_compare_op(s: String) -> bool:
	match s.strip_edges():
		"==", "!=", "<", ">", "<=", ">=": return true
		_: return false

func _is_orderable(v: Variant) -> bool:
	return v is int or v is float or v is String or v is StringName

#endregion

#region Type / node helpers

func _node_is_class(node: Node, class_name_arg: String) -> bool:
	if node.is_class(class_name_arg):
		return true
	# Walk the script inheritance chain looking for a matching class_name.
	var script: Script = node.get_script()
	while script != null:
		if script.get_global_name() == StringName(class_name_arg):
			return true
		var path: String = script.resource_path
		if not path.is_empty() and path.get_file().get_basename() == class_name_arg:
			return true
		script = script.get_base_script()
	return false

func _script_global_name(node: Node) -> String:
	var script: Script = node.get_script()
	if script == null:
		return ""
	var gn: StringName = script.get_global_name()
	if String(gn).is_empty():
		return script.resource_path.get_file()
	return String(gn)

func _get_scene_root() -> Node:
	if Engine.is_editor_hint():
		# EditorInterface is only available when the editor module is loaded;
		# guard so the same code runs cleanly in standalone exports.
		if Engine.has_singleton("EditorInterface"):
			var ei: Object = Engine.get_singleton("EditorInterface")
			if ei and ei.has_method("get_edited_scene_root"):
				return ei.call("get_edited_scene_root")
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

#endregion

#region Formatting helpers

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

func _color_muted(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_MUTED, s]

func _join_args(args: Array) -> String:
	var parts: Array[String] = []
	for a in args:
		parts.append(str(a))
	return " ".join(parts).strip_edges()

func _stringify(v: Variant) -> String:
	if v == null:
		return "<null>"
	if v is String:
		return "\"%s\"" % v
	return str(v)

func _format_stack() -> String:
	# get_stack() returns [] in non-debug builds; the empty string is handled
	# by the callers, which simply skip the stack section.
	var frames: Array = get_stack()
	if frames.is_empty():
		return ""
	var lines: Array[String] = []
	lines.append("stack:")
	for f in frames:
		var src: String = str(f.get("source", "?"))
		var fn: String = str(f.get("function", "?"))
		var ln: int = int(f.get("line", 0))
		lines.append("  %s:%d in %s()" % [src, ln, fn])
	return "\n".join(lines)

#endregion

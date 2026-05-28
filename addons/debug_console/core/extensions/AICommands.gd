@tool
class_name DebugConsoleAICommands extends RefCounted

# Tier 7 - lightweight finite-state-machine and behaviour-tree commands.
# Ships separately from BuiltInCommands.gd to keep that file manageable as
# the command surface grows. The orchestrator instantiates one of these,
# holds a strong reference, and calls register_commands(registry, core).
# All commands route through the strong-referenced instance so their
# Callables stay valid for the lifetime of the plugin.
#
# Module state lives on the instance: a dictionary of FSMs and a dictionary
# of behaviour trees keyed by user-supplied name. Conditions are evaluated
# via the Godot Expression API rooted at the current scene, mirroring the
# evaluation strategy used by AssertCommands (assert/invariant/postcondition).
#
# Commands here intentionally avoid touching the file-based test runner,
# the editor-dock plugin glue, or BuiltInCommands.gd; everything they need
# (registry + core) is passed in.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_MUTED := "#888888"

const _BT_SUCCESS := "success"
const _BT_FAILURE := "failure"

var _registry: Node
var _core: Node

# name -> {
#   "initial":     String,
#   "current":     String,
#   "states":      Array[String],
#   "transitions": Array[{ "from": String, "to": String, "expr": String }],
#   "history":     Array[String],        # entries shaped "from->to"
#   "ticks":       int,
# }
var _fsms: Dictionary = {}

# name -> {
#   "root":     String,                  # "sequence" or "selector"
#   "children": Array[String],           # condition expressions evaluated per tick
#   "ticks":    int,
#   "last":     String,                  # last tick status (success/failure/"")
# }
var _bts: Dictionary = {}

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("fsm_new", _cmd_fsm_new, "Create a finite state machine: fsm_new <name> <initial_state>", "both")
	_registry.register_command("fsm_state_add", _cmd_fsm_state_add, "Add a state to an FSM: fsm_state_add <name> <state>", "both")
	_registry.register_command("fsm_transition", _cmd_fsm_transition, "Add a guarded transition: fsm_transition <name> <from> <to> <condition_expr>", "both")
	_registry.register_command("fsm_tick", _cmd_fsm_tick, "Evaluate transitions from the current state and switch on the first truthy guard: fsm_tick <name>", "both")
	_registry.register_command("fsm_dump", _cmd_fsm_dump, "Show FSM current state, states, transitions and history: fsm_dump <name>", "both")
	_registry.register_command("bt_new", _cmd_bt_new, "Create a minimal behaviour tree: bt_new <name> [sequence|selector] [child_expr ...]", "both")
	_registry.register_command("bt_tick", _cmd_bt_tick, "Tick a behaviour tree once and report the root status: bt_tick <name>", "both")

#region Command implementations

func _cmd_fsm_new(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: fsm_new <name> <initial_state>")
	var name := str(args[0]).strip_edges()
	var initial := str(args[1]).strip_edges()
	if name.is_empty():
		return _format_error("FSM name cannot be empty")
	if initial.is_empty():
		return _format_error("Initial state cannot be empty")
	if _fsms.has(name):
		return _format_error("FSM already exists: %s" % name)

	_fsms[name] = {
		"initial": initial,
		"current": initial,
		"states": [initial],
		"transitions": [],
		"history": [],
		"ticks": 0,
	}
	return _format_success("Created FSM %s @ %s" % [_color_path(name), _color_path(initial)])

func _cmd_fsm_state_add(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: fsm_state_add <name> <state>")
	var name := str(args[0]).strip_edges()
	var state := str(args[1]).strip_edges()
	var fsm: Dictionary = _get_fsm(name)
	if fsm.is_empty():
		return _format_error("FSM not found: %s" % name)
	if state.is_empty():
		return _format_error("State cannot be empty")

	var states: Array = fsm["states"]
	if states.has(state):
		return _format_error("State already exists on %s: %s" % [name, state])
	states.append(state)
	return _format_success("Added state %s to FSM %s (%d states)" % [_color_path(state), _color_path(name), states.size()])

func _cmd_fsm_transition(args: Array, piped_input: String = "") -> String:
	if args.size() < 4:
		return _format_error("Usage: fsm_transition <name> <from> <to> <condition_expr>")
	var name := str(args[0]).strip_edges()
	var from_state := str(args[1]).strip_edges()
	var to_state := str(args[2]).strip_edges()
	var expr_str := _join_args(args.slice(3))

	var fsm: Dictionary = _get_fsm(name)
	if fsm.is_empty():
		return _format_error("FSM not found: %s" % name)
	if expr_str.is_empty():
		return _format_error("Condition expression cannot be empty")

	var states: Array = fsm["states"]
	if not states.has(from_state):
		return _format_error("Unknown 'from' state on %s: %s" % [name, from_state])
	if not states.has(to_state):
		return _format_error("Unknown 'to' state on %s: %s" % [name, to_state])

	# Parse the expression now so the user gets immediate feedback rather
	# than discovering syntax errors only at fsm_tick time.
	var probe := Expression.new()
	var parse_err: int = probe.parse(expr_str, [])
	if parse_err != OK:
		return _format_error("Transition expression parse error: %s" % probe.get_error_text())

	var transitions: Array = fsm["transitions"]
	transitions.append({"from": from_state, "to": to_state, "expr": expr_str})
	return _format_success("Added transition %s -> %s when %s" % [_color_path(from_state), _color_path(to_state), expr_str])

func _cmd_fsm_tick(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: fsm_tick <name>")
	var name := str(args[0]).strip_edges()
	var fsm: Dictionary = _get_fsm(name)
	if fsm.is_empty():
		return _format_error("FSM not found: %s" % name)

	fsm["ticks"] = int(fsm["ticks"]) + 1
	var current: String = str(fsm["current"])
	var transitions: Array = fsm["transitions"]

	# First-match-wins ordering preserves registration order, which is the
	# natural way for the user to express priority when writing scripts.
	for t in transitions:
		if str(t["from"]) != current:
			continue
		var eval: Dictionary = _evaluate(str(t["expr"]))
		if not bool(eval["ok"]):
			return _format_error("fsm_tick %s: guard '%s' failed: %s" % [name, str(t["expr"]), str(eval["error"])])
		if _is_truthy(eval["value"]):
			var next_state: String = str(t["to"])
			var history: Array = fsm["history"]
			history.append("%s->%s" % [current, next_state])
			fsm["current"] = next_state
			return _format_success("FSM %s: %s -> %s (guard: %s)" % [_color_path(name), _color_path(current), _color_path(next_state), str(t["expr"])])

	return "%s %s no transition (state=%s, tick=%d)" % [_color_muted("FSM"), _color_path(name), _color_path(current), int(fsm["ticks"])]

func _cmd_fsm_dump(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: fsm_dump <name>")
	var name := str(args[0]).strip_edges()
	var fsm: Dictionary = _get_fsm(name)
	if fsm.is_empty():
		return _format_error("FSM not found: %s" % name)

	var states: Array = fsm["states"]
	var transitions: Array = fsm["transitions"]
	var history: Array = fsm["history"]

	var lines: Array[String] = []
	lines.append("[color=%s]=== FSM %s ===[/color]" % [_COLOR_PATH, name])
	lines.append("current: %s  |  initial: %s  |  ticks: %s" % [_color_path(str(fsm["current"])), str(fsm["initial"]), _color_number(str(fsm["ticks"]))])
	lines.append("states (%d): %s" % [states.size(), ", ".join(_to_string_array(states))])
	if transitions.is_empty():
		lines.append("transitions: (none)")
	else:
		lines.append("transitions (%d):" % transitions.size())
		for t in transitions:
			lines.append("  %s -> %s  when  %s" % [_color_path(str(t["from"])), _color_path(str(t["to"])), str(t["expr"])])
	if history.is_empty():
		lines.append("history: (none)")
	else:
		var preview: Array[String] = []
		var limit: int = mini(history.size(), 16)
		for i in range(limit):
			preview.append(str(history[i]))
		var suffix := "" if history.size() <= limit else "  (+%d more)" % (history.size() - limit)
		lines.append("history (%d): %s%s" % [history.size(), " -> ".join(preview), suffix])
	return "\n".join(lines)

func _cmd_bt_new(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: bt_new <name> [sequence|selector] [child_expr ...]")
	var name := str(args[0]).strip_edges()
	if name.is_empty():
		return _format_error("BT name cannot be empty")
	if _bts.has(name):
		return _format_error("BT already exists: %s" % name)

	var root: String = "sequence"
	var first_child_index: int = 1
	if args.size() > 1:
		var maybe_root := str(args[1]).strip_edges().to_lower()
		if maybe_root == "sequence" or maybe_root == "selector":
			root = maybe_root
			first_child_index = 2

	var children: Array[String] = []
	for i in range(first_child_index, args.size()):
		var child_expr := str(args[i]).strip_edges()
		if child_expr.is_empty():
			continue
		var probe := Expression.new()
		var parse_err: int = probe.parse(child_expr, [])
		if parse_err != OK:
			return _format_error("BT child expression parse error: %s | %s" % [child_expr, probe.get_error_text()])
		children.append(child_expr)

	_bts[name] = {
		"root": root,
		"children": children,
		"ticks": 0,
		"last": "",
	}
	return _format_success("Created BT %s [%s] with %d child(ren)" % [_color_path(name), root, children.size()])

func _cmd_bt_tick(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: bt_tick <name>")
	var name := str(args[0]).strip_edges()
	if not _bts.has(name):
		return _format_error("BT not found: %s" % name)

	var bt: Dictionary = _bts[name]
	bt["ticks"] = int(bt["ticks"]) + 1
	var root: String = str(bt["root"])
	var children: Array = bt["children"]

	# Empty composites: sequence with no children is conventionally SUCCESS,
	# selector with no children is conventionally FAILURE.
	if children.is_empty():
		var empty_status: String = _BT_SUCCESS if root == "sequence" else _BT_FAILURE
		bt["last"] = empty_status
		return "%s %s [%s] -> %s (no children, tick=%d)" % [_color_muted("BT"), _color_path(name), root, _color_status(empty_status), int(bt["ticks"])]

	var trace: Array[String] = []
	var status: String = _BT_SUCCESS if root == "sequence" else _BT_FAILURE
	for i in range(children.size()):
		var child_expr: String = str(children[i])
		var eval: Dictionary = _evaluate(child_expr)
		if not bool(eval["ok"]):
			return _format_error("bt_tick %s: child[%d] '%s' failed: %s" % [name, i, child_expr, str(eval["error"])])
		var child_status: String = _BT_SUCCESS if _is_truthy(eval["value"]) else _BT_FAILURE
		trace.append("%s=%s" % [child_expr, child_status])
		if root == "sequence" and child_status == _BT_FAILURE:
			status = _BT_FAILURE
			break
		if root == "selector" and child_status == _BT_SUCCESS:
			status = _BT_SUCCESS
			break

	bt["last"] = status
	return "%s %s [%s] -> %s  |  %s  |  tick=%d" % [_color_muted("BT"), _color_path(name), root, _color_status(status), " ; ".join(trace), int(bt["ticks"])]

#endregion

#region Helpers

func _get_fsm(name: String) -> Dictionary:
	if not _fsms.has(name):
		return {}
	return _fsms[name]

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

func _join_args(args: Array) -> String:
	var parts: Array[String] = []
	for a in args:
		parts.append(str(a))
	return " ".join(parts).strip_edges()

func _to_string_array(arr: Array) -> Array[String]:
	var out: Array[String] = []
	for v in arr:
		out.append(str(v))
	return out

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

func _color_status(s: String) -> String:
	var color: String = _COLOR_SUCCESS if s == _BT_SUCCESS else _COLOR_ERROR
	return "[color=%s]%s[/color]" % [color, s]

#endregion

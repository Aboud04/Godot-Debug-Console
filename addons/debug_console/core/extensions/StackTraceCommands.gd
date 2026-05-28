@tool
class_name DebugConsoleStackTraceCommands extends RefCounted

# Extension module - GDScript stack-trace inspection commands. Mirrors the
# DebugConsoleSceneCommands / DebugConsoleScriptRunCommands contract: the
# orchestrator instantiates one of these, holds a strong reference, and calls
# register_commands(registry, core). All commands register with the "both"
# context so they work from the editor dock and the in-game overlay.
#
# Note on availability: get_stack() returns frames only when the
# script debugger is connected. In editor and in any debug build with
# Project Settings -> Network/Debug enabled this is the case; in release
# (exported) builds get_stack() returns an empty array. All commands here
# fail soft with a clear message when that happens.
#
# Commands provided:
#   stacktrace      dump get_stack() with optional depth
#   stacktrace_at   arm a one-shot hook that prints the stack the next
#                   time <node_path>.<method> executes (output -> stdout)
#   caller          immediate caller frame (function + file:line)
#   frames          last n script frames, compact
#   where           current frame as file:line in function
#   script_self     dump self of the current script context (this module)
#   print_stack     call Godot's print_stack() and report frame count
#   backtrace       alias for stacktrace

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"

var _registry: Node
var _core: Node
var _hooks: Array[Dictionary] = []

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("stacktrace", _cmd_stacktrace, "Dump the current GDScript stack: stacktrace [depth]", "both")
	_registry.register_command("stacktrace_at", _cmd_stacktrace_at, "Print stack on the next call to a method: stacktrace_at <node_path>.<method>", "both")
	_registry.register_command("caller", _cmd_caller, "Show the immediate caller frame (function + file:line)", "both")
	_registry.register_command("frames", _cmd_frames, "Show the last n script frames: frames [n]", "both")
	_registry.register_command("where", _cmd_where, "Current script frame as file:line in function", "both")
	_registry.register_command("script_self", _cmd_script_self, "Dump self of the current script context", "both")
	_registry.register_command("print_stack", _cmd_print_stack, "One-liner: call Godot's print_stack() and report frame count", "both")
	_registry.register_command("backtrace", _cmd_backtrace, "Alias for stacktrace: backtrace [depth]", "both")

#region Command implementations

func _cmd_stacktrace(args: Array, piped_input: String = "") -> String:
	var stack: Array = get_stack()
	if stack.is_empty():
		return _format_error("Stack unavailable. get_stack() returned empty (requires a debug build with the script debugger active).")
	var depth: int = stack.size()
	if not args.is_empty():
		var d := str(args[0]).strip_edges()
		if d.is_valid_int():
			depth = max(1, d.to_int())
	return _format_stack(stack, depth, "stacktrace")

func _cmd_backtrace(args: Array, piped_input: String = "") -> String:
	return _cmd_stacktrace(args, piped_input)

func _cmd_frames(args: Array, piped_input: String = "") -> String:
	var n: int = 5
	if not args.is_empty():
		var v := str(args[0]).strip_edges()
		if v.is_valid_int():
			n = max(1, v.to_int())
	var stack: Array = get_stack()
	if stack.is_empty():
		return _format_error("Stack unavailable (get_stack() returned empty).")
	return _format_stack(stack, n, "frames (last %s)" % _color_number(str(n)))

func _cmd_where(args: Array, piped_input: String = "") -> String:
	var stack: Array = get_stack()
	if stack.is_empty():
		return _format_error("Stack unavailable (get_stack() returned empty).")
	var f: Dictionary = stack[0]
	return "%s:%s in %s" % [
		_color_path(str(f.get("source", "?"))),
		_color_number(str(f.get("line", 0))),
		str(f.get("function", "?"))
	]

func _cmd_caller(args: Array, piped_input: String = "") -> String:
	var stack: Array = get_stack()
	if stack.size() < 2:
		return _format_error("No caller frame available (stack depth %s)." % _color_number(str(stack.size())))
	var f: Dictionary = stack[1]
	return "caller: %s at %s:%s" % [
		str(f.get("function", "?")),
		_color_path(str(f.get("source", "?"))),
		_color_number(str(f.get("line", 0)))
	]

func _cmd_print_stack(args: Array, piped_input: String = "") -> String:
	var stack: Array = get_stack()
	print_stack()
	return _format_success("print_stack() emitted to stdout (%s frame(s))." % _color_number(str(stack.size())))

func _cmd_script_self(args: Array, piped_input: String = "") -> String:
	var lines: Array[String] = []
	var script: Script = get_script() as Script
	var script_path: String = script.resource_path if script else "<none>"
	lines.append("self: %s" % _color_path(script_path))
	lines.append("  class: %s" % str(get_class()))
	if script:
		var gname: StringName = script.get_global_name()
		if str(gname) != "":
			lines.append("  class_name: %s" % str(gname))
	var registry_label: String = "<null>"
	if _registry:
		registry_label = str(_registry.get_path()) if _registry.is_inside_tree() else str(_registry.name)
	var core_label: String = "<null>"
	if _core:
		core_label = str(_core.get_path()) if _core.is_inside_tree() else str(_core.name)
	lines.append("  registry: %s" % _color_path(registry_label))
	lines.append("  core: %s" % _color_path(core_label))
	lines.append("  active_hooks: %s" % _color_number(str(_hooks.size())))
	var stack: Array = get_stack()
	if not stack.is_empty():
		var top: Dictionary = stack[0]
		lines.append("  invoked_from: %s:%s in %s" % [
			_color_path(str(top.get("source", "?"))),
			_color_number(str(top.get("line", 0))),
			str(top.get("function", "?"))
		])
	return "\n".join(lines)

func _cmd_stacktrace_at(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: stacktrace_at <node_path>.<method>")
	var selector := str(args[0]).strip_edges()
	var split := _split_selector(selector)
	if split.is_empty():
		return _format_error("Selector must be <node_path>.<method>: %s" % selector)
	var node := _resolve_node(split[0])
	if not node:
		return _format_error("Node not found: %s" % split[0])
	var method: String = split[1]
	if not node.has_method(method):
		return _format_error("Method not found on %s: %s" % [node.get_class(), method])
	var script: Script = node.get_script() as Script
	var script_path: String = script.resource_path if script else ""

	var tree: SceneTree = null
	if _core and _core is Node and (_core as Node).is_inside_tree():
		tree = (_core as Node).get_tree()
	if not tree:
		tree = Engine.get_main_loop() as SceneTree
	if not tree:
		return _format_error("No SceneTree available; cannot install hook.")

	var hook: Dictionary = {
		"selector": selector,
		"method": method,
		"script_path": script_path,
		"node_id": node.get_instance_id(),
		"callable": Callable(),
	}
	var cb: Callable = Callable(self, "_poll_stack_hook").bind(hook)
	hook["callable"] = cb
	_hooks.append(hook)
	tree.process_frame.connect(cb)
	var origin_label: String = script_path if script_path != "" else "<no script>"
	return _format_success("Hook armed for %s (script %s). Stack will print to stdout on next call." % [
		_color_path(selector),
		_color_path(origin_label)
	])

func _poll_stack_hook(hook: Dictionary) -> void:
	var stack: Array = get_stack()
	if stack.is_empty():
		return
	var method: String = str(hook.get("method", ""))
	var script_path: String = str(hook.get("script_path", ""))
	var hit: bool = false
	for frame in stack:
		var fd: Dictionary = frame
		if str(fd.get("function", "")) != method:
			continue
		if script_path == "" or str(fd.get("source", "")) == script_path:
			hit = true
			break
	if not hit:
		return
	print("[debug_console] stacktrace_at %s hit (%d frame(s)):" % [str(hook.get("selector", "?")), stack.size()])
	for i in range(stack.size()):
		var f: Dictionary = stack[i]
		print("  #%d %s:%s in %s" % [
			i,
			str(f.get("source", "?")),
			str(f.get("line", 0)),
			str(f.get("function", "?"))
		])
	_disarm_hook(hook)

func _disarm_hook(hook: Dictionary) -> void:
	var cb: Callable = hook.get("callable", Callable())
	var tree: SceneTree = null
	if _core and _core is Node and (_core as Node).is_inside_tree():
		tree = (_core as Node).get_tree()
	if not tree:
		tree = Engine.get_main_loop() as SceneTree
	if tree and cb.is_valid() and tree.process_frame.is_connected(cb):
		tree.process_frame.disconnect(cb)
	_hooks.erase(hook)

#endregion

#region Helpers

func _format_stack(stack: Array, depth: int, header: String) -> String:
	var lines: Array[String] = []
	lines.append("%s [%s frame(s)]:" % [header, _color_number(str(stack.size()))])
	var limit: int = min(depth, stack.size())
	for i in range(limit):
		var f: Dictionary = stack[i]
		lines.append("  %s %s:%s in %s" % [
			_color_number("#%d" % i),
			_color_path(str(f.get("source", "?"))),
			_color_number(str(f.get("line", 0))),
			str(f.get("function", "?"))
		])
	if limit < stack.size():
		lines.append("  ... (%s more)" % _color_number(str(stack.size() - limit)))
	return "\n".join(lines)

func _split_selector(selector: String) -> Array:
	var idx := selector.rfind(".")
	if idx <= 0 or idx >= selector.length() - 1:
		return []
	return [selector.substr(0, idx), selector.substr(idx + 1)]

func _resolve_node(path: String) -> Node:
	var p := path.strip_edges()
	if p.is_empty():
		return null

	if Engine.is_editor_hint():
		var root := EditorInterface.get_edited_scene_root()
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

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

#endregion

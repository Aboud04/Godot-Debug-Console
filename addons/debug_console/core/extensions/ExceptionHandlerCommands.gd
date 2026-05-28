@tool
class_name DebugConsoleExceptionHandlerCommands extends RefCounted

# Tier-extension: defensive wrappers around the core command surface.
# GDScript has no try/catch, so "exception handling" here means pre-validating
# every operation (has_method / is_valid / in / ResourceLoader.exists) and
# returning a clean error string instead of letting the engine push a runtime
# error that aborts the script. Mirrors the registration shape used by
# SceneCommands.gd: the orchestrator instantiates this, keeps a strong
# reference, and calls register_commands(registry, core).

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_WARN := "#F5A742"

var _registry: Node
var _core: Node
var _safe_mode_enabled: bool = false
var _safe_mode_guard: bool = false

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("try_call", _cmd_try_call, "Defensively invoke a method: try_call <path>.<method> [args...] (pre-checks node validity, method existence, arg count)", "both")
	_registry.register_command("try_load", _cmd_try_load, "Defensively load a resource: try_load <res://path> (returns error code instead of crashing on missing file)", "both")
	_registry.register_command("try_get", _cmd_try_get, "Safe property read with default: try_get <path>.<property> [default]", "both")
	_registry.register_command("try_exec", _cmd_try_exec, "Run a console command and catch errors: try_exec <command...>", "both")
	_registry.register_command("safe_mode", _cmd_safe_mode, "Wrap subsequent commands in try_exec: safe_mode <on|off|status>", "both")
	_registry.register_command("retry", _cmd_retry, "Run a command up to N times until it succeeds: retry <count> <command...>", "both")

	if _registry.has_signal("command_executed") and not _registry.is_connected("command_executed", _on_command_executed):
		_registry.connect("command_executed", _on_command_executed)

# Public accessor so a future dispatcher hook can decide whether to wrap input.
func is_safe_mode() -> bool:
	return _safe_mode_enabled

#region Command implementations

func _cmd_try_call(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: try_call <path>.<method> [args...]")
	var selector := str(args[0]).strip_edges()
	var split := _split_selector(selector)
	if split.is_empty():
		return _format_error("Selector must be <path>.<method>: %s" % selector)

	var node := _resolve_node(split[0])
	if not is_instance_valid(node):
		return _format_error("Node not found or invalid: %s" % split[0])
	var method: String = split[1]
	if not node.has_method(method):
		return _format_error("Method not found: %s on %s (defended; no call made)" % [method, node.get_class()])

	var call_args: Array = []
	for i in range(1, args.size()):
		call_args.append(_parse_value(str(args[i])))

	var bounds: Array = _arg_bounds(node, method)
	if bounds.size() == 2:
		var min_n: int = bounds[0]
		var max_n: int = bounds[1]
		if call_args.size() < min_n or call_args.size() > max_n:
			return _format_error("Arg count out of range on %s: expected %d..%d, got %d (defended; no call made)" % [method, min_n, max_n, call_args.size()])

	var result: Variant = node.callv(method, call_args)
	if not is_instance_valid(node):
		return _format_error("Node became invalid during call: %s" % split[0])
	return "%s = %s" % [_color_path("%s.%s" % [split[0], method]), str(result) if result != null else "<null>"]

func _cmd_try_load(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: try_load <res://path>")
	var path := str(args[0]).strip_edges()
	if path.is_empty():
		return _format_error("Path is empty")
	if not ResourceLoader.exists(path):
		return _format_error("Resource not found (err=%d ERR_FILE_NOT_FOUND): %s" % [ERR_FILE_NOT_FOUND, path])
	var res: Resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REUSE)
	if res == null:
		return _format_error("Load failed (err=%d ERR_CANT_OPEN): %s" % [ERR_CANT_OPEN, path])
	var type_str: String = res.get_class()
	if res.resource_path != "":
		return _format_success("Loaded %s [%s]" % [_color_path(path), type_str])
	return _format_success("Loaded %s [%s] (no resource_path)" % [_color_path(path), type_str])

func _cmd_try_get(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: try_get <path>.<property> [default]")
	var selector := str(args[0]).strip_edges()
	var split := _split_selector(selector)
	if split.is_empty():
		return _format_error("Selector must be <path>.<property>: %s" % selector)
	var default_value: Variant = _parse_value(str(args[1])) if args.size() > 1 else null

	var node := _resolve_node(split[0])
	if not is_instance_valid(node):
		var fallback_str: String = str(default_value) if default_value != null else "<null>"
		return "%s = %s [color=%s](default: node invalid)[/color]" % [_color_path(selector), fallback_str, _COLOR_WARN]
	var prop: String = split[1]

	if not _has_property(node, prop):
		var fallback_str_2: String = str(default_value) if default_value != null else "<null>"
		return "%s = %s [color=%s](default: property missing on %s)[/color]" % [_color_path(selector), fallback_str_2, _COLOR_WARN, node.get_class()]

	var value: Variant = node.get(prop)
	if value == null and default_value != null:
		return "%s = %s [color=%s](default: value was null)[/color]" % [_color_path(selector), str(default_value), _COLOR_WARN]
	return "%s = %s" % [_color_path(selector), str(value) if value != null else "<null>"]

func _cmd_try_exec(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: try_exec <command...>")
	var inner: String = _join_command(args)
	if inner.is_empty():
		return _format_error("Empty inner command")
	if not _registry or not _registry.has_method("execute_command"):
		return _format_error("Registry unavailable")

	# Re-entrancy guard: prevent safe_mode signal handler from re-wrapping us.
	var prev_guard: bool = _safe_mode_guard
	_safe_mode_guard = true
	var result_variant: Variant = _registry.call("execute_command", inner)
	_safe_mode_guard = prev_guard

	var result_str: String = str(result_variant) if result_variant != null else ""
	if _looks_like_error(result_str):
		return "[color=%s]try_exec caught:[/color] %s" % [_COLOR_WARN, result_str]
	return result_str

func _cmd_safe_mode(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: safe_mode <on|off|status>")
	var mode: String = str(args[0]).strip_edges().to_lower()
	match mode:
		"on", "true", "1":
			_safe_mode_enabled = true
			return _format_success("safe_mode ON  (errors from subsequent commands will be flagged; for pre-execution wrapping use 'try_exec <cmd>' explicitly or have the dispatcher call is_safe_mode())")
		"off", "false", "0":
			_safe_mode_enabled = false
			return _format_success("safe_mode OFF")
		"status":
			return "safe_mode = %s" % ("ON" if _safe_mode_enabled else "OFF")
		_:
			return _format_error("Unknown safe_mode argument: %s (use on|off|status)" % mode)

func _cmd_retry(args: Array, _piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: retry <count> <command...>")
	var count_str := str(args[0]).strip_edges()
	if not count_str.is_valid_int():
		return _format_error("First argument must be an integer count: %s" % count_str)
	var count: int = count_str.to_int()
	if count <= 0:
		return _format_error("Count must be >= 1, got %d" % count)
	if count > 1000:
		return _format_error("Count too large (max 1000): %d" % count)

	var inner: String = _join_command(args.slice(1))
	if inner.is_empty():
		return _format_error("Empty command to retry")
	if not _registry or not _registry.has_method("execute_command"):
		return _format_error("Registry unavailable")

	var attempts: Array[String] = []
	var prev_guard: bool = _safe_mode_guard
	_safe_mode_guard = true
	for i in range(count):
		var raw: Variant = _registry.call("execute_command", inner)
		var result_str: String = str(raw) if raw != null else ""
		if not _looks_like_error(result_str):
			_safe_mode_guard = prev_guard
			return "%s attempt %d/%d succeeded:\n%s" % [_format_success("retry"), i + 1, count, result_str]
		attempts.append("  [%d] %s" % [i + 1, result_str])
	_safe_mode_guard = prev_guard
	var trail: String = "\n".join(attempts) if attempts.size() <= 5 else "\n".join(attempts.slice(attempts.size() - 5)) + "\n  ... (showing last 5)"
	return _format_error("retry exhausted after %d attempts:\n%s" % [count, trail])

#endregion

#region Signal hook for safe_mode flagging

func _on_command_executed(command: String, result: String) -> void:
	if not _safe_mode_enabled:
		return
	if _safe_mode_guard:
		return
	var trimmed := command.strip_edges()
	# Avoid flagging our own wrappers and the toggle itself.
	if trimmed.begins_with("try_exec") or trimmed.begins_with("retry") or trimmed.begins_with("safe_mode") or trimmed.begins_with("try_call") or trimmed.begins_with("try_load") or trimmed.begins_with("try_get"):
		return
	if _looks_like_error(result):
		push_warning("[safe_mode] '%s' produced an error: %s" % [trimmed, result])

#endregion

#region Helpers

func _has_property(obj: Object, prop: String) -> bool:
	if obj == null:
		return false
	for entry in obj.get_property_list():
		if str(entry.get("name", "")) == prop:
			return true
	return false

func _arg_bounds(obj: Object, method: String) -> Array:
	if obj == null:
		return []
	for m in obj.get_method_list():
		if str(m.get("name", "")) == method:
			var total: int = (m.get("args", []) as Array).size()
			var defaults: int = (m.get("default_args", []) as Array).size()
			var min_n: int = max(0, total - defaults)
			# Variadic methods report flag bit 32 (METHOD_FLAG_VARARG).
			var flags: int = int(m.get("flags", 0))
			var is_vararg: bool = (flags & METHOD_FLAG_VARARG) != 0
			var max_n: int = 1_000_000 if is_vararg else total
			return [min_n, max_n]
	return []

func _looks_like_error(result: String) -> bool:
	if result.is_empty():
		return false
	if result.contains("Error:"):
		return true
	if result.begins_with("Unknown command:"):
		return true
	if result.begins_with("Command '"):
		return true
	return false

func _join_command(parts: Array) -> String:
	var pieces: Array[String] = []
	for p in parts:
		pieces.append(str(p))
	return " ".join(pieces).strip_edges()

func _resolve_node(path: String) -> Node:
	var p := path.strip_edges()
	if p.is_empty():
		return null

	if Engine.is_editor_hint():
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

	var tree := Engine.get_main_loop() as SceneTree
	if not tree:
		return null
	if p.begins_with("/"):
		return tree.root.get_node_or_null(p)
	var scene: Node = tree.current_scene if tree.current_scene else tree.root
	return scene.get_node_or_null(p) if scene else null

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

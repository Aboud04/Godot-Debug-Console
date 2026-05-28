@tool
class_name DebugConsolePersistentReplCommands extends RefCounted

# Extension module - session-scoped REPL variables for the debug console.
# The built-in `eval` command spins up a fresh Expression every call which
# means there is no carry-over between successive evals. This module owns a
# dict (`_vars`) that survives across calls; `evalp` injects those variables
# into the Expression's input names array so they can be referenced by name.
#
# Follows the same registration contract as SceneCommands.gd: the orchestrator
# instantiates this once, holds a strong reference, and calls
# register_commands(registry, core). All Callables therefore stay valid for
# the lifetime of the plugin.

const _COLOR_ERROR := "#FF4444"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NAME := "#5FBEE0"
const _COLOR_TYPE := "#C792EA"
const _COLOR_VALUE := "#F7DC6F"

var _registry: Node
var _core: Node
var _vars: Dictionary = {}

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("let", _cmd_let, "Bind a session variable: let <name> = <expr>", "both")
	_registry.register_command("var_set", _cmd_var_set, "Alias for let: var_set <name> <expr>", "both")
	_registry.register_command("unlet", _cmd_unlet, "Remove a session variable: unlet <name>", "both")
	_registry.register_command("vars", _cmd_vars, "List all session variables with types and values", "both")
	_registry.register_command("var_get", _cmd_var_get, "Read a session variable: var_get <name>", "both")
	_registry.register_command("var_save", _cmd_var_save, "Persist session vars to JSON: var_save <user://path.json>", "both")
	_registry.register_command("var_load", _cmd_var_load, "Restore session vars from JSON: var_load <user://path.json>", "both")
	_registry.register_command("evalp", _cmd_evalp, "Eval an expression with session vars in scope: evalp <expr>", "both")

#region Command implementations

func _cmd_let(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: let <name> = <expr>")
	var joined: String = " ".join(args).strip_edges()
	var eq_index: int = joined.find("=")
	if eq_index <= 0:
		return _format_error("Usage: let <name> = <expr>")
	var name_part: String = joined.substr(0, eq_index).strip_edges()
	var expr_part: String = joined.substr(eq_index + 1).strip_edges()
	if name_part.is_empty() or expr_part.is_empty():
		return _format_error("Usage: let <name> = <expr>")
	if not _is_valid_identifier(name_part):
		return _format_error("Invalid identifier: %s" % name_part)
	return _bind_variable(name_part, expr_part)

func _cmd_var_set(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: var_set <name> <expr>")
	var name_part: String = str(args[0]).strip_edges()
	var rest: Array = args.slice(1)
	var expr_part: String = " ".join(rest).strip_edges()
	# Tolerate "var_set name = expr" too: strip a leading '=' if present.
	if expr_part.begins_with("="):
		expr_part = expr_part.substr(1).strip_edges()
	if name_part.is_empty() or expr_part.is_empty():
		return _format_error("Usage: var_set <name> <expr>")
	if not _is_valid_identifier(name_part):
		return _format_error("Invalid identifier: %s" % name_part)
	return _bind_variable(name_part, expr_part)

func _cmd_unlet(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: unlet <name>")
	var name_part: String = str(args[0]).strip_edges()
	if not _vars.has(name_part):
		return _format_error("No such variable: %s" % name_part)
	_vars.erase(name_part)
	return _format_success("Unset %s" % _color_name(name_part))

func _cmd_vars(args: Array, piped_input: String = "") -> String:
	if _vars.is_empty():
		return "(no session variables)"
	var keys: Array = _vars.keys()
	keys.sort()
	var lines: Array[String] = []
	for k in keys:
		var value: Variant = _vars[k]
		lines.append("%s : %s = %s" % [
			_color_name(str(k)),
			_color_type(_type_name(value)),
			_color_value(_format_value(value)),
		])
	return "\n".join(lines)

func _cmd_var_get(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: var_get <name>")
	var name_part: String = str(args[0]).strip_edges()
	if not _vars.has(name_part):
		return _format_error("No such variable: %s" % name_part)
	var value: Variant = _vars[name_part]
	return "%s : %s = %s" % [
		_color_name(name_part),
		_color_type(_type_name(value)),
		_color_value(_format_value(value)),
	]

func _cmd_var_save(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: var_save <user://path.json>")
	var path: String = str(args[0]).strip_edges()
	var serializable: Dictionary = {}
	for k in _vars.keys():
		serializable[str(k)] = _to_serializable(_vars[k])
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return _format_error("Could not open for write: %s (err %d)" % [path, FileAccess.get_open_error()])
	file.store_string(JSON.stringify(serializable, "\t"))
	file.close()
	return _format_success("Saved %d var(s) to %s" % [_vars.size(), path])

func _cmd_var_load(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: var_load <user://path.json>")
	var path: String = str(args[0]).strip_edges()
	if not FileAccess.file_exists(path):
		return _format_error("File not found: %s" % path)
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return _format_error("Could not open for read: %s (err %d)" % [path, FileAccess.get_open_error()])
	var text: String = file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return _format_error("JSON root is not an object in: %s" % path)
	_vars.clear()
	var loaded: Dictionary = parsed
	for k in loaded.keys():
		_vars[str(k)] = loaded[k]
	return _format_success("Loaded %d var(s) from %s" % [_vars.size(), path])

func _cmd_evalp(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: evalp <expr>")
	var expr_text: String = " ".join(args).strip_edges()
	return _eval_with_vars(expr_text, true)

#endregion

#region Internals

func _bind_variable(var_name: String, expr_text: String) -> String:
	# Evaluate the RHS with the current vars in scope so `let y = x + 1`
	# works after `let x = 5`.
	var names: PackedStringArray = PackedStringArray()
	var values: Array = []
	for k in _vars.keys():
		names.append(str(k))
		values.append(_vars[k])
	var expr := Expression.new()
	var parse_err: int = expr.parse(expr_text, names)
	if parse_err != OK:
		return _format_error("Parse error: %s" % expr.get_error_text())
	var result: Variant = expr.execute(values, null, true)
	if expr.has_execute_failed():
		return _format_error("Execute error: %s" % expr.get_error_text())
	_vars[var_name] = result
	return _format_success("%s : %s = %s" % [
		_color_name(var_name),
		_color_type(_type_name(result)),
		_color_value(_format_value(result)),
	])

func _eval_with_vars(expr_text: String, show_value: bool) -> String:
	var names: PackedStringArray = PackedStringArray()
	var values: Array = []
	for k in _vars.keys():
		names.append(str(k))
		values.append(_vars[k])
	var expr := Expression.new()
	var parse_err: int = expr.parse(expr_text, names)
	if parse_err != OK:
		return _format_error("Parse error: %s" % expr.get_error_text())
	var result: Variant = expr.execute(values, null, true)
	if expr.has_execute_failed():
		return _format_error("Execute error: %s" % expr.get_error_text())
	if not show_value:
		return ""
	return "%s = %s" % [_color_type(_type_name(result)), _color_value(_format_value(result))]

func _is_valid_identifier(s: String) -> bool:
	if s.is_empty():
		return false
	var first: String = s.substr(0, 1)
	if not (first == "_" or _is_alpha(first)):
		return false
	for i in range(1, s.length()):
		var ch: String = s.substr(i, 1)
		if not (ch == "_" or _is_alpha(ch) or _is_digit(ch)):
			return false
	return true

func _is_alpha(ch: String) -> bool:
	return (ch >= "a" and ch <= "z") or (ch >= "A" and ch <= "Z")

func _is_digit(ch: String) -> bool:
	return ch >= "0" and ch <= "9"

func _type_name(value: Variant) -> String:
	match typeof(value):
		TYPE_NIL: return "null"
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
		TYPE_ARRAY: return "Array"
		TYPE_DICTIONARY: return "Dictionary"
		TYPE_OBJECT:
			if value is Object and (value as Object) != null:
				return (value as Object).get_class()
			return "Object"
		_: return "Variant"

func _format_value(value: Variant) -> String:
	var s: String = str(value)
	if s.length() > 200:
		s = s.substr(0, 197) + "..."
	return s

func _to_serializable(value: Variant) -> Variant:
	# JSON can natively encode null/bool/int/float/String/Array/Dictionary.
	# Anything else is round-tripped through str() so the file is human-readable
	# even if it can't be perfectly reconstructed by var_load.
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING:
			return value
		TYPE_ARRAY:
			var out_arr: Array = []
			for item in (value as Array):
				out_arr.append(_to_serializable(item))
			return out_arr
		TYPE_DICTIONARY:
			var out_dict: Dictionary = {}
			for k in (value as Dictionary).keys():
				out_dict[str(k)] = _to_serializable((value as Dictionary)[k])
			return out_dict
		_:
			return str(value)

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_name(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NAME, s]

func _color_type(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_TYPE, s]

func _color_value(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_VALUE, s]

#endregion

@tool
class_name DebugConsoleAliasArgsCommands extends RefCounted

# Parametric aliases extension. Mirrors the structure of the other extensions
# under addons/debug_console/core/extensions/: the orchestrator instantiates
# one of these, holds a strong reference to it, and calls
# register_commands(registry, core). All commands route through the
# strong-referenced instance so the bound Callables stay valid for the lifetime
# of the plugin.
#
# Unlike BuiltInCommands' static `alias` (text expansion only), this module
# supports positional argument substitution in the template:
#   $1, $2, ...  -> the Nth positional arg (1-indexed)
#   $*           -> all args joined with a single space
#   $@           -> all args quoted individually and joined with a space
#                   (useful when forwarding to a command that re-tokenizes)
# When an alias is executed, the callable substitutes the placeholders against
# the args it received and routes the expanded command string through
# _registry.execute_command(expanded).

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_MUTED := "#888888"

const PARAMETRIC_ALIAS_CONFIG_PATH := "user://parametric_aliases.cfg"
const PARAMETRIC_ALIAS_CONFIG_SECTION := "parametric_aliases"

var _registry: Node
var _core: Node

# name -> template (String). Lower-cased keys.
var _palaiases: Dictionary = {}
# Names of dynamically registered alias commands (so we can unregister cleanly).
var _registered_alias_names: Array[String] = []
# Recursion guard so an alias that expands into a command which dispatches to
# itself does not blow the stack.
var _active_alias_calls: Array[String] = []

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return

	_registry.register_command("aliasp", _cmd_aliasp, "Define a parametric alias: aliasp <name> <template> (use $1,$2,$*,$@)", "both")
	_registry.register_command("aliasp_list", _cmd_aliasp_list, "List parametric aliases", "both")
	_registry.register_command("aliasp_remove", _cmd_aliasp_remove, "Remove a parametric alias: aliasp_remove <name>", "both")
	_registry.register_command("aliasp_expand", _cmd_aliasp_expand, "Preview alias expansion without executing: aliasp_expand <name> [args...]", "both")
	_registry.register_command("aliasp_save", _cmd_aliasp_save, "Save parametric aliases to user://parametric_aliases.cfg", "both")
	_registry.register_command("aliasp_load", _cmd_aliasp_load, "Load parametric aliases from user://parametric_aliases.cfg", "both")

	_load_aliases_from_config()
	_register_alias_commands()

#region Command implementations

func _cmd_aliasp(args: Array, _piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: aliasp <name> <template>  (use $1,$2,$*,$@)")
	var alias_name := str(args[0]).strip_edges().to_lower()
	if alias_name.is_empty() or alias_name.contains(" ") or alias_name.contains("|"):
		return _format_error("Invalid alias name: %s" % alias_name)
	if _is_reserved_name(alias_name):
		return _format_error("Reserved alias name: %s" % alias_name)
	if not _registry:
		return _format_error("CommandRegistry is unavailable")
	if _registry._commands.has(alias_name) and not _palaiases.has(alias_name):
		return _format_error("Command already exists: %s" % alias_name)

	var template_parts: Array = []
	for i in range(1, args.size()):
		template_parts.append(str(args[i]))
	var template := " ".join(template_parts).strip_edges()
	if template.is_empty():
		return _format_error("Template cannot be empty")
	if template == alias_name or template.begins_with(alias_name + " "):
		return _format_error("Alias template cannot start with its own name")

	_palaiases[alias_name] = template
	_register_single_alias_command(alias_name)
	return _format_success("Parametric alias set: %s='%s'" % [alias_name, template])

func _cmd_aliasp_list(_args: Array, _piped_input: String = "") -> String:
	if _palaiases.is_empty():
		return "No parametric aliases configured"
	var keys := _palaiases.keys()
	keys.sort()
	var lines: Array[String] = ["Parametric aliases (%s):" % _color_number(str(keys.size()))]
	for key in keys:
		lines.append("  %s='%s'" % [_color_path(str(key)), str(_palaiases[key])])
	return "\n".join(lines)

func _cmd_aliasp_remove(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: aliasp_remove <name>")
	var alias_name := str(args[0]).strip_edges().to_lower()
	if not _palaiases.has(alias_name):
		return _format_error("Parametric alias not found: %s" % alias_name)
	_palaiases.erase(alias_name)
	_unregister_single_alias_command(alias_name)
	return _format_success("Parametric alias removed: %s" % alias_name)

func _cmd_aliasp_expand(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: aliasp_expand <name> [args...]")
	var alias_name := str(args[0]).strip_edges().to_lower()
	if not _palaiases.has(alias_name):
		return _format_error("Parametric alias not found: %s" % alias_name)
	var rest: Array = args.slice(1, args.size())
	var template := str(_palaiases.get(alias_name, ""))
	var expanded := _expand_template(template, rest)
	return "%s -> %s" % [_color_path(alias_name), expanded]

func _cmd_aliasp_save(_args: Array, _piped_input: String = "") -> String:
	var err := _save_aliases_to_config()
	if err != OK:
		return _format_error("Failed to save (%d): %s" % [err, PARAMETRIC_ALIAS_CONFIG_PATH])
	return _format_success("Saved %s alias(es) to %s" % [_color_number(str(_palaiases.size())), _color_path(PARAMETRIC_ALIAS_CONFIG_PATH)])

func _cmd_aliasp_load(_args: Array, _piped_input: String = "") -> String:
	var loaded := _load_aliases_from_config()
	if loaded < 0:
		return _format_error("Failed to load: %s" % PARAMETRIC_ALIAS_CONFIG_PATH)
	_register_alias_commands()
	return _format_success("Loaded %s alias(es) from %s" % [_color_number(str(loaded)), _color_path(PARAMETRIC_ALIAS_CONFIG_PATH)])

#endregion

#region Alias execution

func _execute_alias(args: Array, alias_name: String) -> String:
	if not _registry:
		return _format_error("CommandRegistry is unavailable")
	if not _palaiases.has(alias_name):
		return _format_error("Parametric alias not found: %s" % alias_name)
	if _active_alias_calls.has(alias_name):
		return _format_error("Alias recursion detected: %s" % alias_name)

	_active_alias_calls.append(alias_name)
	var template := str(_palaiases.get(alias_name, ""))
	var expanded := _expand_template(template, args)
	var result: String = _registry.execute_command(expanded)
	_active_alias_calls.erase(alias_name)
	return result

# Substitute $1..$9, ${N}, $*, $@ placeholders in the template against args.
# - $N (1-indexed) is replaced with the Nth arg, or "" if missing.
# - ${N} works the same and lets you write $12 etc. without ambiguity.
# - $* is all args joined with " " (raw, no quoting).
# - $@ is all args wrapped in double quotes (internal " escaped) and joined
#   with " " - the right choice when the receiving command tokenizes again.
# - $$ is a literal "$" so templates can produce a "$" if needed.
func _expand_template(template: String, args: Array) -> String:
	if template.is_empty():
		return ""
	var out := ""
	var i := 0
	var n := template.length()
	while i < n:
		var ch := template[i]
		if ch != "$":
			out += ch
			i += 1
			continue

		# Lone "$" at end of string -> emit literally.
		if i + 1 >= n:
			out += "$"
			i += 1
			continue

		var next_ch := template[i + 1]
		if next_ch == "$":
			out += "$"
			i += 2
		elif next_ch == "*":
			out += _join_args_raw(args)
			i += 2
		elif next_ch == "@":
			out += _join_args_quoted(args)
			i += 2
		elif next_ch == "{":
			var close_idx := template.find("}", i + 2)
			if close_idx < 0:
				# Malformed - emit raw and advance one char so we don't loop.
				out += ch
				i += 1
				continue
			var num_str := template.substr(i + 2, close_idx - (i + 2)).strip_edges()
			if num_str.is_valid_int():
				out += _arg_at(args, int(num_str))
			else:
				out += template.substr(i, close_idx - i + 1)
			i = close_idx + 1
		elif _is_ascii_digit(next_ch):
			# Greedy digit run so $12 reads as arg 12, not arg 1 + "2".
			var j := i + 1
			while j < n and _is_ascii_digit(template[j]):
				j += 1
			var idx_str := template.substr(i + 1, j - (i + 1))
			out += _arg_at(args, int(idx_str))
			i = j
		else:
			# Unknown sequence - emit "$" literally and continue scanning.
			out += "$"
			i += 1
	return out

func _arg_at(args: Array, one_based_index: int) -> String:
	if one_based_index <= 0:
		return ""
	var idx := one_based_index - 1
	if idx >= args.size():
		return ""
	return str(args[idx])

func _join_args_raw(args: Array) -> String:
	var parts: Array[String] = []
	for a in args:
		parts.append(str(a))
	return " ".join(parts)

func _join_args_quoted(args: Array) -> String:
	var parts: Array[String] = []
	for a in args:
		var s := str(a)
		parts.append("\"%s\"" % s.replace("\"", "\\\""))
	return " ".join(parts)

func _is_ascii_digit(ch: String) -> bool:
	return ch.length() == 1 and ch >= "0" and ch <= "9"

#endregion

#region Registration

func _register_alias_commands() -> void:
	if not _registry:
		return
	for alias_name in _registered_alias_names.duplicate():
		_registry.unregister_command(alias_name)
	_registered_alias_names.clear()
	for alias_name_variant in _palaiases.keys():
		_register_single_alias_command(str(alias_name_variant))

func _register_single_alias_command(alias_name: String) -> void:
	if not _registry or alias_name.is_empty():
		return
	# Do not let parametric aliases override built-in commands, except updating
	# existing alias entries we already own.
	if _registry._commands.has(alias_name) and not _registered_alias_names.has(alias_name):
		return
	var callable := Callable(self, "_execute_alias").bind(alias_name)
	_registry.register_command(alias_name, callable, "Parametric alias for: %s" % str(_palaiases.get(alias_name, "")), "both")
	if not _registered_alias_names.has(alias_name):
		_registered_alias_names.append(alias_name)

func _unregister_single_alias_command(alias_name: String) -> void:
	if not _registry:
		return
	_registry.unregister_command(alias_name)
	_registered_alias_names.erase(alias_name)

func _is_reserved_name(alias_name: String) -> bool:
	match alias_name:
		"aliasp", "aliasp_list", "aliasp_remove", "aliasp_expand", "aliasp_save", "aliasp_load", "alias", "unalias":
			return true
		_:
			return false

#endregion

#region Persistence

# Returns OK on success, an error code on failure.
func _save_aliases_to_config() -> int:
	var config := ConfigFile.new()
	for alias_name_variant in _palaiases.keys():
		var alias_name := str(alias_name_variant)
		config.set_value(PARAMETRIC_ALIAS_CONFIG_SECTION, alias_name, str(_palaiases[alias_name]))
	return config.save(PARAMETRIC_ALIAS_CONFIG_PATH)

# Returns the number of aliases loaded, or -1 on failure.
func _load_aliases_from_config() -> int:
	_palaiases.clear()
	var config := ConfigFile.new()
	var err := config.load(PARAMETRIC_ALIAS_CONFIG_PATH)
	if err != OK:
		# Missing file is not an error - just nothing to load yet.
		if err == ERR_FILE_NOT_FOUND:
			return 0
		return -1
	if not config.has_section(PARAMETRIC_ALIAS_CONFIG_SECTION):
		return 0
	var count := 0
	for key in config.get_section_keys(PARAMETRIC_ALIAS_CONFIG_SECTION):
		var alias_name := str(key).to_lower()
		var template := str(config.get_value(PARAMETRIC_ALIAS_CONFIG_SECTION, key, "")).strip_edges()
		if alias_name.is_empty() or template.is_empty():
			continue
		_palaiases[alias_name] = template
		count += 1
	return count

#endregion

#region Formatting helpers

func _format_error(msg: String) -> String:
	return "[color=%s]Error:[/color] %s" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(text: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, text]

func _color_number(text: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, text]

#endregion

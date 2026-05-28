@tool
class_name DebugConsoleSettingsCommands extends RefCounted

# Tier 7 - ProjectSettings inspection plus per-user ConfigFile persistence.
# Lives in the auto-loaded extensions/ directory so
# BuiltInCommands.register_universal_commands picks it up via the extensions
# loader on plugin enable. Module is held alive by the static keepalive array
# on BuiltInCommands; no edits to that file are required to add it.
#
# Important: `setting_set` mutates ProjectSettings in-memory only. The Godot
# runtime cannot write back to project.godot from a shipped game (the file
# may not exist on disk in an exported build), so per-user persistence is
# handled separately through the setting_user_* family backed by ConfigFile
# at user://settings.cfg. All commands route through this strong-referenced
# instance so their Callables stay valid for the lifetime of the plugin.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_INFO := "#C8C8C8"

const _USER_CFG_PATH := "user://settings.cfg"
const _USER_CFG_SECTION := "settings"
const _MAX_LIST_RESULTS := 500

var _registry: Node
var _core: Node

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("setting_get", _cmd_setting_get, "Read a ProjectSettings key: setting_get <key>", "both")
	_registry.register_command("setting_set", _cmd_setting_set, "Set a ProjectSettings key in-memory (not persisted to project.godot): setting_set <key> <value>", "both")
	_registry.register_command("setting_list", _cmd_setting_list, "List ProjectSettings keys, optionally filtered by prefix: setting_list [prefix]", "both")
	_registry.register_command("setting_user_save", _cmd_setting_user_save, "Persist a value to user://settings.cfg: setting_user_save <key> <value>", "both")
	_registry.register_command("setting_user_get", _cmd_setting_user_get, "Read a value from user://settings.cfg: setting_user_get <key>", "both")
	_registry.register_command("setting_user_clear", _cmd_setting_user_clear, "Erase user://settings.cfg: setting_user_clear", "both")
	_registry.register_command("setting_search", _cmd_setting_search, "Regex-search ProjectSettings keys: setting_search <pattern>", "both")
	_registry.register_command("setting_dump", _cmd_setting_dump, "Pretty-print a ConfigFile on disk: setting_dump <user://path.cfg>", "both")

#region Command implementations

func _cmd_setting_get(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: setting_get <key>")
	var key := str(args[0]).strip_edges()
	if key.is_empty():
		return _format_error("Usage: setting_get <key>")
	if not ProjectSettings.has_setting(key):
		return _format_error("ProjectSettings has no key: %s" % key)
	var value: Variant = ProjectSettings.get_setting(key)
	return "%s = %s %s" % [_color_path(key), _format_value(value), _color_info("(%s)" % _type_name(typeof(value)))]

func _cmd_setting_set(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: setting_set <key> <value>")
	var key := str(args[0]).strip_edges()
	if key.is_empty():
		return _format_error("Usage: setting_set <key> <value>")
	var raw_value := _join_remaining(args, 1)
	var new_value: Variant = _parse_value(raw_value)

	var existed: bool = ProjectSettings.has_setting(key)
	var previous: Variant = ProjectSettings.get_setting(key) if existed else null
	ProjectSettings.set_setting(key, new_value)

	var lines := PackedStringArray()
	lines.append(_format_success("Set %s in-memory" % _color_path(key)))
	if existed:
		lines.append("  was: %s" % _format_value(previous))
	else:
		lines.append("  was: %s" % _color_info("<unset>"))
	lines.append("  now: %s %s" % [_format_value(new_value), _color_info("(%s)" % _type_name(typeof(new_value)))])
	lines.append(_color_info("note: ProjectSettings.set_setting() does not persist to project.godot at runtime; use setting_user_save for per-user storage."))
	return "\n".join(lines)

func _cmd_setting_list(args: Array, piped_input: String = "") -> String:
	var prefix := ""
	if not args.is_empty():
		prefix = str(args[0]).strip_edges()

	var matches: Array[String] = []
	for entry in ProjectSettings.get_property_list():
		var key: String = str(entry.get("name", ""))
		if key.is_empty():
			continue
		if not prefix.is_empty() and not key.begins_with(prefix):
			continue
		matches.append(key)
	matches.sort()

	if matches.is_empty():
		if prefix.is_empty():
			return _format_error("ProjectSettings exposed no keys via get_property_list()")
		return _format_error("No ProjectSettings keys match prefix: %s" % prefix)

	var truncated: bool = matches.size() > _MAX_LIST_RESULTS
	var shown: Array[String] = matches if not truncated else matches.slice(0, _MAX_LIST_RESULTS)

	var lines := PackedStringArray()
	var header_label: String = "all keys" if prefix.is_empty() else ("prefix=%s" % prefix)
	lines.append(_format_success("ProjectSettings %s (%s match)" % [header_label, _color_number(str(matches.size()))]))
	for key in shown:
		lines.append("  %s" % _color_path(key))
	if truncated:
		lines.append(_color_info("  ... (%d more, truncated at %d)" % [matches.size() - _MAX_LIST_RESULTS, _MAX_LIST_RESULTS]))
	return "\n".join(lines)

func _cmd_setting_user_save(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: setting_user_save <key> <value>")
	var key := str(args[0]).strip_edges()
	if key.is_empty():
		return _format_error("Usage: setting_user_save <key> <value>")
	var raw_value := _join_remaining(args, 1)
	var new_value: Variant = _parse_value(raw_value)

	var cfg := ConfigFile.new()
	var load_err: int = cfg.load(_USER_CFG_PATH)
	if load_err != OK and load_err != ERR_FILE_NOT_FOUND:
		return _format_error("Failed to read %s (err=%d)" % [_USER_CFG_PATH, load_err])

	cfg.set_value(_USER_CFG_SECTION, key, new_value)
	var save_err: int = cfg.save(_USER_CFG_PATH)
	if save_err != OK:
		return _format_error("Failed to write %s (err=%d)" % [_USER_CFG_PATH, save_err])

	return "%s\n  %s = %s %s\n  %s" % [
		_format_success("Saved to %s" % _color_path(_USER_CFG_PATH)),
		_color_path(key),
		_format_value(new_value),
		_color_info("(%s)" % _type_name(typeof(new_value))),
		_color_info("resolved: %s" % ProjectSettings.globalize_path(_USER_CFG_PATH)),
	]

func _cmd_setting_user_get(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: setting_user_get <key>")
	var key := str(args[0]).strip_edges()
	if key.is_empty():
		return _format_error("Usage: setting_user_get <key>")

	var cfg := ConfigFile.new()
	var load_err: int = cfg.load(_USER_CFG_PATH)
	if load_err == ERR_FILE_NOT_FOUND:
		return _format_error("%s does not exist (resolved: %s)" % [_USER_CFG_PATH, ProjectSettings.globalize_path(_USER_CFG_PATH)])
	if load_err != OK:
		return _format_error("Failed to read %s (err=%d)" % [_USER_CFG_PATH, load_err])
	if not cfg.has_section_key(_USER_CFG_SECTION, key):
		return _format_error("Key not found in %s: %s" % [_USER_CFG_PATH, key])

	var value: Variant = cfg.get_value(_USER_CFG_SECTION, key)
	return "%s = %s %s" % [_color_path(key), _format_value(value), _color_info("(%s)" % _type_name(typeof(value)))]

func _cmd_setting_user_clear(args: Array, piped_input: String = "") -> String:
	var globalized: String = ProjectSettings.globalize_path(_USER_CFG_PATH)
	if not FileAccess.file_exists(_USER_CFG_PATH):
		return _color_info("Nothing to clear: %s does not exist (resolved: %s)" % [_USER_CFG_PATH, globalized])
	var dir_err: int = DirAccess.remove_absolute(globalized)
	if dir_err != OK:
		return _format_error("Failed to delete %s (err=%d)" % [_USER_CFG_PATH, dir_err])
	return _format_success("Deleted %s (resolved: %s)" % [_color_path(_USER_CFG_PATH), globalized])

func _cmd_setting_search(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: setting_search <pattern>")
	var pattern := _join_remaining(args, 0)
	if pattern.is_empty():
		return _format_error("Usage: setting_search <pattern>")

	var regex := RegEx.new()
	var compile_err: int = regex.compile(pattern)
	if compile_err != OK:
		return _format_error("Invalid regex: %s" % pattern)

	var matches: Array[String] = []
	for entry in ProjectSettings.get_property_list():
		var key: String = str(entry.get("name", ""))
		if key.is_empty():
			continue
		if regex.search(key) != null:
			matches.append(key)
	matches.sort()

	if matches.is_empty():
		return _format_error("No ProjectSettings keys match regex: %s" % pattern)

	var truncated: bool = matches.size() > _MAX_LIST_RESULTS
	var shown: Array[String] = matches if not truncated else matches.slice(0, _MAX_LIST_RESULTS)

	var lines := PackedStringArray()
	lines.append(_format_success("ProjectSettings regex=%s (%s match)" % [pattern, _color_number(str(matches.size()))]))
	for key in shown:
		var value: Variant = ProjectSettings.get_setting(key) if ProjectSettings.has_setting(key) else null
		lines.append("  %s = %s" % [_color_path(key), _format_value(value)])
	if truncated:
		lines.append(_color_info("  ... (%d more, truncated at %d)" % [matches.size() - _MAX_LIST_RESULTS, _MAX_LIST_RESULTS]))
	return "\n".join(lines)

func _cmd_setting_dump(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: setting_dump <user://path.cfg>")
	var path := str(args[0]).strip_edges()
	if path.is_empty():
		return _format_error("Usage: setting_dump <user://path.cfg>")

	if not FileAccess.file_exists(path):
		return _format_error("ConfigFile not found: %s (resolved: %s)" % [path, ProjectSettings.globalize_path(path)])

	var cfg := ConfigFile.new()
	var load_err: int = cfg.load(path)
	if load_err != OK:
		return _format_error("Failed to parse ConfigFile %s (err=%d)" % [path, load_err])

	var sections: PackedStringArray = cfg.get_sections()
	var lines := PackedStringArray()
	lines.append(_format_success("Dump of %s (resolved: %s)" % [_color_path(path), ProjectSettings.globalize_path(path)]))
	if sections.is_empty():
		lines.append(_color_info("  <no sections>"))
		return "\n".join(lines)
	for section in sections:
		lines.append("[%s]" % _color_path(section))
		var keys: PackedStringArray = cfg.get_section_keys(section)
		if keys.is_empty():
			lines.append(_color_info("  <no keys>"))
			continue
		for key in keys:
			var value: Variant = cfg.get_value(section, key)
			lines.append("  %s = %s %s" % [_color_path(key), _format_value(value), _color_info("(%s)" % _type_name(typeof(value)))])
	return "\n".join(lines)

#endregion

#region Helpers

func _join_remaining(args: Array, start_index: int) -> String:
	var parts := PackedStringArray()
	for i in range(start_index, args.size()):
		parts.append(str(args[i]))
	return " ".join(parts).strip_edges()

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

func _format_value(value: Variant) -> String:
	match typeof(value):
		TYPE_NIL: return _color_info("null")
		TYPE_STRING, TYPE_STRING_NAME: return "\"%s\"" % str(value)
		TYPE_BOOL: return _color_number(str(value))
		TYPE_INT, TYPE_FLOAT: return _color_number(str(value))
		_: return str(value)

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

func _color_info(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_INFO, s]

#endregion

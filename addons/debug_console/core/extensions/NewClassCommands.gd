@tool
class_name DebugConsoleNewClassCommands extends RefCounted

# Extension module - editor-only class authoring commands.
# Generates and rewrites GDScript files on disk under res://generated/ (or
# arbitrary res:// paths for the *_add_* and class_strip commands). All commands
# follow the SceneCommands.gd contract: register_commands(registry, core)
# wires Callables that take (args: Array, piped_input: String = "") -> String
# and return BBCode-formatted strings.
#
# Registered as mode="editor" because they only make sense at design time
# (file system writes, .gd authoring, no runtime effect).
#
# Author the orchestrator must keep a strong reference to the instance so the
# bound Callables survive for the lifetime of the plugin.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"

const _GENERATED_DIR := "res://generated"

var _registry: Node
var _core: Node

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("class_new", _cmd_class_new, "Generate a new GDScript file: class_new <name> <extends> [props=field:Type[=default],...]", "editor")
	_registry.register_command("class_add_method", _cmd_class_add_method, "Append an empty method: class_add_method <res://path.gd> <signature>", "editor")
	_registry.register_command("class_add_signal", _cmd_class_add_signal, "Append a signal declaration: class_add_signal <res://path.gd> <signature>", "editor")
	_registry.register_command("class_add_export", _cmd_class_add_export, "Append an @export var: class_add_export <res://path.gd> <type> <name> [default]", "editor")
	_registry.register_command("class_strip", _cmd_class_strip, "Strip all func blocks from a script, keep declarations: class_strip <res://path.gd>", "editor")
	_registry.register_command("class_template", _cmd_class_template, "Emit a standard scaffold: class_template <node2d|node3d|control|resource|autoload> [name]", "editor")

#region Command implementations

func _cmd_class_new(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: class_new <name> <extends> [props=field:Type[=default],...]")
	var class_ident := str(args[0]).strip_edges()
	var extends_type := str(args[1]).strip_edges()
	if not _is_valid_identifier(class_ident):
		return _format_error("Invalid class name: %s" % class_ident)
	if extends_type.is_empty():
		return _format_error("extends type cannot be empty")

	var props_raw := ""
	for i in range(2, args.size()):
		var token := str(args[i]).strip_edges()
		if token.begins_with("props="):
			props_raw = token.substr("props=".length())
			break

	var props_lines: Array[String] = []
	if not props_raw.is_empty():
		var parse_err := _parse_props(props_raw, props_lines)
		if not parse_err.is_empty():
			return _format_error(parse_err)

	var path := "%s/%s.gd" % [_GENERATED_DIR, class_ident.to_snake_case()]
	var ensure_err := _ensure_dir(_GENERATED_DIR)
	if not ensure_err.is_empty():
		return _format_error(ensure_err)
	if FileAccess.file_exists(path):
		return _format_error("File already exists: %s" % path)

	var lines: Array[String] = []
	lines.append("class_name %s extends %s" % [class_ident, extends_type])
	lines.append("")
	if not props_lines.is_empty():
		for p in props_lines:
			lines.append(p)
		lines.append("")

	var write_err := _write_file(path, "\n".join(lines) + "\n")
	if not write_err.is_empty():
		return _format_error(write_err)
	_request_filesystem_scan()

	var summary := "extends %s" % extends_type
	if not props_lines.is_empty():
		summary += ", %d prop(s)" % props_lines.size()
	return _format_success("Generated %s [%s]" % [_color_path(path), summary])

func _cmd_class_add_method(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: class_add_method <res://path.gd> <signature>")
	var path := str(args[0]).strip_edges()
	var sig_parts: Array[String] = []
	for i in range(1, args.size()):
		sig_parts.append(str(args[i]))
	var signature := " ".join(sig_parts).strip_edges()
	if signature.is_empty():
		return _format_error("Empty method signature")

	var read := _read_file(path)
	if read.is_empty() and not FileAccess.file_exists(path):
		return _format_error("File not found: %s" % path)

	var snippet := "\nfunc %s -> Variant:\n\tpass\n" % signature
	var new_text := _ensure_trailing_newline(read) + snippet
	var write_err := _write_file(path, new_text)
	if not write_err.is_empty():
		return _format_error(write_err)
	_request_filesystem_scan()
	return _format_success("Added method on %s: %s" % [_color_path(path), signature])

func _cmd_class_add_signal(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: class_add_signal <res://path.gd> <signature>")
	var path := str(args[0]).strip_edges()
	var sig_parts: Array[String] = []
	for i in range(1, args.size()):
		sig_parts.append(str(args[i]))
	var signature := " ".join(sig_parts).strip_edges()
	if signature.is_empty():
		return _format_error("Empty signal signature")

	var read := _read_file(path)
	if read.is_empty() and not FileAccess.file_exists(path):
		return _format_error("File not found: %s" % path)

	var insert_at := _find_signal_insertion(read)
	var new_text := _insert_line(read, "signal %s" % signature, insert_at)
	var write_err := _write_file(path, new_text)
	if not write_err.is_empty():
		return _format_error(write_err)
	_request_filesystem_scan()
	return _format_success("Added signal on %s: %s" % [_color_path(path), signature])

func _cmd_class_add_export(args: Array, piped_input: String = "") -> String:
	if args.size() < 3:
		return _format_error("Usage: class_add_export <res://path.gd> <type> <name> [default]")
	var path := str(args[0]).strip_edges()
	var type_name := str(args[1]).strip_edges()
	var var_name := str(args[2]).strip_edges()
	if not _is_valid_identifier(var_name):
		return _format_error("Invalid variable name: %s" % var_name)
	if type_name.is_empty():
		return _format_error("Type cannot be empty")

	var default_raw := ""
	if args.size() > 3:
		var rest: Array[String] = []
		for i in range(3, args.size()):
			rest.append(str(args[i]))
		default_raw = " ".join(rest).strip_edges()

	var read := _read_file(path)
	if read.is_empty() and not FileAccess.file_exists(path):
		return _format_error("File not found: %s" % path)

	var line := "@export var %s: %s" % [var_name, type_name]
	if not default_raw.is_empty():
		line += " = %s" % default_raw

	var insert_at := _find_var_insertion(read)
	var new_text := _insert_line(read, line, insert_at)
	var write_err := _write_file(path, new_text)
	if not write_err.is_empty():
		return _format_error(write_err)
	_request_filesystem_scan()
	return _format_success("Added export on %s: %s" % [_color_path(path), line])

func _cmd_class_strip(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: class_strip <res://path.gd>")
	var path := str(args[0]).strip_edges()
	if not FileAccess.file_exists(path):
		return _format_error("File not found: %s" % path)

	var read := _read_file(path)
	var stripped := _strip_methods(read)
	var removed := stripped["removed"] as int
	var new_text := stripped["text"] as String
	var write_err := _write_file(path, new_text)
	if not write_err.is_empty():
		return _format_error(write_err)
	_request_filesystem_scan()
	return _format_success("Stripped %s methods from %s" % [_color_number(str(removed)), _color_path(path)])

func _cmd_class_template(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: class_template <node2d|node3d|control|resource|autoload> [name]")
	var kind := str(args[0]).strip_edges().to_lower()
	var desired_name := str(args[1]).strip_edges() if args.size() > 1 else ""

	var scaffold := _scaffold_for(kind, desired_name)
	if scaffold.is_empty():
		return _format_error("Unknown template kind: %s (expected node2d|node3d|control|resource|autoload)" % kind)

	var ident := scaffold["class_name"] as String
	var body := scaffold["body"] as String
	var path := "%s/%s.gd" % [_GENERATED_DIR, ident.to_snake_case()]
	var ensure_err := _ensure_dir(_GENERATED_DIR)
	if not ensure_err.is_empty():
		return _format_error(ensure_err)
	if FileAccess.file_exists(path):
		return _format_error("File already exists: %s" % path)
	var write_err := _write_file(path, body)
	if not write_err.is_empty():
		return _format_error(write_err)
	_request_filesystem_scan()
	return _format_success("Generated %s template at %s" % [kind, _color_path(path)])

#endregion

#region Helpers

func _parse_props(raw: String, out_lines: Array[String]) -> String:
	for chunk in raw.split(",", false):
		var entry := chunk.strip_edges()
		if entry.is_empty():
			continue
		var default_value := ""
		var eq := entry.find("=")
		if eq != -1:
			default_value = entry.substr(eq + 1).strip_edges()
			entry = entry.substr(0, eq).strip_edges()
		var colon := entry.find(":")
		if colon == -1:
			return "Prop missing ':Type' in '%s'" % chunk
		var field_name := entry.substr(0, colon).strip_edges()
		var field_type := entry.substr(colon + 1).strip_edges()
		if not _is_valid_identifier(field_name):
			return "Invalid prop name: %s" % field_name
		if field_type.is_empty():
			return "Prop type cannot be empty for %s" % field_name
		var line := "var %s: %s" % [field_name, field_type]
		if not default_value.is_empty():
			line += " = %s" % default_value
		out_lines.append(line)
	return ""

func _scaffold_for(kind: String, desired_name: String) -> Dictionary:
	match kind:
		"node2d":
			var ident := desired_name if not desired_name.is_empty() else "GeneratedNode2D"
			var body := "extends Node2D\nclass_name %s\n\nfunc _ready() -> void:\n\tpass\n\nfunc _process(delta: float) -> void:\n\tpass\n" % ident
			return {"class_name": ident, "body": body}
		"node3d":
			var ident := desired_name if not desired_name.is_empty() else "GeneratedNode3D"
			var body := "extends Node3D\nclass_name %s\n\nfunc _ready() -> void:\n\tpass\n\nfunc _process(delta: float) -> void:\n\tpass\n" % ident
			return {"class_name": ident, "body": body}
		"control":
			var ident := desired_name if not desired_name.is_empty() else "GeneratedControl"
			var body := "extends Control\nclass_name %s\n\nfunc _ready() -> void:\n\tpass\n\nfunc _gui_input(event: InputEvent) -> void:\n\tpass\n" % ident
			return {"class_name": ident, "body": body}
		"resource":
			var ident := desired_name if not desired_name.is_empty() else "GeneratedResource"
			var body := "@tool\nclass_name %s extends Resource\n\n@export var id: StringName = &\"\"\n" % ident
			return {"class_name": ident, "body": body}
		"autoload":
			var ident := desired_name if not desired_name.is_empty() else "GeneratedAutoload"
			var body := "extends Node\nclass_name %s\n\n# Register in Project Settings > Autoload after generating.\n\nfunc _ready() -> void:\n\tpass\n" % ident
			return {"class_name": ident, "body": body}
		_:
			return {}

func _strip_methods(text: String) -> Dictionary:
	var lines := text.split("\n")
	var out: Array[String] = []
	var i := 0
	var removed := 0
	while i < lines.size():
		var line: String = lines[i]
		var stripped_line := line.strip_edges(true, false)
		if stripped_line.begins_with("func "):
			removed += 1
			i += 1
			while i < lines.size():
				var next: String = lines[i]
				if next.strip_edges().is_empty():
					i += 1
					continue
				var indent := _leading_indent(next)
				if indent == 0:
					break
				i += 1
			continue
		out.append(line)
		i += 1
	var joined := "\n".join(out)
	while joined.ends_with("\n\n\n"):
		joined = joined.substr(0, joined.length() - 1)
	return {"text": _ensure_trailing_newline(joined), "removed": removed}

func _leading_indent(line: String) -> int:
	var n := 0
	for c in line:
		if c == "\t" or c == " ":
			n += 1
		else:
			break
	return n

func _find_signal_insertion(text: String) -> int:
	var lines := text.split("\n")
	var last_signal := -1
	var first_func := -1
	for i in lines.size():
		var s: String = lines[i].strip_edges()
		if s.begins_with("signal "):
			last_signal = i
		elif first_func == -1 and s.begins_with("func "):
			first_func = i
	if last_signal != -1:
		return last_signal + 1
	if first_func != -1:
		return first_func
	return lines.size()

func _find_var_insertion(text: String) -> int:
	var lines := text.split("\n")
	var last_var := -1
	var first_func := -1
	for i in lines.size():
		var s: String = lines[i].strip_edges()
		if s.begins_with("var ") or s.begins_with("@export") or s.begins_with("const "):
			last_var = i
		elif first_func == -1 and s.begins_with("func "):
			first_func = i
	if last_var != -1:
		return last_var + 1
	if first_func != -1:
		return first_func
	return lines.size()

func _insert_line(text: String, new_line: String, at_index: int) -> String:
	var lines := text.split("\n")
	var arr: Array[String] = []
	for l in lines:
		arr.append(l)
	var idx: int = clampi(at_index, 0, arr.size())
	arr.insert(idx, new_line)
	var joined := "\n".join(arr)
	return _ensure_trailing_newline(joined)

func _ensure_trailing_newline(text: String) -> String:
	if text.is_empty():
		return ""
	if text.ends_with("\n"):
		return text
	return text + "\n"

func _is_valid_identifier(s: String) -> bool:
	if s.is_empty():
		return false
	var first := s.unicode_at(0)
	var is_alpha_first := (first == 95) or (first >= 65 and first <= 90) or (first >= 97 and first <= 122)
	if not is_alpha_first:
		return false
	for i in range(1, s.length()):
		var c := s.unicode_at(i)
		var ok := (c == 95) or (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122)
		if not ok:
			return false
	return true

func _ensure_dir(res_path: String) -> String:
	if DirAccess.dir_exists_absolute(res_path):
		return ""
	var err := DirAccess.make_dir_recursive_absolute(res_path)
	if err != OK:
		return "Failed to create directory %s (err %d)" % [res_path, err]
	return ""

func _read_file(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if not f:
		return ""
	var text := f.get_as_text()
	f.close()
	return text

func _write_file(path: String, contents: String) -> String:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if not f:
		return "Failed to open %s for writing (err %d)" % [path, FileAccess.get_open_error()]
	f.store_string(contents)
	f.close()
	return ""

func _request_filesystem_scan() -> void:
	if not Engine.is_editor_hint():
		return
	var fs: Object = Engine.get_singleton("EditorInterface") if Engine.has_singleton("EditorInterface") else null
	if fs and fs.has_method("get_resource_filesystem"):
		var rfs: Object = fs.call("get_resource_filesystem")
		if rfs and rfs.has_method("scan"):
			rfs.call("scan")

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

#endregion

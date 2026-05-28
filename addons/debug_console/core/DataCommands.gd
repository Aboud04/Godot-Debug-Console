@tool
class_name DebugConsoleDataCommands extends RefCounted

# Tabular data + Resource introspection commands. Mirrors the
# SceneCommands/RuntimeCommands/UICommands module convention: the orchestrator
# in BuiltInCommands.register_universal_commands instantiates one of these,
# keeps a strong reference, and calls register_commands(registry, core). All
# Callables are bound to this instance so they stay valid for the plugin's
# lifetime.
#
# Scope is intentionally narrow: file/text I/O, CSV+JSON parsing, ASCII table
# rendering, a minimal JSON-path query, and Resource/Script introspection.
# Nothing here touches the editor dock plugin glue or BuiltInCommands.gd.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_DIM := "#909090"

# Rows past this cap are dropped from csv_read / query output to prevent the
# console terminal from being flooded by huge datasets.
const _MAX_ROWS := 100

var _registry: Node
var _core: Node

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("csv_read", _cmd_csv_read, "Read a CSV file and render as an ASCII table (first row = headers, capped at 100 rows): csv_read <res://file.csv | user://file.csv>", "both")
	_registry.register_command("csv_write", _cmd_csv_write, "Write piped rows to CSV (one row per line, commas split columns): csv_write <path>", "both", true)
	_registry.register_command("json_read", _cmd_json_read, "Read a JSON file and pretty-print it: json_read <path>", "both")
	_registry.register_command("json_write", _cmd_json_write, "Write piped JSON content to a file (validated via parse): json_write <path>", "both", true)
	_registry.register_command("table", _cmd_table, "Render piped CSV or JSON array-of-objects as an ASCII table", "both", true)
	_registry.register_command("query", _cmd_query, "JSON-path query on piped JSON. Subset: .field chains, [index], [start:end] slice. Example: .users[0].name", "both", true)
	_registry.register_command("resource_read", _cmd_resource_read, "Load a Resource and dump its property table; for scripts dumps class_name+extends+methods: resource_read <res://path.tres | res://path.gd>", "both")
	_registry.register_command("resource_save", _cmd_resource_save, "Extract a Resource property from a node and save to disk: resource_save <node_path>:<property> <res://path.tres>", "both")
	_registry.register_command("dir", _cmd_dir, "List a directory's contents with size+type: dir <path>", "both")
	_registry.register_command("hash", _cmd_hash, "SHA256 (or MD5 with -m) of piped text; without piped input treats first arg as a file path: hash [-m] [file_path]", "both", true)

#region Command implementations

func _cmd_csv_read(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: csv_read <res://file.csv | user://file.csv>")
	var path := _normalize_path(str(args[0]))
	if not FileAccess.file_exists(path):
		return _format_error("File not found: %s" % path)
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		return _format_error("Failed to open: %s (err %d)" % [path, FileAccess.get_open_error()])
	var text := file.get_as_text()
	file.close()
	var rows: Array = _parse_csv(text)
	if rows.is_empty():
		return "%s is empty" % _color_path(path)
	var headers: Array = rows[0]
	var data: Array = rows.slice(1)
	var truncated := false
	if data.size() > _MAX_ROWS:
		data = data.slice(0, _MAX_ROWS)
		truncated = true
	var rendered := _format_table(data, headers)
	var summary := "%s rows from %s" % [_color_num(str(data.size())), _color_path(path)]
	if truncated:
		summary += "  [color=%s](capped at %d)[/color]" % [_COLOR_DIM, _MAX_ROWS]
	return "%s\n%s" % [summary, rendered]

func _cmd_csv_write(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: csv_write <path> (with piped rows)")
	if piped_input.strip_edges().is_empty():
		return _format_error("csv_write requires piped input (one row per line)")
	var path := _normalize_path(str(args[0]))
	# Use the same parser as csv_read so quoted fields with embedded commas
	# round-trip cleanly when callers pipe CSV-shaped input back in.
	var rows: Array = _parse_csv(piped_input)
	if rows.is_empty():
		return _format_error("No rows parsed from piped input")
	var serialized := _serialize_csv(rows)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if not file:
		return _format_error("Failed to open for write: %s (err %d)" % [path, FileAccess.get_open_error()])
	file.store_string(serialized)
	file.close()
	return _format_success("Wrote %s row(s) to %s" % [_color_num(str(rows.size())), _color_path(path)])

func _cmd_json_read(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: json_read <path>")
	var path := _normalize_path(str(args[0]))
	if not FileAccess.file_exists(path):
		return _format_error("File not found: %s" % path)
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		return _format_error("Failed to open: %s (err %d)" % [path, FileAccess.get_open_error()])
	var text := file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	if parsed == null and text.strip_edges() != "null":
		return _format_error("Invalid JSON in %s" % path)
	return JSON.stringify(parsed, "  ")

func _cmd_json_write(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: json_write <path> (with piped JSON content)")
	if piped_input.strip_edges().is_empty():
		return _format_error("json_write requires piped JSON content")
	var parsed: Variant = JSON.parse_string(piped_input)
	if parsed == null and piped_input.strip_edges() != "null":
		return _format_error("Piped input is not valid JSON")
	var path := _normalize_path(str(args[0]))
	var serialized := JSON.stringify(parsed, "  ")
	var file := FileAccess.open(path, FileAccess.WRITE)
	if not file:
		return _format_error("Failed to open for write: %s (err %d)" % [path, FileAccess.get_open_error()])
	file.store_string(serialized)
	file.close()
	return _format_success("Wrote JSON (%s bytes) to %s" % [_color_num(str(serialized.length())), _color_path(path)])

func _cmd_table(args: Array, piped_input: String = "") -> String:
	if piped_input.strip_edges().is_empty():
		return _format_error("table requires piped input (CSV text or JSON array of objects)")
	var trimmed := piped_input.strip_edges()
	if trimmed.begins_with("[") or trimmed.begins_with("{"):
		var parsed: Variant = JSON.parse_string(trimmed)
		if parsed == null:
			return _format_error("Piped input looks like JSON but failed to parse")
		if parsed is Array:
			return _render_json_array(parsed as Array)
		if parsed is Dictionary:
			var d: Dictionary = parsed
			var rows: Array = []
			for k in d.keys():
				rows.append([str(k), _stringify_value(d[k])])
			return _format_table(rows, ["key", "value"])
		return _format_error("Unsupported JSON shape for table")
	var csv_rows: Array = _parse_csv(piped_input)
	if csv_rows.is_empty():
		return _format_error("No rows parsed from piped input")
	var headers: Array = csv_rows[0]
	var data: Array = csv_rows.slice(1)
	return _format_table(data, headers)

func _cmd_query(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: query <selector> (with piped JSON input). Subset: .field chains, [index], [start:end]")
	if piped_input.strip_edges().is_empty():
		return _format_error("query requires piped JSON content")
	var parsed: Variant = JSON.parse_string(piped_input)
	if parsed == null and piped_input.strip_edges() != "null":
		return _format_error("Piped input is not valid JSON")
	var selector := str(args[0]).strip_edges()
	var result: Variant = _query_json(parsed, selector)
	if result == null:
		return "[color=%s]null[/color]" % _COLOR_DIM
	if result is Array and (result as Array).size() > _MAX_ROWS:
		var arr: Array = (result as Array).slice(0, _MAX_ROWS)
		return "%s\n[color=%s](capped at %d of %d)[/color]" % [
			JSON.stringify(arr, "  "),
			_COLOR_DIM,
			_MAX_ROWS,
			(result as Array).size(),
		]
	return JSON.stringify(result, "  ")

func _cmd_resource_read(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: resource_read <res://path.tres | res://path.gd>")
	var path := _normalize_path(str(args[0]))
	if not ResourceLoader.exists(path):
		return _format_error("Resource not found: %s" % path)
	var res: Resource = load(path)
	if not res:
		return _format_error("Failed to load: %s" % path)
	if res is Script:
		return _dump_script(res as Script, path)
	return _dump_resource(res, path)

func _cmd_resource_save(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: resource_save <node_path>:<property> <res://path.tres>")
	var selector := str(args[0]).strip_edges()
	var out_path := _normalize_path(str(args[1]))
	var colon := selector.rfind(":")
	if colon <= 0 or colon == selector.length() - 1:
		return _format_error("Selector must be <node_path>:<property> (got %s)" % selector)
	var node_path := selector.substr(0, colon)
	var prop := selector.substr(colon + 1)
	var node := _resolve_node(node_path)
	if not node:
		return _format_error("Node not found: %s" % node_path)
	if not (prop in node):
		return _format_error("Property %s not found on %s" % [prop, node_path])
	var value: Variant = node.get(prop)
	if not (value is Resource):
		return _format_error("Property %s on %s is not a Resource (got %s)" % [prop, node_path, _type_name_of(value)])
	var err := ResourceSaver.save(value as Resource, out_path)
	if err != OK:
		return _format_error("ResourceSaver.save failed (err %d) for %s" % [err, out_path])
	return _format_success("Saved %s.%s -> %s" % [_color_path(node_path), prop, _color_path(out_path)])

func _cmd_dir(args: Array, piped_input: String = "") -> String:
	var raw := str(args[0]).strip_edges() if not args.is_empty() else "res://"
	var path := _normalize_path(raw) if raw != "" else "res://"
	if not DirAccess.dir_exists_absolute(path):
		return _format_error("Directory not found: %s" % path)
	var dir := DirAccess.open(path)
	if not dir:
		return _format_error("Failed to open directory: %s (err %d)" % [path, DirAccess.get_open_error()])
	var subdirs: PackedStringArray = dir.get_directories()
	var files: PackedStringArray = dir.get_files()
	var rows: Array = []
	for d in subdirs:
		rows.append([d + "/", "dir", "-"])
	for f in files:
		var full := path.path_join(f)
		var ext := f.get_extension()
		var size_str := "-"
		var size_file := FileAccess.open(full, FileAccess.READ)
		if size_file:
			size_str = _format_size(size_file.get_length())
			size_file.close()
		rows.append([f, (ext if ext != "" else "file"), size_str])
	if rows.is_empty():
		return "%s is empty" % _color_path(path)
	var header := "Contents of %s (%s entries):" % [_color_path(path), _color_num(str(rows.size()))]
	return "%s\n%s" % [header, _format_table(rows, ["name", "type", "size"])]

func _cmd_hash(args: Array, piped_input: String = "") -> String:
	var use_md5 := false
	var positional: Array = []
	for a in args:
		var s := str(a).strip_edges()
		if s == "-m" or s == "--md5":
			use_md5 = true
		else:
			positional.append(s)
	var data_bytes: PackedByteArray
	var source_label: String
	if not piped_input.is_empty():
		data_bytes = piped_input.to_utf8_buffer()
		source_label = "<piped %d bytes>" % data_bytes.size()
	elif not positional.is_empty():
		var path := _normalize_path(positional[0])
		if not FileAccess.file_exists(path):
			return _format_error("File not found: %s" % path)
		var file := FileAccess.open(path, FileAccess.READ)
		if not file:
			return _format_error("Failed to open: %s (err %d)" % [path, FileAccess.get_open_error()])
		data_bytes = file.get_buffer(file.get_length())
		file.close()
		source_label = path
	else:
		return _format_error("Usage: hash [-m] <file_path>  OR  pipe text into hash [-m]")
	var ctx := HashingContext.new()
	var algo := HashingContext.HASH_MD5 if use_md5 else HashingContext.HASH_SHA256
	if ctx.start(algo) != OK:
		return _format_error("Failed to start HashingContext")
	ctx.update(data_bytes)
	var digest := ctx.finish().hex_encode()
	var label := "MD5" if use_md5 else "SHA256"
	return "%s  %s  (%s)" % [label, digest, _color_path(source_label)]

#endregion

#region Helpers - rendering

func _format_table(rows: Array, headers: Array) -> String:
	var col_count: int = headers.size()
	for r in rows:
		col_count = max(col_count, (r as Array).size() if r is Array else 0)
	if col_count == 0:
		return "[color=%s](empty table)[/color]" % _COLOR_DIM
	var widths: Array[int] = []
	for c in range(col_count):
		var w := 0
		if c < headers.size():
			w = max(w, str(headers[c]).length())
		for r in rows:
			if r is Array and c < (r as Array).size():
				w = max(w, str((r as Array)[c]).length())
		widths.append(max(w, 1))
	var aligns: Array[String] = []
	for c in range(col_count):
		var all_numeric := true
		var sample := 0
		for r in rows:
			if not (r is Array) or c >= (r as Array).size():
				continue
			var cell := str((r as Array)[c]).strip_edges()
			if cell.is_empty():
				continue
			sample += 1
			if not (cell.is_valid_int() or cell.is_valid_float()):
				all_numeric = false
				break
		aligns.append("right" if all_numeric and sample > 0 else "left")
	var lines: Array[String] = []
	var header_cells: Array[String] = []
	for c in range(col_count):
		var h := str(headers[c]) if c < headers.size() else ""
		header_cells.append(_pad(h, widths[c], aligns[c]))
	lines.append("| " + " | ".join(header_cells) + " |")
	var sep_cells: Array[String] = []
	for c in range(col_count):
		sep_cells.append("-".repeat(widths[c]))
	lines.append("|-" + "-|-".join(sep_cells) + "-|")
	for r in rows:
		var body_cells: Array[String] = []
		for c in range(col_count):
			var raw := "" if not (r is Array) or c >= (r as Array).size() else str((r as Array)[c])
			body_cells.append(_pad(raw, widths[c], aligns[c]))
		lines.append("| " + " | ".join(body_cells) + " |")
	return "[color=%s]%s[/color]" % [_COLOR_DIM, "\n".join(lines)]

func _pad(s: String, width: int, align: String) -> String:
	var diff := width - s.length()
	if diff <= 0:
		return s
	if align == "right":
		return " ".repeat(diff) + s
	return s + " ".repeat(diff)

func _render_json_array(arr: Array) -> String:
	if arr.is_empty():
		return "[color=%s](empty array)[/color]" % _COLOR_DIM
	var headers: Array = []
	var seen: Dictionary = {}
	var all_objects := true
	for entry in arr:
		if not (entry is Dictionary):
			all_objects = false
			break
		for k in (entry as Dictionary).keys():
			if not seen.has(k):
				seen[k] = true
				headers.append(str(k))
	if not all_objects:
		var rows: Array = []
		for entry in arr:
			rows.append([_stringify_value(entry)])
		return _format_table(rows, ["value"])
	var truncated := false
	var working: Array = arr
	if working.size() > _MAX_ROWS:
		working = working.slice(0, _MAX_ROWS)
		truncated = true
	var rows2: Array = []
	for entry in working:
		var d: Dictionary = entry
		var row: Array = []
		for h in headers:
			row.append(_stringify_value(d.get(h, "")))
		rows2.append(row)
	var out := _format_table(rows2, headers)
	if truncated:
		out += "\n[color=%s](capped at %d of %d)[/color]" % [_COLOR_DIM, _MAX_ROWS, arr.size()]
	return out

func _stringify_value(v: Variant) -> String:
	if v == null:
		return "null"
	if v is bool:
		return "true" if v else "false"
	if v is String or v is StringName:
		return str(v)
	if v is int or v is float:
		return str(v)
	return JSON.stringify(v)

#endregion

#region Helpers - parsing

func _parse_csv(text: String) -> Array:
	# RFC-4180-flavored parser: handles quoted fields, embedded commas, and the
	# "" escape for a literal quote inside a quoted field. Newlines outside
	# quotes terminate rows; \r is swallowed so CRLF input round-trips.
	var rows: Array = []
	var row: Array = []
	var field := ""
	var in_quotes := false
	var i := 0
	var n := text.length()
	while i < n:
		var ch := text[i]
		if in_quotes:
			if ch == '"':
				if i + 1 < n and text[i + 1] == '"':
					field += '"'
					i += 2
					continue
				in_quotes = false
				i += 1
				continue
			field += ch
			i += 1
			continue
		if ch == '"':
			in_quotes = true
			i += 1
			continue
		if ch == ',':
			row.append(field)
			field = ""
			i += 1
			continue
		if ch == '\n':
			row.append(field)
			rows.append(row)
			row = []
			field = ""
			i += 1
			continue
		if ch == '\r':
			i += 1
			continue
		field += ch
		i += 1
	if field != "" or not row.is_empty():
		row.append(field)
		rows.append(row)
	return rows

func _serialize_csv(rows: Array) -> String:
	var lines: Array[String] = []
	for r in rows:
		var fields: Array[String] = []
		var cells: Array = r if r is Array else [r]
		for cell in cells:
			var s := str(cell)
			if s.contains(",") or s.contains('"') or s.contains("\n"):
				fields.append('"' + s.replace('"', '""') + '"')
			else:
				fields.append(s)
		lines.append(",".join(fields))
	return "\n".join(lines)

func _query_json(data: Variant, selector: String) -> Variant:
	# Supported subset:
	#   .field            object key access (chained: .a.b.c)
	#   [index]           array index (negative counts from end)
	#   [start:end]       slice; start/end may be omitted (defaults 0 / size)
	# A leading dot is optional. Anything outside this subset (wildcards,
	# filters, recursive descent) is not supported and will likely return null.
	var sel := selector.strip_edges()
	if sel.is_empty() or sel == ".":
		return data
	var current: Variant = data
	var i := 0
	var n := sel.length()
	while i < n:
		var ch := sel[i]
		if ch == '.':
			i += 1
			var start := i
			while i < n and sel[i] != '.' and sel[i] != '[':
				i += 1
			var field := sel.substr(start, i - start)
			if field.is_empty():
				continue
			if current is Dictionary and (current as Dictionary).has(field):
				current = (current as Dictionary)[field]
			else:
				return null
		elif ch == '[':
			var end := sel.find("]", i)
			if end == -1:
				return null
			var inner := sel.substr(i + 1, end - i - 1)
			i = end + 1
			if not (current is Array):
				return null
			var arr: Array = current
			if inner.contains(":"):
				var parts: PackedStringArray = inner.split(":")
				var s_str := parts[0].strip_edges()
				var e_str := parts[1].strip_edges() if parts.size() > 1 else ""
				var s := 0 if s_str.is_empty() else int(s_str)
				var e := arr.size() if e_str.is_empty() else int(e_str)
				if s < 0:
					s = max(0, arr.size() + s)
				if e < 0:
					e = max(0, arr.size() + e)
				s = clamp(s, 0, arr.size())
				e = clamp(e, 0, arr.size())
				current = arr.slice(s, e)
			else:
				var idx := int(inner)
				if idx < 0:
					idx = arr.size() + idx
				if idx < 0 or idx >= arr.size():
					return null
				current = arr[idx]
		else:
			var start2 := i
			while i < n and sel[i] != '.' and sel[i] != '[':
				i += 1
			var field2 := sel.substr(start2, i - start2)
			if current is Dictionary and (current as Dictionary).has(field2):
				current = (current as Dictionary)[field2]
			else:
				return null
	return current

#endregion

#region Helpers - introspection

func _dump_resource(res: Resource, path: String) -> String:
	var rows: Array = []
	for prop in res.get_property_list():
		var usage := int(prop.get("usage", 0))
		if (usage & PROPERTY_USAGE_STORAGE) == 0 and (usage & PROPERTY_USAGE_EDITOR) == 0:
			continue
		var pname := str(prop.get("name", ""))
		if pname.begins_with("_") or pname == "script" or pname == "resource_local_to_scene":
			continue
		var ptype := _type_name(int(prop.get("type", TYPE_NIL)))
		var value: Variant = res.get(pname)
		rows.append([pname, ptype, _stringify_value(value)])
	var header := "Resource %s (%s, %s prop(s)):" % [_color_path(path), res.get_class(), _color_num(str(rows.size()))]
	return "%s\n%s" % [header, _format_table(rows, ["key", "type", "value"])]

func _dump_script(script: Script, path: String) -> String:
	var lines: Array[String] = []
	lines.append("Script %s" % _color_path(path))
	var global_name: String = script.get_global_name() if script.has_method("get_global_name") else ""
	if global_name != "":
		lines.append("  class_name: %s" % global_name)
	var base: Script = script.get_base_script()
	if base:
		lines.append("  extends:    %s" % str(base.resource_path))
	var inst_base := script.get_instance_base_type()
	if inst_base != "":
		lines.append("  base type:  %s" % inst_base)
	var methods: Array = script.get_script_method_list()
	# Filter out engine-internal methods (underscore-prefixed) for readability.
	var visible: Array[String] = []
	for m in methods:
		var mname := str(m.get("name", ""))
		if mname.is_empty() or mname.begins_with("_"):
			continue
		var arg_names: Array[String] = []
		for a in (m.get("args", []) as Array):
			arg_names.append(str(a.get("name", "?")))
		visible.append("    %s(%s)" % [mname, ", ".join(arg_names)])
	lines.append("  methods (%s):" % _color_num(str(visible.size())))
	if visible.is_empty():
		lines.append("    [color=%s](none)[/color]" % _COLOR_DIM)
	else:
		lines.append_array(visible)
	return "\n".join(lines)

func _type_name_of(v: Variant) -> String:
	return _type_name(typeof(v))

func _type_name(t: int) -> String:
	match t:
		TYPE_NIL: return "null"
		TYPE_BOOL: return "bool"
		TYPE_INT: return "int"
		TYPE_FLOAT: return "float"
		TYPE_STRING: return "String"
		TYPE_STRING_NAME: return "StringName"
		TYPE_VECTOR2: return "Vector2"
		TYPE_VECTOR3: return "Vector3"
		TYPE_COLOR: return "Color"
		TYPE_NODE_PATH: return "NodePath"
		TYPE_OBJECT: return "Object"
		TYPE_DICTIONARY: return "Dictionary"
		TYPE_ARRAY: return "Array"
		_: return "Variant(%d)" % t

#endregion

#region Helpers - path + scene

func _normalize_path(path: String) -> String:
	# Mirrors BuiltInCommands._resolve_output_path: absolute res://user:// paths
	# are returned untouched; in the editor a bare name is treated as relative
	# to res://, at runtime it is treated as relative to user://.
	var p := path.strip_edges()
	if p.is_empty():
		return ""
	if p.begins_with("res://") or p.begins_with("user://"):
		return p
	if Engine.is_editor_hint():
		return "res://".path_join(p)
	return "user://".path_join(p)

func _resolve_node(path: String) -> Node:
	var p := path.strip_edges()
	if p.is_empty():
		return null
	var root := _get_scene_root()
	if not root:
		return null
	if Engine.is_editor_hint():
		if p == "/root":
			return root
		if p.begins_with("/root/"):
			p = p.substr(6)
		elif p.begins_with("/"):
			p = p.substr(1)
		if p.is_empty():
			return root
		return root.get_node_or_null(NodePath(p))
	var tree := Engine.get_main_loop() as SceneTree
	if not tree:
		return null
	if p.begins_with("/"):
		return tree.root.get_node_or_null(NodePath(p))
	return root.get_node_or_null(NodePath(p))

func _get_scene_root() -> Node:
	if Engine.is_editor_hint():
		return EditorInterface.get_edited_scene_root()
	var tree := Engine.get_main_loop() as SceneTree
	if not tree:
		return null
	if tree.current_scene:
		return tree.current_scene
	return tree.root

func _format_size(bytes: int) -> String:
	if bytes < 1024:
		return "%d B" % bytes
	if bytes < 1024 * 1024:
		return "%.1f KB" % (bytes / 1024.0)
	if bytes < 1024 * 1024 * 1024:
		return "%.1f MB" % (bytes / (1024.0 * 1024.0))
	return "%.1f GB" % (bytes / (1024.0 * 1024.0 * 1024.0))

#endregion

#region Helpers - formatting

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_num(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

#endregion

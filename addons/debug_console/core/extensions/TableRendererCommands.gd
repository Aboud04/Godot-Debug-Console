@tool
class_name DebugConsoleTableRendererCommands extends RefCounted

# Chrome console.table-style renderer for game objects. Evaluates arbitrary
# expressions with the Expression class against the current scene root and
# pretty-prints the result as an aligned ASCII table (BBCode), CSV, or
# markdown. Designed to ship separately from BuiltInCommands.gd; the
# orchestrator instantiates one of these and holds a strong reference so the
# Callables stay valid for the lifetime of the plugin.
#
# Commands here are self-contained: nothing here touches the dock plugin glue,
# the file-based test runner, or BuiltInCommands.gd. State is limited to the
# configured maximum column width.

const _COLOR_ERROR := "#FF4444"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_HEADER := "#5FBEE0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_ROW_TINT := "#C8C8C8"
const _COLOR_MUTED := "#888888"

const _COL_SEPARATOR := " | "
const _COL_PAD := "  "
const _MIN_WIDTH := 1
const _ABSOLUTE_MAX_WIDTH := 200
const _COLUMNS_DELIM := "--"

var _registry: Node
var _core: Node
var _max_width: int = 30

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("table", _cmd_table, "Render expr as a BBCode table: table <expr> [-- col1 col2 ...]", "both")
	_registry.register_command("table_csv", _cmd_table_csv, "Render expr as CSV (pipe-friendly): table_csv <expr> [-- col1 col2 ...]", "both")
	_registry.register_command("table_md", _cmd_table_md, "Render expr as a markdown table: table_md <expr> [-- col1 col2 ...]", "both")
	_registry.register_command("table_pipe", _cmd_table_pipe, "Render piped JSON as a table (use after `| table_pipe`)", "both")
	_registry.register_command("table_width", _cmd_table_width, "Show or set the max column width used by table renderers: table_width [n]", "both")
	_registry.register_command("table_dump", _cmd_table_dump, "Render expr and save as CSV to user://: table_dump <expr> <user://path.csv> [-- col1 col2 ...]", "both")

#region Command implementations

func _cmd_table(args: Array, piped_input: String = "") -> String:
	var parsed: Dictionary = _split_expr_and_columns(args)
	if parsed.error != "":
		return _format_error(parsed.error)
	var data: Variant = _eval_expression(parsed.expr)
	if data is Dictionary and data.has("__error"):
		return _format_error(data["__error"])
	var rows: Array = _to_rows(data)
	var columns: Array = _resolve_columns(rows, parsed.columns)
	if columns.is_empty():
		return _format_error("No columns to render (empty result?)")
	return _render_bbcode(columns, rows)

func _cmd_table_csv(args: Array, piped_input: String = "") -> String:
	var parsed: Dictionary = _split_expr_and_columns(args)
	if parsed.error != "":
		return _format_error(parsed.error)
	var data: Variant = _eval_expression(parsed.expr)
	if data is Dictionary and data.has("__error"):
		return _format_error(data["__error"])
	var rows: Array = _to_rows(data)
	var columns: Array = _resolve_columns(rows, parsed.columns)
	if columns.is_empty():
		return _format_error("No columns to render (empty result?)")
	return _render_csv(columns, rows)

func _cmd_table_md(args: Array, piped_input: String = "") -> String:
	var parsed: Dictionary = _split_expr_and_columns(args)
	if parsed.error != "":
		return _format_error(parsed.error)
	var data: Variant = _eval_expression(parsed.expr)
	if data is Dictionary and data.has("__error"):
		return _format_error(data["__error"])
	var rows: Array = _to_rows(data)
	var columns: Array = _resolve_columns(rows, parsed.columns)
	if columns.is_empty():
		return _format_error("No columns to render (empty result?)")
	return _render_markdown(columns, rows)

func _cmd_table_pipe(args: Array, piped_input: String = "") -> String:
	if piped_input.strip_edges().is_empty():
		return _format_error("table_pipe expects piped JSON input (e.g. `cmd_that_emits_json | table_pipe`)")
	var json := JSON.new()
	var parse_err: int = json.parse(piped_input)
	if parse_err != OK:
		return _format_error("Piped input is not valid JSON: %s (line %d)" % [json.get_error_message(), json.get_error_line()])
	var data: Variant = json.data
	var rows: Array = _to_rows(data)
	var columns: Array = _resolve_columns(rows, [])
	if columns.is_empty():
		return _format_error("No columns to render from piped JSON")
	return _render_bbcode(columns, rows)

func _cmd_table_width(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_success("table_width = %d" % _max_width)
	var raw := str(args[0]).strip_edges()
	if not raw.is_valid_int():
		return _format_error("Usage: table_width [n] (n must be an integer)")
	var n := raw.to_int()
	if n < _MIN_WIDTH:
		return _format_error("table_width must be >= %d" % _MIN_WIDTH)
	if n > _ABSOLUTE_MAX_WIDTH:
		return _format_error("table_width must be <= %d" % _ABSOLUTE_MAX_WIDTH)
	_max_width = n
	return _format_success("table_width set to %d" % _max_width)

func _cmd_table_dump(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: table_dump <expr> <user://path.csv> [-- col1 col2 ...]")
	# The user://path is the LAST positional arg before an optional `--` columns
	# section. Find that boundary first so the expression can still contain
	# spaces.
	var delim_idx: int = -1
	for i in range(args.size()):
		if str(args[i]) == _COLUMNS_DELIM:
			delim_idx = i
			break
	var head: Array = args if delim_idx < 0 else args.slice(0, delim_idx)
	var tail: Array = [] if delim_idx < 0 else args.slice(delim_idx + 1, args.size())
	if head.size() < 2:
		return _format_error("Usage: table_dump <expr> <user://path.csv> [-- col1 col2 ...]")
	var dest: String = str(head[head.size() - 1]).strip_edges()
	if not dest.begins_with("user://"):
		return _format_error("table_dump destination must start with user:// (got: %s)" % dest)
	var expr_parts: Array = head.slice(0, head.size() - 1)
	var expr_str: String = " ".join(_to_string_array(expr_parts)).strip_edges()
	if expr_str.is_empty():
		return _format_error("Usage: table_dump <expr> <user://path.csv> [-- col1 col2 ...]")

	var data: Variant = _eval_expression(expr_str)
	if data is Dictionary and data.has("__error"):
		return _format_error(data["__error"])
	var rows: Array = _to_rows(data)
	var columns: Array = _resolve_columns(rows, tail)
	if columns.is_empty():
		return _format_error("No columns to render (empty result?)")

	var csv: String = _render_csv(columns, rows)
	var file := FileAccess.open(dest, FileAccess.WRITE)
	if not file:
		return _format_error("Failed to open for write: %s (%s)" % [dest, error_string(FileAccess.get_open_error())])
	file.store_string(csv)
	file.close()
	return _format_success("Wrote %d row(s) x %d col(s) to %s" % [rows.size(), columns.size(), dest])

#endregion

#region Argument parsing

func _split_expr_and_columns(args: Array) -> Dictionary:
	if args.is_empty():
		return {"expr": "", "columns": [], "error": "Usage: table <expr> [-- col1 col2 ...]"}
	var delim_idx: int = -1
	for i in range(args.size()):
		if str(args[i]) == _COLUMNS_DELIM:
			delim_idx = i
			break
	var expr_parts: Array
	var col_parts: Array
	if delim_idx < 0:
		expr_parts = args
		col_parts = []
	else:
		expr_parts = args.slice(0, delim_idx)
		col_parts = args.slice(delim_idx + 1, args.size())
	var expr_str: String = " ".join(_to_string_array(expr_parts)).strip_edges()
	if expr_str.is_empty():
		return {"expr": "", "columns": [], "error": "Expression is empty"}
	return {"expr": expr_str, "columns": _to_string_array(col_parts), "error": ""}

func _to_string_array(arr: Array) -> Array:
	var out: Array = []
	for v in arr:
		out.append(str(v))
	return out

#endregion

#region Expression evaluation

func _eval_expression(expression_text: String) -> Variant:
	var expr := Expression.new()
	var parse_err: int = expr.parse(expression_text, [])
	if parse_err != OK:
		return {"__error": "Parse error: %s" % expr.get_error_text()}
	var base: Object = _get_scene_root()
	var value: Variant = expr.execute([], base, false)
	if expr.has_execute_failed():
		return {"__error": "Execute error: %s" % expr.get_error_text()}
	return value

#endregion

#region Row + column normalisation

func _to_rows(data: Variant) -> Array:
	# Normalises any expression result into Array[Dictionary] (column -> value)
	# so renderers can share one code path. Mirrors Chrome's console.table
	# behaviour: array-of-objects becomes a table, scalar arrays become a single
	# "value" column, and a single dict becomes a key/value table.
	var rows: Array = []
	if data is Array:
		for item in data:
			rows.append(_row_from_item(item))
		return rows
	if data is Dictionary:
		var d: Dictionary = data
		for k in d.keys():
			rows.append({"key": k, "value": d[k]})
		return rows
	if data is Object:
		rows.append(_row_from_object(data))
		return rows
	rows.append({"value": data})
	return rows

func _row_from_item(item: Variant) -> Dictionary:
	if item is Dictionary:
		return item
	if item is Object:
		return _row_from_object(item)
	return {"value": item}

func _row_from_object(obj: Object) -> Dictionary:
	var row: Dictionary = {}
	if not is_instance_valid(obj):
		return {"value": "<invalid>"}
	# STORAGE filters out @export-only / runtime-only churn we don't want, and
	# SCRIPT_VARIABLE skips engine-injected category headers. Together they
	# correspond to "the data the script author actually declared".
	var wanted_flags: int = PROPERTY_USAGE_STORAGE | PROPERTY_USAGE_SCRIPT_VARIABLE
	for prop in obj.get_property_list():
		var usage: int = int(prop.get("usage", 0))
		if (usage & wanted_flags) != wanted_flags:
			continue
		var pname: String = str(prop.get("name", ""))
		if pname.is_empty():
			continue
		row[pname] = obj.get(pname)
	if row.is_empty() and obj.has_method("get"):
		# Fall back to a single-cell label so the table is never empty.
		row["value"] = str(obj)
	return row

func _resolve_columns(rows: Array, requested: Array) -> Array:
	var seen: Dictionary = {}
	var order: Array = []
	for row in rows:
		if not (row is Dictionary):
			continue
		for k in (row as Dictionary).keys():
			var key_str: String = str(k)
			if not seen.has(key_str):
				seen[key_str] = true
				order.append(key_str)
	if requested.is_empty():
		return order
	var filtered: Array = []
	for col in requested:
		var col_str: String = str(col).strip_edges()
		if col_str.is_empty():
			continue
		if seen.has(col_str):
			filtered.append(col_str)
	return filtered

#endregion

#region Rendering

func _render_bbcode(columns: Array, rows: Array) -> String:
	var cell_grid: Array = _build_cell_grid(columns, rows)
	var widths: Array = _column_widths(columns, cell_grid)
	var aligns: Array = _column_alignments(columns, rows)

	var lines: Array = []
	lines.append(_format_bbcode_header(columns, widths))
	lines.append(_format_bbcode_separator(widths))
	for i in range(cell_grid.size()):
		var row_cells: Array = cell_grid[i]
		var rendered_cells: Array = []
		for j in range(columns.size()):
			var raw: String = str(row_cells[j])
			var aligned: String = _align_cell(raw, int(widths[j]), str(aligns[j]))
			rendered_cells.append(_color_cell(raw, aligned, str(aligns[j])))
		var joined: String = _COL_SEPARATOR.join(rendered_cells)
		if i % 2 == 1:
			joined = "[color=%s]%s[/color]" % [_COLOR_ROW_TINT, joined]
		lines.append(joined)
	lines.append("[color=%s]%d row(s), %d column(s)[/color]" % [_COLOR_MUTED, rows.size(), columns.size()])
	return "\n".join(lines)

func _format_bbcode_header(columns: Array, widths: Array) -> String:
	var cells: Array = []
	for j in range(columns.size()):
		var col_name: String = str(columns[j])
		var truncated: String = _truncate(col_name)
		var padded: String = truncated.rpad(int(widths[j]))
		cells.append("[color=%s][b]%s[/b][/color]" % [_COLOR_HEADER, padded])
	return _COL_SEPARATOR.join(cells)

func _format_bbcode_separator(widths: Array) -> String:
	var parts: Array = []
	for w in widths:
		parts.append("-".repeat(int(w)))
	return "[color=%s]%s[/color]" % [_COLOR_MUTED, _COL_SEPARATOR.join(parts)]

func _color_cell(raw: String, aligned: String, align: String) -> String:
	if align == "right":
		return "[color=%s]%s[/color]" % [_COLOR_NUMBER, aligned]
	return aligned

func _render_csv(columns: Array, rows: Array) -> String:
	var cell_grid: Array = _build_cell_grid(columns, rows)
	var lines: Array = []
	lines.append(",".join(_csv_escape_row(columns)))
	for row_cells in cell_grid:
		lines.append(",".join(_csv_escape_row(row_cells)))
	return "\n".join(lines)

func _csv_escape_row(cells: Array) -> Array:
	var out: Array = []
	for cell in cells:
		out.append(_csv_escape(str(cell)))
	return out

func _csv_escape(s: String) -> String:
	if s.contains(",") or s.contains("\"") or s.contains("\n") or s.contains("\r"):
		return "\"%s\"" % s.replace("\"", "\"\"")
	return s

func _render_markdown(columns: Array, rows: Array) -> String:
	var cell_grid: Array = _build_cell_grid(columns, rows)
	var aligns: Array = _column_alignments(columns, rows)
	var widths: Array = _column_widths(columns, cell_grid)
	var lines: Array = []

	var header_cells: Array = []
	for j in range(columns.size()):
		header_cells.append(_md_pad(str(columns[j]), int(widths[j]), str(aligns[j])))
	lines.append("| " + " | ".join(header_cells) + " |")

	var separator_cells: Array = []
	for j in range(columns.size()):
		separator_cells.append(_md_separator(int(widths[j]), str(aligns[j])))
	lines.append("| " + " | ".join(separator_cells) + " |")

	for row_cells in cell_grid:
		var cells: Array = []
		for j in range(columns.size()):
			cells.append(_md_pad(str(row_cells[j]), int(widths[j]), str(aligns[j])))
		lines.append("| " + " | ".join(cells) + " |")
	return "\n".join(lines)

func _md_pad(raw: String, width: int, align: String) -> String:
	# Markdown rendering of literal `|` inside a cell would break the table, so
	# escape it. Width-padding here is purely cosmetic for the raw markdown
	# source; renderers ignore extra spaces.
	var escaped: String = _truncate(raw).replace("|", "\\|")
	if align == "right":
		return escaped.lpad(width)
	return escaped.rpad(width)

func _md_separator(width: int, align: String) -> String:
	var w: int = max(width, 3)
	if align == "right":
		return "-".repeat(w - 1) + ":"
	return "-".repeat(w)

#endregion

#region Layout helpers

func _build_cell_grid(columns: Array, rows: Array) -> Array:
	var grid: Array = []
	for row in rows:
		var row_cells: Array = []
		var d: Dictionary = row if row is Dictionary else {}
		for col in columns:
			var col_str: String = str(col)
			var value: Variant = d.get(col_str, "")
			row_cells.append(_truncate(_stringify_value(value)))
		grid.append(row_cells)
	return grid

func _column_widths(columns: Array, cell_grid: Array) -> Array:
	var widths: Array = []
	for j in range(columns.size()):
		var col_str: String = str(columns[j])
		var w: int = col_str.length()
		for row_cells in cell_grid:
			var cell_len: int = str(row_cells[j]).length()
			if cell_len > w:
				w = cell_len
		if w > _max_width:
			w = _max_width
		if w < _MIN_WIDTH:
			w = _MIN_WIDTH
		widths.append(w)
	return widths

func _column_alignments(columns: Array, rows: Array) -> Array:
	# A column is right-aligned when every non-empty cell in it parses as a
	# number; otherwise left-aligned. Booleans and nulls do not flip a column
	# to right-aligned.
	var aligns: Array = []
	for col in columns:
		var col_str: String = str(col)
		var any_value: bool = false
		var all_numeric: bool = true
		for row in rows:
			if not (row is Dictionary):
				continue
			var d: Dictionary = row
			if not d.has(col_str):
				continue
			var v: Variant = d[col_str]
			if v == null:
				continue
			any_value = true
			if not _is_numeric(v):
				all_numeric = false
				break
		aligns.append("right" if (any_value and all_numeric) else "left")
	return aligns

func _is_numeric(v: Variant) -> bool:
	if v is int or v is float:
		return true
	if v is bool:
		return false
	if v is String:
		var s: String = (v as String).strip_edges()
		if s.is_empty():
			return false
		return s.is_valid_int() or s.is_valid_float()
	return false

func _align_cell(raw: String, width: int, align: String) -> String:
	if align == "right":
		return raw.lpad(width)
	return raw.rpad(width)

func _truncate(s: String) -> String:
	if s.length() <= _max_width:
		return s
	if _max_width <= 3:
		return s.substr(0, _max_width)
	return s.substr(0, _max_width - 3) + "..."

func _stringify_value(v: Variant) -> String:
	if v == null:
		return ""
	if v is String:
		return v
	if v is bool:
		return "true" if v else "false"
	if v is float:
		# Keep floats compact but readable; %g drops trailing zeros without
		# turning small magnitudes into scientific notation for typical game
		# data ranges.
		return "%g" % v
	if v is int:
		return str(v)
	if v is Object:
		var obj: Object = v
		if not is_instance_valid(obj):
			return "<freed>"
		if obj is Node:
			var n: Node = obj
			if n.is_inside_tree():
				return str(n.get_path())
			return "<%s:%s>" % [n.get_class(), n.name]
		return "<%s>" % obj.get_class()
	if v is Array or v is Dictionary:
		var json_text: String = JSON.stringify(v)
		if json_text == "":
			return str(v)
		return json_text
	return str(v)

#endregion

#region Tree helpers

func _get_scene_root() -> Node:
	if Engine.is_editor_hint():
		return EditorInterface.get_edited_scene_root()
	var tree := Engine.get_main_loop() as SceneTree
	if not tree:
		return null
	if tree.current_scene:
		return tree.current_scene
	return tree.root

#endregion

#region Formatting helpers

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

#endregion

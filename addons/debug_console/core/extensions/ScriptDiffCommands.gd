@tool
class_name DebugConsoleScriptDiffCommands extends RefCounted

# Tier 6 extension - script diff/blame/history commands.
# Auto-loaded by BuiltInCommands.register_universal_commands via the
# extensions loader; the module instance is held alive in the shared
# _t6_keepalive static array on BuiltInCommands. Mirrors the shape of
# core/SceneCommands.gd (RefCounted, register_commands(registry, core)).
#
# History is session-scoped: kept on the live instance, lost on plugin
# reload, which matches the task spec ("in-memory history... from this
# session"). External callers (e.g. a future script_save command) can
# push entries via record_save(path).

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_DEL := "#FF6666"
const _COLOR_ADD := "#66FF66"
const _COLOR_HUNK := "#C586C0"
const _COLOR_DIM := "#888888"

const _CONTEXT_LINES := 3
const _MAX_HISTORY_PER_FILE := 50

var _registry: Node
var _core: Node

# path -> Array[{timestamp:int, mtime:int, size:int, content:String}]
var _history: Dictionary = {}

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("script_diff", _cmd_script_diff, "Unified diff of two files: script_diff <path_a> <path_b>", "both")
	_registry.register_command("script_diff_inline", _cmd_script_diff_inline, "Diff two paths read from piped input (one per line)", "both")
	_registry.register_command("script_diff_func", _cmd_script_diff_func, "Diff a single function: script_diff_func <path_a>.<func> <path_b>.<func>", "both")
	_registry.register_command("script_blame", _cmd_script_blame, "Report file mtime for a line (no git): script_blame <path> <line>", "both")
	_registry.register_command("script_history", _cmd_script_history, "List in-memory save history: script_history <path> [n]", "both")
	_registry.register_command("script_revert", _cmd_script_revert, "Restore a version from in-memory history: script_revert <path> <version_idx>", "both")

# Public hook so other modules (e.g. a future script_save command) can
# push a snapshot into this session's history without a circular import.
func record_save(path: String) -> bool:
	return _snapshot(path.strip_edges())

#region Command implementations

func _cmd_script_diff(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: script_diff <path_a> <path_b>")
	var path_a := _normalize_path(str(args[0]))
	var path_b := _normalize_path(str(args[1]))
	return _diff_files(path_a, path_b)

func _cmd_script_diff_inline(args: Array, piped_input: String = "") -> String:
	if piped_input.strip_edges().is_empty():
		return _format_error("script_diff_inline reads 2 file paths from piped input")
	var paths: Array[String] = []
	for raw in piped_input.split("\n", false):
		var line := str(raw).strip_edges()
		if line.is_empty():
			continue
		# Tolerate space-separated paths on a single line too.
		for token in line.split(" ", false):
			var t := str(token).strip_edges()
			if not t.is_empty():
				paths.append(t)
				if paths.size() >= 2:
					break
		if paths.size() >= 2:
			break
	if paths.size() < 2:
		return _format_error("Need 2 paths in piped input, got %d" % paths.size())
	return _diff_files(_normalize_path(paths[0]), _normalize_path(paths[1]))

func _cmd_script_diff_func(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: script_diff_func <path_a>.<func> <path_b>.<func>")
	var sel_a := _split_path_func(str(args[0]))
	var sel_b := _split_path_func(str(args[1]))
	if sel_a.is_empty():
		return _format_error("Selector must be <path>.<func>: %s" % str(args[0]))
	if sel_b.is_empty():
		return _format_error("Selector must be <path>.<func>: %s" % str(args[1]))

	var path_a := _normalize_path(sel_a[0])
	var path_b := _normalize_path(sel_b[0])
	var func_a: String = sel_a[1]
	var func_b: String = sel_b[1]

	var src_a: Variant = _read_file(path_a)
	if src_a == null:
		return _format_error("Cannot read: %s" % path_a)
	var src_b: Variant = _read_file(path_b)
	if src_b == null:
		return _format_error("Cannot read: %s" % path_b)

	var body_a := _extract_function(src_a, func_a)
	if body_a.is_empty():
		return _format_error("Function not found: %s in %s" % [func_a, path_a])
	var body_b := _extract_function(src_b, func_b)
	if body_b.is_empty():
		return _format_error("Function not found: %s in %s" % [func_b, path_b])

	var label_a := "%s::%s" % [path_a, func_a]
	var label_b := "%s::%s" % [path_b, func_b]
	return _build_diff(body_a, body_b, label_a, label_b)

func _cmd_script_blame(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: script_blame <path> <line>")
	var path := _normalize_path(str(args[0]))
	var line_str := str(args[1]).strip_edges()
	if not line_str.is_valid_int():
		return _format_error("Line must be an integer: %s" % line_str)
	var line_no: int = line_str.to_int()
	if line_no < 1:
		return _format_error("Line must be >= 1, got %d" % line_no)

	var abs_path := ProjectSettings.globalize_path(path) if path.begins_with("res://") else path
	if not FileAccess.file_exists(path):
		return _format_error("File not found: %s" % path)

	var src: Variant = _read_file(path)
	if src == null:
		return _format_error("Cannot read: %s" % path)
	var lines: PackedStringArray = str(src).split("\n", true)
	if line_no > lines.size():
		return _format_error("Line %d out of range (file has %d lines)" % [line_no, lines.size()])

	var mtime: int = FileAccess.get_modified_time(path)
	var fa := FileAccess.open(path, FileAccess.READ)
	var size_bytes: int = 0
	if fa:
		size_bytes = int(fa.get_length())
		fa.close()

	var out: Array[String] = []
	out.append("%s %s:%s" % [_color_dim("blame"), _color_path(path), _color_number(str(line_no))])
	out.append("  %s %s" % [_color_dim("mtime:"), _color_number(_format_timestamp(mtime))])
	out.append("  %s %s bytes  %s %s" % [
		_color_dim("size:"), _color_number(str(size_bytes)),
		_color_dim("abs:"), _color_dim(abs_path),
	])
	out.append("  %s %s" % [_color_dim("line:"), _escape_bbcode(lines[line_no - 1])])
	out.append(_color_dim("  (git blame unavailable in console; reporting file mtime)"))
	return "\n".join(out)

func _cmd_script_history(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: script_history <path> [n]")
	var path := _normalize_path(str(args[0]))
	var n: int = 10
	if args.size() > 1:
		var n_str := str(args[1]).strip_edges()
		if n_str.is_valid_int():
			n = max(1, n_str.to_int())

	# Opportunistic snapshot so the listing reflects the current on-disk
	# state even when no save hook has fired yet this session.
	_snapshot(path)

	var entries: Array = _history.get(path, []) as Array
	if entries.is_empty():
		return _format_error("No history for %s" % path)

	var total: int = entries.size()
	var shown: int = min(n, total)
	var out: Array[String] = []
	out.append("%s for %s  (showing %s of %s)" % [
		_color_dim("history"), _color_path(path),
		_color_number(str(shown)), _color_number(str(total)),
	])
	# Newest first; index 1 = newest, matches script_revert <idx>.
	for i in range(total - 1, max(-1, total - 1 - shown), -1):
		var entry: Dictionary = entries[i]
		var idx: int = total - i
		out.append("  %s %s  %s %s bytes  mtime %s" % [
			_color_number("#" + str(idx)),
			_format_timestamp(int(entry.get("timestamp", 0))),
			_color_dim("size"), _color_number(str(int(entry.get("size", 0)))),
			_format_timestamp(int(entry.get("mtime", 0))),
		])
	return "\n".join(out)

func _cmd_script_revert(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: script_revert <path> <version_idx>")
	var path := _normalize_path(str(args[0]))
	var idx_str := str(args[1]).strip_edges()
	if not idx_str.is_valid_int():
		return _format_error("version_idx must be an integer: %s" % idx_str)
	var idx: int = idx_str.to_int()
	if idx < 1:
		return _format_error("version_idx is 1-based (1 = most recent), got %d" % idx)

	var entries: Array = _history.get(path, []) as Array
	if entries.is_empty():
		return _format_error("No history for %s" % path)
	if idx > entries.size():
		return _format_error("version_idx %d > history size %d" % [idx, entries.size()])

	# Resolve the target FIRST against the existing list so the index the
	# user saw in `script_history` is the one we restore, even if a
	# pre-revert snapshot grows the list.
	var target_pos: int = entries.size() - idx
	var entry: Dictionary = entries[target_pos]
	var content: String = str(entry.get("content", ""))

	# Snapshot current on-disk state (if changed) so the revert is undoable.
	_snapshot(path)

	var fa := FileAccess.open(path, FileAccess.WRITE)
	if not fa:
		var err := FileAccess.get_open_error()
		return _format_error("Cannot write %s (error %d)" % [path, err])
	fa.store_string(content)
	fa.close()

	# Record the reverted content as a new history entry so we don't
	# silently drop the round-trip from the log.
	_snapshot(path)

	return _format_success("Reverted %s to #%s  (%s bytes, saved %s)" % [
		_color_path(path), _color_number(str(idx)),
		_color_number(str(content.length())),
		_format_timestamp(int(entry.get("timestamp", 0))),
	])

#endregion

#region Diff core

func _diff_files(path_a: String, path_b: String) -> String:
	var src_a: Variant = _read_file(path_a)
	if src_a == null:
		return _format_error("Cannot read: %s" % path_a)
	var src_b: Variant = _read_file(path_b)
	if src_b == null:
		return _format_error("Cannot read: %s" % path_b)
	return _build_diff(src_a, src_b, path_a, path_b)

func _build_diff(src_a: String, src_b: String, label_a: String, label_b: String) -> String:
	var a_lines: PackedStringArray = src_a.split("\n", true)
	var b_lines: PackedStringArray = src_b.split("\n", true)
	# Strip the trailing empty element that split() leaves when the file
	# ends in "\n", so length matches the number of "real" lines.
	if a_lines.size() > 0 and a_lines[a_lines.size() - 1] == "":
		a_lines.remove_at(a_lines.size() - 1)
	if b_lines.size() > 0 and b_lines[b_lines.size() - 1] == "":
		b_lines.remove_at(b_lines.size() - 1)

	var ops: Array = _diff_ops(a_lines, b_lines)

	var header: String = "%s %s\n%s %s" % [
		_color_dim("---"), _color_path("a/" + label_a),
		_color_dim("+++"), _color_path("b/" + label_b),
	]
	if a_lines.size() == b_lines.size():
		var identical: bool = true
		for i in range(a_lines.size()):
			if a_lines[i] != b_lines[i]:
				identical = false
				break
		if identical:
			return "%s\n%s" % [header, _color_dim("(files are identical)")]

	var hunks: Array = _group_hunks(ops, a_lines.size(), b_lines.size())
	if hunks.is_empty():
		return "%s\n%s" % [header, _color_dim("(no textual differences)")]

	var out: Array[String] = [header]
	for hunk in hunks:
		out.append(_render_hunk(hunk))
	return "\n".join(out)

# Returns array of dicts {op:"eq"|"add"|"del", text:String}, in order.
func _diff_ops(a: PackedStringArray, b: PackedStringArray) -> Array:
	var m: int = a.size()
	var n: int = b.size()
	# LCS DP table. Use nested Array (not PackedInt32Array) so chained
	# subscript assignment `dp[i][j] = x` is reliable in GDScript 4.
	var dp: Array = []
	dp.resize(m + 1)
	for i in range(m + 1):
		var row: Array = []
		row.resize(n + 1)
		for j in range(n + 1):
			row[j] = 0
		dp[i] = row
	for i in range(m):
		var row_i: Array = dp[i]
		var row_next: Array = dp[i + 1]
		for j in range(n):
			if a[i] == b[j]:
				row_next[j + 1] = int(row_i[j]) + 1
			else:
				var up: int = int(row_i[j + 1])
				var left: int = int(row_next[j])
				row_next[j + 1] = up if up >= left else left

	var ops_reversed: Array = []
	var i: int = m
	var j: int = n
	while i > 0 and j > 0:
		if a[i - 1] == b[j - 1]:
			ops_reversed.append({"op": "eq", "text": a[i - 1]})
			i -= 1
			j -= 1
		elif dp[i][j - 1] >= dp[i - 1][j]:
			ops_reversed.append({"op": "add", "text": b[j - 1]})
			j -= 1
		else:
			ops_reversed.append({"op": "del", "text": a[i - 1]})
			i -= 1
	while i > 0:
		ops_reversed.append({"op": "del", "text": a[i - 1]})
		i -= 1
	while j > 0:
		ops_reversed.append({"op": "add", "text": b[j - 1]})
		j -= 1
	ops_reversed.reverse()
	return ops_reversed

# Groups ops into hunks separated by long runs of context. Each hunk is
# {a_start:int, a_count:int, b_start:int, b_count:int, lines:Array[op]}
# with 1-based start indices, matching unified-diff convention.
func _group_hunks(ops: Array, _total_a: int, _total_b: int) -> Array:
	var hunks: Array = []
	if ops.is_empty():
		return hunks

	# First pass: find indices into `ops` that are "interesting" (add/del).
	var change_indices: Array[int] = []
	for k in range(ops.size()):
		if ops[k].op != "eq":
			change_indices.append(k)
	if change_indices.is_empty():
		return hunks

	# Cluster change indices that are within 2 * _CONTEXT_LINES of each other.
	var clusters: Array = []
	var cur_lo: int = change_indices[0]
	var cur_hi: int = change_indices[0]
	for k in range(1, change_indices.size()):
		var ci: int = change_indices[k]
		if ci - cur_hi <= 2 * _CONTEXT_LINES:
			cur_hi = ci
		else:
			clusters.append([cur_lo, cur_hi])
			cur_lo = ci
			cur_hi = ci
	clusters.append([cur_lo, cur_hi])

	# Convert each cluster into a hunk with context.
	for cluster in clusters:
		var lo: int = max(0, int(cluster[0]) - _CONTEXT_LINES)
		var hi: int = min(ops.size() - 1, int(cluster[1]) + _CONTEXT_LINES)
		var a_start: int = 0
		var b_start: int = 0
		# Count a/b indices that precede `lo`.
		for k in range(lo):
			match ops[k].op:
				"eq":
					a_start += 1
					b_start += 1
				"del":
					a_start += 1
				"add":
					b_start += 1
		var a_count: int = 0
		var b_count: int = 0
		var lines: Array = []
		for k in range(lo, hi + 1):
			lines.append(ops[k])
			match ops[k].op:
				"eq":
					a_count += 1
					b_count += 1
				"del":
					a_count += 1
				"add":
					b_count += 1
		hunks.append({
			"a_start": a_start + 1,
			"a_count": a_count,
			"b_start": b_start + 1,
			"b_count": b_count,
			"lines": lines,
		})
	return hunks

func _render_hunk(hunk: Dictionary) -> String:
	var header: String = "[color=%s]@@ -%d,%d +%d,%d @@[/color]" % [
		_COLOR_HUNK, int(hunk.a_start), int(hunk.a_count),
		int(hunk.b_start), int(hunk.b_count),
	]
	var out: Array[String] = [header]
	for entry in hunk.lines:
		var text: String = _escape_bbcode(str(entry.text))
		match entry.op:
			"del":
				out.append("[color=%s]- %s[/color]" % [_COLOR_DEL, text])
			"add":
				out.append("[color=%s]+ %s[/color]" % [_COLOR_ADD, text])
			_:
				out.append("  " + text)
	return "\n".join(out)

#endregion

#region Helpers

func _read_file(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	var fa := FileAccess.open(path, FileAccess.READ)
	if not fa:
		return null
	var text := fa.get_as_text()
	fa.close()
	return text

func _snapshot(path: String) -> bool:
	if path.is_empty() or not FileAccess.file_exists(path):
		return false
	var content: Variant = _read_file(path)
	if content == null:
		return false
	var entries: Array = _history.get(path, []) as Array
	if not entries.is_empty():
		var last: Dictionary = entries[entries.size() - 1]
		if str(last.get("content", "")) == content:
			return false
	var mtime: int = FileAccess.get_modified_time(path)
	var text: String = content
	entries.append({
		"timestamp": int(Time.get_unix_time_from_system()),
		"mtime": mtime,
		"size": text.length(),
		"content": text,
	})
	while entries.size() > _MAX_HISTORY_PER_FILE:
		entries.remove_at(0)
	_history[path] = entries
	return true

func _split_path_func(selector: String) -> Array:
	var s := selector.strip_edges()
	var idx := s.rfind(".")
	if idx <= 0 or idx >= s.length() - 1:
		return []
	var path_part: String = s.substr(0, idx)
	var func_part: String = s.substr(idx + 1)
	# Reject if the right side looks like a file extension (e.g. ".gd")
	# instead of a function name.
	if func_part == "gd" or func_part == "tres" or func_part == "tscn":
		return []
	return [path_part, func_part]

# Returns the function body (header + indented body) as a single string,
# or empty string if the function isn't found at file scope.
func _extract_function(src: String, func_name: String) -> String:
	var lines: PackedStringArray = src.split("\n", true)
	var start: int = -1
	for i in range(lines.size()):
		var stripped := lines[i].strip_edges()
		# Tolerate `static func` and decorator prefixes like `@rpc func`.
		var func_idx := stripped.find("func ")
		if func_idx < 0:
			continue
		# Only treat it as a definition if everything before `func` is
		# decorators / modifiers (no parens, no `=`, no `.`).
		var prefix := stripped.substr(0, func_idx).strip_edges()
		if prefix.contains("(") or prefix.contains("=") or prefix.contains("."):
			continue
		var after := stripped.substr(func_idx + 5).strip_edges()
		var paren := after.find("(")
		if paren > 0 and after.substr(0, paren).strip_edges() == func_name:
			start = i
			break
	if start < 0:
		return ""

	var end: int = lines.size()
	for j in range(start + 1, lines.size()):
		var line: String = lines[j]
		if line.strip_edges().is_empty():
			continue
		# Next top-level declaration (no leading whitespace) ends the body.
		if not (line.begins_with("\t") or line.begins_with(" ")):
			end = j
			break

	var body: PackedStringArray = PackedStringArray()
	for k in range(start, end):
		body.append(lines[k])
	return "\n".join(body)

func _normalize_path(raw: String) -> String:
	var p := raw.strip_edges()
	# Strip wrapping quotes so users can paste paths with spaces.
	if (p.begins_with("\"") and p.ends_with("\"")) or (p.begins_with("'") and p.ends_with("'")):
		if p.length() >= 2:
			p = p.substr(1, p.length() - 2)
	return p

func _format_timestamp(unix_ts: int) -> String:
	if unix_ts <= 0:
		return "<none>"
	var dt: Dictionary = Time.get_datetime_dict_from_unix_time(unix_ts)
	return "%04d-%02d-%02d %02d:%02d:%02d" % [
		int(dt.get("year", 0)), int(dt.get("month", 0)), int(dt.get("day", 0)),
		int(dt.get("hour", 0)), int(dt.get("minute", 0)), int(dt.get("second", 0)),
	]

# BBCode-escape so source-code brackets don't get parsed as tags by the
# console RichTextLabel.
func _escape_bbcode(s: String) -> String:
	return s.replace("[", "[lb]")

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

func _color_dim(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_DIM, s]

#endregion

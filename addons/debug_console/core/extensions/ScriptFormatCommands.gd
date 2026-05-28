@tool
class_name DebugConsoleScriptFormatCommands extends RefCounted

# GDScript source-formatting commands. Follows the standard extension shape
# documented in addons/debug_console/core/extensions/README.md: a RefCounted
# with register_commands(registry, core), kept alive by BuiltInCommands.
#
# All six commands operate on plain .gd files via FileAccess. Mutating
# commands (fmt_tabs, fmt_strip_trailing, fmt_blanks, fmt_dir) write only
# when the transform actually changes the file. fmt_check and fmt_diff are
# read-only; they report what fmt_dir would do.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_DIFF_ADD := "#A0E0A0"
const _COLOR_DIFF_DEL := "#FF8888"
const _COLOR_INFO := "#C0C0C0"

const _TAB_WIDTH := 4
const _DIFF_PREVIEW_LIMIT := 30

var _registry: Node
var _core: Node

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("fmt_tabs", _cmd_fmt_tabs, "Convert leading spaces to tabs (GDScript convention): fmt_tabs <path>", "both")
	_registry.register_command("fmt_strip_trailing", _cmd_fmt_strip_trailing, "Remove trailing whitespace on every line: fmt_strip_trailing <path>", "both")
	_registry.register_command("fmt_blanks", _cmd_fmt_blanks, "Collapse 3+ consecutive blank lines to 1: fmt_blanks <path>", "both")
	_registry.register_command("fmt_check", _cmd_fmt_check, "Report formatting violations without modifying: fmt_check <path>", "both")
	_registry.register_command("fmt_dir", _cmd_fmt_dir, "Apply tabs+strip+blanks to all .gd files (recursive): fmt_dir <res://dir>", "both")
	_registry.register_command("fmt_diff", _cmd_fmt_diff, "Show what fmt_dir would change without applying: fmt_diff <path>", "both")

#region Command implementations

func _cmd_fmt_tabs(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: fmt_tabs <path>")
	var path := _normalize_path(str(args[0]))
	var src: Variant = _read_file(path)
	if src == null:
		return _format_error("Cannot read: %s" % path)
	var result := _apply_tabs(src)
	if not result.changed:
		return _format_success("fmt_tabs %s - already tab-indented (%s lines)" % [_color_path(path), _color_number(str(result.line_count))])
	if not _write_file(path, result.text):
		return _format_error("Cannot write: %s" % path)
	return _format_success("fmt_tabs %s - converted leading spaces on %s line(s)" % [_color_path(path), _color_number(str(result.changes))])

func _cmd_fmt_strip_trailing(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: fmt_strip_trailing <path>")
	var path := _normalize_path(str(args[0]))
	var src: Variant = _read_file(path)
	if src == null:
		return _format_error("Cannot read: %s" % path)
	var result := _apply_strip_trailing(src)
	if not result.changed:
		return _format_success("fmt_strip_trailing %s - no trailing whitespace (%s lines)" % [_color_path(path), _color_number(str(result.line_count))])
	if not _write_file(path, result.text):
		return _format_error("Cannot write: %s" % path)
	return _format_success("fmt_strip_trailing %s - stripped %s line(s)" % [_color_path(path), _color_number(str(result.changes))])

func _cmd_fmt_blanks(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: fmt_blanks <path>")
	var path := _normalize_path(str(args[0]))
	var src: Variant = _read_file(path)
	if src == null:
		return _format_error("Cannot read: %s" % path)
	var result := _apply_blanks(src)
	if not result.changed:
		return _format_success("fmt_blanks %s - no runs of 3+ blank lines" % _color_path(path))
	if not _write_file(path, result.text):
		return _format_error("Cannot write: %s" % path)
	return _format_success("fmt_blanks %s - collapsed %s blank-line run(s), removed %s line(s)" % [_color_path(path), _color_number(str(result.runs)), _color_number(str(result.removed))])

func _cmd_fmt_check(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: fmt_check <path>")
	var path := _normalize_path(str(args[0]))
	var src: Variant = _read_file(path)
	if src == null:
		return _format_error("Cannot read: %s" % path)
	return _build_report(path, src, "violations")

func _cmd_fmt_dir(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: fmt_dir <res://dir>")
	var dir_path := _normalize_path(str(args[0]))
	if not DirAccess.dir_exists_absolute(dir_path):
		return _format_error("Directory not found: %s" % dir_path)
	var files: Array[String] = []
	_collect_gd_files(dir_path, files)
	if files.is_empty():
		return _format_success("fmt_dir %s - no .gd files found" % _color_path(dir_path))
	var modified := 0
	var skipped := 0
	var failed: Array[String] = []
	var total_tab_lines := 0
	var total_strip_lines := 0
	var total_blank_runs := 0
	for f in files:
		var src: Variant = _read_file(f)
		if src == null:
			failed.append(f)
			continue
		var step1 := _apply_tabs(src)
		var step2 := _apply_strip_trailing(step1.text)
		var step3 := _apply_blanks(step2.text)
		var any_change: bool = bool(step1.changed) or bool(step2.changed) or bool(step3.changed)
		if not any_change:
			skipped += 1
			continue
		if not _write_file(f, step3.text):
			failed.append(f)
			continue
		modified += 1
		total_tab_lines += int(step1.changes)
		total_strip_lines += int(step2.changes)
		total_blank_runs += int(step3.runs)
	var lines: Array[String] = []
	lines.append(_format_success("fmt_dir %s" % _color_path(dir_path)))
	lines.append("  scanned: %s file(s)" % _color_number(str(files.size())))
	lines.append("  modified: %s, unchanged: %s, failed: %s" % [_color_number(str(modified)), _color_number(str(skipped)), _color_number(str(failed.size()))])
	lines.append("  totals: tabs=%s line(s), strip=%s line(s), blanks=%s run(s)" % [_color_number(str(total_tab_lines)), _color_number(str(total_strip_lines)), _color_number(str(total_blank_runs))])
	if not failed.is_empty():
		lines.append("[color=%s]Failed:[/color]" % _COLOR_ERROR)
		var shown := 0
		for f in failed:
			lines.append("  %s" % _color_path(f))
			shown += 1
			if shown >= 20:
				lines.append("  ... and %s more" % (failed.size() - shown))
				break
	return "\n".join(lines)

func _cmd_fmt_diff(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: fmt_diff <path>")
	var path := _normalize_path(str(args[0]))
	var src: Variant = _read_file(path)
	if src == null:
		return _format_error("Cannot read: %s" % path)
	return _build_report(path, src, "diff")

#endregion

#region Transforms

func _apply_tabs(src: String) -> Dictionary:
	var lines: PackedStringArray = src.split("\n", true)
	var changes := 0
	for i in range(lines.size()):
		var converted := _convert_leading_to_tabs(lines[i])
		if converted != lines[i]:
			lines[i] = converted
			changes += 1
	var text := "\n".join(lines)
	return {"text": text, "changed": changes > 0, "changes": changes, "line_count": lines.size()}

func _apply_strip_trailing(src: String) -> Dictionary:
	var lines: PackedStringArray = src.split("\n", true)
	var changes := 0
	for i in range(lines.size()):
		var stripped := _strip_trailing(lines[i])
		if stripped != lines[i]:
			lines[i] = stripped
			changes += 1
	var text := "\n".join(lines)
	return {"text": text, "changed": changes > 0, "changes": changes, "line_count": lines.size()}

func _apply_blanks(src: String) -> Dictionary:
	var lines: PackedStringArray = src.split("\n", true)
	var out: Array[String] = []
	var run := 0
	var runs := 0
	var removed := 0
	for line in lines:
		var is_blank := line.strip_edges().is_empty()
		if is_blank:
			run += 1
			if run <= 1:
				out.append(line)
			else:
				removed += 1
		else:
			if run >= 3:
				runs += 1
			run = 0
			out.append(line)
	if run >= 3:
		runs += 1
	var text := "\n".join(PackedStringArray(out))
	return {"text": text, "changed": removed > 0, "runs": runs, "removed": removed, "line_count": out.size()}

func _convert_leading_to_tabs(line: String) -> String:
	var i := 0
	var col := 0
	var n := line.length()
	while i < n:
		var ch := line.unicode_at(i)
		if ch == 9:
			col += _TAB_WIDTH - (col % _TAB_WIDTH)
			i += 1
		elif ch == 32:
			col += 1
			i += 1
		else:
			break
	if i == 0:
		return line
	var rest := line.substr(i)
	var tabs := col / _TAB_WIDTH
	var spaces := col % _TAB_WIDTH
	var lead := ""
	for _t in range(tabs):
		lead += "\t"
	for _s in range(spaces):
		lead += " "
	return lead + rest

func _strip_trailing(line: String) -> String:
	var i := line.length() - 1
	while i >= 0:
		var ch := line.unicode_at(i)
		if ch == 32 or ch == 9:
			i -= 1
		else:
			break
	if i == line.length() - 1:
		return line
	return line.substr(0, i + 1)

#endregion

#region Reporting (fmt_check / fmt_diff)

func _build_report(path: String, src: String, mode: String) -> String:
	var lines: PackedStringArray = src.split("\n", true)
	var tab_changes: Array[int] = []
	var strip_changes: Array[int] = []
	for i in range(lines.size()):
		var line := lines[i]
		if _convert_leading_to_tabs(line) != line:
			tab_changes.append(i + 1)
		if _strip_trailing(line) != line:
			strip_changes.append(i + 1)
	var blank_runs: Array = _scan_blank_runs(lines)
	var total_runs_to_collapse := 0
	for r in blank_runs:
		if int(r.count) >= 3:
			total_runs_to_collapse += 1
	var header_label := "violations" if mode == "violations" else "would change"
	var out: Array[String] = []
	if tab_changes.is_empty() and strip_changes.is_empty() and total_runs_to_collapse == 0:
		return _format_success("%s %s - clean (%s lines)" % [
			"fmt_check" if mode == "violations" else "fmt_diff",
			_color_path(path),
			_color_number(str(lines.size())),
		])
	out.append(_format_success("%s %s - %s:" % [
		"fmt_check" if mode == "violations" else "fmt_diff",
		_color_path(path),
		header_label,
	]))
	if not tab_changes.is_empty():
		out.append("  tabs: %s line(s) %s" % [_color_number(str(tab_changes.size())), _summarize_line_numbers(tab_changes)])
	if not strip_changes.is_empty():
		out.append("  strip: %s line(s) %s" % [_color_number(str(strip_changes.size())), _summarize_line_numbers(strip_changes)])
	if total_runs_to_collapse > 0:
		out.append("  blanks: %s run(s) of 3+ to collapse" % _color_number(str(total_runs_to_collapse)))
		var shown := 0
		for r in blank_runs:
			if int(r.count) < 3:
				continue
			out.append("    lines %s-%s (%s→1)" % [
				_color_number(str(r.start)),
				_color_number(str(r.start + int(r.count) - 1)),
				_color_number(str(r.count)),
			])
			shown += 1
			if shown >= 10:
				out.append("    ... and %s more" % (total_runs_to_collapse - shown))
				break
	if mode == "diff":
		out.append_array(_build_inline_diff_preview(lines, tab_changes, strip_changes))
	return "\n".join(out)

func _scan_blank_runs(lines: PackedStringArray) -> Array:
	var runs: Array = []
	var run_start := -1
	var run_count := 0
	for i in range(lines.size()):
		if lines[i].strip_edges().is_empty():
			if run_start == -1:
				run_start = i + 1
				run_count = 1
			else:
				run_count += 1
		else:
			if run_start != -1:
				runs.append({"start": run_start, "count": run_count})
				run_start = -1
				run_count = 0
	if run_start != -1:
		runs.append({"start": run_start, "count": run_count})
	return runs

func _build_inline_diff_preview(lines: PackedStringArray, tab_changes: Array[int], strip_changes: Array[int]) -> Array[String]:
	var changed_set := {}
	for n in tab_changes:
		changed_set[n] = true
	for n in strip_changes:
		changed_set[n] = true
	var sorted_nums: Array = changed_set.keys()
	sorted_nums.sort()
	var out: Array[String] = []
	if sorted_nums.is_empty():
		return out
	out.append("  diff (first %s line(s)):" % _color_number(str(min(_DIFF_PREVIEW_LIMIT, sorted_nums.size()))))
	var shown := 0
	for num in sorted_nums:
		if shown >= _DIFF_PREVIEW_LIMIT:
			out.append("    ... and %s more" % (sorted_nums.size() - shown))
			break
		var idx: int = int(num) - 1
		var before := lines[idx]
		var after := _strip_trailing(_convert_leading_to_tabs(before))
		out.append("    [color=%s]L%s -[/color] %s" % [_COLOR_DIFF_DEL, str(num), _visualize_whitespace(before)])
		out.append("    [color=%s]L%s +[/color] %s" % [_COLOR_DIFF_ADD, str(num), _visualize_whitespace(after)])
		shown += 1
	return out

func _summarize_line_numbers(nums: Array[int]) -> String:
	if nums.size() <= 8:
		var parts: Array[String] = []
		for n in nums:
			parts.append(str(n))
		return "(%s)" % ", ".join(parts)
	var first_parts: Array[String] = []
	for k in range(5):
		first_parts.append(str(nums[k]))
	return "(%s, ... %s more)" % [", ".join(first_parts), nums.size() - 5]

func _visualize_whitespace(line: String) -> String:
	var out := ""
	var n := line.length()
	var seen_non_ws := false
	for i in range(n):
		var ch := line.unicode_at(i)
		if not seen_non_ws and ch == 9:
			out += "→   "
		elif not seen_non_ws and ch == 32:
			out += "·"
		else:
			seen_non_ws = seen_non_ws or (ch != 9 and ch != 32)
			out += line.substr(i, 1)
	return out

#endregion

#region File IO + helpers

func _normalize_path(raw: String) -> String:
	var p := raw.strip_edges()
	if p.is_empty():
		return p
	if p.begins_with("res://") or p.begins_with("user://"):
		return p
	if p.begins_with("/") or (p.length() >= 2 and p[1] == ":"):
		return p
	return "res://" + p

func _read_file(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if not f:
		return null
	var text := f.get_as_text()
	f.close()
	return text

func _write_file(path: String, text: String) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if not f:
		return false
	f.store_string(text)
	f.close()
	return true

func _collect_gd_files(dir_path: String, out: Array[String]) -> void:
	var d := DirAccess.open(dir_path)
	if not d:
		return
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		if name == "." or name == "..":
			name = d.get_next()
			continue
		var full := dir_path.trim_suffix("/") + "/" + name
		if d.current_is_dir():
			_collect_gd_files(full, out)
		elif name.ends_with(".gd"):
			out.append(full)
		name = d.get_next()
	d.list_dir_end()

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

#endregion

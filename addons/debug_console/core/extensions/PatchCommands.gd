@tool
class_name DebugConsolePatchCommands extends RefCounted

# Unified-diff patch application commands. Lets the user receive a patch from
# an external source (LLM output, web, file on disk) and apply, preview, or
# revert it against a .gd file. Also generates patches between two files.
#
# Ships separately from BuiltInCommands.gd to keep that file manageable as the
# command surface grows. The orchestrator instantiates one of these, holds a
# strong reference, and calls register_commands(registry, core). All commands
# route through the strong-referenced instance so their Callables stay valid
# for the lifetime of the plugin.
#
# The parser is permissive: it ignores `--- a/...`, `+++ b/...`, "\ No newline
# at end of file" markers, and any text outside `@@` hunks. Hunks are applied
# by walking the source from the hunk's old_start, verifying that context and
# removed lines match exactly, then emitting context and added lines. Revert
# mode swaps + and -, and anchors at new_start instead of old_start.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"

const _CONTEXT_LINES := 3
const _PREVIEW_MAX_LINES := 20
const _SNIPPET_MAX_CHARS := 60

var _registry: Node
var _core: Node

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("patch_apply", _cmd_patch_apply, "Apply a unified-diff patch to a file: patch_apply <res://target.gd> <user://patch.diff>", "both")
	_registry.register_command("patch_preview", _cmd_patch_preview, "Show what a patch would change without writing: patch_preview <target> <patch>", "both")
	_registry.register_command("patch_revert", _cmd_patch_revert, "Reverse a previously applied patch: patch_revert <target> <patch>", "both")
	_registry.register_command("patch_make", _cmd_patch_make, "Generate a unified diff between two files: patch_make <a.gd> <b.gd> <user://out.diff>", "both")
	_registry.register_command("patch_pipe", _cmd_patch_pipe, "Apply a patch read from piped input: patch_pipe <target>", "both")

#region Command implementations

func _cmd_patch_apply(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: patch_apply <res://target.gd> <user://patch.diff>")
	var target_path := str(args[0]).strip_edges()
	var patch_path := str(args[1]).strip_edges()
	if not FileAccess.file_exists(target_path):
		return _format_error("Target not found: %s" % target_path)
	if not FileAccess.file_exists(patch_path):
		return _format_error("Patch not found: %s" % patch_path)
	var target_text := _read_text(target_path)
	var patch_text := _read_text(patch_path)
	return _apply_patch_to(target_path, target_text, patch_text, false)

func _cmd_patch_preview(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: patch_preview <target> <patch>")
	var target_path := str(args[0]).strip_edges()
	var patch_path := str(args[1]).strip_edges()
	if not FileAccess.file_exists(target_path):
		return _format_error("Target not found: %s" % target_path)
	if not FileAccess.file_exists(patch_path):
		return _format_error("Patch not found: %s" % patch_path)
	var target_text := _read_text(target_path)
	var patch_text := _read_text(patch_path)
	var hunks := _parse_unified_diff(patch_text)
	if hunks.is_empty():
		return _format_error("No hunks parsed from patch")
	var result := _apply_hunks(target_text, hunks, false)
	if not bool(result.get("ok", false)):
		return _format_error(str(result.get("error", "apply failed")))
	var header := "[color=%s]Preview[/color] %s: %s hunks, +%s/-%s lines (not written)" % [
		_COLOR_SUCCESS,
		_color_path(target_path),
		_color_number(str(hunks.size())),
		_color_number(str(result.get("added", 0))),
		_color_number(str(result.get("removed", 0))),
	]
	return header + "\n" + _render_preview(target_text, str(result.get("text", "")))

func _cmd_patch_revert(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: patch_revert <target> <patch>")
	var target_path := str(args[0]).strip_edges()
	var patch_path := str(args[1]).strip_edges()
	if not FileAccess.file_exists(target_path):
		return _format_error("Target not found: %s" % target_path)
	if not FileAccess.file_exists(patch_path):
		return _format_error("Patch not found: %s" % patch_path)
	var target_text := _read_text(target_path)
	var patch_text := _read_text(patch_path)
	return _apply_patch_to(target_path, target_text, patch_text, true)

func _cmd_patch_make(args: Array, piped_input: String = "") -> String:
	if args.size() < 3:
		return _format_error("Usage: patch_make <a.gd> <b.gd> <user://out.diff>")
	var a_path := str(args[0]).strip_edges()
	var b_path := str(args[1]).strip_edges()
	var out_path := str(args[2]).strip_edges()
	if not FileAccess.file_exists(a_path):
		return _format_error("File a not found: %s" % a_path)
	if not FileAccess.file_exists(b_path):
		return _format_error("File b not found: %s" % b_path)
	var a_text := _read_text(a_path)
	var b_text := _read_text(b_path)
	var diff := _make_unified_diff(a_path, b_path, a_text, b_text)
	if not _write_text(out_path, diff):
		return _format_error("Failed to write: %s" % out_path)
	var hunk_count := diff.count("@@") / 2
	return _format_success("Wrote diff %s (%s hunks, %s bytes)" % [
		_color_path(out_path),
		_color_number(str(hunk_count)),
		_color_number(str(diff.length())),
	])

func _cmd_patch_pipe(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: patch_pipe <target> (with diff on stdin)")
	if piped_input.strip_edges().is_empty():
		return _format_error("patch_pipe requires piped diff input")
	var target_path := str(args[0]).strip_edges()
	if not FileAccess.file_exists(target_path):
		return _format_error("Target not found: %s" % target_path)
	var target_text := _read_text(target_path)
	return _apply_patch_to(target_path, target_text, piped_input, false)

#endregion
#region Patch engine

func _apply_patch_to(target_path: String, target_text: String, patch_text: String, reverse: bool) -> String:
	var hunks := _parse_unified_diff(patch_text)
	if hunks.is_empty():
		return _format_error("No hunks parsed from patch")
	var result := _apply_hunks(target_text, hunks, reverse)
	if not bool(result.get("ok", false)):
		return _format_error(str(result.get("error", "apply failed")))
	var new_text := str(result.get("text", ""))
	if not _write_text(target_path, new_text):
		return _format_error("Failed to write: %s" % target_path)
	var verb := "Reverted" if reverse else "Applied"
	return _format_success("%s %s hunks to %s (+%s/-%s)" % [
		verb,
		_color_number(str(hunks.size())),
		_color_path(target_path),
		_color_number(str(result.get("added", 0))),
		_color_number(str(result.get("removed", 0))),
	])

# Parse unified diff into an array of hunks.
# Hunk shape: { old_start, old_count, new_start, new_count, lines: Array[String] }
func _parse_unified_diff(text: String) -> Array:
	var hunks: Array = []
	var lines := text.split("\n")
	var i := 0
	var n := lines.size()
	while i < n:
		var line := str(lines[i])
		if line.begins_with("@@"):
			var hunk := _parse_hunk_header(line)
			if hunk.is_empty():
				i += 1
				continue
			i += 1
			var collected: Array = []
			while i < n:
				var l := str(lines[i])
				if l.begins_with("@@") or l.begins_with("--- ") or l.begins_with("+++ "):
					break
				if l.begins_with("\\"):
					# "\ No newline at end of file" markers - ignore.
					i += 1
					continue
				if l.begins_with(" ") or l.begins_with("+") or l.begins_with("-"):
					collected.append(l)
				elif l.is_empty():
					# An empty line inside a hunk is treated as an empty context line.
					collected.append(" ")
				else:
					break
				i += 1
			hunk["lines"] = collected
			hunks.append(hunk)
		else:
			i += 1
	return hunks

# Parse "@@ -old_start,old_count +new_start,new_count @@" header. Counts default
# to 1 if omitted, matching the unified-diff spec.
func _parse_hunk_header(line: String) -> Dictionary:
	var regex := RegEx.new()
	regex.compile("^@@ -([0-9]+)(?:,([0-9]+))? \\+([0-9]+)(?:,([0-9]+))? @@")
	var m := regex.search(line)
	if m == null:
		return {}
	var oc_str := m.get_string(2)
	var nc_str := m.get_string(4)
	return {
		"old_start": int(m.get_string(1)),
		"old_count": 1 if oc_str.is_empty() else int(oc_str),
		"new_start": int(m.get_string(3)),
		"new_count": 1 if nc_str.is_empty() else int(nc_str),
	}

# Apply hunks (or reverse them) to source_text. Returns
# { ok: bool, text: String, added: int, removed: int, error: String }.
func _apply_hunks(source_text: String, hunks: Array, reverse: bool) -> Dictionary:
	var src_lines: Array = Array(source_text.split("\n"))
	var trailing_newline := source_text.ends_with("\n")
	if trailing_newline and src_lines.size() > 0 and str(src_lines[-1]).is_empty():
		src_lines.pop_back()
	var out: Array = []
	var src_index := 0
	var added := 0
	var removed := 0
	var anchor_key := "new_start" if reverse else "old_start"
	for h in hunks:
		var hunk: Dictionary = h
		var start_line_1based: int = int(hunk.get(anchor_key, 1))
		var target_index: int = max(start_line_1based - 1, 0)
		while src_index < target_index and src_index < src_lines.size():
			out.append(src_lines[src_index])
			src_index += 1
		if src_index != target_index:
			return { "ok": false, "error": "Hunk start past end of file (line %d)" % start_line_1based }
		var hunk_lines: Array = hunk.get("lines", [])
		for raw_l in hunk_lines:
			var l := str(raw_l)
			if l.is_empty():
				continue
			var tag := l.substr(0, 1)
			var body := l.substr(1)
			if reverse:
				if tag == "+":
					tag = "-"
				elif tag == "-":
					tag = "+"
			match tag:
				" ":
					if src_index >= src_lines.size() or str(src_lines[src_index]) != body:
						return { "ok": false, "error": "Context mismatch at line %d: expected '%s', got '%s'" % [
							src_index + 1,
							_truncate(body),
							_truncate(str(src_lines[src_index]) if src_index < src_lines.size() else "<EOF>"),
						] }
					out.append(body)
					src_index += 1
				"-":
					if src_index >= src_lines.size() or str(src_lines[src_index]) != body:
						return { "ok": false, "error": "Remove mismatch at line %d: expected '%s', got '%s'" % [
							src_index + 1,
							_truncate(body),
							_truncate(str(src_lines[src_index]) if src_index < src_lines.size() else "<EOF>"),
						] }
					src_index += 1
					removed += 1
				"+":
					out.append(body)
					added += 1
				_:
					out.append(l)
	while src_index < src_lines.size():
		out.append(src_lines[src_index])
		src_index += 1
	var joined := "\n".join(PackedStringArray(out))
	if trailing_newline:
		joined += "\n"
	return { "ok": true, "text": joined, "added": added, "removed": removed }

func _truncate(s: String) -> String:
	if s.length() > _SNIPPET_MAX_CHARS:
		return s.substr(0, _SNIPPET_MAX_CHARS) + "..."
	return s

#endregion
#region Diff generation

# Build a unified diff between a_text and b_text using an LCS-based line diff
# with _CONTEXT_LINES of surrounding context.
func _make_unified_diff(a_path: String, b_path: String, a_text: String, b_text: String) -> String:
	var a_lines: Array = Array(a_text.split("\n"))
	var b_lines: Array = Array(b_text.split("\n"))
	if a_text.ends_with("\n") and a_lines.size() > 0 and str(a_lines[-1]).is_empty():
		a_lines.pop_back()
	if b_text.ends_with("\n") and b_lines.size() > 0 and str(b_lines[-1]).is_empty():
		b_lines.pop_back()
	var edits := _diff_lines(a_lines, b_lines)
	var parts: PackedStringArray = PackedStringArray()
	parts.append("--- %s" % a_path)
	parts.append("+++ %s" % b_path)
	var has_changes := false
	for e in edits:
		if str((e as Dictionary).get("op")) != "=":
			has_changes = true
			break
	if not has_changes:
		return "\n".join(parts) + "\n"
	var hunks := _group_edits_into_hunks(edits, _CONTEXT_LINES)
	for h in hunks:
		parts.append(_render_hunk(h))
	return "\n".join(parts) + "\n"

# Returns an array of edits: { op: "="/"+"/"-", a?: String, b?: String, ai?: int, bi?: int }
# ai/bi are 1-based line numbers in their respective files.
func _diff_lines(a: Array, b: Array) -> Array:
	var n := a.size()
	var m := b.size()
	var lcs: Array = []
	lcs.resize(n + 1)
	for i in range(n + 1):
		var row: Array = []
		row.resize(m + 1)
		for j in range(m + 1):
			row[j] = 0
		lcs[i] = row
	for i in range(n - 1, -1, -1):
		for j in range(m - 1, -1, -1):
			if str(a[i]) == str(b[j]):
				lcs[i][j] = int(lcs[i + 1][j + 1]) + 1
			else:
				lcs[i][j] = max(int(lcs[i + 1][j]), int(lcs[i][j + 1]))
	var edits: Array = []
	var i2 := 0
	var j2 := 0
	while i2 < n and j2 < m:
		if str(a[i2]) == str(b[j2]):
			edits.append({ "op": "=", "a": str(a[i2]), "b": str(b[j2]), "ai": i2 + 1, "bi": j2 + 1 })
			i2 += 1
			j2 += 1
		elif int(lcs[i2 + 1][j2]) >= int(lcs[i2][j2 + 1]):
			edits.append({ "op": "-", "a": str(a[i2]), "ai": i2 + 1 })
			i2 += 1
		else:
			edits.append({ "op": "+", "b": str(b[j2]), "bi": j2 + 1 })
			j2 += 1
	while i2 < n:
		edits.append({ "op": "-", "a": str(a[i2]), "ai": i2 + 1 })
		i2 += 1
	while j2 < m:
		edits.append({ "op": "+", "b": str(b[j2]), "bi": j2 + 1 })
		j2 += 1
	return edits

# Group consecutive non-= edits with context_lines of leading/trailing context
# into hunks. Adjacent change-runs separated by <= 2*context equals are merged.
func _group_edits_into_hunks(edits: Array, context_lines: int) -> Array:
	var hunks: Array = []
	var k := 0
	var total := edits.size()
	while k < total:
		while k < total and str((edits[k] as Dictionary).get("op")) == "=":
			k += 1
		if k >= total:
			break
		var start := k
		var ctx_back := 0
		while start > 0 and str((edits[start - 1] as Dictionary).get("op")) == "=" and ctx_back < context_lines:
			start -= 1
			ctx_back += 1
		var end := k
		while end < total:
			if str((edits[end] as Dictionary).get("op")) != "=":
				end += 1
				continue
			var run_start := end
			while end < total and str((edits[end] as Dictionary).get("op")) == "=":
				end += 1
			var run_len := end - run_start
			if end >= total or run_len > context_lines * 2:
				end = run_start + min(run_len, context_lines)
				break
		var hunk_edits: Array = edits.slice(start, end)
		var first: Dictionary = hunk_edits[0]
		var old_start := int(first.get("ai", first.get("bi", 1)))
		var new_start := int(first.get("bi", first.get("ai", 1)))
		if not first.has("ai"):
			old_start = max(old_start - 1, 0)
		if not first.has("bi"):
			new_start = max(new_start - 1, 0)
		var old_count := 0
		var new_count := 0
		for e in hunk_edits:
			var op := str((e as Dictionary).get("op"))
			if op == "=" or op == "-":
				old_count += 1
			if op == "=" or op == "+":
				new_count += 1
		hunks.append({
			"old_start": old_start,
			"old_count": old_count,
			"new_start": new_start,
			"new_count": new_count,
			"edits": hunk_edits,
		})
		k = end
	return hunks

func _render_hunk(hunk: Dictionary) -> String:
	var header := "@@ -%d,%d +%d,%d @@" % [
		int(hunk.get("old_start", 1)),
		int(hunk.get("old_count", 0)),
		int(hunk.get("new_start", 1)),
		int(hunk.get("new_count", 0)),
	]
	var parts: PackedStringArray = PackedStringArray()
	parts.append(header)
	for e in hunk.get("edits", []):
		var ed: Dictionary = e
		match str(ed.get("op")):
			"=": parts.append(" " + str(ed.get("a", "")))
			"-": parts.append("-" + str(ed.get("a", "")))
			"+": parts.append("+" + str(ed.get("b", "")))
	return "\n".join(parts)

#endregion
#region Preview rendering

func _render_preview(before_text: String, after_text: String) -> String:
	var a: Array = Array(before_text.split("\n"))
	var b: Array = Array(after_text.split("\n"))
	var edits := _diff_lines(a, b)
	var out: PackedStringArray = PackedStringArray()
	var shown := 0
	for e in edits:
		if shown >= _PREVIEW_MAX_LINES:
			out.append("[color=%s]... preview truncated ...[/color]" % _COLOR_NUMBER)
			break
		var ed: Dictionary = e
		match str(ed.get("op")):
			"-":
				out.append("[color=%s]- %s[/color]" % [_COLOR_ERROR, str(ed.get("a", ""))])
				shown += 1
			"+":
				out.append("[color=%s]+ %s[/color]" % [_COLOR_SUCCESS, str(ed.get("b", ""))])
				shown += 1
			_:
				pass
	if out.size() == 0:
		return "[color=%s](no textual changes)[/color]" % _COLOR_NUMBER
	return "\n".join(out)

#endregion
#region File IO

func _read_text(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var t := f.get_as_text()
	f.close()
	return t

func _write_text(path: String, text: String) -> bool:
	if path.is_empty():
		return false
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(text)
	f.close()
	return true

#endregion
#region Formatting helpers

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

#endregion

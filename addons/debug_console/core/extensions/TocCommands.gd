@tool
class_name DebugConsoleTocCommands extends RefCounted

# Extension module - table-of-contents over captured DebugCore output.
# Mirrors the structure of core/SceneCommands.gd: the orchestrator
# (BuiltInCommands.register_universal_commands) instantiates this once,
# holds a strong reference, and calls register_commands(registry, core)
# so the Callables here remain valid for the lifetime of the plugin.
#
# Use case: a long pipeline (build steps, asserts, batch runs) sprays
# hundreds of lines into the console. Sprinkle '### Phase 1' / '## Setup'
# style headers - either manually with toc_add or naturally via whatever
# emits them - then toc_build scans the history, toc_show prints the
# numbered index, and toc_jump <n> reprints just that section's output.
#
# Header detection rules:
#   - The "## "  prefix is treated as level 2 (major section)
#   - The "### " prefix is treated as level 3 (subsection)
#   - Detection runs on the message portion after stripping the standard
#     "[HH:MM:SS] [LEVEL] " prefix that DebugCore.Log prepends, and after
#     stripping any BBCode tags so coloured headers still match.
#
# The TOC itself is purely in-memory: it is rebuilt on demand from the
# current DebugCore history and never persisted. Export goes to a user://
# markdown file the caller specifies.
#
# Context: every command is registered under "both" - the TOC is just
# data over the message history, equally useful in the editor dock or a
# running game build.

const _COLOR_ERROR := "#FF4444"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_DIM := "#888888"
const _COLOR_HEADER := "#9FD0FF"

const _MAX_SECTION_LINES: int = 200

var _registry: Node
var _core: Node

# Cache of the last toc_build result. Each entry is a Dictionary:
#   { "level": int, "title": String, "line": int }
# where "line" is the index into DebugCore.get_history() AT THE MOMENT
# toc_build ran. We snapshot the history length so toc_jump can detect
# the case where the history has since rotated past the recorded index.
var _entries: Array[Dictionary] = []
var _history_size_at_build: int = 0

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("toc_build", _cmd_toc_build, "Scan DebugCore output history for '## Section' / '### Section' headers and build a TOC: toc_build", "both")
	_registry.register_command("toc_show", _cmd_toc_show, "Display the last-built TOC (run toc_build first): toc_show", "both")
	_registry.register_command("toc_jump", _cmd_toc_jump, "Print the output of a TOC section by 1-based index: toc_jump <index>", "both")
	_registry.register_command("toc_add", _cmd_toc_add, "Insert a '### <name>' marker into the live output stream so toc_build will pick it up: toc_add <name>", "both")
	_registry.register_command("toc_clear", _cmd_toc_clear, "Reset the cached TOC (does not touch the output history): toc_clear", "both")
	_registry.register_command("toc_export", _cmd_toc_export, "Write the last-built TOC to a markdown file: toc_export <user://path.md>", "both")

#region Command implementations

func _cmd_toc_build(_args: Array, _piped_input: String = "") -> String:
	if not _core:
		return _format_error("DebugCore unavailable; cannot read output history")
	if not _core.has_method("get_history"):
		return _format_error("DebugCore has no get_history(); cannot scan output history")

	var history: Array = _core.get_history()
	_entries.clear()
	_history_size_at_build = history.size()

	for i in history.size():
		var raw_line: String = str(history[i])
		var msg: String = _extract_message_body(raw_line)
		var header: Dictionary = _detect_header(msg)
		if header.is_empty():
			continue
		_entries.append({
			"level": int(header["level"]),
			"title": str(header["title"]),
			"line": i,
		})

	if _entries.is_empty():
		return "[color=%s]Scanned %d line(s); no '## ' / '### ' headers found.[/color]" % [_COLOR_DIM, history.size()]
	return _format_success("Built TOC: %d section(s) from %d line(s). Run 'toc_show' to view." % [_entries.size(), history.size()])

func _cmd_toc_show(_args: Array, _piped_input: String = "") -> String:
	if _entries.is_empty():
		return "[color=%s](TOC is empty - run 'toc_build' first)[/color]" % _COLOR_DIM
	var lines: Array[String] = []
	lines.append("Table of contents (%d section(s)):" % _entries.size())
	for i in _entries.size():
		var e: Dictionary = _entries[i]
		var level: int = int(e.get("level", 3))
		# Level 2 = no indent, level 3 = two-space indent. Keeps the
		# hierarchy visible without needing a real tree widget.
		var indent: String = "" if level <= 2 else "  "
		var number: String = "[color=%s]%2d.[/color]" % [_COLOR_NUMBER, i + 1]
		var title: String = "[color=%s]%s[/color]" % [_COLOR_HEADER, str(e.get("title", ""))]
		var loc: String = "[color=%s](line %d)[/color]" % [_COLOR_DIM, int(e.get("line", -1)) + 1]
		lines.append("%s%s %s %s" % [indent, number, title, loc])
	return "\n".join(lines)

func _cmd_toc_jump(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: toc_jump <index>")
	if _entries.is_empty():
		return _format_error("TOC is empty - run 'toc_build' first")

	var raw: String = str(args[0]).strip_edges()
	if not raw.is_valid_int():
		return _format_error("Index must be an integer: %s" % raw)
	var idx_1based: int = raw.to_int()
	if idx_1based < 1 or idx_1based > _entries.size():
		return _format_error("Index out of range: %d (have %d section(s))" % [idx_1based, _entries.size()])

	if not _core or not _core.has_method("get_history"):
		return _format_error("DebugCore unavailable; cannot read output history")
	var history: Array = _core.get_history()

	var entry: Dictionary = _entries[idx_1based - 1]
	var start_line: int = int(entry.get("line", -1))
	# If the history rotated since toc_build, the recorded index can
	# point past the end of the buffer OR to an unrelated line. Detect
	# the rotation by comparing the snapshot size to the live size and
	# tell the user to rebuild rather than silently printing garbage.
	if history.size() < _history_size_at_build:
		return _format_error("History rotated since last toc_build; run toc_build again")
	if start_line < 0 or start_line >= history.size():
		return _format_error("Section line %d no longer in history; run toc_build again" % (start_line + 1))

	# A section's content ends at the line BEFORE the next entry's
	# header line. The last section runs to end-of-history. We cap at
	# _MAX_SECTION_LINES so a runaway final section doesn't dump the
	# entire buffer.
	var end_line: int = history.size()
	if idx_1based < _entries.size():
		end_line = int(_entries[idx_1based].get("line", history.size()))
	if end_line - start_line > _MAX_SECTION_LINES:
		end_line = start_line + _MAX_SECTION_LINES

	var title: String = str(entry.get("title", ""))
	var lines: Array[String] = []
	lines.append("[color=%s]== Section %d: %s (lines %d..%d) ==[/color]" % [
		_COLOR_HEADER, idx_1based, title, start_line + 1, end_line
	])
	for i in range(start_line, end_line):
		lines.append(str(history[i]))
	if end_line < history.size() and idx_1based == _entries.size():
		lines.append("[color=%s](truncated at %d lines; section continues to line %d)[/color]" % [
			_COLOR_DIM, _MAX_SECTION_LINES, history.size()
		])
	return "\n".join(lines)

func _cmd_toc_add(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: toc_add <name>")
	# Join all args so multi-word section names like "Setup Phase"
	# don't require the caller to quote them.
	var parts: Array = []
	for a in args:
		parts.append(str(a))
	var name: String = " ".join(parts).strip_edges()
	if name.is_empty():
		return _format_error("Section name must not be empty")

	var marker: String = "### " + name
	# Push the marker through DebugCore so it lands in the same
	# _message_history buffer that toc_build scans. If DebugCore isn't
	# available we still echo the marker back so the caller can see it
	# was attempted - but warn that it won't be picked up by toc_build.
	var logged: bool = false
	if _core and _core.has_method("Log"):
		_core.Log(marker)
		logged = true

	var head: String = "[color=%s]%s[/color]" % [_COLOR_HEADER, marker]
	if logged:
		return _format_success("Inserted TOC marker into output stream:") + "\n  " + head
	return _format_error("DebugCore unavailable; marker not added to history:") + "\n  " + head

func _cmd_toc_clear(_args: Array, _piped_input: String = "") -> String:
	var count: int = _entries.size()
	_entries.clear()
	_history_size_at_build = 0
	return _format_success("Cleared cached TOC (%d entry/entries)" % count)

func _cmd_toc_export(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: toc_export <user://path.md>")
	if _entries.is_empty():
		return _format_error("TOC is empty - run 'toc_build' first")

	var path: String = str(args[0]).strip_edges()
	if path.is_empty():
		return _format_error("Output path must not be empty")
	# Refuse anything outside user:// to keep this command from
	# accidentally splattering markdown files inside the project source
	# tree. The user can still pass any subpath under user://.
	if not path.begins_with("user://"):
		return _format_error("Output path must begin with user:// (got: %s)" % path)

	var base_dir: String = path.get_base_dir()
	if not base_dir.is_empty() and base_dir != "user://":
		var mk_err: int = DirAccess.make_dir_recursive_absolute(base_dir)
		if mk_err != OK and mk_err != ERR_ALREADY_EXISTS:
			return _format_error("Failed to create directory %s (%s)" % [base_dir, error_string(mk_err)])

	var file := FileAccess.open(path, FileAccess.WRITE)
	if not file:
		var fa_err: int = FileAccess.get_open_error()
		return _format_error("Failed to open %s for writing (%s)" % [path, error_string(fa_err)])

	file.store_line("# Table of Contents")
	file.store_line("")
	file.store_line("_Generated by debug_console toc_export. %d section(s)._" % _entries.size())
	file.store_line("")
	for i in _entries.size():
		var e: Dictionary = _entries[i]
		var level: int = int(e.get("level", 3))
		var indent: String = "" if level <= 2 else "  "
		var line_no: int = int(e.get("line", -1)) + 1
		var title: String = str(e.get("title", ""))
		# Plain markdown list - no BBCode in the file. Renderers will
		# pick up the indentation as a nested list.
		file.store_line("%s- %d. %s _(line %d)_" % [indent, i + 1, title, line_no])
	file.close()

	return _format_success("Exported %d section(s) to %s" % [_entries.size(), _color_path(path)])

#endregion

#region Helpers

func _extract_message_body(raw: String) -> String:
	# DebugCore.Log prepends "[HH:MM:SS] [LEVEL] " to every message.
	# Strip exactly that prefix when present; otherwise return the raw
	# string so callers that bypassed Log() still get scanned.
	var s := raw
	# Match "[" timestamp "] [" level "] "
	var re := RegEx.new()
	if re.compile("^\\[\\d{2}:\\d{2}:\\d{2}\\]\\s*\\[[A-Z]+\\]\\s*") == OK:
		var m := re.search(s)
		if m:
			s = s.substr(m.get_end())
	# Drop BBCode tags so '[color=#FFF]## foo[/color]' still matches.
	var tag_re := RegEx.new()
	if tag_re.compile("\\[/?[^\\]]+\\]") == OK:
		s = tag_re.sub(s, "", true)
	return s.strip_edges()

func _detect_header(msg: String) -> Dictionary:
	# Order matters: check '### ' before '## ' since the former is a
	# strict prefix of the latter after stripping one '#'.
	if msg.begins_with("### "):
		var t3: String = msg.substr(4).strip_edges()
		if t3.is_empty():
			return {}
		return {"level": 3, "title": t3}
	if msg.begins_with("## "):
		var t2: String = msg.substr(3).strip_edges()
		if t2.is_empty():
			return {}
		return {"level": 2, "title": t2}
	return {}

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

#endregion

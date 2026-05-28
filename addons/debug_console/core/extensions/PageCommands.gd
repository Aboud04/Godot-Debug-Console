@tool
class_name DebugConsolePageCommands extends RefCounted

# Extension module - tmux-style scrollback pages for the debug console.
# Mirrors the structure of core/SceneCommands.gd: the orchestrator
# (BuiltInCommands.register_universal_commands) instantiates this once,
# holds a strong reference, and calls register_commands(registry, core)
# so the Callables here remain valid for the lifetime of the plugin.
#
# A "page" is a named, multi-line text buffer the user stashes so they can
# leaf through huge output 30 lines at a time without flooding the console.
# Per-instance state stores the buffers, the most recently shown buffer's
# name, and a 1-indexed cursor used by page_next / page_prev.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_DIM := "#808080"

const _PAGE_SIZE: int = 30

var _registry: Node
var _core: Node

var _pages: Dictionary = {}
var _current_name: String = ""
var _current_page: int = 1

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("page_create", _cmd_page_create, "Store a named output buffer: page_create <name> <content>", "both")
	_registry.register_command("page_show", _cmd_page_show, "Display a stored buffer paginated 30 lines/page: page_show <name> [page_n]", "both")
	_registry.register_command("page_next", _cmd_page_next, "Show the next page of the currently shown buffer: page_next", "both")
	_registry.register_command("page_prev", _cmd_page_prev, "Show the previous page of the currently shown buffer: page_prev", "both")
	_registry.register_command("page_list", _cmd_page_list, "List all stored pages with their line counts: page_list", "both")
	_registry.register_command("page_drop", _cmd_page_drop, "Delete a stored page (or all of them): page_drop <name|all>", "both")
	_registry.register_command("page_pipe", _cmd_page_pipe, "Store the upstream command's piped output as a named page: <cmd> | page_pipe <name>", "both")

#region Command implementations

func _cmd_page_create(args: Array, _piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: page_create <name> <content>")
	var name := str(args[0]).strip_edges()
	if name.is_empty():
		return _format_error("Page name cannot be empty.")
	var content_parts: PackedStringArray = []
	for i in range(1, args.size()):
		content_parts.append(str(args[i]))
	var content := " ".join(content_parts)
	var lines := _split_lines(content)
	_pages[name] = lines
	return _format_success("Stored page %s (%s line(s))" % [
		_color_path(name),
		_color_number(str(lines.size())),
	])

func _cmd_page_show(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: page_show <name> [page_n]")
	var name := str(args[0]).strip_edges()
	if not _pages.has(name):
		return _format_error("No page named %s. Use page_list to see stored pages." % name)
	var page_n: int = 1
	if args.size() > 1:
		var raw := str(args[1]).strip_edges()
		if not raw.is_valid_int():
			return _format_error("page_n must be an integer, got: %s" % raw)
		page_n = raw.to_int()
	_current_name = name
	_current_page = page_n
	return _render_current()

func _cmd_page_next(_args: Array, _piped_input: String = "") -> String:
	if _current_name.is_empty() or not _pages.has(_current_name):
		return _format_error("No page currently shown. Run 'page_show <name>' first.")
	_current_page += 1
	return _render_current()

func _cmd_page_prev(_args: Array, _piped_input: String = "") -> String:
	if _current_name.is_empty() or not _pages.has(_current_name):
		return _format_error("No page currently shown. Run 'page_show <name>' first.")
	_current_page -= 1
	return _render_current()

func _cmd_page_list(_args: Array, _piped_input: String = "") -> String:
	if _pages.is_empty():
		return "No pages stored. Use page_create or page_pipe to add one."
	var names: Array = _pages.keys()
	names.sort()
	var out: PackedStringArray = []
	out.append("Stored pages (%s):" % _color_number(str(names.size())))
	for raw_name in names:
		var name := str(raw_name)
		var lines: PackedStringArray = _pages[name]
		var total_pages: int = _page_count(lines.size())
		var marker := ">" if name == _current_name else " "
		var gutter := "[color=%s]%s[/color]" % [_COLOR_DIM, marker]
		out.append("%s %s  %s line(s), %s page(s)" % [
			gutter,
			_color_path(name),
			_color_number(str(lines.size())),
			_color_number(str(total_pages)),
		])
	return "\n".join(out)

func _cmd_page_drop(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: page_drop <name|all>")
	var target := str(args[0]).strip_edges()
	if target == "all":
		var n: int = _pages.size()
		_pages.clear()
		_current_name = ""
		_current_page = 1
		return _format_success("Dropped all stored pages (%s)" % _color_number(str(n)))
	if not _pages.has(target):
		return _format_error("No page named %s." % target)
	_pages.erase(target)
	if _current_name == target:
		_current_name = ""
		_current_page = 1
	return _format_success("Dropped page %s" % _color_path(target))

func _cmd_page_pipe(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: <cmd> | page_pipe <name>")
	var name := str(args[0]).strip_edges()
	if name.is_empty():
		return _format_error("Page name cannot be empty.")
	if piped_input.is_empty():
		return _format_error("page_pipe expects piped input; pipe a command into it like 'dump_logs | page_pipe %s'." % name)
	var lines := _split_lines(piped_input)
	_pages[name] = lines
	return _format_success("Piped %s line(s) into page %s" % [
		_color_number(str(lines.size())),
		_color_path(name),
	])

#endregion

#region Pagination core

func _render_current() -> String:
	if _current_name.is_empty() or not _pages.has(_current_name):
		return _format_error("No page currently shown.")
	var lines: PackedStringArray = _pages[_current_name]
	var total: int = lines.size()
	var total_pages: int = _page_count(total)

	if _current_page < 1:
		_current_page = 1
	elif _current_page > total_pages:
		_current_page = total_pages

	var start_idx: int = (_current_page - 1) * _PAGE_SIZE
	var end_idx: int = min(total, start_idx + _PAGE_SIZE)

	var out: PackedStringArray = []
	var range_label: String
	if total == 0:
		range_label = "empty"
	else:
		range_label = "lines %s-%s of %s" % [
			_color_number(str(start_idx + 1)),
			_color_number(str(end_idx)),
			_color_number(str(total)),
		]
	out.append("Page %s/%s of %s (%s)" % [
		_color_number(str(_current_page)),
		_color_number(str(total_pages)),
		_color_path(_current_name),
		range_label,
	])
	for i in range(start_idx, end_idx):
		var gutter := "[color=%s]%s[/color]" % [_COLOR_DIM, str(i + 1).pad_zeros(4)]
		out.append("%s  %s" % [gutter, lines[i]])
	return "\n".join(out)

func _page_count(line_total: int) -> int:
	if line_total <= 0:
		return 1
	return int(ceil(float(line_total) / float(_PAGE_SIZE)))

func _split_lines(content: String) -> PackedStringArray:
	# Normalize CRLF and literal "\n" escapes so page_create from a typed
	# command line and page_pipe from real multi-line output both yield the
	# same line list. Trailing empty line from a final newline is dropped.
	var normalized := content.replace("\r\n", "\n").replace("\\n", "\n")
	var parts := normalized.split("\n", true)
	if parts.size() > 0 and parts[parts.size() - 1] == "":
		parts.remove_at(parts.size() - 1)
	var out: PackedStringArray = []
	for p in parts:
		out.append(p)
	return out

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

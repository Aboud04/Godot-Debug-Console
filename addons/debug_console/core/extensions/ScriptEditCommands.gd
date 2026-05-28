@tool
class_name DebugConsoleScriptEditCommands extends RefCounted

# Tier 6 - script editor commands. Provides open / navigate / grep / replace /
# lines / diff helpers backed by EditorInterface and ScriptEditor. Registered
# under the "editor" context because every command here either drives the
# editor UI or reads the in-memory script buffer.
#
# The orchestrator (BuiltInCommands.register_universal_commands) instantiates
# this via the extensions loader and keeps a strong reference, which keeps the
# Callables registered below valid for the lifetime of the plugin.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_DIM := "#909090"

const _MAX_GREP_FILES := 4000
const _MAX_GREP_MATCHES := 500
const _MAX_DIFF_LINES := 400

var _registry: Node
var _core: Node

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("script_open", _cmd_script_open, "Open a script in the editor: script_open <res://path.gd> [line]", "editor")
	_registry.register_command("script_open_at_method", _cmd_script_open_at_method, "Open script at method: script_open_at_method <res://path.gd>.<method>", "editor")
	_registry.register_command("script_grep", _cmd_script_grep, "Regex-search .gd files: script_grep <regex> [path_glob]", "editor")
	_registry.register_command("script_replace_in_file", _cmd_script_replace_in_file, "Safe in-place replace: script_replace_in_file <path> <find> <replace>", "editor")
	_registry.register_command("script_lines", _cmd_script_lines, "Line count + size: script_lines <path>", "editor")
	_registry.register_command("script_diff_to_disk", _cmd_script_diff_to_disk, "Diff editor buffer vs disk: script_diff_to_disk <path>", "editor")

#region Command implementations

func _cmd_script_open(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: script_open <res://path.gd> [line]")
	if not Engine.is_editor_hint():
		return _format_error("script_open is editor-only")
	var path := str(args[0]).strip_edges()
	var line: int = 0
	if args.size() > 1:
		var line_str := str(args[1]).strip_edges()
		if not line_str.is_valid_int():
			return _format_error("Line must be an integer: %s" % line_str)
		line = line_str.to_int()
	if not ResourceLoader.exists(path):
		return _format_error("Script not found: %s" % path)
	var script: Script = load(path) as Script
	if not script:
		return _format_error("Not a Script resource: %s" % path)

	# EditorInterface.edit_script takes a 0-based line; -1 means "no jump".
	var goto: int = -1
	if line > 0:
		goto = line - 1
	EditorInterface.edit_script(script, goto)
	if line > 0:
		return _format_success("Opened %s at line %s" % [_color_path(path), _color_number(str(line))])
	return _format_success("Opened %s" % _color_path(path))

func _cmd_script_open_at_method(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: script_open_at_method <res://path.gd>.<method>")
	if not Engine.is_editor_hint():
		return _format_error("script_open_at_method is editor-only")
	var selector := str(args[0]).strip_edges()
	var split := _split_method_selector(selector)
	if split.is_empty():
		return _format_error("Selector must be <res://path.gd>.<method>: %s" % selector)
	var path: String = split[0]
	var method: String = split[1]
	if not ResourceLoader.exists(path):
		return _format_error("Script not found: %s" % path)
	var line: int = _find_method_line(path, method)
	if line <= 0:
		return _format_error("Method not found: %s in %s" % [method, path])
	var script: Script = load(path) as Script
	if not script:
		return _format_error("Not a Script resource: %s" % path)
	EditorInterface.edit_script(script, line - 1)
	return _format_success("Opened %s at %s (line %s)" % [_color_path(path), method, _color_number(str(line))])

func _cmd_script_grep(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: script_grep <regex> [path_glob]")
	var pattern := str(args[0])
	var glob: String = str(args[1]).strip_edges() if args.size() > 1 else ""
	var rx := RegEx.new()
	if rx.compile(pattern) != OK:
		return _format_error("Invalid regex: %s" % pattern)

	var files := PackedStringArray()
	_collect_gd_files("res://", files, _MAX_GREP_FILES)
	var files_truncated: bool = files.size() >= _MAX_GREP_FILES

	var matches: Array[String] = []
	var scanned: int = 0
	var hit_match_limit: bool = false
	for f in files:
		if not glob.is_empty() and not f.match(glob):
			continue
		scanned += 1
		var fa := FileAccess.open(f, FileAccess.READ)
		if not fa:
			continue
		var content := fa.get_as_text()
		fa.close()
		var lines := content.split("\n")
		for i in range(lines.size()):
			var line_text: String = lines[i]
			if rx.search(line_text) == null:
				continue
			matches.append("%s:%s  %s" % [_color_path(f), _color_number(str(i + 1)), line_text.strip_edges()])
			if matches.size() >= _MAX_GREP_MATCHES:
				hit_match_limit = true
				break
		if hit_match_limit:
			break

	var header: String = "%s match(es) in %s file(s) scanned" % [_color_number(str(matches.size())), _color_number(str(scanned))]
	if files_truncated:
		header += "  (file walk truncated at %d)" % _MAX_GREP_FILES
	if hit_match_limit:
		header += "  (match limit %d reached)" % _MAX_GREP_MATCHES
	if matches.is_empty():
		return header
	return "%s\n%s" % [header, "\n".join(matches)]

func _cmd_script_replace_in_file(args: Array, piped_input: String = "") -> String:
	if args.size() < 3:
		return _format_error("Usage: script_replace_in_file <path> <find> <replace>")
	var path := str(args[0]).strip_edges()
	var find_text := str(args[1])
	var replace_text := str(args[2])

	if find_text.is_empty():
		return _format_error("<find> must not be empty")
	if not (path.begins_with("res://") or path.begins_with("user://")):
		return _format_error("Path must start with res:// or user://: %s" % path)
	if not path.ends_with(".gd"):
		return _format_error("Refusing to edit non-.gd file: %s" % path)
	if not FileAccess.file_exists(path):
		return _format_error("File not found: %s" % path)

	var fa_r := FileAccess.open(path, FileAccess.READ)
	if not fa_r:
		return _format_error("Could not read: %s (err %d)" % [path, FileAccess.get_open_error()])
	var original := fa_r.get_as_text()
	fa_r.close()

	var occurrences: int = original.count(find_text)
	if occurrences == 0:
		return _format_error("No matches for <find> in %s" % path)
	var updated := original.replace(find_text, replace_text)
	if updated == original:
		return _format_error("Replacement produced identical content")

	var fa_w := FileAccess.open(path, FileAccess.WRITE)
	if not fa_w:
		return _format_error("Could not open for write: %s (err %d)" % [path, FileAccess.get_open_error()])
	fa_w.store_string(updated)
	fa_w.close()

	# Verify the bytes actually landed on disk before reporting success.
	var verify := FileAccess.open(path, FileAccess.READ)
	if not verify:
		return _format_error("Post-write verify could not reopen: %s" % path)
	var roundtrip := verify.get_as_text()
	verify.close()
	if roundtrip != updated:
		return _format_error("Post-write verification mismatch: %s" % path)

	if Engine.is_editor_hint():
		var fs := EditorInterface.get_resource_filesystem()
		if fs:
			fs.update_file(path)

	return _format_success("Replaced %s occurrence(s) in %s" % [_color_number(str(occurrences)), _color_path(path)])

func _cmd_script_lines(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: script_lines <path>")
	var path := str(args[0]).strip_edges()
	if not FileAccess.file_exists(path):
		return _format_error("File not found: %s" % path)
	var fa := FileAccess.open(path, FileAccess.READ)
	if not fa:
		return _format_error("Could not read: %s (err %d)" % [path, FileAccess.get_open_error()])
	var size: int = fa.get_length()
	var content := fa.get_as_text()
	fa.close()

	var line_count: int = 0
	if not content.is_empty():
		line_count = content.split("\n").size()
		# A trailing newline produces an empty final split element; don't count it.
		if content.ends_with("\n"):
			line_count -= 1

	return "%s  lines=%s  bytes=%s" % [_color_path(path), _color_number(str(line_count)), _color_number(str(size))]

func _cmd_script_diff_to_disk(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: script_diff_to_disk <path>")
	if not Engine.is_editor_hint():
		return _format_error("script_diff_to_disk is editor-only")
	var path := str(args[0]).strip_edges()
	if not FileAccess.file_exists(path):
		return _format_error("File not found: %s" % path)

	var fa := FileAccess.open(path, FileAccess.READ)
	if not fa:
		return _format_error("Could not read: %s (err %d)" % [path, FileAccess.get_open_error()])
	var disk_text := fa.get_as_text()
	fa.close()

	var script_editor: ScriptEditor = EditorInterface.get_script_editor()
	if not script_editor:
		return _format_error("ScriptEditor unavailable")

	var buffer_text := ""
	var found_open: bool = false
	for s in script_editor.get_open_scripts():
		if s and s.resource_path == path:
			buffer_text = s.source_code
			found_open = true
			break
	if not found_open:
		return _format_error("Script not open in editor: %s" % path)

	if buffer_text == disk_text:
		return _format_success("No differences: %s (buffer == disk)" % _color_path(path))

	var disk_lines := disk_text.split("\n")
	var buf_lines := buffer_text.split("\n")
	var diff_lines: Array[String] = _simple_diff(disk_lines, buf_lines)
	var header: String = "%s  disk=%s lines  buffer=%s lines" % [
		_color_path(path),
		_color_number(str(disk_lines.size())),
		_color_number(str(buf_lines.size())),
	]
	if diff_lines.size() > _MAX_DIFF_LINES:
		var truncated: Array[String] = []
		for i in range(_MAX_DIFF_LINES):
			truncated.append(diff_lines[i])
		truncated.append("[color=%s]... (diff truncated at %d lines)[/color]" % [_COLOR_DIM, _MAX_DIFF_LINES])
		diff_lines = truncated
	return "%s\n%s" % [header, "\n".join(diff_lines)]

#endregion

#region Helpers

func _split_method_selector(selector: String) -> Array:
	# We split on the LAST '.' so that the .gd extension stays with the path.
	# Valid selector: "res://foo/bar.gd.something" -> path "res://foo/bar.gd", method "something".
	var idx: int = selector.rfind(".")
	if idx <= 0 or idx >= selector.length() - 1:
		return []
	var path: String = selector.substr(0, idx)
	var method: String = selector.substr(idx + 1)
	if not path.ends_with(".gd"):
		return []
	if method.strip_edges().is_empty():
		return []
	return [path, method]

func _find_method_line(path: String, method: String) -> int:
	var fa := FileAccess.open(path, FileAccess.READ)
	if not fa:
		return -1
	var content := fa.get_as_text()
	fa.close()
	var lines := content.split("\n")
	for i in range(lines.size()):
		var stripped: String = lines[i].strip_edges()
		if not stripped.begins_with("func "):
			continue
		var rest: String = stripped.substr(5).strip_edges()
		if not rest.begins_with(method):
			continue
		# Make sure we matched the whole name, not a prefix ("foo" should not match "foobar").
		var after: String = rest.substr(method.length())
		var paren_idx: int = after.find("(")
		if paren_idx < 0:
			continue
		var between: String = after.substr(0, paren_idx).strip_edges()
		if not between.is_empty():
			continue
		return i + 1
	return -1

func _collect_gd_files(root: String, out: PackedStringArray, limit: int) -> void:
	if out.size() >= limit:
		return
	var dir := DirAccess.open(root)
	if not dir:
		return
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while entry != "":
		if entry == "." or entry == "..":
			entry = dir.get_next()
			continue
		var full: String = root.path_join(entry)
		if dir.current_is_dir():
			# Skip Godot's internal caches; they hold no source we care about.
			if entry != ".godot" and entry != ".import":
				_collect_gd_files(full, out, limit)
				if out.size() >= limit:
					dir.list_dir_end()
					return
		elif entry.ends_with(".gd"):
			out.append(full)
			if out.size() >= limit:
				dir.list_dir_end()
				return
		entry = dir.get_next()
	dir.list_dir_end()

func _simple_diff(a: PackedStringArray, b: PackedStringArray) -> Array[String]:
	# Trim shared prefix and suffix, then render the differing middle as -/+.
	# Not a full LCS diff, but produces clean output for the common case where
	# a script has one contiguous block of edits between saves.
	var prefix: int = 0
	var min_len: int = mini(a.size(), b.size())
	while prefix < min_len and a[prefix] == b[prefix]:
		prefix += 1
	var suffix: int = 0
	while suffix < (min_len - prefix) and a[a.size() - 1 - suffix] == b[b.size() - 1 - suffix]:
		suffix += 1

	var out: Array[String] = []
	var ctx: int = 2
	var ctx_start: int = maxi(0, prefix - ctx)
	for i in range(ctx_start, prefix):
		out.append("[color=%s]  %4d  %s[/color]" % [_COLOR_DIM, i + 1, a[i]])
	for i in range(prefix, a.size() - suffix):
		out.append("[color=%s]- %4d  %s[/color]" % [_COLOR_ERROR, i + 1, a[i]])
	for i in range(prefix, b.size() - suffix):
		out.append("[color=%s]+ %4d  %s[/color]" % [_COLOR_SUCCESS, i + 1, b[i]])
	var tail_start: int = a.size() - suffix
	var tail_stop: int = mini(a.size(), tail_start + ctx)
	for i in range(tail_start, tail_stop):
		out.append("[color=%s]  %4d  %s[/color]" % [_COLOR_DIM, i + 1, a[i]])
	return out

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

#endregion

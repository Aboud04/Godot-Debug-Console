@tool
class_name DebugConsoleGlobCommands extends RefCounted

# Filesystem glob expansion exposed as explicit commands. The console parser
# intentionally does not auto-expand `*.gd` style arguments because doing so
# would interfere with pipes, quoted strings, and commands that take literal
# pattern arguments (e.g. find_node, log_filter). Instead, users opt in to
# expansion by typing one of the glob_* commands below.
#
# Pattern syntax:
#   *     matches any run of characters within a single path segment
#   ?     matches a single character within a segment
#   **    matches zero or more path segments (recursive)
#
# Patterns starting with `res://` or `user://` anchor at that protocol.
# Anything else is treated as relative to `res://`.
#
# Wildcard matching for individual segments is delegated to GDScript's
# String.match(), which already handles `*` and `?`. The `**` token is
# special-cased by the recursive walker.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_MUTED := "#888888"

const _DEFAULT_EXPAND_LIMIT := 10000
const _DEFAULT_APPLY_LIMIT := 500

var _registry: Node
var _core: Node

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("glob", _cmd_glob, "Expand a filesystem glob pattern: glob <pattern>  (e.g. glob res://addons/**/*.gd)", "both")
	_registry.register_command("glob_count", _cmd_glob_count, "Count files matching a glob: glob_count <pattern>", "both")
	_registry.register_command("glob_apply", _cmd_glob_apply, "Run a command for every match: glob_apply <pattern> <template>  ({} is the path, e.g. glob_apply *.gd \"wc {}\")", "both")
	_registry.register_command("glob_pipe", _cmd_glob_pipe, "Expand pattern into pipe-friendly newline-separated list: glob_pipe <pattern>", "both")
	_registry.register_command("glob_test", _cmd_glob_test, "Test whether a path matches a glob pattern: glob_test <path> <pattern>", "both")

#region Command implementations

func _cmd_glob(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: glob <pattern>")
	var pattern: String = " ".join(args).strip_edges()
	if pattern.is_empty():
		return _format_error("Usage: glob <pattern>")
	var matches: Array[String] = _glob_expand(pattern, _DEFAULT_EXPAND_LIMIT)
	if matches.is_empty():
		return "No matches for %s" % pattern
	matches.sort()
	var lines: Array[String] = []
	for p in matches:
		lines.append(_color_path(p))
	var header: String = "%s match(es) for %s:" % [_color_number(str(matches.size())), pattern]
	if matches.size() >= _DEFAULT_EXPAND_LIMIT:
		header += "  [color=%s](limit reached)[/color]" % _COLOR_MUTED
	return "%s\n%s" % [header, "\n".join(lines)]

func _cmd_glob_count(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: glob_count <pattern>")
	var pattern: String = " ".join(args).strip_edges()
	if pattern.is_empty():
		return _format_error("Usage: glob_count <pattern>")
	var matches: Array[String] = _glob_expand(pattern, _DEFAULT_EXPAND_LIMIT)
	var suffix: String = ""
	if matches.size() >= _DEFAULT_EXPAND_LIMIT:
		suffix = "  [color=%s](limit reached)[/color]" % _COLOR_MUTED
	return "%s match(es) for %s%s" % [_color_number(str(matches.size())), pattern, suffix]

func _cmd_glob_apply(args: Array, _piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: glob_apply <pattern> <command_template>  ({} is substituted for the path)")
	var pattern: String = str(args[0]).strip_edges()
	# Everything after the pattern becomes the template. We join with spaces so
	# users don't have to quote multi-word templates (e.g. `glob_apply *.gd wc {}`),
	# but we also strip a single layer of surrounding quotes for users who do.
	var template_parts: Array = []
	for i in range(1, args.size()):
		template_parts.append(str(args[i]))
	var template: String = " ".join(template_parts).strip_edges()
	if template.length() >= 2:
		var first: String = template.substr(0, 1)
		var last: String = template.substr(template.length() - 1, 1)
		if (first == "\"" and last == "\"") or (first == "'" and last == "'"):
			template = template.substr(1, template.length() - 2)
	if not template.contains("{}"):
		return _format_error("Template must contain {} placeholder for the matched path: %s" % template)
	if not (_registry and _registry.has_method("execute_command")):
		return _format_error("Registry does not expose execute_command; cannot dispatch template")

	var matches: Array[String] = _glob_expand(pattern, _DEFAULT_APPLY_LIMIT)
	if matches.is_empty():
		return "No matches for %s" % pattern
	matches.sort()

	var lines: Array[String] = []
	var ran: int = 0
	for p in matches:
		var sub_cmd: String = template.replace("{}", p)
		lines.append("[color=%s]$ %s[/color]" % [_COLOR_MUTED, sub_cmd])
		var out_text: String = str(_registry.call("execute_command", sub_cmd))
		if out_text != "":
			lines.append(out_text)
		ran += 1
	var header: String = _format_success("Applied to %s file(s)" % _color_number(str(ran)))
	if matches.size() >= _DEFAULT_APPLY_LIMIT:
		header += "  [color=%s](limit reached)[/color]" % _COLOR_MUTED
	return "%s\n%s" % [header, "\n".join(lines)]

func _cmd_glob_pipe(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: glob_pipe <pattern>")
	var pattern: String = " ".join(args).strip_edges()
	if pattern.is_empty():
		return _format_error("Usage: glob_pipe <pattern>")
	var matches: Array[String] = _glob_expand(pattern, _DEFAULT_EXPAND_LIMIT)
	if matches.is_empty():
		return ""
	matches.sort()
	# Plain text only - downstream commands in a pipe read this verbatim, so we
	# intentionally emit no BBCode and no header.
	return "\n".join(matches)

func _cmd_glob_test(args: Array, _piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: glob_test <path> <pattern>")
	var path: String = str(args[0]).strip_edges()
	# Everything after the first arg is the pattern, so users don't need to
	# quote patterns that contain shell-significant characters (when the
	# console preserves them as separate args).
	var pat_parts: Array = []
	for i in range(1, args.size()):
		pat_parts.append(str(args[i]))
	var pattern: String = " ".join(pat_parts).strip_edges()
	if path.is_empty() or pattern.is_empty():
		return _format_error("Usage: glob_test <path> <pattern>")
	var hit: bool = _glob_match_path(path, pattern)
	if hit:
		return _format_success("true  (%s matches %s)" % [_color_path(path), pattern])
	return "[color=%s]false[/color]  (%s does not match %s)" % [_COLOR_ERROR, _color_path(path), pattern]

#endregion

#region Glob engine

func _glob_expand(pattern: String, limit: int) -> Array[String]:
	var matches: Array[String] = []
	var p: String = pattern.strip_edges()
	if p.is_empty():
		return matches

	var base: String = "res://"
	var rel: String = p
	if p.begins_with("res://"):
		base = "res://"
		rel = p.substr(6)
	elif p.begins_with("user://"):
		base = "user://"
		rel = p.substr(7)

	var segs: PackedStringArray = rel.split("/", false)
	if segs.is_empty():
		# Pattern was just the protocol; treat as no-op rather than enumerating
		# the entire project root.
		return matches

	# Walk down the literal prefix (segments with no wildcards) to pin a
	# starting directory. This avoids scanning the whole filesystem when the
	# user already pinned a subtree like `res://addons/**/*.gd`.
	var literal_end: int = 0
	while literal_end < segs.size():
		var s: String = segs[literal_end]
		if s == "**" or s.contains("*") or s.contains("?"):
			break
		literal_end += 1

	var start_dir: String = base
	if literal_end > 0:
		var prefix_parts: Array[String] = []
		for j in range(literal_end):
			prefix_parts.append(segs[j])
		start_dir = base + "/".join(prefix_parts)
		if not start_dir.ends_with("/"):
			start_dir += "/"

	var remaining: Array[String] = []
	for j in range(literal_end, segs.size()):
		remaining.append(segs[j])

	if remaining.is_empty():
		# Pure literal path: succeed iff the path actually exists.
		var literal_path: String = start_dir
		if literal_path.ends_with("/") and literal_path.length() > base.length():
			literal_path = literal_path.substr(0, literal_path.length() - 1)
		if FileAccess.file_exists(literal_path) or DirAccess.dir_exists_absolute(literal_path):
			matches.append(literal_path)
		return matches

	_glob_walk(start_dir, remaining, 0, matches, limit)
	return matches

func _glob_walk(dir: String, segs: Array[String], idx: int, out: Array[String], limit: int) -> void:
	if out.size() >= limit:
		return
	if idx >= segs.size():
		return
	var seg: String = segs[idx]
	var is_last: bool = (idx == segs.size() - 1)

	if seg == "**":
		# Collapse runs of consecutive `**` so `a/**/**/b` behaves like `a/**/b`.
		var next_idx: int = idx + 1
		while next_idx < segs.size() and segs[next_idx] == "**":
			next_idx += 1

		if next_idx >= segs.size():
			# Trailing `**` matches everything under `dir`, recursively.
			_collect_all(dir, out, limit)
			return

		# Match zero segments: try the rest of the pattern in this directory.
		_glob_walk(dir, segs, next_idx, out, limit)
		if out.size() >= limit:
			return

		# Match one or more segments: descend into every subdirectory, keeping
		# the `**` at the current pattern position so it can keep matching.
		var d: DirAccess = DirAccess.open(dir)
		if d == null:
			return
		d.list_dir_begin()
		var name: String = d.get_next()
		while name != "":
			if name != "." and name != "..":
				if d.current_is_dir():
					_glob_walk(_join(dir, name), segs, idx, out, limit)
					if out.size() >= limit:
						d.list_dir_end()
						return
			name = d.get_next()
		d.list_dir_end()
		return

	# Normal segment: enumerate `dir` and keep only names that match the glob.
	var d2: DirAccess = DirAccess.open(dir)
	if d2 == null:
		return
	d2.list_dir_begin()
	var name2: String = d2.get_next()
	while name2 != "":
		if name2 != "." and name2 != "..":
			if name2.match(seg):
				var full: String = _join(dir, name2)
				if is_last:
					out.append(full)
					if out.size() >= limit:
						d2.list_dir_end()
						return
				elif d2.current_is_dir():
					_glob_walk(full, segs, idx + 1, out, limit)
					if out.size() >= limit:
						d2.list_dir_end()
						return
		name2 = d2.get_next()
	d2.list_dir_end()

func _collect_all(dir: String, out: Array[String], limit: int) -> void:
	if out.size() >= limit:
		return
	var d: DirAccess = DirAccess.open(dir)
	if d == null:
		return
	d.list_dir_begin()
	var name: String = d.get_next()
	while name != "":
		if name != "." and name != "..":
			var full: String = _join(dir, name)
			if d.current_is_dir():
				_collect_all(full, out, limit)
				if out.size() >= limit:
					d.list_dir_end()
					return
			else:
				out.append(full)
				if out.size() >= limit:
					d.list_dir_end()
					return
		name = d.get_next()
	d.list_dir_end()

func _glob_match_path(path: String, pattern: String) -> bool:
	# Strip leading protocol from both sides so `res://a/b.gd` can be tested
	# against `a/**/*.gd` and vice versa. This is purely a string operation
	# and never touches the filesystem.
	var p_segs: PackedStringArray = _strip_proto(path).split("/", false)
	var q_segs: PackedStringArray = _strip_proto(pattern).split("/", false)
	return _match_segs(p_segs, 0, q_segs, 0)

func _match_segs(p_segs: PackedStringArray, pi: int, q_segs: PackedStringArray, qi: int) -> bool:
	while qi < q_segs.size() and pi < p_segs.size():
		var pat: String = q_segs[qi]
		if pat == "**":
			# Skip runs of consecutive `**`.
			while qi < q_segs.size() and q_segs[qi] == "**":
				qi += 1
			if qi >= q_segs.size():
				return true
			# Try to anchor the remainder of the pattern at every position
			# from `pi` to the end of the path.
			for k in range(pi, p_segs.size() + 1):
				if _match_segs(p_segs, k, q_segs, qi):
					return true
			return false
		if not p_segs[pi].match(pat):
			return false
		pi += 1
		qi += 1
	# A pattern that ends in one or more `**` still matches even when the path
	# has been fully consumed.
	while qi < q_segs.size() and q_segs[qi] == "**":
		qi += 1
	return pi == p_segs.size() and qi == q_segs.size()

func _strip_proto(s: String) -> String:
	if s.begins_with("res://"):
		return s.substr(6)
	if s.begins_with("user://"):
		return s.substr(7)
	return s

func _join(dir: String, name: String) -> String:
	if dir.ends_with("/"):
		return dir + name
	return dir + "/" + name

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

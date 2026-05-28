@tool
class_name DebugConsoleRegexCommands extends RefCounted

# Regex utilities exposed as console commands. This is a thin, ergonomic wrapper
# around Godot's RegEx class so users don't have to drop into GDScript every time
# they want to grep, validate, or rewrite a string. Like the other extension
# modules, the orchestrator (BuiltInCommands.register_universal_commands) keeps a
# strong reference to one instance and routes every Callable through it so the
# commands remain valid for the lifetime of the plugin.
#
# Argument conventions:
#   * The first positional argument is always the regex pattern.
#   * For commands that take a text argument, every remaining positional token
#     is joined with single spaces. This matches what users naturally type at
#     the prompt and avoids forcing them to quote their input.
#   * Patterns and replacements may be wrapped in matching single or double
#     quotes; the wrapping quotes are stripped before compilation.
#   * re_pipe reads its input from the upstream pipe so it can be chained with
#     commands like `cat`, `log_filter`, or `select`.

const _COLOR_ERROR := "#FF4444"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_MUTED := "#888888"

const _MAX_MATCHES := 1000
const _MAX_GROUP_PREVIEW := 200

var _registry: Node
var _core: Node

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("re_match", _cmd_re_match, "Find the first regex match: re_match <pattern> <text>", "both")
	_registry.register_command("re_find", _cmd_re_find, "Find every regex match with positions: re_find <pattern> <text>", "both")
	_registry.register_command("re_replace", _cmd_re_replace, "Replace every regex match: re_replace <pattern> <replacement> <text>", "both")
	_registry.register_command("re_test", _cmd_re_test, "Return true/false if pattern matches anywhere in text: re_test <pattern> <text>", "both")
	_registry.register_command("re_split", _cmd_re_split, "Split text on every regex match: re_split <pattern> <text>", "both")
	_registry.register_command("re_groups", _cmd_re_groups, "Show named and numbered groups from the first match: re_groups <pattern> <text>", "both")
	_registry.register_command("re_validate", _cmd_re_validate, "Test whether a pattern compiles: re_validate <pattern>", "both")
	_registry.register_command("re_pipe", _cmd_re_pipe, "Pipe-driven regex op: re_pipe <pattern> [--mode match|find|replace] [--with=<replacement>]", "both")

#region Command implementations

func _cmd_re_match(args: Array, _piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: re_match <pattern> <text>")
	var pattern: String = _unquote(str(args[0]))
	var text: String = _join_text(args, 1)
	var re := _compile(pattern)
	if re == null:
		return _format_error("Invalid pattern: %s" % pattern)
	var m: RegExMatch = re.search(text)
	if m == null:
		return _format_muted("no match")
	return _format_match_line(m, 0)

func _cmd_re_find(args: Array, _piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: re_find <pattern> <text>")
	var pattern: String = _unquote(str(args[0]))
	var text: String = _join_text(args, 1)
	var re := _compile(pattern)
	if re == null:
		return _format_error("Invalid pattern: %s" % pattern)
	var matches: Array[RegExMatch] = re.search_all(text)
	if matches.is_empty():
		return _format_muted("no match")
	var lines: Array[String] = []
	lines.append(_format_success("%d match(es):" % matches.size()))
	var shown: int = 0
	for m in matches:
		if shown >= _MAX_MATCHES:
			lines.append(_format_muted("... truncated at %d" % _MAX_MATCHES))
			break
		lines.append("  %s" % _format_match_line(m, shown))
		shown += 1
	return "\n".join(lines)

func _cmd_re_replace(args: Array, _piped_input: String = "") -> String:
	if args.size() < 3:
		return _format_error("Usage: re_replace <pattern> <replacement> <text>")
	var pattern: String = _unquote(str(args[0]))
	var replacement: String = _unquote(str(args[1]))
	var text: String = _join_text(args, 2)
	var re := _compile(pattern)
	if re == null:
		return _format_error("Invalid pattern: %s" % pattern)
	var result: String = re.sub(text, replacement, true)
	return result

func _cmd_re_test(args: Array, _piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: re_test <pattern> <text>")
	var pattern: String = _unquote(str(args[0]))
	var text: String = _join_text(args, 1)
	var re := _compile(pattern)
	if re == null:
		return _format_error("Invalid pattern: %s" % pattern)
	var hit: bool = re.search(text) != null
	if hit:
		return _format_success("true")
	return _format_muted("false")

func _cmd_re_split(args: Array, _piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: re_split <pattern> <text>")
	var pattern: String = _unquote(str(args[0]))
	var text: String = _join_text(args, 1)
	var re := _compile(pattern)
	if re == null:
		return _format_error("Invalid pattern: %s" % pattern)
	var parts: Array[String] = _split_on_regex(re, text)
	if parts.is_empty():
		return _format_muted("(empty)")
	var lines: Array[String] = []
	lines.append(_format_success("%d part(s):" % parts.size()))
	for i in parts.size():
		lines.append("  [%s] %s" % [_color_number(str(i)), parts[i]])
	return "\n".join(lines)

func _cmd_re_groups(args: Array, _piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: re_groups <pattern> <text>")
	var pattern: String = _unquote(str(args[0]))
	var text: String = _join_text(args, 1)
	var re := _compile(pattern)
	if re == null:
		return _format_error("Invalid pattern: %s" % pattern)
	var m: RegExMatch = re.search(text)
	if m == null:
		return _format_muted("no match")

	var lines: Array[String] = []
	lines.append(_format_success("match: ") + _format_match_line(m, 0))

	var captured: PackedStringArray = m.strings
	if captured.size() > 1:
		lines.append("numbered groups:")
		for i in range(1, captured.size()):
			var s: int = m.get_start(i)
			var e: int = m.get_end(i)
			lines.append("  %s = %s  %s" % [
				_color_number(str(i)),
				_preview(captured[i]),
				_color_muted("[%d..%d]" % [s, e]),
			])
	else:
		lines.append(_color_muted("no numbered groups"))

	var name_map: Dictionary = m.names
	if not name_map.is_empty():
		lines.append("named groups:")
		var keys: Array = name_map.keys()
		keys.sort()
		for k in keys:
			var idx: int = int(name_map[k])
			var val: String = m.get_string(k) if idx >= 0 else ""
			var s2: int = m.get_start(k) if idx >= 0 else -1
			var e2: int = m.get_end(k) if idx >= 0 else -1
			lines.append("  %s = %s  %s" % [
				_color_path(str(k)),
				_preview(val),
				_color_muted("[%d..%d]" % [s2, e2]),
			])
	else:
		lines.append(_color_muted("no named groups"))

	return "\n".join(lines)

func _cmd_re_validate(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: re_validate <pattern>")
	var pattern: String = _unquote(" ".join(_stringify(args)).strip_edges())
	if pattern.is_empty():
		return _format_error("Pattern is empty")
	var re := RegEx.new()
	var err: int = re.compile(pattern)
	if err != OK or not re.is_valid():
		return _format_error("Invalid pattern (err=%d): %s" % [err, pattern])
	var group_count: int = re.get_group_count()
	return _format_success("ok") + "  " + _color_muted("groups=%d" % group_count)

func _cmd_re_pipe(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: re_pipe <pattern> [--mode match|find|replace] [--with=<replacement>]")

	var pattern: String = ""
	var mode: String = "match"
	var replacement: String = ""
	var positional_seen: bool = false

	for raw in args:
		var token: String = str(raw)
		if token.begins_with("--mode="):
			mode = token.substr(7).strip_edges().to_lower()
		elif token == "--mode":
			# Next positional will be the mode value; handled lazily by setting a sentinel.
			mode = "__expect_mode__"
		elif mode == "__expect_mode__":
			mode = token.strip_edges().to_lower()
		elif token.begins_with("--with="):
			replacement = _unquote(token.substr(7))
		elif not positional_seen:
			pattern = _unquote(token)
			positional_seen = true
		else:
			# Allow the pattern to span multiple unquoted tokens by joining them.
			pattern += " " + _unquote(token)

	if pattern.is_empty():
		return _format_error("re_pipe: pattern is required")
	if mode == "__expect_mode__":
		return _format_error("re_pipe: --mode requires a value (match|find|replace)")
	if mode != "match" and mode != "find" and mode != "replace":
		return _format_error("re_pipe: unknown mode '%s' (expected match|find|replace)" % mode)

	var text: String = piped_input
	if text.is_empty():
		return _format_muted("(no piped input)")

	var re := _compile(pattern)
	if re == null:
		return _format_error("Invalid pattern: %s" % pattern)

	match mode:
		"match":
			var m: RegExMatch = re.search(text)
			if m == null:
				return ""
			return m.get_string()
		"find":
			var matches: Array[RegExMatch] = re.search_all(text)
			if matches.is_empty():
				return ""
			var out: Array[String] = []
			var shown: int = 0
			for hit in matches:
				if shown >= _MAX_MATCHES:
					break
				out.append(hit.get_string())
				shown += 1
			return "\n".join(out)
		"replace":
			return re.sub(text, replacement, true)
		_:
			return _format_error("re_pipe: unreachable mode '%s'" % mode)

#endregion

#region Helpers

func _compile(pattern: String) -> RegEx:
	if pattern.is_empty():
		return null
	var re := RegEx.new()
	var err: int = re.compile(pattern)
	if err != OK or not re.is_valid():
		return null
	return re

func _join_text(args: Array, start: int) -> String:
	if start >= args.size():
		return ""
	var pieces: Array[String] = []
	for i in range(start, args.size()):
		pieces.append(str(args[i]))
	var joined: String = " ".join(pieces)
	# If the joined text is wrapped in matching quotes, strip them. Individual
	# tokens are not unquoted because callers may legitimately pass strings
	# containing apostrophes or quote characters.
	return _unquote(joined)

func _stringify(args: Array) -> Array[String]:
	var out: Array[String] = []
	for a in args:
		out.append(str(a))
	return out

func _unquote(raw: String) -> String:
	var s := raw
	if s.length() >= 2:
		if (s.begins_with("\"") and s.ends_with("\"")) or (s.begins_with("'") and s.ends_with("'")):
			return s.substr(1, s.length() - 2)
	return s

func _split_on_regex(re: RegEx, text: String) -> Array[String]:
	var parts: Array[String] = []
	if text.is_empty():
		return parts
	var matches: Array[RegExMatch] = re.search_all(text)
	if matches.is_empty():
		parts.append(text)
		return parts
	var cursor: int = 0
	for m in matches:
		var s: int = m.get_start()
		var e: int = m.get_end()
		# A zero-width match at the cursor would loop forever; skip past it.
		if e == s:
			if s >= cursor:
				parts.append(text.substr(cursor, s - cursor))
				cursor = s + 1
			continue
		parts.append(text.substr(cursor, s - cursor))
		cursor = e
	if cursor <= text.length():
		parts.append(text.substr(cursor, text.length() - cursor))
	return parts

func _format_match_line(m: RegExMatch, _index: int) -> String:
	var captured: String = m.get_string()
	var s: int = m.get_start()
	var e: int = m.get_end()
	return "%s  %s" % [_preview(captured), _color_muted("[%d..%d]" % [s, e])]

func _preview(s: String) -> String:
	if s.length() <= _MAX_GROUP_PREVIEW:
		return s
	return s.substr(0, _MAX_GROUP_PREVIEW) + "…"

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _format_muted(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_MUTED, msg]

func _color_muted(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_MUTED, s]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

#endregion

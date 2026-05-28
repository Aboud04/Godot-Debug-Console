@tool
class_name DebugConsoleConditionalOperatorCommands extends RefCounted

# Bash-style conditional / sequential command operators (&&, ||, ;, retry).
# These commands take command-strings as arguments and dispatch back into the
# registry via execute_command, so they compose with every other registered
# command without touching the parser.
#
# Why we don't touch the parser:
#   CommandRegistry.execute_command() routes any input containing '|' through
#   execute_command_with_pipes(), which splits on '|' at the top level and
#   feeds each segment's stdout into the next segment as piped_input. That
#   pipe machinery is load-bearing for the rest of the console, so adding a
#   second meaning to '|' (conditional vs piped) inside the parser would
#   silently break every existing pipeline. Instead we treat '|' as a
#   DOCUMENTED split-point INSIDE each operator's args list, recovering the
#   intended sub-commands ourselves.
#
# How args arrive:
#   When invoked through the live console, the top-level pipe-split strips
#   '|' before we see it - so a typed `and_run a | b` is functionally just
#   `and_run a` followed by a normal pipe into `b`. Use these operators
#   either (a) via _registry.execute_command() from another script, where
#   you can keep the '|' inside a single segment, or (b) with the planned
#   parser-escape syntax. In every case, this implementation joins all args
#   back into a single string and re-splits on the literal '|' token, so
#   whatever tokenisation upstream chose, we recover the user's sub-commands
#   verbatim.

const _COLOR_ERROR := "#FF4444"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_MUTED := "#888888"

# The literal token that separates sub-commands inside an operator's args.
const _SPLIT_TOKEN := "|"

var _registry: Node
var _core: Node

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command(
		"and_run", _cmd_and_run,
		"Bash-style && : run cmd_a; if result is non-empty AND does not start with 'Error', run cmd_b. Returns the last result. Split point: literal '|' between cmd_a and cmd_b. Usage: and_run <cmd_a> | <cmd_b>",
		"both"
	)
	_registry.register_command(
		"or_run", _cmd_or_run,
		"Bash-style || : run cmd_a; if result starts with 'Error', run cmd_b instead. Returns the last result. Split point: literal '|' between cmd_a and cmd_b. Usage: or_run <cmd_a> | <cmd_b>",
		"both"
	)
	_registry.register_command(
		"then_run", _cmd_then_run,
		"Bash-style ; : run cmd_a then cmd_b unconditionally, returning both results concatenated with a newline. Split point: literal '|' between cmd_a and cmd_b. Usage: then_run <cmd_a> | <cmd_b>",
		"both"
	)
	_registry.register_command(
		"seq", _cmd_seq,
		"Generalised sequential runner: execute each sub-command in order, return every result joined by newlines. Split points: each literal '|' between sub-commands. Usage: seq <cmd1> | <cmd2> | <cmd3> ...",
		"both"
	)
	_registry.register_command(
		"with_retry", _cmd_with_retry,
		"Run <cmd> up to <n> times until the result does not start with 'Error'. Returns the successful result, or the last failing result after n attempts. Usage: with_retry <n> <cmd...>",
		"both"
	)

#region Command implementations

func _cmd_and_run(args: Array, _piped_input: String = "") -> String:
	var parts := _split_on_token(args)
	if parts.size() < 2:
		return _format_error("Usage: and_run <cmd_a> | <cmd_b>  (split point: literal '|' token)")
	var cmd_a := parts[0]
	var cmd_b := parts[1]
	if cmd_a.is_empty() or cmd_b.is_empty():
		return _format_error("and_run: both cmd_a and cmd_b must be non-empty")
	var result_a := _run(cmd_a)
	if _looks_like_error(result_a) or result_a.is_empty():
		return result_a
	return _run(cmd_b)

func _cmd_or_run(args: Array, _piped_input: String = "") -> String:
	var parts := _split_on_token(args)
	if parts.size() < 2:
		return _format_error("Usage: or_run <cmd_a> | <cmd_b>  (split point: literal '|' token)")
	var cmd_a := parts[0]
	var cmd_b := parts[1]
	if cmd_a.is_empty() or cmd_b.is_empty():
		return _format_error("or_run: both cmd_a and cmd_b must be non-empty")
	var result_a := _run(cmd_a)
	if not _looks_like_error(result_a):
		return result_a
	return _run(cmd_b)

func _cmd_then_run(args: Array, _piped_input: String = "") -> String:
	var parts := _split_on_token(args)
	if parts.size() < 2:
		return _format_error("Usage: then_run <cmd_a> | <cmd_b>  (split point: literal '|' token)")
	var cmd_a := parts[0]
	var cmd_b := parts[1]
	if cmd_a.is_empty() or cmd_b.is_empty():
		return _format_error("then_run: both cmd_a and cmd_b must be non-empty")
	var result_a := _run(cmd_a)
	var result_b := _run(cmd_b)
	return result_a + "\n" + result_b

func _cmd_seq(args: Array, _piped_input: String = "") -> String:
	var parts := _split_on_token(args)
	# Forgive trailing or doubled '|' by dropping empty sub-commands.
	var commands: Array[String] = []
	for p in parts:
		var s := p.strip_edges()
		if not s.is_empty():
			commands.append(s)
	if commands.is_empty():
		return _format_error("Usage: seq <cmd1> | <cmd2> | <cmd3> ...  (each '|' is a split point)")
	var results: Array[String] = []
	for cmd in commands:
		results.append(_run(cmd))
	return "\n".join(results)

func _cmd_with_retry(args: Array, _piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: with_retry <n> <cmd...>")
	var n_str := str(args[0]).strip_edges()
	if not n_str.is_valid_int():
		return _format_error("with_retry: <n> must be an integer, got '%s'" % n_str)
	var n := n_str.to_int()
	if n <= 0:
		return _format_error("with_retry: <n> must be > 0, got %d" % n)
	var cmd := _join_tokens(args.slice(1)).strip_edges()
	if cmd.is_empty():
		return _format_error("with_retry: <cmd> must be non-empty")

	var last_result := ""
	for attempt in range(n):
		last_result = _run(cmd)
		if not _looks_like_error(last_result):
			if attempt == 0:
				return last_result
			# Annotate so callers can tell a retry happened without parsing
			# the raw command output.
			return "%s\n%s" % [
				_format_success("with_retry succeeded on attempt %d/%d" % [attempt + 1, n]),
				last_result,
			]
	return _format_error("with_retry: '%s' failed after %d attempts. Last result:\n%s" % [cmd, n, last_result])

#endregion

#region Helpers

# Split an args array on literal '|' tokens, returning each contiguous run of
# non-'|' tokens joined with a single space and edge-stripped. This recovers
# the user's intended sub-commands without needing quoting/escaping support
# from the registry parser.
func _split_on_token(args: Array) -> Array[String]:
	var groups: Array[String] = []
	var current: Array[String] = []
	for a in args:
		var token := str(a)
		if token == _SPLIT_TOKEN:
			groups.append(_join_tokens(current).strip_edges())
			current = []
		else:
			current.append(token)
	groups.append(_join_tokens(current).strip_edges())
	return groups

func _join_tokens(tokens: Array) -> String:
	var parts: Array[String] = []
	for t in tokens:
		parts.append(str(t))
	return " ".join(parts)

func _run(cmd: String) -> String:
	if not _registry or not is_instance_valid(_registry):
		return _format_error("conditional operator: registry unavailable")
	if not _registry.has_method("execute_command"):
		return _format_error("conditional operator: registry missing execute_command")
	var raw: Variant = _registry.call("execute_command", cmd)
	return str(raw) if raw != null else ""

# _format_error wraps "Error: ..." in BBCode colour tags, so a naive
# begins_with("Error") check on the wrapped string would miss it. Strip
# BBCode first and then test the stripped form too, so we catch both
# wrapped and bare error outputs from any command in the registry.
func _looks_like_error(s: String) -> bool:
	if s.begins_with("Error"):
		return true
	var bare := _strip_bbcode(s)
	return bare.begins_with("Error")

func _strip_bbcode(s: String) -> String:
	var regex := RegEx.new()
	# Matches both opening and closing BBCode tags like [color=#x] and [/color].
	var err := regex.compile("\\[/?[^\\]]*\\]")
	if err != OK:
		return s
	return regex.sub(s, "", true)

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

#endregion

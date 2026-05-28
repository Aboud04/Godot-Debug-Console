@tool
class_name DebugConsoleHistoryModifierCommands extends RefCounted

# Bash-readline history-modifier shortcuts implemented as ordinary commands.
# Registered by BuiltInCommands the same way SceneCommands is: the orchestrator
# instantiates one of these, holds a strong reference, then calls
# register_commands(registry, core). All Callables stay valid for the lifetime
# of the plugin via that strong reference.
#
# Modeling these as commands (rather than as special syntax handled by the
# console's input LineEdit) means `!!`, `bang_n`, etc. participate in the
# normal pipe/alias/context machinery and need no parser changes. The trade-off
# is that the command name `!!` is a literal token, so users type `!! ` or
# just `!!`, never `!!something`. That matches bash's behavior for `!!` when
# it appears on its own (not as part of a word).
#
# History source - documented contract:
#   We first ask `_registry.get_command_history()`. In the stock plugin that
#   method is a stub returning [] (CommandRegistry.gd::get_command_history),
#   because the real per-session history buffer lives on the active console:
#     - EditorConsole.command_history (Array[String])
#     - GameConsole.command_history   (Array[String])
#   Those consoles append the submitted command BEFORE handing it to the
#   registry, so by the time _cmd_bang_last runs, the most-recent entry is the
#   `bang_last` (or `!!`) invocation itself. We therefore skip any entry whose
#   first token is one of the history-modifier commands when computing the
#   "previous" command. Looking up the console is done by walking the
#   SceneTree once per call (cheap, handful of nodes); we don't cache because
#   the editor may swap consoles across @tool reloads.
#
# Re-execution uses `_registry.execute_command(constructed_str)` which routes
# through the same code path as a user-typed command (including pipes). That
# call does NOT mutate the console's command_history (the console is the one
# that appends, not the registry), so re-executing `!!` does not pollute
# history with duplicates and does not break the "skip modifiers" heuristic.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"

# Commands that read or rewrite history and therefore must be skipped when we
# look backwards for the "previous user command". Kept lowercase because the
# registry lowercases command names before dispatch.
const _HISTORY_MODIFIER_COMMANDS: Array[String] = [
	"bang_last",
	"!!",
	"bang_n",
	"bang_re",
	"sub_run",
	"bang_args",
	"bang_first",
	"last_word",
]

var _registry: Node
var _core: Node

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("bang_last", _cmd_bang_last, "Re-execute the previous command (alias: !!)", "both")
	_registry.register_command("!!", _cmd_bang_last, "Re-execute the previous command (alias for bang_last)", "both")
	_registry.register_command("bang_n", _cmd_bang_n, "Re-execute the n-th history entry (1-based): bang_n <n>", "both")
	_registry.register_command("bang_re", _cmd_bang_re, "Re-execute the most recent history entry matching pattern: bang_re <pattern>", "both")
	_registry.register_command("sub_run", _cmd_sub_run, "Quick substitution on previous command and run: sub_run <old> <new>", "both")
	_registry.register_command("bang_args", _cmd_bang_args, "Print just the args of the previous command", "both")
	_registry.register_command("bang_first", _cmd_bang_first, "Print the first arg of the previous command", "both")
	_registry.register_command("last_word", _cmd_last_word, "Print the last whitespace-delimited word of the previous command", "both")

#region Command implementations

func _cmd_bang_last(_args: Array, _piped_input: String = "") -> String:
	var prev: String = _get_prev_command()
	if prev.is_empty():
		return _format_error("No previous command in history")
	return _reexecute(prev)

func _cmd_bang_n(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: bang_n <n>  (1-based index into history)")
	var raw: String = str(args[0]).strip_edges()
	if not raw.is_valid_int():
		return _format_error("bang_n expects an integer index, got: %s" % raw)
	var n: int = int(raw)
	var history: Array = _get_command_history()
	if history.is_empty():
		return _format_error("Command history is empty")
	if n < 1 or n > history.size():
		return _format_error("History index out of range: %d (have 1..%d)" % [n, history.size()])
	var entry: String = str(history[n - 1]).strip_edges()
	if entry.is_empty():
		return _format_error("History entry %d is empty" % n)
	return _reexecute(entry)

func _cmd_bang_re(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: bang_re <pattern>")
	# Treat the entire remainder as the pattern so multi-word substrings like
	# `bang_re echo hello` look for `echo hello`. Args have already been split
	# on single spaces by the registry, so re-join with a single space.
	var pattern: String = " ".join(args).strip_edges()
	if pattern.is_empty():
		return _format_error("bang_re pattern must not be empty")
	var history: Array = _get_command_history()
	if history.is_empty():
		return _format_error("Command history is empty")
	for i in range(history.size() - 1, -1, -1):
		var entry: String = str(history[i]).strip_edges()
		if entry.is_empty():
			continue
		if _is_history_modifier(entry):
			continue
		if entry.contains(pattern):
			return _reexecute(entry)
	return _format_error("No history entry matches: %s" % pattern)

func _cmd_sub_run(args: Array, _piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: sub_run <old> <new>")
	var old_text: String = str(args[0])
	var new_text: String = str(args[1])
	if old_text.is_empty():
		return _format_error("sub_run <old> must not be empty")
	var prev: String = _get_prev_command()
	if prev.is_empty():
		return _format_error("No previous command in history")
	if not prev.contains(old_text):
		return _format_error("Previous command does not contain %s: %s" % [old_text, prev])
	var substituted: String = prev.replace(old_text, new_text)
	return _reexecute(substituted)

func _cmd_bang_args(_args: Array, _piped_input: String = "") -> String:
	var prev: String = _get_prev_command()
	if prev.is_empty():
		return _format_error("No previous command in history")
	var tokens: PackedStringArray = _tokenize(prev)
	if tokens.size() < 2:
		return ""
	var args_only: Array[String] = []
	for i in range(1, tokens.size()):
		args_only.append(tokens[i])
	return " ".join(args_only)

func _cmd_bang_first(_args: Array, _piped_input: String = "") -> String:
	var prev: String = _get_prev_command()
	if prev.is_empty():
		return _format_error("No previous command in history")
	var tokens: PackedStringArray = _tokenize(prev)
	if tokens.size() < 2:
		return _format_error("Previous command has no arguments: %s" % prev)
	return tokens[1]

func _cmd_last_word(_args: Array, _piped_input: String = "") -> String:
	var prev: String = _get_prev_command()
	if prev.is_empty():
		return _format_error("No previous command in history")
	var tokens: PackedStringArray = _tokenize(prev)
	if tokens.is_empty():
		return ""
	return tokens[tokens.size() - 1]

#endregion

#region Helpers

func _reexecute(command_str: String) -> String:
	if not _registry:
		return _format_error("Command registry unavailable")
	if not _registry.has_method("execute_command"):
		return _format_error("Registry does not expose execute_command()")
	# Echo the resolved command so the user sees what `!!` (or friends)
	# actually ran. Then re-route through the registry, which handles pipes,
	# context filtering, and aliases identically to a user-typed command.
	var echoed: String = "[color=%s]> %s[/color]" % [_COLOR_PATH, command_str]
	var result: Variant = _registry.execute_command(command_str)
	var result_str: String = str(result) if result != null else ""
	if result_str.is_empty():
		return echoed
	return "%s\n%s" % [echoed, result_str]

func _get_prev_command() -> String:
	var history: Array = _get_command_history()
	if history.is_empty():
		return ""
	for i in range(history.size() - 1, -1, -1):
		var entry: String = str(history[i]).strip_edges()
		if entry.is_empty():
			continue
		if _is_history_modifier(entry):
			continue
		return entry
	return ""

func _is_history_modifier(command_str: String) -> bool:
	var tokens: PackedStringArray = _tokenize(command_str)
	if tokens.is_empty():
		return false
	var head: String = tokens[0].to_lower()
	return _HISTORY_MODIFIER_COMMANDS.has(head)

func _tokenize(command_str: String) -> PackedStringArray:
	# Match the registry's own splitting (CommandRegistry._execute_single_command
	# uses split(" ", false)) so "first arg" / "args" / "last word" line up
	# with how the rest of the system already sees a command.
	return command_str.strip_edges().split(" ", false)

func _get_command_history() -> Array:
	# Preferred path: ask the registry. The stock CommandRegistry stub returns
	# [] but a host project may legitimately swap in a registry that owns the
	# buffer, so we honor a non-empty result first.
	if _registry and _registry.has_method("get_command_history"):
		var registry_history: Variant = _registry.get_command_history()
		if registry_history is Array and (registry_history as Array).size() > 0:
			return registry_history
	# Fallback: the active console owns the buffer. EditorConsole and
	# GameConsole both expose `command_history: Array[String]`. Walk the
	# SceneTree once and return the first match. Cheap in practice (consoles
	# live near the root) and avoids hard-coding node paths that change
	# between editor and game contexts.
	var tree := Engine.get_main_loop() as SceneTree
	if not tree or not tree.root:
		return []
	var found: Node = _find_console_with_history(tree.root)
	if found:
		var value: Variant = found.get("command_history")
		if value is Array:
			return value
	return []

func _find_console_with_history(node: Node) -> Node:
	if not node:
		return null
	var value: Variant = node.get("command_history")
	if value is Array:
		return node
	for child in node.get_children():
		var hit: Node = _find_console_with_history(child)
		if hit:
			return hit
	return null

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

#endregion

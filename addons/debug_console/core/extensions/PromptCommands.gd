@tool
class_name DebugConsolePromptCommands extends RefCounted

# Blocking-style prompt commands. These are designed for scripts and pipelines
# that need to halt mid-execution, ask the user a question, and resume with
# the typed/selected value.
#
# ----------------------------------------------------------------------------
# CRITICAL: BLOCKING SEMANTICS
# ----------------------------------------------------------------------------
# Each prompt command is an *async coroutine*: it spawns a Window dialog and
# suspends on `await ...process_frame` until the user answers. The return
# value flows back to whatever `await`s the function call.
#
# However, the project's CommandRegistry invokes commands via
# `callable.callv(...)` (see core/CommandRegistry.gd:112) and immediately
# stringifies the result. There is NO `await` between the dispatcher and the
# command. That means when a sync caller (the default console line, a piped
# command, or any non-await invocation) runs `ask`, the dispatcher will see
# the coroutine's *first-suspension* value - typically empty - NOT the user's
# eventual answer.
#
# Two ways to consume an answer reliably:
#
#   1. Await directly from a script that holds a reference to this module:
#          var prompts := DebugConsolePromptCommands.new()
#          prompts.register_commands(registry, core)
#          var name: String = await prompts._cmd_ask(["What", "is", "your", "name?"])
#
#   2. Watch the console output. Every prompt also pushes its final result
#      through `_emit_result(...)`, so sync callers can read the answer from
#      the same sink that DialogCommands uses (DebugCore.info / print_to_console
#      / registry echo). This is *observational*, not return-value flow - it
#      cannot be assigned to a variable from within a sync pipeline.
#
# A one-shot warning is emitted the first time any prompt fires per session,
# so users diagnosing "why is ask returning empty?" see the explanation in
# the console without it spamming every subsequent prompt.
#
# ----------------------------------------------------------------------------
# REGISTRATION LIFETIME
# ----------------------------------------------------------------------------
# This module follows the same pattern as DialogCommands / SceneCommands /
# AssertCommands: the orchestrator (BuiltInCommands.register_universal_commands)
# instantiates one, holds a strong reference, and calls register_commands.
# Callables stay valid for the lifetime of the plugin because the orchestrator
# keeps this RefCounted alive.

const _COLOR_ERROR := "#FF4444"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_ID := "#F7DC6F"
const _COLOR_WARN := "#FFB347"
const _COLOR_VALUE := "#5FBEE0"

var _registry: Node
var _core: Node

# Maps prompt_id -> Window node currently awaiting user input. Mirrored after
# DialogCommands._active; removed in `_on_prompt_finalized` once the dialog
# closes for any reason (confirmed / canceled / close_requested / timeout).
var _active: Dictionary = {}

# Monotonic ID counter. Format `prompt_N` keeps the token short for log lines
# and avoids confusion with DialogCommands' `dlg_N` IDs in mixed output.
var _next_id_counter: int = 0

# Set true after the first sync-warning fires; the warning then stays silent
# for the rest of the session so dense scripted pipelines do not get spammed.
var _sync_warning_emitted: bool = false

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	# All prompts are runtime-only: dialogs need a live SceneTree and the
	# `process_frame` await loop only ticks reliably in a running game. The
	# editor's @tool main loop technically ticks too, but the user request
	# explicitly scoped this module to "game context".
	_registry.register_command("ask", _cmd_ask,
		"Prompt for free-form text (blocking; awaits user): ask <message>",
		"game")
	_registry.register_command("ask_yn", _cmd_ask_yn,
		"Prompt yes/no (blocking; returns 'yes' or 'no'): ask_yn <message>",
		"game")
	_registry.register_command("ask_select", _cmd_ask_select,
		"Prompt for one of several options (blocking): ask_select <message> <opt1,opt2,opt3>  (use commas; '|' is reserved by the pipe parser)",
		"game")
	_registry.register_command("ask_file", _cmd_ask_file,
		"Prompt for a file path via FileDialog (blocking): ask_file <prompt>",
		"game")
	_registry.register_command("ask_password", _cmd_ask_password,
		"Prompt for a masked LineEdit value (blocking): ask_password <message>",
		"game")
	_registry.register_command("ask_timeout", _cmd_ask_timeout,
		"Prompt with auto-cancel after N seconds (blocking; returns '' on timeout): ask_timeout <message> <secs>",
		"game")

#region commands

func _cmd_ask(args: Array) -> String:
	var message: String = _join_args(args).strip_edges()
	if message.is_empty():
		return _format_error("Usage: ask <message>")

	var root: Node = _get_root_for_dialog()
	if not root:
		return _format_error("ask: no SceneTree root available")

	var id: String = _next_id()
	_emit_sync_warning_once(id)

	# AcceptDialog + LineEdit mirrors DialogCommands._cmd_dialog_input so the
	# user sees a consistent prompt UX across the plugin.
	var dialog: AcceptDialog = AcceptDialog.new()
	dialog.title = "Prompt"
	dialog.dialog_text = message
	dialog.name = "DebugConsolePrompt_%s" % id
	var line_edit: LineEdit = LineEdit.new()
	line_edit.name = "Input"
	line_edit.custom_minimum_size = Vector2(320, 0)
	dialog.add_child(line_edit)
	# Submit-on-Enter feels native; without this the user must mouse to OK.
	line_edit.text_submitted.connect(func(_t: String): dialog.confirmed.emit())

	root.add_child(dialog)
	_active[id] = dialog
	dialog.popup_centered()
	line_edit.call_deferred("grab_focus")

	# state[0] = done, state[1] = captured result. Array container is required
	# because GDScript lambdas need a reference-typed binding to mutate a
	# value visible to the awaiting outer scope.
	var state: Array = [false, ""]
	var on_confirm: Callable = func():
		if state[0]: return
		state[0] = true
		state[1] = line_edit.text if is_instance_valid(line_edit) else ""
	var on_cancel: Callable = func():
		if state[0]: return
		state[0] = true
		state[1] = ""
	dialog.confirmed.connect(on_confirm)
	dialog.canceled.connect(on_cancel)
	dialog.close_requested.connect(on_cancel)

	await _await_state(state)
	_on_prompt_finalized(id)
	var answer: String = str(state[1])
	_emit_result(id, "Ask %s: %s" % [_color_id(id), _color_value(answer)])
	return answer

func _cmd_ask_yn(args: Array) -> String:
	var message: String = _join_args(args).strip_edges()
	if message.is_empty():
		return _format_error("Usage: ask_yn <message>")

	var root: Node = _get_root_for_dialog()
	if not root:
		return _format_error("ask_yn: no SceneTree root available")

	var id: String = _next_id()
	_emit_sync_warning_once(id)

	var dialog: ConfirmationDialog = ConfirmationDialog.new()
	dialog.title = "Confirm"
	dialog.dialog_text = message
	dialog.name = "DebugConsolePrompt_%s" % id
	dialog.get_ok_button().text = "Yes"
	dialog.get_cancel_button().text = "No"
	root.add_child(dialog)
	_active[id] = dialog
	dialog.popup_centered()

	var state: Array = [false, "no"]
	var on_yes: Callable = func():
		if state[0]: return
		state[0] = true
		state[1] = "yes"
	var on_no: Callable = func():
		if state[0]: return
		state[0] = true
		state[1] = "no"
	dialog.confirmed.connect(on_yes)
	dialog.canceled.connect(on_no)
	# close_requested = X button; treat as "no" because anything else surprises
	# scripted callers that assumed a binary answer.
	dialog.close_requested.connect(on_no)

	await _await_state(state)
	_on_prompt_finalized(id)
	var answer: String = str(state[1])
	_emit_result(id, "Ask y/n %s: %s" % [_color_id(id), _color_value(answer)])
	return answer

func _cmd_ask_select(args: Array) -> String:
	if args.size() < 2:
		return _format_error("Usage: ask_select <message> <opt1,opt2,opt3>  (use commas; '|' is reserved by the pipe parser)")

	# Convention: the LAST arg holds the option list, everything before it is
	# the message. We accept BOTH `,` and `|` as in-token separators so direct
	# programmatic callers can use the natural pipe syntax even though the
	# console's pipe parser strips literal `|` before commands ever see them.
	var options_token: String = str(args[args.size() - 1]).strip_edges()
	var message_parts: Array = args.slice(0, args.size() - 1)
	var message: String = _join_args(message_parts).strip_edges()
	if message.is_empty():
		return _format_error("ask_select: message cannot be empty")

	var options: Array[String] = []
	for raw in options_token.replace("|", ",").split(",", false):
		var opt: String = String(raw).strip_edges()
		if not opt.is_empty():
			options.append(opt)
	if options.is_empty():
		return _format_error("ask_select: need at least one option")

	var root: Node = _get_root_for_dialog()
	if not root:
		return _format_error("ask_select: no SceneTree root available")

	var id: String = _next_id()
	_emit_sync_warning_once(id)

	var dialog: AcceptDialog = AcceptDialog.new()
	dialog.title = "Select"
	dialog.dialog_text = message
	dialog.name = "DebugConsolePrompt_%s" % id

	var option_button: OptionButton = OptionButton.new()
	option_button.name = "Options"
	option_button.custom_minimum_size = Vector2(320, 0)
	for opt_text in options:
		option_button.add_item(opt_text)
	option_button.select(0)
	dialog.add_child(option_button)

	root.add_child(dialog)
	_active[id] = dialog
	dialog.popup_centered()

	var state: Array = [false, ""]
	var on_confirm: Callable = func():
		if state[0]: return
		state[0] = true
		# Re-read selection at confirm-time rather than caching, in case the
		# user changed their mind right before clicking OK.
		var idx: int = option_button.selected if is_instance_valid(option_button) else -1
		state[1] = option_button.get_item_text(idx) if idx >= 0 and is_instance_valid(option_button) else ""
	var on_cancel: Callable = func():
		if state[0]: return
		state[0] = true
		state[1] = ""
	dialog.confirmed.connect(on_confirm)
	dialog.canceled.connect(on_cancel)
	dialog.close_requested.connect(on_cancel)

	await _await_state(state)
	_on_prompt_finalized(id)
	var answer: String = str(state[1])
	_emit_result(id, "Ask select %s: %s" % [_color_id(id), _color_value(answer)])
	return answer

func _cmd_ask_file(args: Array) -> String:
	# The prompt text is purely a label set on the dialog title; FileDialog
	# does not surface a `dialog_text` field the way AcceptDialog does, so we
	# use the title as the user-visible hint.
	var prompt: String = _join_args(args).strip_edges()
	if prompt.is_empty():
		prompt = "Select a file"

	var root: Node = _get_root_for_dialog()
	if not root:
		return _format_error("ask_file: no SceneTree root available")

	var id: String = _next_id()
	_emit_sync_warning_once(id)

	var dialog: FileDialog = FileDialog.new()
	dialog.title = prompt
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	# ACCESS_RESOURCES matches DialogCommands' file dialogs and keeps the
	# picker pointed at the project. Callers who need user:// or absolute
	# paths can adjust the spawned FileDialog before it pops up - but that
	# requires a more elaborate sub-API than the simple 6-command surface.
	dialog.access = FileDialog.ACCESS_RESOURCES
	dialog.current_dir = "res://"
	dialog.name = "DebugConsolePrompt_%s" % id

	root.add_child(dialog)
	_active[id] = dialog
	dialog.popup_centered(Vector2i(720, 480))

	var state: Array = [false, ""]
	var on_selected: Callable = func(path: String):
		if state[0]: return
		state[0] = true
		state[1] = path
	var on_cancel: Callable = func():
		if state[0]: return
		state[0] = true
		state[1] = ""
	dialog.file_selected.connect(on_selected)
	dialog.canceled.connect(on_cancel)
	dialog.close_requested.connect(on_cancel)

	await _await_state(state)
	_on_prompt_finalized(id)
	var answer: String = str(state[1])
	_emit_result(id, "Ask file %s: %s" % [_color_id(id), _color_value(answer)])
	return answer

func _cmd_ask_password(args: Array) -> String:
	var message: String = _join_args(args).strip_edges()
	if message.is_empty():
		return _format_error("Usage: ask_password <message>")

	var root: Node = _get_root_for_dialog()
	if not root:
		return _format_error("ask_password: no SceneTree root available")

	var id: String = _next_id()
	_emit_sync_warning_once(id)

	var dialog: AcceptDialog = AcceptDialog.new()
	dialog.title = "Password"
	dialog.dialog_text = message
	dialog.name = "DebugConsolePrompt_%s" % id
	var line_edit: LineEdit = LineEdit.new()
	line_edit.name = "Input"
	line_edit.custom_minimum_size = Vector2(320, 0)
	# secret=true is what the spec asks for: masks the text on screen. The
	# value is still in plain text on read, so the prompt is "secret" only in
	# the visual sense - do NOT pretend this is a credential vault.
	line_edit.secret = true
	dialog.add_child(line_edit)
	line_edit.text_submitted.connect(func(_t: String): dialog.confirmed.emit())

	root.add_child(dialog)
	_active[id] = dialog
	dialog.popup_centered()
	line_edit.call_deferred("grab_focus")

	var state: Array = [false, ""]
	var on_confirm: Callable = func():
		if state[0]: return
		state[0] = true
		state[1] = line_edit.text if is_instance_valid(line_edit) else ""
	var on_cancel: Callable = func():
		if state[0]: return
		state[0] = true
		state[1] = ""
	dialog.confirmed.connect(on_confirm)
	dialog.canceled.connect(on_cancel)
	dialog.close_requested.connect(on_cancel)

	await _await_state(state)
	_on_prompt_finalized(id)
	var answer: String = str(state[1])
	# Echo a masked confirmation only - never log the typed password to the
	# console sink. Length still leaks the magnitude, which is the standard
	# trade-off for "show me whether the user typed anything".
	var masked: String = "*".repeat(answer.length()) if not answer.is_empty() else "(empty)"
	_emit_result(id, "Ask password %s: %s" % [_color_id(id), _color_value(masked)])
	return answer

func _cmd_ask_timeout(args: Array) -> String:
	if args.size() < 2:
		return _format_error("Usage: ask_timeout <message> <secs>")

	# Last arg is the timeout, everything before it is the message. Matches
	# the parsing convention used by ask_select.
	var secs_token: String = str(args[args.size() - 1]).strip_edges()
	if not secs_token.is_valid_float():
		return _format_error("ask_timeout: '%s' is not a number" % secs_token)
	var secs: float = secs_token.to_float()
	if secs <= 0.0:
		return _format_error("ask_timeout: timeout must be > 0 (got %s)" % secs_token)
	var message_parts: Array = args.slice(0, args.size() - 1)
	var message: String = _join_args(message_parts).strip_edges()
	if message.is_empty():
		return _format_error("ask_timeout: message cannot be empty")

	var root: Node = _get_root_for_dialog()
	if not root:
		return _format_error("ask_timeout: no SceneTree root available")

	var id: String = _next_id()
	_emit_sync_warning_once(id)

	var dialog: AcceptDialog = AcceptDialog.new()
	dialog.title = "Prompt (%.1fs)" % secs
	dialog.dialog_text = message
	dialog.name = "DebugConsolePrompt_%s" % id
	var line_edit: LineEdit = LineEdit.new()
	line_edit.name = "Input"
	line_edit.custom_minimum_size = Vector2(320, 0)
	dialog.add_child(line_edit)
	line_edit.text_submitted.connect(func(_t: String): dialog.confirmed.emit())

	root.add_child(dialog)
	_active[id] = dialog
	dialog.popup_centered()
	line_edit.call_deferred("grab_focus")

	var state: Array = [false, ""]
	var on_confirm: Callable = func():
		if state[0]: return
		state[0] = true
		state[1] = line_edit.text if is_instance_valid(line_edit) else ""
	var on_cancel: Callable = func():
		if state[0]: return
		state[0] = true
		state[1] = ""
	dialog.confirmed.connect(on_confirm)
	dialog.canceled.connect(on_cancel)
	dialog.close_requested.connect(on_cancel)

	# Race the dialog against a wall-clock deadline. Time.get_ticks_msec is
	# monotonic and unaffected by Engine.time_scale, which is what we want -
	# `ask_timeout 30` should mean 30 real seconds even if the user paused
	# the game with a slow-mo cheat.
	var deadline_ms: int = Time.get_ticks_msec() + int(secs * 1000.0)
	var timed_out: bool = await _await_state_or_deadline(state, deadline_ms)

	if timed_out:
		# Spec: timeout returns "". We also forcibly free the dialog because
		# the user did not dismiss it, so it would otherwise leak on screen.
		if is_instance_valid(dialog):
			dialog.queue_free()
		_active.erase(id)
		_emit_result(id, "Ask timeout %s: timed out after %.1fs" % [_color_id(id), secs])
		return ""

	_on_prompt_finalized(id)
	var answer: String = str(state[1])
	_emit_result(id, "Ask timeout %s: %s" % [_color_id(id), _color_value(answer)])
	return answer

#endregion

#region helpers

# Polls the shared state container once per frame until the signal handlers
# flip state[0] to true. The await target is `process_frame` rather than a
# bespoke signal so we can reuse the same loop across all commands AND layer
# a deadline check on top of it (see _await_state_or_deadline below).
func _await_state(state: Array) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if not tree:
		# No SceneTree means we can't await anything. The state will never
		# flip, so we'd hang forever - return immediately and let the caller
		# see whatever default state[1] held.
		return
	while not bool(state[0]):
		await tree.process_frame

# Same as _await_state but also bails out when wall-clock time passes
# `deadline_ms`. Returns true if the deadline fired before the user answered.
func _await_state_or_deadline(state: Array, deadline_ms: int) -> bool:
	var tree := Engine.get_main_loop() as SceneTree
	if not tree:
		return false
	while not bool(state[0]):
		if Time.get_ticks_msec() >= deadline_ms:
			return true
		await tree.process_frame
	return false

# Common cleanup: free the dialog node (if it is still valid; signal handlers
# may have already triggered queue_free elsewhere) and drop our tracking
# entry. Kept symmetric with DialogCommands._on_dialog_finalized for parity.
func _on_prompt_finalized(id: String) -> void:
	if _active.has(id):
		var dialog = _active.get(id)
		if is_instance_valid(dialog):
			dialog.queue_free()
		_active.erase(id)

# Returns the Node that newly created dialogs should be parented to. Same
# rationale as DialogCommands._get_root_for_dialog: SceneTree.root is the
# only universally-valid parent at runtime because `current_scene` can be
# null mid-transition. We do not need the editor branch here because prompt
# commands register as "game"-only.
func _get_root_for_dialog() -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if not tree:
		return null
	return tree.root

# Generates the next prompt ID. The `prompt_` prefix distinguishes these from
# DialogCommands' `dlg_` IDs in shared output, which matters because both
# modules emit through the same _emit_result sink.
func _next_id() -> String:
	_next_id_counter += 1
	return "prompt_%d" % _next_id_counter

# Single-fire warning explaining the sync-caller caveat. Emitting once per
# session keeps the message visible during discovery without polluting tight
# scripted loops that fire prompts in a tight cycle.
func _emit_sync_warning_once(id: String) -> void:
	if _sync_warning_emitted:
		return
	_sync_warning_emitted = true
	var msg: String = "[color=%s]%s: prompts are async - sync console/pipe callers will receive '' immediately and must read the answer from this console sink (see %s). For an actual return value, await the command from a script that holds the module instance.[/color]" % [
		_COLOR_WARN,
		_color_id(id),
		_color_id("prompt_*"),
	]
	_emit_result(id, msg)

# Result delivery mirrors DialogCommands._emit_result so prompt output lands
# in the same sink the rest of the plugin uses. The cascade is intentional:
# `print_to_console` is the documented forward-compat hook, `info` is the
# current DebugCore API, and the registry-echo / print fallbacks keep
# results visible even if both core entry points are missing (e.g. unit
# tests that instantiate the registry without a full DebugCore).
func _emit_result(id: String, msg: String) -> void:
	if _core and is_instance_valid(_core):
		if _core.has_method("print_to_console"):
			_core.call("print_to_console", msg)
			return
		if _core.has_method("info"):
			_core.call("info", msg)
			return
	if _registry and is_instance_valid(_registry) and _registry.has_method("execute_command"):
		_registry.call("execute_command", "echo " + msg)
		return
	print(msg)

# Joins free-form arg tokens with single spaces. CommandRegistry splits the
# raw command line on whitespace before calling us, so `ask Are you sure?`
# arrives as ['Are', 'you', 'sure?'] and we need to glue it back. Same shape
# as DialogCommands._join_args - kept private here so this module stays
# self-contained per the orchestrator convention.
func _join_args(args: Array) -> String:
	var parts: Array = []
	for a in args:
		parts.append(str(a))
	return " ".join(parts)

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_id(id: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_ID, id]

func _color_value(v: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_VALUE, v]

#endregion

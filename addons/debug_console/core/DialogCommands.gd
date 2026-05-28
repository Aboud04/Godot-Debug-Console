@tool
class_name DebugConsoleDialogCommands extends RefCounted

# Spawns Godot's built-in modal dialogs (AcceptDialog,
# ConfirmationDialog, FileDialog, ColorPicker host Window) from the console.
# Dialogs are inherently asynchronous: the command returns immediately with an
# awaiting ID, and the user's response is delivered to the console output via
# `_emit_result` once the dialog signal fires.
#
# Lifetime: every spawned dialog is registered in `_active` keyed by its ID
# and removed when it is dismissed (via `dialog_dismiss` or its own
# close_requested / canceled / confirmed signal). The module itself is held
# by the orchestrator (BuiltInCommands.register_universal_commands), which
# keeps the Callables alive for the whole plugin lifetime.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_ID := "#F7DC6F"
const _COLOR_TYPE := "#C792EA"

var _registry: Node
var _core: Node

# Maps dialog_id -> Window node currently awaiting user input. Removed when
# the dialog finalizes (confirmed / canceled / close_requested / dismissed).
var _active: Dictionary = {}

# Monotonic counter so IDs stay unique across the session even after old
# dialogs are dismissed. Starts at 1 so the first ID is `dlg_1`, which reads
# more naturally than `dlg_0` in user-facing messages.
var _next_id_counter: int = 0

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("dialog_alert", _cmd_dialog_alert, "Show an AcceptDialog: dialog_alert <message>", "both")
	_registry.register_command("dialog_confirm", _cmd_dialog_confirm, "Show a ConfirmationDialog: dialog_confirm <message>", "both")
	_registry.register_command("dialog_input", _cmd_dialog_input, "Show an input prompt: dialog_input <prompt> [default_value]", "both")
	_registry.register_command("dialog_file", _cmd_dialog_file, "Open-file dialog: dialog_file [pattern] [dir]", "editor")
	_registry.register_command("dialog_save_file", _cmd_dialog_save_file, "Save-file dialog: dialog_save_file [pattern] [dir]", "editor")
	_registry.register_command("dialog_color", _cmd_dialog_color, "Color picker dialog: dialog_color [initial_hex]", "both")
	_registry.register_command("dialog_dismiss", _cmd_dialog_dismiss, "Dismiss active dialog(s): dialog_dismiss [id|all]", "both")
	_registry.register_command("dialog_list", _cmd_dialog_list, "List active dialogs awaiting input: dialog_list", "both")

#region commands

func _cmd_dialog_alert(args: Array) -> String:
	var message: String = _join_args(args).strip_edges()
	if message.is_empty():
		return _format_error("Usage: dialog_alert <message>")

	var root: Node = _get_root_for_dialog()
	if not root:
		return _format_error("dialog_alert: no SceneTree root available")

	var id: String = _next_id()
	var dialog: AcceptDialog = AcceptDialog.new()
	dialog.title = "Alert"
	dialog.dialog_text = message
	dialog.name = "DebugConsoleDialog_%s" % id
	root.add_child(dialog)

	# AcceptDialog auto-frees on close by default, but we still bind a
	# cleanup callback so `_active` stays in sync. `Object.has_signal` guards
	# are unnecessary - these signals exist on every AcceptDialog in Godot 4.
	var cleanup: Callable = func(): _on_dialog_finalized(id, "Alert dismissed")
	dialog.confirmed.connect(cleanup)
	dialog.canceled.connect(cleanup)
	dialog.close_requested.connect(cleanup)

	_active[id] = dialog
	dialog.popup_centered()
	return _format_success("Alert shown: %s" % _color_id(id))

func _cmd_dialog_confirm(args: Array) -> String:
	var message: String = _join_args(args).strip_edges()
	if message.is_empty():
		return _format_error("Usage: dialog_confirm <message>")

	var root: Node = _get_root_for_dialog()
	if not root:
		return _format_error("dialog_confirm: no SceneTree root available")

	var id: String = _next_id()
	var dialog: ConfirmationDialog = ConfirmationDialog.new()
	dialog.title = "Confirm"
	dialog.dialog_text = message
	dialog.name = "DebugConsoleDialog_%s" % id
	root.add_child(dialog)

	# Use a small router so all three terminal signals share the same cleanup
	# path. close_requested fires when the user clicks the window X button,
	# which we treat as a cancel.
	var on_confirm: Callable = func():
		_emit_result(id, "Confirmation %s: accepted" % id)
		_on_dialog_finalized(id, "")
	var on_cancel: Callable = func():
		_emit_result(id, "Confirmation %s: cancelled" % id)
		_on_dialog_finalized(id, "")
	dialog.confirmed.connect(on_confirm)
	dialog.canceled.connect(on_cancel)
	dialog.close_requested.connect(on_cancel)

	_active[id] = dialog
	dialog.popup_centered()
	return _format_success("Awaiting user response: %s" % _color_id(id))

func _cmd_dialog_input(args: Array) -> String:
	if args.is_empty():
		return _format_error("Usage: dialog_input <prompt> [default_value]")
	# The prompt is a single token unless quoted; the default is the second
	# token if present. This mirrors how SceneCommands treats trailing args.
	var prompt: String = str(args[0]).strip_edges()
	var default_value: String = ""
	if args.size() > 1:
		default_value = str(args[1])
	if prompt.is_empty():
		return _format_error("dialog_input: prompt cannot be empty")

	var root: Node = _get_root_for_dialog()
	if not root:
		return _format_error("dialog_input: no SceneTree root available")

	var id: String = _next_id()
	var dialog: AcceptDialog = AcceptDialog.new()
	dialog.title = "Input"
	dialog.name = "DebugConsoleDialog_%s" % id
	# AcceptDialog ships with `dialog_text` rendered above the content. We use
	# that for the prompt and then add a LineEdit as the editable body via
	# `add_child` - simpler than overriding the whole layout with a VBox.
	dialog.dialog_text = prompt
	var line_edit: LineEdit = LineEdit.new()
	line_edit.text = default_value
	line_edit.custom_minimum_size = Vector2(280, 0)
	line_edit.name = "Input"
	dialog.add_child(line_edit)
	# Wire Enter on the LineEdit to the dialog's OK so submission feels
	# natural; otherwise the user has to click the button explicitly.
	line_edit.text_submitted.connect(func(_t: String): dialog.confirmed.emit())

	root.add_child(dialog)

	# Captured LineEdit ref is safe because the lambda only runs while the
	# dialog is alive (we disconnect implicitly by freeing on cleanup).
	var on_confirm: Callable = func():
		var typed: String = line_edit.text if is_instance_valid(line_edit) else ""
		_emit_result(id, "Input %s: %s" % [id, typed])
		_on_dialog_finalized(id, "")
	var on_cancel: Callable = func():
		_emit_result(id, "Input %s: cancelled" % id)
		_on_dialog_finalized(id, "")
	dialog.confirmed.connect(on_confirm)
	dialog.canceled.connect(on_cancel)
	dialog.close_requested.connect(on_cancel)

	_active[id] = dialog
	dialog.popup_centered()
	# Defer grab_focus so the LineEdit is in the tree and visible before the
	# focus request lands, otherwise Godot swallows the grab.
	line_edit.call_deferred("grab_focus")
	return _format_success("Awaiting input: %s" % _color_id(id))

func _cmd_dialog_file(args: Array) -> String:
	return _spawn_file_dialog(args, FileDialog.FILE_MODE_OPEN_FILE, "Open File")

func _cmd_dialog_save_file(args: Array) -> String:
	return _spawn_file_dialog(args, FileDialog.FILE_MODE_SAVE_FILE, "Save File")

func _cmd_dialog_color(args: Array) -> String:
	var initial_hex: String = str(args[0]).strip_edges() if args.size() > 0 else ""
	var initial_color: Color = Color.WHITE
	if not initial_hex.is_empty():
		if not initial_hex.begins_with("#"):
			initial_hex = "#" + initial_hex
		if Color.html_is_valid(initial_hex):
			initial_color = Color.html(initial_hex)
		else:
			return _format_error("dialog_color: invalid hex '%s'" % initial_hex)

	var root: Node = _get_root_for_dialog()
	if not root:
		return _format_error("dialog_color: no SceneTree root available")

	var id: String = _next_id()
	# AcceptDialog hosts the ColorPicker so we get an OK/Cancel pair for free
	# instead of inventing one with a bare Window + buttons.
	var dialog: AcceptDialog = AcceptDialog.new()
	dialog.title = "Pick Color"
	dialog.name = "DebugConsoleDialog_%s" % id
	var picker: ColorPicker = ColorPicker.new()
	picker.color = initial_color
	picker.name = "Picker"
	dialog.add_child(picker)
	root.add_child(dialog)

	var on_confirm: Callable = func():
		var c: Color = picker.color if is_instance_valid(picker) else initial_color
		_emit_result(id, "Color %s: #%s" % [id, c.to_html(false)])
		_on_dialog_finalized(id, "")
	var on_cancel: Callable = func():
		_emit_result(id, "Color %s: cancelled" % id)
		_on_dialog_finalized(id, "")
	dialog.confirmed.connect(on_confirm)
	dialog.canceled.connect(on_cancel)
	dialog.close_requested.connect(on_cancel)

	_active[id] = dialog
	dialog.popup_centered(Vector2i(420, 520))
	return _format_success("Awaiting color: %s" % _color_id(id))

func _cmd_dialog_dismiss(args: Array) -> String:
	if _active.is_empty():
		return "No active dialogs to dismiss"

	var target: String = str(args[0]).strip_edges().to_lower() if args.size() > 0 else "all"
	if target.is_empty():
		target = "all"

	if target == "all":
		var count: int = _active.size()
		# Snapshot the keys before iterating because _on_dialog_finalized
		# mutates _active and would invalidate a live iterator otherwise.
		var ids: Array = _active.keys().duplicate()
		for id in ids:
			var dialog = _active.get(id)
			if is_instance_valid(dialog):
				dialog.queue_free()
			_active.erase(id)
		return _format_success("Dismissed %d dialog(s)" % count)

	if not _active.has(target):
		return _format_error("dialog_dismiss: no active dialog with id '%s'" % target)
	var dialog = _active.get(target)
	if is_instance_valid(dialog):
		dialog.queue_free()
	_active.erase(target)
	return _format_success("Dismissed dialog %s" % _color_id(target))

func _cmd_dialog_list(args: Array) -> String:
	if _active.is_empty():
		return "No active dialogs"
	# Sort IDs so the output is deterministic across calls. Dictionary key
	# order in GDScript is insertion order, which is fine in practice, but a
	# sort makes tests and logs easier to diff.
	var ids: Array = _active.keys()
	ids.sort()
	var lines: Array[String] = []
	lines.append("Active dialogs (%d):" % _active.size())
	for id in ids:
		var dialog = _active.get(id)
		var type_str: String = dialog.get_class() if is_instance_valid(dialog) else "<freed>"
		lines.append("  %s  [%s]" % [_color_id(str(id)), _color_type(type_str)])
	return "\n".join(lines)

#endregion

#region helpers

# Generates the next dialog ID. Format `dlg_N` matches the spec and keeps the
# token short enough to type back into `dialog_dismiss <id>` from the console.
func _next_id() -> String:
	_next_id_counter += 1
	return "dlg_%d" % _next_id_counter

# Returns the Node that newly created dialogs should be parented to.
# - In editor (@tool) context, prefer the edited scene root so the dialog
#   appears on top of the open scene's editor viewport rather than getting
#   orphaned to the engine root.
# - At runtime, the SceneTree's `root` Window is the only universally-valid
#   parent because `current_scene` can be null mid-transition.
func _get_root_for_dialog() -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if not tree:
		return null
	if Engine.is_editor_hint():
		# EditorInterface is exposed as an Engine singleton only inside @tool
		# scripts when the editor is running. Using has_singleton avoids a
		# hard crash if this script is loaded headlessly.
		if Engine.has_singleton("EditorInterface"):
			var ei = Engine.get_singleton("EditorInterface")
			if ei and ei.has_method("get_base_control"):
				var base = ei.get_base_control()
				if base:
					return base
			if ei and ei.has_method("get_edited_scene_root"):
				var edited = ei.get_edited_scene_root()
				if edited:
					return edited
		# Fallback: tree root works in headless editor runs (e.g. CI).
		return tree.root
	return tree.root

# Async result delivery. Tries `_core.print_to_console` first (forward-compat
# hook documented for future DebugCore versions). Falls back to `_core.info`
# (current API, see DebugCore.gd:58). Last resort echoes via the registry so
# the line still surfaces in any output sink that subscribes to
# `command_executed`. Finally degrades to plain `print()` so a developer
# watching the OS console still sees the result during unit tests.
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

# Common cleanup path for any dialog finalization. Optional follow-up message
# lets caller emit a status note (e.g. "Alert dismissed") through the same
# delivery channel the user-facing results use.
func _on_dialog_finalized(id: String, follow_up: String) -> void:
	if _active.has(id):
		var dialog = _active.get(id)
		if is_instance_valid(dialog):
			dialog.queue_free()
		_active.erase(id)
	if not follow_up.is_empty():
		_emit_result(id, follow_up)

# Shared body for `dialog_file` / `dialog_save_file`. Splitting only the
# file_mode + title keeps the two commands aligned when pattern parsing,
# parent resolution, or signal wiring changes later.
func _spawn_file_dialog(args: Array, file_mode: int, title: String) -> String:
	var pattern: String = str(args[0]).strip_edges() if args.size() > 0 else "*.tscn,*.gd"
	var dir: String = str(args[1]).strip_edges() if args.size() > 1 else "res://"

	var root: Node = _get_root_for_dialog()
	if not root:
		return _format_error("dialog_file: no SceneTree root available")

	var id: String = _next_id()
	var dialog: FileDialog = FileDialog.new()
	dialog.title = title
	dialog.file_mode = file_mode
	dialog.access = FileDialog.ACCESS_RESOURCES
	dialog.current_dir = dir
	dialog.name = "DebugConsoleDialog_%s" % id

	# FileDialog expects each extension as its own filter string of the form
	# "*.gd ; GDScript". Splitting on comma lets the user pass several
	# patterns in one CLI token (`*.tscn,*.gd`).
	var filters: PackedStringArray = []
	for raw in pattern.split(",", false):
		var ext: String = String(raw).strip_edges()
		if not ext.is_empty():
			filters.append(ext)
	dialog.filters = filters

	root.add_child(dialog)

	# OPEN_FILE emits file_selected; SAVE_FILE also emits file_selected. We
	# wire both to the same handler because the payload (a single path) is
	# identical between the two modes.
	var on_selected: Callable = func(path: String):
		_emit_result(id, "File %s: %s" % [id, path])
		_on_dialog_finalized(id, "")
	var on_cancel: Callable = func():
		_emit_result(id, "File %s: cancelled" % id)
		_on_dialog_finalized(id, "")
	dialog.file_selected.connect(on_selected)
	dialog.canceled.connect(on_cancel)
	dialog.close_requested.connect(on_cancel)

	_active[id] = dialog
	dialog.popup_centered(Vector2i(720, 480))
	return _format_success("Awaiting file selection: %s" % _color_id(id))

# Joins free-form arg tokens back into a single string. CommandRegistry splits
# on whitespace, so `dialog_alert Hello world` arrives as ['Hello', 'world'];
# users who want literal multi-token messages get them by typing naturally.
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

func _color_type(t: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_TYPE, t]

#endregion

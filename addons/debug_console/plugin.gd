@tool
@icon("res://addons/debug_console/icons/console_icon.svg")
extends EditorPlugin

var editor_console_panel: Control
var console_button: Button
var builtin_commands: BuiltInCommands
var console_visible: bool = false

func _enter_tree():
	editor_console_panel = preload("res://addons/debug_console/editor/EditorConsole.tscn").instantiate()
	DebugCore.initialize_for_editor(editor_console_panel)
	
	builtin_commands = preload("res://addons/debug_console/core/BuiltInCommands.gd").new()
	builtin_commands.register_editor_commands()
	
	_add_toggle_shortcut()
	
	console_button = add_control_to_bottom_panel(editor_console_panel, "Debug Console")
	
	show_console()

func _exit_tree():
	DebugCore.cleanup_editor()
	
	if editor_console_panel:
		remove_control_from_bottom_panel(editor_console_panel)
		editor_console_panel.queue_free()
	
func _add_toggle_shortcut():
	var toggle_shortcut = InputEventKey.new()
	toggle_shortcut.keycode = KEY_QUOTELEFT
	toggle_shortcut.ctrl_pressed = true
	
	if not InputMap.has_action("toggle_debug_console"):
		InputMap.add_action("toggle_debug_console")
		InputMap.action_add_event("toggle_debug_console", toggle_shortcut)

func _input(event):
	if not Engine.is_editor_hint():
		return
	
	if event.is_action_pressed("toggle_debug_console"):
		toggle_console()

func toggle_console():
	if not editor_console_panel:
		return
	
	if console_visible:
		hide_console()
	else:
		show_console()

func show_console():
	if not editor_console_panel or console_visible:
		return
	
	console_button.show()
	console_visible = true

func hide_console():
	if not editor_console_panel or not console_visible:
		return
	
	console_button.hide()
	console_visible = false

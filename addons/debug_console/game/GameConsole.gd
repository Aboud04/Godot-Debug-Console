
extends Control
class_name GameConsole

const LOG_LEVEL_INFO := 0
const LOG_LEVEL_WARNING := 1
const LOG_LEVEL_ERROR := 2
const LOG_LEVEL_SUCCESS := 3

@onready var background: ColorRect = $Background
@onready var output_text: RichTextLabel = $VBox/OutputText
@onready var input_container: HBoxContainer = $VBox/InputContainer
@onready var input_line: LineEdit = $VBox/InputContainer/InputLine
@onready var close_button: Button = $VBox/InputContainer/CloseButton

var command_history: Array[String] = []
var history_index: int = -1
var is_animating: bool = false
var target_height: float = 400.0

func _command_registry() -> Node:
	return get_node_or_null("/root/CommandRegistry")

func _ready():
	set_process_mode(Node.PROCESS_MODE_ALWAYS)
	
	_setup_ui()
	
	input_line.text_submitted.connect(_on_command_submitted)
	close_button.pressed.connect(hide_console)
	
	call_deferred("_set_initial_size")
	

func _set_initial_size():
	custom_minimum_size.y = 0
	set_deferred("size.y", 0)

func _setup_ui():
	background.color = Color(0, 0, 0, 0.85)
	
	output_text.bbcode_enabled = true
	output_text.scroll_following = true
	
	input_line.placeholder_text = "Enter command... (F12 to close)"
	
	close_button.text = "×"
	close_button.custom_minimum_size = Vector2(30, 30)

func _input(event):
	if not visible:
		return
	
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_ESCAPE, KEY_F12:
				if event.keycode == KEY_F12 or (event.keycode == KEY_QUOTELEFT and event.ctrl_pressed):
					hide_console()
					get_viewport().set_input_as_handled()
			KEY_UP:
				if input_line.has_focus():
					_navigate_history(-1)
					get_viewport().set_input_as_handled()
			KEY_DOWN:
				if input_line.has_focus():
					_navigate_history(1)
					get_viewport().set_input_as_handled()

func toggle_visibility():
	if visible and not is_animating:
		hide_console()
	elif not visible and not is_animating:
		show_console()

func show_console():
	if is_animating:
		return
	
	visible = true
	is_animating = true
	focus_command_input()
	
	var tween = create_tween()
	tween.tween_method(_update_height, 0.0, target_height, 0.3)
	tween.tween_callback(_on_show_complete)

func hide_console():
	if is_animating:
		return
	
	is_animating = true
	
	var tween = create_tween()
	tween.tween_method(_update_height, size.y, 0.0, 0.2)
	tween.tween_callback(_on_hide_complete)

func _update_height(height: float):
	custom_minimum_size.y = height
	size.y = height

func focus_command_input():
	if not input_line:
		return
	input_line.call_deferred("grab_focus")
	call_deferred("_apply_input_caret")

func _apply_input_caret():
	if input_line:
		input_line.caret_column = input_line.text.length()

func _on_show_complete():
	is_animating = false
	focus_command_input()

func _on_hide_complete():
	is_animating = false
	visible = false

func _on_command_submitted(command: String):
	_execute_command(command)

func _execute_command(command: String):
	if command.strip_edges().is_empty():
		return
	
	command_history.append(command)
	history_index = command_history.size()
	
	add_log_message("> " + command, LOG_LEVEL_INFO)
	
	var registry := _command_registry()
	if not registry:
		add_log_message("Command registry is not available.", LOG_LEVEL_ERROR)
		return

	var result = registry.execute_command(command)
	if result != null and not str(result).is_empty():
		add_log_message(str(result), LOG_LEVEL_INFO)
	
	input_line.clear()
	focus_command_input()

func add_log_message(message: String, level: int = LOG_LEVEL_INFO):
	if not output_text:
		return
	
	var color = _get_level_color(level)
	output_text.append_text("[color=%s]%s[/color]\n" % [color, message])

func clear_output():
	if output_text:
		output_text.clear()

func _get_level_color(level: int) -> String:
	match level:
		LOG_LEVEL_INFO: return "#808080"
		LOG_LEVEL_WARNING: return "#FFAA00"
		LOG_LEVEL_ERROR: return "#FF4444"
		LOG_LEVEL_SUCCESS: return "#44FF44"
		_: return "#FFFFFF"

func _navigate_history(direction: int):
	if command_history.is_empty():
		return
	
	history_index = clamp(history_index + direction, 0, command_history.size())
	
	if history_index < command_history.size():
		input_line.text = command_history[history_index]
		input_line.caret_column = input_line.text.length()
	else:
		input_line.clear()

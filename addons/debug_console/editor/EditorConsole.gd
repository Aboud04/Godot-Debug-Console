@tool
extends Control
class_name EditorConsole

@onready var output_text: RichTextLabel = $VBox/OutputPanel/OutputText
@onready var input_line: LineEdit = $VBox/InputPanel/InputLine
@onready var send_button: Button = $VBox/InputPanel/SendButton
@onready var clear_button: Button = $VBox/InputPanel/ClearButton

var command_history: Array[String] = []
var history_index: int = -1
var max_output_lines: int = 1000
var autocomplete_index: int = -1
var current_autocomplete_options: Array[String] = []

var _last_autocomplete_word: String = ""
var _matching_commands: Array[String] = []
var _autocomplete_mode: String = "commands"

func _ready():
	if not Engine.is_editor_hint():
		return
	
	input_line.placeholder_text = "Enter command..."
	input_line.gui_input.connect(_on_input_line_gui_input)
	input_line.text_changed.connect(_on_input_text_changed)
	input_line.focus_mode = Control.FOCUS_ALL
	send_button.pressed.connect(_on_send_pressed)
	clear_button.pressed.connect(_on_clear_pressed)
	
	output_text.focus_mode = Control.FOCUS_NONE
	output_text.bbcode_enabled = true
	output_text.scroll_following = true
	
	add_log_message("Editor Debug Console Ready", DebugCore.LogLevel.SUCCESS)

func _on_send_pressed():
	_execute_command(input_line.text)

func _on_clear_pressed():
	clear_output()

func _execute_command(command: String):
	if command.strip_edges().is_empty():
		return
	
	command_history.append(command)
	history_index = command_history.size()
	
	add_log_message("> " + command, DebugCore.LogLevel.INFO)
	
	var result = CommandRegistry.execute_command(command)
	if not result.is_empty():
		add_log_message(result, DebugCore.LogLevel.INFO)
	
	input_line.clear()
	
	autocomplete_index = -1
	current_autocomplete_options.clear()
	_last_autocomplete_word = ""
	_matching_commands.clear()
	
	input_line.grab_focus()

func add_log_message(message: String, level: DebugCore.LogLevel = DebugCore.LogLevel.INFO):
	if not output_text:
		return
	
	var color = _get_level_color(level)
	output_text.append_text("[color=%s]%s[/color]\n" % [color, message])
	
	if output_text.get_line_count() > max_output_lines:
		var lines = output_text.get_parsed_text().split("\n")
		var trimmed = lines.slice(-max_output_lines)
		output_text.clear()
		for line in trimmed:
			output_text.append_text(line + "\n")
	
	if input_line and not input_line.has_focus():
		input_line.grab_focus()

func clear_output():
	if output_text:
		output_text.clear()

func _get_level_color(level: DebugCore.LogLevel) -> String:
	match level:
		DebugCore.LogLevel.INFO: return "#808080"
		DebugCore.LogLevel.WARNING: return "#FFAA00"
		DebugCore.LogLevel.ERROR: return "#FF4444"
		DebugCore.LogLevel.SUCCESS: return "#44FF44"
		_: return "#FFFFFF"

func _on_input_line_gui_input(event):
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_ENTER, KEY_KP_ENTER:
				send_button.emit_signal("pressed")
				accept_event()
			KEY_TAB:
				_autocomplete()
				accept_event()
			KEY_UP:
				_navigate_history(-1)
				accept_event()
			KEY_DOWN:
				_navigate_history(1)
				accept_event()

func _navigate_history(direction: int):
	if command_history.is_empty():
		return
	
	history_index = clamp(history_index + direction, 0, command_history.size())
	
	if history_index < command_history.size():
		input_line.text = command_history[history_index]
		input_line.caret_column = input_line.text.length()
	else:
		input_line.clear()

func _on_input_text_changed(new_text: String):
	var caret_pos = input_line.caret_column
	var word_start = caret_pos
	while word_start > 0 and new_text[word_start - 1] != " ":
		word_start -= 1
	
	var current_word = new_text.substr(word_start, caret_pos - word_start)
	
	if current_word != _last_autocomplete_word:
		autocomplete_index = -1
		_last_autocomplete_word = ""
		_matching_commands.clear()

func _autocomplete():
	if input_line.text == "":
		return
	
	var current_text = input_line.text
	var caret_pos = input_line.caret_column
	
	var word_start = caret_pos
	while word_start > 0 and current_text[word_start - 1] != " ":
		word_start -= 1
	
	var current_word = current_text.substr(word_start, caret_pos - word_start)
	
	var mode = _determine_autocomplete_mode(current_text, caret_pos)
	
	if autocomplete_index == -1:
		autocomplete_index = 0
		_autocomplete_mode = mode
		
		match mode:
			"commands":
				_get_command_suggestions(current_word)
			"directories":
				_get_directory_suggestions(current_word)
			"files":
				_get_file_suggestions(current_word)
			"node_types":
				_get_node_type_suggestions(current_word)
	
	if _matching_commands.is_empty():
		return
	
	var current_selection = autocomplete_index % _matching_commands.size()
	var selected_option = _matching_commands[current_selection]
	
	var new_text = current_text.substr(0, word_start) + selected_option + current_text.substr(caret_pos)
	input_line.text = new_text
	input_line.caret_column = word_start + selected_option.length()
	
	autocomplete_index += 1

func _determine_autocomplete_mode(text: String, caret_pos: int) -> String:
	var parts = text.substr(0, caret_pos).split(" ", false)
	if parts.is_empty():
		return "commands"
	
	var command = parts[0].to_lower()
	
	if command in ["new_script", "new_scene", "new_resource"]:
		if parts.size() >= 2:
			if command in ["new_script", "new_scene"]:
				return "node_types"
			else:
				return "files"
		else:
			return "directories"
	
	if command == "cd":
		return "directories"
	
	if command == "mkdir":
		return "directories"
	
	if command in ["ls", "rm", "mv", "cp", "touch", "open", "cat", "stat", "find", "head", "tail", "run_project"]:
		return "files"
	
	return "commands"

func _get_command_suggestions(current_word: String):
	current_autocomplete_options = CommandRegistry.get_available_commands()
	var matching_commands: Array[String] = []
	for cmd in current_autocomplete_options:
		if cmd.begins_with(current_word):
			matching_commands.append(cmd)
	
	_matching_commands = matching_commands
	_last_autocomplete_word = current_word

func _get_file_suggestions(current_word: String):
	var current_dir = "res://"
	if BuiltInCommands.get_current_directory:
		current_dir = BuiltInCommands.get_current_directory()
		if current_dir != "res://":
			current_dir = "res://"
	
	if current_word.contains("/"):
		var path_parts = current_word.split("/")
		var partial_path = "/".join(path_parts.slice(0, -1))
		var search_term = path_parts[-1]
		
		var base_path = current_dir
		if partial_path != "":
			base_path = current_dir.path_join(partial_path)
		
		var dir = DirAccess.open(base_path)
		if not dir:
			_matching_commands = []
			return
		
		var files: Array[String] = []
		dir.list_dir_begin()
		var file_name = dir.get_next()
		
		while file_name != "":
			if not file_name.begins_with(".") and file_name.begins_with(search_term):
				var full_path = partial_path + "/" + file_name if partial_path != "" else file_name
				files.append(full_path)
			file_name = dir.get_next()
		
		dir.list_dir_end()
		files.sort()
		_matching_commands = files
		_last_autocomplete_word = current_word
		return

	var dir = DirAccess.open(current_dir)
	if not dir:
		_matching_commands = []
		return
	
	var files: Array[String] = []
	dir.list_dir_begin()
	var file_name = dir.get_next()
	
	while file_name != "":
		if not file_name.begins_with(".") and file_name.begins_with(current_word):
			files.append(file_name)
		file_name = dir.get_next()
	
	dir.list_dir_end()
	files.sort()
	_matching_commands = files
	_last_autocomplete_word = current_word

func _get_directory_suggestions(current_word: String):
	var current_dir = "res://"
	if BuiltInCommands.get_current_directory:
		current_dir = BuiltInCommands.get_current_directory()
		if current_dir != "res://":
			current_dir = "res://"
	
	if current_word.contains("/"):
		var path_parts = current_word.split("/")
		var partial_path = "/".join(path_parts.slice(0, -1))
		var search_term = path_parts[-1]
		
		var base_path = current_dir
		if partial_path != "":
			base_path = current_dir.path_join(partial_path)
		
		var dir = DirAccess.open(base_path)
		if not dir:
			_matching_commands = []
			return
		
		var directories: Array[String] = []
		dir.list_dir_begin()
		var file_name = dir.get_next()
		
		while file_name != "":
			if not file_name.begins_with(".") and file_name.begins_with(search_term):
				if dir.current_is_dir():
					var full_path = partial_path + "/" + file_name if partial_path != "" else file_name
					directories.append(full_path)
			file_name = dir.get_next()
		
		dir.list_dir_end()
		directories.sort()
		_matching_commands = directories
		_last_autocomplete_word = current_word
		return
	
	var dir = DirAccess.open(current_dir)
	if not dir:
		_matching_commands = []
		return
	
	var directories: Array[String] = []
	dir.list_dir_begin()
	var file_name = dir.get_next()
	
	while file_name != "":
		if not file_name.begins_with(".") and file_name.begins_with(current_word):
			if dir.current_is_dir():
				directories.append(file_name)
		file_name = dir.get_next()
	
	dir.list_dir_end()
	directories.sort()
	_matching_commands = directories
	_last_autocomplete_word = current_word

func _get_node_type_suggestions(current_word: String):
	var valid_types = ["Node", "Node2D", "Node3D", "Control", "CanvasItem", "CanvasLayer", "Viewport", "Window", "SubViewport", "Area2D", "Area3D", "CollisionShape2D", "CollisionShape3D", "Sprite2D", "Sprite3D", "Label", "Button", "LineEdit", "TextEdit", "RichTextLabel", "Panel", "VBoxContainer", "HBoxContainer", "GridContainer", "CenterContainer", "MarginContainer", "ScrollContainer", "TabContainer", "SplitContainer", "AspectRatioContainer", "TextureRect", "ColorRect", "NinePatchRect", "ProgressBar", "Slider", "SpinBox", "CheckBox", "CheckButton", "OptionButton", "ItemList", "Tree", "TreeItem", "FileDialog", "ColorPicker", "ColorPickerButton", "MenuButton", "PopupMenu", "MenuBar", "ToolButton", "LinkButton", "TextureButton", "TextureProgressBar", "AnimationPlayer", "AnimationTree", "Tween", "Timer", "Camera2D", "Camera3D", "Light2D", "Light3D", "AudioStreamPlayer", "AudioStreamPlayer2D", "AudioStreamPlayer3D", "AudioListener2D", "AudioListener3D", "RigidBody2D", "RigidBody3D", "CharacterBody2D", "CharacterBody3D", "StaticBody2D", "StaticBody3D", "KinematicBody2D", "KinematicBody3D", "Path2D", "Path3D", "NavigationAgent2D", "NavigationAgent3D", "NavigationRegion2D", "NavigationRegion3D", "NavigationPolygon", "NavigationMesh", "NavigationLink2D", "NavigationLink3D", "NavigationObstacle2D", "NavigationObstacle3D", "NavigationPathQueryParameters2D", "NavigationPathQueryParameters3D", "NavigationPathQueryResult2D", "NavigationPathQueryResult3D", "NavigationMeshSourceGeometry2D", "NavigationMeshSourceGeometry3D", "NavigationMeshSourceGeometryData2D", "NavigationMeshSourceGeometryData3D"]
	
	var matching_types: Array[String] = []
	for type_name in valid_types:
		if type_name.begins_with(current_word):
			matching_types.append(type_name)
	
	_matching_commands = matching_types
	_last_autocomplete_word = current_word

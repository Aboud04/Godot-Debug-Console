@tool
extends Node

signal message_logged(message: String, level: String)

enum LogLevel { INFO, WARNING, ERROR, SUCCESS }

var editor_output = null
var game_output = null
var _message_history: Array[String] = []
var max_history_size: int = 1000

func _ready():
	set_process_mode(Node.PROCESS_MODE_ALWAYS)

func initialize_for_editor(console_dock):
	editor_output = console_dock
	Log("Debug system initialized for editor", LogLevel.SUCCESS)

func cleanup_editor():
	editor_output = null

func initialize_for_game(console_instance):
	game_output = console_instance
	Log("Debug system initialized for game", LogLevel.SUCCESS)

func cleanup_game():
	game_output = null

func Log(message: String, level: LogLevel = LogLevel.INFO):
	var formatted_msg = _format_message(message, level)
	_add_to_history(formatted_msg)
	
	if Engine.is_editor_hint() and editor_output:
		editor_output.add_log_message(formatted_msg, level)
	elif not Engine.is_editor_hint() and game_output:
		game_output.add_log_message(formatted_msg, level)
	else:
		print(formatted_msg)
	
	message_logged.emit(formatted_msg, LogLevel.keys()[level])

func info(message: String):
	Log(message, LogLevel.INFO)

func warning(message: String):
	Log(message, LogLevel.WARNING)

func error(message: String):
	Log(message, LogLevel.ERROR)

func success(message: String):
	Log(message, LogLevel.SUCCESS)

func _format_message(message: String, level: LogLevel) -> String:
	var timestamp = Time.get_datetime_string_from_system().split("T")[1].substr(0, 8)
	var level_str = LogLevel.keys()[level]
	return "[%s] [%s] %s" % [timestamp, level_str, message]

func _add_to_history(message: String):
	_message_history.append(message)
	if _message_history.size() > max_history_size:
		_message_history = _message_history.slice(-max_history_size)

func get_history() -> Array[String]:
	return _message_history.duplicate()

func clear_history():
	_message_history.clear()

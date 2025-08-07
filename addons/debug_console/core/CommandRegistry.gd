@tool
extends Node

signal command_executed(command: String, result: String)

var _commands: Dictionary = {}

func _ready():
	set_process_mode(Node.PROCESS_MODE_ALWAYS)

func register_command(name: String, callable: Callable, description: String = "", context: String = "both", supports_input: bool = false):
	_commands[name] = {
		"callable": callable,
		"description": description,
		"context": context,  # "editor", "game", or "both"
		"supports_input": supports_input
	}
	DebugCore.Log("Command registered: %s (%s)" % [name, context])

func unregister_command(name: String):
	if _commands.has(name):
		_commands.erase(name)
		DebugCore.Log("Command unregistered: " + name)

func execute_command(input: String) -> String:
	if input.contains("|"):
		return execute_command_with_pipes(input)
	
	var parts = input.strip_edges().split(" ", false)
	if parts.is_empty():
		return ""
	
	var cmd_name = parts[0].to_lower()
	var args = parts.slice(1)
	
	if not _commands.has(cmd_name):
		var error_msg = "Unknown command: %s" % cmd_name
		command_executed.emit(input, error_msg)
		return error_msg
	
	var command_data = _commands[cmd_name]
	
	var current_context = "editor" if Engine.is_editor_hint() else "game"
	if command_data.context != "both" and command_data.context != current_context:
		var error_msg = "Command '%s' not available in %s context" % [cmd_name, current_context]
		command_executed.emit(input, error_msg)
		return error_msg
	
	if not command_data.callable.is_valid():
		var error_msg = "Command '%s' is no longer valid (object was destroyed)" % cmd_name
		command_executed.emit(input, error_msg)
		return error_msg
	
	var result = command_data.callable.callv([args])
	
	var result_str = str(result) if result != null else ""
	command_executed.emit(input, result_str)
	return result_str


func execute_command_with_pipes(input: String) -> String:
	var trimmed_input = input.strip_edges()
	var commands = trimmed_input.split("|")
	
	if commands.size() == 1:
		return execute_command(trimmed_input)
	
	var current_input = ""
	
	for i in range(commands.size()):
		var command_str = commands[i].strip_edges()
		if command_str.is_empty():
			continue
		
		var parts = command_str.split(" ", false)
		if parts.is_empty():
			continue
		
		var cmd_name = parts[0].to_lower()
		var args = parts.slice(1)
		
		if not _commands.has(cmd_name):
			var error_msg = "Unknown command: %s" % cmd_name
			command_executed.emit(input, error_msg)
			return error_msg
		
		var command_data = _commands[cmd_name]
		
		var current_context = "editor" if Engine.is_editor_hint() else "game"
		if command_data.context != "both" and command_data.context != current_context:
			var error_msg = "Command '%s' not available in %s context" % [cmd_name, current_context]
			command_executed.emit(input, error_msg)
			return error_msg
		
		if not command_data.callable.is_valid():
			var error_msg = "Command '%s' is no longer valid (object was destroyed)" % cmd_name
			command_executed.emit(input, error_msg)
			return error_msg

		var result
		if command_data.supports_input:
			var is_pipe_context = commands.size() > 1
			result = command_data.callable.callv([args, current_input, is_pipe_context])
		else:
			var modified_args = args.duplicate()
			if not current_input.is_empty():
				modified_args.insert(0, current_input)
			result = command_data.callable.callv([modified_args])
		
		var result_str = str(result) if result != null else ""
		current_input = result_str
	
	command_executed.emit(input, current_input)
	return current_input

func get_available_commands(context: String = "") -> Array[String]:
	var available: Array[String] = []
	var current_context = context if context else ("editor" if Engine.is_editor_hint() else "game")
	
	for cmd_name in _commands.keys():
		var cmd_context = _commands[cmd_name].context
		if cmd_context == "both" or cmd_context == current_context:
			available.append(str(cmd_name))
	
	available.sort()
	return available

func get_command_help(cmd_name: String = "") -> String:
	if cmd_name:
		if _commands.has(cmd_name):
			return "%s - %s" % [cmd_name, _commands[cmd_name].description]
		else:
			return "Unknown command: " + cmd_name
	
	var help_lines = ["Available commands:"]
	var current_context = "editor" if Engine.is_editor_hint() else "game"
	
	for cmd in get_available_commands():
		var desc = _commands[cmd].description
		help_lines.append("  %s - %s" % [cmd, desc])
	
	return "\n".join(help_lines)

func get_command_history() -> Array[String]:
	return []

func clear_command_history():
	pass

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

func unregister_command(name: String):
	if _commands.has(name):
		_commands.erase(name)

func execute_command(input: String) -> String:
	if input.contains("|"):
		return execute_command_with_pipes(input)

	var execution = _execute_single_command(input, input)
	if not bool(execution["ok"]):
		var error_result = str(execution["result"])
		command_executed.emit(input, error_result)
		return error_result

	var result_str = str(execution["result"])
	command_executed.emit(input, result_str)
	return result_str


func execute_command_with_pipes(input: String) -> String:
	var trimmed_input = input.strip_edges()
	if trimmed_input.is_empty():
		command_executed.emit(input, "")
		return ""

	var commands = trimmed_input.split("|", true)
	
	if commands.size() == 1:
		return execute_command(trimmed_input)
	
	var current_input := ""
	var executed_any := false
	
	for i in range(commands.size()):
		var command_str = commands[i].strip_edges()
		if command_str.is_empty():
			continue

		var execution = _execute_single_command(command_str, input, current_input, true)
		if not bool(execution["ok"]):
			var error_result = str(execution["result"])
			command_executed.emit(input, error_result)
			return error_result

		current_input = str(execution["result"])
		executed_any = true

	if not executed_any:
		command_executed.emit(input, "")
		return ""
	
	command_executed.emit(input, current_input)
	return current_input

func _execute_single_command(command_str: String, original_input: String, piped_input: String = "", is_pipe_context: bool = false) -> Dictionary:
	var trimmed_command := command_str.strip_edges()
	if trimmed_command.is_empty():
		return {"ok": true, "result": piped_input}

	var parts := trimmed_command.split(" ", false)
	if parts.is_empty():
		return {"ok": true, "result": piped_input}

	var cmd_name := parts[0].to_lower()
	var args := parts.slice(1)

	if not _commands.has(cmd_name):
		return {"ok": false, "result": "Unknown command: %s" % cmd_name}

	var command_data: Dictionary = _commands[cmd_name]
	var current_context := "editor" if Engine.is_editor_hint() else "game"
	var command_context := str(command_data.get("context", "both"))
	if command_context != "both" and command_context != current_context:
		return {
			"ok": false,
			"result": "Command '%s' not available in %s context" % [cmd_name, current_context]
		}

	var callable: Callable = command_data.get("callable", Callable())
	if not callable.is_valid():
		return {
			"ok": false,
			"result": "Command '%s' is no longer valid (object was destroyed)" % cmd_name
		}

	var supports_input := bool(command_data.get("supports_input", false))
	var result
	if supports_input:
		result = callable.callv([args, piped_input, is_pipe_context])
	else:
		var modified_args = args.duplicate()
		if not piped_input.is_empty():
			modified_args.insert(0, piped_input)
		result = callable.callv([modified_args])

	var result_str := str(result) if result != null else ""
	return {"ok": true, "result": result_str}

func get_available_commands(context: String = "") -> Array[String]:
	var available: Array[String] = []
	var current_context = context if context else ("editor" if Engine.is_editor_hint() else "game")
	
	for cmd_name in _commands.keys():
		var command_data: Dictionary = _commands[cmd_name]
		var cmd_context = str(command_data.get("context", "both"))
		if cmd_context == "both" or cmd_context == current_context:
			available.append(str(cmd_name))
	
	available.sort()
	return available

func get_command_help(cmd_name: String = "") -> String:
	if cmd_name:
		if _commands.has(cmd_name):
			var command_data: Dictionary = _commands[cmd_name]
			return "%s - %s" % [cmd_name, str(command_data.get("description", ""))]
		else:
			return "Unknown command: " + cmd_name
	
	var help_lines = ["Available commands:"]
	var current_context = "editor" if Engine.is_editor_hint() else "game"
	
	for cmd in get_available_commands():
		var command_data: Dictionary = _commands[cmd]
		var desc = str(command_data.get("description", ""))
		help_lines.append("  %s - %s" % [cmd, desc])
	
	return "\n".join(help_lines)

func get_command_history() -> Array[String]:
	return []

func clear_command_history():
	pass

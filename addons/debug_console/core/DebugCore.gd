@tool
extends Node

signal message_logged(message: String, level: String)

enum LogLevel { INFO, WARNING, ERROR, SUCCESS }

var editor_output = null
var game_output = null
var _message_history: Array[String] = []
var max_history_size: int = 1000
var _watch_entries: Array[Dictionary] = []
var _watch_poll_interval: float = 0.5
var _watch_poll_elapsed: float = 0.0

func _ready():
	set_process_mode(Node.PROCESS_MODE_ALWAYS)

func _process(delta: float):
	if _watch_entries.is_empty():
		_watch_poll_elapsed = 0.0
		return

	_watch_poll_elapsed += delta
	if _watch_poll_elapsed < _watch_poll_interval:
		return

	_watch_poll_elapsed = 0.0
	poll_watch_expressions()

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

func get_history_text() -> String:
	return "\n".join(_message_history)

func clear_history():
	_message_history.clear()

func save_history_to_file(file_path: String) -> Dictionary:
	var normalized_path := file_path.strip_edges()
	if normalized_path.is_empty():
		return {"ok": false, "result": "Error: File path is empty"}

	var base_dir := normalized_path.get_base_dir()
	if not base_dir.is_empty() and base_dir != "res://" and base_dir != "user://":
		var ensure_result := DirAccess.make_dir_recursive_absolute(base_dir)
		if ensure_result != OK:
			return {
				"ok": false,
				"result": "Error: Failed to create directory: %s" % base_dir
			}

	var file := FileAccess.open(normalized_path, FileAccess.WRITE)
	if not file:
		return {"ok": false, "result": "Error: Failed to open log file: %s" % normalized_path}

	file.store_string(get_history_text())
	file.close()

	return {
		"ok": true,
		"path": normalized_path,
		"count": _message_history.size(),
	}

func add_watch(expression: String) -> Dictionary:
	var normalized_expression := expression.strip_edges()
	if normalized_expression.is_empty():
		return {"ok": false, "result": "Usage: watch <Engine.property|node_path:property>"}

	if _find_watch_index(normalized_expression) != -1:
		return {"ok": false, "result": "Watch already exists: %s" % normalized_expression}

	var evaluation := _evaluate_watch_expression(normalized_expression)
	if not bool(evaluation.get("ok", false)):
		return evaluation

	_watch_entries.append({
		"expression": normalized_expression,
		"last_value": str(evaluation.get("value", "")),
	})
	_watch_poll_elapsed = 0.0
	return {
		"ok": true,
		"expression": normalized_expression,
		"value": str(evaluation.get("value", "")),
	}

func remove_watch(expression: String) -> bool:
	var watch_index := _find_watch_index(expression.strip_edges())
	if watch_index == -1:
		return false

	_watch_entries.remove_at(watch_index)
	return true

func clear_watches() -> int:
	var cleared_count := _watch_entries.size()
	_watch_entries.clear()
	_watch_poll_elapsed = 0.0
	return cleared_count

func list_watches() -> Array[Dictionary]:
	return _watch_entries.duplicate(true)

func poll_watch_expressions(log_changes: bool = true) -> Array[String]:
	var updates: Array[String] = []
	for entry in _watch_entries:
		var expression := str(entry.get("expression", ""))
		var evaluation := _evaluate_watch_expression(expression)
		var current_value := ""
		if bool(evaluation.get("ok", false)):
			current_value = str(evaluation.get("value", ""))
		else:
			current_value = str(evaluation.get("result", "Error: Watch evaluation failed"))

		if current_value == str(entry.get("last_value", "")):
			continue

		entry["last_value"] = current_value
		var update_message := "WATCH %s = %s" % [expression, current_value]
		updates.append(update_message)
		if log_changes:
			Log(update_message, LogLevel.INFO)

	return updates

func _find_watch_index(expression: String) -> int:
	for index in range(_watch_entries.size()):
		if str(_watch_entries[index].get("expression", "")) == expression:
			return index
	return -1

func _evaluate_watch_expression(expression: String) -> Dictionary:
	if expression.begins_with("Engine."):
		var engine_property := expression.trim_prefix("Engine.")
		return _evaluate_engine_watch(engine_property, expression)

	if not expression.contains(":"):
		return {
			"ok": false,
			"result": "Error: Watch expression must use Engine.<property> or <node_path>:<property>"
		}

	var separator_index := expression.find(":")
	var node_selector := expression.substr(0, separator_index).strip_edges()
	var property_path := expression.substr(separator_index + 1).strip_edges()
	if node_selector.is_empty() or property_path.is_empty():
		return {
			"ok": false,
			"result": "Error: Watch expression must use <node_path>:<property>"
		}

	var tree := get_tree()
	if not tree:
		return {"ok": false, "result": "Error: Scene tree unavailable"}

	var node := tree.root.get_node_or_null(NodePath(node_selector))
	if not node and not node_selector.begins_with("/"):
		node = tree.root.find_child(node_selector, true, false)
	if not node:
		return {"ok": false, "result": "Error: Watch node not found: %s" % node_selector}

	return _evaluate_property_path(node, property_path, expression)

func _evaluate_engine_watch(property_path: String, original_expression: String) -> Dictionary:
	var value = _resolve_property_path(Engine, property_path)
	if value == null and not _property_exists(Engine, property_path):
		return {"ok": false, "result": "Error: Engine property not found: %s" % original_expression}
	return {"ok": true, "value": _format_watch_value(value)}

func _evaluate_property_path(target, property_path: String, original_expression: String) -> Dictionary:
	var value = _resolve_property_path(target, property_path)
	if value == null and not _property_exists(target, property_path):
		return {"ok": false, "result": "Error: Watch property not found: %s" % original_expression}
	return {"ok": true, "value": _format_watch_value(value)}

func _resolve_property_path(target, property_path: String):
	var current = target
	for segment in property_path.split(".", false):
		if current == null:
			return null
		if current is Dictionary:
			if not current.has(segment):
				return null
			current = current[segment]
		elif current is Object:
			current = current.get(segment)
		else:
			return null
	return current

func _property_exists(target, property_path: String) -> bool:
	var current = target
	for segment in property_path.split(".", false):
		if current == null:
			return false
		if current is Dictionary:
			if not current.has(segment):
				return false
			current = current[segment]
		elif current is Object:
			var found := false
			for property in current.get_property_list():
				if str(property.get("name", "")) == segment:
					found = true
					break
			if not found:
				return false
			current = current.get(segment)
		else:
			return false
	return true

func _format_watch_value(value) -> String:
	if value is Node:
		return "[%s] %s" % [value.get_class(), value.name]
	if value is String:
		return value
	return var_to_str(value)

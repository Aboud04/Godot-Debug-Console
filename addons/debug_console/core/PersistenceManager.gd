@tool
class_name DebugConsolePersistenceManager extends RefCounted

# T3.3 - persistence layer for the Debug Console addon. Owned by plugin.gd and
# injected into EditorConsole (history) and BuiltInCommands (working directory)
# so neither of those classes needs to know about disk I/O. Everything lives in
# user:// JSON files that are robust to corruption (load returns sane defaults
# and a push_warning) and survive editor restarts.
#
# Two storage files are managed independently so that history truncation never
# touches the project-cwd map and vice-versa:
#   user://debug_console_history.json   - JSON array of command strings
#   user://debug_console_state.json     - JSON dict { cwd_by_project: {...}, version: N }

const HISTORY_PATH := "user://debug_console_history.json"
const STATE_PATH := "user://debug_console_state.json"
const HISTORY_CAP := 500
const STATE_VERSION := 1

# Tests override these so they don't trample the real user files. Production
# code never touches them - plugin.gd just calls new() and uses the defaults.
var history_path: String = HISTORY_PATH
var state_path: String = STATE_PATH

func load_history() -> Array[String]:
	var out: Array[String] = []
	if not FileAccess.file_exists(history_path):
		return out
	var f := FileAccess.open(history_path, FileAccess.READ)
	if not f:
		push_warning("Debug Console: history file exists but could not be opened: %s" % history_path)
		return out
	var text: String = f.get_as_text()
	f.close()
	var trimmed: String = text.strip_edges()
	if trimmed.is_empty():
		return out
	# Pre-screen the structural shape before invoking JSON.parse_string. The
	# parse method pushes a "Parse JSON failed" error to the editor Output
	# panel when called on malformed input, which is noisy during the
	# "corrupted history file" recovery path (we want a single push_warning,
	# not two log lines). Histories are always JSON arrays, so anything that
	# does not start with [ is corrupted by definition.
	if not trimmed.begins_with("["):
		push_warning("Debug Console: history file is corrupted, starting fresh: %s" % history_path)
		return out
	var parsed: Variant = JSON.parse_string(trimmed)
	if typeof(parsed) != TYPE_ARRAY:
		push_warning("Debug Console: history file is corrupted, starting fresh: %s" % history_path)
		return out
	var arr: Array = parsed as Array
	if arr.size() > HISTORY_CAP:
		arr = arr.slice(-HISTORY_CAP)
	for entry in arr:
		out.append(str(entry))
	return out

func save_history(history: Array[String]) -> void:
	var capped: Array[String] = history
	if capped.size() > HISTORY_CAP:
		capped = capped.slice(-HISTORY_CAP)
	var f := FileAccess.open(history_path, FileAccess.WRITE)
	if not f:
		push_warning("Debug Console: could not open history file for writing: %s" % history_path)
		return
	f.store_string(JSON.stringify(capped))
	f.close()

func load_cwd_for_project(project_path: String) -> String:
	var state: Dictionary = _load_state()
	var cwd_map: Dictionary = state.get("cwd_by_project", {})
	return str(cwd_map.get(project_path, ""))

func save_cwd(cwd: String) -> void:
	# Keyed by ProjectSettings.globalize_path("res://") so one OS user with
	# multiple Godot projects keeps a distinct cwd per project. Other projects'
	# entries are preserved across the read-modify-write.
	var project_path: String = ProjectSettings.globalize_path("res://")
	var state: Dictionary = _load_state()
	var cwd_map: Dictionary = state.get("cwd_by_project", {})
	cwd_map[project_path] = cwd
	state["cwd_by_project"] = cwd_map
	state["version"] = STATE_VERSION
	_save_state(state)

func _load_state() -> Dictionary:
	var default_state: Dictionary = {"cwd_by_project": {}, "version": STATE_VERSION}
	if not FileAccess.file_exists(state_path):
		return default_state
	var f := FileAccess.open(state_path, FileAccess.READ)
	if not f:
		return default_state
	var text: String = f.get_as_text()
	f.close()
	var trimmed: String = text.strip_edges()
	if trimmed.is_empty():
		return default_state
	# Pre-screen for the same reason load_history does: avoid Godot's
	# "Parse JSON failed" error when the file is structurally broken.
	# State is always a JSON dictionary, so anything not starting with { is
	# corrupted by definition.
	if not trimmed.begins_with("{"):
		push_warning("Debug Console: state file is corrupted, starting fresh: %s" % state_path)
		return default_state
	var parsed: Variant = JSON.parse_string(trimmed)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("Debug Console: state file is corrupted, starting fresh: %s" % state_path)
		return default_state
	return parsed as Dictionary

func _save_state(state: Dictionary) -> void:
	var f := FileAccess.open(state_path, FileAccess.WRITE)
	if not f:
		push_warning("Debug Console: could not open state file for writing: %s" % state_path)
		return
	f.store_string(JSON.stringify(state))
	f.close()

func _clear_all() -> void:
	# Convenience for tests. Removes both files if they exist; missing files
	# are not an error since the goal is "ensure clean slate".
	if FileAccess.file_exists(history_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(history_path))
	if FileAccess.file_exists(state_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(state_path))

@tool
class_name DebugConsoleAutoScreenshotCommands extends RefCounted

# Tier 6 (game context) - auto-capture viewport PNGs whenever push_error or
# push_warning fires. Mirrors the structure of core/SceneCommands.gd: the
# orchestrator (BuiltInCommands.register_universal_commands) instantiates one
# of these, holds a strong reference, and calls register_commands(registry,
# core). All toggle / counter state lives on this instance so the Callables
# stay valid for the plugin lifetime.
#
# Implementation: a nested Logger subclass is installed via OS.add_logger() the
# first time either toggle is flipped on. Godot routes both push_error and
# push_warning through Logger._log_error() with different error_type values
# (ERROR_TYPE_WARNING == 1 for warnings, everything else counts as error).
# The logger forwards events back here via call_deferred so the actual
# get_viewport().get_texture().get_image().save_png() chain always runs on
# the main thread, and a _capturing guard prevents a failed save from
# infinite-looping when its own push_error fires.
#
# Commands are registered with the "game" context because grabbing a viewport
# texture requires a live runtime SceneTree.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"

const _DEFAULT_DIR := "user://screenshots/"
const _FILE_PREFIX := "auto_shot_"

var _registry: Node
var _core: Node
var _on_error: bool = false
var _on_warning: bool = false
var _output_dir: String = _DEFAULT_DIR
var _count: int = 0
var _logger: RefCounted = null
var _capturing: bool = false

# Nested Logger subclass. Godot 4.3+ exposes Logger to scripting; if the
# running engine does not, the whole file fails to parse and the orchestrator
# simply skips this extension - same failure mode as any other version-gated
# extension in this folder.
class _AutoLogger extends Logger:
	var _owner_ref: WeakRef = null

	func bind(o: RefCounted) -> void:
		_owner_ref = weakref(o)

	func _log_error(function: String, file: String, line: int, code: String, rationale: String, editor_notify: bool, error_type: int, script_backtraces: Array[ScriptBacktrace] = []) -> void:
		if _owner_ref == null:
			return
		var owner: Object = _owner_ref.get_ref()
		if owner == null:
			return
		owner.call_deferred("_on_log_error", error_type)

	func _log_message(message: String, error: bool) -> void:
		pass


func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("auto_shot_on_error", _cmd_on_error, "Toggle viewport capture on push_error: auto_shot_on_error <on|off>", "game")
	_registry.register_command("auto_shot_on_warning", _cmd_on_warning, "Toggle viewport capture on push_warning: auto_shot_on_warning <on|off>", "game")
	_registry.register_command("auto_shot_dir", _cmd_dir, "Set output dir for auto-captured screenshots (default user://screenshots/): auto_shot_dir <user://path>", "game")
	_registry.register_command("auto_shot_count", _cmd_count, "Print total auto-captured screenshots this session: auto_shot_count", "game")
	_registry.register_command("auto_shot_manual", _cmd_manual, "Trigger one immediate manual capture: auto_shot_manual", "game")
	_registry.register_command("auto_shot_clear", _cmd_clear, "Delete all auto-shot PNGs in the configured output dir: auto_shot_clear", "game")

#region Command implementations

func _cmd_on_error(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: auto_shot_on_error <on|off>")
	var flag := _parse_on_off(str(args[0]))
	if flag == -1:
		return _format_error("Expected 'on' or 'off' (got %s)" % str(args[0]))
	_on_error = (flag == 1)
	if _on_error:
		_ensure_logger()
	return _format_success("auto_shot_on_error = %s" % _color_number(str(_on_error)))

func _cmd_on_warning(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: auto_shot_on_warning <on|off>")
	var flag := _parse_on_off(str(args[0]))
	if flag == -1:
		return _format_error("Expected 'on' or 'off' (got %s)" % str(args[0]))
	_on_warning = (flag == 1)
	if _on_warning:
		_ensure_logger()
	return _format_success("auto_shot_on_warning = %s" % _color_number(str(_on_warning)))

func _cmd_dir(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: auto_shot_dir <user://path>")
	var raw := str(args[0]).strip_edges()
	if raw.is_empty():
		return _format_error("Empty path.")
	if not raw.ends_with("/"):
		raw += "/"
	var err := _ensure_dir(raw)
	if err != OK:
		return _format_error("Failed to create dir %s (err %d)" % [raw, err])
	_output_dir = raw
	return _format_success("auto_shot_dir = %s" % _color_path(_output_dir))

func _cmd_count(args: Array, piped_input: String = "") -> String:
	return _format_success("auto_shot_count = %s (dir=%s, on_error=%s, on_warning=%s)" % [
		_color_number(str(_count)),
		_color_path(_output_dir),
		_color_number(str(_on_error)),
		_color_number(str(_on_warning)),
	])

func _cmd_manual(args: Array, piped_input: String = "") -> String:
	var path := _capture_now("manual")
	if path.is_empty():
		return _format_error("Manual capture failed (no viewport/texture or save_png error).")
	return _format_success("Saved %s (total=%s)" % [
		_color_path(path),
		_color_number(str(_count)),
	])

func _cmd_clear(args: Array, piped_input: String = "") -> String:
	var err := _ensure_dir(_output_dir)
	if err != OK:
		return _format_error("Output dir not accessible: %s (err %d)" % [_output_dir, err])
	var dir := DirAccess.open(_output_dir)
	if dir == null:
		return _format_error("Cannot open dir: %s" % _output_dir)
	var removed: int = 0
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while entry != "":
		if not dir.current_is_dir() and entry.begins_with(_FILE_PREFIX) and entry.ends_with(".png"):
			var rerr := dir.remove(entry)
			if rerr == OK:
				removed += 1
		entry = dir.get_next()
	dir.list_dir_end()
	return _format_success("Deleted %s file(s) in %s" % [
		_color_number(str(removed)),
		_color_path(_output_dir),
	])

#endregion

#region Helpers

func _on_log_error(error_type: int) -> void:
	# Bounced here via call_deferred from _AutoLogger._log_error. We're on the
	# main thread now, so viewport access is safe.
	if _capturing:
		return
	# Logger.ERROR_TYPE_WARNING == 1 in Godot 4. Anything else (ERROR,
	# SCRIPT, SHADER) is treated as an error for our purposes.
	var is_warning := (error_type == 1)
	if is_warning and not _on_warning:
		return
	if not is_warning and not _on_error:
		return
	_capture_now("warning" if is_warning else "error")

func _capture_now(reason: String) -> String:
	if _capturing:
		return ""
	_capturing = true
	var saved_path := ""
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		_capturing = false
		return ""
	var viewport: Viewport = tree.root
	var texture := viewport.get_texture()
	if texture == null:
		_capturing = false
		return ""
	var image := texture.get_image()
	if image == null:
		_capturing = false
		return ""
	var err := _ensure_dir(_output_dir)
	if err != OK:
		_capturing = false
		return ""
	_count += 1
	var stamp := Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	var fname := "%s%s_%04d_%s.png" % [_FILE_PREFIX, reason, _count, stamp]
	saved_path = _output_dir + fname
	var save_err := image.save_png(saved_path)
	if save_err != OK:
		_count -= 1
		saved_path = ""
	_capturing = false
	return saved_path

func _ensure_logger() -> void:
	if _logger != null:
		return
	if not ClassDB.class_exists("Logger"):
		return
	var auto_logger := _AutoLogger.new()
	auto_logger.bind(self)
	_logger = auto_logger
	OS.add_logger(_logger)

func _ensure_dir(path: String) -> int:
	if path.is_empty():
		return ERR_INVALID_PARAMETER
	if DirAccess.dir_exists_absolute(path):
		return OK
	return DirAccess.make_dir_recursive_absolute(path)

func _parse_on_off(s: String) -> int:
	var v := s.strip_edges().to_lower()
	if v == "on" or v == "true" or v == "1" or v == "yes":
		return 1
	if v == "off" or v == "false" or v == "0" or v == "no":
		return 0
	return -1

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

#endregion

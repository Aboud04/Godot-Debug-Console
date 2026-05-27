extends Logger
## T2.3 - GameConsole print interceptor.
##
## Conditionally loaded via load() from GameConsole.set_intercept_enabled()
## so this file is never PARSED on Godot < 4.5 (where the Logger class is
## not exposed to GDScript). The conditional load + has_method guards in
## the caller keep this file dormant on older engine versions.
##
## We don't try to unregister - Godot 4.6 has OS.add_logger but no
## remove_logger from script. Instead, the logger checks the console's
## _intercept_enabled flag every callback. "intercept off" flips the
## flag; the logger keeps receiving events but discards them.

var _console_ref: WeakRef

func _init(console: Node) -> void:
	_console_ref = weakref(console)

func _log_message(message: String, error: bool) -> void:
	var gc: Node = _console_ref.get_ref() if _console_ref else null
	if not is_instance_valid(gc):
		return
	if not gc.has_method("is_intercept_enabled") or not gc.call("is_intercept_enabled"):
		return
	# LOG_LEVEL_ERROR = 2, LOG_LEVEL_INFO = 0 (mirrors GameConsole constants).
	var level: int = 2 if error else 0
	if gc.has_method("_on_intercepted_log"):
		gc.call("_on_intercepted_log", message, level)

func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _script_backtraces: Array) -> void:
	var gc: Node = _console_ref.get_ref() if _console_ref else null
	if not is_instance_valid(gc):
		return
	if not gc.has_method("is_intercept_enabled") or not gc.call("is_intercept_enabled"):
		return
	# Godot's ErrorType enum: 0=ERROR, 1=WARNING, 2=SCRIPT, 3=SHADER. We
	# treat WARNING as LOG_LEVEL_WARNING (1) and everything else as ERROR (2).
	var level: int = 1 if error_type == 1 else 2
	var msg: String = rationale if rationale != "" else code
	if file != "" and line > 0:
		msg = "%s (%s:%d in %s)" % [msg, file, line, function]
	elif file != "":
		msg = "%s (%s)" % [msg, file]
	if gc.has_method("_on_intercepted_log"):
		gc.call("_on_intercepted_log", msg, level)

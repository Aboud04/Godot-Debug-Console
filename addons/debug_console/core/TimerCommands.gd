@tool
class_name DebugConsoleTimerCommands extends RefCounted

# Deferred and recurring command scheduling. Like the other tier modules
# modules this is a RefCounted instance owned by BuiltInCommands; the
# orchestrator keeps a strong reference so the Callables we register stay
# valid across the plugin lifetime.
#
# Scheduled commands are backed by Timer nodes parented to the registry so
# the SceneTree drives them; we store strong references in _scheduled keyed
# by a monotonically increasing ID so cancel/scheduled can find them.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_MUTED := "#888888"
const _COLOR_COUNTDOWN := "#FFB347"

const _MAX_REPEAT := 10000
const _MAX_DELAY_SECS := 30.0

var _registry: Node
var _core: Node
var _scheduled: Dictionary = {}
var _id_counter: int = 0
var _stopwatch_start_ms: int = 0
var _stopwatch_running: bool = false
var _cleanup_connected: bool = false


func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	# schedule/repeat/every/cancel/scheduled/countdown lean on the SceneTree
	# (Timer nodes parented to the registry), so they are game-only. delay
	# uses OS.delay_msec which works everywhere; stopwatch is pure data on
	# this instance and is also context-agnostic.
	_registry.register_command("schedule", _cmd_schedule, "Run a command after a delay: schedule <secs> <command>", "game")
	_registry.register_command("repeat", _cmd_repeat, "Repeat a command N times every interval: repeat <secs> <count|inf> <command>", "game")
	_registry.register_command("every", _cmd_every, "Run a command forever every interval: every <secs> <command>", "game")
	_registry.register_command("cancel", _cmd_cancel, "Cancel a scheduled command: cancel <schedule_id|all>", "game")
	_registry.register_command("scheduled", _cmd_scheduled, "List active scheduled commands", "game")
	_registry.register_command("delay", _cmd_delay, "Block for N seconds (max 30): delay <secs>", "both", true)
	_registry.register_command("stopwatch", _cmd_stopwatch, "Wall-clock stopwatch: stopwatch <start|stop|reset>", "both")
	_registry.register_command("countdown", _cmd_countdown, "Print a countdown line every second: countdown <secs> [label]", "game")

	if not _cleanup_connected and _registry.has_signal("tree_exiting"):
		# When the registry leaves the tree (plugin disable, scene change) we
		# need to tear down outstanding timers so their lambdas don't fire
		# against a dead registry. The handler is bound to this instance
		# which BuiltInCommands keeps alive.
		_registry.tree_exiting.connect(_on_registry_exiting)
		_cleanup_connected = true

#region Command implementations

func _cmd_schedule(args: Array, _piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: schedule <secs> <command>")
	var delay := _parse_non_negative_float(str(args[0]))
	if delay < 0.0:
		return _format_error("Invalid delay: %s" % str(args[0]))
	var cmd := _join_args(args, 1)
	if cmd.is_empty():
		return _format_error("Empty command")
	if not _get_tree():
		return _format_error("No SceneTree available")

	var timer := Timer.new()
	timer.one_shot = true
	# Timer requires > 0; clamp tiny delays so the node still ticks.
	timer.wait_time = max(delay, 0.001)
	timer.autostart = false
	_registry.add_child(timer)

	var sid := _next_id()
	var entry := {
		"id": sid,
		"timer": timer,
		"command": cmd,
		"kind": "once",
		"remaining": 1,
		"interval": delay,
	}
	_scheduled[sid] = entry
	timer.timeout.connect(func() -> void: _on_once_fired(sid))
	timer.start()
	return _format_success("Scheduled %s in %ss: %s" % [
		_color_path(sid),
		_color_num(delay),
		cmd,
	])

func _cmd_repeat(args: Array, _piped_input: String = "") -> String:
	if args.size() < 3:
		return _format_error("Usage: repeat <secs> <count|inf> <command>")
	var interval := _parse_non_negative_float(str(args[0]))
	if interval <= 0.0:
		return _format_error("Invalid interval: %s" % str(args[0]))
	var count_raw := str(args[1]).strip_edges().to_lower()
	var count: int
	if count_raw == "inf" or count_raw == "infinite" or count_raw == "-1":
		count = _MAX_REPEAT
	else:
		if not count_raw.is_valid_int():
			return _format_error("Invalid count: %s" % count_raw)
		count = count_raw.to_int()
		if count <= 0:
			return _format_error("Count must be positive")
		count = min(count, _MAX_REPEAT)
	var cmd := _join_args(args, 2)
	if cmd.is_empty():
		return _format_error("Empty command")
	if not _get_tree():
		return _format_error("No SceneTree available")

	var timer := Timer.new()
	timer.one_shot = false
	timer.wait_time = interval
	timer.autostart = false
	_registry.add_child(timer)

	var sid := _next_id()
	var entry := {
		"id": sid,
		"timer": timer,
		"command": cmd,
		"kind": "repeat",
		"remaining": count,
		"interval": interval,
	}
	_scheduled[sid] = entry
	timer.timeout.connect(func() -> void: _on_repeat_fired(sid))
	timer.start()
	return _format_success("Repeating %s every %ss x%s: %s" % [
		_color_path(sid),
		_color_num(interval),
		_color_number(str(count)),
		cmd,
	])

func _cmd_every(args: Array, _piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: every <secs> <command>")
	# Forward as repeat <secs> inf <command...>.
	var forwarded: Array = [args[0], "inf"]
	for i in range(1, args.size()):
		forwarded.append(args[i])
	return _cmd_repeat(forwarded)

func _cmd_cancel(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: cancel <schedule_id|all>")
	var target := str(args[0]).strip_edges()
	if target == "all":
		var n := _scheduled.size()
		_cancel_all_internal()
		return _format_success("Cancelled %s schedule(s)" % _color_number(str(n)))
	if not _scheduled.has(target):
		return _format_error("Schedule not found: %s" % target)
	_dispose_entry(target)
	return _format_success("Cancelled %s" % _color_path(target))

func _cmd_scheduled(_args: Array, _piped_input: String = "") -> String:
	if _scheduled.is_empty():
		return "[color=%s](no scheduled commands)[/color]" % _COLOR_MUTED
	var lines: Array[String] = ["Scheduled commands (%d):" % _scheduled.size()]
	var ids: Array = _scheduled.keys()
	ids.sort()
	for sid in ids:
		var entry: Dictionary = _scheduled[sid]
		var timer: Timer = entry.get("timer", null) as Timer
		var time_left := 0.0
		if is_instance_valid(timer):
			time_left = timer.time_left
		var kind: String = str(entry.get("kind", "?"))
		var remaining: int = int(entry.get("remaining", 0))
		var cmd: String = str(entry.get("command", ""))
		var repeats_str := "" if kind == "once" else (" x%s" % _color_number(str(remaining)))
		lines.append("  %s [%s] in %ss%s: %s" % [
			_color_path(sid),
			kind,
			_color_num(time_left),
			repeats_str,
			cmd,
		])
	return "\n".join(lines)

func _cmd_delay(args, piped_input: String = "", _is_pipe: bool = false) -> String:
	# supports_input=true so we can pass piped data through untouched.
	var actual_args: Array = args if args is Array else []
	if actual_args.is_empty():
		return _format_error("Usage: delay <secs>")
	var secs := _parse_non_negative_float(str(actual_args[0]))
	if secs < 0.0:
		return _format_error("Invalid delay: %s" % str(actual_args[0]))
	if secs > _MAX_DELAY_SECS:
		return _format_error("Delay capped at %ss (got %s)" % [str(_MAX_DELAY_SECS), str(secs)])
	OS.delay_msec(int(secs * 1000.0))
	if not piped_input.is_empty():
		return piped_input
	return _format_success("Waited %ss" % _color_num(secs))

func _cmd_stopwatch(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: stopwatch <start|stop|reset>")
	var action := str(args[0]).strip_edges().to_lower()
	match action:
		"start":
			_stopwatch_start_ms = Time.get_ticks_msec()
			_stopwatch_running = true
			return _format_success("Stopwatch started")
		"stop":
			if _stopwatch_start_ms == 0:
				return _format_error("Stopwatch not started")
			var elapsed_ms := Time.get_ticks_msec() - _stopwatch_start_ms
			_stopwatch_running = false
			return _format_success("Elapsed: %ss" % _color_num(float(elapsed_ms) / 1000.0))
		"reset":
			_stopwatch_running = false
			_stopwatch_start_ms = 0
			return _format_success("Stopwatch reset")
		_:
			return _format_error("Unknown action: %s (use start|stop|reset)" % action)

func _cmd_countdown(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: countdown <secs> [label]")
	var secs_raw := str(args[0]).strip_edges()
	if not secs_raw.is_valid_int():
		return _format_error("Invalid seconds: %s" % secs_raw)
	var total := secs_raw.to_int()
	if total <= 0:
		return _format_error("Seconds must be positive")
	total = min(total, _MAX_REPEAT)
	var label := "Countdown"
	if args.size() > 1:
		label = _join_args(args, 1)
	if not _get_tree():
		return _format_error("No SceneTree available")

	# Print the opening line immediately; the timer covers the remaining
	# ticks down to 0.
	_emit_countdown_line(label, total)

	var timer := Timer.new()
	timer.one_shot = false
	timer.wait_time = 1.0
	timer.autostart = false
	_registry.add_child(timer)

	var sid := _next_id()
	var entry := {
		"id": sid,
		"timer": timer,
		"command": "countdown %s" % label,
		"kind": "countdown",
		"remaining": total,
		"interval": 1.0,
		"label": label,
	}
	_scheduled[sid] = entry
	timer.timeout.connect(func() -> void: _on_countdown_tick(sid))
	timer.start()
	return _format_success("Countdown %s started (%ss, label=%s)" % [
		_color_path(sid),
		_color_number(str(total)),
		label,
	])

#endregion

#region Internal helpers

func _on_once_fired(sid: String) -> void:
	if not _scheduled.has(sid):
		return
	var entry: Dictionary = _scheduled[sid]
	var cmd: String = str(entry.get("command", ""))
	_dispose_entry(sid)
	if cmd.is_empty():
		return
	if is_instance_valid(_registry) and _registry.has_method("execute_command"):
		_registry.execute_command(cmd)

func _on_repeat_fired(sid: String) -> void:
	if not _scheduled.has(sid):
		return
	var entry: Dictionary = _scheduled[sid]
	var cmd: String = str(entry.get("command", ""))
	if is_instance_valid(_registry) and _registry.has_method("execute_command") and not cmd.is_empty():
		_registry.execute_command(cmd)
	# Re-check: the executed command could have cancelled the schedule.
	if not _scheduled.has(sid):
		return
	var remaining: int = int(entry.get("remaining", 0)) - 1
	entry["remaining"] = remaining
	_scheduled[sid] = entry
	if remaining <= 0:
		_dispose_entry(sid)

func _on_countdown_tick(sid: String) -> void:
	if not _scheduled.has(sid):
		return
	var entry: Dictionary = _scheduled[sid]
	var label: String = str(entry.get("label", "Countdown"))
	var remaining: int = int(entry.get("remaining", 0)) - 1
	entry["remaining"] = remaining
	_scheduled[sid] = entry
	_emit_countdown_line(label, remaining)
	if remaining <= 0:
		_dispose_entry(sid)

func _emit_countdown_line(label: String, value: int) -> void:
	var line := "[color=%s][%s] %d[/color]" % [_COLOR_COUNTDOWN, label, value]
	if is_instance_valid(_core) and _core.has_method("info"):
		_core.info(line)
	else:
		print(line)

func _cancel_all_internal() -> void:
	var ids: Array = _scheduled.keys()
	for sid in ids:
		_dispose_entry(sid)
	_scheduled.clear()

func _dispose_entry(sid: String) -> void:
	if not _scheduled.has(sid):
		return
	var entry: Dictionary = _scheduled[sid]
	var timer: Timer = entry.get("timer", null) as Timer
	if is_instance_valid(timer):
		timer.stop()
		timer.queue_free()
	_scheduled.erase(sid)

func _on_registry_exiting() -> void:
	_cancel_all_internal()

func _get_tree() -> SceneTree:
	if is_instance_valid(_registry) and _registry.is_inside_tree():
		return _registry.get_tree()
	return Engine.get_main_loop() as SceneTree

func _next_id() -> String:
	_id_counter += 1
	return "sched_%d" % _id_counter

func _parse_non_negative_float(raw: String) -> float:
	var s := raw.strip_edges()
	if not (s.is_valid_float() or s.is_valid_int()):
		return -1.0
	var v := s.to_float()
	if v < 0.0:
		return -1.0
	return v

func _join_args(args: Array, start: int) -> String:
	if start >= args.size():
		return ""
	var parts: Array[String] = []
	for i in range(start, args.size()):
		parts.append(str(args[i]))
	return " ".join(parts).strip_edges()

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

func _color_num(v: float) -> String:
	return _color_number("%.2f" % v)

#endregion

@tool
class_name DebugConsoleReplayCommands extends RefCounted

# Session recorder/replayer with timing fidelity. Distinct from ActionRecorder:
# this captures the full console command stream WITH inter-command delays
# (delta_ms between events plus an absolute ticks_msec timestamp) and plays
# it back at the same cadence via SceneTree timers, optionally scaled by a
# speed multiplier.
#
# Record format: [{ "cmd": String, "delay_ms": int, "ts": int }, ...]
#   - delay_ms : ms elapsed since the previous recorded command (0 for the first)
#   - ts       : absolute Time.get_ticks_msec() at capture (debug aid)
#
# The orchestrator (BuiltInCommands.register_universal_commands) instantiates
# one of these and holds a strong reference; we hook the registry's
# command_executed signal to passively observe the live command stream.
#
# Both contexts (editor + runtime) are supported - SceneTree.create_timer is
# available in both via Engine.get_main_loop().

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_DIM := "#888888"

const _FORMAT_VERSION := 1

var _registry: Node
var _core: Node

# Recording state. A single recording can be active at a time; multiple
# named recordings live in _recordings until overwritten or saved.
var _recordings: Dictionary = {}        # name -> Array[Dictionary]
var _active_name: String = ""
var _record_start_ms: int = 0
var _last_event_ms: int = 0

# Playback state. Each active replay has a numeric id; replay_play allows
# only one at a time, replay_play_async allows many to interleave.
var _active_replays: Dictionary = {}    # id -> { name, speed, async, idx, total }
var _next_replay_id: int = 1
var _has_blocking_replay: bool = false

# Set to true while we're executing a command on behalf of a replay so that
# the command_executed observer does not re-record it (would cause runaway
# growth and infinite loops on re-play).
var _executing_replay: bool = false

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	if _registry.has_signal("command_executed") and not _registry.command_executed.is_connected(_on_command_executed):
		_registry.command_executed.connect(_on_command_executed)
	_registry.register_command("replay_record_start", _cmd_record_start, "Start recording commands with timing: replay_record_start [name]", "both")
	_registry.register_command("replay_record_stop", _cmd_record_stop, "Stop the active recording", "both")
	_registry.register_command("replay_play", _cmd_play, "Play back a recording at original cadence: replay_play <name> [speed]", "both")
	_registry.register_command("replay_play_async", _cmd_play_async, "Play back a recording without blocking subsequent console input: replay_play_async <name> [speed]", "both")
	_registry.register_command("replay_save", _cmd_save, "Persist a recording to disk: replay_save <name> <user://path.json>", "both")
	_registry.register_command("replay_load", _cmd_load, "Load a recording from disk: replay_load <user://path.json> [as_name]", "both")

#region Command implementations

func _cmd_record_start(args: Array, piped_input: String = "") -> String:
	if not _active_name.is_empty():
		return _format_error("Already recording '%s'. Stop it first with replay_record_stop." % _active_name)
	var name: String = str(args[0]).strip_edges() if args.size() > 0 else _auto_name()
	if name.is_empty():
		return _format_error("Recording name cannot be empty.")
	_recordings[name] = []
	_active_name = name
	_record_start_ms = Time.get_ticks_msec()
	_last_event_ms = _record_start_ms
	return _format_success("Recording '%s' started." % _color_path(name))

func _cmd_record_stop(args: Array, piped_input: String = "") -> String:
	if _active_name.is_empty():
		return _format_error("Not currently recording.")
	var name: String = _active_name
	var entries: Array = _recordings.get(name, [])
	var duration_ms: int = Time.get_ticks_msec() - _record_start_ms
	_active_name = ""
	_record_start_ms = 0
	_last_event_ms = 0
	return _format_success("Recording '%s' stopped: %s commands over %s ms." % [
		_color_path(name),
		_color_number(str(entries.size())),
		_color_number(str(duration_ms)),
	])

func _cmd_play(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: replay_play <name> [speed]")
	if _has_blocking_replay:
		return _format_error("A replay is already in progress. Use replay_play_async to interleave.")
	return _start_playback(args, false)

func _cmd_play_async(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: replay_play_async <name> [speed]")
	return _start_playback(args, true)

func _cmd_save(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: replay_save <name> <user://path.json>")
	var name: String = str(args[0]).strip_edges()
	var path: String = str(args[1]).strip_edges()
	if not _recordings.has(name):
		return _format_error("Unknown recording: %s" % name)
	if name == _active_name:
		return _format_error("Stop recording '%s' before saving." % name)
	var entries: Array = _recordings[name]
	var payload: Dictionary = {
		"version": _FORMAT_VERSION,
		"name": name,
		"saved_at_ms": Time.get_ticks_msec(),
		"event_count": entries.size(),
		"events": entries,
	}
	var dir_err: int = _ensure_parent_dir(path)
	if dir_err != OK:
		return _format_error("Failed to create directory for %s (err %d)" % [path, dir_err])
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if not file:
		return _format_error("Cannot open %s for write (err %d)" % [path, FileAccess.get_open_error()])
	file.store_string(JSON.stringify(payload, "  "))
	file.close()
	return _format_success("Saved '%s' (%s events) to %s" % [
		_color_path(name),
		_color_number(str(entries.size())),
		_color_path(path),
	])

func _cmd_load(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: replay_load <user://path.json> [as_name]")
	var path: String = str(args[0]).strip_edges()
	var override_name: String = str(args[1]).strip_edges() if args.size() > 1 else ""
	if not FileAccess.file_exists(path):
		return _format_error("File not found: %s" % path)
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if not file:
		return _format_error("Cannot open %s for read (err %d)" % [path, FileAccess.get_open_error()])
	var text: String = file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return _format_error("Malformed replay file: expected JSON object.")
	var payload: Dictionary = parsed
	var events_raw: Variant = payload.get("events", [])
	if typeof(events_raw) != TYPE_ARRAY:
		return _format_error("Malformed replay file: 'events' is not an array.")
	var events: Array = []
	for item in events_raw:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = item
		events.append({
			"cmd": str(d.get("cmd", "")),
			"delay_ms": int(d.get("delay_ms", 0)),
			"ts": int(d.get("ts", 0)),
		})
	var name: String = override_name if not override_name.is_empty() else str(payload.get("name", ""))
	if name.is_empty():
		name = _auto_name()
	_recordings[name] = events
	return _format_success("Loaded '%s' (%s events) from %s" % [
		_color_path(name),
		_color_number(str(events.size())),
		_color_path(path),
	])

#endregion

#region Recording hook

func _on_command_executed(command: String, _result: String) -> void:
	if _active_name.is_empty():
		return
	if _executing_replay:
		return
	var cmd_text: String = command.strip_edges()
	if cmd_text.is_empty():
		return
	if _is_replay_command(cmd_text):
		return
	var now: int = Time.get_ticks_msec()
	var entries: Array = _recordings.get(_active_name, [])
	var delay_ms: int = 0 if entries.is_empty() else max(0, now - _last_event_ms)
	entries.append({
		"cmd": cmd_text,
		"delay_ms": delay_ms,
		"ts": now,
	})
	_recordings[_active_name] = entries
	_last_event_ms = now

func _is_replay_command(cmd_text: String) -> bool:
	var head: String = cmd_text.split(" ", false, 1)[0]
	return head.begins_with("replay_")

#endregion

#region Playback

func _start_playback(args: Array, is_async: bool) -> String:
	var name: String = str(args[0]).strip_edges()
	var speed: float = 1.0
	if args.size() > 1:
		var raw_speed: String = str(args[1]).strip_edges()
		if raw_speed.is_valid_float() or raw_speed.is_valid_int():
			speed = raw_speed.to_float()
	if speed <= 0.0:
		return _format_error("Speed must be > 0.0 (got %s)" % str(speed))
	if not _recordings.has(name):
		return _format_error("Unknown recording: %s" % name)
	var entries: Array = _recordings[name]
	if entries.is_empty():
		return _format_error("Recording '%s' is empty." % name)
	var tree: SceneTree = _get_tree()
	if not tree:
		return _format_error("No SceneTree available for timed playback.")

	var replay_id: int = _next_replay_id
	_next_replay_id += 1
	_active_replays[replay_id] = {
		"name": name,
		"speed": speed,
		"async": is_async,
		"idx": 0,
		"total": entries.size(),
	}
	if not is_async:
		_has_blocking_replay = true
	_schedule_step(replay_id)
	var mode: String = "async" if is_async else "sync"
	return _format_success("Replay #%s started '%s' x%s (%s, %s events)" % [
		_color_number(str(replay_id)),
		_color_path(name),
		_color_number(str(speed)),
		mode,
		_color_number(str(entries.size())),
	])

func _schedule_step(replay_id: int) -> void:
	if not _active_replays.has(replay_id):
		return
	var state: Dictionary = _active_replays[replay_id]
	var name: String = state.get("name", "")
	var entries: Array = _recordings.get(name, [])
	var idx: int = int(state.get("idx", 0))
	if idx >= entries.size():
		_finish_replay(replay_id)
		return
	var tree: SceneTree = _get_tree()
	if not tree:
		_finish_replay(replay_id)
		return
	var entry: Dictionary = entries[idx]
	var speed: float = float(state.get("speed", 1.0))
	if speed <= 0.0:
		speed = 1.0
	var wait_s: float = max(0.0, float(int(entry.get("delay_ms", 0))) / 1000.0 / speed)
	var timer: SceneTreeTimer = tree.create_timer(wait_s)
	timer.timeout.connect(_run_step.bind(replay_id))

func _run_step(replay_id: int) -> void:
	if not _active_replays.has(replay_id):
		return
	var state: Dictionary = _active_replays[replay_id]
	var name: String = state.get("name", "")
	var entries: Array = _recordings.get(name, [])
	var idx: int = int(state.get("idx", 0))
	if idx >= entries.size():
		_finish_replay(replay_id)
		return
	var entry: Dictionary = entries[idx]
	var cmd_text: String = str(entry.get("cmd", "")).strip_edges()
	if not cmd_text.is_empty() and _registry and _registry.has_method("execute_command"):
		_executing_replay = true
		_registry.execute_command(cmd_text)
		_executing_replay = false
	state["idx"] = idx + 1
	_active_replays[replay_id] = state
	_schedule_step(replay_id)

func _finish_replay(replay_id: int) -> void:
	if not _active_replays.has(replay_id):
		return
	var state: Dictionary = _active_replays[replay_id]
	_active_replays.erase(replay_id)
	if not bool(state.get("async", false)):
		_has_blocking_replay = false

#endregion

#region Helpers

func _get_tree() -> SceneTree:
	var loop: MainLoop = Engine.get_main_loop()
	if loop is SceneTree:
		return loop
	return null

func _auto_name() -> String:
	return "replay_%d" % Time.get_ticks_msec()

func _ensure_parent_dir(path: String) -> int:
	var dir_path: String = path.get_base_dir()
	if dir_path.is_empty():
		return OK
	if DirAccess.dir_exists_absolute(dir_path):
		return OK
	return DirAccess.make_dir_recursive_absolute(dir_path)

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

#endregion

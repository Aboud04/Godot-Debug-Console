@tool
class_name DebugConsoleSignalProfileCommands extends RefCounted

# Tier-? signal-profiler extension. Mirrors the SceneCommands convention:
# instantiated once by BuiltInCommands.register_universal_commands(), which
# holds a strong reference so the Callables registered here stay valid for
# the lifetime of the plugin. Game-only commands: every command needs a live
# scene tree to walk and signals do not fire in the editor anyway.
#
# Selector grammar follows the rest of the console: <node_path>.<signal_name>.
# Trackers are keyed by "<resolved_path>::<signal>" so the same logical signal
# tracked twice (e.g. via abs path and relative path resolving to the same
# node) cannot create duplicate connections.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_WARN := "#F0A040"

const _DEFAULT_TOP_N := 10
const _RATE_WINDOW_MS := 1000
const _RATE_STALE_MS := 2000

var _registry: Node
var _core: Node

# key -> {
#     "node_ref": WeakRef,
#     "node_path": String,
#     "signal_name": String,
#     "count": int,                # total emissions since track started
#     "window_count": int,         # emissions in current 1-second window
#     "window_start_ms": int,      # window start timestamp
#     "last_emit_ms": int,         # last emission timestamp (for staleness)
#     "rate": float,               # last computed Hz
#     "alarm_hz": float,           # -1.0 disabled
#     "alarm_fired": bool,         # currently above threshold
#     "started_ms": int,
#     "callable": Callable,
# }
var _trackers: Dictionary = {}

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("sig_track", _cmd_sig_track, "Track signal emissions/sec: sig_track <node_path>.<signal>", "game")
	_registry.register_command("sig_untrack", _cmd_sig_untrack, "Stop tracking a signal: sig_untrack <node_path>.<signal|all>", "game")
	_registry.register_command("sig_list", _cmd_sig_list, "List tracked signals with per-second rates: sig_list", "game")
	_registry.register_command("sig_dump_to", _cmd_sig_dump_to, "Dump tracked-signal stats to a file: sig_dump_to <file>", "game")
	_registry.register_command("sig_top", _cmd_sig_top, "Show signals with most connections across the tree: sig_top [n]", "game")
	_registry.register_command("sig_alarm", _cmd_sig_alarm, "Warn when a signal exceeds a rate: sig_alarm <node_path>.<signal> <rate_hz>", "game")

#region Command implementations

func _cmd_sig_track(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: sig_track <node_path>.<signal>")
	var selector := str(args[0]).strip_edges()
	var split := _split_selector(selector)
	if split.is_empty():
		return _format_error("Selector must be <node_path>.<signal>: %s" % selector)

	var node := _resolve_node(split[0])
	if not node:
		return _format_error("Node not found: %s" % split[0])
	var sig: String = split[1]
	if not node.has_signal(sig):
		return _format_error("Signal not found: %s on %s" % [sig, node.get_class()])

	var resolved_path: String = str(node.get_path()) if node.is_inside_tree() else node.name
	var key := _tracker_key(resolved_path, sig)
	if _trackers.has(key):
		return _format_error("Already tracking %s.%s" % [resolved_path, sig])

	var arg_count: int = _signal_arg_count(node, sig)
	var callable := Callable(self, "_on_signal_emit").bind(key)
	if arg_count > 0:
		callable = callable.unbind(arg_count)
	var err: int = node.connect(sig, callable)
	if err != OK:
		return _format_error("connect() returned error %d" % err)

	var now := Time.get_ticks_msec()
	_trackers[key] = {
		"node_ref": weakref(node),
		"node_path": resolved_path,
		"signal_name": sig,
		"count": 0,
		"window_count": 0,
		"window_start_ms": now,
		"last_emit_ms": 0,
		"rate": 0.0,
		"alarm_hz": -1.0,
		"alarm_fired": false,
		"started_ms": now,
		"callable": callable,
	}
	return _format_success("Tracking %s.%s" % [_color_path(resolved_path), sig])

func _cmd_sig_untrack(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: sig_untrack <node_path>.<signal|all>")
	var raw := str(args[0]).strip_edges()

	if raw == "all" or raw.to_lower().ends_with(".all"):
		var removed := 0
		for key in _trackers.keys():
			_disconnect_tracker(key)
			removed += 1
		_trackers.clear()
		return _format_success("Untracked %s signal(s)" % _color_number(str(removed)))

	var split := _split_selector(raw)
	if split.is_empty():
		return _format_error("Selector must be <node_path>.<signal> or <node_path>.all: %s" % raw)

	var node := _resolve_node(split[0])
	var node_path: String = str(node.get_path()) if node and node.is_inside_tree() else split[0]
	var sig: String = split[1]

	if sig == "all":
		var removed_for_node := 0
		var match_prefix := node_path + "::"
		for key in _trackers.keys():
			if str(key).begins_with(match_prefix):
				_disconnect_tracker(key)
				_trackers.erase(key)
				removed_for_node += 1
		if removed_for_node == 0:
			return _format_error("No trackers for %s" % node_path)
		return _format_success("Untracked %s signal(s) on %s" % [_color_number(str(removed_for_node)), _color_path(node_path)])

	var key := _tracker_key(node_path, sig)
	if not _trackers.has(key):
		return _format_error("Not tracking %s.%s" % [node_path, sig])
	_disconnect_tracker(key)
	_trackers.erase(key)
	return _format_success("Untracked %s.%s" % [_color_path(node_path), sig])

func _cmd_sig_list(args: Array, piped_input: String = "") -> String:
	if _trackers.is_empty():
		return "No signals tracked. Use sig_track <node_path>.<signal>."
	var rows: Array[Dictionary] = []
	var dead_keys: Array[String] = []
	for key in _trackers.keys():
		var t: Dictionary = _trackers[key]
		var node = (t["node_ref"] as WeakRef).get_ref()
		var alive: bool = node != null and is_instance_valid(node)
		_refresh_rate(t)
		rows.append({
			"path": str(t["node_path"]),
			"signal": str(t["signal_name"]),
			"count": int(t["count"]),
			"rate": float(t["rate"]),
			"alarm_hz": float(t["alarm_hz"]),
			"alive": alive,
		})
		if not alive:
			dead_keys.append(str(key))
	for k in dead_keys:
		_trackers.erase(k)

	rows.sort_custom(func(a, b): return float(a.rate) > float(b.rate))
	var lines: Array[String] = []
	lines.append("Tracking %d signal(s):" % rows.size())
	for r in rows:
		var alarm_txt := ""
		if float(r.alarm_hz) > 0.0:
			alarm_txt = " alarm=%s Hz" % _color_number("%.1f" % float(r.alarm_hz))
		var alive_marker := "" if bool(r.alive) else " [color=%s](dead)[/color]" % _COLOR_ERROR
		lines.append("  %s.%s  count=%s  rate=%s Hz%s%s" % [
			_color_path(str(r.path)),
			str(r.signal),
			_color_number(str(int(r.count))),
			_color_number("%.2f" % float(r.rate)),
			alarm_txt,
			alive_marker,
		])
	return "\n".join(lines)

func _cmd_sig_dump_to(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: sig_dump_to <file>")
	var path := str(args[0]).strip_edges()
	if path.is_empty():
		return _format_error("File path is empty")

	var payload: Dictionary = {
		"timestamp_ms": Time.get_ticks_msec(),
		"datetime": Time.get_datetime_string_from_system(),
		"tracker_count": _trackers.size(),
		"trackers": [],
	}
	for key in _trackers.keys():
		var t: Dictionary = _trackers[key]
		_refresh_rate(t)
		var node = (t["node_ref"] as WeakRef).get_ref()
		var elapsed_ms: int = Time.get_ticks_msec() - int(t["started_ms"])
		var avg_rate: float = 0.0
		if elapsed_ms > 0:
			avg_rate = float(t["count"]) * 1000.0 / float(elapsed_ms)
		(payload["trackers"] as Array).append({
			"node_path": str(t["node_path"]),
			"signal": str(t["signal_name"]),
			"count": int(t["count"]),
			"rate_hz": float(t["rate"]),
			"avg_rate_hz": avg_rate,
			"elapsed_ms": elapsed_ms,
			"alarm_hz": float(t["alarm_hz"]),
			"alive": node != null and is_instance_valid(node),
		})

	var file := FileAccess.open(path, FileAccess.WRITE)
	if not file:
		return _format_error("Could not open for write: %s (err %d)" % [path, FileAccess.get_open_error()])
	file.store_string(JSON.stringify(payload, "  "))
	file.close()
	return _format_success("Dumped %s tracker(s) to %s" % [_color_number(str(_trackers.size())), _color_path(path)])

func _cmd_sig_top(args: Array, piped_input: String = "") -> String:
	var n: int = _DEFAULT_TOP_N
	if args.size() > 0:
		var raw := str(args[0]).strip_edges()
		if raw.is_valid_int():
			n = max(1, raw.to_int())

	var root := _get_scene_root()
	if not root:
		return _format_error("No scene root available")

	# aggregate: signal_name -> {connections: int, emitters: int, sample_path: String}
	var totals: Dictionary = {}
	_walk_signals(root, totals)

	var rows: Array[Dictionary] = []
	for sig_name in totals.keys():
		var entry: Dictionary = totals[sig_name]
		rows.append({
			"signal": str(sig_name),
			"connections": int(entry["connections"]),
			"emitters": int(entry["emitters"]),
			"sample": str(entry["sample_path"]),
		})
	rows.sort_custom(func(a, b): return int(a.connections) > int(b.connections))

	if rows.is_empty():
		return "No signals found under %s" % str(root.get_path())

	var shown: int = min(n, rows.size())
	var lines: Array[String] = []
	lines.append("Top %s signal(s) under %s (by connection count):" % [_color_number(str(shown)), _color_path(str(root.get_path()))])
	for i in range(shown):
		var r: Dictionary = rows[i]
		lines.append("  %2d. %s  connections=%s  emitters=%s  sample=%s" % [
			i + 1,
			str(r["signal"]),
			_color_number(str(int(r["connections"]))),
			_color_number(str(int(r["emitters"]))),
			_color_path(str(r["sample"])),
		])
	return "\n".join(lines)

func _cmd_sig_alarm(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: sig_alarm <node_path>.<signal> <rate_hz>")
	var selector := str(args[0]).strip_edges()
	var split := _split_selector(selector)
	if split.is_empty():
		return _format_error("Selector must be <node_path>.<signal>: %s" % selector)
	var rate_hz: float = str(args[1]).strip_edges().to_float()
	if rate_hz <= 0.0:
		return _format_error("rate_hz must be > 0")

	var node := _resolve_node(split[0])
	if not node:
		return _format_error("Node not found: %s" % split[0])
	var sig: String = split[1]
	var resolved_path: String = str(node.get_path()) if node.is_inside_tree() else node.name
	var key := _tracker_key(resolved_path, sig)

	if not _trackers.has(key):
		var track_result: String = _cmd_sig_track([selector])
		if track_result.contains("Error:"):
			return track_result

	var t: Dictionary = _trackers[key]
	t["alarm_hz"] = rate_hz
	t["alarm_fired"] = false
	return _format_success("Alarm set on %s.%s at %s Hz" % [_color_path(resolved_path), sig, _color_number("%.2f" % rate_hz)])

#endregion

#region Internal hooks

func _on_signal_emit(key: String) -> void:
	if not _trackers.has(key):
		return
	var t: Dictionary = _trackers[key]
	var now := Time.get_ticks_msec()
	t["count"] = int(t["count"]) + 1
	t["window_count"] = int(t["window_count"]) + 1
	t["last_emit_ms"] = now

	var elapsed_ms: int = now - int(t["window_start_ms"])
	if elapsed_ms >= _RATE_WINDOW_MS:
		var rate: float = float(t["window_count"]) * 1000.0 / float(elapsed_ms)
		t["rate"] = rate
		t["window_count"] = 0
		t["window_start_ms"] = now
		var alarm_hz: float = float(t["alarm_hz"])
		if alarm_hz > 0.0:
			if rate > alarm_hz and not bool(t["alarm_fired"]):
				t["alarm_fired"] = true
				push_warning("[SignalProfile] %s.%s rate %.2f Hz exceeds alarm %.2f Hz" % [
					str(t["node_path"]), str(t["signal_name"]), rate, alarm_hz,
				])
			elif rate <= alarm_hz and bool(t["alarm_fired"]):
				t["alarm_fired"] = false

#endregion

#region Helpers

func _tracker_key(node_path: String, signal_name: String) -> String:
	return "%s::%s" % [node_path, signal_name]

func _signal_arg_count(node: Object, signal_name: String) -> int:
	for info in node.get_signal_list():
		if str(info.get("name", "")) == signal_name:
			return (info.get("args", []) as Array).size()
	return 0

func _refresh_rate(t: Dictionary) -> void:
	# If the signal has been silent long enough, decay the displayed rate to 0
	# so sig_list does not show a stale Hz reading from minutes ago.
	var now := Time.get_ticks_msec()
	var since_last_emit: int = now - int(t["last_emit_ms"])
	if int(t["last_emit_ms"]) == 0 or since_last_emit > _RATE_STALE_MS:
		t["rate"] = 0.0
		t["window_count"] = 0
		t["window_start_ms"] = now

func _disconnect_tracker(key: String) -> void:
	if not _trackers.has(key):
		return
	var t: Dictionary = _trackers[key]
	var node = (t["node_ref"] as WeakRef).get_ref()
	if node != null and is_instance_valid(node):
		var callable: Callable = t["callable"]
		var sig: String = str(t["signal_name"])
		if (node as Object).has_signal(sig) and (node as Object).is_connected(sig, callable):
			(node as Object).disconnect(sig, callable)

func _walk_signals(node: Node, totals: Dictionary) -> void:
	for info in node.get_signal_list():
		var sig_name: String = str(info.get("name", ""))
		if sig_name.is_empty():
			continue
		var conn_count: int = node.get_signal_connection_list(sig_name).size()
		if conn_count <= 0:
			continue
		if not totals.has(sig_name):
			totals[sig_name] = {
				"connections": 0,
				"emitters": 0,
				"sample_path": str(node.get_path()) if node.is_inside_tree() else node.name,
			}
		var entry: Dictionary = totals[sig_name]
		entry["connections"] = int(entry["connections"]) + conn_count
		entry["emitters"] = int(entry["emitters"]) + 1
	for child in node.get_children():
		_walk_signals(child, totals)

func _get_scene_root() -> Node:
	if Engine.is_editor_hint():
		return EditorInterface.get_edited_scene_root()
	var tree := Engine.get_main_loop() as SceneTree
	if not tree:
		return null
	if tree.current_scene:
		return tree.current_scene
	return tree.root

func _resolve_node(path: String) -> Node:
	var p := path.strip_edges()
	if p.is_empty():
		return null

	if Engine.is_editor_hint():
		var root := _get_scene_root()
		if not root:
			return null
		if p == "/root":
			return root
		if p.begins_with("/root/"):
			p = p.substr(6)
		elif p.begins_with("/"):
			p = p.substr(1)
		if p == root.name:
			return root
		if p.begins_with(root.name + "/"):
			p = p.substr(root.name.length() + 1)
		if p.is_empty():
			return root
		return root.get_node_or_null(p)

	var tree := Engine.get_main_loop() as SceneTree
	if not tree:
		return null
	if p.begins_with("/"):
		return tree.root.get_node_or_null(p)
	var scene: Node = tree.current_scene if tree.current_scene else tree.root
	return scene.get_node_or_null(p)

func _split_selector(selector: String) -> Array:
	var idx := selector.rfind(".")
	if idx <= 0 or idx >= selector.length() - 1:
		return []
	return [selector.substr(0, idx), selector.substr(idx + 1)]

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

#endregion

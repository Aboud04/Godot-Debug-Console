@tool
class_name DebugConsoleProfileCommands extends RefCounted

# Command-level profiling extension. Auto-loaded by the extensions loader; no
# edits to BuiltInCommands.gd are needed. The orchestrator instantiates this
# module once and stores it in the shared _t6_keepalive array, which means the
# `_recordings` dict below persists for the entire plugin lifetime.
#
# All timings are taken with Time.get_ticks_usec() so they have microsecond
# precision. Output is reported in milliseconds with three decimals.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"

const _COMPARE_SEP := "--"

var _registry: Node
var _core: Node
var _recordings: Dictionary = {}

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("profile_call", _cmd_profile_call, "Measure ms to run one command: profile_call <command...>", "both")
	_registry.register_command("profile_avg", _cmd_profile_avg, "Run command N times, report avg/min/max/stddev: profile_avg <iter> <command...>", "both")
	_registry.register_command("profile_compare", _cmd_profile_compare, "Run two commands, report delta: profile_compare <cmd_a...> -- <cmd_b...>", "both")
	_registry.register_command("profile_record_start", _cmd_profile_record_start, "Start a named recording: profile_record_start <name>", "both")
	_registry.register_command("profile_record_stop", _cmd_profile_record_stop, "Stop a recording and report duration: profile_record_stop <name>", "both")
	_registry.register_command("profile_list", _cmd_profile_list, "List active (in-progress) recordings", "both")
	_registry.register_command("profile_func", _cmd_profile_func, "Call a method N times and time it: profile_func <path>.<method> <iter> [args...]", "both")
	_registry.register_command("profile_export", _cmd_profile_export, "Dump all recordings as JSON: profile_export <res://path.json>", "both")

#region Command implementations

func _cmd_profile_call(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: profile_call <command...>")
	if not _registry:
		return _format_error("Registry unavailable")
	var cmd := _join_args(args, 0)
	if cmd.is_empty():
		return _format_error("Empty command")

	var t0 := Time.get_ticks_usec()
	var output := _run_command(cmd)
	var t1 := Time.get_ticks_usec()
	var elapsed_us: int = t1 - t0
	var elapsed_ms: float = elapsed_us / 1000.0

	var lines: Array[String] = []
	lines.append("%s %s in %s ms (%s us)" % [
		_format_success("profile_call"),
		_color_path(cmd),
		_color_number("%.3f" % elapsed_ms),
		_color_number(str(elapsed_us)),
	])
	if not output.is_empty():
		lines.append("output: %s" % output)
	return "\n".join(lines)

func _cmd_profile_avg(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: profile_avg <iter> <command...>")
	if not _registry:
		return _format_error("Registry unavailable")

	var iter_str := str(args[0]).strip_edges()
	if not iter_str.is_valid_int():
		return _format_error("Iteration count must be an integer: %s" % iter_str)
	var iterations: int = iter_str.to_int()
	if iterations <= 0:
		return _format_error("Iteration count must be > 0")

	var cmd := _join_args(args, 1)
	if cmd.is_empty():
		return _format_error("Empty command")

	var samples_us: Array[int] = []
	var last_error := ""
	for i in iterations:
		var t0 := Time.get_ticks_usec()
		var out := _run_command(cmd)
		var t1 := Time.get_ticks_usec()
		samples_us.append(t1 - t0)
		if _looks_like_error(out):
			last_error = out

	var sum_us: int = 0
	var min_us: int = samples_us[0]
	var max_us: int = samples_us[0]
	for s in samples_us:
		sum_us += s
		if s < min_us: min_us = s
		if s > max_us: max_us = s
	var mean_us: float = float(sum_us) / float(iterations)
	var variance: float = 0.0
	for s in samples_us:
		var d: float = float(s) - mean_us
		variance += d * d
	variance /= float(iterations)
	var stddev_us: float = sqrt(variance)

	var lines: Array[String] = []
	lines.append("%s %s x%s" % [
		_format_success("profile_avg"),
		_color_path(cmd),
		_color_number(str(iterations)),
	])
	lines.append("  avg:    %s ms" % _color_number("%.3f" % (mean_us / 1000.0)))
	lines.append("  min:    %s ms" % _color_number("%.3f" % (float(min_us) / 1000.0)))
	lines.append("  max:    %s ms" % _color_number("%.3f" % (float(max_us) / 1000.0)))
	lines.append("  stddev: %s ms" % _color_number("%.3f" % (stddev_us / 1000.0)))
	lines.append("  total:  %s ms" % _color_number("%.3f" % (float(sum_us) / 1000.0)))
	if not last_error.is_empty():
		lines.append("note: last error-looking output: %s" % last_error)
	return "\n".join(lines)

func _cmd_profile_compare(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: profile_compare <cmd_a...> %s <cmd_b...>" % _COMPARE_SEP)
	if not _registry:
		return _format_error("Registry unavailable")

	var sep_idx: int = -1
	for i in args.size():
		if str(args[i]).strip_edges() == _COMPARE_SEP:
			sep_idx = i
			break
	if sep_idx <= 0 or sep_idx >= args.size() - 1:
		return _format_error("Separator '%s' required between commands: profile_compare <cmd_a...> %s <cmd_b...>" % [_COMPARE_SEP, _COMPARE_SEP])

	var cmd_a := _join_args_slice(args, 0, sep_idx)
	var cmd_b := _join_args_slice(args, sep_idx + 1, args.size())
	if cmd_a.is_empty() or cmd_b.is_empty():
		return _format_error("Both sides of '%s' must be non-empty" % _COMPARE_SEP)

	var ta0 := Time.get_ticks_usec()
	var _out_a := _run_command(cmd_a)
	var ta1 := Time.get_ticks_usec()
	var us_a: int = ta1 - ta0

	var tb0 := Time.get_ticks_usec()
	var _out_b := _run_command(cmd_b)
	var tb1 := Time.get_ticks_usec()
	var us_b: int = tb1 - tb0

	var delta_us: int = us_b - us_a
	var faster := "tie"
	if us_a < us_b: faster = "A"
	elif us_b < us_a: faster = "B"
	var ratio := 0.0
	if us_a > 0:
		ratio = float(us_b) / float(us_a)

	var lines: Array[String] = []
	lines.append("%s" % _format_success("profile_compare"))
	lines.append("  A: %s -> %s ms" % [_color_path(cmd_a), _color_number("%.3f" % (float(us_a) / 1000.0))])
	lines.append("  B: %s -> %s ms" % [_color_path(cmd_b), _color_number("%.3f" % (float(us_b) / 1000.0))])
	lines.append("  delta (B-A): %s ms" % _color_number("%.3f" % (float(delta_us) / 1000.0)))
	lines.append("  ratio (B/A): %s" % _color_number("%.3f" % ratio))
	lines.append("  faster: %s" % _color_path(faster))
	return "\n".join(lines)

func _cmd_profile_record_start(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: profile_record_start <name>")
	var name := _join_args(args, 0)
	if name.is_empty():
		return _format_error("Recording name required")
	var existing: Dictionary = _recordings.get(name, {})
	if not existing.is_empty() and int(existing.get("stop_usec", 0)) == 0:
		return _format_error("Recording already active: %s" % name)
	_recordings[name] = {
		"start_usec": Time.get_ticks_usec(),
		"stop_usec": 0,
		"duration_usec": 0,
	}
	return _format_success("Recording started: %s" % _color_path(name))

func _cmd_profile_record_stop(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: profile_record_stop <name>")
	var name := _join_args(args, 0)
	if name.is_empty():
		return _format_error("Recording name required")
	if not _recordings.has(name):
		return _format_error("No such recording: %s" % name)
	var rec: Dictionary = _recordings[name]
	if int(rec.get("stop_usec", 0)) != 0:
		return _format_error("Recording already stopped: %s (duration %.3f ms)" % [name, float(rec.get("duration_usec", 0)) / 1000.0])
	var stop_us := Time.get_ticks_usec()
	var duration_us: int = stop_us - int(rec.get("start_usec", stop_us))
	rec["stop_usec"] = stop_us
	rec["duration_usec"] = duration_us
	_recordings[name] = rec
	return "%s %s in %s ms (%s us)" % [
		_format_success("Recording stopped:"),
		_color_path(name),
		_color_number("%.3f" % (float(duration_us) / 1000.0)),
		_color_number(str(duration_us)),
	]

func _cmd_profile_list(args: Array, piped_input: String = "") -> String:
	var active: Array[String] = []
	var now_us := Time.get_ticks_usec()
	var keys: Array = _recordings.keys()
	keys.sort()
	for k in keys:
		var rec: Dictionary = _recordings[k]
		if int(rec.get("stop_usec", 0)) != 0:
			continue
		var elapsed_us: int = now_us - int(rec.get("start_usec", now_us))
		active.append("  %s elapsed %s ms" % [
			_color_path(str(k)),
			_color_number("%.3f" % (float(elapsed_us) / 1000.0)),
		])
	if active.is_empty():
		return _format_success("No active recordings (total stored: %d)" % _recordings.size())
	var lines: Array[String] = []
	lines.append("%s (%d)" % [_format_success("Active recordings:"), active.size()])
	lines.append_array(active)
	return "\n".join(lines)

func _cmd_profile_func(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: profile_func <path>.<method> <iter> [args...]")
	var selector := str(args[0]).strip_edges()
	var split := _split_selector(selector)
	if split.is_empty():
		return _format_error("Selector must be <path>.<method>: %s" % selector)
	var iter_str := str(args[1]).strip_edges()
	if not iter_str.is_valid_int():
		return _format_error("Iteration count must be an integer: %s" % iter_str)
	var iterations: int = iter_str.to_int()
	if iterations <= 0:
		return _format_error("Iteration count must be > 0")

	var node := _resolve_node(split[0])
	if not node:
		return _format_error("Node not found: %s" % split[0])
	var method: String = split[1]
	if not node.has_method(method):
		return _format_error("Method not found: %s on %s" % [method, node.get_class()])

	var call_args: Array = []
	for i in range(2, args.size()):
		call_args.append(_parse_value(str(args[i])))

	var samples_us: Array[int] = []
	for i in iterations:
		var t0 := Time.get_ticks_usec()
		node.callv(method, call_args)
		var t1 := Time.get_ticks_usec()
		samples_us.append(t1 - t0)

	var sum_us: int = 0
	var min_us: int = samples_us[0]
	var max_us: int = samples_us[0]
	for s in samples_us:
		sum_us += s
		if s < min_us: min_us = s
		if s > max_us: max_us = s
	var mean_us: float = float(sum_us) / float(iterations)
	var variance: float = 0.0
	for s in samples_us:
		var d: float = float(s) - mean_us
		variance += d * d
	variance /= float(iterations)
	var stddev_us: float = sqrt(variance)

	var lines: Array[String] = []
	lines.append("%s %s x%s" % [
		_format_success("profile_func"),
		_color_path("%s.%s" % [split[0], method]),
		_color_number(str(iterations)),
	])
	lines.append("  avg:    %s ms" % _color_number("%.3f" % (mean_us / 1000.0)))
	lines.append("  min:    %s ms" % _color_number("%.3f" % (float(min_us) / 1000.0)))
	lines.append("  max:    %s ms" % _color_number("%.3f" % (float(max_us) / 1000.0)))
	lines.append("  stddev: %s ms" % _color_number("%.3f" % (stddev_us / 1000.0)))
	lines.append("  total:  %s ms" % _color_number("%.3f" % (float(sum_us) / 1000.0)))
	return "\n".join(lines)

func _cmd_profile_export(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: profile_export <res://path.json>")
	var path := _join_args(args, 0)
	if path.is_empty():
		return _format_error("Output path required")
	if not (path.begins_with("res://") or path.begins_with("user://")):
		return _format_error("Path must start with res:// or user://: %s" % path)

	var payload: Dictionary = {
		"generated_at_usec": Time.get_ticks_usec(),
		"unix_time": Time.get_unix_time_from_system(),
		"count": _recordings.size(),
		"recordings": {},
	}
	var keys: Array = _recordings.keys()
	keys.sort()
	for k in keys:
		var rec: Dictionary = _recordings[k]
		var stop_us: int = int(rec.get("stop_usec", 0))
		var start_us: int = int(rec.get("start_usec", 0))
		var dur_us: int = int(rec.get("duration_usec", 0))
		var active: bool = stop_us == 0
		if active:
			dur_us = Time.get_ticks_usec() - start_us
		(payload["recordings"] as Dictionary)[str(k)] = {
			"start_usec": start_us,
			"stop_usec": stop_us,
			"active": active,
			"duration_usec": dur_us,
			"duration_ms": float(dur_us) / 1000.0,
		}

	var file := FileAccess.open(path, FileAccess.WRITE)
	if not file:
		var err := FileAccess.get_open_error()
		return _format_error("Could not open %s for writing (err %d)" % [path, err])
	file.store_string(JSON.stringify(payload, "  "))
	file.close()
	return _format_success("Exported %d recording(s) to %s" % [_recordings.size(), _color_path(path)])

#endregion

#region Helpers

func _run_command(cmd: String) -> String:
	if not _registry:
		return ""
	if not _registry.has_method("execute_command"):
		return ""
	return str(_registry.execute_command(cmd))

func _looks_like_error(output: String) -> bool:
	return output.contains("Error:") or output.contains("[color=%s]Error" % _COLOR_ERROR)

func _join_args(args: Array, start: int) -> String:
	var parts: Array[String] = []
	for i in range(start, args.size()):
		parts.append(str(args[i]))
	return " ".join(parts).strip_edges()

func _join_args_slice(args: Array, start: int, end_exclusive: int) -> String:
	var parts: Array[String] = []
	for i in range(start, end_exclusive):
		parts.append(str(args[i]))
	return " ".join(parts).strip_edges()

func _split_selector(selector: String) -> Array:
	var idx := selector.rfind(".")
	if idx <= 0 or idx >= selector.length() - 1:
		return []
	return [selector.substr(0, idx), selector.substr(idx + 1)]

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

func _parse_value(raw: String) -> Variant:
	var s := raw.strip_edges()
	if s.is_empty():
		return ""
	if s == "null":
		return null
	if s == "true":
		return true
	if s == "false":
		return false
	if (s.begins_with("\"") and s.ends_with("\"")) or (s.begins_with("'") and s.ends_with("'")):
		return s.substr(1, s.length() - 2)
	if s.contains(","):
		var parts: PackedStringArray = s.split(",")
		var nums: Array[float] = []
		var all_num: bool = true
		for p in parts:
			var t := p.strip_edges()
			if not (t.is_valid_float() or t.is_valid_int()):
				all_num = false
				break
			nums.append(t.to_float())
		if all_num:
			match nums.size():
				2: return Vector2(nums[0], nums[1])
				3: return Vector3(nums[0], nums[1], nums[2])
				4: return Vector4(nums[0], nums[1], nums[2], nums[3])
	if s.is_valid_int():
		return s.to_int()
	if s.is_valid_float():
		return s.to_float()
	return s

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

#endregion

@tool
class_name DebugConsoleScriptTimingCommands extends RefCounted

# Script timing extension - hot-path microbenchmarks for live scenes.
# Mirrors the layout of core/SceneCommands.gd: the orchestrator instantiates
# one of these, keeps a strong reference, and calls register_commands().
# All state (named regions, active signal timers, completed-measurement
# history for CSV export) lives on this instance so Callables stay valid
# for the lifetime of the plugin.
#
# Commands:
#   time_method <path>.<method> [iter=1000]   - callv N times, avg/min/max
#   time_expr <expr> [iter=1000]              - Expression eval timing
#   time_signal <path>.<signal>               - toggle: attach wrapper / stop & report
#   time_record <name>                        - start a named region
#   time_record_stop <name>                   - stop region, report, store
#   time_list                                 - active regions + active signal timers
#   time_export <res://path>                  - dump history as CSV

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"

const _DEFAULT_ITER := 1000
const _MAX_ITER := 1_000_000

var _registry: Node
var _core: Node

# name -> start usec
var _active_regions: Dictionary = {}
# selector ("path.signal") -> { node, signal, callable, arg_count, count, total_us, min_us, max_us, last_us, started_us }
var _active_signals: Dictionary = {}
# completed measurements for CSV export
# each: { timestamp_unix, kind, target, iterations, total_us, avg_us, min_us, max_us }
var _history: Array = []

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("time_method", _cmd_time_method, "Time a method via callv: time_method <path>.<method> [iter]", "both")
	_registry.register_command("time_expr", _cmd_time_expr, "Time an Expression eval: time_expr <expr> [iter]", "both")
	_registry.register_command("time_signal", _cmd_time_signal, "Toggle handler-latency timing on a signal: time_signal <path>.<signal>", "both")
	_registry.register_command("time_record", _cmd_time_record, "Start a named timing region: time_record <name>", "both")
	_registry.register_command("time_record_stop", _cmd_time_record_stop, "Stop and report a named region: time_record_stop <name>", "both")
	_registry.register_command("time_list", _cmd_time_list, "List active named regions and signal timers", "both")
	_registry.register_command("time_export", _cmd_time_export, "Dump completed measurements as CSV: time_export <res://path.csv>", "both")

#region Command implementations

func _cmd_time_method(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: time_method <path>.<method> [iter] [args...]")
	var selector := str(args[0]).strip_edges()
	var split := _split_selector(selector)
	if split.is_empty():
		return _format_error("Selector must be <path>.<method>: %s" % selector)

	var node := _resolve_node(split[0])
	if not node:
		return _format_error("Node not found: %s" % split[0])
	var method: String = split[1]
	if not node.has_method(method):
		return _format_error("Method not found: %s on %s" % [method, node.get_class()])

	var iter_count: int = _DEFAULT_ITER
	var call_args: Array = []
	if args.size() > 1:
		var second := str(args[1]).strip_edges()
		if second.is_valid_int():
			iter_count = second.to_int()
			for i in range(2, args.size()):
				call_args.append(_parse_value(str(args[i])))
		else:
			for i in range(1, args.size()):
				call_args.append(_parse_value(str(args[i])))
	if iter_count <= 0:
		return _format_error("iter must be > 0")
	if iter_count > _MAX_ITER:
		return _format_error("iter capped at %d" % _MAX_ITER)

	var min_us: int = 0x7FFFFFFFFFFFFFFF
	var max_us: int = 0
	var total_us: int = 0
	for i in range(iter_count):
		var t0: int = Time.get_ticks_usec()
		node.callv(method, call_args)
		var dt: int = Time.get_ticks_usec() - t0
		total_us += dt
		if dt < min_us:
			min_us = dt
		if dt > max_us:
			max_us = dt
	var avg_us: float = float(total_us) / float(iter_count)

	_record_history("method", "%s.%s" % [split[0], method], iter_count, total_us, avg_us, min_us, max_us)
	return _format_stats("time_method %s" % _color_path("%s.%s" % [split[0], method]), iter_count, total_us, avg_us, min_us, max_us)

func _cmd_time_expr(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: time_expr <expr> [iter]   (wrap multi-word expr in quotes)")

	var iter_count: int = _DEFAULT_ITER
	var expr_text: String = ""
	# If the last arg is an int, treat it as iter. Otherwise join all args as the expression.
	var last := str(args[args.size() - 1]).strip_edges()
	if args.size() >= 2 and last.is_valid_int():
		iter_count = last.to_int()
		var parts: Array[String] = []
		for i in range(args.size() - 1):
			parts.append(str(args[i]))
		expr_text = " ".join(parts).strip_edges()
	else:
		var parts2: Array[String] = []
		for a in args:
			parts2.append(str(a))
		expr_text = " ".join(parts2).strip_edges()
	if expr_text.is_empty():
		return _format_error("Expression is empty")
	if iter_count <= 0:
		return _format_error("iter must be > 0")
	if iter_count > _MAX_ITER:
		return _format_error("iter capped at %d" % _MAX_ITER)

	var expr := Expression.new()
	var parse_err: int = expr.parse(expr_text, [])
	if parse_err != OK:
		return _format_error("parse failed: %s" % expr.get_error_text())

	var base_instance: Object = _get_scene_root()
	var min_us: int = 0x7FFFFFFFFFFFFFFF
	var max_us: int = 0
	var total_us: int = 0
	for i in range(iter_count):
		var t0: int = Time.get_ticks_usec()
		var _r: Variant = expr.execute([], base_instance, false)
		var dt: int = Time.get_ticks_usec() - t0
		if expr.has_execute_failed():
			return _format_error("execute failed at iter %d: %s" % [i, expr.get_error_text()])
		total_us += dt
		if dt < min_us:
			min_us = dt
		if dt > max_us:
			max_us = dt
	var avg_us: float = float(total_us) / float(iter_count)

	_record_history("expr", expr_text, iter_count, total_us, avg_us, min_us, max_us)
	return _format_stats("time_expr %s" % _color_path(expr_text), iter_count, total_us, avg_us, min_us, max_us)

func _cmd_time_signal(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: time_signal <path>.<signal>   (run again to stop and report)")
	var selector := str(args[0]).strip_edges()
	var split := _split_selector(selector)
	if split.is_empty():
		return _format_error("Selector must be <path>.<signal>: %s" % selector)

	var node := _resolve_node(split[0])
	if not node:
		return _format_error("Node not found: %s" % split[0])
	var sig: String = split[1]
	if not node.has_signal(sig):
		return _format_error("Signal not found: %s on %s" % [sig, node.get_class()])

	# Toggle: if already tracking, stop & report.
	if _active_signals.has(selector):
		return _stop_signal_timer(selector)

	# Determine arg count to construct a Callable that swallows signal args.
	var arg_count: int = 0
	for s_info in node.get_signal_list():
		if str(s_info.get("name", "")) == sig:
			arg_count = (s_info.get("args", []) as Array).size()
			break

	var cb := Callable(self, "_on_timed_signal").bind(selector)
	if arg_count > 0:
		cb = cb.unbind(arg_count)

	var err: int = node.connect(sig, cb)
	if err != OK:
		return _format_error("connect() returned error %d" % err)

	_active_signals[selector] = {
		"node": node,
		"signal": sig,
		"callable": cb,
		"arg_count": arg_count,
		"count": 0,
		"total_us": 0,
		"min_us": 0x7FFFFFFFFFFFFFFF,
		"max_us": 0,
		"last_us": 0,
		"started_us": Time.get_ticks_usec(),
	}
	return _format_success("Timing %s.%s - run `time_signal %s` again to stop & report" % [_color_path(split[0]), sig, selector])

func _cmd_time_record(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: time_record <name>")
	var rname := " ".join(args).strip_edges()
	if rname.is_empty():
		return _format_error("Region name is required")
	if _active_regions.has(rname):
		return _format_error("Region already active: %s" % rname)
	_active_regions[rname] = Time.get_ticks_usec()
	return _format_success("Started region %s" % _color_path(rname))

func _cmd_time_record_stop(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: time_record_stop <name>")
	var rname := " ".join(args).strip_edges()
	if not _active_regions.has(rname):
		return _format_error("No active region: %s" % rname)
	var start_us: int = int(_active_regions[rname])
	var total_us: int = Time.get_ticks_usec() - start_us
	_active_regions.erase(rname)

	_record_history("region", rname, 1, total_us, float(total_us), total_us, total_us)
	return "%s elapsed %s (%s ms)" % [
		_color_path("region %s" % rname),
		_color_number("%d us" % total_us),
		_color_number("%.3f" % (float(total_us) / 1000.0)),
	]

func _cmd_time_list(_args: Array, _piped_input: String = "") -> String:
	var lines: Array[String] = []
	lines.append("[color=%s]Active named regions: %d[/color]" % [_COLOR_PATH, _active_regions.size()])
	if _active_regions.is_empty():
		lines.append("  (none)")
	else:
		var now: int = Time.get_ticks_usec()
		var names: Array = _active_regions.keys()
		names.sort()
		for n in names:
			var elapsed: int = now - int(_active_regions[n])
			lines.append("  %-32s %s us (%.3f ms)" % [str(n), _color_number(str(elapsed)), float(elapsed) / 1000.0])
	lines.append("[color=%s]Active signal timers: %d[/color]" % [_COLOR_PATH, _active_signals.size()])
	if _active_signals.is_empty():
		lines.append("  (none)")
	else:
		var keys: Array = _active_signals.keys()
		keys.sort()
		for k in keys:
			var d: Dictionary = _active_signals[k]
			lines.append("  %-40s emissions=%s total=%s us" % [
				str(k),
				_color_number(str(int(d.get("count", 0)))),
				_color_number(str(int(d.get("total_us", 0)))),
			])
	lines.append("[color=%s]Completed history: %d entries (use time_export to save)[/color]" % [_COLOR_PATH, _history.size()])
	return "\n".join(lines)

func _cmd_time_export(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: time_export <res://path.csv>")
	var path := str(args[0]).strip_edges()
	if path.is_empty():
		return _format_error("Path is empty")
	if _history.is_empty():
		return _format_error("No completed measurements to export")

	var file := FileAccess.open(path, FileAccess.WRITE)
	if not file:
		return _format_error("Cannot open for write: %s (err %d)" % [path, FileAccess.get_open_error()])

	file.store_line("timestamp_unix,kind,target,iterations,total_us,avg_us,min_us,max_us")
	for entry in _history:
		var d: Dictionary = entry
		file.store_line("%d,%s,%s,%d,%d,%.3f,%d,%d" % [
			int(d.get("timestamp_unix", 0)),
			_csv_escape(str(d.get("kind", ""))),
			_csv_escape(str(d.get("target", ""))),
			int(d.get("iterations", 0)),
			int(d.get("total_us", 0)),
			float(d.get("avg_us", 0.0)),
			int(d.get("min_us", 0)),
			int(d.get("max_us", 0)),
		])
	file.close()
	return _format_success("Exported %s rows to %s" % [_color_number(str(_history.size())), _color_path(path)])

#endregion

#region Signal-timer internals

func _on_timed_signal(key: String) -> void:
	if not _active_signals.has(key):
		return
	var d: Dictionary = _active_signals[key]
	var now: int = Time.get_ticks_usec()
	var last: int = int(d.get("last_us", 0))
	# Skip the very first invocation's dt - there is no prior emission to diff against.
	if last > 0:
		var dt: int = now - last
		d["count"] = int(d.get("count", 0)) + 1
		d["total_us"] = int(d.get("total_us", 0)) + dt
		if dt < int(d.get("min_us", 0x7FFFFFFFFFFFFFFF)):
			d["min_us"] = dt
		if dt > int(d.get("max_us", 0)):
			d["max_us"] = dt
	d["last_us"] = now
	_active_signals[key] = d

func _stop_signal_timer(key: String) -> String:
	var d: Dictionary = _active_signals[key]
	var node: Node = d.get("node")
	var sig: String = str(d.get("signal", ""))
	var cb: Callable = d.get("callable")
	if is_instance_valid(node) and node.is_connected(sig, cb):
		node.disconnect(sig, cb)
	_active_signals.erase(key)

	var count: int = int(d.get("count", 0))
	var total_us: int = int(d.get("total_us", 0))
	var min_us: int = int(d.get("min_us", 0))
	var max_us: int = int(d.get("max_us", 0))
	if count <= 0:
		return _format_error("Stopped %s - no inter-emission samples captured" % key)
	var avg_us: float = float(total_us) / float(count)
	_record_history("signal", key, count, total_us, avg_us, min_us, max_us)
	return _format_stats("time_signal %s (inter-emission)" % _color_path(key), count, total_us, avg_us, min_us, max_us)

#endregion

#region History + formatting

func _record_history(kind: String, target: String, iter_count: int, total_us: int, avg_us: float, min_us: int, max_us: int) -> void:
	_history.append({
		"timestamp_unix": int(Time.get_unix_time_from_system()),
		"kind": kind,
		"target": target,
		"iterations": iter_count,
		"total_us": total_us,
		"avg_us": avg_us,
		"min_us": min_us,
		"max_us": max_us,
	})

func _format_stats(header: String, iter_count: int, total_us: int, avg_us: float, min_us: int, max_us: int) -> String:
	return "%s\n  iter=%s  total=%s us  avg=%s us  min=%s us  max=%s us" % [
		header,
		_color_number(str(iter_count)),
		_color_number(str(total_us)),
		_color_number("%.3f" % avg_us),
		_color_number(str(min_us)),
		_color_number(str(max_us)),
	]

func _csv_escape(s: String) -> String:
	if s.contains(",") or s.contains("\"") or s.contains("\n"):
		return "\"%s\"" % s.replace("\"", "\"\"")
	return s

#endregion

#region Helpers (mirror SceneCommands.gd so this extension is self-contained)

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

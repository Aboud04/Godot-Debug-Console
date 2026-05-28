@tool
class_name DebugConsoleFlameGraphCommands extends RefCounted

# Text-art flame graph extension. Renders profile recordings or CSV-imported
# call trees as ASCII bar charts in the console. Each frame becomes a horizontal
# bar whose width is proportional to its share of the total recording time;
# rows are indented by call depth and tinted with a rotating palette so the
# depth structure is visually obvious.
#
# Two data sources are supported:
#   1. Recordings imported from CSV via flame_from_csv. The CSV must have
#      columns (ts, name, dur_us, depth). A header row is optional and the
#      column order can be reshuffled if a header is present.
#   2. Recordings created by the sibling ProfileCommands module (the simple
#      start/stop timers). Those have no call hierarchy, so they render as a
#      single root-depth bar - still useful for comparing wall-clock chunks.
#
# All durations are stored in microseconds (matching ProfileCommands) and
# reported in milliseconds with three decimals.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_HEADER := "#E0C0FF"

# Rotating palette indexed by call depth. Designed for dark consoles.
const _DEPTH_PALETTE: Array = [
	"#FF6B6B", "#F7B731", "#FED330", "#26DE81",
	"#2BCBBA", "#45AAF2", "#A55EEA", "#FD79A8",
]

const _BAR_WIDTH: int = 60
const _BAR_FULL := "█"
# Eighth-block partials for sub-cell resolution on the right edge.
const _BAR_PARTIAL: Array = ["", "▏", "▎", "▍", "▌", "▋", "▊", "▉"]
const _BAR_TINY := "·"

var _registry: Node
var _core: Node

# recording_name -> {
#   "frames":    Array[Dictionary],  # each {ts, name, dur_us, depth}
#   "total_us":  int,
#   "loaded_at": float,               # unix time
#   "source":    String,              # "csv:<path>" or "profile:<name>"
# }
var _recordings: Dictionary = {}
var _last_recording: String = ""

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("flame", _cmd_flame, "Render flame graph: flame [recording_name]", "both")
	_registry.register_command("flame_from_csv", _cmd_flame_from_csv, "Load flame data from CSV (ts,name,dur_us,depth): flame_from_csv <user://path.csv>", "both")
	_registry.register_command("flame_top", _cmd_flame_top, "Top N self-time methods: flame_top [n]", "both")
	_registry.register_command("flame_inverted", _cmd_flame_inverted, "Bottom-up flame graph view: flame_inverted [recording_name]", "both")
	_registry.register_command("flame_save", _cmd_flame_save, "Save flame graph as plain text: flame_save <user://path.txt>", "both")

#region Command implementations

func _cmd_flame(args: Array, piped_input: String = "") -> String:
	var name := _resolve_recording_name(args)
	if name.is_empty():
		return _no_recording_error()
	var rec: Dictionary = _recordings[name]
	return _render_flame(name, rec, false)

func _cmd_flame_from_csv(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: flame_from_csv <user://path.csv>")
	var path := _join_args(args, 0)
	if path.is_empty():
		return _format_error("CSV path required")
	if not (path.begins_with("res://") or path.begins_with("user://")):
		return _format_error("Path must start with res:// or user://: %s" % path)
	if not FileAccess.file_exists(path):
		return _format_error("File not found: %s" % path)

	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		return _format_error("Could not open %s (err %d)" % [path, FileAccess.get_open_error()])

	var col_ts: int = 0
	var col_name: int = 1
	var col_dur: int = 2
	var col_depth: int = 3
	var header_consumed: bool = false
	var frames: Array = []
	var skipped: int = 0
	var line_no: int = 0

	while not file.eof_reached():
		var line := file.get_line().strip_edges()
		line_no += 1
		if line.is_empty() or line.begins_with("#"):
			continue
		var parts: PackedStringArray = line.split(",")
		if parts.size() < 4:
			skipped += 1
			continue
		if not header_consumed:
			header_consumed = true
			var first_lower := parts[0].strip_edges().to_lower()
			# Detect header by looking for a textual ts/timestamp marker.
			if first_lower == "ts" or first_lower == "timestamp" or first_lower == "time":
				for i in parts.size():
					var h := parts[i].strip_edges().to_lower()
					match h:
						"ts", "timestamp", "time":
							col_ts = i
						"name", "method", "op", "func":
							col_name = i
						"dur_us", "duration_us", "dur", "us":
							col_dur = i
						"depth", "level", "stack":
							col_depth = i
				continue
		var max_col: int = maxi(maxi(col_ts, col_name), maxi(col_dur, col_depth))
		if parts.size() <= max_col:
			skipped += 1
			continue
		var dur_str := parts[col_dur].strip_edges()
		var depth_str := parts[col_depth].strip_edges()
		if not dur_str.is_valid_int() or not depth_str.is_valid_int():
			skipped += 1
			continue
		var ts_str := parts[col_ts].strip_edges()
		var nm_str := parts[col_name].strip_edges()
		if nm_str.length() >= 2 and nm_str.begins_with("\"") and nm_str.ends_with("\""):
			nm_str = nm_str.substr(1, nm_str.length() - 2)
		if nm_str.is_empty():
			nm_str = "<unnamed>"
		var ts_val: int = 0
		if ts_str.is_valid_int():
			ts_val = ts_str.to_int()
		var depth_val: int = depth_str.to_int()
		if depth_val < 0:
			depth_val = 0
		frames.append({
			"ts": ts_val,
			"name": nm_str,
			"dur_us": dur_str.to_int(),
			"depth": depth_val,
		})

	file.close()

	if frames.is_empty():
		return _format_error("No valid rows parsed from %s (skipped %d)" % [path, skipped])

	var total_us: int = _compute_total_us(frames)
	var rec_name := path.get_file().get_basename()
	if rec_name.is_empty():
		rec_name = "csv_%d" % Time.get_ticks_msec()
	_recordings[rec_name] = {
		"frames": frames,
		"total_us": total_us,
		"loaded_at": Time.get_unix_time_from_system(),
		"source": "csv:%s" % path,
	}
	_last_recording = rec_name

	return "%s loaded %s frames from %s as %s (total %s ms, skipped %s)" % [
		_format_success("flame_from_csv"),
		_color_number(str(frames.size())),
		_color_path(path),
		_color_path(rec_name),
		_color_number("%.3f" % (float(total_us) / 1000.0)),
		_color_number(str(skipped)),
	]

func _cmd_flame_top(args: Array, piped_input: String = "") -> String:
	var n: int = 10
	if not args.is_empty():
		var s := str(args[0]).strip_edges()
		if s.is_valid_int():
			n = maxi(1, s.to_int())
	var name: String = _last_recording
	if name.is_empty() or not _recordings.has(name):
		# Try to pick up the most recent ProfileCommands recording on demand.
		name = _try_import_latest_profile()
		if name.is_empty():
			return _no_recording_error()

	var rec: Dictionary = _recordings[name]
	var frames: Array = rec.get("frames", [])
	if frames.is_empty():
		return _format_error("Recording '%s' has no frames" % name)
	var total_us: int = int(rec.get("total_us", 0))
	var self_map: Dictionary = _compute_self_times(frames)

	var entries: Array = []
	for k in self_map.keys():
		entries.append([str(k), int(self_map[k])])
	entries.sort_custom(func(a, b): return int(a[1]) > int(b[1]))

	var lines: Array[String] = []
	lines.append("%s top %s self-time methods in %s" % [
		_format_success("flame_top"),
		_color_number(str(n)),
		_color_path(name),
	])
	var shown: int = mini(n, entries.size())
	if shown == 0:
		lines.append("  (no entries)")
		return "\n".join(lines)
	var top_us: int = int((entries[0] as Array)[1])
	var scale_us: int = top_us if top_us > 0 else 1
	for i in shown:
		var e: Array = entries[i]
		var nm: String = e[0]
		var us: int = e[1]
		var pct_of_total: float = 0.0
		if total_us > 0:
			pct_of_total = (float(us) / float(total_us)) * 100.0
		var bar := _make_bar(us, scale_us)
		var col := _depth_color(i)
		lines.append("  %2d. [color=%s]%s[/color] %s %s ms (%s%% of total)" % [
			i + 1,
			col,
			bar,
			_color_path(nm),
			_color_number("%.3f" % (float(us) / 1000.0)),
			_color_number("%.1f" % pct_of_total),
		])
	return "\n".join(lines)

func _cmd_flame_inverted(args: Array, piped_input: String = "") -> String:
	var name := _resolve_recording_name(args)
	if name.is_empty():
		return _no_recording_error()
	var rec: Dictionary = _recordings[name]
	return _render_flame(name, rec, true)

func _cmd_flame_save(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: flame_save <user://path.txt>")
	var path := _join_args(args, 0)
	if path.is_empty():
		return _format_error("Output path required")
	if not (path.begins_with("res://") or path.begins_with("user://")):
		return _format_error("Path must start with res:// or user://: %s" % path)

	var name: String = _last_recording
	if name.is_empty() or not _recordings.has(name):
		name = _try_import_latest_profile()
		if name.is_empty():
			return _no_recording_error()

	var rendered := _render_flame(name, _recordings[name], false)
	var plain := _strip_bbcode(rendered)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if not file:
		return _format_error("Could not open %s for writing (err %d)" % [path, FileAccess.get_open_error()])
	file.store_string(plain)
	file.close()
	return "%s wrote %s bytes to %s (recording %s)" % [
		_format_success("flame_save"),
		_color_number(str(plain.length())),
		_color_path(path),
		_color_path(name),
	]

#endregion

#region Rendering

func _render_flame(name: String, rec: Dictionary, inverted: bool) -> String:
	var frames: Array = rec.get("frames", [])
	var total_us: int = int(rec.get("total_us", 0))
	if frames.is_empty():
		return _format_error("Recording '%s' has no frames" % name)
	if total_us <= 0:
		total_us = _compute_total_us(frames)
	if total_us <= 0:
		return _format_error("Recording '%s' has zero total duration" % name)

	var max_depth: int = 0
	for f in frames:
		var d: int = int((f as Dictionary).get("depth", 0))
		if d > max_depth:
			max_depth = d

	var label := "flame_inverted" if inverted else "flame"
	var lines: Array[String] = []
	lines.append("%s %s [color=%s](source: %s)[/color]" % [
		_format_success(label),
		_color_path(name),
		_COLOR_HEADER,
		str(rec.get("source", "?")),
	])
	lines.append("  total: %s ms  frames: %s  max_depth: %s  bar_width: %s" % [
		_color_number("%.3f" % (float(total_us) / 1000.0)),
		_color_number(str(frames.size())),
		_color_number(str(max_depth)),
		_color_number(str(_BAR_WIDTH)),
	])
	lines.append("")

	var ordered: Array = frames
	if inverted:
		# Bottom-up: flip depth so the deepest leaves become the top row, and
		# reverse the array so the visual stacking still keeps adjacent calls
		# next to each other.
		var inv: Array = []
		for f in frames:
			var src: Dictionary = f
			var clone: Dictionary = src.duplicate()
			clone["depth"] = max_depth - int(src.get("depth", 0))
			inv.append(clone)
		inv.reverse()
		ordered = inv

	for f in ordered:
		var fd: Dictionary = f
		var nm: String = str(fd.get("name", "?"))
		var dur: int = int(fd.get("dur_us", 0))
		var depth: int = int(fd.get("depth", 0))
		var pct: float = (float(dur) / float(total_us)) * 100.0
		var bar := _make_bar(dur, total_us)
		var col := _depth_color(depth)
		var indent := "  ".repeat(depth)
		lines.append("%s[color=%s]%s[/color] %s %s ms (%s%%) d=%s" % [
			indent,
			col,
			bar,
			_color_path(nm),
			_color_number("%.3f" % (float(dur) / 1000.0)),
			_color_number("%.1f" % pct),
			_color_number(str(depth)),
		])
	return "\n".join(lines)

func _make_bar(dur: int, total: int) -> String:
	if total <= 0 or dur <= 0:
		return _BAR_TINY
	var eighths: int = int(round((float(dur) / float(total)) * float(_BAR_WIDTH * 8)))
	if eighths <= 0:
		return _BAR_TINY
	var full: int = eighths / 8
	var rem: int = eighths % 8
	var out := _BAR_FULL.repeat(full)
	if rem > 0:
		out += _BAR_PARTIAL[rem]
	if out.is_empty():
		out = _BAR_TINY
	return out

func _depth_color(depth: int) -> String:
	var idx: int = depth % _DEPTH_PALETTE.size()
	if idx < 0:
		idx += _DEPTH_PALETTE.size()
	return str(_DEPTH_PALETTE[idx])

#endregion

#region Analysis helpers

func _compute_total_us(frames: Array) -> int:
	# Total is the sum of root-depth (depth==0) durations. Falls back to the
	# single largest frame if no depth-0 frames exist (CSV may start deeper).
	var total: int = 0
	for f in frames:
		if int((f as Dictionary).get("depth", 0)) == 0:
			total += int((f as Dictionary).get("dur_us", 0))
	if total > 0:
		return total
	var min_depth: int = 0x7FFFFFFF
	for f in frames:
		var d: int = int((f as Dictionary).get("depth", 0))
		if d < min_depth:
			min_depth = d
	for f in frames:
		if int((f as Dictionary).get("depth", 0)) == min_depth:
			total += int((f as Dictionary).get("dur_us", 0))
	if total > 0:
		return total
	# Last resort: largest single duration.
	for f in frames:
		var d2: int = int((f as Dictionary).get("dur_us", 0))
		if d2 > total:
			total = d2
	return total

func _compute_self_times(frames: Array) -> Dictionary:
	# Self time = own duration minus the sum of immediate children's durations.
	# Children of frame i are the longest run of subsequent frames whose depth
	# is strictly greater than frame i's depth, terminated by a frame with
	# depth <= frame i's depth. Immediate children have depth == di + 1.
	var by_name: Dictionary = {}
	var n: int = frames.size()
	for i in n:
		var fi: Dictionary = frames[i]
		var di: int = int(fi.get("depth", 0))
		var dur: int = int(fi.get("dur_us", 0))
		var children_us: int = 0
		var j: int = i + 1
		while j < n:
			var fj: Dictionary = frames[j]
			var dj: int = int(fj.get("depth", 0))
			if dj <= di:
				break
			if dj == di + 1:
				children_us += int(fj.get("dur_us", 0))
			j += 1
		var self_us: int = dur - children_us
		if self_us < 0:
			self_us = 0
		var nm: String = str(fi.get("name", "?"))
		by_name[nm] = int(by_name.get(nm, 0)) + self_us
	return by_name

func _resolve_recording_name(args: Array) -> String:
	var requested := _join_args(args, 0).strip_edges()
	if not requested.is_empty():
		if _recordings.has(requested):
			_last_recording = requested
			return requested
		# Try to import a ProfileCommands recording by that name on demand.
		var imported := _try_import_profile_recording(requested)
		if not imported.is_empty():
			return imported
		return ""
	if not _last_recording.is_empty() and _recordings.has(_last_recording):
		return _last_recording
	# Nothing imported yet - fall back to the most recent profile recording.
	return _try_import_latest_profile()

func _no_recording_error() -> String:
	var avail: Array = _list_recording_names()
	if avail.is_empty():
		return _format_error("No recordings loaded. Use flame_from_csv <user://path.csv> or record one with profile_record_start/stop first.")
	return _format_error("No recording specified. Available: %s" % ", ".join(avail))

func _list_recording_names() -> Array:
	var out: Array = []
	var keys: Array = _recordings.keys()
	keys.sort()
	for k in keys:
		out.append(str(k))
	return out

#endregion

#region ProfileCommands bridge

func _get_profile_module() -> Object:
	# The orchestrator keeps a strong reference to every extension module in a
	# keepalive array on _core. We look for an entry that quacks like
	# ProfileCommands (has a _recordings Dictionary and the profile_record_start
	# command implementation). This is best-effort: if the keepalive array is
	# absent or named differently, we silently report no module.
	if not _core:
		return null
	var candidates: Array = []
	var keepalive: Variant = _core.get("_t6_keepalive")
	if keepalive is Array:
		candidates.append_array(keepalive as Array)
	var alt: Variant = _core.get("_extension_modules")
	if alt is Array:
		candidates.append_array(alt as Array)
	for c in candidates:
		if c == null:
			continue
		if not (c is Object):
			continue
		var obj: Object = c
		if not obj.has_method("_cmd_profile_record_start"):
			continue
		var recs: Variant = obj.get("_recordings")
		if recs is Dictionary:
			return obj
	return null

func _try_import_profile_recording(name: String) -> String:
	var mod := _get_profile_module()
	if not mod:
		return ""
	var recs: Variant = mod.get("_recordings")
	if not (recs is Dictionary):
		return ""
	var profile_recs: Dictionary = recs
	if not profile_recs.has(name):
		return ""
	_import_profile_entry(name, profile_recs[name])
	return name

func _try_import_latest_profile() -> String:
	var mod := _get_profile_module()
	if not mod:
		return ""
	var recs: Variant = mod.get("_recordings")
	if not (recs is Dictionary):
		return ""
	var profile_recs: Dictionary = recs
	if profile_recs.is_empty():
		return ""
	# Pick the recording with the largest start_usec (most recent).
	var best_name := ""
	var best_start: int = -1
	for k in profile_recs.keys():
		var rec: Dictionary = profile_recs[k]
		var s: int = int(rec.get("start_usec", 0))
		if s > best_start:
			best_start = s
			best_name = str(k)
	if best_name.is_empty():
		return ""
	_import_profile_entry(best_name, profile_recs[best_name])
	return best_name

func _import_profile_entry(name: String, rec: Dictionary) -> void:
	var stop_us: int = int(rec.get("stop_usec", 0))
	var start_us: int = int(rec.get("start_usec", 0))
	var dur_us: int = int(rec.get("duration_usec", 0))
	if dur_us <= 0 and stop_us > 0 and start_us > 0:
		dur_us = stop_us - start_us
	if dur_us <= 0:
		dur_us = max(1, Time.get_ticks_usec() - start_us)
	var frames: Array = [{
		"ts": start_us,
		"name": name,
		"dur_us": dur_us,
		"depth": 0,
	}]
	_recordings[name] = {
		"frames": frames,
		"total_us": dur_us,
		"loaded_at": Time.get_unix_time_from_system(),
		"source": "profile:%s" % name,
	}
	_last_recording = name

#endregion

#region Generic helpers

func _strip_bbcode(s: String) -> String:
	var rx := RegEx.new()
	# Drop anything that looks like a BBCode tag: [color=...] [/color] [b] [/b] etc.
	var err := rx.compile("\\[/?[A-Za-z][^\\]]*\\]")
	if err != OK:
		return s
	return rx.sub(s, "", true)

func _join_args(args: Array, start: int) -> String:
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

#endregion

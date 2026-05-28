@tool
class_name DebugConsoleUnitConvertCommands extends RefCounted

# Unit-conversion commands common in game-dev: pixels, time, angles, and sizes.
# Mirrors the SceneCommands.gd / ClipboardCommands.gd pattern - the orchestrator
# instantiates one of these, holds a strong reference, and calls
# register_commands(registry, core). The strong reference is what keeps the
# Callables registered with the console alive for the lifetime of the plugin.
#
# All commands run in "both" context. These are pure-math conversions; they
# never touch the scene tree, the filesystem, or the network, so the `_core`
# reference is accepted for symmetry with sibling extensions but is unused.
#
# The generic `convert` command resolves units through a single table keyed by
# family (bytes, time, angle, length). Cross-family conversions are rejected
# with a clear error so a typo cannot silently produce a meaningless number.

const _COLOR_ERROR := "#FF4444"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_MUTED := "#888888"
const _COLOR_LABEL := "#5FBEE0"

const _DEFAULT_EM_BASE := 16.0
const _DEFAULT_FPS := 60.0
# CSS reference values: 1in = 96px, derived for cm/mm/pt accordingly.
const _PX_PER_IN := 96.0
const _PX_PER_CM := 96.0 / 2.54
const _PX_PER_MM := 96.0 / 25.4
const _PX_PER_PT := 96.0 / 72.0

# Common named aspect ratios. Keys are simplified "w:h", values are labels.
const _NAMED_ASPECTS := {
	"16:9": "Widescreen HD",
	"4:3": "Standard / Classic",
	"21:9": "Ultrawide",
	"32:9": "Super Ultrawide",
	"5:4": "SXGA",
	"3:2": "Photography / DSLR",
	"16:10": "Golden / WUXGA",
	"1:1": "Square",
	"9:16": "Portrait HD",
	"9:21": "Portrait Ultrawide",
	"9:19": "Modern phone",
	"2:1": "Univisium / Modern cinematic",
	"17:9": "DCI 2K/4K",
}

var _registry: Node
var _core: Node

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("convert", _cmd_convert, "Convert between common units: convert <value> <from> <to>  e.g. convert 1024 KB MB  (families: bytes, time, angle, length)", "both")
	_registry.register_command("px_to_em", _cmd_px_to_em, "Pixels -> em: px_to_em <pixels> [base_em=16]", "both")
	_registry.register_command("em_to_px", _cmd_em_to_px, "em -> pixels: em_to_px <em> [base_em=16]", "both")
	_registry.register_command("ms_to_frames", _cmd_ms_to_frames, "Milliseconds -> frames: ms_to_frames <ms> [fps=60]", "both")
	_registry.register_command("frames_to_ms", _cmd_frames_to_ms, "Frames -> milliseconds: frames_to_ms <frames> [fps=60]", "both")
	_registry.register_command("deg", _cmd_deg, "Radians -> degrees: deg <radians>", "both")
	_registry.register_command("rad", _cmd_rad, "Degrees -> radians: rad <degrees>", "both")
	_registry.register_command("bytes", _cmd_bytes, "Bytes -> KB/MB/GB/TB shorthand: bytes <value> <KB|MB|GB|TB>", "both")
	_registry.register_command("aspect", _cmd_aspect, "Simplify + name an aspect ratio: aspect <w> <h>", "both")

#region Command implementations

func _cmd_convert(args: Array, _piped_input: String = "") -> String:
	if args.size() < 3:
		return _format_error("Usage: convert <value> <from> <to>  e.g. convert 1024 KB MB")
	var value_ok := _parse_float(args[0])
	if not value_ok["ok"]:
		return _format_error("Value is not a number: %s" % str(args[0]))
	var value: float = value_ok["value"]
	var from_raw := str(args[1]).strip_edges()
	var to_raw := str(args[2]).strip_edges()

	var from_info := _lookup_unit(from_raw)
	if from_info.is_empty():
		return _format_error("Unknown source unit: %s. Known: %s" % [from_raw, _known_units_summary()])
	var to_info := _lookup_unit(to_raw)
	if to_info.is_empty():
		return _format_error("Unknown target unit: %s. Known: %s" % [to_raw, _known_units_summary()])
	if from_info["family"] != to_info["family"]:
		return _format_error("Cannot convert across families: %s (%s) -> %s (%s)" % [from_raw, from_info["family"], to_raw, to_info["family"]])

	var as_base: float = value * float(from_info["to_base"])
	var result: float = as_base / float(to_info["to_base"])
	return "%s %s = %s %s  %s" % [
		_color_number(_format_number(value)),
		_color_label(String(from_info["canonical"])),
		_color_number(_format_number(result)),
		_color_label(String(to_info["canonical"])),
		_color_muted("(family: %s)" % String(from_info["family"])),
	]

func _cmd_px_to_em(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: px_to_em <pixels> [base_em=16]")
	var px_ok := _parse_float(args[0])
	if not px_ok["ok"]:
		return _format_error("Pixels is not a number: %s" % str(args[0]))
	var base: float = _DEFAULT_EM_BASE
	if args.size() > 1:
		var base_ok := _parse_float(args[1])
		if not base_ok["ok"] or float(base_ok["value"]) <= 0.0:
			return _format_error("base_em must be a positive number: %s" % str(args[1]))
		base = base_ok["value"]
	var em: float = float(px_ok["value"]) / base
	return "%s px = %s em  %s" % [
		_color_number(_format_number(px_ok["value"])),
		_color_number(_format_number(em)),
		_color_muted("(base %s px)" % _format_number(base)),
	]

func _cmd_em_to_px(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: em_to_px <em> [base_em=16]")
	var em_ok := _parse_float(args[0])
	if not em_ok["ok"]:
		return _format_error("em is not a number: %s" % str(args[0]))
	var base: float = _DEFAULT_EM_BASE
	if args.size() > 1:
		var base_ok := _parse_float(args[1])
		if not base_ok["ok"] or float(base_ok["value"]) <= 0.0:
			return _format_error("base_em must be a positive number: %s" % str(args[1]))
		base = base_ok["value"]
	var px: float = float(em_ok["value"]) * base
	return "%s em = %s px  %s" % [
		_color_number(_format_number(em_ok["value"])),
		_color_number(_format_number(px)),
		_color_muted("(base %s px)" % _format_number(base)),
	]

func _cmd_ms_to_frames(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: ms_to_frames <ms> [fps=60]")
	var ms_ok := _parse_float(args[0])
	if not ms_ok["ok"]:
		return _format_error("ms is not a number: %s" % str(args[0]))
	var fps: float = _DEFAULT_FPS
	if args.size() > 1:
		var fps_ok := _parse_float(args[1])
		if not fps_ok["ok"] or float(fps_ok["value"]) <= 0.0:
			return _format_error("fps must be a positive number: %s" % str(args[1]))
		fps = fps_ok["value"]
	var frames: float = (float(ms_ok["value"]) / 1000.0) * fps
	return "%s ms = %s frames  %s" % [
		_color_number(_format_number(ms_ok["value"])),
		_color_number(_format_number(frames)),
		_color_muted("(@ %s fps)" % _format_number(fps)),
	]

func _cmd_frames_to_ms(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: frames_to_ms <frames> [fps=60]")
	var fr_ok := _parse_float(args[0])
	if not fr_ok["ok"]:
		return _format_error("frames is not a number: %s" % str(args[0]))
	var fps: float = _DEFAULT_FPS
	if args.size() > 1:
		var fps_ok := _parse_float(args[1])
		if not fps_ok["ok"] or float(fps_ok["value"]) <= 0.0:
			return _format_error("fps must be a positive number: %s" % str(args[1]))
		fps = fps_ok["value"]
	var ms: float = (float(fr_ok["value"]) / fps) * 1000.0
	return "%s frames = %s ms  %s" % [
		_color_number(_format_number(fr_ok["value"])),
		_color_number(_format_number(ms)),
		_color_muted("(@ %s fps)" % _format_number(fps)),
	]

func _cmd_deg(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: deg <radians>")
	var rad_ok := _parse_float(args[0])
	if not rad_ok["ok"]:
		return _format_error("radians is not a number: %s" % str(args[0]))
	var deg: float = rad_to_deg(float(rad_ok["value"]))
	return "%s rad = %s deg" % [
		_color_number(_format_number(rad_ok["value"])),
		_color_number(_format_number(deg)),
	]

func _cmd_rad(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: rad <degrees>")
	var deg_ok := _parse_float(args[0])
	if not deg_ok["ok"]:
		return _format_error("degrees is not a number: %s" % str(args[0]))
	var rad: float = deg_to_rad(float(deg_ok["value"]))
	return "%s deg = %s rad" % [
		_color_number(_format_number(deg_ok["value"])),
		_color_number(_format_number(rad)),
	]

func _cmd_bytes(args: Array, _piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: bytes <value> <KB|MB|GB|TB>")
	var val_ok := _parse_float(args[0])
	if not val_ok["ok"]:
		return _format_error("Value is not a number: %s" % str(args[0]))
	var target := str(args[1]).strip_edges().to_upper()
	if target == "B":
		return _format_error("Target must be one of KB, MB, GB, TB (got B - that's just the input value)")
	var info := _lookup_unit(target)
	if info.is_empty() or String(info["family"]) != "bytes":
		return _format_error("Target must be one of KB, MB, GB, TB (got %s)" % target)
	var result: float = float(val_ok["value"]) / float(info["to_base"])
	return "%s bytes = %s %s" % [
		_color_number(_format_number(val_ok["value"])),
		_color_number(_format_number(result)),
		_color_label(String(info["canonical"])),
	]

func _cmd_aspect(args: Array, _piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: aspect <w> <h>  e.g. aspect 1920 1080")
	var w_ok := _parse_float(args[0])
	var h_ok := _parse_float(args[1])
	if not w_ok["ok"] or not h_ok["ok"]:
		return _format_error("Width and height must be numbers")
	var w: float = w_ok["value"]
	var h: float = h_ok["value"]
	if w <= 0.0 or h <= 0.0:
		return _format_error("Width and height must be positive")

	var ratio: float = w / h
	# Integer inputs get a proper GCD-reduced ratio. Floats can't be reduced
	# cleanly, so fall back to a "ratio:1" form and lean on the closest-named
	# lookup to label common cinematic ratios like 2.39:1.
	var w_int: int = int(round(w))
	var h_int: int = int(round(h))
	var both_integer: bool = is_equal_approx(w, float(w_int)) and is_equal_approx(h, float(h_int))
	var simplified: String
	if both_integer and w_int > 0 and h_int > 0:
		var g: int = _gcd(w_int, h_int)
		simplified = "%d:%d" % [w_int / g, h_int / g]
	else:
		simplified = "%s:1" % _format_number(ratio)

	var label: String = ""
	if simplified in _NAMED_ASPECTS:
		label = "  %s" % _color_muted("- %s" % String(_NAMED_ASPECTS[simplified]))
	else:
		var closest := _closest_named_aspect(ratio)
		if not closest.is_empty():
			label = "  %s" % _color_muted("(closest named: %s - %s)" % [closest, String(_NAMED_ASPECTS[closest])])
	return "%s x %s -> %s  (%s:1)%s" % [
		_color_number(_format_number(w)),
		_color_number(_format_number(h)),
		_color_label(simplified),
		_color_number(_format_number(ratio)),
		label,
	]

#endregion
#region Internals

func _parse_float(v: Variant) -> Dictionary:
	var s := str(v).strip_edges()
	if s.is_empty():
		return {"ok": false, "value": 0.0}
	if not s.is_valid_float() and not s.is_valid_int():
		return {"ok": false, "value": 0.0}
	return {"ok": true, "value": s.to_float()}

func _lookup_unit(raw: String) -> Dictionary:
	var key := raw.strip_edges()
	if key.is_empty():
		return {}
	# Bytes are conventionally upper-case (KB/MB/GB), time/angle/length tokens
	# are conventionally lower-case (ms, deg, px). Try both forms.
	var table := _unit_table()
	if key in table:
		return table[key]
	var upper := key.to_upper()
	if upper in table:
		return table[upper]
	var lower := key.to_lower()
	if lower in table:
		return table[lower]
	return {}

func _unit_table() -> Dictionary:
	# Each entry: family + canonical display name + multiplier to family base.
	# Bytes base: byte (binary 1024 progression - the convention in game tooling).
	# Time base: second.
	# Angle base: degree.
	# Length base: pixel (CSS reference: 96px == 1in, em uses 16px default).
	var t: Dictionary = {}
	t["B"]  = {"family": "bytes", "canonical": "B",  "to_base": 1.0}
	t["KB"] = {"family": "bytes", "canonical": "KB", "to_base": 1024.0}
	t["MB"] = {"family": "bytes", "canonical": "MB", "to_base": 1024.0 * 1024.0}
	t["GB"] = {"family": "bytes", "canonical": "GB", "to_base": 1024.0 * 1024.0 * 1024.0}
	t["TB"] = {"family": "bytes", "canonical": "TB", "to_base": 1024.0 * 1024.0 * 1024.0 * 1024.0}

	t["ms"]     = {"family": "time", "canonical": "ms",    "to_base": 0.001}
	t["s"]      = {"family": "time", "canonical": "s",     "to_base": 1.0}
	t["sec"]    = {"family": "time", "canonical": "s",     "to_base": 1.0}
	t["min"]    = {"family": "time", "canonical": "min",   "to_base": 60.0}
	t["h"]      = {"family": "time", "canonical": "h",     "to_base": 3600.0}
	t["hr"]     = {"family": "time", "canonical": "h",     "to_base": 3600.0}
	t["frame"]  = {"family": "time", "canonical": "frame", "to_base": 1.0 / _DEFAULT_FPS}
	t["frames"] = {"family": "time", "canonical": "frame", "to_base": 1.0 / _DEFAULT_FPS}
	t["f"]      = {"family": "time", "canonical": "frame", "to_base": 1.0 / _DEFAULT_FPS}

	t["deg"]  = {"family": "angle", "canonical": "deg",  "to_base": 1.0}
	t["rad"]  = {"family": "angle", "canonical": "rad",  "to_base": 180.0 / PI}
	t["turn"] = {"family": "angle", "canonical": "turn", "to_base": 360.0}
	t["grad"] = {"family": "angle", "canonical": "grad", "to_base": 0.9}

	t["px"] = {"family": "length", "canonical": "px", "to_base": 1.0}
	t["em"] = {"family": "length", "canonical": "em", "to_base": _DEFAULT_EM_BASE}
	t["in"] = {"family": "length", "canonical": "in", "to_base": _PX_PER_IN}
	t["cm"] = {"family": "length", "canonical": "cm", "to_base": _PX_PER_CM}
	t["mm"] = {"family": "length", "canonical": "mm", "to_base": _PX_PER_MM}
	t["pt"] = {"family": "length", "canonical": "pt", "to_base": _PX_PER_PT}
	t["m"]  = {"family": "length", "canonical": "m",  "to_base": _PX_PER_CM * 100.0}
	return t

func _known_units_summary() -> String:
	return "bytes(B,KB,MB,GB,TB) time(ms,s,min,h,frames) angle(deg,rad,turn,grad) length(px,em,in,cm,mm,pt,m)"

func _gcd(a: int, b: int) -> int:
	var x: int = absi(a)
	var y: int = absi(b)
	while y != 0:
		var t: int = y
		y = x % y
		x = t
	return maxi(x, 1)

func _closest_named_aspect(ratio: float) -> String:
	if ratio <= 0.0:
		return ""
	var best_key: String = ""
	var best_diff: float = INF
	for key in _NAMED_ASPECTS.keys():
		var parts: PackedStringArray = String(key).split(":")
		if parts.size() != 2:
			continue
		var w: float = parts[0].to_float()
		var h: float = parts[1].to_float()
		if h == 0.0:
			continue
		var diff: float = absf(ratio - (w / h))
		if diff < best_diff:
			best_diff = diff
			best_key = key
	# Only label as "closest" if it's actually close. 0.08 absolute ratio diff
	# accepts e.g. 3440x1440 (~2.389) -> 21:9 (2.333), but rejects unrelated
	# ratios like 2:1 vs 16:9.
	if best_diff <= 0.08:
		return best_key
	return ""

func _format_number(n: float) -> String:
	if is_equal_approx(n, round(n)) and absf(n) < 1.0e15:
		return "%d" % int(n)
	var s: String = "%.6f" % n
	if "." in s:
		while s.ends_with("0"):
			s = s.substr(0, s.length() - 1)
		if s.ends_with("."):
			s = s.substr(0, s.length() - 1)
	return s

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

func _color_muted(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_MUTED, s]

func _color_label(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_LABEL, s]

#endregion

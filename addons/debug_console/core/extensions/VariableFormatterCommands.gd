@tool
class_name DebugConsoleVariableFormatterCommands extends RefCounted

# GDB-style format specifier commands for inspecting values in the debug
# console. Mirrors the SceneCommands.gd / DnsCommands.gd pattern: the
# orchestrator (BuiltInCommands.register_universal_commands) instantiates one
# of these, holds a strong reference to it, and calls
# register_commands(registry, core). All commands route through that
# strong-referenced instance so their Callables stay valid for the lifetime
# of the plugin.
#
# These commands are pure value formatters - they do not touch the scene
# tree, the filesystem, or any plugin state. They run in both editor and
# game context.
#
# Numeric input accepts decimal (255), hex (0xFF / FF), octal (0o377) and
# binary (0b11111111) forms, so any of the spec commands compose with the
# output of any other.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_MUTED := "#888888"

var _registry: Node
var _core: Node

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("fmt", _cmd_fmt, "Evaluate <expr> and format result with <spec> (x|o|b|d|f|s|c|p). e.g. fmt 255 x -> 0xFF", "both")
	_registry.register_command("fmt_hex", _cmd_fmt_hex, "Format integer as hex: fmt_hex <int>", "both")
	_registry.register_command("fmt_bin", _cmd_fmt_bin, "Format integer as binary: fmt_bin <int>", "both")
	_registry.register_command("fmt_oct", _cmd_fmt_oct, "Format integer as octal: fmt_oct <int>", "both")
	_registry.register_command("fmt_dec", _cmd_fmt_dec, "Parse a hex string to decimal: fmt_dec <hex_string>", "both")
	_registry.register_command("fmt_color", _cmd_fmt_color, "Render a Color preview swatch: fmt_color <r,g,b[,a]>  (0-1 or 0-255)", "both")
	_registry.register_command("fmt_vector", _cmd_fmt_vector, "Format a vector with magnitude + angle: fmt_vector <x,y[,z[,w]]>", "both")
	_registry.register_command("fmt_bytes", _cmd_fmt_bytes, "Hex-dump a byte array (16 cols, ascii sidebar): fmt_bytes <b1,b2,b3,...>", "both")
	_registry.register_command("fmt_size", _cmd_fmt_size, "Human-readable byte size (B/KiB/MiB/GiB): fmt_size <bytes>", "both")

#region Command implementations

func _cmd_fmt(args: Array, _piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: fmt <expr> <spec>  (spec: x|o|b|d|f|s|c|p)")
	var spec := str(args[-1]).strip_edges().to_lower()
	var expr_parts: Array[String] = []
	for i in range(args.size() - 1):
		expr_parts.append(str(args[i]))
	var expr_text := " ".join(expr_parts).strip_edges()
	if expr_text.is_empty():
		return _format_error("Empty expression")

	var value: Variant = _evaluate(expr_text)
	var formatted: Variant = _apply_spec(value, spec)
	if formatted == null:
		return _format_error("Unknown spec '%s' (expected x|o|b|d|f|s|c|p)" % spec)
	return "%s = %s" % [_color_path(expr_text), str(formatted)]

func _cmd_fmt_hex(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: fmt_hex <int>")
	var raw := str(args[0]).strip_edges()
	var iv: int = _parse_int_smart(raw)
	return "%s = %s" % [_color_path(raw), _color_number(_to_hex(iv))]

func _cmd_fmt_bin(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: fmt_bin <int>")
	var raw := str(args[0]).strip_edges()
	var iv: int = _parse_int_smart(raw)
	return "%s = %s" % [_color_path(raw), _color_number(_to_bin(iv))]

func _cmd_fmt_oct(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: fmt_oct <int>")
	var raw := str(args[0]).strip_edges()
	var iv: int = _parse_int_smart(raw)
	return "%s = %s" % [_color_path(raw), _color_number(_to_oct(iv))]

func _cmd_fmt_dec(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: fmt_dec <hex_string>")
	var raw := str(args[0]).strip_edges()
	var stripped := raw
	var lower := stripped.to_lower()
	if lower.begins_with("0x"):
		stripped = stripped.substr(2)
	elif lower.begins_with("#"):
		stripped = stripped.substr(1)
	if stripped.is_empty() or not stripped.is_valid_hex_number(false):
		return _format_error("Not a valid hex string: %s" % raw)
	var iv: int = stripped.hex_to_int()
	return "%s = %s" % [_color_path(raw), _color_number(str(iv))]

func _cmd_fmt_color(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: fmt_color <r,g,b[,a]>  (0-1 or 0-255)")
	var raw := " ".join(_to_string_array(args)).strip_edges()
	var color_v: Variant = _parse_color(raw)
	if color_v == null:
		return _format_error("Bad color: %s  (expected r,g,b or r,g,b,a)" % raw)
	var c: Color = color_v
	var hex_rgb := c.to_html(false)
	var hex_rgba := c.to_html(true)
	var swatch := "[bgcolor=#%s]          [/bgcolor]" % hex_rgb
	var rgba_text := "rgba=(%.3f, %.3f, %.3f, %.3f)" % [c.r, c.g, c.b, c.a]
	var u8_text := "u8=(%d, %d, %d, %d)" % [int(round(c.r * 255.0)), int(round(c.g * 255.0)), int(round(c.b * 255.0)), int(round(c.a * 255.0))]
	return "%s  %s  %s  #%s  #%s" % [
		swatch,
		rgba_text,
		u8_text,
		_color_number(hex_rgb.to_upper()),
		_color_number(hex_rgba.to_upper()),
	]

func _cmd_fmt_vector(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: fmt_vector <x,y[,z[,w]]>")
	var raw := " ".join(_to_string_array(args)).strip_edges()
	var nums := _parse_floats(raw)
	if nums.size() < 2 or nums.size() > 4:
		return _format_error("Need 2-4 components, got %d: %s" % [nums.size(), raw])

	var lines: Array[String] = []
	if nums.size() == 2:
		var v2 := Vector2(nums[0], nums[1])
		var angle_deg: float = rad_to_deg(v2.angle())
		lines.append("Vector2(%s, %s)" % [_color_number(_num(v2.x)), _color_number(_num(v2.y))])
		lines.append("  magnitude = %s" % _color_number(_num(v2.length())))
		lines.append("  angle     = %s deg  (atan2(y, x))" % _color_number(_num(angle_deg)))
	elif nums.size() == 3:
		var v3 := Vector3(nums[0], nums[1], nums[2])
		var azimuth_deg: float = rad_to_deg(atan2(v3.z, v3.x))
		var horiz: float = sqrt(v3.x * v3.x + v3.z * v3.z)
		var elev_deg: float = rad_to_deg(atan2(v3.y, horiz))
		lines.append("Vector3(%s, %s, %s)" % [_color_number(_num(v3.x)), _color_number(_num(v3.y)), _color_number(_num(v3.z))])
		lines.append("  magnitude = %s" % _color_number(_num(v3.length())))
		lines.append("  azimuth   = %s deg  (XZ plane, from +X toward +Z)" % _color_number(_num(azimuth_deg)))
		lines.append("  elevation = %s deg  (from XZ plane, +Y up)" % _color_number(_num(elev_deg)))
	else:
		var v4 := Vector4(nums[0], nums[1], nums[2], nums[3])
		lines.append("Vector4(%s, %s, %s, %s)" % [_color_number(_num(v4.x)), _color_number(_num(v4.y)), _color_number(_num(v4.z)), _color_number(_num(v4.w))])
		lines.append("  magnitude = %s" % _color_number(_num(v4.length())))
	return "\n".join(lines)

func _cmd_fmt_bytes(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: fmt_bytes <b1,b2,b3,...>")
	var raw := " ".join(_to_string_array(args)).strip_edges()
	if (raw.begins_with("[") and raw.ends_with("]")) or (raw.begins_with("(") and raw.ends_with(")")):
		raw = raw.substr(1, raw.length() - 2)
	var parts: PackedStringArray = raw.split(",", false)
	var bytes := PackedByteArray()
	for p in parts:
		var t := p.strip_edges()
		if t.is_empty():
			continue
		var v: int = _parse_int_smart(t)
		if v < 0 or v > 255:
			return _format_error("Byte out of range (0-255): %s" % t)
		bytes.append(v)
	if bytes.is_empty():
		return _format_error("No bytes to dump")

	var lines: Array[String] = []
	var total: int = bytes.size()
	var i: int = 0
	while i < total:
		var end: int = mini(i + 16, total)
		var hex_parts: Array[String] = []
		var ascii_parts: Array[String] = []
		for j in range(i, end):
			var b: int = bytes[j]
			hex_parts.append("%02x" % b)
			ascii_parts.append(char(b) if b >= 32 and b < 127 else ".")
		while hex_parts.size() < 16:
			hex_parts.append("  ")
			ascii_parts.append(" ")
		var left_hex := " ".join(hex_parts.slice(0, 8))
		var right_hex := " ".join(hex_parts.slice(8, 16))
		var ascii_text := "".join(ascii_parts)
		lines.append("[color=%s]%04x[/color]: %s  %s  |%s|" % [_COLOR_MUTED, i, left_hex, right_hex, ascii_text])
		i = end
	lines.append("[color=%s](%d bytes)[/color]" % [_COLOR_MUTED, total])
	return "\n".join(lines)

func _cmd_fmt_size(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: fmt_size <bytes>")
	var raw := str(args[0]).strip_edges()
	var iv: int = _parse_int_smart(raw)
	if iv < 0:
		return _format_error("Size must be >= 0: %s" % raw)
	return "%s = %s" % [_color_path("%d B" % iv), _color_number(_human_size(iv))]

#endregion

#region Helpers

func _apply_spec(value: Variant, spec: String) -> Variant:
	match spec:
		"x":
			return _color_number(_to_hex(_to_int_lenient(value)))
		"o":
			return _color_number(_to_oct(_to_int_lenient(value)))
		"b":
			return _color_number(_to_bin(_to_int_lenient(value)))
		"d":
			return _color_number(str(_to_int_lenient(value)))
		"f":
			return _color_number("%f" % _to_float_lenient(value))
		"s":
			return "\"%s\"" % str(value)
		"c":
			var cp: int = _to_int_lenient(value)
			cp = clamp(cp, 0, 0x10FFFF)
			return "%s  (U+%04X)" % [char(cp), cp]
		"p":
			return _printable(value)
		_:
			return null

func _evaluate(expr_text: String) -> Variant:
	# Try Godot's Expression first so users can compose arithmetic
	# (`fmt 1+2*3 x` -> 0x7), then fall back to literal parsing on failure.
	var eval := Expression.new()
	var parse_err: int = eval.parse(expr_text, PackedStringArray())
	if parse_err == OK:
		var result: Variant = eval.execute([], null, true)
		if not eval.has_execute_failed():
			return result
	return _parse_value(expr_text)

func _printable(value: Variant) -> String:
	if value == null:
		return "<null>"
	var t: int = typeof(value)
	if t == TYPE_STRING or t == TYPE_STRING_NAME:
		var s := str(value)
		var out := ""
		for ch in s:
			var cp: int = ch.unicode_at(0)
			if cp >= 32 and cp < 127:
				out += ch
			elif cp == 9:
				out += "\\t"
			elif cp == 10:
				out += "\\n"
			elif cp == 13:
				out += "\\r"
			elif cp == 0:
				out += "\\0"
			else:
				out += "\\x%02x" % cp
		return "\"%s\"" % out
	return str(value)

func _to_hex(i: int) -> String:
	var raw := String.num_int64(absi(i), 16, true)
	return ("-0x" if i < 0 else "0x") + raw

func _to_oct(i: int) -> String:
	var raw := String.num_int64(absi(i), 8)
	return ("-0o" if i < 0 else "0o") + raw

func _to_bin(i: int) -> String:
	var raw := String.num_int64(absi(i), 2)
	return ("-0b" if i < 0 else "0b") + raw

func _to_int_lenient(value: Variant) -> int:
	var t: int = typeof(value)
	if t == TYPE_INT:
		return value
	if t == TYPE_FLOAT:
		return int(value)
	if t == TYPE_BOOL:
		return 1 if value else 0
	if t == TYPE_STRING or t == TYPE_STRING_NAME:
		return _parse_int_smart(str(value))
	return 0

func _to_float_lenient(value: Variant) -> float:
	var t: int = typeof(value)
	if t == TYPE_FLOAT:
		return value
	if t == TYPE_INT:
		return float(value)
	if t == TYPE_BOOL:
		return 1.0 if value else 0.0
	if t == TYPE_STRING or t == TYPE_STRING_NAME:
		var s := str(value).strip_edges()
		if s.is_valid_float():
			return s.to_float()
		return float(_parse_int_smart(s))
	return 0.0

func _parse_int_smart(raw: String) -> int:
	var s := raw.strip_edges()
	if s.is_empty():
		return 0
	var negative := false
	if s.begins_with("-"):
		negative = true
		s = s.substr(1)
	elif s.begins_with("+"):
		s = s.substr(1)
	var iv: int = 0
	var lower := s.to_lower()
	if lower.begins_with("0x"):
		var hex := s.substr(2)
		if hex.is_valid_hex_number(false):
			iv = hex.hex_to_int()
	elif lower.begins_with("0b"):
		iv = _bin_to_int(s.substr(2))
	elif lower.begins_with("0o"):
		iv = _oct_to_int(s.substr(2))
	elif s.is_valid_int():
		iv = s.to_int()
	elif s.is_valid_float():
		iv = int(s.to_float())
	elif s.is_valid_hex_number(false):
		iv = s.hex_to_int()
	return -iv if negative else iv

func _bin_to_int(bin: String) -> int:
	var acc: int = 0
	for ch in bin:
		if ch == "0":
			acc = acc << 1
		elif ch == "1":
			acc = (acc << 1) | 1
		else:
			return 0
	return acc

func _oct_to_int(oct: String) -> int:
	var acc: int = 0
	for ch in oct:
		var code: int = ch.unicode_at(0)
		if code < 0x30 or code > 0x37:
			return 0
		acc = (acc << 3) | (code - 0x30)
	return acc

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
	var lower := s.to_lower()
	if lower.begins_with("0x") or lower.begins_with("0b") or lower.begins_with("0o"):
		return _parse_int_smart(s)
	if s.is_valid_int():
		return s.to_int()
	if s.is_valid_float():
		return s.to_float()
	return s

func _parse_floats(raw: String) -> Array[float]:
	var s := raw
	if (s.begins_with("(") and s.ends_with(")")) or (s.begins_with("[") and s.ends_with("]")):
		s = s.substr(1, s.length() - 2)
	var out: Array[float] = []
	var parts: PackedStringArray = s.split(",", false)
	for p in parts:
		var t := p.strip_edges()
		if t.is_empty():
			continue
		if t.is_valid_float() or t.is_valid_int():
			out.append(t.to_float())
		else:
			return [] as Array[float]
	return out

func _parse_color(raw: String) -> Variant:
	var s := raw
	if (s.begins_with("(") and s.ends_with(")")) or (s.begins_with("[") and s.ends_with("]")):
		s = s.substr(1, s.length() - 2)
	var parts: PackedStringArray = s.split(",", false)
	if parts.size() < 3 or parts.size() > 4:
		return null
	var vals: Array[float] = []
	for p in parts:
		var t := p.strip_edges()
		if not (t.is_valid_float() or t.is_valid_int()):
			return null
		vals.append(t.to_float())
	# Detect 0-255 vs 0-1 by inspecting magnitude. If any component is > 1
	# we assume the user supplied an 8-bit triplet/quad and rescale.
	var max_v: float = 0.0
	for v in vals:
		if v > max_v:
			max_v = v
	var scale: float = (1.0 / 255.0) if max_v > 1.0 else 1.0
	var r: float = clamp(vals[0] * scale, 0.0, 1.0)
	var g: float = clamp(vals[1] * scale, 0.0, 1.0)
	var b: float = clamp(vals[2] * scale, 0.0, 1.0)
	var a: float = clamp(vals[3] * scale, 0.0, 1.0) if vals.size() == 4 else 1.0
	return Color(r, g, b, a)

func _human_size(bytes: int) -> String:
	var units: PackedStringArray = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]
	if bytes < 1024:
		return "%d %s" % [bytes, units[0]]
	var value: float = float(bytes)
	var idx: int = 0
	while value >= 1024.0 and idx < units.size() - 1:
		value /= 1024.0
		idx += 1
	return "%.2f %s" % [value, units[idx]]

func _num(v: float) -> String:
	if absf(v - roundf(v)) < 0.0001:
		return "%.1f" % v
	return "%.4f" % v

func _to_string_array(arr: Array) -> Array[String]:
	var out: Array[String] = []
	for a in arr:
		out.append(str(a))
	return out

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

#endregion

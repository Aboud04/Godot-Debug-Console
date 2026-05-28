@tool
class_name DebugConsoleMathCommands extends RefCounted

# Math utility commands. Bundles the random/lerp/noise/vector/angle
# helpers gamedevs typically reach for in a debug console. All commands run in
# "both" contexts (math is context-agnostic). Follows the same registration
# contract as the other sibling modules: the orchestrator instantiates one
# of these, holds a strong reference, and calls register_commands(registry,
# core). Callables stay valid for the plugin lifetime via that strong ref.

const _COLOR_ERROR := "#FF4444"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_LABEL := "#A0E0A0"
const _COLOR_HINT := "#5FBEE0"

var _registry: Node
var _core: Node

# Last seed the user explicitly applied via `rand_seed <s>`. Godot does not
# expose the live RNG seed, so we track it ourselves to keep `rand_seed` (no
# arg) reportable. Null means "never set in this session".
var _current_seed: Variant = null

# Lazy FastNoiseLite instance reused across `noise` calls so successive
# samples come from a stable noise field (and so `noise_seed` is meaningful).
var _noise: FastNoiseLite = null

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("rand", _cmd_rand, "Random float in [min, max]: rand <min> <max>", "both")
	_registry.register_command("rand_int", _cmd_rand_int, "Random int in [min, max] (inclusive): rand_int <min> <max>", "both")
	_registry.register_command("rand_seed", _cmd_rand_seed, "Get or set the global RNG seed: rand_seed [seed]", "both")
	_registry.register_command("dist", _cmd_dist, "Distance between two points (2D or 3D): dist <ax,ay[,az]> <bx,by[,bz]>", "both")
	_registry.register_command("lerp_val", _cmd_lerp_val, "Scalar lerp: lerp_val <a> <b> <t>", "both")
	_registry.register_command("ease_val", _cmd_ease_val, "Eased interpolation: ease_val <a> <b> <t> <curve>", "both")
	_registry.register_command("noise", _cmd_noise, "Sample FastNoiseLite: noise <x> [y] [z]", "both")
	_registry.register_command("noise_seed", _cmd_noise_seed, "Set FastNoiseLite seed: noise_seed <s>", "both")
	_registry.register_command("vec", _cmd_vec, "Vector op (add|sub|dot|cross|length|normalize|reflect): vec <op> <a> [b]", "both")
	_registry.register_command("angle", _cmd_angle, "Angle op (deg_to_rad|rad_to_deg|lerp_angle|angle_between): angle <op> <a> [b] [t]", "both")

#region Command implementations

func _cmd_rand(args: Array, _piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: rand <min> <max>")
	var lo_v: Variant = _parse_float(args[0])
	var hi_v: Variant = _parse_float(args[1])
	if lo_v == null or hi_v == null:
		return _format_error("rand expects two numbers")
	var lo: float = lo_v
	var hi: float = hi_v
	if hi < lo:
		return _format_error("max must be >= min (%s < %s)" % [str(hi), str(lo)])
	var value: float = randf_range(lo, hi)
	return "rand(%s, %s) = %s" % [_color_number(str(lo)), _color_number(str(hi)), _color_number(str(value))]

func _cmd_rand_int(args: Array, _piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: rand_int <min> <max>")
	var lo_v: Variant = _parse_int(args[0])
	var hi_v: Variant = _parse_int(args[1])
	if lo_v == null or hi_v == null:
		return _format_error("rand_int expects two integers")
	var lo: int = lo_v
	var hi: int = hi_v
	if hi < lo:
		return _format_error("max must be >= min (%d < %d)" % [hi, lo])
	var value: int = randi_range(lo, hi)
	return "rand_int(%s, %s) = %s" % [_color_number(str(lo)), _color_number(str(hi)), _color_number(str(value))]

func _cmd_rand_seed(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		if _current_seed == null:
			return "rand_seed: %s (use 'rand_seed <s>' to set)" % _color_hint("unset")
		return "rand_seed = %s" % _color_number(str(_current_seed))
	var s_v: Variant = _parse_int(args[0])
	if s_v == null:
		return _format_error("rand_seed expects an integer")
	var s: int = s_v
	seed(s)
	_current_seed = s
	return "rand_seed set to %s" % _color_number(str(s))

func _cmd_dist(args: Array, _piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: dist <ax,ay[,az]> <bx,by[,bz]>")
	var a_v: Variant = _parse_vec(args[0])
	var b_v: Variant = _parse_vec(args[1])
	if a_v == null or b_v == null:
		return _format_error("dist expects two comma-separated vectors")
	if typeof(a_v) != typeof(b_v):
		return _format_error("dist: vector dimensions must match (2D vs 3D)")
	var d: float = 0.0
	if a_v is Vector2:
		d = (a_v as Vector2).distance_to(b_v as Vector2)
	else:
		d = (a_v as Vector3).distance_to(b_v as Vector3)
	return "dist(%s, %s) = %s" % [_color_number(str(a_v)), _color_number(str(b_v)), _color_number(str(d))]

func _cmd_lerp_val(args: Array, _piped_input: String = "") -> String:
	if args.size() < 3:
		return _format_error("Usage: lerp_val <a> <b> <t>")
	var a_v: Variant = _parse_float(args[0])
	var b_v: Variant = _parse_float(args[1])
	var t_v: Variant = _parse_float(args[2])
	if a_v == null or b_v == null or t_v == null:
		return _format_error("lerp_val expects three numbers")
	var a: float = a_v
	var b: float = b_v
	var t: float = t_v
	var value: float = lerp(a, b, t)
	return "lerp(%s, %s, %s) = %s" % [_color_number(str(a)), _color_number(str(b)), _color_number(str(t)), _color_number(str(value))]

func _cmd_ease_val(args: Array, _piped_input: String = "") -> String:
	if args.size() < 4:
		return _format_error("Usage: ease_val <a> <b> <t> <curve>")
	var a_v: Variant = _parse_float(args[0])
	var b_v: Variant = _parse_float(args[1])
	var t_v: Variant = _parse_float(args[2])
	if a_v == null or b_v == null or t_v == null:
		return _format_error("ease_val expects three numbers and a curve name")
	var curve_name: String = str(args[3]).strip_edges().to_lower()
	var curve: Variant = _parse_ease(curve_name)
	if curve == null:
		return _format_error("Unknown ease curve: %s (try: in, out, in_out, out_in, sine, quad, cubic, expo, elastic, back, bounce)" % curve_name)
	var spec: Dictionary = curve
	var a: float = a_v
	var b: float = b_v
	var t: float = clampf(t_v, 0.0, 1.0)
	var value: float = Tween.interpolate_value(a, b - a, t, 1.0, spec["trans"], spec["ease"])
	return "ease_val(%s, %s, %s, %s) = %s" % [_color_number(str(a)), _color_number(str(b)), _color_number(str(t)), _color_hint(curve_name), _color_number(str(value))]

func _cmd_noise(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: noise <x> [y] [z]")
	_ensure_noise()
	var x_v: Variant = _parse_float(args[0])
	if x_v == null:
		return _format_error("noise expects numeric coordinates")
	var x: float = x_v
	var value: float = 0.0
	var label: String = ""
	if args.size() == 1:
		value = _noise.get_noise_1d(x)
		label = "noise(%s)" % _color_number(str(x))
	elif args.size() == 2:
		var y_v: Variant = _parse_float(args[1])
		if y_v == null:
			return _format_error("noise expects numeric coordinates")
		var y: float = y_v
		value = _noise.get_noise_2d(x, y)
		label = "noise(%s, %s)" % [_color_number(str(x)), _color_number(str(y))]
	else:
		var y2_v: Variant = _parse_float(args[1])
		var z_v: Variant = _parse_float(args[2])
		if y2_v == null or z_v == null:
			return _format_error("noise expects numeric coordinates")
		var y2: float = y2_v
		var z: float = z_v
		value = _noise.get_noise_3d(x, y2, z)
		label = "noise(%s, %s, %s)" % [_color_number(str(x)), _color_number(str(y2)), _color_number(str(z))]
	return "%s = %s" % [label, _color_number(str(value))]

func _cmd_noise_seed(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: noise_seed <s>")
	var s_v: Variant = _parse_int(args[0])
	if s_v == null:
		return _format_error("noise_seed expects an integer")
	var s: int = s_v
	_ensure_noise()
	_noise.seed = s
	return "noise_seed set to %s" % _color_number(str(s))

func _cmd_vec(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: vec <op> <a> [b]  (op: add|sub|dot|cross|length|normalize|reflect)")
	var op: String = str(args[0]).strip_edges().to_lower()
	var unary: Array = ["length", "normalize"]
	var binary: Array = ["add", "sub", "dot", "cross", "reflect"]
	if op in unary:
		if args.size() < 2:
			return _format_error("vec %s expects 1 vector" % op)
		var a_v: Variant = _parse_vec(args[1])
		if a_v == null:
			return _format_error("vec %s: invalid vector" % op)
		match op:
			"length":
				var l: float = (a_v as Vector3).length() if a_v is Vector3 else (a_v as Vector2).length()
				return "vec length(%s) = %s" % [_color_number(str(a_v)), _color_number(str(l))]
			"normalize":
				var n: Variant = (a_v as Vector3).normalized() if a_v is Vector3 else (a_v as Vector2).normalized()
				return "vec normalize(%s) = %s" % [_color_number(str(a_v)), _color_number(str(n))]
	elif op in binary:
		if args.size() < 3:
			return _format_error("vec %s expects 2 vectors" % op)
		var a2_v: Variant = _parse_vec(args[1])
		var b_v: Variant = _parse_vec(args[2])
		if a2_v == null or b_v == null:
			return _format_error("vec %s: invalid vector(s)" % op)
		if typeof(a2_v) != typeof(b_v):
			return _format_error("vec %s: vector dimensions must match" % op)
		match op:
			"add":
				var r: Variant = a2_v + b_v
				return "vec add(%s, %s) = %s" % [_color_number(str(a2_v)), _color_number(str(b_v)), _color_number(str(r))]
			"sub":
				var r2: Variant = a2_v - b_v
				return "vec sub(%s, %s) = %s" % [_color_number(str(a2_v)), _color_number(str(b_v)), _color_number(str(r2))]
			"dot":
				var d: float = (a2_v as Vector3).dot(b_v as Vector3) if a2_v is Vector3 else (a2_v as Vector2).dot(b_v as Vector2)
				return "vec dot(%s, %s) = %s" % [_color_number(str(a2_v)), _color_number(str(b_v)), _color_number(str(d))]
			"cross":
				if a2_v is Vector3:
					var c3: Vector3 = (a2_v as Vector3).cross(b_v as Vector3)
					return "vec cross(%s, %s) = %s" % [_color_number(str(a2_v)), _color_number(str(b_v)), _color_number(str(c3))]
				else:
					var c2: float = (a2_v as Vector2).cross(b_v as Vector2)
					return "vec cross(%s, %s) = %s" % [_color_number(str(a2_v)), _color_number(str(b_v)), _color_number(str(c2))]
			"reflect":
				if a2_v is Vector3:
					var n3: Vector3 = (b_v as Vector3)
					if n3.is_zero_approx():
						return _format_error("vec reflect: normal must be non-zero")
					var r3: Vector3 = (a2_v as Vector3).bounce(n3.normalized())
					return "vec reflect(%s, %s) = %s" % [_color_number(str(a2_v)), _color_number(str(b_v)), _color_number(str(r3))]
				else:
					var n2: Vector2 = (b_v as Vector2)
					if n2.is_zero_approx():
						return _format_error("vec reflect: normal must be non-zero")
					var rr2: Vector2 = (a2_v as Vector2).bounce(n2.normalized())
					return "vec reflect(%s, %s) = %s" % [_color_number(str(a2_v)), _color_number(str(b_v)), _color_number(str(rr2))]
	return _format_error("Unknown vec op: %s (add|sub|dot|cross|length|normalize|reflect)" % op)

func _cmd_angle(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: angle <op> <a> [b] [t]  (op: deg_to_rad|rad_to_deg|lerp_angle|angle_between)")
	var op: String = str(args[0]).strip_edges().to_lower()
	match op:
		"deg_to_rad":
			if args.size() < 2:
				return _format_error("angle deg_to_rad expects 1 number")
			var d_v: Variant = _parse_float(args[1])
			if d_v == null:
				return _format_error("angle deg_to_rad: invalid number")
			var d: float = d_v
			return "deg_to_rad(%s) = %s" % [_color_number(str(d)), _color_number(str(deg_to_rad(d)))]
		"rad_to_deg":
			if args.size() < 2:
				return _format_error("angle rad_to_deg expects 1 number")
			var r_v: Variant = _parse_float(args[1])
			if r_v == null:
				return _format_error("angle rad_to_deg: invalid number")
			var r: float = r_v
			return "rad_to_deg(%s) = %s" % [_color_number(str(r)), _color_number(str(rad_to_deg(r)))]
		"lerp_angle":
			if args.size() < 4:
				return _format_error("angle lerp_angle expects <a> <b> <t> (radians)")
			var a_v: Variant = _parse_float(args[1])
			var b_v: Variant = _parse_float(args[2])
			var t_v: Variant = _parse_float(args[3])
			if a_v == null or b_v == null or t_v == null:
				return _format_error("angle lerp_angle: invalid number(s)")
			var a: float = a_v
			var b: float = b_v
			var t: float = t_v
			return "lerp_angle(%s, %s, %s) = %s" % [_color_number(str(a)), _color_number(str(b)), _color_number(str(t)), _color_number(str(lerp_angle(a, b, t)))]
		"angle_between":
			if args.size() < 3:
				return _format_error("angle angle_between expects <a_vec> <b_vec>")
			var av_v: Variant = _parse_vec(args[1])
			var bv_v: Variant = _parse_vec(args[2])
			if av_v == null or bv_v == null:
				return _format_error("angle angle_between: invalid vector(s)")
			if typeof(av_v) != typeof(bv_v):
				return _format_error("angle angle_between: vector dimensions must match")
			var ang: float = 0.0
			if av_v is Vector3:
				ang = (av_v as Vector3).angle_to(bv_v as Vector3)
			else:
				ang = (av_v as Vector2).angle_to(bv_v as Vector2)
			return "angle_between(%s, %s) = %s rad" % [_color_number(str(av_v)), _color_number(str(bv_v)), _color_number(str(ang))]
		_:
			return _format_error("Unknown angle op: %s (deg_to_rad|rad_to_deg|lerp_angle|angle_between)" % op)

#endregion

#region Helpers

func _ensure_noise() -> void:
	if _noise == null:
		_noise = FastNoiseLite.new()

func _parse_float(v: Variant) -> Variant:
	var s: String = str(v).strip_edges()
	if s.is_empty():
		return null
	if not s.is_valid_float():
		return null
	return s.to_float()

func _parse_int(v: Variant) -> Variant:
	var s: String = str(v).strip_edges()
	if s.is_empty():
		return null
	if not s.is_valid_int():
		# Allow trailing .0 etc by trying float conversion as a fallback.
		if s.is_valid_float():
			return int(s.to_float())
		return null
	return s.to_int()

# Returns Vector2 / Vector3 (auto-detected from comma count) or null on failure.
func _parse_vec(v: Variant) -> Variant:
	var s: String = str(v).strip_edges()
	if s.is_empty():
		return null
	# Tolerate enclosing parens or brackets that users sometimes paste in.
	if s.begins_with("("):
		s = s.substr(1, s.length() - 1)
	if s.ends_with(")"):
		s = s.substr(0, s.length() - 1)
	if s.begins_with("["):
		s = s.substr(1, s.length() - 1)
	if s.ends_with("]"):
		s = s.substr(0, s.length() - 1)
	var parts: PackedStringArray = s.split(",", false)
	if parts.size() != 2 and parts.size() != 3:
		return null
	var nums: Array[float] = []
	for p in parts:
		var t: String = p.strip_edges()
		if not t.is_valid_float():
			return null
		nums.append(t.to_float())
	if nums.size() == 2:
		return Vector2(nums[0], nums[1])
	return Vector3(nums[0], nums[1], nums[2])

# Maps a single curve token to a (trans, ease) pair for Tween.interpolate_value.
# Direction tokens (in/out/in_out/out_in) pair with a smooth default transition
# (TRANS_SINE). Shape tokens (sine/quad/cubic/...) pair with EASE_IN_OUT so
# they read naturally when used alone.
func _parse_ease(name: String) -> Variant:
	match name:
		"in":
			return {"trans": Tween.TRANS_SINE, "ease": Tween.EASE_IN}
		"out":
			return {"trans": Tween.TRANS_SINE, "ease": Tween.EASE_OUT}
		"in_out":
			return {"trans": Tween.TRANS_SINE, "ease": Tween.EASE_IN_OUT}
		"out_in":
			return {"trans": Tween.TRANS_SINE, "ease": Tween.EASE_OUT_IN}
		"sine":
			return {"trans": Tween.TRANS_SINE, "ease": Tween.EASE_IN_OUT}
		"quad":
			return {"trans": Tween.TRANS_QUAD, "ease": Tween.EASE_IN_OUT}
		"cubic":
			return {"trans": Tween.TRANS_CUBIC, "ease": Tween.EASE_IN_OUT}
		"expo":
			return {"trans": Tween.TRANS_EXPO, "ease": Tween.EASE_IN_OUT}
		"elastic":
			return {"trans": Tween.TRANS_ELASTIC, "ease": Tween.EASE_IN_OUT}
		"back":
			return {"trans": Tween.TRANS_BACK, "ease": Tween.EASE_IN_OUT}
		"bounce":
			return {"trans": Tween.TRANS_BOUNCE, "ease": Tween.EASE_IN_OUT}
		_:
			return null

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

func _color_hint(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_HINT, s]

#endregion

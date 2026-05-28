@tool
class_name DebugConsoleColorCommands extends RefCounted

# Color utility commands: hex/RGB/HSV conversion, color picker dialog,
# BBCode swatch preview, palette generation, and WCAG contrast scoring.
#
# Mirrors the SceneCommands.gd / DnsCommands.gd pattern: the orchestrator
# (BuiltInCommands.register_universal_commands) instantiates one of these,
# holds a strong reference, and calls `register_commands(registry, core)`.
# All Callables route through this instance so they outlive single-command
# invocations.
#
# Everything except `color_pick` is pure-function and runs in both editor
# and game contexts. `color_pick` spawns an AcceptDialog hosting a
# ColorPicker and emits the chosen hex asynchronously through `_core`,
# mirroring the delivery channel that DialogCommands._emit_result uses.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_MUTED := "#888888"

# Width of the inline swatch block. Eight spaces with a bgcolor read as a
# distinct colored rectangle in any RichTextLabel that honors `bgcolor`.
const _SWATCH_PAD := "        "

# CSS / SVG 1.0 named colors. Godot's `Color(name)` constructor accepts the
# same set, but the engine does not expose an enumeration API, so the list
# is materialized here once. Names are lower-cased to match the constructor's
# case-insensitive lookup.
const _NAMED_COLORS: PackedStringArray = [
	"aliceblue", "antiquewhite", "aqua", "aquamarine", "azure",
	"beige", "bisque", "black", "blanchedalmond", "blue",
	"blueviolet", "brown", "burlywood", "cadetblue", "chartreuse",
	"chocolate", "coral", "cornflowerblue", "cornsilk", "crimson",
	"cyan", "darkblue", "darkcyan", "darkgoldenrod", "darkgray",
	"darkgreen", "darkkhaki", "darkmagenta", "darkolivegreen", "darkorange",
	"darkorchid", "darkred", "darksalmon", "darkseagreen", "darkslateblue",
	"darkslategray", "darkturquoise", "darkviolet", "deeppink", "deepskyblue",
	"dimgray", "dodgerblue", "firebrick", "floralwhite", "forestgreen",
	"fuchsia", "gainsboro", "ghostwhite", "gold", "goldenrod",
	"gray", "green", "greenyellow", "honeydew", "hotpink",
	"indianred", "indigo", "ivory", "khaki", "lavender",
	"lavenderblush", "lawngreen", "lemonchiffon", "lightblue", "lightcoral",
	"lightcyan", "lightgoldenrodyellow", "lightgray", "lightgreen", "lightpink",
	"lightsalmon", "lightseagreen", "lightskyblue", "lightslategray", "lightsteelblue",
	"lightyellow", "lime", "limegreen", "linen", "magenta",
	"maroon", "mediumaquamarine", "mediumblue", "mediumorchid", "mediumpurple",
	"mediumseagreen", "mediumslateblue", "mediumspringgreen", "mediumturquoise", "mediumvioletred",
	"midnightblue", "mintcream", "mistyrose", "moccasin", "navajowhite",
	"navy", "oldlace", "olive", "olivedrab", "orange",
	"orangered", "orchid", "palegoldenrod", "palegreen", "paleturquoise",
	"palevioletred", "papayawhip", "peachpuff", "peru", "pink",
	"plum", "powderblue", "purple", "rebeccapurple", "red",
	"rosybrown", "royalblue", "saddlebrown", "salmon", "sandybrown",
	"seagreen", "seashell", "sienna", "silver", "skyblue",
	"slateblue", "slategray", "snow", "springgreen", "steelblue",
	"tan", "teal", "thistle", "tomato", "transparent",
	"turquoise", "violet", "webgray", "webgreen", "webmaroon",
	"webpurple", "wheat", "white", "whitesmoke", "yellow",
	"yellowgreen",
]

var _registry: Node
var _core: Node

# Monotonic counter so each picker spawned during a session gets a unique
# ID, even if the previous one is still open. Starts at 1 to read as
# `pick_1` instead of `pick_0`.
var _pick_counter: int = 0

# Holds strong refs to live picker dialogs so the GC does not collect them
# while they are waiting for the user. Cleared on confirm / cancel / close.
var _active_pickers: Dictionary = {}

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("color_show", _cmd_color_show, "Render a color swatch with RGB+HSV breakdown: color_show <hex|name>", "both")
	_registry.register_command("color_pick", _cmd_color_pick, "Spawn a ColorPicker dialog and emit the chosen hex: color_pick [initial_hex]", "both")
	_registry.register_command("color_from_hex", _cmd_color_from_hex, "Decompose a hex color into r,g,b,a components: color_from_hex <hex>", "both")
	_registry.register_command("color_to_hex", _cmd_color_to_hex, "Compose a hex color from r,g,b[,a] (0-1 floats or 0-255 ints): color_to_hex <r,g,b[,a]>", "both")
	_registry.register_command("color_blend", _cmd_color_blend, "Lerp two hex colors at t in [0,1]: color_blend <hex_a> <hex_b> <t>", "both")
	_registry.register_command("color_palette", _cmd_color_palette, "Generate N evenly-spaced hues from a base color: color_palette <hex_a> <count>", "both")
	_registry.register_command("color_contrast", _cmd_color_contrast, "WCAG 2.x contrast ratio between two colors: color_contrast <hex_a> <hex_b>", "both")
	_registry.register_command("color_named", _cmd_color_named, "List Godot's built-in color names with swatches", "both")

#region Command implementations

func _cmd_color_show(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: color_show <hex|name>")
	var raw := str(args[0]).strip_edges()
	var parsed := _parse_color_token(raw)
	if not parsed.ok:
		return _format_error("color_show: unknown color '%s'" % raw)
	var c: Color = parsed.color
	var lines: PackedStringArray = []
	lines.append("%s  %s" % [_swatch(c), _color_path(raw)])
	lines.append("  hex   %s  (#%s)" % [_color_number("#" + c.to_html(false)), c.to_html(true)])
	lines.append("  rgb   r=%s g=%s b=%s a=%s" % [
		_color_number("%.3f" % c.r),
		_color_number("%.3f" % c.g),
		_color_number("%.3f" % c.b),
		_color_number("%.3f" % c.a),
	])
	lines.append("  rgb8  r=%s g=%s b=%s a=%s" % [
		_color_number(str(c.r8)),
		_color_number(str(c.g8)),
		_color_number(str(c.b8)),
		_color_number(str(c.a8)),
	])
	lines.append("  hsv   h=%s s=%s v=%s" % [
		_color_number("%.1f°" % (c.h * 360.0)),
		_color_number("%.3f" % c.s),
		_color_number("%.3f" % c.v),
	])
	return "\n".join(lines)

func _cmd_color_pick(args: Array, _piped_input: String = "") -> String:
	var initial_color: Color = Color.WHITE
	if args.size() > 0:
		var raw := str(args[0]).strip_edges()
		var parsed := _parse_color_token(raw)
		if not parsed.ok:
			return _format_error("color_pick: invalid initial color '%s'" % raw)
		initial_color = parsed.color

	var root: Node = _get_root_for_dialog()
	if not root:
		return _format_error("color_pick: no SceneTree root available")

	_pick_counter += 1
	var id: String = "pick_%d" % _pick_counter

	# AcceptDialog wraps the ColorPicker so the user gets OK/Cancel for free,
	# matching DialogCommands._cmd_dialog_color's approach.
	var dialog: AcceptDialog = AcceptDialog.new()
	dialog.title = "Pick Color"
	dialog.name = "DebugConsoleColorPicker_%s" % id
	var picker: ColorPicker = ColorPicker.new()
	picker.color = initial_color
	picker.name = "Picker"
	dialog.add_child(picker)
	root.add_child(dialog)

	var on_confirm: Callable = func():
		var c: Color = picker.color if is_instance_valid(picker) else initial_color
		_emit_result("color_pick %s: %s  #%s" % [id, _swatch(c), c.to_html(false)])
		_finalize_picker(id)
	var on_cancel: Callable = func():
		_emit_result("color_pick %s: cancelled" % id)
		_finalize_picker(id)
	dialog.confirmed.connect(on_confirm)
	dialog.canceled.connect(on_cancel)
	dialog.close_requested.connect(on_cancel)

	_active_pickers[id] = dialog
	dialog.popup_centered(Vector2i(420, 520))
	return _format_success("Awaiting color: %s" % _color_id(id))

func _cmd_color_from_hex(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: color_from_hex <hex>")
	var raw := str(args[0]).strip_edges()
	var c: Variant = _parse_hex(raw)
	if c == null:
		return _format_error("color_from_hex: invalid hex '%s'" % raw)
	var col: Color = c
	return "%s  r=%s g=%s b=%s a=%s  (r8=%s g8=%s b8=%s a8=%s)" % [
		_swatch(col),
		_color_number("%.4f" % col.r),
		_color_number("%.4f" % col.g),
		_color_number("%.4f" % col.b),
		_color_number("%.4f" % col.a),
		_color_number(str(col.r8)),
		_color_number(str(col.g8)),
		_color_number(str(col.b8)),
		_color_number(str(col.a8)),
	]

func _cmd_color_to_hex(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: color_to_hex <r,g,b[,a]>")
	# Accept either a single CSV arg ("0.5,0.2,0.9") or already-split tokens
	# ("0.5 0.2 0.9") so users do not have to remember which the parser wants.
	var joined: String = ""
	for a in args:
		if not joined.is_empty():
			joined += ","
		joined += str(a)
	var parts := joined.replace(" ", ",").split(",", false)
	if parts.size() < 3 or parts.size() > 4:
		return _format_error("color_to_hex: need 3 or 4 channels, got %d" % parts.size())

	var values: Array[float] = []
	for p in parts:
		var token := str(p).strip_edges()
		if not token.is_valid_float():
			return _format_error("color_to_hex: '%s' is not a number" % token)
		values.append(token.to_float())

	# Detect 0-255 vs 0-1 by inspecting the magnitudes. If anything exceeds
	# 1.0 we treat the whole tuple as byte-range, which matches how `color_show`
	# reports the rgb8 channels and avoids silently clamping inputs like
	# "255,128,0".
	var byte_range: bool = false
	for v in values:
		if v > 1.0:
			byte_range = true
			break

	var col: Color
	if byte_range:
		col = Color8(
			int(clamp(values[0], 0.0, 255.0)),
			int(clamp(values[1], 0.0, 255.0)),
			int(clamp(values[2], 0.0, 255.0)),
			int(clamp(values[3] if values.size() == 4 else 255.0, 0.0, 255.0)),
		)
	else:
		col = Color(
			clamp(values[0], 0.0, 1.0),
			clamp(values[1], 0.0, 1.0),
			clamp(values[2], 0.0, 1.0),
			clamp(values[3] if values.size() == 4 else 1.0, 0.0, 1.0),
		)

	var include_alpha := values.size() == 4 and not is_equal_approx(col.a, 1.0)
	return "%s  %s" % [_swatch(col), _color_number("#" + col.to_html(include_alpha))]

func _cmd_color_blend(args: Array, _piped_input: String = "") -> String:
	if args.size() < 3:
		return _format_error("Usage: color_blend <hex_a> <hex_b> <t>")
	var a: Variant = _parse_hex(str(args[0]).strip_edges())
	var b: Variant = _parse_hex(str(args[1]).strip_edges())
	if a == null:
		return _format_error("color_blend: invalid hex_a '%s'" % str(args[0]))
	if b == null:
		return _format_error("color_blend: invalid hex_b '%s'" % str(args[1]))
	var t_token := str(args[2]).strip_edges()
	if not t_token.is_valid_float():
		return _format_error("color_blend: t must be a number, got '%s'" % t_token)
	var t := clamp(t_token.to_float(), 0.0, 1.0)
	var ca: Color = a
	var cb: Color = b
	var blended: Color = ca.lerp(cb, t)
	return "%s + %s  @ t=%s  ->  %s  %s" % [
		_swatch(ca),
		_swatch(cb),
		_color_number("%.3f" % t),
		_swatch(blended),
		_color_number("#" + blended.to_html(false)),
	]

func _cmd_color_palette(args: Array, _piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: color_palette <hex_a> <count>")
	var base: Variant = _parse_hex(str(args[0]).strip_edges())
	if base == null:
		return _format_error("color_palette: invalid hex '%s'" % str(args[0]))
	var count_token := str(args[1]).strip_edges()
	if not count_token.is_valid_int():
		return _format_error("color_palette: count must be an integer, got '%s'" % count_token)
	var count: int = count_token.to_int()
	if count < 1 or count > 64:
		return _format_error("color_palette: count must be in [1,64], got %d" % count)

	var base_col: Color = base
	var lines: PackedStringArray = []
	lines.append("Palette of %s from %s" % [_color_number(str(count)), _color_number("#" + base_col.to_html(false))])
	for i in range(count):
		var hue_offset := float(i) / float(count)
		var h := fposmod(base_col.h + hue_offset, 1.0)
		var c := Color.from_hsv(h, base_col.s, base_col.v, base_col.a)
		lines.append("  %s  %s  h=%s" % [
			_swatch(c),
			_color_number("#" + c.to_html(false)),
			_color_number("%.1f°" % (h * 360.0)),
		])
	return "\n".join(lines)

func _cmd_color_contrast(args: Array, _piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: color_contrast <hex_a> <hex_b>")
	var a: Variant = _parse_hex(str(args[0]).strip_edges())
	var b: Variant = _parse_hex(str(args[1]).strip_edges())
	if a == null:
		return _format_error("color_contrast: invalid hex_a '%s'" % str(args[0]))
	if b == null:
		return _format_error("color_contrast: invalid hex_b '%s'" % str(args[1]))
	var ca: Color = a
	var cb: Color = b
	var la := _relative_luminance(ca)
	var lb := _relative_luminance(cb)
	var hi := max(la, lb)
	var lo := min(la, lb)
	var ratio: float = (hi + 0.05) / (lo + 0.05)

	# WCAG 2.x thresholds: AA 4.5 / AAA 7.0 for normal text, AA 3.0 / AAA 4.5
	# for large text (>= 18pt / 14pt bold). We surface all four so users can
	# pick the bucket appropriate to their UI sample.
	var verdict := "FAIL"
	if ratio >= 7.0:
		verdict = "AAA"
	elif ratio >= 4.5:
		verdict = "AA"
	elif ratio >= 3.0:
		verdict = "AA Large"
	var verdict_colored := _color_path(verdict) if verdict != "FAIL" else "[color=%s]%s[/color]" % [_COLOR_ERROR, verdict]

	return "%s vs %s  ratio=%s  %s\n  normal text: AA %s 4.5  / AAA %s 7.0\n  large text:  AA %s 3.0  / AAA %s 4.5" % [
		_swatch(ca),
		_swatch(cb),
		_color_number("%.2f" % ratio),
		verdict_colored,
		_pass_glyph(ratio >= 4.5),
		_pass_glyph(ratio >= 7.0),
		_pass_glyph(ratio >= 3.0),
		_pass_glyph(ratio >= 4.5),
	]

func _cmd_color_named(_args: Array, _piped_input: String = "") -> String:
	var lines: PackedStringArray = []
	lines.append("Named colors (%s total):" % _color_number(str(_NAMED_COLORS.size())))
	for name in _NAMED_COLORS:
		var c: Color = Color(name)
		lines.append("  %s  %s  #%s" % [
			_swatch(c),
			_color_path(name),
			_color_number(c.to_html(false)),
		])
	return "\n".join(lines)

#endregion

#region Helpers

# Returns {ok: bool, color: Color}. Accepts either a hex string ("#fff",
# "ffffff", "ffffffff") or one of Godot's built-in color names. Wrapping the
# two branches behind one helper keeps `color_show` and `color_pick` from
# duplicating the name-vs-hex disambiguation logic.
func _parse_color_token(raw: String) -> Dictionary:
	var token := raw.strip_edges()
	if token.is_empty():
		return {"ok": false, "color": Color.WHITE}
	var hex: Variant = _parse_hex(token)
	if hex != null:
		return {"ok": true, "color": hex}
	var lower := token.to_lower()
	if _NAMED_COLORS.has(lower):
		return {"ok": true, "color": Color(lower)}
	# Fall through to Godot's own constructor in case the user typed a name
	# the cached list does not cover (e.g. future engine additions).
	var probe := Color(lower)
	if probe != Color(0, 0, 0, 1) or lower == "black":
		return {"ok": true, "color": probe}
	return {"ok": false, "color": Color.WHITE}

# Returns a Color on success, null on failure. Tolerates a leading '#' and
# both 6- and 8-digit forms. Uses `Color.html_is_valid` for the actual
# validation so the accepted dialect stays in lock-step with the engine.
func _parse_hex(raw: String):
	var token := raw.strip_edges()
	if token.is_empty():
		return null
	if not token.begins_with("#"):
		token = "#" + token
	if not Color.html_is_valid(token):
		return null
	return Color.html(token)

# WCAG 2.x relative-luminance per
# https://www.w3.org/TR/WCAG21/#dfn-relative-luminance. The 0.03928 cutoff
# and 2.4 exponent are taken verbatim from the spec; do not "simplify" them.
func _relative_luminance(c: Color) -> float:
	return 0.2126 * _linearize(c.r) + 0.7152 * _linearize(c.g) + 0.0722 * _linearize(c.b)

func _linearize(v: float) -> float:
	if v <= 0.03928:
		return v / 12.92
	return pow((v + 0.055) / 1.055, 2.4)

# Renders an inline BBCode swatch. `bgcolor` is honored by RichTextLabel; the
# eight non-breaking-looking spaces give it enough width to read as a chip.
func _swatch(c: Color) -> String:
	return "[bgcolor=#%s]%s[/bgcolor]" % [c.to_html(false), _SWATCH_PAD]

func _pass_glyph(passing: bool) -> String:
	if passing:
		return "[color=%s]✓[/color]" % _COLOR_SUCCESS
	return "[color=%s]✗[/color]" % _COLOR_ERROR

# Mirrors DialogCommands._get_root_for_dialog so the picker can attach to a
# Window that is guaranteed to exist in both editor and runtime contexts.
func _get_root_for_dialog() -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if not tree:
		return null
	if Engine.is_editor_hint():
		if Engine.has_singleton("EditorInterface"):
			var ei = Engine.get_singleton("EditorInterface")
			if ei and ei.has_method("get_base_control"):
				var base = ei.get_base_control()
				if base:
					return base
			if ei and ei.has_method("get_edited_scene_root"):
				var edited = ei.get_edited_scene_root()
				if edited:
					return edited
		return tree.root
	return tree.root

# Async result delivery for `color_pick`. Mirrors DialogCommands._emit_result:
# prefer the forward-compat `print_to_console` hook, fall back to `info`,
# then echo through the registry, finally degrade to `print` so the line is
# never lost.
func _emit_result(msg: String) -> void:
	if _core and is_instance_valid(_core):
		if _core.has_method("print_to_console"):
			_core.call("print_to_console", msg)
			return
		if _core.has_method("info"):
			_core.call("info", msg)
			return
	if _registry and is_instance_valid(_registry) and _registry.has_method("execute_command"):
		_registry.call("execute_command", "echo " + msg)
		return
	print(msg)

func _finalize_picker(id: String) -> void:
	if _active_pickers.has(id):
		var dialog = _active_pickers.get(id)
		if is_instance_valid(dialog):
			dialog.queue_free()
		_active_pickers.erase(id)

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

func _color_id(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_MUTED, s]

#endregion

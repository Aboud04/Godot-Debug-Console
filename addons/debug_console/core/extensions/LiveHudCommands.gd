@tool
class_name DebugConsoleLiveHudCommands extends RefCounted

# Tier 14 - persistent on-screen formula HUD. Each `live_show` paints a Label
# whose text re-evaluates a user-supplied Godot Expression every frame. Useful
# for live FPS, player position, health, custom singleton values, or any tiny
# diagnostic you'd otherwise have to re-print into the log on a timer.
#
# All Labels are children of a single CanvasLayer overlay parented to the
# running scene root (mirrors core/UICommands.gd:391-420 which lazy-creates a
# `DebugConsoleUI` CanvasLayer for ui_* commands). Per-frame work is driven by
# a one-shot connection to SceneTree.process_frame (same pattern as
# extensions/AssertCommands.gd:252-256 and AnimGraphCommands.gd:200) so an
# empty HUD costs zero per-frame overhead.
#
# Quoting: command tokens are split on whitespace by CommandRegistry, so the
# expression body must not contain spaces. Use Godot Expression syntax that
# packs tightly (`get_node("Player").position`, `Engine.get_frames_per_second()`).
# The trailing token is auto-recognised as a `#hex` color override.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"

const _OVERLAY_NAME := "__DebugConsoleLiveHud__"
const _OVERLAY_LAYER_INDEX := 100  # above gameplay UI, below CommandRegistry's
									# debug-console layer (128)
const _DEFAULT_FONT_SIZE := 16
const _DEFAULT_COLOR := Color(1.0, 1.0, 1.0, 1.0)
const _DEFAULT_POSITION := Vector2(16, 16)
const _ENTRY_VSPACING := 22  # auto-stack offset for new entries

var _registry: Node
var _core: Node

# key -> Dictionary{
#   label: Label, expression_src: String, expression: Expression,
#   color: Color, font_size: int, position: Vector2,
#   paused: bool, last_error: String
# }
# Keyed by the user-supplied identifier (not the Node.name) so live_position,
# live_color, etc. stay readable even if the Node name was mangled to satisfy
# Godot's name rules. See _safe_node_suffix() for the mangling.
var _entries: Dictionary = {}

# Weak reference to the overlay CanvasLayer. Weakref instead of a Node ref so a
# scene reload that frees the layer doesn't leave us with a dangling pointer.
var _overlay_ref: WeakRef = null

var _process_connected: bool = false

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("live_show", _cmd_show,
		"Spawn/update a Label that re-evaluates an expression each frame: live_show <key> <expr> [#color]", "game")
	_registry.register_command("live_hide", _cmd_hide,
		"Remove one or all live HUD entries: live_hide <key|all>", "game")
	_registry.register_command("live_list", _cmd_list,
		"List all live HUD entries with their expressions and current values: live_list", "game")
	_registry.register_command("live_position", _cmd_position,
		"Move an entry's Label to a screen position: live_position <key> <x,y>", "game")
	_registry.register_command("live_color", _cmd_color,
		"Recolor an entry's font: live_color <key> <#hex>", "game")
	_registry.register_command("live_font_size", _cmd_font_size,
		"Set the font size for an entry: live_font_size <key> <n>", "game")
	_registry.register_command("live_pause", _cmd_pause,
		"Freeze an entry's value (stop re-evaluating): live_pause <key>", "game")
	_registry.register_command("live_resume", _cmd_resume,
		"Resume re-evaluating a paused entry: live_resume <key>", "game")

#region commands

func _cmd_show(args: Array) -> String:
	if Engine.is_editor_hint():
		return _format_error("live_show requires a running game context")
	if args.size() < 2:
		return _format_error("Usage: live_show <key> <expr> [#color]")

	var key: String = str(args[0]).strip_edges()
	if key.is_empty():
		return _format_error("live_show: key cannot be empty")
	if key == "all":
		return _format_error("live_show: 'all' is reserved (used by live_hide all)")

	# Detect an optional trailing `#hex` color. CommandRegistry split on
	# whitespace, so we re-glue the remaining tokens into the expression body.
	# A token starting with '#' is treated as a color iff its body is 3, 6, or
	# 8 hex digits - other '#'-prefixed tokens (rare in Godot expressions) are
	# left in the expression untouched.
	var has_color_override: bool = false
	var color_override: Color = _DEFAULT_COLOR
	var expr_end: int = args.size()
	if args.size() >= 3:
		var tail: String = str(args[args.size() - 1]).strip_edges()
		if _looks_like_color_literal(tail):
			color_override = _parse_color(tail)
			has_color_override = true
			expr_end -= 1

	var expr_parts: Array = []
	for i in range(1, expr_end):
		expr_parts.append(str(args[i]))
	var expr_src: String = " ".join(expr_parts).strip_edges()
	if expr_src.is_empty():
		return _format_error("live_show: expression cannot be empty")

	# Parse once. Re-parsing every frame would waste cycles and would surface
	# parse errors on every tick instead of failing fast here.
	var expression: Expression = Expression.new()
	var parse_err: int = expression.parse(expr_src)
	if parse_err != OK:
		return _format_error("live_show: parse error: %s" % expression.get_error_text())

	var overlay: CanvasLayer = _ensure_overlay()
	if not overlay:
		return _format_error("live_show: no SceneTree root available")

	var entry: Dictionary = _entries.get(key, {})
	var is_new: bool = entry.is_empty()
	var label: Label = null
	if is_new:
		label = Label.new()
		label.name = "Live_" + _safe_node_suffix(key)
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		# Auto-stack downward so a user firing several live_show in a row
		# doesn't get all the labels piled on top of each other.
		var stack_y: float = _DEFAULT_POSITION.y + (_ENTRY_VSPACING * _entries.size())
		var initial_pos: Vector2 = Vector2(_DEFAULT_POSITION.x, stack_y)
		label.position = initial_pos
		overlay.add_child(label)
		entry = {
			"label": label,
			"expression_src": expr_src,
			"expression": expression,
			"color": _DEFAULT_COLOR,
			"font_size": _DEFAULT_FONT_SIZE,
			"position": initial_pos,
			"paused": false,
			"last_error": "",
		}
	else:
		label = entry.get("label", null)
		if not is_instance_valid(label):
			# Scene reload freed the Label out from under us. Re-attach to the
			# (possibly new) overlay without losing the stored visual config.
			label = Label.new()
			label.name = "Live_" + _safe_node_suffix(key)
			label.mouse_filter = Control.MOUSE_FILTER_IGNORE
			label.position = entry.get("position", _DEFAULT_POSITION)
			overlay.add_child(label)
			entry["label"] = label
		entry["expression_src"] = expr_src
		entry["expression"] = expression
		entry["last_error"] = ""

	if has_color_override:
		entry["color"] = color_override

	_apply_visuals(entry)
	_entries[key] = entry
	_ensure_process_connected()
	# Pump one evaluation so the Label isn't blank for the first visible frame.
	_evaluate_entry(key)

	var verb: String = "added" if is_new else "updated"
	return "%s live HUD entry '%s' -> %s" % [verb, key, expr_src]

func _cmd_hide(args: Array) -> String:
	if args.is_empty():
		return _format_error("Usage: live_hide <key|all>")
	var key: String = str(args[0]).strip_edges()
	if key.is_empty():
		return _format_error("live_hide: key cannot be empty")

	if key == "all":
		var count: int = _entries.size()
		for k in _entries.keys():
			_free_entry_label(k)
		_entries.clear()
		_maybe_disconnect_process()
		_maybe_free_overlay()
		return "Removed %d live HUD entry(ies)" % count

	if not _entries.has(key):
		return _format_error("live_hide: no entry '%s'" % key)
	_free_entry_label(key)
	_entries.erase(key)
	_maybe_disconnect_process()
	_maybe_free_overlay()
	return "Removed live HUD entry '%s'" % key

func _cmd_list(_args: Array) -> String:
	if _entries.is_empty():
		return "No live HUD entries. Use live_show <key> <expr> to add one."
	var lines: Array[String] = []
	lines.append("Live HUD entries (%d):" % _entries.size())
	var keys: Array = _entries.keys()
	keys.sort()
	for k in keys:
		var entry: Dictionary = _entries[k]
		var label: Label = entry.get("label", null)
		var current: String = label.text if is_instance_valid(label) else "<freed>"
		var status: String = " [paused]" if bool(entry.get("paused", false)) else ""
		var color_val: Color = entry.get("color", _DEFAULT_COLOR)
		var color_hex: String = color_val.to_html(false)
		var pos: Vector2 = entry.get("position", _DEFAULT_POSITION)
		var size_n: int = int(entry.get("font_size", _DEFAULT_FONT_SIZE))
		lines.append("  %s%s pos=(%d,%d) size=%d color=#%s" % [
			k, status, int(pos.x), int(pos.y), size_n, color_hex
		])
		lines.append("    expr : %s" % str(entry.get("expression_src", "")))
		lines.append("    value: %s" % current)
		var err: String = str(entry.get("last_error", ""))
		if not err.is_empty():
			lines.append("    error: %s" % err)
	return "\n".join(lines)

func _cmd_position(args: Array) -> String:
	if args.size() < 2:
		return _format_error("Usage: live_position <key> <x,y>")
	var key: String = str(args[0]).strip_edges()
	if not _entries.has(key):
		return _format_error("live_position: no entry '%s'" % key)
	var pos_str: String = str(args[1]).strip_edges()
	var parts: PackedStringArray = pos_str.split(",")
	if parts.size() != 2:
		return _format_error("live_position: expected 'x,y' (got '%s')" % pos_str)
	var x_raw: String = String(parts[0]).strip_edges()
	var y_raw: String = String(parts[1]).strip_edges()
	if not x_raw.is_valid_float() or not y_raw.is_valid_float():
		return _format_error("live_position: invalid floats in '%s'" % pos_str)
	var pos: Vector2 = Vector2(x_raw.to_float(), y_raw.to_float())
	var entry: Dictionary = _entries[key]
	entry["position"] = pos
	var label: Label = entry.get("label", null)
	if is_instance_valid(label):
		label.position = pos
	_entries[key] = entry
	return "Moved '%s' to (%s, %s)" % [key, pos.x, pos.y]

func _cmd_color(args: Array) -> String:
	if args.size() < 2:
		return _format_error("Usage: live_color <key> <#hex>")
	var key: String = str(args[0]).strip_edges()
	if not _entries.has(key):
		return _format_error("live_color: no entry '%s'" % key)
	var hex: String = str(args[1])
	var color_val: Color = _parse_color(hex)
	var entry: Dictionary = _entries[key]
	entry["color"] = color_val
	_apply_visuals(entry)
	_entries[key] = entry
	return "Set '%s' font_color to %s" % [key, color_val.to_html()]

func _cmd_font_size(args: Array) -> String:
	if args.size() < 2:
		return _format_error("Usage: live_font_size <key> <n>")
	var key: String = str(args[0]).strip_edges()
	if not _entries.has(key):
		return _format_error("live_font_size: no entry '%s'" % key)
	var n_raw: String = str(args[1]).strip_edges()
	if not n_raw.is_valid_int():
		return _format_error("live_font_size: size must be an integer (got '%s')" % n_raw)
	# Clamp to 4 minimum so a typo (`live_font_size fps 0`) doesn't render an
	# invisible Label the user then can't find to fix.
	var n: int = max(4, int(n_raw))
	var entry: Dictionary = _entries[key]
	entry["font_size"] = n
	_apply_visuals(entry)
	_entries[key] = entry
	return "Set '%s' font_size to %d" % [key, n]

func _cmd_pause(args: Array) -> String:
	if args.is_empty():
		return _format_error("Usage: live_pause <key>")
	var key: String = str(args[0]).strip_edges()
	if not _entries.has(key):
		return _format_error("live_pause: no entry '%s'" % key)
	var entry: Dictionary = _entries[key]
	entry["paused"] = true
	_entries[key] = entry
	return "Paused live HUD entry '%s' (current value frozen)" % key

func _cmd_resume(args: Array) -> String:
	if args.is_empty():
		return _format_error("Usage: live_resume <key>")
	var key: String = str(args[0]).strip_edges()
	if not _entries.has(key):
		return _format_error("live_resume: no entry '%s'" % key)
	var entry: Dictionary = _entries[key]
	entry["paused"] = false
	_entries[key] = entry
	# Pump one evaluation so the Label updates immediately on resume rather
	# than waiting for the next process_frame tick.
	_evaluate_entry(key)
	return "Resumed live HUD entry '%s'" % key

#endregion

#region per-frame loop

func _on_process_frame() -> void:
	# Iterate over keys() (which returns a fresh Array) so we can safely erase
	# stale entries inside the loop without ConcurrentModificationException-
	# style issues.
	var stale: Array[String] = []
	for k in _entries.keys():
		var entry: Dictionary = _entries[k]
		var label = entry.get("label", null)
		if not is_instance_valid(label):
			stale.append(k)
			continue
		if bool(entry.get("paused", false)):
			continue
		_evaluate_entry(k)
	for k in stale:
		_entries.erase(k)
	if _entries.is_empty():
		_maybe_disconnect_process()
		_maybe_free_overlay()

func _evaluate_entry(key: String) -> void:
	if not _entries.has(key):
		return
	var entry: Dictionary = _entries[key]
	var expression: Expression = entry.get("expression", null)
	var label: Label = entry.get("label", null)
	if not expression or not is_instance_valid(label):
		return
	# Base instance = current scene root so users can write expressions like
	# `get_node("Player").position` or `health` that resolve against the
	# loaded scene. Fall back to the SceneTree window root in headless / pre-
	# scene contexts so the expression still has *something* to bind against.
	var tree := Engine.get_main_loop() as SceneTree
	var base: Object = null
	if tree:
		base = tree.current_scene
		if not base:
			base = tree.root
	# show_error=false suppresses per-frame error spam to the Godot log;
	# has_execute_failed() still tells us whether to render an [err] tag.
	var result: Variant = expression.execute([], base, false)
	if expression.has_execute_failed():
		var err_text: String = expression.get_error_text()
		entry["last_error"] = err_text
		label.text = "[err] %s" % err_text
	else:
		entry["last_error"] = ""
		label.text = _stringify(result)
	_entries[key] = entry

func _ensure_process_connected() -> void:
	if _process_connected:
		return
	var tree := Engine.get_main_loop() as SceneTree
	if not tree:
		return
	if not tree.process_frame.is_connected(_on_process_frame):
		tree.process_frame.connect(_on_process_frame)
	_process_connected = true

func _maybe_disconnect_process() -> void:
	if not _process_connected:
		return
	if not _entries.is_empty():
		return
	var tree := Engine.get_main_loop() as SceneTree
	if tree and tree.process_frame.is_connected(_on_process_frame):
		tree.process_frame.disconnect(_on_process_frame)
	_process_connected = false

#endregion

#region helpers

# Lazy-creates the shared overlay CanvasLayer under the current scene root. The
# cached weakref survives most lookups, but a scene reload between commands
# will invalidate it and we transparently re-create.
func _ensure_overlay() -> CanvasLayer:
	if _overlay_ref:
		var cached: Object = _overlay_ref.get_ref()
		if cached and cached is CanvasLayer and is_instance_valid(cached):
			return cached
	var tree := Engine.get_main_loop() as SceneTree
	if not tree:
		return null
	var parent: Node = tree.current_scene
	if not parent:
		parent = tree.root
	var existing: Node = parent.get_node_or_null(NodePath(_OVERLAY_NAME))
	if existing and existing is CanvasLayer and is_instance_valid(existing):
		_overlay_ref = weakref(existing)
		return existing
	var layer: CanvasLayer = CanvasLayer.new()
	layer.name = _OVERLAY_NAME
	layer.layer = _OVERLAY_LAYER_INDEX
	parent.add_child(layer)
	_overlay_ref = weakref(layer)
	return layer

func _maybe_free_overlay() -> void:
	if not _entries.is_empty():
		return
	if not _overlay_ref:
		return
	var cached: Object = _overlay_ref.get_ref()
	if cached and cached is CanvasLayer and is_instance_valid(cached):
		(cached as CanvasLayer).queue_free()
	_overlay_ref = null

func _free_entry_label(key: String) -> void:
	if not _entries.has(key):
		return
	var entry: Dictionary = _entries[key]
	var label = entry.get("label", null)
	if is_instance_valid(label):
		(label as Node).queue_free()

func _apply_visuals(entry: Dictionary) -> void:
	var label: Label = entry.get("label", null)
	if not is_instance_valid(label):
		return
	var color_val: Color = entry.get("color", _DEFAULT_COLOR)
	label.add_theme_color_override("font_color", color_val)
	var size_n: int = int(entry.get("font_size", _DEFAULT_FONT_SIZE))
	label.add_theme_font_size_override("font_size", size_n)
	var pos: Vector2 = entry.get("position", _DEFAULT_POSITION)
	label.position = pos

# Sanitises an arbitrary user-supplied key into a valid Node name suffix. Godot
# rejects '.', ':', '/', '@' and ' ' in node names, so swap them for '_' before
# concatenating. The dictionary key is preserved verbatim - only the Node name
# is normalised, so the user's `live_position my.key 100,100` still resolves.
func _safe_node_suffix(key: String) -> String:
	var s: String = key.replace(".", "_").replace(":", "_").replace("/", "_").replace("@", "_").replace(" ", "_")
	if s.is_empty():
		s = "entry"
	return s

# Converts an expression result to a single-line display string. Floats are
# trimmed to 3 decimals to keep a jittery FPS counter readable; Vectors get a
# compact 2-decimal form. Everything else falls through to Variant.str().
func _stringify(value: Variant) -> String:
	if value == null:
		return "null"
	if typeof(value) == TYPE_FLOAT:
		return "%.3f" % float(value)
	if value is Vector2:
		var v2: Vector2 = value
		return "(%.2f, %.2f)" % [v2.x, v2.y]
	if value is Vector3:
		var v3: Vector3 = value
		return "(%.2f, %.2f, %.2f)" % [v3.x, v3.y, v3.z]
	return str(value)

# Returns true if `s` looks like a color literal: starts with '#' followed by
# 3, 6, or 8 hex digits. Used to decide whether the trailing token of a
# live_show invocation is a color override or part of the expression.
func _looks_like_color_literal(s: String) -> bool:
	if not s.begins_with("#"):
		return false
	var body: String = s.substr(1)
	var n: int = body.length()
	if n != 3 and n != 6 and n != 8:
		return false
	for i in range(body.length()):
		var c: String = body.substr(i, 1).to_lower()
		var is_digit: bool = c >= "0" and c <= "9"
		var is_hex_alpha: bool = c >= "a" and c <= "f"
		if not is_digit and not is_hex_alpha:
			return false
	return true

# Accepts `#RGB`, `#RRGGBB`, `#RRGGBBAA`, and `#AARRGGBB` (Windows-style).
# Mirrors the parser in core/UICommands.gd:469-484 so live_* commands accept
# the same color vocabulary as ui_* commands.
func _parse_color(s: String) -> Color:
	var trimmed: String = s.strip_edges()
	if trimmed.is_empty():
		return _DEFAULT_COLOR
	if not trimmed.begins_with("#"):
		trimmed = "#" + trimmed
	if trimmed.length() == 9:
		var aa: String = trimmed.substr(1, 2)
		var rr: String = trimmed.substr(3, 2)
		var gg: String = trimmed.substr(5, 2)
		var bb: String = trimmed.substr(7, 2)
		var reordered: String = "#" + rr + gg + bb + aa
		return Color.html(reordered) if Color.html_is_valid(reordered) else _DEFAULT_COLOR
	if Color.html_is_valid(trimmed):
		return Color.html(trimmed)
	return _DEFAULT_COLOR

func _format_error(msg: String) -> String:
	return "Error: %s" % msg

#endregion

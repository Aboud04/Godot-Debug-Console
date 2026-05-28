@tool
class_name DebugConsoleScreenNotifierCommands extends RefCounted

# Tier 7 - in-game popup notifications. Inspired by the Panku ScreenNotifier
# module, this extension surfaces transient text in a corner of the viewport
# without forcing the user to wire UI nodes themselves. Two flavors:
#
#   * one-shot   - spawned via `notify`, fades in, holds, fades out, frees
#   * pinned     - spawned via `notify_pin <id>`; persists until unpinned and
#                  updates its existing Label in place when re-called with
#                  the same id (useful for "FPS: 60", "Player HP: 12/20").
#
# Overlay strategy mirrors UICommands.gd: a CanvasLayer is lazily parented to
# the running scene root (or tree.root in headless tests) and cached by
# absolute NodePath string so reference loss across scene reloads is detected
# and self-heals on the next call. A single VBoxContainer inside the layer
# stacks all active labels; corner anchoring is reapplied to the same VBox
# when `notify_position` is invoked so pinned labels survive layout changes.
#
# This module is game-scope only - editor @tool execution would spawn a
# CanvasLayer into the edited scene root and dirty the scene, which is the
# opposite of what a runtime notification system should do.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"

const _OVERLAY_LAYER_NAME := "DebugConsoleNotifier"
const _VBOX_NAME := "NotifyStack"
const _META_PIN_ID := "_dc_notify_pin_id"
const _META_IS_PINNED := "_dc_notify_is_pinned"
const _META_SPAWN_TIME := "_dc_notify_spawn_time"

const _EDGE_MARGIN := 16.0
const _NOTIF_MIN_WIDTH := 320.0
const _FADE_IN_SECS := 0.2
const _FADE_OUT_SECS := 0.4

var _registry: Node
var _core: Node

# Cached absolute paths so we can detect scene reloads (the cached Node would
# dangle) and rebuild on demand. See UICommands.gd:22-24 for the same rationale.
var _overlay_layer_path: String = ""
var _vbox_path: String = ""

# Maps user-supplied pin id -> absolute NodePath string of the Label. We use
# strings rather than Node refs for the same dangling-reference reason.
var _pinned: Dictionary = {}

var _default_corner: String = "tr"
var _default_duration: float = 3.0

const _CORNER_ALIASES: Dictionary = {
	"tl": "tl", "top_left": "tl", "topleft": "tl",
	"tr": "tr", "top_right": "tr", "topright": "tr",
	"bl": "bl", "bottom_left": "bl", "bottomleft": "bl",
	"br": "br", "bottom_right": "br", "bottomright": "br",
	"center": "center", "c": "center", "middle": "center",
}

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("notify", _cmd_notify, "Spawn a fade-in/out popup Label at the default corner: notify <text>", "game")
	_registry.register_command("notify_pin", _cmd_notify_pin, "Pin a resident notification; updates in place if id already pinned: notify_pin <id> <text>", "game")
	_registry.register_command("notify_unpin", _cmd_notify_unpin, "Remove a pinned notification: notify_unpin <id|all>", "game")
	_registry.register_command("notify_clear", _cmd_notify_clear, "Remove every active notification (pinned + one-shot)", "game")
	_registry.register_command("notify_list", _cmd_notify_list, "List active notifications with their kind and remaining lifetime", "game")
	_registry.register_command("notify_position", _cmd_notify_position, "Set default corner: notify_position <tl|tr|bl|br|center>", "game")
	_registry.register_command("notify_duration", _cmd_notify_duration, "Set default visible time for one-shot notifications: notify_duration <secs>", "game")

#region commands

func _cmd_notify(args: Array) -> String:
	var text: String = _join_text(args, 0)
	if text.is_empty():
		return _format_error("Usage: notify <text>")

	var vbox: VBoxContainer = _get_vbox()
	if not vbox:
		return _format_error("notify: no SceneTree available - is the game running?")

	var label: Label = _make_label(text, false, "")
	vbox.add_child(label)
	_animate_one_shot(label, _default_duration)
	return _format_success("notify shown (%s)" % _color_number("%.1fs" % _default_duration))

func _cmd_notify_pin(args: Array) -> String:
	if args.size() < 2:
		return _format_error("Usage: notify_pin <id> <text>")
	var pin_id: String = str(args[0]).strip_edges()
	if pin_id.is_empty():
		return _format_error("notify_pin: id cannot be empty")
	var text: String = _join_text(args, 1)
	if text.is_empty():
		return _format_error("notify_pin: text cannot be empty")

	var vbox: VBoxContainer = _get_vbox()
	if not vbox:
		return _format_error("notify_pin: no SceneTree available - is the game running?")

	var existing: Label = _resolve_pinned_label(pin_id)
	if existing:
		# Update-in-place: refreshing the text reuses the same Label so its
		# position in the stack and any prior styling stays put.
		existing.text = text
		existing.modulate.a = 1.0
		return _format_success("notify_pin updated [%s]" % _color_path(pin_id))

	var label: Label = _make_label(text, true, pin_id)
	vbox.add_child(label)
	_pinned[pin_id] = String(label.get_path())
	# Pinned labels skip the fade-out, but a short fade-in keeps the spawn
	# from being jarring when several are registered in quick succession.
	label.modulate.a = 0.0
	var tween: Tween = label.create_tween()
	if tween:
		tween.tween_property(label, "modulate:a", 1.0, _FADE_IN_SECS)
	else:
		label.modulate.a = 1.0
	return _format_success("notify_pin set [%s]" % _color_path(pin_id))

func _cmd_notify_unpin(args: Array) -> String:
	if args.is_empty():
		return _format_error("Usage: notify_unpin <id|all>")
	var pin_id: String = str(args[0]).strip_edges()
	if pin_id.is_empty():
		return _format_error("notify_unpin: id cannot be empty")

	if pin_id == "all":
		var removed: int = 0
		for id_key in _pinned.keys():
			var lbl: Label = _resolve_pinned_label(String(id_key))
			if lbl:
				lbl.queue_free()
				removed += 1
		_pinned.clear()
		return _format_success("notify_unpin all removed %s" % _color_number(str(removed)))

	if not _pinned.has(pin_id):
		return _format_error("notify_unpin: no pinned notification with id '%s'" % pin_id)
	var label: Label = _resolve_pinned_label(pin_id)
	if label:
		label.queue_free()
	_pinned.erase(pin_id)
	return _format_success("notify_unpin removed [%s]" % _color_path(pin_id))

func _cmd_notify_clear(_args: Array) -> String:
	var vbox: VBoxContainer = _peek_vbox()
	if not vbox:
		_pinned.clear()
		return _format_success("notify_clear: nothing to clear")
	var count: int = 0
	for child in vbox.get_children():
		if child is Label:
			child.queue_free()
			count += 1
	_pinned.clear()
	return _format_success("notify_clear removed %s" % _color_number(str(count)))

func _cmd_notify_list(_args: Array) -> String:
	var vbox: VBoxContainer = _peek_vbox()
	if not vbox:
		return "No active notifications"

	# Pinned ids whose stored path has gone stale (scene reload, manual free)
	# are pruned here so `notify_list` doubles as a reconciliation pass.
	var stale: Array[String] = []
	for id_key in _pinned.keys():
		if not _resolve_pinned_label(String(id_key)):
			stale.append(String(id_key))
	for s in stale:
		_pinned.erase(s)

	var pinned_lines: Array[String] = []
	var oneshot_lines: Array[String] = []
	var now_ms: int = Time.get_ticks_msec()
	for child in vbox.get_children():
		if not (child is Label):
			continue
		var label: Label = child
		var is_pinned: bool = bool(label.get_meta(_META_IS_PINNED, false))
		var preview: String = label.text
		if preview.length() > 60:
			preview = preview.substr(0, 57) + "..."
		if is_pinned:
			var id_meta: String = str(label.get_meta(_META_PIN_ID, ""))
			pinned_lines.append("  [%s] %s" % [_color_path(id_meta), preview])
		else:
			var spawn_ms: int = int(label.get_meta(_META_SPAWN_TIME, now_ms))
			var elapsed: float = float(now_ms - spawn_ms) / 1000.0
			var remaining: float = maxf(0.0, _default_duration - elapsed)
			oneshot_lines.append("  %s %s" % [_color_number("%.1fs" % remaining), preview])

	var total: int = pinned_lines.size() + oneshot_lines.size()
	if total == 0:
		return "No active notifications"
	var out: Array[String] = []
	out.append("Active notifications: %s (corner=%s default=%s)" % [
		_color_number(str(total)),
		_color_path(_default_corner),
		_color_number("%.1fs" % _default_duration),
	])
	if not pinned_lines.is_empty():
		out.append("Pinned (%d):" % pinned_lines.size())
		out.append_array(pinned_lines)
	if not oneshot_lines.is_empty():
		out.append("One-shot (%d):" % oneshot_lines.size())
		out.append_array(oneshot_lines)
	return "\n".join(out)

func _cmd_notify_position(args: Array) -> String:
	if args.is_empty():
		return _format_error("Usage: notify_position <tl|tr|bl|br|center>")
	var raw: String = str(args[0]).strip_edges().to_lower()
	if not _CORNER_ALIASES.has(raw):
		return _format_error("notify_position: unknown corner '%s' (expected tl|tr|bl|br|center)" % raw)
	_default_corner = String(_CORNER_ALIASES[raw])
	# Re-apply on the live VBox so existing pinned labels jump to the new
	# corner immediately; new one-shots inherit the same layout naturally.
	var vbox: VBoxContainer = _peek_vbox()
	if vbox:
		_apply_corner(vbox, _default_corner)
	return _format_success("notify_position set to %s" % _color_path(_default_corner))

func _cmd_notify_duration(args: Array) -> String:
	if args.is_empty():
		return _format_error("Usage: notify_duration <secs>")
	var raw: String = str(args[0]).strip_edges()
	if not (raw.is_valid_float() or raw.is_valid_int()):
		return _format_error("notify_duration: '%s' is not a number" % raw)
	var secs: float = raw.to_float()
	if secs <= 0.0:
		return _format_error("notify_duration: must be > 0")
	_default_duration = secs
	return _format_success("notify_duration set to %s" % _color_number("%.2fs" % secs))

#endregion

#region overlay management

func _get_overlay_layer() -> CanvasLayer:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if not tree:
		return null

	if not _overlay_layer_path.is_empty():
		var cached: Node = tree.root.get_node_or_null(NodePath(_overlay_layer_path))
		if cached and is_instance_valid(cached) and cached is CanvasLayer:
			return cached
		_overlay_layer_path = ""
		_vbox_path = ""
		_pinned.clear()

	var scene_root: Node = tree.current_scene
	if not scene_root:
		scene_root = tree.root

	var existing: Node = scene_root.get_node_or_null(NodePath(_OVERLAY_LAYER_NAME))
	if existing and is_instance_valid(existing) and existing is CanvasLayer:
		_overlay_layer_path = String(existing.get_path())
		return existing

	var layer: CanvasLayer = CanvasLayer.new()
	layer.name = _OVERLAY_LAYER_NAME
	# Layer 100 keeps notifications above most gameplay HUDs without colliding
	# with the debug console itself (which lives on its own much higher layer).
	layer.layer = 100
	scene_root.add_child(layer)
	_overlay_layer_path = String(layer.get_path())
	return layer

# Lazy VBox builder. Always re-applies the current corner so a scene reload
# (which would land us in _make_vbox via _get_overlay_layer's cache miss)
# starts in the user's last chosen layout.
func _get_vbox() -> VBoxContainer:
	var layer: CanvasLayer = _get_overlay_layer()
	if not layer:
		return null

	if not _vbox_path.is_empty():
		var cached: Node = layer.get_tree().root.get_node_or_null(NodePath(_vbox_path))
		if cached and is_instance_valid(cached) and cached is VBoxContainer:
			return cached
		_vbox_path = ""

	var existing: Node = layer.get_node_or_null(NodePath(_VBOX_NAME))
	if existing and is_instance_valid(existing) and existing is VBoxContainer:
		_vbox_path = String(existing.get_path())
		_apply_corner(existing, _default_corner)
		return existing

	var vbox: VBoxContainer = VBoxContainer.new()
	vbox.name = _VBOX_NAME
	# The stack is a passive overlay - it must never eat clicks that belong
	# to gameplay UI underneath it.
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_theme_constant_override("separation", 4)
	layer.add_child(vbox)
	_apply_corner(vbox, _default_corner)
	_vbox_path = String(vbox.get_path())
	return vbox

# Non-creating lookup used by clear/list/position so we don't spawn a layer
# just to discover there's nothing to act on.
func _peek_vbox() -> VBoxContainer:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if not tree:
		return null
	if _vbox_path.is_empty():
		return null
	var cached: Node = tree.root.get_node_or_null(NodePath(_vbox_path))
	if cached and is_instance_valid(cached) and cached is VBoxContainer:
		return cached
	_vbox_path = ""
	return null

# Anchors + grow direction per corner. PRESET_* alone sets anchors but leaves
# offsets and grow direction at their defaults, which would make a zero-sized
# VBox invisible. We pin the box to its corner with a small edge margin and
# tell it to grow inward (BEGIN for right/bottom, END for left/top) so each
# new Label expands the stack toward the screen center.
func _apply_corner(vbox: VBoxContainer, corner: String) -> void:
	var label_align: int = HORIZONTAL_ALIGNMENT_LEFT
	match corner:
		"tl":
			vbox.set_anchors_preset(Control.PRESET_TOP_LEFT)
			vbox.offset_left = _EDGE_MARGIN
			vbox.offset_top = _EDGE_MARGIN
			vbox.offset_right = _EDGE_MARGIN
			vbox.offset_bottom = _EDGE_MARGIN
			vbox.grow_horizontal = Control.GROW_DIRECTION_END
			vbox.grow_vertical = Control.GROW_DIRECTION_END
			label_align = HORIZONTAL_ALIGNMENT_LEFT
		"tr":
			vbox.set_anchors_preset(Control.PRESET_TOP_RIGHT)
			vbox.offset_left = -_EDGE_MARGIN
			vbox.offset_top = _EDGE_MARGIN
			vbox.offset_right = -_EDGE_MARGIN
			vbox.offset_bottom = _EDGE_MARGIN
			vbox.grow_horizontal = Control.GROW_DIRECTION_BEGIN
			vbox.grow_vertical = Control.GROW_DIRECTION_END
			label_align = HORIZONTAL_ALIGNMENT_RIGHT
		"bl":
			vbox.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
			vbox.offset_left = _EDGE_MARGIN
			vbox.offset_top = -_EDGE_MARGIN
			vbox.offset_right = _EDGE_MARGIN
			vbox.offset_bottom = -_EDGE_MARGIN
			vbox.grow_horizontal = Control.GROW_DIRECTION_END
			vbox.grow_vertical = Control.GROW_DIRECTION_BEGIN
			label_align = HORIZONTAL_ALIGNMENT_LEFT
		"br":
			vbox.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
			vbox.offset_left = -_EDGE_MARGIN
			vbox.offset_top = -_EDGE_MARGIN
			vbox.offset_right = -_EDGE_MARGIN
			vbox.offset_bottom = -_EDGE_MARGIN
			vbox.grow_horizontal = Control.GROW_DIRECTION_BEGIN
			vbox.grow_vertical = Control.GROW_DIRECTION_BEGIN
			label_align = HORIZONTAL_ALIGNMENT_RIGHT
		_:
			vbox.set_anchors_preset(Control.PRESET_CENTER)
			vbox.offset_left = 0
			vbox.offset_top = 0
			vbox.offset_right = 0
			vbox.offset_bottom = 0
			vbox.grow_horizontal = Control.GROW_DIRECTION_BOTH
			vbox.grow_vertical = Control.GROW_DIRECTION_BOTH
			label_align = HORIZONTAL_ALIGNMENT_CENTER

	vbox.custom_minimum_size = Vector2(_NOTIF_MIN_WIDTH, 0)

	# Re-align every existing Label child so a mid-session corner change does
	# not leave pinned notifications with stale (e.g. left-aligned) text.
	for child in vbox.get_children():
		if child is Label:
			(child as Label).horizontal_alignment = label_align

#endregion

#region label construction & animation

func _make_label(text: String, is_pinned: bool, pin_id: String) -> Label:
	var label: Label = Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.horizontal_alignment = _alignment_for_corner(_default_corner)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_color_override("font_color", Color(1, 1, 1, 1))
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	label.add_theme_constant_override("outline_size", 4)
	label.set_meta(_META_IS_PINNED, is_pinned)
	label.set_meta(_META_PIN_ID, pin_id)
	label.set_meta(_META_SPAWN_TIME, Time.get_ticks_msec())
	return label

# One-shot lifecycle: fade-in -> hold -> fade-out -> queue_free. The total
# on-screen time matches `duration` (fade-out eats into the tail so the
# command's reported duration stays truthful).
func _animate_one_shot(label: Label, duration: float) -> void:
	label.modulate.a = 0.0
	var tween: Tween = label.create_tween()
	if not tween:
		# Without a Tween the fade can't run; degrade to instant show + Timer
		# free so the label still disappears on schedule rather than leaking.
		label.modulate.a = 1.0
		var tree: SceneTree = label.get_tree()
		if tree:
			tree.create_timer(duration).timeout.connect(func(): if is_instance_valid(label): label.queue_free())
		return

	var hold: float = maxf(0.0, duration - _FADE_IN_SECS - _FADE_OUT_SECS)
	tween.tween_property(label, "modulate:a", 1.0, _FADE_IN_SECS)
	if hold > 0.0:
		tween.tween_interval(hold)
	tween.tween_property(label, "modulate:a", 0.0, _FADE_OUT_SECS)
	tween.tween_callback(label.queue_free)

func _alignment_for_corner(corner: String) -> int:
	match corner:
		"tr", "br":
			return HORIZONTAL_ALIGNMENT_RIGHT
		"center":
			return HORIZONTAL_ALIGNMENT_CENTER
		_:
			return HORIZONTAL_ALIGNMENT_LEFT

func _resolve_pinned_label(pin_id: String) -> Label:
	if not _pinned.has(pin_id):
		return null
	var path: String = String(_pinned[pin_id])
	if path.is_empty():
		return null
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if not tree:
		return null
	var node: Node = tree.root.get_node_or_null(NodePath(path))
	if node and is_instance_valid(node) and node is Label:
		return node
	# Stale entry - the underlying Label is gone (scene reload, manual free).
	# Drop it so a future `notify_pin <same id>` recreates cleanly.
	_pinned.erase(pin_id)
	return null

#endregion

#region formatting + arg helpers

# Joins args[start..] back into a single text string. CommandRegistry splits
# tokens on whitespace, so quoted phrases (handled by the registry's quoting
# rules) arrive as a single arg while unquoted phrases arrive as many - join
# with spaces and strip surrounding quotes for symmetry with both forms.
func _join_text(args: Array, start: int) -> String:
	if start >= args.size():
		return ""
	var parts: Array[String] = []
	for i in range(start, args.size()):
		parts.append(str(args[i]))
	var joined: String = " ".join(parts).strip_edges()
	if joined.length() >= 2 and ((joined.begins_with("\"") and joined.ends_with("\"")) or (joined.begins_with("'") and joined.ends_with("'"))):
		joined = joined.substr(1, joined.length() - 2)
	return joined

func _format_error(msg: String) -> String:
	return "[color=%s]Error:[/color] %s" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

#endregion

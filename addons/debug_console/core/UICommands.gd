@tool
class_name DebugConsoleUICommands extends RefCounted

# Declarative UI builder commands. Each command spawns a Control
# node (PanelContainer, Label, Button, etc) under a target parent at runtime.
# The parent defaults to the scene root's CanvasLayer if one exists; otherwise
# a new CanvasLayer named "DebugConsoleUI" is created lazily as a child of
# the current scene root. This keeps user-built UI overlay-safe and prevents
# it from being clipped by 3D viewport rendering.
#
# Quoting: command tokens are split on whitespace by CommandRegistry. To pass
# a value with spaces (e.g. a Label's text), wrap it in double quotes and the
# module joins the tokens back together before processing.

const _DC_COLOR_PATH := "#5FBEE0"
const _OVERLAY_LAYER_NAME := "DebugConsoleUI"

var _registry: Node
var _core: Node

# Lazy-created overlay layer for ui_* commands when no explicit parent is given.
# Stored as an absolute node path string rather than a Node reference because a
# Node reference would dangle if the user reloaded the scene mid-session.
var _overlay_layer_path: String = ""

# Maps the human-readable preset string accepted by `ui_layout` to the matching
# Control.PRESET_* enum value. Keeping this as a constant dictionary avoids a
# growing if/elif chain and makes the accepted vocabulary self-documenting.
const _PRESET_MAP: Dictionary = {
	"top_left": Control.PRESET_TOP_LEFT,
	"top_right": Control.PRESET_TOP_RIGHT,
	"bottom_left": Control.PRESET_BOTTOM_LEFT,
	"bottom_right": Control.PRESET_BOTTOM_RIGHT,
	"center_left": Control.PRESET_CENTER_LEFT,
	"center_top": Control.PRESET_CENTER_TOP,
	"center_right": Control.PRESET_CENTER_RIGHT,
	"center_bottom": Control.PRESET_CENTER_BOTTOM,
	"center": Control.PRESET_CENTER,
	"left_wide": Control.PRESET_LEFT_WIDE,
	"top_wide": Control.PRESET_TOP_WIDE,
	"right_wide": Control.PRESET_RIGHT_WIDE,
	"bottom_wide": Control.PRESET_BOTTOM_WIDE,
	"vcenter_wide": Control.PRESET_VCENTER_WIDE,
	"hcenter_wide": Control.PRESET_HCENTER_WIDE,
	"full_rect": Control.PRESET_FULL_RECT,
}

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("ui_panel", _cmd_ui_panel, "Spawn a PanelContainer: ui_panel <name> [parent_path] [WxH] [#bg]", "both")
	_registry.register_command("ui_label", _cmd_ui_label, "Spawn a Label: ui_label <text|\"text with spaces\"> [parent_path] [name]", "both")
	_registry.register_command("ui_button", _cmd_ui_button, "Spawn a Button: ui_button <text> [parent_path] [name] [<node_path>.<method>]", "both")
	_registry.register_command("ui_vbox", _cmd_ui_vbox, "Spawn a VBoxContainer: ui_vbox [parent_path] [name]", "both")
	_registry.register_command("ui_hbox", _cmd_ui_hbox, "Spawn an HBoxContainer: ui_hbox [parent_path] [name]", "both")
	_registry.register_command("ui_grid", _cmd_ui_grid, "Spawn a GridContainer: ui_grid <columns> [parent_path] [name]", "both")
	_registry.register_command("ui_layout", _cmd_ui_layout, "Apply layout preset: ui_layout <path> <top_left|center|full_rect|...>", "both")
	_registry.register_command("ui_text_color", _cmd_ui_text_color, "Set font color on Label/Button/RichTextLabel: ui_text_color <path> <#hex>", "both")
	_registry.register_command("ui_size", _cmd_ui_size, "Set custom_minimum_size: ui_size <path> <WxH>", "both")
	_registry.register_command("ui_anchor", _cmd_ui_anchor, "Set anchors: ui_anchor <path> <left,top,right,bottom> (0.0-1.0 each)", "both")
	_registry.register_command("ui_clear", _cmd_ui_clear, "Remove all children of a Control: ui_clear [parent_path]", "both")
	_registry.register_command("ui_dump", _cmd_ui_dump, "ASCII tree of Controls under a node: ui_dump [root_path]", "both")
	_registry.register_command("ui_modal", _cmd_ui_modal, "Wrap a Control in a fullscreen modal backdrop: ui_modal <child_path>", "both")

#region commands

func _cmd_ui_panel(args: Array) -> String:
	var parsed: Array = _parse_args(args)
	if parsed.is_empty():
		return _format_error("Usage: ui_panel <name> [parent_path] [WxH] [#bg]")

	var panel_name: String = str(parsed[0]).strip_edges()
	if panel_name.is_empty():
		return _format_error("ui_panel: name cannot be empty")

	var parent_path: String = ""
	var size_str: String = ""
	var bg_str: String = ""
	# Optional args are positional but unambiguous by prefix: "#" → color,
	# `\d+x\d+` → size, anything else → parent_path. This lets the user
	# write `ui_panel P #FF0000` without supplying parent_path/size.
	for i in range(1, parsed.size()):
		var token: String = str(parsed[i]).strip_edges()
		if token.is_empty():
			continue
		if token.begins_with("#"):
			bg_str = token
		elif _looks_like_size(token):
			size_str = token
		else:
			parent_path = token

	var parent: Node = _resolve_parent_string(parent_path)
	if not parent:
		return _format_error("ui_panel: cannot resolve parent '%s'" % parent_path)

	var panel: PanelContainer = PanelContainer.new()
	panel.name = panel_name
	parent.add_child(panel)

	if not size_str.is_empty():
		var sz: Vector2 = _parse_size(size_str)
		if sz != Vector2.ZERO:
			panel.custom_minimum_size = sz

	if not bg_str.is_empty():
		var color_val: Color = _parse_color(bg_str)
		var sb: StyleBoxFlat = StyleBoxFlat.new()
		sb.bg_color = color_val
		panel.add_theme_stylebox_override("panel", sb)

	return _format_path(panel)

func _cmd_ui_label(args: Array) -> String:
	var parsed: Array = _parse_args(args)
	if parsed.is_empty():
		return _format_error("Usage: ui_label <text> [parent_path] [name]")

	var text: String = str(parsed[0])
	var parent_path: String = str(parsed[1]) if parsed.size() > 1 else ""
	var explicit_name: String = str(parsed[2]) if parsed.size() > 2 else ""

	var parent: Node = _resolve_parent_string(parent_path)
	if not parent:
		return _format_error("ui_label: cannot resolve parent '%s'" % parent_path)

	var label: Label = Label.new()
	label.name = explicit_name if not explicit_name.is_empty() else _auto_name(parent, "Label")
	label.text = text
	parent.add_child(label)
	return _format_path(label)

func _cmd_ui_button(args: Array) -> String:
	var parsed: Array = _parse_args(args)
	if parsed.is_empty():
		return _format_error("Usage: ui_button <text> [parent_path] [name] [<node_path>.<method>]")

	var text: String = str(parsed[0])
	var parent_path: String = str(parsed[1]) if parsed.size() > 1 else ""
	var explicit_name: String = str(parsed[2]) if parsed.size() > 2 else ""
	var callback: String = str(parsed[3]) if parsed.size() > 3 else ""

	var parent: Node = _resolve_parent_string(parent_path)
	if not parent:
		return _format_error("ui_button: cannot resolve parent '%s'" % parent_path)

	var btn: Button = Button.new()
	btn.name = explicit_name if not explicit_name.is_empty() else _auto_name(parent, "Button")
	btn.text = text
	parent.add_child(btn)

	var callback_info: String = ""
	if not callback.is_empty():
		var dot: int = callback.rfind(".")
		if dot <= 0 or dot >= callback.length() - 1:
			return _format_error("ui_button: callback must be '<node_path>.<method>' (got '%s')" % callback)
		var cb_path: String = callback.substr(0, dot)
		var cb_method: String = callback.substr(dot + 1)
		var target: Node = _resolve_node(cb_path)
		if not target:
			return _format_error("ui_button: callback target not found: %s" % cb_path)
		if not target.has_method(cb_method):
			return _format_error("ui_button: callback method '%s' not found on %s" % [cb_method, cb_path])
		btn.pressed.connect(Callable(target, cb_method))
		callback_info = " (pressed -> %s.%s)" % [cb_path, cb_method]

	return _format_path(btn) + callback_info

func _cmd_ui_vbox(args: Array) -> String:
	return _spawn_container(args, "ui_vbox", "VBox", func(): return VBoxContainer.new())

func _cmd_ui_hbox(args: Array) -> String:
	return _spawn_container(args, "ui_hbox", "HBox", func(): return HBoxContainer.new())

func _cmd_ui_grid(args: Array) -> String:
	var parsed: Array = _parse_args(args)
	if parsed.is_empty():
		return _format_error("Usage: ui_grid <columns> [parent_path] [name]")

	var cols_raw: String = str(parsed[0]).strip_edges()
	if not cols_raw.is_valid_int():
		return _format_error("ui_grid: columns must be an integer (got '%s')" % cols_raw)
	var cols: int = max(1, int(cols_raw))

	var parent_path: String = str(parsed[1]) if parsed.size() > 1 else ""
	var explicit_name: String = str(parsed[2]) if parsed.size() > 2 else ""

	var parent: Node = _resolve_parent_string(parent_path)
	if not parent:
		return _format_error("ui_grid: cannot resolve parent '%s'" % parent_path)

	var grid: GridContainer = GridContainer.new()
	grid.name = explicit_name if not explicit_name.is_empty() else _auto_name(parent, "Grid")
	grid.columns = cols
	parent.add_child(grid)
	return _format_path(grid)

func _cmd_ui_layout(args: Array) -> String:
	if args.size() < 2:
		return _format_error("Usage: ui_layout <path> <preset>")
	var path: String = str(args[0])
	var preset_name: String = str(args[1]).strip_edges().to_lower()
	if not _PRESET_MAP.has(preset_name):
		var keys: Array = _PRESET_MAP.keys()
		keys.sort()
		return _format_error("ui_layout: unknown preset '%s'. Valid: %s" % [preset_name, ", ".join(keys)])

	var control: Control = _resolve_control(path)
	if not control:
		return _format_error("ui_layout: Control not found: %s" % path)

	var preset_val: int = int(_PRESET_MAP[preset_name])
	control.set_anchors_and_offsets_preset(preset_val)
	return "Applied preset '%s' to %s" % [preset_name, _format_path(control)]

func _cmd_ui_text_color(args: Array) -> String:
	if args.size() < 2:
		return _format_error("Usage: ui_text_color <path> <#hex>")
	var path: String = str(args[0])
	var hex: String = str(args[1])
	var control: Control = _resolve_control(path)
	if not control:
		return _format_error("ui_text_color: Control not found: %s" % path)

	var color_val: Color = _parse_color(hex)
	# Button has multiple state-specific font color overrides; setting only
	# `font_color` leaves hover/pressed visually unchanged. Mirror the same
	# color across all three so the user sees a consistent visual change.
	if control is Button:
		control.add_theme_color_override("font_color", color_val)
		control.add_theme_color_override("font_hover_color", color_val)
		control.add_theme_color_override("font_pressed_color", color_val)
	else:
		control.add_theme_color_override("font_color", color_val)
	return "Set font_color on %s to %s" % [_format_path(control), color_val.to_html()]

func _cmd_ui_size(args: Array) -> String:
	if args.size() < 2:
		return _format_error("Usage: ui_size <path> <WxH>")
	var path: String = str(args[0])
	var size_str: String = str(args[1])
	var control: Control = _resolve_control(path)
	if not control:
		return _format_error("ui_size: Control not found: %s" % path)
	if not _looks_like_size(size_str):
		return _format_error("ui_size: size must be WxH (got '%s')" % size_str)
	var sz: Vector2 = _parse_size(size_str)
	control.custom_minimum_size = sz
	return "Set custom_minimum_size on %s to %s" % [_format_path(control), str(sz)]

func _cmd_ui_anchor(args: Array) -> String:
	if args.size() < 2:
		return _format_error("Usage: ui_anchor <path> <left,top,right,bottom>")
	var path: String = str(args[0])
	var anchor_str: String = str(args[1])
	var control: Control = _resolve_control(path)
	if not control:
		return _format_error("ui_anchor: Control not found: %s" % path)

	var parts: PackedStringArray = anchor_str.split(",")
	if parts.size() != 4:
		return _format_error("ui_anchor: expected 4 comma-separated floats (got %d)" % parts.size())
	var vals: Array[float] = []
	for p in parts:
		var trimmed: String = String(p).strip_edges()
		if not trimmed.is_valid_float():
			return _format_error("ui_anchor: invalid float '%s'" % trimmed)
		vals.append(clampf(trimmed.to_float(), 0.0, 1.0))

	control.anchor_left = vals[0]
	control.anchor_top = vals[1]
	control.anchor_right = vals[2]
	control.anchor_bottom = vals[3]
	# Zero the offsets so the anchor values actually take effect; otherwise
	# pre-existing offsets keep the control glued to its old position.
	control.offset_left = 0.0
	control.offset_top = 0.0
	control.offset_right = 0.0
	control.offset_bottom = 0.0
	return "Set anchors on %s to (%s, %s, %s, %s)" % [
		_format_path(control), vals[0], vals[1], vals[2], vals[3]
	]

func _cmd_ui_clear(args: Array) -> String:
	var parent_path: String = str(args[0]) if args.size() > 0 else ""
	var parent: Node = _resolve_parent_string(parent_path)
	if not parent:
		return _format_error("ui_clear: cannot resolve parent '%s'" % parent_path)

	# Hard guardrails. Clearing /root would nuke the entire engine state and
	# clearing the current scene root would wipe the user's game. Either is
	# almost certainly a typo, so refuse and tell the user what happened.
	var tree := Engine.get_main_loop() as SceneTree
	if tree:
		if parent == tree.root:
			return _format_error("ui_clear: refusing to clear /root")
		if tree.current_scene and parent == tree.current_scene:
			return _format_error("ui_clear: refusing to clear current scene root %s" % str(parent.get_path()))

	var children: Array = parent.get_children()
	for child in children:
		if is_instance_valid(child):
			child.queue_free()
	return "Removed %d child(ren) from %s" % [children.size(), _format_path(parent)]

func _cmd_ui_dump(args: Array) -> String:
	var root_path: String = str(args[0]) if args.size() > 0 else ""
	var root_node: Node = _resolve_parent_string(root_path)
	if not root_node:
		return _format_error("ui_dump: cannot resolve root '%s'" % root_path)

	var lines: Array[String] = []
	lines.append("%s [%s]" % [_format_path(root_node), root_node.get_class()])
	_build_ui_dump_lines(root_node, "", true, lines, true)
	return "\n".join(lines)

func _cmd_ui_modal(args: Array) -> String:
	if args.is_empty():
		return _format_error("Usage: ui_modal <child_path>")
	var child_path: String = str(args[0])
	var child: Control = _resolve_control(child_path)
	if not child:
		return _format_error("ui_modal: Control not found: %s" % child_path)

	var tree := Engine.get_main_loop() as SceneTree
	if not tree:
		return _format_error("ui_modal: no SceneTree available")

	# Wrapper is a ColorRect because it both renders the dim backdrop and
	# accepts mouse_filter=STOP, which swallows clicks that miss the modal
	# content. Using two separate nodes (Panel + Control overlay) would
	# require extra wiring without buying anything.
	var wrapper: ColorRect = ColorRect.new()
	wrapper.color = Color(0, 0, 0, 0.6)
	wrapper.mouse_filter = Control.MOUSE_FILTER_STOP
	wrapper.name = "Modal_%d" % Time.get_ticks_msec()
	tree.root.add_child(wrapper)
	wrapper.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var old_parent: Node = child.get_parent()
	if old_parent:
		old_parent.remove_child(child)
	wrapper.add_child(child)
	# Re-center the child inside the modal. set_anchors_and_offsets_preset
	# with PRESET_CENTER places the control at the middle of its parent and
	# preserves its current size.
	child.set_anchors_and_offsets_preset(Control.PRESET_CENTER, Control.PRESET_MODE_KEEP_SIZE)
	return _format_path(wrapper)

#endregion

#region helpers

# Joins tokens that were split across a quoted span. CommandRegistry splits on
# whitespace, so `ui_label "Hello World"` arrives as ['"Hello', 'World"']. This
# walks the array, glues quoted spans back together, and strips the quote chars.
# Single-token strings are passed through untouched.
func _parse_args(args: Array) -> Array:
	var result: Array = []
	var i: int = 0
	while i < args.size():
		var token: String = str(args[i])
		if token.begins_with("\""):
			if token.length() >= 2 and token.ends_with("\""):
				result.append(token.substr(1, token.length() - 2))
				i += 1
				continue
			var collected: String = token.substr(1)
			var j: int = i + 1
			while j < args.size():
				var next_token: String = str(args[j])
				if next_token.ends_with("\""):
					collected += " " + next_token.substr(0, next_token.length() - 1)
					j += 1
					break
				collected += " " + next_token
				j += 1
			result.append(collected)
			i = j
		else:
			result.append(token)
			i += 1
	return result

# Returns the Control to use when no parent_path is supplied. Lazy-creates
# `DebugConsoleUI` under the current scene root (runtime) or the edited scene
# root (editor). Falls back to tree.root only if no scene root exists, which
# should be rare outside of headless test setups.
func _get_overlay_layer() -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if not tree:
		return null

	if not _overlay_layer_path.is_empty():
		var cached := tree.root.get_node_or_null(NodePath(_overlay_layer_path))
		if cached and is_instance_valid(cached):
			return cached
		_overlay_layer_path = ""

	# In runtime `tree.current_scene` is the loaded scene root. In editor @tool
	# context it may be null (the editor doesn't expose EditorInterface as an
	# Engine singleton in Godot 4 - it's gated behind EditorPlugin), so fall
	# back to tree.root. A CanvasLayer parented to the Window root still
	# overlays correctly; the user can always supply an explicit parent_path.
	var scene_root: Node = tree.current_scene
	if not scene_root:
		scene_root = tree.root

	var existing: Node = scene_root.get_node_or_null(NodePath(_OVERLAY_LAYER_NAME))
	if existing and is_instance_valid(existing):
		_overlay_layer_path = String(existing.get_path())
		return existing

	var layer: CanvasLayer = CanvasLayer.new()
	layer.name = _OVERLAY_LAYER_NAME
	scene_root.add_child(layer)
	_overlay_layer_path = String(layer.get_path())
	return layer

# Resolves a parent argument. Empty string = overlay layer. Non-empty string
# is looked up as an absolute path then by find_child fallback.
func _resolve_parent_string(parent_path: String) -> Node:
	var trimmed: String = parent_path.strip_edges()
	if trimmed.is_empty():
		return _get_overlay_layer()
	return _resolve_node(trimmed)

# Generic node resolver. Tries absolute path first, then a tree-wide find_child
# search by literal name (mirrors how `_cmd_scene_tree` resolves targets in
# BuiltInCommands.gd:1813-1815 so users get consistent lookup semantics).
func _resolve_node(path: String) -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if not tree:
		return null
	var trimmed: String = path.strip_edges()
	if trimmed.is_empty():
		return null
	var n: Node = tree.root.get_node_or_null(NodePath(trimmed))
	if n:
		return n
	if not trimmed.begins_with("/"):
		n = tree.root.find_child(trimmed, true, false)
	return n

# Convenience cast - returns null (not a Node-shaped value) when the resolved
# node exists but isn't a Control. Callers can distinguish "missing" from
# "wrong type" by re-resolving with _resolve_node when needed.
func _resolve_control(path: String) -> Control:
	var n: Node = _resolve_node(path)
	if n is Control:
		return n
	return null

func _parse_size(s: String) -> Vector2:
	var parts: PackedStringArray = s.split("x")
	if parts.size() != 2:
		return Vector2.ZERO
	var w: String = String(parts[0]).strip_edges()
	var h: String = String(parts[1]).strip_edges()
	if not w.is_valid_float() or not h.is_valid_float():
		return Vector2.ZERO
	return Vector2(w.to_float(), h.to_float())

# Accepts `#RRGGBB`, `#RRGGBBAA`, and `#AARRGGBB` (Windows-style). For
# 8-hex-digit input we manually re-order to RRGGBBAA before handing off to
# Color.html() since Godot's parser uses RGBA, not ARGB.
func _parse_color(s: String) -> Color:
	var trimmed: String = s.strip_edges()
	if trimmed.is_empty():
		return Color.WHITE
	if not trimmed.begins_with("#"):
		trimmed = "#" + trimmed
	if trimmed.length() == 9:
		var aa: String = trimmed.substr(1, 2)
		var rr: String = trimmed.substr(3, 2)
		var gg: String = trimmed.substr(5, 2)
		var bb: String = trimmed.substr(7, 2)
		var reordered: String = "#" + rr + gg + bb + aa
		return Color.html(reordered) if Color.html_is_valid(reordered) else Color.WHITE
	if Color.html_is_valid(trimmed):
		return Color.html(trimmed)
	return Color.WHITE

func _format_error(msg: String) -> String:
	return "Error: %s" % msg

# Returns the next free `<prefix>_N` name under parent. N starts at 0 and walks
# upward until an unused suffix is found. Keeps generated names predictable and
# easy to reference from follow-up commands.
func _auto_name(parent: Node, prefix: String) -> String:
	if not parent:
		return prefix + "_0"
	var n: int = 0
	while parent.has_node(NodePath("%s_%d" % [prefix, n])):
		n += 1
	return "%s_%d" % [prefix, n]

func _format_path(node: Node) -> String:
	if not node:
		return ""
	return "[color=%s]%s[/color]" % [_DC_COLOR_PATH, str(node.get_path())]

func _looks_like_size(s: String) -> bool:
	var parts: PackedStringArray = s.split("x")
	if parts.size() != 2:
		return false
	return String(parts[0]).strip_edges().is_valid_float() and String(parts[1]).strip_edges().is_valid_float()

# Shared body for ui_vbox / ui_hbox so the two commands stay in lockstep when
# adding new defaults. Accepts a factory Callable so the caller picks the
# container class without branching here.
func _spawn_container(args: Array, cmd_label: String, prefix: String, factory: Callable) -> String:
	var parsed: Array = _parse_args(args)
	var parent_path: String = str(parsed[0]) if parsed.size() > 0 else ""
	var explicit_name: String = str(parsed[1]) if parsed.size() > 1 else ""

	var parent: Node = _resolve_parent_string(parent_path)
	if not parent:
		return _format_error("%s: cannot resolve parent '%s'" % [cmd_label, parent_path])

	var node: Node = factory.call()
	if not node:
		return _format_error("%s: factory returned null" % cmd_label)
	node.name = explicit_name if not explicit_name.is_empty() else _auto_name(parent, prefix)
	parent.add_child(node)
	return _format_path(node)

# Walks Control descendants and emits ASCII tree lines mirroring scene_tree's
# format (BuiltInCommands.gd:1823-1840). Adds rect (size+position) and visible
# flag so users can spot off-screen or hidden Controls at a glance.
func _build_ui_dump_lines(node: Node, prefix: String, _is_last: bool, output: Array[String], is_root: bool) -> void:
	if not is_root and node is Control:
		var ctrl: Control = node
		var rect_str: String = "size=%s pos=%s" % [str(ctrl.size), str(ctrl.position)]
		var vis: String = "" if ctrl.visible else " [hidden]"
		output[output.size() - 1] += "  (%s)%s" % [rect_str, vis]
	var children: Array = node.get_children()
	for i in range(children.size()):
		var child: Node = children[i]
		var is_last_child: bool = (i == children.size() - 1)
		var branch: String = "└─ " if is_last_child else "├─ "
		var line: String = "%s%s[%s] %s" % [prefix, branch, child.get_class(), child.name]
		output.append(line)
		var next_prefix: String = prefix + ("   " if is_last_child else "│  ")
		_build_ui_dump_lines(child, next_prefix, is_last_child, output, false)

#endregion

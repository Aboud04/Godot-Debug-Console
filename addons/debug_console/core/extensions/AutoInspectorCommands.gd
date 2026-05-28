@tool
class_name DebugConsoleAutoInspectorCommands extends RefCounted

# Extension module: auto-spawning Data Controller panels (Panku-style). Mirrors
# the SceneCommands shape - the orchestrator instantiates this RefCounted,
# holds a strong reference, and calls register_commands(registry, core). All
# Callables are bound to this instance so the lifetime matches the plugin.
#
# An "inspector" is a floating PanelContainer attached to the running scene
# (or to /root for pinned panels) that introspects an Object's property_list,
# filters to @export properties (PROPERTY_USAGE_EDITOR + STORAGE), and builds
# type-appropriate widgets that read/write the underlying node bidirectionally:
#
#   bool        -> CheckBox
#   int/float   -> SpinBox  (HSlider when the property has a @export_range hint)
#   String      -> LineEdit
#   Color       -> ColorPickerButton
#   Vector2/3   -> 2/3 SpinBoxes laid out in an HBoxContainer
#   enum        -> OptionButton (PROPERTY_HINT_ENUM)
#
# Widget -> node propagation goes through node.set(prop_name, new_value). The
# reverse direction (node -> widget) only runs on `inspector_refresh` to avoid
# the per-frame polling cost of a full Object scan; users can wire a Timer or
# the existing watchpoint commands if they need continuous sync.
#
# Panels are tracked in `_panels` keyed by the canonical path string the caller
# used to open them. The same Dictionary is the source of truth for
# inspector_list, inspector_close, inspector_pin, etc. - which means a panel
# that has been freed by a scene change (and is not pinned) still has an entry
# until the next command runs, so every accessor validates is_instance_valid()
# before touching the panel.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_WARN := "#F5B041"

const _DEFAULT_SIZE := Vector2(300, 400)
const _BG_COLOR := Color(0.12, 0.12, 0.14, 0.96)
const _HEADER_COLOR := Color(0.18, 0.18, 0.22, 1.0)
const _FONT_COLOR := Color(0.88, 0.88, 0.92, 1.0)
const _LABEL_COLOR := Color(0.70, 0.80, 0.95, 1.0)
const _MARGIN := 6

const _SCENE_LAYER_NAME := "DebugConsoleInspectors"
const _PINNED_LAYER_NAME := "DebugConsoleInspectorsPinned"

const _CORNER_MAP := {
	"tl": Vector2(0, 0),
	"tr": Vector2(1, 0),
	"bl": Vector2(0, 1),
	"br": Vector2(1, 1),
}

var _registry: Node
var _core: Node

# Entries: {
#   "panel": PanelContainer,           floating root we add to a CanvasLayer
#   "node_ref": WeakRef,               weak ref so freeing the target doesn't pin it
#   "node_path": String,               the path the user originally typed
#   "pinned": bool,                    survives scene changes when true
#   "minimized": bool,                 content_container hidden when true
#   "content": VBoxContainer,          holds property rows
#   "header": HBoxContainer,           title + min/close buttons
#   "title": Label,                    "<Node> [<class>]"
#   "rows": Dictionary,                prop_name -> Control (the row container)
#   "widgets": Dictionary,             prop_name -> { "widget": Control, "type": int, "prop": Dictionary }
#   "filter": String,                  current visibility filter pattern
# }
var _panels: Dictionary = {}


func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("inspector_open", _cmd_inspector_open, "Open a Data Controller inspector for a node: inspector_open <node_path>", "game")
	_registry.register_command("inspector_close", _cmd_inspector_close, "Close an inspector or all: inspector_close <node_path|all>", "game")
	_registry.register_command("inspector_pin", _cmd_inspector_pin, "Pin inspector so it survives scene changes: inspector_pin <node_path>", "game")
	_registry.register_command("inspector_list", _cmd_inspector_list, "List active inspector panels: inspector_list", "game")
	_registry.register_command("inspector_refresh", _cmd_inspector_refresh, "Re-read property values into widgets: inspector_refresh <node_path>", "game")
	_registry.register_command("inspector_filter", _cmd_inspector_filter, "Hide rows whose property name doesn't match: inspector_filter <node_path> <pattern>", "game")
	_registry.register_command("inspector_minimize", _cmd_inspector_minimize, "Toggle inspector minimized state: inspector_minimize <node_path>", "game")
	_registry.register_command("inspector_dock", _cmd_inspector_dock, "Move inspector panel to a screen corner: inspector_dock <node_path> <tl|tr|bl|br>", "game")

#region commands

func _cmd_inspector_open(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: inspector_open <node_path>")
	var path: String = " ".join(args).strip_edges()
	var node: Node = _resolve_node(path)
	if not node:
		return _format_error("Node not found: %s" % path)

	if _panels.has(path):
		var existing: Dictionary = _panels[path]
		if is_instance_valid(existing.get("panel")):
			return _format_success("Inspector already open for %s" % _color_path(path))
		_panels.erase(path)

	var props: Array = _collect_inspectable_properties(node)
	if props.is_empty():
		return _format_error("No @export properties (EDITOR+STORAGE) found on %s [%s]" % [path, node.get_class()])

	var entry: Dictionary = _build_panel(node, path, props)
	if entry.is_empty():
		return _format_error("Failed to build inspector panel for %s" % path)

	_panels[path] = entry
	return _format_success("Opened inspector for %s [%s] with %s widget(s)" % [
		_color_path(path),
		node.get_class(),
		_color_number(str(entry.get("widgets", {}).size())),
	])

func _cmd_inspector_close(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: inspector_close <node_path|all>")
	var arg: String = " ".join(args).strip_edges()
	if arg.to_lower() == "all":
		var count: int = _panels.size()
		for key in _panels.keys():
			_destroy_panel(_panels[key])
		_panels.clear()
		return _format_success("Closed %s inspector(s)" % _color_number(str(count)))

	if not _panels.has(arg):
		return _format_error("No inspector open for: %s" % arg)
	_destroy_panel(_panels[arg])
	_panels.erase(arg)
	return _format_success("Closed inspector for %s" % _color_path(arg))

func _cmd_inspector_pin(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: inspector_pin <node_path>")
	var path: String = " ".join(args).strip_edges()
	if not _panels.has(path):
		return _format_error("No inspector open for: %s" % path)
	var entry: Dictionary = _panels[path]
	var panel: PanelContainer = entry.get("panel")
	if not is_instance_valid(panel):
		_panels.erase(path)
		return _format_error("Inspector panel was freed (likely by a scene change): %s" % path)

	if entry.get("pinned", false):
		return _format_success("Inspector already pinned for %s" % _color_path(path))

	# Reparent under a CanvasLayer attached to /root so a scene reload won't
	# free the panel. The target node may itself disappear; the inspector will
	# stay open but show stale data until refresh, at which point the missing
	# node will surface as an error.
	var pinned_layer: CanvasLayer = _get_pinned_layer()
	if not pinned_layer:
		return _format_error("Cannot pin: no SceneTree available")
	var old_parent: Node = panel.get_parent()
	if old_parent and old_parent != pinned_layer:
		old_parent.remove_child(panel)
		pinned_layer.add_child(panel)
	entry["pinned"] = true
	return _format_success("Pinned inspector for %s" % _color_path(path))

func _cmd_inspector_list(_args: Array, _piped_input: String = "") -> String:
	_prune_dead_entries()
	if _panels.is_empty():
		return "No active inspector panels."
	var lines: Array[String] = []
	lines.append("Active inspectors: %s" % _color_number(str(_panels.size())))
	var keys: Array = _panels.keys()
	keys.sort()
	for key in keys:
		var entry: Dictionary = _panels[key]
		var node_ref: WeakRef = entry.get("node_ref")
		var target: Object = node_ref.get_ref() if node_ref else null
		var alive: String = "alive" if (target != null and is_instance_valid(target)) else "[color=%s]dead[/color]" % _COLOR_WARN
		var flags: Array[String] = []
		if entry.get("pinned", false):
			flags.append("pinned")
		if entry.get("minimized", false):
			flags.append("min")
		var widgets: Dictionary = entry.get("widgets", {})
		var flag_str: String = (" [" + ",".join(flags) + "]") if not flags.is_empty() else ""
		lines.append("  %s -> %s widget(s) (%s)%s" % [
			_color_path(str(key)),
			_color_number(str(widgets.size())),
			alive,
			flag_str,
		])
	return "\n".join(lines)

func _cmd_inspector_refresh(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: inspector_refresh <node_path>")
	var path: String = " ".join(args).strip_edges()
	if not _panels.has(path):
		return _format_error("No inspector open for: %s" % path)
	var entry: Dictionary = _panels[path]
	var node_ref: WeakRef = entry.get("node_ref")
	var target: Object = node_ref.get_ref() if node_ref else null
	if target == null or not is_instance_valid(target):
		return _format_error("Inspected node is gone: %s" % path)
	var refreshed: int = _refresh_widgets(entry, target)
	return _format_success("Refreshed %s widget(s) on %s" % [_color_number(str(refreshed)), _color_path(path)])

func _cmd_inspector_filter(args: Array, _piped_input: String = "") -> String:
	if args.size() < 1:
		return _format_error("Usage: inspector_filter <node_path> <pattern>")
	var path: String = str(args[0]).strip_edges()
	var pattern: String = ""
	if args.size() >= 2:
		# Allow patterns with spaces by joining the tail.
		var tail: Array[String] = []
		for i in range(1, args.size()):
			tail.append(str(args[i]))
		pattern = " ".join(tail).strip_edges()
	if not _panels.has(path):
		return _format_error("No inspector open for: %s" % path)
	var entry: Dictionary = _panels[path]
	entry["filter"] = pattern
	var visible_count: int = _apply_filter(entry, pattern)
	return _format_success("Filter '%s' on %s: %s row(s) visible" % [
		pattern,
		_color_path(path),
		_color_number(str(visible_count)),
	])

func _cmd_inspector_minimize(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: inspector_minimize <node_path>")
	var path: String = " ".join(args).strip_edges()
	if not _panels.has(path):
		return _format_error("No inspector open for: %s" % path)
	var entry: Dictionary = _panels[path]
	var content: Control = entry.get("content")
	if not is_instance_valid(content):
		return _format_error("Inspector content node is gone: %s" % path)
	var minimized: bool = not bool(entry.get("minimized", false))
	entry["minimized"] = minimized
	content.visible = not minimized
	var panel: PanelContainer = entry.get("panel")
	if is_instance_valid(panel):
		# Shrink min-size when minimized so the panel collapses to the header.
		panel.custom_minimum_size = Vector2(_DEFAULT_SIZE.x, 0) if minimized else _DEFAULT_SIZE
		# Reset the actual size; Containers won't shrink below their content
		# until size is explicitly reassigned.
		panel.size = panel.custom_minimum_size
	return _format_success("Inspector %s for %s" % [
		"minimized" if minimized else "restored",
		_color_path(path),
	])

func _cmd_inspector_dock(args: Array, _piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: inspector_dock <node_path> <tl|tr|bl|br>")
	var path: String = str(args[0]).strip_edges()
	var corner: String = str(args[1]).strip_edges().to_lower()
	if not _CORNER_MAP.has(corner):
		return _format_error("inspector_dock: unknown corner '%s'. Valid: tl, tr, bl, br" % corner)
	if not _panels.has(path):
		return _format_error("No inspector open for: %s" % path)
	var entry: Dictionary = _panels[path]
	var panel: PanelContainer = entry.get("panel")
	if not is_instance_valid(panel):
		return _format_error("Inspector panel was freed: %s" % path)

	var viewport_size: Vector2 = panel.get_viewport_rect().size
	var panel_size: Vector2 = panel.size
	if panel_size == Vector2.ZERO:
		panel_size = _DEFAULT_SIZE
	var anchor: Vector2 = _CORNER_MAP[corner]
	# anchor = (0,0) means top-left of viewport, (1,1) means bottom-right etc.
	# Apply a small margin so the panel doesn't bleed into the screen edge.
	var margin: float = 8.0
	var pos: Vector2 = Vector2(
		anchor.x * (viewport_size.x - panel_size.x) + (margin if anchor.x == 0.0 else -margin if anchor.x == 1.0 else 0.0),
		anchor.y * (viewport_size.y - panel_size.y) + (margin if anchor.y == 0.0 else -margin if anchor.y == 1.0 else 0.0)
	)
	# Detach from anchor presets so explicit position takes effect.
	panel.anchor_left = 0.0
	panel.anchor_top = 0.0
	panel.anchor_right = 0.0
	panel.anchor_bottom = 0.0
	panel.position = pos
	return _format_success("Docked inspector for %s to %s @ %s" % [
		_color_path(path),
		corner,
		str(pos),
	])

#endregion

#region panel construction

func _build_panel(node: Object, node_path: String, props: Array) -> Dictionary:
	var layer: CanvasLayer = _get_scene_layer()
	if not layer:
		return {}

	var panel: PanelContainer = PanelContainer.new()
	panel.name = "Inspector_%s" % _sanitize_name(node_path)
	panel.custom_minimum_size = _DEFAULT_SIZE
	panel.size = _DEFAULT_SIZE
	panel.position = _next_cascade_position(layer)

	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = _BG_COLOR
	sb.border_color = Color(0.32, 0.36, 0.45, 1.0)
	sb.border_width_left = 1
	sb.border_width_top = 1
	sb.border_width_right = 1
	sb.border_width_bottom = 1
	sb.corner_radius_top_left = 4
	sb.corner_radius_top_right = 4
	sb.corner_radius_bottom_left = 4
	sb.corner_radius_bottom_right = 4
	sb.content_margin_left = _MARGIN
	sb.content_margin_top = _MARGIN
	sb.content_margin_right = _MARGIN
	sb.content_margin_bottom = _MARGIN
	panel.add_theme_stylebox_override("panel", sb)

	layer.add_child(panel)

	var outer: VBoxContainer = VBoxContainer.new()
	outer.name = "Outer"
	outer.add_theme_constant_override("separation", 4)
	panel.add_child(outer)

	# Header: title + minimize + close. PanelContainer holds it together with
	# the scrollable content; minimize hides the content but keeps the header.
	var header: HBoxContainer = HBoxContainer.new()
	header.name = "Header"
	var header_panel: PanelContainer = PanelContainer.new()
	var hsb: StyleBoxFlat = StyleBoxFlat.new()
	hsb.bg_color = _HEADER_COLOR
	hsb.content_margin_left = 4
	hsb.content_margin_right = 4
	hsb.content_margin_top = 2
	hsb.content_margin_bottom = 2
	header_panel.add_theme_stylebox_override("panel", hsb)
	header_panel.add_child(header)
	outer.add_child(header_panel)

	var title_text: String = "%s [%s]" % [node_path, node.get_class()]
	var title: Label = Label.new()
	title.text = title_text
	title.add_theme_color_override("font_color", _LABEL_COLOR)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.clip_text = true
	header.add_child(title)

	var min_btn: Button = Button.new()
	min_btn.text = "_"
	min_btn.custom_minimum_size = Vector2(22, 0)
	min_btn.pressed.connect(_on_minimize_pressed.bind(node_path))
	header.add_child(min_btn)

	var close_btn: Button = Button.new()
	close_btn.text = "x"
	close_btn.custom_minimum_size = Vector2(22, 0)
	close_btn.pressed.connect(_on_close_pressed.bind(node_path))
	header.add_child(close_btn)

	# Scrollable content area for property rows.
	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(scroll)

	var content: VBoxContainer = VBoxContainer.new()
	content.name = "Content"
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 3)
	scroll.add_child(content)

	var rows: Dictionary = {}
	var widgets: Dictionary = {}

	for prop in props:
		var row: Control = _build_row(node, prop, widgets)
		if row == null:
			continue
		var prop_name: String = str(prop.get("name", ""))
		rows[prop_name] = row
		content.add_child(row)

	# Reparent the scroll so it lives under the outer VBox at the right
	# index - already done above. We expose `content` (the inner VBox) as the
	# "content_container" so minimize/filter operate on the visible rows.
	return {
		"panel": panel,
		"node_ref": weakref(node),
		"node_path": node_path,
		"pinned": false,
		"minimized": false,
		"content": scroll,
		"header": header,
		"title": title,
		"rows": rows,
		"widgets": widgets,
		"filter": "",
	}

# Builds a single labelled row for one property. Returns null if we can't
# represent the property type (skipped silently rather than failing the whole
# panel construction).
func _build_row(node: Object, prop: Dictionary, widgets: Dictionary) -> Control:
	var prop_name: String = str(prop.get("name", ""))
	if prop_name.is_empty():
		return null
	var type_id: int = int(prop.get("type", TYPE_NIL))
	var hint: int = int(prop.get("hint", PROPERTY_HINT_NONE))
	var hint_string: String = str(prop.get("hint_string", ""))
	var current: Variant = node.get(prop_name)

	var row: HBoxContainer = HBoxContainer.new()
	row.name = "Row_%s" % prop_name
	row.add_theme_constant_override("separation", 6)

	var label: Label = Label.new()
	label.text = prop_name
	label.custom_minimum_size = Vector2(110, 0)
	label.add_theme_color_override("font_color", _LABEL_COLOR)
	label.clip_text = true
	row.add_child(label)

	var widget: Control = null
	match type_id:
		TYPE_BOOL:
			var cb: CheckBox = CheckBox.new()
			cb.button_pressed = bool(current)
			cb.toggled.connect(_on_widget_changed.bind(node, prop_name, "bool"))
			widget = cb
		TYPE_INT, TYPE_FLOAT:
			if hint == PROPERTY_HINT_ENUM and type_id == TYPE_INT and not hint_string.is_empty():
				widget = _make_enum_button(hint_string, int(current), node, prop_name)
			elif hint == PROPERTY_HINT_RANGE and not hint_string.is_empty():
				widget = _make_range_slider(hint_string, current, node, prop_name, type_id)
			else:
				widget = _make_spinbox(current, node, prop_name, type_id, hint, hint_string)
		TYPE_STRING, TYPE_STRING_NAME:
			if hint == PROPERTY_HINT_ENUM and not hint_string.is_empty():
				widget = _make_string_enum_button(hint_string, str(current), node, prop_name)
			else:
				var le: LineEdit = LineEdit.new()
				le.text = str(current)
				le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				le.text_submitted.connect(_on_widget_changed.bind(node, prop_name, "string"))
				# Also commit on focus loss so the user doesn't have to press
				# Enter to push their edit.
				le.focus_exited.connect(_on_line_edit_focus_lost.bind(le, node, prop_name))
				widget = le
		TYPE_COLOR:
			var cp: ColorPickerButton = ColorPickerButton.new()
			cp.color = current if current is Color else Color.WHITE
			cp.custom_minimum_size = Vector2(0, 24)
			cp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			cp.color_changed.connect(_on_widget_changed.bind(node, prop_name, "color"))
			widget = cp
		TYPE_VECTOR2, TYPE_VECTOR2I:
			widget = _make_vector_widget(current, node, prop_name, 2, type_id == TYPE_VECTOR2I)
		TYPE_VECTOR3, TYPE_VECTOR3I:
			widget = _make_vector_widget(current, node, prop_name, 3, type_id == TYPE_VECTOR3I)
		_:
			# Unsupported type - render a read-only Label so the user still
			# knows the property exists and what its current value is.
			var info: Label = Label.new()
			info.text = "%s = %s" % [_type_name(type_id), str(current)]
			info.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6, 1.0))
			info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			widget = info

	if widget == null:
		return null
	widget.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(widget)
	widgets[prop_name] = {
		"widget": widget,
		"type": type_id,
		"prop": prop,
	}
	return row

func _make_spinbox(current: Variant, node: Object, prop_name: String, type_id: int, hint: int, hint_string: String) -> SpinBox:
	var sb: SpinBox = SpinBox.new()
	sb.allow_greater = true
	sb.allow_lesser = true
	sb.step = 1.0 if type_id == TYPE_INT else 0.01
	sb.min_value = -1000000000.0
	sb.max_value = 1000000000.0
	if hint == PROPERTY_HINT_RANGE and not hint_string.is_empty():
		var parts: PackedStringArray = hint_string.split(",")
		if parts.size() >= 2:
			sb.min_value = float(parts[0])
			sb.max_value = float(parts[1])
		if parts.size() >= 3 and not str(parts[2]).is_empty() and str(parts[2]).is_valid_float():
			sb.step = float(parts[2])
	sb.value = float(current) if current != null else 0.0
	var tag: String = "int" if type_id == TYPE_INT else "float"
	sb.value_changed.connect(_on_widget_changed.bind(node, prop_name, tag))
	return sb

func _make_range_slider(hint_string: String, current: Variant, node: Object, prop_name: String, type_id: int) -> HBoxContainer:
	# When a numeric property carries @export_range, render an HSlider next to
	# a read-only Label so the user gets both fine drag control AND the exact
	# current value. The Slider drives the underlying property; the Label is
	# updated by the change handler.
	var parts: PackedStringArray = hint_string.split(",")
	var min_v: float = 0.0
	var max_v: float = 100.0
	var step_v: float = 1.0 if type_id == TYPE_INT else 0.01
	if parts.size() >= 1 and str(parts[0]).is_valid_float():
		min_v = float(parts[0])
	if parts.size() >= 2 and str(parts[1]).is_valid_float():
		max_v = float(parts[1])
	if parts.size() >= 3 and str(parts[2]).is_valid_float():
		step_v = float(parts[2])

	var hb: HBoxContainer = HBoxContainer.new()
	hb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_theme_constant_override("separation", 4)
	var slider: HSlider = HSlider.new()
	slider.min_value = min_v
	slider.max_value = max_v
	slider.step = step_v
	slider.value = float(current) if current != null else min_v
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size = Vector2(80, 0)
	hb.add_child(slider)

	var value_lbl: Label = Label.new()
	value_lbl.name = "ValueLabel"
	value_lbl.text = _format_numeric(slider.value, type_id)
	value_lbl.custom_minimum_size = Vector2(50, 0)
	value_lbl.add_theme_color_override("font_color", _FONT_COLOR)
	hb.add_child(value_lbl)

	slider.value_changed.connect(_on_slider_changed.bind(node, prop_name, type_id, value_lbl))
	# Stash the slider so refresh can find it without inspecting children.
	hb.set_meta("widget", slider)
	hb.set_meta("value_label", value_lbl)
	return hb

func _make_enum_button(hint_string: String, current: int, node: Object, prop_name: String) -> OptionButton:
	# hint_string is "Option1,Option2,Option3" or "Option1:5,Option2:7,..."
	var ob: OptionButton = OptionButton.new()
	var values: Array[int] = []
	var entries: PackedStringArray = hint_string.split(",")
	for i in range(entries.size()):
		var entry: String = String(entries[i])
		var colon: int = entry.rfind(":")
		var label_text: String = entry
		var value: int = i
		if colon > 0 and colon < entry.length() - 1:
			label_text = entry.substr(0, colon)
			var num_str: String = entry.substr(colon + 1).strip_edges()
			if num_str.is_valid_int():
				value = int(num_str)
		ob.add_item(label_text, value)
		values.append(value)
	var idx: int = values.find(current)
	if idx >= 0:
		ob.select(idx)
	ob.item_selected.connect(_on_enum_selected.bind(ob, node, prop_name))
	ob.set_meta("values", values)
	return ob

func _make_string_enum_button(hint_string: String, current: String, node: Object, prop_name: String) -> OptionButton:
	var ob: OptionButton = OptionButton.new()
	var entries: PackedStringArray = hint_string.split(",")
	var values: Array[String] = []
	for i in range(entries.size()):
		var entry: String = String(entries[i]).strip_edges()
		ob.add_item(entry, i)
		values.append(entry)
	var idx: int = values.find(current)
	if idx >= 0:
		ob.select(idx)
	ob.item_selected.connect(_on_string_enum_selected.bind(ob, node, prop_name))
	ob.set_meta("string_values", values)
	return ob

func _make_vector_widget(current: Variant, node: Object, prop_name: String, dim: int, is_int: bool) -> HBoxContainer:
	var hb: HBoxContainer = HBoxContainer.new()
	hb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_theme_constant_override("separation", 3)
	var spinboxes: Array[SpinBox] = []
	var axis_labels: Array[String] = ["x", "y", "z", "w"]
	for i in range(dim):
		var axis_box: VBoxContainer = VBoxContainer.new()
		axis_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var axis_lbl: Label = Label.new()
		axis_lbl.text = axis_labels[i]
		axis_lbl.add_theme_color_override("font_color", Color(0.6, 0.7, 0.85, 1.0))
		axis_box.add_child(axis_lbl)
		var sb: SpinBox = SpinBox.new()
		sb.allow_greater = true
		sb.allow_lesser = true
		sb.step = 1.0 if is_int else 0.01
		sb.min_value = -1000000000.0
		sb.max_value = 1000000000.0
		sb.value = float(_vector_component(current, i))
		sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		sb.custom_minimum_size = Vector2(60, 0)
		sb.value_changed.connect(_on_vector_component_changed.bind(node, prop_name, i, dim, is_int, hb))
		axis_box.add_child(sb)
		hb.add_child(axis_box)
		spinboxes.append(sb)
	hb.set_meta("vector_spinboxes", spinboxes)
	hb.set_meta("vector_dim", dim)
	hb.set_meta("vector_is_int", is_int)
	return hb

#endregion

#region widget callbacks

func _on_widget_changed(value: Variant, node: Object, prop_name: String, tag: String) -> void:
	if not is_instance_valid(node):
		return
	# SpinBox always emits floats - if the underlying property is typed as int
	# (the "int" tag is set in _make_spinbox), coerce so Godot's setter doesn't
	# truncate-with-warning or refuse the assignment.
	var coerced: Variant = value
	if tag == "int" and value is float:
		coerced = int(round(value))
	node.set(prop_name, coerced)

func _on_slider_changed(value: float, node: Object, prop_name: String, type_id: int, value_lbl: Label) -> void:
	if not is_instance_valid(node):
		return
	var typed_value: Variant = int(value) if type_id == TYPE_INT else value
	node.set(prop_name, typed_value)
	if is_instance_valid(value_lbl):
		value_lbl.text = _format_numeric(value, type_id)

func _on_enum_selected(index: int, ob: OptionButton, node: Object, prop_name: String) -> void:
	if not is_instance_valid(node) or not is_instance_valid(ob):
		return
	var values: Array = ob.get_meta("values", [])
	var v: int = int(values[index]) if index >= 0 and index < values.size() else index
	node.set(prop_name, v)

func _on_string_enum_selected(index: int, ob: OptionButton, node: Object, prop_name: String) -> void:
	if not is_instance_valid(node) or not is_instance_valid(ob):
		return
	var values: Array = ob.get_meta("string_values", [])
	if index < 0 or index >= values.size():
		return
	node.set(prop_name, str(values[index]))

func _on_vector_component_changed(_value: float, node: Object, prop_name: String, _idx: int, dim: int, is_int: bool, hb: HBoxContainer) -> void:
	if not is_instance_valid(node) or not is_instance_valid(hb):
		return
	var spinboxes: Array = hb.get_meta("vector_spinboxes", [])
	if spinboxes.size() < dim:
		return
	var values: Array[float] = []
	for i in range(dim):
		values.append(float((spinboxes[i] as SpinBox).value))
	var composed: Variant
	if is_int:
		match dim:
			2: composed = Vector2i(int(values[0]), int(values[1]))
			3: composed = Vector3i(int(values[0]), int(values[1]), int(values[2]))
			_: return
	else:
		match dim:
			2: composed = Vector2(values[0], values[1])
			3: composed = Vector3(values[0], values[1], values[2])
			_: return
	node.set(prop_name, composed)

func _on_line_edit_focus_lost(line_edit: LineEdit, node: Object, prop_name: String) -> void:
	if not is_instance_valid(line_edit) or not is_instance_valid(node):
		return
	node.set(prop_name, line_edit.text)

func _on_minimize_pressed(node_path: String) -> void:
	_cmd_inspector_minimize([node_path])

func _on_close_pressed(node_path: String) -> void:
	if not _panels.has(node_path):
		return
	_destroy_panel(_panels[node_path])
	_panels.erase(node_path)

#endregion

#region refresh / filter / lifecycle

# Re-reads each property from the target node and pushes the new value into
# the bound widget. Signals are blocked around the assignment so we don't
# trigger spurious "user changed value" handlers and write the same value
# back to the node (which is a no-op but adds noise in custom setters).
func _refresh_widgets(entry: Dictionary, node: Object) -> int:
	var widgets: Dictionary = entry.get("widgets", {})
	var refreshed: int = 0
	for prop_name in widgets.keys():
		var info: Dictionary = widgets[prop_name]
		var widget: Control = info.get("widget")
		if not is_instance_valid(widget):
			continue
		var current: Variant = node.get(prop_name)
		widget.set_block_signals(true)
		_assign_widget_value(widget, info, current)
		widget.set_block_signals(false)
		refreshed += 1
	return refreshed

func _assign_widget_value(widget: Control, info: Dictionary, current: Variant) -> void:
	var type_id: int = int(info.get("type", TYPE_NIL))
	if widget is CheckBox:
		(widget as CheckBox).button_pressed = bool(current)
		return
	if widget is SpinBox:
		(widget as SpinBox).value = float(current) if current != null else 0.0
		return
	if widget is LineEdit:
		(widget as LineEdit).text = str(current)
		return
	if widget is ColorPickerButton:
		(widget as ColorPickerButton).color = current if current is Color else Color.WHITE
		return
	if widget is OptionButton:
		var ob: OptionButton = widget
		if ob.has_meta("values"):
			var values: Array = ob.get_meta("values", [])
			var idx: int = values.find(int(current) if current != null else 0)
			if idx >= 0:
				ob.select(idx)
		elif ob.has_meta("string_values"):
			var values_s: Array = ob.get_meta("string_values", [])
			var idx_s: int = values_s.find(str(current))
			if idx_s >= 0:
				ob.select(idx_s)
		return
	if widget is HBoxContainer:
		var hb: HBoxContainer = widget
		# Range slider row.
		if hb.has_meta("widget") and hb.get_meta("widget") is HSlider:
			var slider: HSlider = hb.get_meta("widget")
			slider.set_block_signals(true)
			slider.value = float(current) if current != null else slider.min_value
			slider.set_block_signals(false)
			var vl: Label = hb.get_meta("value_label", null)
			if is_instance_valid(vl):
				vl.text = _format_numeric(slider.value, type_id)
			return
		# Vector row.
		if hb.has_meta("vector_spinboxes"):
			var spinboxes: Array = hb.get_meta("vector_spinboxes", [])
			var dim: int = int(hb.get_meta("vector_dim", spinboxes.size()))
			for i in range(min(dim, spinboxes.size())):
				var sb: SpinBox = spinboxes[i]
				if is_instance_valid(sb):
					sb.set_block_signals(true)
					sb.value = float(_vector_component(current, i))
					sb.set_block_signals(false)
			return

# Walks the rows dict and toggles visibility based on a substring match against
# the property name. Empty pattern restores all rows. Returns the count of
# rows left visible so the caller can echo it to the user.
func _apply_filter(entry: Dictionary, pattern: String) -> int:
	var rows: Dictionary = entry.get("rows", {})
	var lower: String = pattern.to_lower()
	var visible_count: int = 0
	for prop_name in rows.keys():
		var row: Control = rows[prop_name]
		if not is_instance_valid(row):
			continue
		var match_visible: bool = lower.is_empty() or str(prop_name).to_lower().contains(lower)
		row.visible = match_visible
		if match_visible:
			visible_count += 1
	return visible_count

func _destroy_panel(entry: Dictionary) -> void:
	var panel: PanelContainer = entry.get("panel")
	if is_instance_valid(panel):
		panel.queue_free()

func _prune_dead_entries() -> void:
	var dead_keys: Array = []
	for key in _panels.keys():
		var entry: Dictionary = _panels[key]
		var panel: PanelContainer = entry.get("panel")
		if not is_instance_valid(panel):
			dead_keys.append(key)
	for key in dead_keys:
		_panels.erase(key)

#endregion

#region property introspection

# Collects properties that the Godot inspector itself would show: anything
# carrying both EDITOR and STORAGE usage flags. Skips category/group headers
# (TYPE_NIL with non-name usage) and properties whose type we can't render.
func _collect_inspectable_properties(node: Object) -> Array:
	var result: Array = []
	var raw: Array = node.get_property_list()
	var required: int = PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_STORAGE
	for prop in raw:
		var usage: int = int(prop.get("usage", 0))
		if (usage & required) != required:
			continue
		var type_id: int = int(prop.get("type", TYPE_NIL))
		if type_id == TYPE_NIL:
			continue
		var prop_name: String = str(prop.get("name", ""))
		if prop_name.is_empty():
			continue
		# Skip internal node properties Godot tags with EDITOR for the dock
		# but that aren't useful here (e.g. `script`, which would let the user
		# accidentally rebind classes mid-game).
		if prop_name == "script":
			continue
		result.append(prop)
	return result

#endregion

#region layer + position helpers

func _get_scene_layer() -> CanvasLayer:
	var tree := Engine.get_main_loop() as SceneTree
	if not tree:
		return null
	var scene_root: Node = tree.current_scene if tree.current_scene else tree.root
	if not scene_root:
		return null
	var existing: Node = scene_root.get_node_or_null(NodePath(_SCENE_LAYER_NAME))
	if existing is CanvasLayer and is_instance_valid(existing):
		return existing
	var layer: CanvasLayer = CanvasLayer.new()
	layer.name = _SCENE_LAYER_NAME
	# Layer 100 puts inspectors above typical game UI but below the debug
	# console itself, which sits at the engine's max layer.
	layer.layer = 100
	scene_root.add_child(layer)
	return layer

func _get_pinned_layer() -> CanvasLayer:
	var tree := Engine.get_main_loop() as SceneTree
	if not tree:
		return null
	var existing: Node = tree.root.get_node_or_null(NodePath(_PINNED_LAYER_NAME))
	if existing is CanvasLayer and is_instance_valid(existing):
		return existing
	var layer: CanvasLayer = CanvasLayer.new()
	layer.name = _PINNED_LAYER_NAME
	layer.layer = 101
	tree.root.add_child(layer)
	return layer

# Cascades successive panels so they don't perfectly overlap when multiple
# inspectors are opened. Offset = number of existing panels under the layer
# times 24px, clamped so we don't run off the viewport.
func _next_cascade_position(layer: CanvasLayer) -> Vector2:
	var count: int = 0
	for child in layer.get_children():
		if child is PanelContainer:
			count += 1
	var step: float = 24.0
	var max_offset: float = 240.0
	var offset: float = minf(count * step, max_offset)
	return Vector2(20 + offset, 20 + offset)

#endregion

#region value + path helpers

func _vector_component(v: Variant, idx: int) -> float:
	if v is Vector2:
		var v2: Vector2 = v
		match idx:
			0: return v2.x
			1: return v2.y
		return 0.0
	if v is Vector2i:
		var v2i: Vector2i = v
		match idx:
			0: return float(v2i.x)
			1: return float(v2i.y)
		return 0.0
	if v is Vector3:
		var v3: Vector3 = v
		match idx:
			0: return v3.x
			1: return v3.y
			2: return v3.z
		return 0.0
	if v is Vector3i:
		var v3i: Vector3i = v
		match idx:
			0: return float(v3i.x)
			1: return float(v3i.y)
			2: return float(v3i.z)
		return 0.0
	return 0.0

func _format_numeric(v: float, type_id: int) -> String:
	if type_id == TYPE_INT:
		return str(int(round(v)))
	return "%.3f" % v

func _sanitize_name(s: String) -> String:
	# Replace anything that isn't [A-Za-z0-9_] with an underscore so the
	# resulting string is safe to use as a Node name (Godot rejects '/', '.',
	# ':', '@', etc).
	var out: String = ""
	for i in range(s.length()):
		var c: String = s.substr(i, 1)
		var code: int = c.unicode_at(0)
		var is_alnum: bool = (code >= 48 and code <= 57) or (code >= 65 and code <= 90) or (code >= 97 and code <= 122)
		if is_alnum or c == "_":
			out += c
		else:
			out += "_"
	if out.is_empty():
		out = "node"
	return out

# Path resolver mirroring SceneCommands._resolve_node so users get consistent
# lookup semantics across the plugin. Tries absolute paths first, then a
# find_child sweep so short names like "Player" still hit.
func _resolve_node(path: String) -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if not tree:
		return null
	var p: String = path.strip_edges()
	if p.is_empty():
		return null
	if p.begins_with("/"):
		return tree.root.get_node_or_null(NodePath(p))
	var scene: Node = tree.current_scene if tree.current_scene else tree.root
	var direct: Node = scene.get_node_or_null(NodePath(p))
	if direct:
		return direct
	return scene.find_child(p, true, false)

func _type_name(type_id: int) -> String:
	match type_id:
		TYPE_NIL: return "void"
		TYPE_BOOL: return "bool"
		TYPE_INT: return "int"
		TYPE_FLOAT: return "float"
		TYPE_STRING: return "String"
		TYPE_STRING_NAME: return "StringName"
		TYPE_VECTOR2: return "Vector2"
		TYPE_VECTOR2I: return "Vector2i"
		TYPE_VECTOR3: return "Vector3"
		TYPE_VECTOR3I: return "Vector3i"
		TYPE_VECTOR4: return "Vector4"
		TYPE_COLOR: return "Color"
		TYPE_NODE_PATH: return "NodePath"
		TYPE_OBJECT: return "Object"
		TYPE_DICTIONARY: return "Dictionary"
		TYPE_ARRAY: return "Array"
		_: return "Variant"

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

#endregion

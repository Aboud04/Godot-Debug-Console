@tool
class_name DebugConsoleLogFilterUICommands extends RefCounted

# Extension module - graphical floating overlay for the log filter system.
# Sits on top of LogFilterCommands: every interactive widget translates a
# user gesture into a registry.execute_command(...) call against the
# underlying log_level / log_filter_add / log_exclude_add / log_filter_clear
# commands. Doing it through the registry (rather than holding a direct
# reference to the LogFilterCommands instance) keeps this module decoupled
# and lets the underlying filter stay swappable.
#
# The panel itself is lazily parented to a CanvasLayer named
# `DebugConsoleLogFilterUI` under the current scene root (mirrors the lazy
# overlay pattern used by core/UICommands.gd). The CanvasLayer keeps the
# panel rendered above the 3D viewport and survives scene reloads only if
# the user re-runs `log_ui_show` - we deliberately do not persist the Node
# reference across scene reloads (it would dangle).

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_DIM := "#808080"

const _OVERLAY_LAYER_NAME := "DebugConsoleLogFilterUI"
const _PANEL_NAME := "LogFilterPanel"
const _DEFAULT_SIZE := Vector2(360, 220)
const _DEFAULT_MARGIN := 16.0

# Severity ladder for the four checkboxes. Ordered most-verbose -> least so
# _recompute_log_level can walk it top-down and pick the highest checked
# level (which translates to `log_level <name>` against LogFilterCommands).
# Matches the constants in core/extensions/LogFilterCommands.gd:25-32.
const _LEVELS: Array = ["debug", "info", "warn", "error"]

const _DOCK_PRESETS: Dictionary = {
	"tl": Control.PRESET_TOP_LEFT,
	"tr": Control.PRESET_TOP_RIGHT,
	"bl": Control.PRESET_BOTTOM_LEFT,
	"br": Control.PRESET_BOTTOM_RIGHT,
}

var _registry: Node
var _core: Node

# Stored as an absolute node path string rather than a Node reference because
# a Node reference would dangle if the user reloaded the scene mid-session.
# Matches the cache strategy in core/UICommands.gd:24.
var _overlay_layer_path: String = ""
var _panel_path: String = ""

# Surface state used by log_ui_save_settings. Tracked here instead of
# scraped back out of LogFilterCommands so the saved file always reflects
# what the user is seeing in the UI, even if the underlying log filter was
# poked by another command in between.
var _ui_state: Dictionary = {
	"level": "info",
	"include": "",
	"exclude": "",
	"dock": "",
	"position": Vector2.ZERO,
	"visible": false,
}

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("log_ui_show", _cmd_log_ui_show, "Show the floating log-filter UI panel: log_ui_show", "game")
	_registry.register_command("log_ui_hide", _cmd_log_ui_hide, "Hide the floating log-filter UI panel: log_ui_hide", "game")
	_registry.register_command("log_ui_dock", _cmd_log_ui_dock, "Dock the log-filter UI panel to a corner: log_ui_dock <tl|tr|bl|br>", "game")
	_registry.register_command("log_ui_position", _cmd_log_ui_position, "Move the log-filter UI panel to absolute pixel coords: log_ui_position <x> <y>", "game")
	_registry.register_command("log_ui_save_settings", _cmd_log_ui_save_settings, "Persist current log-filter UI state to a ConfigFile: log_ui_save_settings <user://path.cfg>", "game")

#region Command implementations

func _cmd_log_ui_show(_args: Array, _piped_input: String = "") -> String:
	var panel: PanelContainer = _ensure_panel()
	if not panel:
		return _format_error("log_ui_show: no SceneTree / scene root available")
	panel.visible = true
	_ui_state["visible"] = true
	return _format_success("Log filter UI shown at %s" % _format_path(panel))

func _cmd_log_ui_hide(_args: Array, _piped_input: String = "") -> String:
	var panel: PanelContainer = _get_panel()
	if not panel:
		return _format_error("log_ui_hide: panel is not currently shown")
	panel.visible = false
	_ui_state["visible"] = false
	return _format_success("Log filter UI hidden")

func _cmd_log_ui_dock(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: log_ui_dock <tl|tr|bl|br>")
	var corner: String = str(args[0]).strip_edges().to_lower()
	if not _DOCK_PRESETS.has(corner):
		return _format_error("log_ui_dock: unknown corner '%s' (expected tl|tr|bl|br)" % corner)
	var panel: PanelContainer = _get_panel()
	if not panel:
		return _format_error("log_ui_dock: panel not shown - run log_ui_show first")

	var preset_val: int = int(_DOCK_PRESETS[corner])
	# KEEP_SIZE so docking doesn't blow the panel up to viewport-wide; the
	# panel keeps its custom_minimum_size and just snaps to the chosen
	# corner.
	panel.set_anchors_and_offsets_preset(preset_val, Control.PRESET_MODE_KEEP_SIZE)
	# After preset_keep_size the panel hugs the corner with zero margin,
	# which looks pinched. Push it inward by _DEFAULT_MARGIN so it visually
	# floats inside the viewport rather than glueing to the edge.
	_apply_corner_margin(panel, corner)
	_ui_state["dock"] = corner
	_ui_state["position"] = panel.position
	return _format_success("Log filter UI docked to %s" % _color_path(corner))

func _cmd_log_ui_position(args: Array, _piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: log_ui_position <x> <y>")
	var x_raw: String = str(args[0]).strip_edges()
	var y_raw: String = str(args[1]).strip_edges()
	if not x_raw.is_valid_float() or not y_raw.is_valid_float():
		return _format_error("log_ui_position: x and y must be numeric (got '%s', '%s')" % [x_raw, y_raw])
	var panel: PanelContainer = _get_panel()
	if not panel:
		return _format_error("log_ui_position: panel not shown - run log_ui_show first")

	# Detach from any prior dock anchors so absolute position actually
	# takes effect. PRESET_TOP_LEFT with KEEP_SIZE pins anchors to (0,0)
	# and leaves size alone, then setting position offsets the panel.
	panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT, Control.PRESET_MODE_KEEP_SIZE)
	var pos: Vector2 = Vector2(x_raw.to_float(), y_raw.to_float())
	panel.position = pos
	_ui_state["dock"] = ""
	_ui_state["position"] = pos
	return _format_success("Log filter UI moved to %s" % _color_path(str(pos)))

func _cmd_log_ui_save_settings(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: log_ui_save_settings <user://path.cfg>")
	var path: String = str(args[0]).strip_edges()
	if path.is_empty():
		return _format_error("log_ui_save_settings: path cannot be empty")

	# Pull the freshest UI state back from the live panel if it exists so
	# the saved file matches what the user can see, not just what was last
	# written through a command. If the panel has been freed we fall back
	# to whatever was last cached in _ui_state.
	_sync_state_from_panel()

	var cfg: ConfigFile = ConfigFile.new()
	cfg.set_value("filter", "level", str(_ui_state.get("level", "info")))
	cfg.set_value("filter", "include", str(_ui_state.get("include", "")))
	cfg.set_value("filter", "exclude", str(_ui_state.get("exclude", "")))
	cfg.set_value("ui", "dock", str(_ui_state.get("dock", "")))
	var pos_v: Vector2 = _ui_state.get("position", Vector2.ZERO)
	cfg.set_value("ui", "position_x", pos_v.x)
	cfg.set_value("ui", "position_y", pos_v.y)
	cfg.set_value("ui", "visible", bool(_ui_state.get("visible", false)))

	var err: int = cfg.save(path)
	if err != OK:
		return _format_error("log_ui_save_settings: ConfigFile.save() failed (err=%d) for %s" % [err, path])
	return _format_success("Log filter UI settings saved to %s" % _color_path(path))

#endregion

#region Panel construction

# Builds the panel on first call and returns the existing one on subsequent
# calls. Panel structure is built in code (rather than instanced from a
# .tscn) because this module ships as a single .gd file in an addon and we
# don't want to drag along a sibling scene resource.
func _ensure_panel() -> PanelContainer:
	var existing: PanelContainer = _get_panel()
	if existing:
		return existing

	var layer: Node = _get_overlay_layer()
	if not layer:
		return null

	var panel: PanelContainer = PanelContainer.new()
	panel.name = _PANEL_NAME
	panel.custom_minimum_size = _DEFAULT_SIZE
	# Mouse_filter STOP so clicks on the panel background don't leak into
	# the game's input handlers underneath; individual widgets re-enable
	# their own click handling internally.
	panel.mouse_filter = Control.MOUSE_FILTER_STOP

	var bg: StyleBoxFlat = StyleBoxFlat.new()
	bg.bg_color = Color(0.08, 0.08, 0.10, 0.92)
	bg.border_color = Color(0.35, 0.35, 0.40, 1.0)
	bg.border_width_left = 1
	bg.border_width_top = 1
	bg.border_width_right = 1
	bg.border_width_bottom = 1
	bg.content_margin_left = 10
	bg.content_margin_right = 10
	bg.content_margin_top = 8
	bg.content_margin_bottom = 8
	panel.add_theme_stylebox_override("panel", bg)

	layer.add_child(panel)
	_panel_path = String(panel.get_path())

	# Default-anchor top-left and offset by _DEFAULT_MARGIN so a fresh
	# `log_ui_show` doesn't park the panel at exactly (0,0) where it would
	# overlap the engine debug overlays.
	panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT, Control.PRESET_MODE_KEEP_SIZE)
	panel.position = Vector2(_DEFAULT_MARGIN, _DEFAULT_MARGIN)
	_ui_state["position"] = panel.position

	var vbox: VBoxContainer = VBoxContainer.new()
	vbox.name = "VBox"
	vbox.add_theme_constant_override("separation", 6)
	panel.add_child(vbox)

	var title: Label = Label.new()
	title.name = "Title"
	title.text = "Log Filter"
	title.add_theme_color_override("font_color", Color(0.85, 0.85, 0.90))
	vbox.add_child(title)

	_build_level_row(vbox)
	_build_regex_row(vbox, "include", "Include regex:")
	_build_regex_row(vbox, "exclude", "Exclude regex:")
	_build_clear_button(vbox)

	return panel

func _build_level_row(parent: VBoxContainer) -> void:
	var row: HBoxContainer = HBoxContainer.new()
	row.name = "LevelRow"
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)

	var lbl: Label = Label.new()
	lbl.text = "Capture:"
	row.add_child(lbl)

	# One CheckBox per severity. Toggling any of them recomputes the
	# effective threshold (most-verbose checked wins) and forwards a
	# single `log_level <name>` command through the registry.
	for level in _LEVELS:
		var cb: CheckBox = CheckBox.new()
		cb.name = "Level_" + str(level)
		cb.text = str(level)
		# Default ladder: capture info+warn+error (matches the LEVEL_INFO
		# default in LogFilterCommands.gd:39).
		cb.button_pressed = (level == "info" or level == "warn" or level == "error")
		cb.toggled.connect(_on_level_toggled)
		row.add_child(cb)

func _build_regex_row(parent: VBoxContainer, kind: String, label_text: String) -> void:
	var row: HBoxContainer = HBoxContainer.new()
	row.name = kind.capitalize() + "Row"
	row.add_theme_constant_override("separation", 6)
	parent.add_child(row)

	var lbl: Label = Label.new()
	lbl.text = label_text
	lbl.custom_minimum_size = Vector2(96, 0)
	row.add_child(lbl)

	var edit: LineEdit = LineEdit.new()
	edit.name = kind.capitalize() + "Edit"
	edit.placeholder_text = "regex pattern"
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(edit)

	var btn: Button = Button.new()
	btn.name = "Apply_" + kind.capitalize()
	btn.text = "Add"
	# bind() injects the kind ("include" or "exclude") and the LineEdit
	# so a single handler can route to the right underlying command.
	btn.pressed.connect(_on_regex_apply.bind(kind, edit))
	row.add_child(btn)

func _build_clear_button(parent: VBoxContainer) -> void:
	var btn: Button = Button.new()
	btn.name = "ClearAll"
	btn.text = "Clear all filters"
	btn.pressed.connect(_on_clear_pressed)
	parent.add_child(btn)

#endregion

#region Signal handlers (wire to LogFilterCommands via the registry)

func _on_level_toggled(_pressed: bool) -> void:
	# Recompute the highest-verbosity checked level and forward to
	# `log_level`. If nothing is checked we explicitly set "off" so the
	# UI faithfully mirrors the underlying state.
	var level_name: String = _recompute_active_level()
	_ui_state["level"] = level_name
	_dispatch("log_level " + level_name)

func _on_regex_apply(kind: String, edit: LineEdit) -> void:
	if not is_instance_valid(edit):
		return
	var pattern: String = edit.text.strip_edges()
	if pattern.is_empty():
		return
	_ui_state[kind] = pattern
	var cmd: String = "log_filter_add " if kind == "include" else "log_exclude_add "
	_dispatch(cmd + pattern)

func _on_clear_pressed() -> void:
	_ui_state["include"] = ""
	_ui_state["exclude"] = ""
	var panel: PanelContainer = _get_panel()
	if panel:
		var inc: LineEdit = panel.find_child("IncludeEdit", true, false) as LineEdit
		var exc: LineEdit = panel.find_child("ExcludeEdit", true, false) as LineEdit
		if is_instance_valid(inc):
			inc.text = ""
		if is_instance_valid(exc):
			exc.text = ""
	_dispatch("log_filter_clear")

#endregion

#region Helpers

func _recompute_active_level() -> String:
	var panel: PanelContainer = _get_panel()
	if not panel:
		return "off"
	# Walk _LEVELS in declared order (most -> least verbose) and return
	# the first one whose CheckBox is checked. "debug" beats "info"
	# beats "warn" beats "error".
	for level in _LEVELS:
		var cb: CheckBox = panel.find_child("Level_" + str(level), true, false) as CheckBox
		if is_instance_valid(cb) and cb.button_pressed:
			return str(level)
	return "off"

func _sync_state_from_panel() -> void:
	var panel: PanelContainer = _get_panel()
	if not panel:
		return
	_ui_state["level"] = _recompute_active_level()
	var inc: LineEdit = panel.find_child("IncludeEdit", true, false) as LineEdit
	var exc: LineEdit = panel.find_child("ExcludeEdit", true, false) as LineEdit
	if is_instance_valid(inc):
		_ui_state["include"] = inc.text
	if is_instance_valid(exc):
		_ui_state["exclude"] = exc.text
	_ui_state["position"] = panel.position
	_ui_state["visible"] = panel.visible

func _apply_corner_margin(panel: PanelContainer, corner: String) -> void:
	var m: float = _DEFAULT_MARGIN
	match corner:
		"tl":
			panel.position = Vector2(m, m)
		"tr":
			panel.position = Vector2(-panel.size.x - m, m) if panel.size.x > 0.0 else Vector2(-_DEFAULT_SIZE.x - m, m)
		"bl":
			panel.position = Vector2(m, -panel.size.y - m) if panel.size.y > 0.0 else Vector2(m, -_DEFAULT_SIZE.y - m)
		"br":
			panel.position = Vector2(
				-panel.size.x - m if panel.size.x > 0.0 else -_DEFAULT_SIZE.x - m,
				-panel.size.y - m if panel.size.y > 0.0 else -_DEFAULT_SIZE.y - m
			)

func _dispatch(command_line: String) -> void:
	if not _registry:
		return
	# Use call() with a guarded method existence check so this module
	# fails soft if hosted by a registry without execute_command - matches
	# the defensive pattern in core/extensions/RestApiCommands.gd:138.
	if _registry.has_method("execute_command"):
		_registry.call("execute_command", command_line)

func _get_panel() -> PanelContainer:
	if _panel_path.is_empty():
		return null
	var tree := Engine.get_main_loop() as SceneTree
	if not tree:
		return null
	var n: Node = tree.root.get_node_or_null(NodePath(_panel_path))
	if n is PanelContainer:
		return n
	# Stale cache (scene reload, manual delete) - clear so the next show
	# builds a fresh panel instead of resolving to a freed instance.
	_panel_path = ""
	return null

func _get_overlay_layer() -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if not tree:
		return null

	if not _overlay_layer_path.is_empty():
		var cached: Node = tree.root.get_node_or_null(NodePath(_overlay_layer_path))
		if cached and is_instance_valid(cached):
			return cached
		_overlay_layer_path = ""

	var scene_root: Node = tree.current_scene
	if not scene_root:
		scene_root = tree.root

	var existing: Node = scene_root.get_node_or_null(NodePath(_OVERLAY_LAYER_NAME))
	if existing and is_instance_valid(existing):
		_overlay_layer_path = String(existing.get_path())
		return existing

	var layer: CanvasLayer = CanvasLayer.new()
	layer.name = _OVERLAY_LAYER_NAME
	# Layer 100 so the log filter UI sits above typical HUD overlays
	# (which usually live in the default layer 1). Users can re-parent
	# the panel manually if they need a different stacking order.
	layer.layer = 100
	scene_root.add_child(layer)
	_overlay_layer_path = String(layer.get_path())
	return layer

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _format_path(node: Node) -> String:
	if not node:
		return ""
	return _color_path(str(node.get_path()))

#endregion

@tool
class_name DebugConsoleWatchPanelCommands extends RefCounted

# Tier 8 - floating watch panel widget. Mirrors the design intent of Panku's
# ExpressionMonitor: persistent on-screen overlays that re-evaluate a set of
# GDScript expressions every frame, grouped into sub-panels so users can keep
# (say) "player state" separate from "enemy AI" without the rows interleaving.
#
# This is intentionally stronger than the existing `watch` command, which only
# prints a one-shot snapshot to the console log. The widget here:
#   * stays visible while the game runs (parented to a dedicated CanvasLayer),
#   * updates each frame from a child Node helper (per-frame Expression.execute),
#   * supports pausing / resuming a group without losing its expressions,
#   * persists to / restores from user:// JSON.
#
# Same orchestration contract as the other extension modules: the plugin
# instantiates one of these, holds a strong reference, and calls
# register_commands(registry, core). All Callables stay alive for the lifetime
# of that strong reference. No external helper scripts and no editor-side state.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_DIM := "#888888"
const _COLOR_VALUE := "#E0E0E0"
const _COLOR_EVAL_ERR := "#FFB070"

const _OVERLAY_LAYER_NAME := "DebugConsoleWatchPanels"
const _DEFAULT_GROUP := "Default"
const _PANEL_WIDTH: float = 260.0
const _PANEL_MARGIN: Vector2 = Vector2(8, 8)
const _PANEL_SLOT_OFFSET: Vector2 = Vector2(_PANEL_WIDTH + 12.0, 0.0)
const _ROW_VALUE_TRUNCATE: int = 120
const _CANVAS_LAYER_INDEX: int = 128

# The updater Node lives on the running scene tree (process_mode = ALWAYS so it
# keeps ticking even while the rest of the tree is paused, which matches the
# breakpoint poller and is what users expect from a debug overlay). Its only
# job is to forward _process to back into _tick on this RefCounted; keeping the
# logic here means we don't have to ship a second .gd file.
const _UPDATER_SCRIPT_SOURCE: String = """
extends Node
var commands_ref = null
func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
func _process(_delta: float) -> void:
	if commands_ref and commands_ref.has_method(\"_tick\"):
		commands_ref._tick()
"""

var _registry: Node
var _core: Node

# group_name -> {
#   "panel": PanelContainer,         # the floating sub-panel for this group
#   "vbox": VBoxContainer,           # holds the per-expression row Labels
#   "title": Label,                  # header label (group name + paused tag)
#   "exprs": Dictionary,             # expr_string -> { "expr": Expression, "label": Label }
#   "paused": bool,
#   "slot": int,                     # which screen slot this panel occupies
# }
var _groups: Dictionary = {}

# Tracks which slot indices are currently in use so close+open cycles reuse
# vacated positions instead of marching off the right edge of the screen.
var _used_slots: Dictionary = {}

# Cache of the absolute path so we survive scene reloads gracefully (the cached
# Node would dangle; the path lookup just returns null and we recreate).
var _overlay_layer_path: String = ""
var _updater: Node = null


func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	# Floating UI overlays only make sense at runtime; in the editor there is
	# no game viewport for them to float over, so all commands are "game".
	_registry.register_command("watch_panel_open", _cmd_watch_panel_open, "Open a floating watch panel: watch_panel_open [group_name]", "game")
	_registry.register_command("watch_panel_close", _cmd_watch_panel_close, "Close a watch panel group: watch_panel_close [group]", "game")
	_registry.register_command("watch_panel_add", _cmd_watch_panel_add, "Add an expression to a group: watch_panel_add <group> <expr>", "game")
	_registry.register_command("watch_panel_remove", _cmd_watch_panel_remove, "Remove an expression from a group: watch_panel_remove <group> <expr>", "game")
	_registry.register_command("watch_panel_group", _cmd_watch_panel_group, "Create or focus a group: watch_panel_group <name>", "game")
	_registry.register_command("watch_panel_pause", _cmd_watch_panel_pause, "Pause live updates for a group: watch_panel_pause <group>", "game")
	_registry.register_command("watch_panel_resume", _cmd_watch_panel_resume, "Resume live updates for a group: watch_panel_resume <group>", "game")
	_registry.register_command("watch_panel_save", _cmd_watch_panel_save, "Persist groups+expressions to JSON: watch_panel_save <user://path.json>", "game")
	_registry.register_command("watch_panel_load", _cmd_watch_panel_load, "Restore groups+expressions from JSON: watch_panel_load <user://path.json>", "game")

#region Command implementations

func _cmd_watch_panel_open(args: Array, _piped: String = "") -> String:
	var group_name: String = _DEFAULT_GROUP
	if args.size() > 0:
		var raw: String = str(args[0]).strip_edges()
		if not raw.is_empty():
			group_name = raw
	var created: bool = not _groups.has(group_name)
	var group: Dictionary = _ensure_group(group_name)
	if group.is_empty():
		return _format_error("watch_panel_open: cannot create overlay (no SceneTree root)")
	_focus_group(group_name)
	var verb: String = "Opened" if created else "Focused"
	return _format_success("%s watch panel '%s' at %s" % [verb, _color_path(group_name), _color_number(str(_describe_position(group)))])

func _cmd_watch_panel_close(args: Array, _piped: String = "") -> String:
	var group_name: String = _DEFAULT_GROUP
	if args.size() > 0:
		var raw: String = str(args[0]).strip_edges()
		if not raw.is_empty():
			group_name = raw
	if not _groups.has(group_name):
		return _format_error("watch_panel_close: no such group '%s'" % group_name)
	_destroy_group(group_name)
	return _format_success("Closed watch panel '%s'" % _color_path(group_name))

func _cmd_watch_panel_add(args: Array, _piped: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: watch_panel_add <group> <expr>")
	var group_name: String = str(args[0]).strip_edges()
	if group_name.is_empty():
		return _format_error("watch_panel_add: group name cannot be empty")
	# The expression may contain spaces (CommandRegistry splits on whitespace);
	# rejoin everything past the group name. Strip surrounding quotes to make
	# `watch_panel_add g "player.position.x"` work the way users expect.
	var expr_string: String = _strip_outer_quotes(" ".join(args.slice(1)).strip_edges())
	if expr_string.is_empty():
		return _format_error("watch_panel_add: expression cannot be empty")

	var probe := Expression.new()
	var parse_err: int = probe.parse(expr_string, [])
	if parse_err != OK:
		return _format_error("watch_panel_add: parse failed: %s" % probe.get_error_text())

	var group: Dictionary = _ensure_group(group_name)
	if group.is_empty():
		return _format_error("watch_panel_add: cannot create overlay (no SceneTree root)")
	var exprs: Dictionary = group["exprs"]
	if exprs.has(expr_string):
		return _format_error("watch_panel_add: '%s' already in group '%s'" % [expr_string, group_name])

	var row: Label = Label.new()
	row.text = "%s: <pending>" % expr_string
	row.add_theme_font_size_override("font_size", 12)
	row.add_theme_color_override("font_color", Color.html(_COLOR_VALUE))
	row.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var vbox: VBoxContainer = group["vbox"]
	vbox.add_child(row)

	exprs[expr_string] = {"expr": probe, "label": row}
	_ensure_updater()
	return _format_success("Added %s to '%s' (%s rows)" % [_color_path(expr_string), _color_path(group_name), _color_number(str(exprs.size()))])

func _cmd_watch_panel_remove(args: Array, _piped: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: watch_panel_remove <group> <expr>")
	var group_name: String = str(args[0]).strip_edges()
	if not _groups.has(group_name):
		return _format_error("watch_panel_remove: no such group '%s'" % group_name)
	var expr_string: String = _strip_outer_quotes(" ".join(args.slice(1)).strip_edges())
	if expr_string.is_empty():
		return _format_error("watch_panel_remove: expression cannot be empty")
	var group: Dictionary = _groups[group_name]
	var exprs: Dictionary = group["exprs"]
	if not exprs.has(expr_string):
		return _format_error("watch_panel_remove: '%s' not in group '%s'" % [expr_string, group_name])
	var entry: Dictionary = exprs[expr_string]
	var label: Label = entry.get("label")
	if is_instance_valid(label):
		label.queue_free()
	exprs.erase(expr_string)
	return _format_success("Removed %s from '%s'" % [_color_path(expr_string), _color_path(group_name)])

func _cmd_watch_panel_group(args: Array, _piped: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: watch_panel_group <name>")
	var group_name: String = str(args[0]).strip_edges()
	if group_name.is_empty():
		return _format_error("watch_panel_group: name cannot be empty")
	var created: bool = not _groups.has(group_name)
	var group: Dictionary = _ensure_group(group_name)
	if group.is_empty():
		return _format_error("watch_panel_group: cannot create overlay (no SceneTree root)")
	_focus_group(group_name)
	var verb: String = "Created" if created else "Focused"
	return _format_success("%s group '%s'" % [verb, _color_path(group_name)])

func _cmd_watch_panel_pause(args: Array, _piped: String = "") -> String:
	return _set_paused(args, true, "watch_panel_pause")

func _cmd_watch_panel_resume(args: Array, _piped: String = "") -> String:
	return _set_paused(args, false, "watch_panel_resume")

func _cmd_watch_panel_save(args: Array, _piped: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: watch_panel_save <user://path.json>")
	var path: String = str(args[0]).strip_edges()
	if path.is_empty():
		return _format_error("watch_panel_save: path cannot be empty")
	var payload: Dictionary = {"version": 1, "groups": {}}
	var groups_out: Dictionary = payload["groups"]
	for group_name in _groups.keys():
		var group: Dictionary = _groups[group_name]
		var exprs: Dictionary = group.get("exprs", {})
		var expr_list: Array = []
		# Preserve insertion order so reloading reproduces the visual layout
		# rows-down. Dictionary keys in GDScript iterate in insertion order.
		for k in exprs.keys():
			expr_list.append(str(k))
		groups_out[group_name] = {
			"paused": bool(group.get("paused", false)),
			"exprs": expr_list,
		}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return _format_error("watch_panel_save: cannot open '%s' (err=%s)" % [path, FileAccess.get_open_error()])
	file.store_string(JSON.stringify(payload, "  "))
	file.close()
	return _format_success("Saved %s group(s) to %s" % [_color_number(str(_groups.size())), _color_path(path)])

func _cmd_watch_panel_load(args: Array, _piped: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: watch_panel_load <user://path.json>")
	var path: String = str(args[0]).strip_edges()
	if path.is_empty():
		return _format_error("watch_panel_load: path cannot be empty")
	if not FileAccess.file_exists(path):
		return _format_error("watch_panel_load: file not found '%s'" % path)
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return _format_error("watch_panel_load: cannot open '%s' (err=%s)" % [path, FileAccess.get_open_error()])
	var text: String = file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return _format_error("watch_panel_load: JSON root is not a Dictionary")
	var groups_in: Dictionary = (parsed as Dictionary).get("groups", {})
	if not (groups_in is Dictionary):
		return _format_error("watch_panel_load: 'groups' is missing or not a Dictionary")

	var loaded_groups: int = 0
	var loaded_exprs: int = 0
	var skipped: int = 0
	for group_name_v in groups_in.keys():
		var group_name: String = str(group_name_v)
		if group_name.is_empty():
			continue
		var entry: Variant = groups_in[group_name_v]
		if not (entry is Dictionary):
			continue
		var entry_d: Dictionary = entry
		var group: Dictionary = _ensure_group(group_name)
		if group.is_empty():
			continue
		loaded_groups += 1
		var expr_list: Variant = entry_d.get("exprs", [])
		if expr_list is Array:
			for raw_expr in (expr_list as Array):
				var expr_string: String = str(raw_expr)
				if expr_string.is_empty():
					continue
				var add_result: String = _cmd_watch_panel_add([group_name, expr_string], "")
				# `watch_panel_add` returns a colored error string when parse
				# fails or the expression already exists; we don't want a
				# partial load to look like a total failure, so count separately
				# and surface the skip count in the final summary.
				if add_result.contains("Error"):
					skipped += 1
				else:
					loaded_exprs += 1
		if bool(entry_d.get("paused", false)):
			_set_paused([group_name], true, "watch_panel_load")
	var msg := "Loaded %s group(s), %s expr(s)" % [_color_number(str(loaded_groups)), _color_number(str(loaded_exprs))]
	if skipped > 0:
		msg += " (%s skipped)" % _color_number(str(skipped))
	return _format_success(msg)

#endregion

#region Update loop

# Called from the child Node helper every frame. Kept extremely short so its
# per-frame cost stays predictable even when many rows are watched: skip
# paused groups outright, reuse the already-parsed Expression objects, and
# only stringify when assigning to the Label (Label.text setter does its own
# diff so unchanged text is a cheap no-op).
func _tick() -> void:
	if _groups.is_empty():
		return
	var base: Object = _get_scene_root()
	for group_name in _groups.keys():
		var group: Dictionary = _groups[group_name]
		if bool(group.get("paused", false)):
			continue
		var panel: PanelContainer = group.get("panel")
		if not is_instance_valid(panel):
			# Panel was freed externally (scene reload). Drop the entry so we
			# don't keep iterating dead state; the user can re-open with the
			# same group name to rebuild it.
			_drop_dead_group(group_name)
			continue
		var exprs: Dictionary = group["exprs"]
		for expr_string in exprs.keys():
			var entry: Dictionary = exprs[expr_string]
			var expr: Expression = entry.get("expr")
			var label: Label = entry.get("label")
			if expr == null or not is_instance_valid(label):
				continue
			var value: Variant = expr.execute([], base, false)
			if expr.has_execute_failed():
				label.text = "%s: <err: %s>" % [expr_string, expr.get_error_text()]
				label.add_theme_color_override("font_color", Color.html(_COLOR_EVAL_ERR))
			else:
				label.text = "%s: %s" % [expr_string, _stringify(value)]
				label.add_theme_color_override("font_color", Color.html(_COLOR_VALUE))

#endregion

#region Group lifecycle

func _ensure_group(group_name: String) -> Dictionary:
	if _groups.has(group_name):
		return _groups[group_name]
	var layer: CanvasLayer = _get_overlay_layer()
	if not layer:
		return {}
	var slot: int = _allocate_slot()
	var panel: PanelContainer = PanelContainer.new()
	panel.name = "WatchGroup_%s" % _safe_node_name(group_name)
	panel.custom_minimum_size = Vector2(_PANEL_WIDTH, 0.0)
	panel.position = _slot_position(slot)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	# Dim, opaque-ish backdrop so foreground text stays readable over noisy
	# game scenes. Designers can override by inspecting the node at runtime.
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.08, 0.10, 0.86)
	sb.border_color = Color(0.35, 0.55, 0.70, 0.9)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(4)
	sb.content_margin_left = 6
	sb.content_margin_right = 6
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	panel.add_theme_stylebox_override("panel", sb)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 2)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = group_name
	title.add_theme_font_size_override("font_size", 13)
	title.add_theme_color_override("font_color", Color.html(_COLOR_PATH))
	vbox.add_child(title)

	var sep := HSeparator.new()
	vbox.add_child(sep)

	layer.add_child(panel)

	var group: Dictionary = {
		"panel": panel,
		"vbox": vbox,
		"title": title,
		"exprs": {},
		"paused": false,
		"slot": slot,
	}
	_groups[group_name] = group
	_ensure_updater()
	return group

func _destroy_group(group_name: String) -> void:
	if not _groups.has(group_name):
		return
	var group: Dictionary = _groups[group_name]
	var slot: int = int(group.get("slot", -1))
	if slot >= 0:
		_used_slots.erase(slot)
	var panel: PanelContainer = group.get("panel")
	if is_instance_valid(panel):
		panel.queue_free()
	_groups.erase(group_name)

func _drop_dead_group(group_name: String) -> void:
	# Same as _destroy_group but does not touch the (already-dead) panel node.
	if not _groups.has(group_name):
		return
	var group: Dictionary = _groups[group_name]
	var slot: int = int(group.get("slot", -1))
	if slot >= 0:
		_used_slots.erase(slot)
	_groups.erase(group_name)

func _focus_group(group_name: String) -> void:
	if not _groups.has(group_name):
		return
	var group: Dictionary = _groups[group_name]
	var panel: PanelContainer = group.get("panel")
	if not is_instance_valid(panel):
		return
	# move_child to last so this panel renders on top of its siblings - the
	# CanvasItem draw order under a CanvasLayer follows tree-child order.
	var parent: Node = panel.get_parent()
	if parent:
		parent.move_child(panel, parent.get_child_count() - 1)

func _set_paused(args: Array, value: bool, cmd_name: String) -> String:
	if args.is_empty():
		return _format_error("Usage: %s <group>" % cmd_name)
	var group_name: String = str(args[0]).strip_edges()
	if not _groups.has(group_name):
		return _format_error("%s: no such group '%s'" % [cmd_name, group_name])
	var group: Dictionary = _groups[group_name]
	group["paused"] = value
	var title: Label = group.get("title")
	if is_instance_valid(title):
		title.text = "%s%s" % [group_name, "  [paused]" if value else ""]
	return _format_success("Group '%s' %s" % [_color_path(group_name), "paused" if value else "resumed"])

#endregion

#region Overlay layer + updater

# Lazy CanvasLayer creator. We re-use one shared layer for every group panel
# so the user only ever sees a single overlay node in the scene tree. The
# cached node path is re-validated on every call because scene reloads can
# free the node out from under us.
func _get_overlay_layer() -> CanvasLayer:
	var tree := Engine.get_main_loop() as SceneTree
	if not tree:
		return null
	if not _overlay_layer_path.is_empty():
		var cached: Node = tree.root.get_node_or_null(NodePath(_overlay_layer_path))
		if cached is CanvasLayer and is_instance_valid(cached):
			return cached
		_overlay_layer_path = ""
		# All our group panels lived under that layer; their dictionary entries
		# are now stale. Clearing here means re-issuing watch_panel_open
		# rebuilds cleanly instead of writing to dangling nodes.
		_groups.clear()
		_used_slots.clear()

	var scene_root: Node = tree.current_scene
	if not scene_root:
		scene_root = tree.root
	var existing: Node = scene_root.get_node_or_null(NodePath(_OVERLAY_LAYER_NAME))
	if existing is CanvasLayer and is_instance_valid(existing):
		_overlay_layer_path = String(existing.get_path())
		return existing
	var layer := CanvasLayer.new()
	layer.name = _OVERLAY_LAYER_NAME
	# High layer index so we draw on top of HUDs that use the default 0/1.
	layer.layer = _CANVAS_LAYER_INDEX
	scene_root.add_child(layer)
	_overlay_layer_path = String(layer.get_path())
	return layer

func _ensure_updater() -> Node:
	if is_instance_valid(_updater):
		return _updater
	var tree := Engine.get_main_loop() as SceneTree
	if not tree or not tree.root:
		return null
	# Build the tiny per-frame Node from in-line source so this module stays a
	# single file. Same trick used by BreakpointCommands._ensure_poller.
	var script := GDScript.new()
	script.source_code = _UPDATER_SCRIPT_SOURCE
	var reload_err := script.reload()
	if reload_err != OK:
		return null
	var node := Node.new()
	node.name = "DebugConsoleWatchPanelUpdater"
	node.set_script(script)
	node.set("commands_ref", self)
	tree.root.add_child(node)
	_updater = node
	return _updater

func _allocate_slot() -> int:
	# Linear scan; we never have many panels so an int counter would be
	# wasteful and would miss the goal of reusing freed slots.
	var i: int = 0
	while _used_slots.has(i):
		i += 1
	_used_slots[i] = true
	return i

func _slot_position(slot: int) -> Vector2:
	# Two columns of panels stacked vertically; the second column kicks in
	# once 4 panels are open so we don't immediately march off-screen on a
	# typical 1280x720 viewport.
	var col: int = slot / 4
	var row: int = slot % 4
	return _PANEL_MARGIN + Vector2(col, row) * _PANEL_SLOT_OFFSET

func _describe_position(group: Dictionary) -> Vector2:
	var panel: PanelContainer = group.get("panel")
	if is_instance_valid(panel):
		return panel.position
	return Vector2.ZERO

#endregion

#region Helpers

func _get_scene_root() -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if not tree:
		return null
	if tree.current_scene:
		return tree.current_scene
	return tree.root

func _stringify(value: Variant) -> String:
	# Compact representation that fits inside a single row Label. Long strings
	# and large containers are truncated so a runaway watch (e.g. `range(10000)`)
	# doesn't blow up the UI layout pass every frame.
	var text: String
	if value == null:
		text = "<null>"
	elif value is String or value is StringName:
		text = "\"%s\"" % str(value)
	elif value is float:
		text = "%.4f" % float(value)
	elif value is Object:
		var obj: Object = value
		if is_instance_valid(obj):
			text = "<%s#%d>" % [obj.get_class(), obj.get_instance_id()]
		else:
			text = "<freed Object>"
	else:
		text = str(value)
	if text.length() > _ROW_VALUE_TRUNCATE:
		text = text.substr(0, _ROW_VALUE_TRUNCATE - 3) + "..."
	return text

func _strip_outer_quotes(s: String) -> String:
	if s.length() >= 2 and s.begins_with("\"") and s.ends_with("\""):
		return s.substr(1, s.length() - 2)
	return s

func _safe_node_name(s: String) -> String:
	# Node.name disallows /, :, @, ., %. Replace the most likely offenders so
	# users can use punctuation in group names without breaking node lookup.
	var out: String = s
	for ch in ["/", ":", "@", ".", "%", " "]:
		out = out.replace(ch, "_")
	if out.is_empty():
		out = "Group"
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

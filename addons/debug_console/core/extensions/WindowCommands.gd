@tool
class_name DebugConsoleWindowCommands extends RefCounted

# Coordinator for Panku-style floating dev windows. Per-window-kind modules
# (inspector, watch_panel, texture viewer, log, ...) instantiate their own
# Godot Window node and call register(id, window, kind) to hand it to this
# coordinator. The coordinator then owns the cross-cutting layout surface
# (open / close / list / move / resize / dock / minimize / restore) plus
# JSON-backed save_layout / load_layout so users can tile multiple inspector
# + watch + texture viewer panels and persist the arrangement between runs.
#
# `window_open` will also lazy-instantiate a stub Window for kinds whose
# module hasn't registered anything yet, so demos and tests stay usable
# even before the per-kind modules ship. The `custom` kind takes a scene
# path (PackedScene whose root is Window, or any scene we wrap inside one).
#
# All commands are registered under the "game" context: sub-windows depend
# on a live SceneTree to host them, which isn't reliably available in the
# editor @tool path.

const _COLOR_ERROR := "#FF4444"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_KIND := "#B0C4DE"

const _VALID_KINDS: Array = ["inspector", "watch_panel", "texture", "log", "custom"]
const _VALID_DOCK: Array = ["tl", "tr", "bl", "br", "center"]

const _LAYOUT_VERSION := 1

# Each entry shape: {
#   "id": String, "kind": String, "window": Window,
#   "saved_rect": Rect2i (geometry remembered across minimize),
#   "minimized": bool,
# }
# Keyed by id so register() can replace entries by id on hot-reload.
var _windows: Dictionary = {}

var _registry: Node
var _core: Node

# Monotonic counter for auto-generated ids inside window_open. Walked
# forward (never reset) so a freshly opened inspector never collides with
# one that a module is about to re-register under "inspector_0".
var _next_auto_id: int = 0

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("window_open", _cmd_window_open, "Open a floating dev window: window_open <inspector|watch_panel|texture|log|custom> [args]", "game")
	_registry.register_command("window_close", _cmd_window_close, "Close a window by id, or all: window_close <id|all>", "game")
	_registry.register_command("window_list", _cmd_window_list, "List registered windows (id, kind, rect, visible)", "game")
	_registry.register_command("window_move", _cmd_window_move, "Move a window: window_move <id> <x,y>", "game")
	_registry.register_command("window_resize", _cmd_window_resize, "Resize a window: window_resize <id> <w,h>", "game")
	_registry.register_command("window_dock", _cmd_window_dock, "Dock a window to a corner: window_dock <id> <tl|tr|bl|br|center>", "game")
	_registry.register_command("window_minimize", _cmd_window_minimize, "Minimize a window (id stays alive): window_minimize <id>", "game")
	_registry.register_command("window_restore", _cmd_window_restore, "Restore a minimized window: window_restore <id>", "game")
	_registry.register_command("window_save_layout", _cmd_window_save_layout, "Save layout to JSON: window_save_layout <user://path.json>", "game")
	_registry.register_command("window_load_layout", _cmd_window_load_layout, "Load layout from JSON: window_load_layout <user://path.json>", "game")

#region Public coordinator API

# Called by per-window-kind modules (inspector, watch_panel, texture, log)
# after they've instanced and parented their own Window. The coordinator
# does NOT take scene-tree ownership of the window - the caller controls
# its lifetime. We only track (id, kind, window) so layout commands and
# save/load can target it by id.
#
# Returns true on success. Re-registering the same id replaces the prior
# entry; the previous Window is freed if it's distinct from the new one,
# which lets modules hot-reload their windows cleanly.
func register(id: String, window: Window, kind: String) -> bool:
	var clean_id: String = id.strip_edges()
	if clean_id.is_empty():
		push_warning("WindowCommands.register: empty id rejected")
		return false
	if not is_instance_valid(window):
		push_warning("WindowCommands.register: invalid window for id '%s'" % clean_id)
		return false

	var clean_kind: String = kind.strip_edges()
	if clean_kind.is_empty():
		clean_kind = "custom"

	if _windows.has(clean_id):
		var prev_entry: Dictionary = _windows[clean_id]
		var prev_window: Variant = prev_entry.get("window")
		if prev_window is Window and is_instance_valid(prev_window) and prev_window != window:
			(prev_window as Window).queue_free()

	_windows[clean_id] = {
		"id": clean_id,
		"kind": clean_kind,
		"window": window,
		"saved_rect": Rect2i(),
		"minimized": false,
	}

	# Free the Window when the user clicks the native close button. We
	# capture the Window reference in the lambda so re-registrations don't
	# yank the new entry out from under us via a stale id binding.
	var captured: Window = window
	if not _is_close_hooked(captured):
		captured.close_requested.connect(func() -> void:
			if is_instance_valid(captured):
				captured.queue_free()
		)
	return true

# Drops the entry for `id` without touching the window itself. Use this
# when a per-kind module wants to detach without freeing.
func unregister(id: String) -> bool:
	return _windows.erase(id)

# Public lookup so per-kind modules can find a window they registered.
# Returns null if the entry is missing or the underlying Window was freed.
func get_window(id: String) -> Window:
	if not _windows.has(id):
		return null
	var w: Variant = _windows[id].get("window")
	if w is Window and is_instance_valid(w):
		return w
	return null

#endregion

#region Commands

func _cmd_window_open(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: window_open <inspector|watch_panel|texture|log|custom> [args]")
	var kind: String = str(args[0]).strip_edges().to_lower()
	if not _VALID_KINDS.has(kind):
		return _format_error("Unknown kind '%s' (use one of: %s)" % [kind, ", ".join(_VALID_KINDS)])

	var extra: Array = []
	for i in range(1, args.size()):
		extra.append(str(args[i]))

	var window: Window = null
	if kind == "custom":
		if extra.is_empty():
			return _format_error("window_open custom requires a scene path")
		window = _instantiate_scene_window(extra[0])
		if not window:
			return _format_error("Could not load scene as Window: %s" % extra[0])
	else:
		window = _build_stub_window(kind, extra)

	var parent: Node = _get_window_parent()
	if not parent:
		window.queue_free()
		return _format_error("No scene tree available to host the window")
	parent.add_child(window)

	var id: String = _next_id(kind)
	register(id, window, kind)
	return _format_success("Opened %s as %s" % [_color_kind(kind), _color_path(id)])

func _cmd_window_close(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: window_close <id|all>")
	var target: String = str(args[0]).strip_edges()
	if target == "all":
		var ids: Array = _windows.keys().duplicate()
		var n: int = 0
		for id in ids:
			if _close_window(str(id)):
				n += 1
			_windows.erase(id)
		return _format_success("Closed %s window(s)" % _color_number(str(n)))
	if not _windows.has(target):
		return _format_error("Unknown window id: %s" % target)
	var freed: bool = _close_window(target)
	_windows.erase(target)
	if freed:
		return _format_success("Closed %s" % _color_path(target))
	return _format_success("Removed stale entry %s" % _color_path(target))

func _cmd_window_list(args: Array, piped_input: String = "") -> String:
	_prune_dead()
	if _windows.is_empty():
		return "(no windows registered)"
	var ids: Array = _windows.keys()
	ids.sort()
	var lines: Array[String] = []
	lines.append("%-18s %-12s %-22s %-7s %s" % ["id", "kind", "rect (x,y w,h)", "visible", "state"])
	for id in ids:
		var entry: Dictionary = _windows[id]
		var w: Variant = entry.get("window")
		if not (w is Window) or not is_instance_valid(w):
			continue
		var win: Window = w
		var rect_str: String = "%d,%d %dx%d" % [int(win.position.x), int(win.position.y), int(win.size.x), int(win.size.y)]
		var vis: String = "yes" if win.visible else "no"
		var state: String = "min" if bool(entry.get("minimized", false)) else "open"
		lines.append("%-18s %-12s %-22s %-7s %s" % [
			_color_path(str(id)),
			_color_kind(str(entry.get("kind", "?"))),
			rect_str,
			vis,
			state,
		])
	return "\n".join(lines)

func _cmd_window_move(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: window_move <id> <x,y>")
	var id: String = str(args[0]).strip_edges()
	var w: Window = get_window(id)
	if not w:
		return _format_error("Unknown window id: %s" % id)
	var parsed: Dictionary = _try_parse_vec2i(str(args[1]))
	if not bool(parsed.get("ok", false)):
		return _format_error("Could not parse x,y: %s" % str(args[1]))
	var v: Vector2i = parsed.get("value", Vector2i.ZERO)
	w.position = v
	return _format_success("%s -> %d,%d" % [_color_path(id), v.x, v.y])

func _cmd_window_resize(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: window_resize <id> <w,h>")
	var id: String = str(args[0]).strip_edges()
	var win: Window = get_window(id)
	if not win:
		return _format_error("Unknown window id: %s" % id)
	var parsed: Dictionary = _try_parse_vec2i(str(args[1]))
	if not bool(parsed.get("ok", false)):
		return _format_error("Could not parse w,h: %s" % str(args[1]))
	var v: Vector2i = parsed.get("value", Vector2i.ZERO)
	if v.x <= 0 or v.y <= 0:
		return _format_error("Size must be positive (got %dx%d)" % [v.x, v.y])
	win.size = v
	return _format_success("%s -> %dx%d" % [_color_path(id), v.x, v.y])

func _cmd_window_dock(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: window_dock <id> <tl|tr|bl|br|center>")
	var id: String = str(args[0]).strip_edges()
	var corner: String = str(args[1]).strip_edges().to_lower()
	if not _VALID_DOCK.has(corner):
		return _format_error("Unknown dock '%s' (use one of: %s)" % [corner, ", ".join(_VALID_DOCK)])
	var win: Window = get_window(id)
	if not win:
		return _format_error("Unknown window id: %s" % id)
	var screen: Vector2i = _screen_size_for(win)
	var sz: Vector2i = win.size
	var pos: Vector2i = Vector2i.ZERO
	match corner:
		"tl":
			pos = Vector2i(0, 0)
		"tr":
			pos = Vector2i(maxi(0, screen.x - sz.x), 0)
		"bl":
			pos = Vector2i(0, maxi(0, screen.y - sz.y))
		"br":
			pos = Vector2i(maxi(0, screen.x - sz.x), maxi(0, screen.y - sz.y))
		"center":
			pos = Vector2i(maxi(0, (screen.x - sz.x) / 2), maxi(0, (screen.y - sz.y) / 2))
	win.position = pos
	return _format_success("%s docked %s -> %d,%d" % [_color_path(id), corner, pos.x, pos.y])

func _cmd_window_minimize(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: window_minimize <id>")
	var id: String = str(args[0]).strip_edges()
	if not _windows.has(id):
		return _format_error("Unknown window id: %s" % id)
	var entry: Dictionary = _windows[id]
	var w: Variant = entry.get("window")
	if not (w is Window) or not is_instance_valid(w):
		return _format_error("Window for '%s' was freed" % id)
	var win: Window = w
	if bool(entry.get("minimized", false)):
		return _format_success("%s already minimized" % _color_path(id))
	# Save geometry so restore can put the window back where the user had
	# it. Hide instead of setting Window.mode = MODE_MINIMIZED because
	# embedded sub-windows do not honor the minimized mode reliably; hide
	# is the portable fallback that works for both top-level and embedded.
	entry["saved_rect"] = Rect2i(win.position, win.size)
	entry["minimized"] = true
	win.visible = false
	return _format_success("Minimized %s" % _color_path(id))

func _cmd_window_restore(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: window_restore <id>")
	var id: String = str(args[0]).strip_edges()
	if not _windows.has(id):
		return _format_error("Unknown window id: %s" % id)
	var entry: Dictionary = _windows[id]
	var w: Variant = entry.get("window")
	if not (w is Window) or not is_instance_valid(w):
		return _format_error("Window for '%s' was freed" % id)
	var win: Window = w
	if not bool(entry.get("minimized", false)):
		win.visible = true
		return _format_success("%s already restored" % _color_path(id))
	var rect: Rect2i = entry.get("saved_rect", Rect2i())
	if rect.size.x > 0 and rect.size.y > 0:
		win.position = rect.position
		win.size = rect.size
	win.visible = true
	entry["minimized"] = false
	return _format_success("Restored %s" % _color_path(id))

func _cmd_window_save_layout(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: window_save_layout <user://path.json>")
	var path: String = str(args[0]).strip_edges()
	if path.is_empty():
		return _format_error("Path cannot be empty")
	_prune_dead()
	var data: Array = []
	for id in _windows.keys():
		var entry: Dictionary = _windows[id]
		var w: Variant = entry.get("window")
		if not (w is Window) or not is_instance_valid(w):
			continue
		var win: Window = w
		data.append({
			"id": str(id),
			"kind": str(entry.get("kind", "custom")),
			"x": int(win.position.x),
			"y": int(win.position.y),
			"w": int(win.size.x),
			"h": int(win.size.y),
			"visible": win.visible,
			"minimized": bool(entry.get("minimized", false)),
		})
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if not f:
		return _format_error("Could not open '%s' for write: %s" % [path, error_string(FileAccess.get_open_error())])
	f.store_string(JSON.stringify({"version": _LAYOUT_VERSION, "windows": data}, "\t"))
	f.close()
	return _format_success("Saved %s windows -> %s" % [_color_number(str(data.size())), _color_path(path)])

func _cmd_window_load_layout(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: window_load_layout <user://path.json>")
	var path: String = str(args[0]).strip_edges()
	if not FileAccess.file_exists(path):
		return _format_error("File not found: %s" % path)
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if not f:
		return _format_error("Could not open '%s' for read: %s" % [path, error_string(FileAccess.get_open_error())])
	var text: String = f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary) or not (parsed as Dictionary).has("windows"):
		return _format_error("Layout file malformed: expected { \"windows\": [...] }")
	var entries: Array = (parsed as Dictionary).get("windows", [])
	var applied: int = 0
	var skipped: int = 0
	for raw in entries:
		if not (raw is Dictionary):
			skipped += 1
			continue
		var entry_dict: Dictionary = raw
		var id: String = str(entry_dict.get("id", "")).strip_edges()
		if id.is_empty():
			skipped += 1
			continue
		# We only re-apply geometry to windows currently registered. We do
		# not spawn new windows here on purpose: layout files capture
		# geometry, not authorship. Per-kind modules are responsible for
		# bringing their windows back up on load.
		var win: Window = get_window(id)
		if not win:
			skipped += 1
			continue
		win.position = Vector2i(int(entry_dict.get("x", win.position.x)), int(entry_dict.get("y", win.position.y)))
		var ww: int = int(entry_dict.get("w", win.size.x))
		var hh: int = int(entry_dict.get("h", win.size.y))
		if ww > 0 and hh > 0:
			win.size = Vector2i(ww, hh)
		var live: Dictionary = _windows[id]
		var was_minimized: bool = bool(entry_dict.get("minimized", false))
		live["minimized"] = was_minimized
		if was_minimized:
			live["saved_rect"] = Rect2i(win.position, win.size)
			win.visible = false
		else:
			win.visible = bool(entry_dict.get("visible", true))
		applied += 1
	return _format_success("Loaded layout: %s applied, %s skipped" % [_color_number(str(applied)), _color_number(str(skipped))])

#endregion

#region Helpers

# Drops entries whose Window has been freed (user closed via native chrome,
# scene reloaded, etc). Called from list and save so the surface that the
# user actually inspects is always current.
func _prune_dead() -> void:
	var stale: Array[String] = []
	for id in _windows.keys():
		var w: Variant = _windows[id].get("window")
		if not (w is Window) or not is_instance_valid(w):
			stale.append(str(id))
	for id in stale:
		_windows.erase(id)

# Frees the Window for `id` if it's still valid. Does NOT erase from the
# dictionary - callers do that explicitly so the keys() iteration in
# window_close stays stable.
func _close_window(id: String) -> bool:
	if not _windows.has(id):
		return false
	var w: Variant = _windows[id].get("window")
	if not (w is Window) or not is_instance_valid(w):
		return false
	(w as Window).queue_free()
	return true

# Returns true if a close_requested handler owned by this coordinator is
# already wired up for the window. GDScript lambdas bind to the enclosing
# script instance, so we identify our own hook by checking the connection's
# Callable.get_object() against self. This prevents register() being called
# twice for the same Window from stacking duplicate queue_free handlers.
func _is_close_hooked(w: Window) -> bool:
	if not is_instance_valid(w):
		return false
	for c in w.close_requested.get_connections():
		var callable: Callable = c.get("callable", Callable())
		if callable.is_valid() and callable.get_object() == self:
			return true
	return false

func _next_id(kind: String) -> String:
	# Bounded loop: in practice we'll exit on the first iteration, but cap
	# the search so a pathologically full dict can't spin forever.
	for _i in range(10000):
		var candidate: String = "%s_%d" % [kind, _next_auto_id]
		_next_auto_id += 1
		if not _windows.has(candidate):
			return candidate
	return "%s_%d" % [kind, _next_auto_id]

func _get_window_parent() -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if not tree:
		return null
	if tree.current_scene:
		return tree.current_scene
	return tree.root

# Loads a PackedScene and returns its root as Window. If the root is not a
# Window we wrap it in one so the layout API still has a Window handle to
# manipulate - this matches Panku's behavior where arbitrary content can
# be hosted in a floating dev panel.
func _instantiate_scene_window(scene_path: String) -> Window:
	if not ResourceLoader.exists(scene_path):
		return null
	var packed: PackedScene = load(scene_path) as PackedScene
	if not packed:
		return null
	var inst: Node = packed.instantiate()
	if not inst:
		return null
	if inst is Window:
		return inst
	var wrapper: Window = Window.new()
	wrapper.title = scene_path.get_file()
	wrapper.size = Vector2i(420, 280)
	wrapper.add_child(inst)
	return wrapper

# Last-resort stub used by window_open for built-in kinds whose module
# hasn't registered yet. The placeholder is intentionally minimal: title
# + body label naming the missing module. Real modules supersede this by
# constructing their own Window and calling register(id, window, kind).
func _build_stub_window(kind: String, extra: Array) -> Window:
	var w: Window = Window.new()
	w.title = "%s (stub)" % kind.capitalize()
	w.size = Vector2i(360, 240)
	w.unresizable = false
	var label: Label = Label.new()
	label.anchor_right = 1.0
	label.anchor_bottom = 1.0
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.text = "[%s window placeholder]\nNo module has registered for this kind yet.\nargs: %s" % [
		kind, ", ".join(extra),
	]
	w.add_child(label)
	return w

# Returns the bounding box used for window_dock. For embedded sub-windows
# the parent viewport defines the dockable area; for native top-level
# windows we fall back to the primary monitor.
func _screen_size_for(w: Window) -> Vector2i:
	if is_instance_valid(w):
		var vp: Viewport = w.get_viewport()
		if vp:
			var vs: Vector2 = vp.get_visible_rect().size
			if vs.x > 0 and vs.y > 0:
				return Vector2i(int(vs.x), int(vs.y))
	return DisplayServer.screen_get_size()

# Parses "x,y" or "xXy" (case-insensitive on the separator). Returns
# { "ok": bool, "value": Vector2i }. Using a Dictionary rather than a
# sentinel Vector2i avoids ambiguity when 0,0 is a legitimate value.
func _try_parse_vec2i(s: String) -> Dictionary:
	var trimmed: String = s.strip_edges()
	if trimmed.is_empty():
		return {"ok": false, "value": Vector2i.ZERO}
	var parts: PackedStringArray
	if trimmed.contains(","):
		parts = trimmed.split(",")
	elif trimmed.to_lower().contains("x"):
		parts = trimmed.to_lower().split("x")
	else:
		return {"ok": false, "value": Vector2i.ZERO}
	if parts.size() != 2:
		return {"ok": false, "value": Vector2i.ZERO}
	var a: String = String(parts[0]).strip_edges()
	var b: String = String(parts[1]).strip_edges()
	if not (a.is_valid_int() or a.is_valid_float()):
		return {"ok": false, "value": Vector2i.ZERO}
	if not (b.is_valid_int() or b.is_valid_float()):
		return {"ok": false, "value": Vector2i.ZERO}
	return {"ok": true, "value": Vector2i(int(a.to_float()), int(b.to_float()))}

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

func _color_kind(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_KIND, s]

#endregion

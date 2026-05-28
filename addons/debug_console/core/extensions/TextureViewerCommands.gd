@tool
class_name DebugConsoleTextureViewerCommands extends RefCounted

# Tier 6 (game context) - floating Window viewers for Texture2D assets and
# live node textures. Each `tex_show` invocation spawns a Window parented to
# the root viewport so the window survives scene reloads while staying out of
# the user's gameplay tree. Sources accepted by `tex_show`:
#   * res:// or user:// path  -> ResourceLoader.load() cast to Texture2D
#   * node_path.property      -> resolves the node, reads the named property
#                                via Object.get() (e.g. `Player.texture`)
#
# For viewport-backed textures (ViewportTexture, or any Viewport/SubViewport
# property), the viewer hooks SceneTree.process_frame and re-reads the source
# each frame so the displayed image tracks live rendering. A ViewportTexture
# is already live on its own, but re-reading covers the case where the user
# reassigns the property (e.g. swapping Sprite2D textures per frame) and
# keeps behaviour predictable across every source flavor.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"

var _registry: Node
var _core: Node

# id -> { window: Window, rect: TextureRect, source: String,
#         auto_update: bool, zoom: float, base_size: Vector2i }
var _windows: Dictionary = {}
var _id_counter: int = 0
var _frame_callback_connected: bool = false

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("tex_show", _cmd_tex_show, "Open a floating Texture2D viewer: tex_show <res://path | node_path.property>", "game")
	_registry.register_command("tex_close", _cmd_tex_close, "Close a viewer: tex_close <window_id|all>", "game")
	_registry.register_command("tex_list", _cmd_tex_list, "List active texture viewer windows", "game")
	_registry.register_command("tex_save_png", _cmd_tex_save_png, "Save current texture as PNG: tex_save_png <window_id> <user://path.png>", "game")
	_registry.register_command("tex_save_jpg", _cmd_tex_save_jpg, "Save current texture as JPG: tex_save_jpg <window_id> <user://path.jpg>", "game")
	_registry.register_command("tex_zoom", _cmd_tex_zoom, "Resize the viewer window by a factor of its source size: tex_zoom <window_id> <factor>", "game")
	_registry.register_command("tex_dump_info", _cmd_tex_dump_info, "Print width/height/format/mipmap status: tex_dump_info <window_id>", "game")

#region commands

func _cmd_tex_show(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: tex_show <res://path | node_path.property>")
	var source: String = str(args[0]).strip_edges()
	if source.is_empty():
		return _format_error("Empty source.")

	var resolved: Dictionary = _resolve_source(source)
	if resolved.has("error"):
		return _format_error(String(resolved["error"]))
	var tex: Texture2D = resolved["texture"]
	var auto_update: bool = bool(resolved.get("auto_update", false))

	var tree := Engine.get_main_loop() as SceneTree
	if not tree or not tree.root:
		return _format_error("No SceneTree available.")

	_id_counter += 1
	var win_id: String = "tex_%d" % _id_counter

	var tex_size: Vector2i = _texture_size(tex)
	if tex_size == Vector2i.ZERO:
		tex_size = Vector2i(256, 256)

	var window: Window = Window.new()
	window.title = "Texture: %s" % source
	window.name = "TextureViewer_%s" % win_id
	window.min_size = Vector2i(64, 64)
	window.size = tex_size
	# Non-exclusive: lets the user keep interacting with the game while
	# inspecting textures. Transient binding to the main window keeps the
	# OS window manager treating these as tool palettes.
	window.exclusive = false
	window.transient = true
	window.visible = true

	var rect: TextureRect = TextureRect.new()
	rect.name = "TextureRect"
	rect.texture = tex
	# EXPAND_IGNORE_SIZE + STRETCH_KEEP_ASPECT_CENTERED: let the user resize
	# the OS window freely and keep the texture centered & aspect-correct
	# inside the new bounds rather than clipping it.
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	window.add_child(rect)
	rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	tree.root.add_child(window)

	var entry: Dictionary = {
		"window": window,
		"rect": rect,
		"source": source,
		"auto_update": auto_update,
		"zoom": 1.0,
		"base_size": tex_size,
	}
	_windows[win_id] = entry

	# bind() captures the id so the connection knows which entry to evict
	# when the user closes the OS window via its X button.
	window.close_requested.connect(_on_window_close_requested.bind(win_id))

	if auto_update:
		_ensure_frame_callback(tree)

	return _format_success("Opened %s [%s] %dx%d source=%s live=%s" % [
		_color_path(win_id),
		tex.get_class(),
		tex_size.x, tex_size.y,
		_color_path(source),
		"yes" if auto_update else "no",
	])

func _cmd_tex_close(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: tex_close <window_id|all>")
	var target: String = str(args[0]).strip_edges()
	if target == "all":
		var count: int = _windows.size()
		var ids: Array = _windows.keys().duplicate()
		for id in ids:
			_close_window(String(id))
		return _format_success("Closed %s window(s)." % _color_number(str(count)))
	if not _windows.has(target):
		return _format_error("No viewer with id '%s'." % target)
	_close_window(target)
	return _format_success("Closed %s." % _color_path(target))

func _cmd_tex_list(args: Array, piped_input: String = "") -> String:
	if _windows.is_empty():
		return "No active texture viewers."
	var lines: PackedStringArray = ["Active texture viewers (%d):" % _windows.size()]
	var ids: Array = _windows.keys()
	ids.sort()
	for id in ids:
		var entry: Dictionary = _windows[id]
		var rect_node: TextureRect = entry.get("rect")
		var size_str: String = "?"
		if rect_node and is_instance_valid(rect_node) and rect_node.texture:
			var s: Vector2i = _texture_size(rect_node.texture)
			size_str = "%dx%d" % [s.x, s.y]
		lines.append("  %s %s [%s] live=%s zoom=%s" % [
			_color_path(String(id)),
			_color_path(String(entry.get("source", ""))),
			size_str,
			"yes" if bool(entry.get("auto_update", false)) else "no",
			_color_number(str(entry.get("zoom", 1.0))),
		])
	return "\n".join(lines)

func _cmd_tex_save_png(args: Array, piped_input: String = "") -> String:
	return _save_image(args, "png")

func _cmd_tex_save_jpg(args: Array, piped_input: String = "") -> String:
	return _save_image(args, "jpg")

func _cmd_tex_zoom(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: tex_zoom <window_id> <factor>")
	var id: String = str(args[0]).strip_edges()
	var raw: String = str(args[1]).strip_edges()
	if not raw.is_valid_float():
		return _format_error("factor must be a number (got '%s')" % raw)
	var factor: float = raw.to_float()
	if factor <= 0.0:
		return _format_error("factor must be > 0 (got %s)" % str(factor))
	if not _windows.has(id):
		return _format_error("No viewer with id '%s'." % id)
	var entry: Dictionary = _windows[id]
	var window: Window = entry.get("window")
	if not (window and is_instance_valid(window)):
		return _format_error("Viewer window is no longer valid.")
	var base: Vector2i = entry.get("base_size", Vector2i(256, 256))
	# clamp to >=1 so a 0.001x zoom on a 64x64 texture still produces a
	# usable window instead of asking the OS for a degenerate 0x0 surface.
	var new_size: Vector2i = Vector2i(
		maxi(1, int(round(float(base.x) * factor))),
		maxi(1, int(round(float(base.y) * factor)))
	)
	window.size = new_size
	entry["zoom"] = factor
	return _format_success("Zoomed %s to %sx (%dx%d)" % [
		_color_path(id),
		_color_number(str(factor)),
		new_size.x, new_size.y,
	])

func _cmd_tex_dump_info(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: tex_dump_info <window_id>")
	var id: String = str(args[0]).strip_edges()
	if not _windows.has(id):
		return _format_error("No viewer with id '%s'." % id)
	var entry: Dictionary = _windows[id]
	var rect: TextureRect = entry.get("rect")
	if not (rect and is_instance_valid(rect)):
		return _format_error("Viewer TextureRect is no longer valid.")
	var tex: Texture2D = rect.texture
	if not tex:
		return _format_error("No texture currently assigned.")

	var size: Vector2i = _texture_size(tex)
	var lines: PackedStringArray = []
	lines.append("Texture info for %s (%s):" % [_color_path(id), _color_path(String(entry.get("source", "")))])
	lines.append("  class: %s" % tex.get_class())
	lines.append("  width: %s" % _color_number(str(size.x)))
	lines.append("  height: %s" % _color_number(str(size.y)))

	# Compressed textures (CompressedTexture2D for BPTC/ETC2/...) refuse
	# get_image() on some platforms; record the failure rather than crashing.
	var format_str: String = "?"
	var mipmap_str: String = "?"
	var image_err: String = ""
	var image: Image = null
	if tex.has_method("get_image"):
		image = tex.get_image()
	if image:
		format_str = _format_name_for(image.get_format())
		mipmap_str = "yes" if image.has_mipmaps() else "no"
	else:
		image_err = " (cannot read image data)"
	lines.append("  format: %s%s" % [format_str, image_err])
	lines.append("  mipmaps: %s" % mipmap_str)
	lines.append("  live: %s" % ("yes" if bool(entry.get("auto_update", false)) else "no"))
	lines.append("  zoom: %s" % _color_number(str(entry.get("zoom", 1.0))))
	return "\n".join(lines)

#endregion

#region helpers

# Returns { texture: Texture2D, auto_update: bool } on success or
# { error: String } on failure. Two source flavors:
#   * res://foo.png or user://bar.png    -> ResourceLoader.load
#   * Node/Path.property                  -> node.get(property)
# The dot used to separate node and property is the LAST dot in the source
# so node names containing dots still resolve correctly when the property
# name itself is dot-free (the common case).
func _resolve_source(source: String) -> Dictionary:
	var trimmed: String = source.strip_edges()
	if trimmed.begins_with("res://") or trimmed.begins_with("user://"):
		if not ResourceLoader.exists(trimmed):
			return {"error": "Resource not found: %s" % trimmed}
		var res: Resource = ResourceLoader.load(trimmed)
		if not (res is Texture2D):
			return {"error": "Resource is not a Texture2D: %s" % trimmed}
		return {"texture": res as Texture2D, "auto_update": false}

	var dot: int = trimmed.rfind(".")
	if dot <= 0 or dot >= trimmed.length() - 1:
		return {"error": "Source must be res:// path or node_path.property (got '%s')" % trimmed}
	var node_path: String = trimmed.substr(0, dot)
	var prop_name: String = trimmed.substr(dot + 1)

	var node: Node = _resolve_node(node_path)
	if not node:
		return {"error": "Node not found: %s" % node_path}

	var value: Variant = node.get(prop_name)
	if not (value is Texture2D):
		return {"error": "Property '%s' on %s is not a Texture2D" % [prop_name, node_path]}

	var tex: Texture2D = value
	var auto_update: bool = _is_live_texture(node, tex)
	return {"texture": tex, "auto_update": auto_update}

# Heuristic for "should we re-read this each frame". ViewportTexture is
# already live by reference, but Sprite2D/TextureRect may swap textures at
# runtime so checking the source node type catches reassignments too. False
# negatives are harmless (user just sees a stale frame); false positives
# only cost one Dictionary lookup + assignment per frame per window.
func _is_live_texture(node: Node, tex: Texture2D) -> bool:
	if tex is ViewportTexture:
		return true
	if node is Viewport:
		return true
	return false

# Mirrors UICommands._resolve_node: absolute NodePath first, then a tree-wide
# find_child by literal name so users can type just "Player" without spelling
# out the full /root/Main/... path.
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

func _texture_size(tex: Texture2D) -> Vector2i:
	if not tex:
		return Vector2i.ZERO
	return Vector2i(tex.get_width(), tex.get_height())

func _ensure_frame_callback(tree: SceneTree) -> void:
	if _frame_callback_connected:
		return
	if not tree.process_frame.is_connected(_on_process_frame):
		tree.process_frame.connect(_on_process_frame)
	_frame_callback_connected = true

# Per-frame refresh for live sources. Also harvests stale entries whose
# windows the engine freed under us (e.g. a queue_free called from outside
# this module) so the dictionary doesn't grow forever.
func _on_process_frame() -> void:
	if _windows.is_empty():
		return
	var stale: Array = []
	for id in _windows.keys():
		var entry: Dictionary = _windows[id]
		var window: Window = entry.get("window")
		var rect: TextureRect = entry.get("rect")
		if not (window and is_instance_valid(window) and rect and is_instance_valid(rect)):
			stale.append(id)
			continue
		if not bool(entry.get("auto_update", false)):
			continue
		var source: String = String(entry.get("source", ""))
		var resolved: Dictionary = _resolve_source(source)
		if resolved.has("error"):
			continue
		var tex: Texture2D = resolved["texture"]
		if tex and rect.texture != tex:
			rect.texture = tex
	for id in stale:
		_windows.erase(String(id))
	if _windows.is_empty():
		_disconnect_frame_callback()

func _on_window_close_requested(window_id: String) -> void:
	_close_window(window_id)

func _close_window(window_id: String) -> void:
	if not _windows.has(window_id):
		return
	var entry: Dictionary = _windows[window_id]
	var window: Window = entry.get("window")
	if window and is_instance_valid(window):
		window.queue_free()
	_windows.erase(window_id)
	if _windows.is_empty():
		_disconnect_frame_callback()

func _disconnect_frame_callback() -> void:
	if not _frame_callback_connected:
		return
	var tree := Engine.get_main_loop() as SceneTree
	if tree and tree.process_frame.is_connected(_on_process_frame):
		tree.process_frame.disconnect(_on_process_frame)
	_frame_callback_connected = false

func _save_image(args: Array, fmt: String) -> String:
	if args.size() < 2:
		return _format_error("Usage: tex_save_%s <window_id> <user://path.%s>" % [fmt, fmt])
	var id: String = str(args[0]).strip_edges()
	var path: String = str(args[1]).strip_edges()
	if path.is_empty():
		return _format_error("Empty path.")
	if not _windows.has(id):
		return _format_error("No viewer with id '%s'." % id)
	var entry: Dictionary = _windows[id]
	var rect: TextureRect = entry.get("rect")
	if not (rect and is_instance_valid(rect)):
		return _format_error("Viewer TextureRect is no longer valid.")
	var tex: Texture2D = rect.texture
	if not tex:
		return _format_error("No texture currently assigned.")
	if not tex.has_method("get_image"):
		return _format_error("Texture (%s) does not expose get_image()." % tex.get_class())
	var image: Image = tex.get_image()
	if not image:
		return _format_error("Failed to read image data from texture.")
	var err: int = OK
	match fmt:
		"png":
			err = image.save_png(path)
		"jpg":
			err = image.save_jpg(path)
		_:
			return _format_error("Unsupported format: %s" % fmt)
	if err != OK:
		return _format_error("save_%s failed (err %d) at %s" % [fmt, err, path])
	return _format_success("Wrote %s %dx%d to %s" % [
		fmt.to_upper(),
		image.get_width(),
		image.get_height(),
		_color_path(path),
	])

# Maps Image.FORMAT_* enum values to their canonical short names. Keeps
# tex_dump_info output readable instead of dumping raw integers. Falls back
# to "fmt#N" for newer formats the dictionary doesn't know about so future
# Godot additions degrade gracefully.
func _format_name_for(image_format: int) -> String:
	var name_map: Dictionary = {
		Image.FORMAT_L8: "L8",
		Image.FORMAT_LA8: "LA8",
		Image.FORMAT_R8: "R8",
		Image.FORMAT_RG8: "RG8",
		Image.FORMAT_RGB8: "RGB8",
		Image.FORMAT_RGBA8: "RGBA8",
		Image.FORMAT_RGBA4444: "RGBA4444",
		Image.FORMAT_RGB565: "RGB565",
		Image.FORMAT_RF: "RF",
		Image.FORMAT_RGF: "RGF",
		Image.FORMAT_RGBF: "RGBF",
		Image.FORMAT_RGBAF: "RGBAF",
		Image.FORMAT_RH: "RH",
		Image.FORMAT_RGH: "RGH",
		Image.FORMAT_RGBH: "RGBH",
		Image.FORMAT_RGBAH: "RGBAH",
		Image.FORMAT_RGBE9995: "RGBE9995",
		Image.FORMAT_DXT1: "DXT1",
		Image.FORMAT_DXT3: "DXT3",
		Image.FORMAT_DXT5: "DXT5",
		Image.FORMAT_BPTC_RGBA: "BPTC_RGBA",
		Image.FORMAT_BPTC_RGBF: "BPTC_RGBF",
		Image.FORMAT_BPTC_RGBFU: "BPTC_RGBFU",
		Image.FORMAT_ETC: "ETC",
		Image.FORMAT_ETC2_RGB8: "ETC2_RGB8",
		Image.FORMAT_ETC2_RGBA8: "ETC2_RGBA8",
	}
	if name_map.has(image_format):
		return String(name_map[image_format])
	return "fmt#%d" % image_format

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _format_error(msg: String) -> String:
	return "[color=%s]Error:[/color] %s" % [_COLOR_ERROR, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

#endregion

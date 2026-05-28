@tool
class_name DebugConsoleTilemapCommands extends RefCounted

# Live TileMapLayer / TileMap manipulation commands. Godot 4.6
# deprecated TileMap in favour of one-layer-per-node TileMapLayer instances,
# so every command here resolves the path to a TileMapLayer first and falls
# back to legacy TileMap (layer 0) only when needed. Legacy support is
# best-effort: multi-layer TileMaps will be touched on layer 0 only.
#
# All output is BBCode-coloured for the in-console log. Bulk operations
# (fill, line, clear, cells listing) are capped at MAX_BULK_CELLS to keep a
# fat-fingered "tile_fill 0,0 99999,99999" from freezing the editor.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"

const MAX_BULK_CELLS := 10000
const MAX_LIST_CELLS := 200

var _registry: Node
var _core: Node

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("tile_set", _cmd_tile_set, "Paint one cell: tile_set <tml_path> <x,y> <source_id> <atlas_x,y> [alt]", "both")
	_registry.register_command("tile_get", _cmd_tile_get, "Inspect one cell: tile_get <tml_path> <x,y>", "both")
	_registry.register_command("tile_erase", _cmd_tile_erase, "Erase one cell: tile_erase <tml_path> <x,y>", "both")
	_registry.register_command("tile_fill", _cmd_tile_fill, "Rect fill (cap 10000 cells): tile_fill <tml_path> <x1,y1> <x2,y2> <source_id> <atlas_x,y>", "both")
	_registry.register_command("tile_line", _cmd_tile_line, "Bresenham line (cap 10000 cells): tile_line <tml_path> <x1,y1> <x2,y2> <source_id> <atlas_x,y>", "both")
	_registry.register_command("tile_clear", _cmd_tile_clear, "Clear whole layer or a rect: tile_clear <tml_path> [x1,y1] [x2,y2]", "both")
	_registry.register_command("tile_used", _cmd_tile_used, "Show get_used_rect + cell count: tile_used <tml_path>", "both")
	_registry.register_command("tile_cells", _cmd_tile_cells, "List non-empty cells (cap 200): tile_cells <tml_path> [source_id]", "both")
	_registry.register_command("tile_sources", _cmd_tile_sources, "List sources in the TileSet: tile_sources <tml_path>", "both")
	_registry.register_command("tile_save", _cmd_tile_save, "Dump used cells to JSON: tile_save <tml_path> <res://map.json>", "both")
	_registry.register_command("tile_load", _cmd_tile_load, "Load cells from JSON: tile_load <tml_path> <res://map.json>", "both")

#region commands

func _cmd_tile_set(args: Array) -> String:
	if args.size() < 4:
		return _format_error("Usage: tile_set <tml_path> <x,y> <source_id> <atlas_x,y> [alt]")
	var node: Object = _resolve_tml(str(args[0]))
	if not node:
		return _format_error("TileMapLayer/TileMap not found: %s" % str(args[0]))
	var coords: Variant = _parse_vec2i(str(args[1]))
	if coords == null:
		return _format_error("Bad coords (want x,y): %s" % str(args[1]))
	var source_id: int = _to_int(str(args[2]), -2)
	if source_id == -2:
		return _format_error("Bad source_id: %s" % str(args[2]))
	var atlas: Variant = _parse_vec2i(str(args[3]))
	if atlas == null:
		return _format_error("Bad atlas coords (want x,y): %s" % str(args[3]))
	var alt: int = 0
	if args.size() >= 5:
		alt = _to_int(str(args[4]), 0)

	var err: String = _set_cell(node, coords, source_id, atlas, alt)
	if not err.is_empty():
		return _format_error(err)
	return "Set %s -> source=%s atlas=%s alt=%s on %s" % [
		_color_number(_vec2i_to_str(coords)),
		_color_number(str(source_id)),
		_color_number(_vec2i_to_str(atlas)),
		_color_number(str(alt)),
		_color_path(str(args[0])),
	]

func _cmd_tile_get(args: Array) -> String:
	if args.size() < 2:
		return _format_error("Usage: tile_get <tml_path> <x,y>")
	var node: Object = _resolve_tml(str(args[0]))
	if not node:
		return _format_error("TileMapLayer/TileMap not found: %s" % str(args[0]))
	var coords: Variant = _parse_vec2i(str(args[1]))
	if coords == null:
		return _format_error("Bad coords (want x,y): %s" % str(args[1]))

	var src_id: int = _get_cell_source(node, coords)
	if src_id == -1:
		return _format_error("Cell %s is empty on %s" % [_vec2i_to_str(coords), str(args[0])])
	var atlas: Vector2i = _get_cell_atlas(node, coords)
	var alt: int = _get_cell_alt(node, coords)
	return "Cell %s on %s: source=%s atlas=%s alt=%s" % [
		_color_number(_vec2i_to_str(coords)),
		_color_path(str(args[0])),
		_color_number(str(src_id)),
		_color_number(_vec2i_to_str(atlas)),
		_color_number(str(alt)),
	]

func _cmd_tile_erase(args: Array) -> String:
	if args.size() < 2:
		return _format_error("Usage: tile_erase <tml_path> <x,y>")
	var node: Object = _resolve_tml(str(args[0]))
	if not node:
		return _format_error("TileMapLayer/TileMap not found: %s" % str(args[0]))
	var coords: Variant = _parse_vec2i(str(args[1]))
	if coords == null:
		return _format_error("Bad coords (want x,y): %s" % str(args[1]))

	var err: String = _set_cell(node, coords, -1, Vector2i(-1, -1), 0)
	if not err.is_empty():
		return _format_error(err)
	return "Erased %s on %s" % [_color_number(_vec2i_to_str(coords)), _color_path(str(args[0]))]

func _cmd_tile_fill(args: Array) -> String:
	if args.size() < 5:
		return _format_error("Usage: tile_fill <tml_path> <x1,y1> <x2,y2> <source_id> <atlas_x,y>")
	var node: Object = _resolve_tml(str(args[0]))
	if not node:
		return _format_error("TileMapLayer/TileMap not found: %s" % str(args[0]))
	var a: Variant = _parse_vec2i(str(args[1]))
	var b: Variant = _parse_vec2i(str(args[2]))
	if a == null or b == null:
		return _format_error("Bad rect corners (want x,y x,y)")
	var source_id: int = _to_int(str(args[3]), -2)
	if source_id == -2:
		return _format_error("Bad source_id: %s" % str(args[3]))
	var atlas: Variant = _parse_vec2i(str(args[4]))
	if atlas == null:
		return _format_error("Bad atlas coords (want x,y): %s" % str(args[4]))

	var x_min: int = min(a.x, b.x)
	var x_max: int = max(a.x, b.x)
	var y_min: int = min(a.y, b.y)
	var y_max: int = max(a.y, b.y)
	var w: int = x_max - x_min + 1
	var h: int = y_max - y_min + 1
	var total: int = w * h
	if total > MAX_BULK_CELLS:
		return _format_error("Refusing fill of %d cells (cap %d). Shrink the rect." % [total, MAX_BULK_CELLS])

	var written: int = 0
	var first_err: String = ""
	for x in range(x_min, x_max + 1):
		for y in range(y_min, y_max + 1):
			var err: String = _set_cell(node, Vector2i(x, y), source_id, atlas, 0)
			if err.is_empty():
				written += 1
			elif first_err.is_empty():
				first_err = err
	if written == 0 and not first_err.is_empty():
		return _format_error(first_err)
	return "Filled %s cells on %s (%s..%s)" % [
		_color_number(str(written)),
		_color_path(str(args[0])),
		_color_number(_vec2i_to_str(Vector2i(x_min, y_min))),
		_color_number(_vec2i_to_str(Vector2i(x_max, y_max))),
	]

func _cmd_tile_line(args: Array) -> String:
	if args.size() < 5:
		return _format_error("Usage: tile_line <tml_path> <x1,y1> <x2,y2> <source_id> <atlas_x,y>")
	var node: Object = _resolve_tml(str(args[0]))
	if not node:
		return _format_error("TileMapLayer/TileMap not found: %s" % str(args[0]))
	var a: Variant = _parse_vec2i(str(args[1]))
	var b: Variant = _parse_vec2i(str(args[2]))
	if a == null or b == null:
		return _format_error("Bad endpoints (want x,y x,y)")
	var source_id: int = _to_int(str(args[3]), -2)
	if source_id == -2:
		return _format_error("Bad source_id: %s" % str(args[3]))
	var atlas: Variant = _parse_vec2i(str(args[4]))
	if atlas == null:
		return _format_error("Bad atlas coords (want x,y): %s" % str(args[4]))

	var cells: Array[Vector2i] = _line_cells(a, b)
	if cells.size() > MAX_BULK_CELLS:
		return _format_error("Refusing line of %d cells (cap %d)." % [cells.size(), MAX_BULK_CELLS])

	var written: int = 0
	var first_err: String = ""
	for c in cells:
		var err: String = _set_cell(node, c, source_id, atlas, 0)
		if err.is_empty():
			written += 1
		elif first_err.is_empty():
			first_err = err
	if written == 0 and not first_err.is_empty():
		return _format_error(first_err)
	return "Drew line of %s cells on %s (%s -> %s)" % [
		_color_number(str(written)),
		_color_path(str(args[0])),
		_color_number(_vec2i_to_str(a)),
		_color_number(_vec2i_to_str(b)),
	]

func _cmd_tile_clear(args: Array) -> String:
	if args.is_empty():
		return _format_error("Usage: tile_clear <tml_path> [x1,y1] [x2,y2]")
	var node: Object = _resolve_tml(str(args[0]))
	if not node:
		return _format_error("TileMapLayer/TileMap not found: %s" % str(args[0]))

	if args.size() == 1:
		var prev: int = _get_used_cells(node).size()
		_clear_all(node)
		return "Cleared %s cells on %s" % [_color_number(str(prev)), _color_path(str(args[0]))]

	if args.size() < 3:
		return _format_error("tile_clear needs both rect corners or neither")
	var a: Variant = _parse_vec2i(str(args[1]))
	var b: Variant = _parse_vec2i(str(args[2]))
	if a == null or b == null:
		return _format_error("Bad rect corners (want x,y x,y)")
	var x_min: int = min(a.x, b.x)
	var x_max: int = max(a.x, b.x)
	var y_min: int = min(a.y, b.y)
	var y_max: int = max(a.y, b.y)
	var total: int = (x_max - x_min + 1) * (y_max - y_min + 1)
	if total > MAX_BULK_CELLS:
		return _format_error("Refusing clear of %d cells (cap %d)." % [total, MAX_BULK_CELLS])

	var cleared: int = 0
	for x in range(x_min, x_max + 1):
		for y in range(y_min, y_max + 1):
			var coords: Vector2i = Vector2i(x, y)
			if _get_cell_source(node, coords) == -1:
				continue
			var err: String = _set_cell(node, coords, -1, Vector2i(-1, -1), 0)
			if err.is_empty():
				cleared += 1
	return "Cleared %s cells on %s (%s..%s)" % [
		_color_number(str(cleared)),
		_color_path(str(args[0])),
		_color_number(_vec2i_to_str(Vector2i(x_min, y_min))),
		_color_number(_vec2i_to_str(Vector2i(x_max, y_max))),
	]

func _cmd_tile_used(args: Array) -> String:
	if args.is_empty():
		return _format_error("Usage: tile_used <tml_path>")
	var node: Object = _resolve_tml(str(args[0]))
	if not node:
		return _format_error("TileMapLayer/TileMap not found: %s" % str(args[0]))
	var cells: Array = _get_used_cells(node)
	var rect: Rect2i = _get_used_rect(node)
	return "%s: rect=%s..%s size=%s cells=%s" % [
		_color_path(str(args[0])),
		_color_number(_vec2i_to_str(rect.position)),
		_color_number(_vec2i_to_str(rect.position + rect.size)),
		_color_number(_vec2i_to_str(rect.size)),
		_color_number(str(cells.size())),
	]

func _cmd_tile_cells(args: Array) -> String:
	if args.is_empty():
		return _format_error("Usage: tile_cells <tml_path> [source_id]")
	var node: Object = _resolve_tml(str(args[0]))
	if not node:
		return _format_error("TileMapLayer/TileMap not found: %s" % str(args[0]))
	var filter_source: int = -999
	if args.size() >= 2:
		filter_source = _to_int(str(args[1]), -2)
		if filter_source == -2:
			return _format_error("Bad source_id filter: %s" % str(args[1]))

	var cells: Array = _get_used_cells(node)
	var lines: Array[String] = []
	var listed: int = 0
	var matched: int = 0
	for c in cells:
		var coords: Vector2i = c
		var src: int = _get_cell_source(node, coords)
		if filter_source != -999 and src != filter_source:
			continue
		matched += 1
		if listed >= MAX_LIST_CELLS:
			continue
		var atlas: Vector2i = _get_cell_atlas(node, coords)
		var alt: int = _get_cell_alt(node, coords)
		lines.append("  %s  source=%s atlas=%s alt=%s" % [
			_color_number(_vec2i_to_str(coords)),
			_color_number(str(src)),
			_color_number(_vec2i_to_str(atlas)),
			_color_number(str(alt)),
		])
		listed += 1

	var header: String = "%s: %s cells listed" % [_color_path(str(args[0])), _color_number(str(matched))]
	if matched > MAX_LIST_CELLS:
		header += " (showing first %d)" % MAX_LIST_CELLS
	if lines.is_empty():
		return header
	return header + "\n" + "\n".join(lines)

func _cmd_tile_sources(args: Array) -> String:
	if args.is_empty():
		return _format_error("Usage: tile_sources <tml_path>")
	var node: Object = _resolve_tml(str(args[0]))
	if not node:
		return _format_error("TileMapLayer/TileMap not found: %s" % str(args[0]))
	var ts: TileSet = node.tile_set
	if not ts:
		return _format_error("No TileSet assigned on %s" % str(args[0]))

	var count: int = ts.get_source_count()
	if count == 0:
		return "%s: no sources in TileSet" % _color_path(str(args[0]))
	var lines: Array[String] = []
	for i in range(count):
		var sid: int = ts.get_source_id(i)
		var src: TileSetSource = ts.get_source(sid)
		var tex_path: String = "<none>"
		var tile_count: int = 0
		if src is TileSetAtlasSource:
			var atlas_src: TileSetAtlasSource = src
			if atlas_src.texture:
				tex_path = atlas_src.texture.resource_path
				if tex_path.is_empty():
					tex_path = "<embedded>"
			tile_count = atlas_src.get_tiles_count()
		else:
			tex_path = "<%s>" % src.get_class()
			if src and src.has_method("get_tiles_count"):
				tile_count = src.get_tiles_count()
		lines.append("  id=%s tiles=%s texture=%s" % [
			_color_number(str(sid)),
			_color_number(str(tile_count)),
			_color_path(tex_path),
		])
	return "%s: %s sources\n%s" % [
		_color_path(str(args[0])),
		_color_number(str(count)),
		"\n".join(lines),
	]

func _cmd_tile_save(args: Array) -> String:
	if args.size() < 2:
		return _format_error("Usage: tile_save <tml_path> <res://map.json>")
	var node: Object = _resolve_tml(str(args[0]))
	if not node:
		return _format_error("TileMapLayer/TileMap not found: %s" % str(args[0]))
	var out_path: String = str(args[1]).strip_edges()
	if out_path.is_empty():
		return _format_error("Empty output path")

	var cells_data: Array = []
	for c in _get_used_cells(node):
		var coords: Vector2i = c
		var src: int = _get_cell_source(node, coords)
		var atlas: Vector2i = _get_cell_atlas(node, coords)
		var alt: int = _get_cell_alt(node, coords)
		cells_data.append([coords.x, coords.y, src, atlas.x, atlas.y, alt])
	var payload: Dictionary = {"cells": cells_data}

	var f: FileAccess = FileAccess.open(out_path, FileAccess.WRITE)
	if not f:
		return _format_error("Cannot write %s (err=%s)" % [out_path, FileAccess.get_open_error()])
	f.store_string(JSON.stringify(payload, "  "))
	f.close()
	return "Saved %s cells to %s" % [_color_number(str(cells_data.size())), _color_path(out_path)]

func _cmd_tile_load(args: Array) -> String:
	if args.size() < 2:
		return _format_error("Usage: tile_load <tml_path> <res://map.json>")
	var node: Object = _resolve_tml(str(args[0]))
	if not node:
		return _format_error("TileMapLayer/TileMap not found: %s" % str(args[0]))
	var in_path: String = str(args[1]).strip_edges()
	if in_path.is_empty():
		return _format_error("Empty input path")
	if not FileAccess.file_exists(in_path):
		return _format_error("File not found: %s" % in_path)

	var f: FileAccess = FileAccess.open(in_path, FileAccess.READ)
	if not f:
		return _format_error("Cannot read %s (err=%s)" % [in_path, FileAccess.get_open_error()])
	var text: String = f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("cells"):
		return _format_error("Bad JSON: expected {\"cells\": [...]} in %s" % in_path)
	var cells_arr: Variant = parsed["cells"]
	if typeof(cells_arr) != TYPE_ARRAY:
		return _format_error("Bad JSON: \"cells\" is not an array")

	if cells_arr.size() > MAX_BULK_CELLS:
		return _format_error("Refusing load of %d cells (cap %d)." % [cells_arr.size(), MAX_BULK_CELLS])

	var written: int = 0
	var skipped: int = 0
	for entry in cells_arr:
		if typeof(entry) != TYPE_ARRAY or entry.size() < 6:
			skipped += 1
			continue
		var coords: Vector2i = Vector2i(int(entry[0]), int(entry[1]))
		var src: int = int(entry[2])
		var atlas: Vector2i = Vector2i(int(entry[3]), int(entry[4]))
		var alt: int = int(entry[5])
		var err: String = _set_cell(node, coords, src, atlas, alt)
		if err.is_empty():
			written += 1
		else:
			skipped += 1
	var msg: String = "Loaded %s cells onto %s from %s" % [
		_color_number(str(written)),
		_color_path(str(args[0])),
		_color_path(in_path),
	]
	if skipped > 0:
		msg += " (%s skipped)" % _color_number(str(skipped))
	return msg

#endregion

#region Helpers

func _resolve_tml(path: String) -> Object:
	# Prefer TileMapLayer; fall back to legacy TileMap. We accept the same
	# editor/runtime path conventions as the other modules.
	var node: Node = _resolve_node(path)
	if not node:
		return null
	if node is TileMapLayer:
		return node
	if node is TileMap:
		return node
	return null

func _resolve_node(path: String) -> Node:
	var p: String = path.strip_edges()
	if p.is_empty():
		return null

	if Engine.is_editor_hint():
		var root: Node = EditorInterface.get_edited_scene_root()
		if not root:
			return null
		if p == "/root":
			return root
		if p.begins_with("/root/"):
			p = p.substr(6)
		elif p.begins_with("/"):
			p = p.substr(1)
		if p == root.name:
			return root
		if p.begins_with(root.name + "/"):
			p = p.substr(root.name.length() + 1)
		if p.is_empty():
			return root
		return root.get_node_or_null(p)

	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if not tree:
		return null
	if p.begins_with("/"):
		return tree.root.get_node_or_null(p)
	var scene: Node = tree.current_scene if tree.current_scene else tree.root
	return scene.get_node_or_null(p)

func _is_layer(node: Object) -> bool:
	return node is TileMapLayer

func _set_cell(node: Object, coords: Vector2i, source_id: int, atlas: Vector2i, alt: int) -> String:
	if not node:
		return "Null node"
	if _is_layer(node):
		(node as TileMapLayer).set_cell(coords, source_id, atlas, alt)
		return ""
	if node is TileMap:
		(node as TileMap).set_cell(0, coords, source_id, atlas, alt)
		return ""
	return "Not a TileMapLayer/TileMap"

func _get_cell_source(node: Object, coords: Vector2i) -> int:
	if _is_layer(node):
		return (node as TileMapLayer).get_cell_source_id(coords)
	if node is TileMap:
		return (node as TileMap).get_cell_source_id(0, coords)
	return -1

func _get_cell_atlas(node: Object, coords: Vector2i) -> Vector2i:
	if _is_layer(node):
		return (node as TileMapLayer).get_cell_atlas_coords(coords)
	if node is TileMap:
		return (node as TileMap).get_cell_atlas_coords(0, coords)
	return Vector2i(-1, -1)

func _get_cell_alt(node: Object, coords: Vector2i) -> int:
	if _is_layer(node):
		return (node as TileMapLayer).get_cell_alternative_tile(coords)
	if node is TileMap:
		return (node as TileMap).get_cell_alternative_tile(0, coords)
	return 0

func _get_used_cells(node: Object) -> Array:
	if _is_layer(node):
		return (node as TileMapLayer).get_used_cells()
	if node is TileMap:
		return (node as TileMap).get_used_cells(0)
	return []

func _get_used_rect(node: Object) -> Rect2i:
	if _is_layer(node):
		return (node as TileMapLayer).get_used_rect()
	if node is TileMap:
		return (node as TileMap).get_used_rect()
	return Rect2i()

func _clear_all(node: Object) -> void:
	if _is_layer(node):
		(node as TileMapLayer).clear()
	elif node is TileMap:
		(node as TileMap).clear_layer(0)

func _parse_vec2i(s: String) -> Variant:
	# Accepts "x,y" with optional whitespace and an optional surrounding "(...)".
	var t: String = s.strip_edges()
	if t.begins_with("(") and t.ends_with(")"):
		t = t.substr(1, t.length() - 2)
	var parts: PackedStringArray = t.split(",")
	if parts.size() != 2:
		return null
	var xs: String = parts[0].strip_edges()
	var ys: String = parts[1].strip_edges()
	if not xs.is_valid_int() or not ys.is_valid_int():
		return null
	return Vector2i(xs.to_int(), ys.to_int())

func _vec2i_to_str(v: Vector2i) -> String:
	return "%d,%d" % [v.x, v.y]

func _line_cells(a: Vector2i, b: Vector2i) -> Array[Vector2i]:
	# Standard integer Bresenham. Includes both endpoints.
	var out: Array[Vector2i] = []
	var x0: int = a.x
	var y0: int = a.y
	var x1: int = b.x
	var y1: int = b.y
	var dx: int = abs(x1 - x0)
	var dy: int = -abs(y1 - y0)
	var sx: int = 1 if x0 < x1 else -1
	var sy: int = 1 if y0 < y1 else -1
	var err: int = dx + dy
	while true:
		out.append(Vector2i(x0, y0))
		if x0 == x1 and y0 == y1:
			break
		if out.size() > MAX_BULK_CELLS:
			break
		var e2: int = 2 * err
		if e2 >= dy:
			err += dy
			x0 += sx
		if e2 <= dx:
			err += dx
			y0 += sy
	return out

func _to_int(s: String, fallback: int) -> int:
	var t: String = s.strip_edges()
	if t.is_valid_int():
		return t.to_int()
	return fallback

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

func _color_num(s: String) -> String:
	return _color_number(s)

#endregion

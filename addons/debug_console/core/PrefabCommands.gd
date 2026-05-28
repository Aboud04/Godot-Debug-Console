@tool
class_name DebugConsolePrefabCommands extends RefCounted

# In-memory prefab snapshots.
# Dictionary lives on this RefCounted via _t6_keepalive (persists across rebuilds).
#
# pack() correctness: PackedScene.pack() only walks descendants whose owner
# is the node being packed. Duplicate into detached copy, rewrite owners,
# pack, and free to avoid mutating the live source's owner chain.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"

# Soft cap: prevent UI lock from massive batch requests.
const _MAX_BATCH := 10000

var _registry: Node
var _core: Node
var _prefabs: Dictionary = {}  # String -> PackedScene
var _origin: Dictionary = {}   # String -> source description (for prefab_list)

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("prefab_save", _cmd_prefab_save, "Snapshot a node subtree as an in-memory prefab: prefab_save <name> <node_path>", "both")
	_registry.register_command("prefab_list", _cmd_prefab_list, "List every saved prefab with its node count: prefab_list", "both")
	_registry.register_command("prefab_drop", _cmd_prefab_drop, "Drop a saved prefab by name: prefab_drop <name>", "both")
	_registry.register_command("prefab_clear", _cmd_prefab_clear, "Drop every saved prefab: prefab_clear", "both")
	_registry.register_command("prefab_spawn", _cmd_prefab_spawn, "Instance a saved prefab: prefab_spawn <name> [parent_path] [x,y,z]", "both")
	_registry.register_command("prefab_export", _cmd_prefab_export, "Write a prefab to disk as a .tscn: prefab_export <name> <res://path.tscn>", "editor")
	_registry.register_command("prefab_import", _cmd_prefab_import, "Load a PackedScene from disk into the prefab dict: prefab_import <res://path.tscn> [as_name]", "both")
	_registry.register_command("prefab_dup", _cmd_prefab_dup, "Duplicate a prefab under a new name (PackedScene is shared by reference): prefab_dup <source_name> <new_name>", "both")
	_registry.register_command("prefab_swarm", _cmd_prefab_swarm, "Spawn N copies in a random AABB: prefab_swarm <name> <count> <x,y,z> <half_extent>", "game")
	_registry.register_command("prefab_field", _cmd_prefab_field, "Spawn a rows x cols grid of copies: prefab_field <name> <rows> <cols> <spacing>", "game")

#region Command implementations

func _cmd_prefab_save(args: Array, _piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: prefab_save <name> <node_path>")
	var name := str(args[0]).strip_edges()
	var node_path := str(args[1]).strip_edges()
	if name.is_empty():
		return _format_error("Prefab name is required")
	if node_path.is_empty():
		return _format_error("Node path is required")

	var source := _resolve_node(node_path)
	if not source:
		return _format_error("Node not found: %s" % node_path)

	var packed := _pack_subtree(source)
	if not packed:
		return _format_error("Failed to pack subtree under %s" % node_path)

	_prefabs[name] = packed
	_origin[name] = "from %s" % node_path
	var node_count: int = packed.get_state().get_node_count()
	var descendants: int = max(0, node_count - 1)
	return _format_success("Saved prefab %s (%s nodes, %s descendants)" % [
		_color_path(name),
		_color_number(str(node_count)),
		_color_number(str(descendants)),
	])

func _cmd_prefab_list(_args: Array, _piped_input: String = "") -> String:
	if _prefabs.is_empty():
		return "No prefabs saved. Use prefab_save <name> <node_path> to make one."
	var names: Array = _prefabs.keys()
	names.sort()
	var lines: Array[String] = []
	lines.append("%s prefab(s):" % _color_number(str(names.size())))
	for n in names:
		var packed: PackedScene = _prefabs[n]
		if not packed:
			lines.append("  %s  [color=%s]<invalid>[/color]" % [_color_path(str(n)), _COLOR_ERROR])
			continue
		var state := packed.get_state()
		var node_count: int = state.get_node_count() if state else 0
		var root_type: String = state.get_node_type(0) if state and node_count > 0 else "?"
		var origin: String = str(_origin.get(n, "in-memory"))
		var approx_kib: float = (node_count * 256.0) / 1024.0
		lines.append("  %s  root=%s  nodes=%s  ~%s kib  (%s)" % [
			_color_path(str(n)),
			root_type,
			_color_number(str(node_count)),
			_color_number("%.1f" % approx_kib),
			origin,
		])
	return "\n".join(lines)

func _cmd_prefab_drop(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: prefab_drop <name>")
	var name := str(args[0]).strip_edges()
	if not _prefabs.has(name):
		return _format_error("No prefab named: %s" % name)
	_prefabs.erase(name)
	_origin.erase(name)
	return _format_success("Dropped prefab %s" % _color_path(name))

func _cmd_prefab_clear(_args: Array, _piped_input: String = "") -> String:
	var count: int = _prefabs.size()
	_prefabs.clear()
	_origin.clear()
	if count == 0:
		return "No prefabs to clear."
	return _format_success("Cleared %s prefab(s)" % _color_number(str(count)))

func _cmd_prefab_spawn(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: prefab_spawn <name> [parent_path] [x,y,z]")
	var name := str(args[0]).strip_edges()
	var parent_path := str(args[1]).strip_edges() if args.size() > 1 else ""
	var pos_str := str(args[2]).strip_edges() if args.size() > 2 else ""

	if not _prefabs.has(name):
		return _format_error("No prefab named: %s" % name)
	var packed: PackedScene = _prefabs[name]
	if not packed:
		return _format_error("Prefab is invalid: %s" % name)

	var instance: Node = packed.instantiate()
	if not instance:
		return _format_error("Failed to instantiate prefab: %s" % name)

	var parent: Node
	if parent_path.is_empty():
		parent = _get_default_parent()
	else:
		parent = _resolve_node(parent_path)
	if not parent:
		instance.free()
		return _format_error("Parent not found: %s" % (parent_path if not parent_path.is_empty() else "<default>"))

	parent.add_child(instance)
	# Mirror Godot convention: persist spawned prefab with edited scene.
	if Engine.is_editor_hint():
		var root := _get_scene_root()
		if root:
			instance.owner = root

	if not pos_str.is_empty():
		var pos_val: Variant = _parse_value(pos_str)
		_apply_position(instance, pos_val)

	var spawned_path: String = str(instance.get_path()) if instance.is_inside_tree() else instance.name
	return _format_success("Spawned %s -> %s" % [
		_color_path(name),
		_color_path(spawned_path),
	])

func _cmd_prefab_export(args: Array, _piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: prefab_export <name> <res://path.tscn>")
	if not Engine.is_editor_hint():
		return _format_error("prefab_export is editor-only (res:// writes at runtime are unreliable)")

	var name := str(args[0]).strip_edges()
	var path := str(args[1]).strip_edges()
	if not _prefabs.has(name):
		return _format_error("No prefab named: %s" % name)
	if not path.begins_with("res://"):
		return _format_error("Path must start with res:// (got %s)" % path)
	if not path.ends_with(".tscn") and not path.ends_with(".scn"):
		return _format_error("Path must end with .tscn or .scn (got %s)" % path)

	var packed: PackedScene = _prefabs[name]
	if not packed:
		return _format_error("Prefab is invalid: %s" % name)

	var err: int = ResourceSaver.save(packed, path)
	if err != OK:
		return _format_error("ResourceSaver.save failed: %s (err=%d)" % [path, err])
	return _format_success("Exported %s -> %s" % [_color_path(name), _color_path(path)])

func _cmd_prefab_import(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: prefab_import <res://path.tscn> [as_name]")
	var path := str(args[0]).strip_edges()
	var as_name := str(args[1]).strip_edges() if args.size() > 1 else ""
	if not ResourceLoader.exists(path):
		return _format_error("Scene not found: %s" % path)
	var packed := load(path) as PackedScene
	if not packed:
		return _format_error("Not a PackedScene: %s" % path)

	if as_name.is_empty():
		as_name = path.get_file().get_basename()
	if as_name.is_empty():
		return _format_error("Could not derive a name from %s" % path)

	_prefabs[as_name] = packed
	_origin[as_name] = "imported %s" % path
	var node_count: int = packed.get_state().get_node_count()
	return _format_success("Imported %s as %s (%s nodes)" % [
		_color_path(path),
		_color_path(as_name),
		_color_number(str(node_count)),
	])

func _cmd_prefab_dup(args: Array, _piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: prefab_dup <source_name> <new_name>")
	var source_name := str(args[0]).strip_edges()
	var new_name := str(args[1]).strip_edges()
	if not _prefabs.has(source_name):
		return _format_error("No prefab named: %s" % source_name)
	if new_name.is_empty():
		return _format_error("New name is required")
	if source_name == new_name:
		return _format_error("Source and new name must differ")
	# Share the PackedScene by reference. PackedScene is immutable from this
	# module's perspective (we never mutate the saved resource), so two names
	# pointing at the same resource is safe and cheap.
	_prefabs[new_name] = _prefabs[source_name]
	_origin[new_name] = "dup of %s" % source_name
	return _format_success("Duplicated %s -> %s" % [
		_color_path(source_name),
		_color_path(new_name),
	])

func _cmd_prefab_swarm(args: Array, _piped_input: String = "") -> String:
	if args.size() < 4:
		return _format_error("Usage: prefab_swarm <name> <count> <x,y,z> <half_extent>")
	if Engine.is_editor_hint():
		# Game-only: avoid spawning into edited scene tree (hard to undo).
		return _format_error("prefab_swarm is game-only (runs against the live scene tree)")

	var name := str(args[0]).strip_edges()
	if not _prefabs.has(name):
		return _format_error("No prefab named: %s" % name)
	var packed: PackedScene = _prefabs[name]
	if not packed:
		return _format_error("Prefab is invalid: %s" % name)

	var count_str := str(args[1]).strip_edges()
	if not count_str.is_valid_int():
		return _format_error("count must be an integer: %s" % count_str)
	var count: int = count_str.to_int()
	if count <= 0:
		return _format_error("count must be > 0")
	if count > _MAX_BATCH:
		return _format_error("count exceeds soft limit of %d" % _MAX_BATCH)

	var area_val: Variant = _parse_value(str(args[2]))
	var center: Vector3
	if area_val is Vector3:
		center = area_val
	elif area_val is Vector2:
		center = Vector3((area_val as Vector2).x, 0.0, (area_val as Vector2).y)
	else:
		return _format_error("area must be x,y,z (got %s)" % str(args[2]))

	var half_str := str(args[3]).strip_edges()
	if not (half_str.is_valid_float() or half_str.is_valid_int()):
		return _format_error("half_extent must be a number: %s" % half_str)
	var half: float = half_str.to_float()
	if half < 0.0:
		return _format_error("half_extent must be >= 0")

	var parent := _get_default_parent()
	if not parent:
		return _format_error("No default parent (no scene root)")

	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var spawned: int = 0
	for i in count:
		var inst: Node = packed.instantiate()
		if not inst:
			continue
		parent.add_child(inst)
		var offset := Vector3(
			rng.randf_range(-half, half),
			rng.randf_range(-half, half),
			rng.randf_range(-half, half),
		)
		_apply_position(inst, center + offset)
		spawned += 1

	var bmin: Vector3 = center - Vector3(half, half, half)
	var bmax: Vector3 = center + Vector3(half, half, half)
	return _format_success("Swarmed %s x %s in AABB [%s -> %s]" % [
		_color_number(str(spawned)),
		_color_path(name),
		_color_number(_vec3_str(bmin)),
		_color_number(_vec3_str(bmax)),
	])

func _cmd_prefab_field(args: Array, _piped_input: String = "") -> String:
	if args.size() < 4:
		return _format_error("Usage: prefab_field <name> <rows> <cols> <spacing>")
	if Engine.is_editor_hint():
		return _format_error("prefab_field is game-only (runs against the live scene tree)")

	var name := str(args[0]).strip_edges()
	if not _prefabs.has(name):
		return _format_error("No prefab named: %s" % name)
	var packed: PackedScene = _prefabs[name]
	if not packed:
		return _format_error("Prefab is invalid: %s" % name)

	var rows_str := str(args[1]).strip_edges()
	var cols_str := str(args[2]).strip_edges()
	if not rows_str.is_valid_int() or not cols_str.is_valid_int():
		return _format_error("rows and cols must be integers")
	var rows: int = rows_str.to_int()
	var cols: int = cols_str.to_int()
	if rows <= 0 or cols <= 0:
		return _format_error("rows and cols must be > 0")
	if rows * cols > _MAX_BATCH:
		return _format_error("rows*cols (%d) exceeds soft limit of %d" % [rows * cols, _MAX_BATCH])

	var spacing_val: Variant = _parse_value(str(args[3]))
	# Peek at the root type by instantiating once. We reuse this first instance
	# as cell (0,0) so the peek is not wasted.
	var first: Node = packed.instantiate()
	if not first:
		return _format_error("Failed to instantiate prefab: %s" % name)

	var is_3d: bool = first is Node3D
	var is_2d: bool = (first is Node2D) or (first is Control)
	if not is_3d and not is_2d:
		first.free()
		return _format_error("Prefab root is neither Node3D nor Node2D/Control; nothing to position")

	var sp3: Vector3 = Vector3.ZERO
	var sp2: Vector2 = Vector2.ZERO
	if is_3d:
		if spacing_val is Vector3:
			sp3 = spacing_val
		elif spacing_val is Vector2:
			sp3 = Vector3((spacing_val as Vector2).x, 0.0, (spacing_val as Vector2).y)
		elif spacing_val is float or spacing_val is int:
			var s: float = float(spacing_val)
			sp3 = Vector3(s, 0.0, s)
		else:
			first.free()
			return _format_error("spacing must be x,y,z for 3D prefabs (got %s)" % str(args[3]))
	else:
		if spacing_val is Vector2:
			sp2 = spacing_val
		elif spacing_val is Vector3:
			var v: Vector3 = spacing_val
			sp2 = Vector2(v.x, v.y)
		elif spacing_val is float or spacing_val is int:
			var s2: float = float(spacing_val)
			sp2 = Vector2(s2, s2)
		else:
			first.free()
			return _format_error("spacing must be x,y for 2D prefabs (got %s)" % str(args[3]))

	var parent := _get_default_parent()
	if not parent:
		first.free()
		return _format_error("No default parent (no scene root)")

	var spawned: int = 0
	for r in rows:
		for c in cols:
			var inst: Node = first if (r == 0 and c == 0) else packed.instantiate()
			if not inst:
				continue
			parent.add_child(inst)
			if is_3d:
				# col maps to X, row maps to Z. Y is only nonzero when the
				# user explicitly passed a 3-component spacing with a Y term
				# (e.g. "2,0.5,2" to make a stepped grid).
				_apply_position(inst, Vector3(c * sp3.x, r * sp3.y, r * sp3.z))
			else:
				_apply_position(inst, Vector2(c * sp2.x, r * sp2.y))
			spawned += 1

	var dims: String
	if is_3d:
		dims = _vec3_str(sp3)
	else:
		dims = _vec2_str(sp2)
	return _format_success("Field %s: %sx%s instances, spacing %s" % [
		_color_path(name),
		_color_number(str(rows)),
		_color_number(str(cols)),
		_color_number(dims),
	])

#endregion

#region Helpers

func _pack_subtree(source: Node) -> PackedScene:
	# Duplicate detached to preserve live source's owner chain,
	# then rewrite owners so pack() includes all descendants.
	var flags: int = (
		Node.DUPLICATE_GROUPS
		| Node.DUPLICATE_SIGNALS
		| Node.DUPLICATE_SCRIPTS
		| Node.DUPLICATE_USE_INSTANTIATION
	)
	var dup: Node = source.duplicate(flags)
	if not dup:
		return null
	_set_owners_recursively(dup, dup)
	var packed := PackedScene.new()
	var err: int = packed.pack(dup)
	dup.free()
	if err != OK:
		return null
	return packed

func _set_owners_recursively(node: Node, root: Node) -> void:
	for child in node.get_children():
		# Sub-instances need owner on instance root (packed as instance placeholder).
		# Do not recurse into them-their descendants belong to the sub-scene.
		child.owner = root
		if child.scene_file_path != "":
			continue
		_set_owners_recursively(child, root)

func _count_descendants(node: Node) -> int:
	var total: int = 0
	for child in node.get_children():
		total += 1 + _count_descendants(child)
	return total

func _apply_position(node: Node, value: Variant) -> void:
	# Set position, adapting across 2D/3D dimensions.
	# Dimension mismatches are silently ignored (spawn succeeded).
	if node is Node3D and value is Vector3:
		(node as Node3D).position = value
	elif node is Node3D and value is Vector2:
		var v2: Vector2 = value
		(node as Node3D).position = Vector3(v2.x, 0.0, v2.y)
	elif node is Node2D and value is Vector2:
		(node as Node2D).position = value
	elif node is Node2D and value is Vector3:
		var v3: Vector3 = value
		(node as Node2D).position = Vector2(v3.x, v3.y)
	elif node is Control and value is Vector2:
		(node as Control).position = value
	elif node is Control and value is Vector3:
		var v3c: Vector3 = value
		(node as Control).position = Vector2(v3c.x, v3c.y)

func _get_scene_root() -> Node:
	# Editor: current scene root. Runtime: current_scene, or /root if unset.
	if Engine.is_editor_hint():
		return EditorInterface.get_edited_scene_root()
	var tree := Engine.get_main_loop() as SceneTree
	if not tree:
		return null
	if tree.current_scene:
		return tree.current_scene
	return tree.root

func _get_default_parent() -> Node:
	return _get_scene_root()

func _resolve_node(path: String) -> Node:
	var p := path.strip_edges()
	if p.is_empty():
		return null

	if Engine.is_editor_hint():
		var root := _get_scene_root()
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

	var tree := Engine.get_main_loop() as SceneTree
	if not tree:
		return null
	if p.begins_with("/"):
		return tree.root.get_node_or_null(p)
	var scene: Node = tree.current_scene if tree.current_scene else tree.root
	return scene.get_node_or_null(p)

func _parse_value(raw: String) -> Variant:
	var s := raw.strip_edges()
	if s.is_empty():
		return ""
	if s == "null":
		return null
	if s == "true":
		return true
	if s == "false":
		return false
	if (s.begins_with("\"") and s.ends_with("\"")) or (s.begins_with("'") and s.ends_with("'")):
		return s.substr(1, s.length() - 2)
	if s.contains(","):
		var parts: PackedStringArray = s.split(",")
		var nums: Array[float] = []
		var all_num: bool = true
		for part in parts:
			var t := part.strip_edges()
			if not (t.is_valid_float() or t.is_valid_int()):
				all_num = false
				break
			nums.append(t.to_float())
		if all_num:
			match nums.size():
				2: return Vector2(nums[0], nums[1])
				3: return Vector3(nums[0], nums[1], nums[2])
				4: return Vector4(nums[0], nums[1], nums[2], nums[3])
	if s.is_valid_int():
		return s.to_int()
	if s.is_valid_float():
		return s.to_float()
	return s

func _parse_vec3(raw: String) -> Vector3:
	var v: Variant = _parse_value(raw)
	if v is Vector3:
		return v
	if v is Vector2:
		var v2: Vector2 = v
		return Vector3(v2.x, 0.0, v2.y)
	return Vector3.ZERO

func _parse_vec2(raw: String) -> Vector2:
	var v: Variant = _parse_value(raw)
	if v is Vector2:
		return v
	if v is Vector3:
		var v3: Vector3 = v
		return Vector2(v3.x, v3.y)
	return Vector2.ZERO

func _vec3_str(v: Vector3) -> String:
	return "(%.2f,%.2f,%.2f)" % [v.x, v.y, v.z]

func _vec2_str(v: Vector2) -> String:
	return "(%.2f,%.2f)" % [v.x, v.y]

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

#endregion

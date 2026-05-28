@tool
class_name DebugConsolePhysicsCommands extends RefCounted

# Physics queries and force application at runtime. Designed for the
# "shake the simulation and see what happens" debugging workflow: cast rays
# from arbitrary points, dump live overlap sets, kick rigid bodies, swap
# collision masks on the fly, and yank gravity to stress test reactions.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"

var _registry: Node
var _core: Node

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("raycast", _cmd_raycast, "Cast a 3D ray: raycast <fx,fy,fz> <tx,ty,tz> [collision_mask]", "game")
	_registry.register_command("raycast2d", _cmd_raycast2d, "Cast a 2D ray: raycast2d <fx,fy> <tx,ty> [collision_mask]", "game")
	_registry.register_command("apply_force", _cmd_apply_force, "Apply central force to RigidBody3D: apply_force <path> <fx,fy,fz>", "game")
	_registry.register_command("apply_impulse", _cmd_apply_impulse, "Apply central impulse to RigidBody3D: apply_impulse <path> <ix,iy,iz>", "game")
	_registry.register_command("set_velocity", _cmd_set_velocity, "Set linear_velocity on RigidBody3D/CharacterBody3D: set_velocity <path> <vx,vy,vz>", "game")
	_registry.register_command("bodies_in_area", _cmd_bodies_in_area, "List overlapping bodies in an Area3D: bodies_in_area <area_path>", "game")
	_registry.register_command("bodies_at", _cmd_bodies_at, "Sphere shape query at point: bodies_at <x,y,z> [radius] [mask]", "game")
	_registry.register_command("collision_layers", _cmd_collision_layers, "Dump project layer names (and node layer/mask if given): collision_layers [path]", "game")
	_registry.register_command("set_layer", _cmd_set_layer, "Set collision_layer bits on a node: set_layer <path> <bits>", "game")
	_registry.register_command("set_mask", _cmd_set_mask, "Set collision_mask bits on a node: set_mask <path> <bits>", "game")
	_registry.register_command("gravity", _cmd_gravity, "Get/set ProjectSettings default 3D gravity vector: gravity [x,y,z]", "game")
	_registry.register_command("physics_dump", _cmd_physics_dump, "Report active body count, collision pairs, islands, sleeping count", "game")

#region Command implementations

func _cmd_raycast(args: Array, _piped_input: String = "") -> String:
	if Engine.is_editor_hint():
		return _format_error("raycast only works in runtime (needs a live PhysicsDirectSpaceState3D)")
	if args.size() < 2:
		return _format_error("Usage: raycast <fx,fy,fz> <tx,ty,tz> [collision_mask]")
	var from := _parse_vec3(str(args[0]))
	var to := _parse_vec3(str(args[1]))
	if from == null or to == null:
		return _format_error("Expected vec3 'x,y,z' for from/to")
	var mask: int = int(str(args[2])) if args.size() > 2 and str(args[2]).is_valid_int() else 0xFFFFFFFF
	var space := _get_space_3d()
	if not space:
		return _format_error("No active 3D space state (is the scene a 3D scene?)")
	var params := PhysicsRayQueryParameters3D.create(from, to, mask)
	var hit: Dictionary = space.intersect_ray(params)
	if hit.is_empty():
		return "No hit from %s to %s (mask %s)" % [_color_num(str(from)), _color_num(str(to)), _color_num("0x%08X" % mask)]
	var collider: Object = hit.get("collider")
	var col_path: String = (collider as Node).get_path() if collider is Node else "<non-Node>"
	return "Hit %s at %s normal %s (rid %s)" % [
		_color_path(col_path),
		_color_num(str(hit.get("position", Vector3.ZERO))),
		_color_num(str(hit.get("normal", Vector3.ZERO))),
		_color_num(str(hit.get("rid", RID())))
	]

func _cmd_raycast2d(args: Array, _piped_input: String = "") -> String:
	if Engine.is_editor_hint():
		return _format_error("raycast2d only works in runtime")
	if args.size() < 2:
		return _format_error("Usage: raycast2d <fx,fy> <tx,ty> [collision_mask]")
	var from := _parse_vec2(str(args[0]))
	var to := _parse_vec2(str(args[1]))
	if from == null or to == null:
		return _format_error("Expected vec2 'x,y' for from/to")
	var mask: int = int(str(args[2])) if args.size() > 2 and str(args[2]).is_valid_int() else 0xFFFFFFFF
	var space := _get_space_2d()
	if not space:
		return _format_error("No active 2D space state (is the scene a 2D scene?)")
	var params := PhysicsRayQueryParameters2D.create(from, to, mask)
	var hit: Dictionary = space.intersect_ray(params)
	if hit.is_empty():
		return "No hit from %s to %s (mask %s)" % [_color_num(str(from)), _color_num(str(to)), _color_num("0x%08X" % mask)]
	var collider: Object = hit.get("collider")
	var col_path: String = (collider as Node).get_path() if collider is Node else "<non-Node>"
	return "Hit %s at %s normal %s" % [
		_color_path(col_path),
		_color_num(str(hit.get("position", Vector2.ZERO))),
		_color_num(str(hit.get("normal", Vector2.ZERO)))
	]

func _cmd_apply_force(args: Array, _piped_input: String = "") -> String:
	if Engine.is_editor_hint():
		return _format_error("apply_force only works in runtime")
	if args.size() < 2:
		return _format_error("Usage: apply_force <path> <fx,fy,fz>")
	var node := _resolve_node(str(args[0]))
	if not node:
		return _format_error("Node not found: %s" % str(args[0]))
	if not (node is RigidBody3D):
		return _format_error("%s is not a RigidBody3D (got %s)" % [node.get_path(), node.get_class()])
	var force := _parse_vec3(str(args[1]))
	if force == null:
		return _format_error("Expected vec3 'fx,fy,fz' for force")
	(node as RigidBody3D).apply_central_force(force)
	return _format_success("Applied force %s to %s" % [_color_num(str(force)), _color_path(str(node.get_path()))])

func _cmd_apply_impulse(args: Array, _piped_input: String = "") -> String:
	if Engine.is_editor_hint():
		return _format_error("apply_impulse only works in runtime")
	if args.size() < 2:
		return _format_error("Usage: apply_impulse <path> <ix,iy,iz>")
	var node := _resolve_node(str(args[0]))
	if not node:
		return _format_error("Node not found: %s" % str(args[0]))
	if not (node is RigidBody3D):
		return _format_error("%s is not a RigidBody3D (got %s)" % [node.get_path(), node.get_class()])
	var impulse := _parse_vec3(str(args[1]))
	if impulse == null:
		return _format_error("Expected vec3 'ix,iy,iz' for impulse")
	(node as RigidBody3D).apply_central_impulse(impulse)
	return _format_success("Applied impulse %s to %s" % [_color_num(str(impulse)), _color_path(str(node.get_path()))])

func _cmd_set_velocity(args: Array, _piped_input: String = "") -> String:
	if Engine.is_editor_hint():
		return _format_error("set_velocity only works in runtime")
	if args.size() < 2:
		return _format_error("Usage: set_velocity <path> <vx,vy,vz>")
	var node := _resolve_node(str(args[0]))
	if not node:
		return _format_error("Node not found: %s" % str(args[0]))
	var vel := _parse_vec3(str(args[1]))
	if vel == null:
		return _format_error("Expected vec3 'vx,vy,vz' for velocity")
	# Both RigidBody3D and CharacterBody3D expose linear_velocity.
	# Duck-type check catches user subclasses that re-expose the property.
	if not "linear_velocity" in node:
		return _format_error("%s has no linear_velocity property (need RigidBody3D or CharacterBody3D)" % node.get_path())
	node.set("linear_velocity", vel)
	return _format_success("Set linear_velocity %s on %s" % [_color_num(str(vel)), _color_path(str(node.get_path()))])

func _cmd_bodies_in_area(args: Array, _piped_input: String = "") -> String:
	if Engine.is_editor_hint():
		return _format_error("bodies_in_area only works in runtime")
	if args.is_empty():
		return _format_error("Usage: bodies_in_area <area_path>")
	var node := _resolve_node(str(args[0]))
	if not node:
		return _format_error("Node not found: %s" % str(args[0]))
	if not (node is Area3D):
		return _format_error("%s is not an Area3D (got %s)" % [node.get_path(), node.get_class()])
	var area := node as Area3D
	if not area.monitoring:
		return _format_error("Area3D %s has monitoring=false; enable it and wait one physics frame" % area.get_path())
	var bodies: Array[Node3D] = area.get_overlapping_bodies()
	if bodies.is_empty():
		return "No overlapping bodies in %s" % _color_path(str(area.get_path()))
	var lines: Array[String] = []
	lines.append("Bodies overlapping %s (%s):" % [_color_path(str(area.get_path())), _color_num(str(bodies.size()))])
	for b in bodies:
		lines.append("  %s (%s)" % [_color_path(str(b.get_path())), b.get_class()])
	return "\n".join(lines)

func _cmd_bodies_at(args: Array, _piped_input: String = "") -> String:
	if Engine.is_editor_hint():
		return _format_error("bodies_at only works in runtime")
	if args.is_empty():
		return _format_error("Usage: bodies_at <x,y,z> [radius] [mask]")
	var point := _parse_vec3(str(args[0]))
	if point == null:
		return _format_error("Expected vec3 'x,y,z' for point")
	var radius: float = float(str(args[1])) if args.size() > 1 and (str(args[1]).is_valid_float() or str(args[1]).is_valid_int()) else 0.5
	var mask: int = int(str(args[2])) if args.size() > 2 and str(args[2]).is_valid_int() else 0xFFFFFFFF
	var space := _get_space_3d()
	if not space:
		return _format_error("No active 3D space state")
	var sphere := SphereShape3D.new()
	sphere.radius = radius
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = sphere
	params.transform = Transform3D(Basis(), point)
	params.collision_mask = mask
	var hits: Array[Dictionary] = space.intersect_shape(params, 32)
	if hits.is_empty():
		return "No bodies within radius %s of %s (mask %s)" % [_color_num(str(radius)), _color_num(str(point)), _color_num("0x%08X" % mask)]
	var lines: Array[String] = []
	lines.append("Bodies at %s r=%s (%s hits):" % [_color_num(str(point)), _color_num(str(radius)), _color_num(str(hits.size()))])
	for h in hits:
		var collider: Object = h.get("collider")
		var col_path: String = (collider as Node).get_path() if collider is Node else "<non-Node>"
		lines.append("  %s (shape_idx %s)" % [_color_path(col_path), _color_num(str(h.get("shape", 0)))])
	return "\n".join(lines)

func _cmd_collision_layers(args: Array, _piped_input: String = "") -> String:
	if Engine.is_editor_hint():
		return _format_error("collision_layers only works in runtime")
	# ProjectSettings stores per-bit names under layer_names/3d_physics/layer_N
	# for N in 1..32. Missing keys mean the user never renamed that slot;
	# we surface them as "<unnamed>" rather than hiding them so the bit
	# index is always recoverable from the dump.
	var lines: Array[String] = []
	lines.append("3D physics layer names:")
	for i in range(1, 33):
		var key := "layer_names/3d_physics/layer_%d" % i
		var name: String = str(ProjectSettings.get_setting(key, ""))
		var display: String = name if not name.is_empty() else "<unnamed>"
		lines.append("  bit %s (0x%08X): %s" % [_color_num(str(i)), 1 << (i - 1), display])
	if not args.is_empty():
		var node := _resolve_node(str(args[0]))
		if not node:
			lines.append(_format_error("Node not found: %s" % str(args[0])))
		elif not ("collision_layer" in node and "collision_mask" in node):
			lines.append(_format_error("%s has no collision_layer/collision_mask" % node.get_path()))
		else:
			lines.append("")
			lines.append("%s:" % _color_path(str(node.get_path())))
			lines.append("  collision_layer = %s" % _color_num("0x%08X" % int(node.get("collision_layer"))))
			lines.append("  collision_mask  = %s" % _color_num("0x%08X" % int(node.get("collision_mask"))))
	return "\n".join(lines)

func _cmd_set_layer(args: Array, _piped_input: String = "") -> String:
	if Engine.is_editor_hint():
		return _format_error("set_layer only works in runtime")
	if args.size() < 2:
		return _format_error("Usage: set_layer <path> <bits>")
	var node := _resolve_node(str(args[0]))
	if not node:
		return _format_error("Node not found: %s" % str(args[0]))
	if not "collision_layer" in node:
		return _format_error("%s has no collision_layer property" % node.get_path())
	var bits_raw := str(args[1]).strip_edges()
	var bits: int = _parse_bits(bits_raw)
	if bits == -1:
		return _format_error("Expected integer bits (decimal or 0xHEX), got '%s'" % bits_raw)
	node.set("collision_layer", bits)
	return _format_success("Set collision_layer = %s on %s" % [_color_num("0x%08X" % bits), _color_path(str(node.get_path()))])

func _cmd_set_mask(args: Array, _piped_input: String = "") -> String:
	if Engine.is_editor_hint():
		return _format_error("set_mask only works in runtime")
	if args.size() < 2:
		return _format_error("Usage: set_mask <path> <bits>")
	var node := _resolve_node(str(args[0]))
	if not node:
		return _format_error("Node not found: %s" % str(args[0]))
	if not "collision_mask" in node:
		return _format_error("%s has no collision_mask property" % node.get_path())
	var bits_raw := str(args[1]).strip_edges()
	var bits: int = _parse_bits(bits_raw)
	if bits == -1:
		return _format_error("Expected integer bits (decimal or 0xHEX), got '%s'" % bits_raw)
	node.set("collision_mask", bits)
	return _format_success("Set collision_mask = %s on %s" % [_color_num("0x%08X" % bits), _color_path(str(node.get_path()))])

func _cmd_gravity(args: Array, _piped_input: String = "") -> String:
	if Engine.is_editor_hint():
		return _format_error("gravity only works in runtime")
	var mag: float = float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
	var dir: Vector3 = ProjectSettings.get_setting("physics/3d/default_gravity_vector", Vector3(0, -1, 0))
	if args.is_empty():
		return "Default 3D gravity: %s (magnitude %s, direction %s)" % [
			_color_num(str(dir * mag)),
			_color_num(str(mag)),
			_color_num(str(dir))
		]
	var new_grav := _parse_vec3(str(args[0]))
	if new_grav == null:
		return _format_error("Expected vec3 'x,y,z' for gravity")
	var new_mag: float = new_grav.length()
	var new_dir: Vector3 = new_grav.normalized() if new_mag > 0.0 else Vector3(0, -1, 0)
	ProjectSettings.set_setting("physics/3d/default_gravity", new_mag)
	ProjectSettings.set_setting("physics/3d/default_gravity_vector", new_dir)
	var pushed: bool = _push_gravity_to_live_world(new_mag, new_dir)
	var note: String = " (live world updated)" if pushed else " (project setting only; restart play to apply to live world)"
	return _format_success("Set gravity to %s%s" % [_color_num(str(new_dir * new_mag)), note])

func _cmd_physics_dump(_args: Array, _piped_input: String = "") -> String:
	if Engine.is_editor_hint():
		return _format_error("physics_dump only works in runtime")
	var active: int = int(Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS))
	var pairs: int = int(Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS))
	var islands: int = int(Performance.get_monitor(Performance.PHYSICS_3D_ISLAND_COUNT))
	var sleeping: int = _count_sleeping_bodies()
	var active2d: int = int(Performance.get_monitor(Performance.PHYSICS_2D_ACTIVE_OBJECTS))
	var pairs2d: int = int(Performance.get_monitor(Performance.PHYSICS_2D_COLLISION_PAIRS))
	var lines: Array[String] = []
	lines.append("Physics state:")
	lines.append("  3D active bodies:   %s" % _color_num(str(active)))
	lines.append("  3D sleeping bodies: %s" % _color_num(str(sleeping)))
	lines.append("  3D collision pairs: %s" % _color_num(str(pairs)))
	lines.append("  3D islands:         %s" % _color_num(str(islands)))
	lines.append("  2D active bodies:   %s" % _color_num(str(active2d)))
	lines.append("  2D collision pairs: %s" % _color_num(str(pairs2d)))
	return "\n".join(lines)

#endregion
#region Helpers

func _get_scene_tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree

func _get_scene_root() -> Node:
	var tree := _get_scene_tree()
	if not tree:
		return null
	if tree.current_scene:
		return tree.current_scene
	return tree.root

func _resolve_node(path: String) -> Node:
	var p := path.strip_edges()
	if p.is_empty():
		return null
	var tree := _get_scene_tree()
	if not tree:
		return null
	if p.begins_with("/"):
		return tree.root.get_node_or_null(p)
	var scene: Node = tree.current_scene if tree.current_scene else tree.root
	return scene.get_node_or_null(p)

func _get_space_3d() -> PhysicsDirectSpaceState3D:
	var tree := _get_scene_tree()
	if not tree or not tree.root:
		return null
	var vp := tree.root.get_viewport()
	if not vp:
		return null
	var world := vp.world_3d
	if not world:
		return null
	return world.direct_space_state

func _get_space_2d() -> PhysicsDirectSpaceState2D:
	var tree := _get_scene_tree()
	if not tree or not tree.root:
		return null
	var vp := tree.root.get_viewport()
	if not vp:
		return null
	var world := vp.world_2d
	if not world:
		return null
	return world.direct_space_state

func _parse_vec3(raw: String) -> Variant:
	var s := raw.strip_edges()
	if not s.contains(","):
		return null
	var parts: PackedStringArray = s.split(",")
	if parts.size() != 3:
		return null
	var nums: Array[float] = []
	for p in parts:
		var t := p.strip_edges()
		if not (t.is_valid_float() or t.is_valid_int()):
			return null
		nums.append(t.to_float())
	return Vector3(nums[0], nums[1], nums[2])

func _parse_vec2(raw: String) -> Variant:
	var s := raw.strip_edges()
	if not s.contains(","):
		return null
	var parts: PackedStringArray = s.split(",")
	if parts.size() != 2:
		return null
	var nums: Array[float] = []
	for p in parts:
		var t := p.strip_edges()
		if not (t.is_valid_float() or t.is_valid_int()):
			return null
		nums.append(t.to_float())
	return Vector2(nums[0], nums[1])

func _parse_bits(raw: String) -> int:
	var s := raw.strip_edges().to_lower()
	if s.begins_with("0x"):
		var hex := s.substr(2)
		if hex.is_empty():
			return -1
		for c in hex:
			if not "0123456789abcdef".contains(c):
				return -1
		return s.hex_to_int()
	if s.is_valid_int():
		return s.to_int()
	return -1

func _count_sleeping_bodies() -> int:
	var root := _get_scene_root()
	if not root:
		return 0
	var count: int = 0
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is RigidBody3D and (n as RigidBody3D).sleeping:
			count += 1
		for c in n.get_children():
			stack.append(c)
	return count

func _push_gravity_to_live_world(magnitude: float, direction: Vector3) -> bool:
	var tree := _get_scene_tree()
	if not tree or not tree.root:
		return false
	var vp := tree.root.get_viewport()
	if not vp:
		return false
	var world := vp.world_3d
	if not world:
		return false
	var space: RID = world.space
	if not space.is_valid():
		return false
	var root := _get_scene_root()
	if not root:
		return false
	var pushed_any: bool = false
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is Area3D:
			var a := n as Area3D
			a.gravity = magnitude
			a.gravity_direction = direction
			pushed_any = true
		for c in n.get_children():
			stack.append(c)
	return pushed_any

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_num(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

#endregion

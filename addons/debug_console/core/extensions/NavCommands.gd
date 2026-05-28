@tool
class_name DebugConsoleNavCommands extends RefCounted

# Tier 8 - live NavigationServer (2D + 3D) inspection commands. Lives in
# extensions/ so BuiltInCommands.register_universal_commands picks it up via
# the extensions loader on plugin enable. The orchestrator instantiates one
# of these, holds a strong reference (alongside the other tier modules), and
# calls register_commands(registry, core). All commands route through that
# strong-referenced instance so their Callables stay valid for the lifetime
# of the plugin.
#
# Auto-detection rule: the point arguments to nav_path / nav_test_reach are
# parsed by counting comma-separated components. Two components routes the
# query to NavigationServer2D; three components routes it to NavigationServer3D.
# Inspection commands (nav_maps, nav_regions, nav_agents, nav_obstacles)
# list both servers side by side. nav_layers picks the agent class off the
# resolved node.
#
# All commands are registered with context "game" because the NavigationServer
# regions / agents / obstacles only populate while the SceneTree is running.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_INFO := "#C8C8C8"

const _REACH_EPSILON := 0.5

var _registry: Node
var _core: Node

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("nav_maps", _cmd_nav_maps, "List NavigationServer 2D + 3D maps with rid, cell size, region/agent/obstacle counts: nav_maps", "game")
	_registry.register_command("nav_regions", _cmd_nav_regions, "List navigation regions across all maps (or filter by map rid id): nav_regions [map_rid]", "game")
	_registry.register_command("nav_agents", _cmd_nav_agents, "List active navigation agents across all maps: nav_agents", "game")
	_registry.register_command("nav_path", _cmd_nav_path, "Compute a path between two points; comma count picks 2D vs 3D: nav_path <from x,y[,z]> <to x,y[,z]> [map_rid]", "game")
	_registry.register_command("nav_test_reach", _cmd_nav_test_reach, "Test reachability between two points (true/false), 2D or 3D auto-detected: nav_test_reach <from> <to>", "game")
	_registry.register_command("nav_obstacles", _cmd_nav_obstacles, "List dynamic navigation obstacles across all maps: nav_obstacles", "game")
	_registry.register_command("nav_layers", _cmd_nav_layers, "Show a NavigationAgent2D/3D node's navigation_layers + avoidance layers/mask: nav_layers <node_path>", "game")

#region Command implementations

func _cmd_nav_maps(_args: Array, _piped_input: String = "") -> String:
	var lines: Array[String] = []

	var maps3: Array[RID] = NavigationServer3D.get_maps()
	lines.append("NavigationServer3D maps: %s" % _color_number(str(maps3.size())))
	for m in maps3:
		if not m.is_valid():
			continue
		var regions: int = NavigationServer3D.map_get_regions(m).size()
		var agents: int = NavigationServer3D.map_get_agents(m).size()
		var obstacles: int = NavigationServer3D.map_get_obstacles(m).size()
		var cell_size: float = NavigationServer3D.map_get_cell_size(m)
		var active: bool = NavigationServer3D.map_is_active(m)
		lines.append("  3D rid=%s active=%s cell=%.3f regions=%s agents=%s obstacles=%s" % [
			_color_number(str(m.get_id())),
			str(active),
			cell_size,
			_color_number(str(regions)),
			_color_number(str(agents)),
			_color_number(str(obstacles)),
		])

	var maps2: Array[RID] = NavigationServer2D.get_maps()
	lines.append("NavigationServer2D maps: %s" % _color_number(str(maps2.size())))
	for m in maps2:
		if not m.is_valid():
			continue
		var regions2: int = NavigationServer2D.map_get_regions(m).size()
		var agents2: int = NavigationServer2D.map_get_agents(m).size()
		var obstacles2: int = NavigationServer2D.map_get_obstacles(m).size()
		var cell_size2: float = NavigationServer2D.map_get_cell_size(m)
		var active2: bool = NavigationServer2D.map_is_active(m)
		lines.append("  2D rid=%s active=%s cell=%.3f regions=%s agents=%s obstacles=%s" % [
			_color_number(str(m.get_id())),
			str(active2),
			cell_size2,
			_color_number(str(regions2)),
			_color_number(str(agents2)),
			_color_number(str(obstacles2)),
		])

	if maps3.is_empty() and maps2.is_empty():
		lines.append(_color_info("(no active navigation maps)"))
	return "\n".join(lines)

func _cmd_nav_regions(args: Array, _piped_input: String = "") -> String:
	var filter_id: int = -1
	if args.size() > 0:
		var raw := str(args[0]).strip_edges()
		if not raw.is_valid_int():
			return _format_error("map_rid must be an integer rid id (see nav_maps); got '%s'" % raw)
		filter_id = raw.to_int()

	var lines: Array[String] = []
	var matched: bool = false

	for m in NavigationServer3D.get_maps():
		if not m.is_valid():
			continue
		if filter_id >= 0 and m.get_id() != filter_id:
			continue
		matched = true
		var regions: Array[RID] = NavigationServer3D.map_get_regions(m)
		lines.append("3D map %s : %s regions" % [_color_number(str(m.get_id())), _color_number(str(regions.size()))])
		for r in regions:
			if not r.is_valid():
				continue
			var enabled: bool = NavigationServer3D.region_get_enabled(r)
			var layers: int = NavigationServer3D.region_get_navigation_layers(r)
			var connections: int = NavigationServer3D.region_get_connections_count(r)
			lines.append("  rid=%s enabled=%s layers=0x%08x (%s) connections=%s" % [
				_color_number(str(r.get_id())),
				str(enabled),
				layers,
				_bitlist(layers),
				_color_number(str(connections)),
			])

	for m in NavigationServer2D.get_maps():
		if not m.is_valid():
			continue
		if filter_id >= 0 and m.get_id() != filter_id:
			continue
		matched = true
		var regions2: Array[RID] = NavigationServer2D.map_get_regions(m)
		lines.append("2D map %s : %s regions" % [_color_number(str(m.get_id())), _color_number(str(regions2.size()))])
		for r in regions2:
			if not r.is_valid():
				continue
			var enabled2: bool = NavigationServer2D.region_get_enabled(r)
			var layers2: int = NavigationServer2D.region_get_navigation_layers(r)
			var connections2: int = NavigationServer2D.region_get_connections_count(r)
			lines.append("  rid=%s enabled=%s layers=0x%08x (%s) connections=%s" % [
				_color_number(str(r.get_id())),
				str(enabled2),
				layers2,
				_bitlist(layers2),
				_color_number(str(connections2)),
			])

	if filter_id >= 0 and not matched:
		return _format_error("No navigation map with rid id %d (see nav_maps)" % filter_id)
	if lines.is_empty():
		return _color_info("(no navigation regions)")
	return "\n".join(lines)

func _cmd_nav_agents(_args: Array, _piped_input: String = "") -> String:
	var lines: Array[String] = []
	var total: int = 0

	for m in NavigationServer3D.get_maps():
		if not m.is_valid():
			continue
		var agents: Array[RID] = NavigationServer3D.map_get_agents(m)
		if agents.is_empty():
			continue
		lines.append("3D map %s : %s agents" % [_color_number(str(m.get_id())), _color_number(str(agents.size()))])
		for a in agents:
			if not a.is_valid():
				continue
			total += 1
			var paused: bool = NavigationServer3D.agent_get_paused(a)
			var avoidance: bool = NavigationServer3D.agent_get_avoidance_enabled(a)
			var radius: float = NavigationServer3D.agent_get_radius(a)
			var max_speed: float = NavigationServer3D.agent_get_max_speed(a)
			lines.append("  rid=%s paused=%s avoidance=%s radius=%.3f max_speed=%.3f" % [
				_color_number(str(a.get_id())),
				str(paused),
				str(avoidance),
				radius,
				max_speed,
			])

	for m in NavigationServer2D.get_maps():
		if not m.is_valid():
			continue
		var agents2: Array[RID] = NavigationServer2D.map_get_agents(m)
		if agents2.is_empty():
			continue
		lines.append("2D map %s : %s agents" % [_color_number(str(m.get_id())), _color_number(str(agents2.size()))])
		for a in agents2:
			if not a.is_valid():
				continue
			total += 1
			var paused2: bool = NavigationServer2D.agent_get_paused(a)
			var avoidance2: bool = NavigationServer2D.agent_get_avoidance_enabled(a)
			var radius2: float = NavigationServer2D.agent_get_radius(a)
			var max_speed2: float = NavigationServer2D.agent_get_max_speed(a)
			lines.append("  rid=%s paused=%s avoidance=%s radius=%.3f max_speed=%.3f" % [
				_color_number(str(a.get_id())),
				str(paused2),
				str(avoidance2),
				radius2,
				max_speed2,
			])

	if lines.is_empty():
		return _color_info("(no active navigation agents)")
	lines.append("Total agents: %s" % _color_number(str(total)))
	return "\n".join(lines)

func _cmd_nav_path(args: Array, _piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: nav_path <from x,y[,z]> <to x,y[,z]> [map_rid]")
	var from_raw := str(args[0]).strip_edges()
	var to_raw := str(args[1]).strip_edges()
	var dim_from: int = _point_dim(from_raw)
	var dim_to: int = _point_dim(to_raw)
	if dim_from == 0 or dim_to == 0:
		return _format_error("Could not parse points; use 'x,y' for 2D or 'x,y,z' for 3D")
	if dim_from != dim_to:
		return _format_error("Dimension mismatch: from=%dD vs to=%dD" % [dim_from, dim_to])

	var override_id: int = -1
	if args.size() > 2:
		var raw := str(args[2]).strip_edges()
		if not raw.is_valid_int():
			return _format_error("map_rid must be an integer rid id (see nav_maps)")
		override_id = raw.to_int()

	if dim_from == 3:
		var from_v3: Vector3 = _parse_vec3(from_raw)
		var to_v3: Vector3 = _parse_vec3(to_raw)
		var map: RID = _resolve_map_3d(override_id)
		if not map.is_valid():
			return _format_error("No valid 3D navigation map (see nav_maps)")
		var path: PackedVector3Array = NavigationServer3D.map_get_path(map, from_v3, to_v3, true)
		return _format_path_3d(map, from_v3, to_v3, path)

	var from_v2: Vector2 = _parse_vec2(from_raw)
	var to_v2: Vector2 = _parse_vec2(to_raw)
	var map2: RID = _resolve_map_2d(override_id)
	if not map2.is_valid():
		return _format_error("No valid 2D navigation map (see nav_maps)")
	var path2: PackedVector2Array = NavigationServer2D.map_get_path(map2, from_v2, to_v2, true)
	return _format_path_2d(map2, from_v2, to_v2, path2)

func _cmd_nav_test_reach(args: Array, _piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: nav_test_reach <from x,y[,z]> <to x,y[,z]>")
	var from_raw := str(args[0]).strip_edges()
	var to_raw := str(args[1]).strip_edges()
	var dim_from: int = _point_dim(from_raw)
	var dim_to: int = _point_dim(to_raw)
	if dim_from == 0 or dim_to == 0:
		return _format_error("Could not parse points; use 'x,y' for 2D or 'x,y,z' for 3D")
	if dim_from != dim_to:
		return _format_error("Dimension mismatch: from=%dD vs to=%dD" % [dim_from, dim_to])

	if dim_from == 3:
		var from_v3: Vector3 = _parse_vec3(from_raw)
		var to_v3: Vector3 = _parse_vec3(to_raw)
		var map: RID = _resolve_map_3d(-1)
		if not map.is_valid():
			return _format_error("No valid 3D navigation map (see nav_maps)")
		var path: PackedVector3Array = NavigationServer3D.map_get_path(map, from_v3, to_v3, true)
		var reachable: bool = path.size() >= 2 and path[path.size() - 1].distance_to(to_v3) <= _REACH_EPSILON
		return _format_reach(reachable, path.size())

	var from_v2: Vector2 = _parse_vec2(from_raw)
	var to_v2: Vector2 = _parse_vec2(to_raw)
	var map2: RID = _resolve_map_2d(-1)
	if not map2.is_valid():
		return _format_error("No valid 2D navigation map (see nav_maps)")
	var path2: PackedVector2Array = NavigationServer2D.map_get_path(map2, from_v2, to_v2, true)
	var reachable2: bool = path2.size() >= 2 and path2[path2.size() - 1].distance_to(to_v2) <= _REACH_EPSILON
	return _format_reach(reachable2, path2.size())

func _cmd_nav_obstacles(_args: Array, _piped_input: String = "") -> String:
	var lines: Array[String] = []
	var total: int = 0

	for m in NavigationServer3D.get_maps():
		if not m.is_valid():
			continue
		var obstacles: Array[RID] = NavigationServer3D.map_get_obstacles(m)
		if obstacles.is_empty():
			continue
		lines.append("3D map %s : %s obstacles" % [_color_number(str(m.get_id())), _color_number(str(obstacles.size()))])
		for o in obstacles:
			if not o.is_valid():
				continue
			total += 1
			var paused: bool = NavigationServer3D.obstacle_get_paused(o)
			var avoidance: bool = NavigationServer3D.obstacle_get_avoidance_enabled(o)
			var radius: float = NavigationServer3D.obstacle_get_radius(o)
			var vertices: int = NavigationServer3D.obstacle_get_vertices(o).size()
			lines.append("  rid=%s paused=%s avoidance=%s radius=%.3f vertices=%s" % [
				_color_number(str(o.get_id())),
				str(paused),
				str(avoidance),
				radius,
				_color_number(str(vertices)),
			])

	for m in NavigationServer2D.get_maps():
		if not m.is_valid():
			continue
		var obstacles2: Array[RID] = NavigationServer2D.map_get_obstacles(m)
		if obstacles2.is_empty():
			continue
		lines.append("2D map %s : %s obstacles" % [_color_number(str(m.get_id())), _color_number(str(obstacles2.size()))])
		for o in obstacles2:
			if not o.is_valid():
				continue
			total += 1
			var paused2: bool = NavigationServer2D.obstacle_get_paused(o)
			var avoidance2: bool = NavigationServer2D.obstacle_get_avoidance_enabled(o)
			var radius2: float = NavigationServer2D.obstacle_get_radius(o)
			var vertices2: int = NavigationServer2D.obstacle_get_vertices(o).size()
			lines.append("  rid=%s paused=%s avoidance=%s radius=%.3f vertices=%s" % [
				_color_number(str(o.get_id())),
				str(paused2),
				str(avoidance2),
				radius2,
				_color_number(str(vertices2)),
			])

	if lines.is_empty():
		return _color_info("(no active navigation obstacles)")
	lines.append("Total obstacles: %s" % _color_number(str(total)))
	return "\n".join(lines)

func _cmd_nav_layers(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: nav_layers <node_path>")
	var node_path := str(args[0]).strip_edges()
	var node := _resolve_node(node_path)
	if not node:
		return _format_error("Node not found: %s" % node_path)

	var lines: Array[String] = []
	var resolved_path: String = str(node.get_path()) if node.is_inside_tree() else node.name
	lines.append("%s (%s)" % [_color_path(resolved_path), node.get_class()])

	if node is NavigationAgent3D:
		var a: NavigationAgent3D = node
		lines.append("  kind              : NavigationAgent3D")
		lines.append("  navigation_layers : 0x%08x (%s)" % [a.navigation_layers, _bitlist(a.navigation_layers)])
		lines.append("  avoidance_enabled : %s" % str(a.avoidance_enabled))
		lines.append("  avoidance_layers  : 0x%08x (%s)" % [a.avoidance_layers, _bitlist(a.avoidance_layers)])
		lines.append("  avoidance_mask    : 0x%08x (%s)" % [a.avoidance_mask, _bitlist(a.avoidance_mask)])
		lines.append("  radius            : %.3f" % a.radius)
		lines.append("  max_speed         : %.3f" % a.max_speed)
		return "\n".join(lines)

	if node is NavigationAgent2D:
		var a2: NavigationAgent2D = node
		lines.append("  kind              : NavigationAgent2D")
		lines.append("  navigation_layers : 0x%08x (%s)" % [a2.navigation_layers, _bitlist(a2.navigation_layers)])
		lines.append("  avoidance_enabled : %s" % str(a2.avoidance_enabled))
		lines.append("  avoidance_layers  : 0x%08x (%s)" % [a2.avoidance_layers, _bitlist(a2.avoidance_layers)])
		lines.append("  avoidance_mask    : 0x%08x (%s)" % [a2.avoidance_mask, _bitlist(a2.avoidance_mask)])
		lines.append("  radius            : %.3f" % a2.radius)
		lines.append("  max_speed         : %.3f" % a2.max_speed)
		return "\n".join(lines)

	return _format_error("Node %s is not a NavigationAgent2D or NavigationAgent3D (got %s)" % [resolved_path, node.get_class()])

#endregion

#region Helpers

func _point_dim(raw: String) -> int:
	var s := raw.strip_edges()
	if s.is_empty():
		return 0
	var parts: PackedStringArray = s.split(",")
	var n: int = parts.size()
	if n != 2 and n != 3:
		return 0
	for p in parts:
		var t := p.strip_edges()
		if not (t.is_valid_float() or t.is_valid_int()):
			return 0
	return n

func _parse_vec3(raw: String) -> Vector3:
	var parts: PackedStringArray = raw.split(",")
	return Vector3(
		parts[0].strip_edges().to_float(),
		parts[1].strip_edges().to_float(),
		parts[2].strip_edges().to_float(),
	)

func _parse_vec2(raw: String) -> Vector2:
	var parts: PackedStringArray = raw.split(",")
	return Vector2(
		parts[0].strip_edges().to_float(),
		parts[1].strip_edges().to_float(),
	)

func _resolve_map_3d(rid_id: int) -> RID:
	if rid_id >= 0:
		for m in NavigationServer3D.get_maps():
			if m.is_valid() and m.get_id() == rid_id:
				return m
		return RID()
	var tree := Engine.get_main_loop() as SceneTree
	if tree and tree.root:
		var world := tree.root.find_world_3d()
		if world:
			var rid: RID = world.navigation_map
			if rid.is_valid():
				return rid
	var maps: Array[RID] = NavigationServer3D.get_maps()
	for m in maps:
		if m.is_valid():
			return m
	return RID()

func _resolve_map_2d(rid_id: int) -> RID:
	if rid_id >= 0:
		for m in NavigationServer2D.get_maps():
			if m.is_valid() and m.get_id() == rid_id:
				return m
		return RID()
	var tree := Engine.get_main_loop() as SceneTree
	if tree and tree.root:
		var world := tree.root.find_world_2d()
		if world:
			var rid: RID = world.navigation_map
			if rid.is_valid():
				return rid
	var maps: Array[RID] = NavigationServer2D.get_maps()
	for m in maps:
		if m.is_valid():
			return m
	return RID()

func _format_path_3d(map: RID, from: Vector3, to: Vector3, path: PackedVector3Array) -> String:
	var lines: Array[String] = []
	lines.append("3D path on map %s : %s points (from %s to %s)" % [
		_color_number(str(map.get_id())),
		_color_number(str(path.size())),
		_color_path("(%.3f, %.3f, %.3f)" % [from.x, from.y, from.z]),
		_color_path("(%.3f, %.3f, %.3f)" % [to.x, to.y, to.z]),
	])
	if path.is_empty():
		lines.append("  (no path returned)")
		return "\n".join(lines)
	var total_len: float = 0.0
	for i in range(path.size()):
		var p: Vector3 = path[i]
		var seg: String = ""
		if i > 0:
			var d: float = path[i - 1].distance_to(p)
			total_len += d
			seg = "  +%.3f" % d
		lines.append("  [%s] (%.3f, %.3f, %.3f)%s" % [_color_number(str(i)), p.x, p.y, p.z, seg])
	var reachable: bool = path[path.size() - 1].distance_to(to) <= _REACH_EPSILON
	lines.append("  length=%.3f reachable=%s" % [total_len, str(reachable)])
	return "\n".join(lines)

func _format_path_2d(map: RID, from: Vector2, to: Vector2, path: PackedVector2Array) -> String:
	var lines: Array[String] = []
	lines.append("2D path on map %s : %s points (from %s to %s)" % [
		_color_number(str(map.get_id())),
		_color_number(str(path.size())),
		_color_path("(%.3f, %.3f)" % [from.x, from.y]),
		_color_path("(%.3f, %.3f)" % [to.x, to.y]),
	])
	if path.is_empty():
		lines.append("  (no path returned)")
		return "\n".join(lines)
	var total_len: float = 0.0
	for i in range(path.size()):
		var p: Vector2 = path[i]
		var seg: String = ""
		if i > 0:
			var d: float = path[i - 1].distance_to(p)
			total_len += d
			seg = "  +%.3f" % d
		lines.append("  [%s] (%.3f, %.3f)%s" % [_color_number(str(i)), p.x, p.y, seg])
	var reachable: bool = path[path.size() - 1].distance_to(to) <= _REACH_EPSILON
	lines.append("  length=%.3f reachable=%s" % [total_len, str(reachable)])
	return "\n".join(lines)

func _format_reach(reachable: bool, point_count: int) -> String:
	var label: String = "true" if reachable else "false"
	var color: String = _COLOR_SUCCESS if reachable else _COLOR_ERROR
	return "[color=%s]%s[/color]  (path points: %s)" % [color, label, _color_number(str(point_count))]

func _bitlist(mask: int) -> String:
	if mask == 0:
		return "none"
	var bits: Array[String] = []
	for i in range(32):
		if (mask >> i) & 1:
			bits.append(str(i + 1))
	return "layers " + ",".join(bits)

func _resolve_node(path: String) -> Node:
	var p := path.strip_edges()
	if p.is_empty():
		return null
	var tree := Engine.get_main_loop() as SceneTree
	if not tree:
		return null
	if p.begins_with("/"):
		return tree.root.get_node_or_null(p)
	var scene: Node = tree.current_scene if tree.current_scene else tree.root
	return scene.get_node_or_null(p)

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

func _color_info(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_INFO, s]

#endregion

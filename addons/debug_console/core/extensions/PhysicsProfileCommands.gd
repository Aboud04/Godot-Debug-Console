@tool
class_name DebugConsolePhysicsProfileCommands extends RefCounted

# Auto-loaded extension module (see core/extensions/README.md).
# Provides runtime physics profiling commands that surface Performance.PHYSICS_*
# monitors plus walk-the-tree introspection for RigidBody2D / RigidBody3D nodes.
#
# All commands are registered with the "game" context because Performance
# monitors and contact reporting are only meaningful while a SceneTree is
# actually simulating physics. Editor invocations would return zeros or stale
# data and mislead the user.
#
# The orchestrator (BuiltInCommands.register_universal_commands) instantiates
# this module via the extensions loader, keeps a strong reference in
# BuiltInCommands._t6_keepalive, and calls register_commands(registry, core).

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_HEADER := "#C0C0FF"
const _COLOR_WARN := "#FFB070"

const _METRIC_KEYS := [
	"active_2d", "active_3d",
	"islands_2d", "islands_3d",
	"pairs_2d", "pairs_3d",
]

var _registry: Node
var _core: Node
var _alarms: Dictionary = {}
var _watcher: Node = null

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("phys_dump", _cmd_phys_dump, "Dump active bodies / islands / contact pairs for 2D and 3D physics: phys_dump", "game")
	_registry.register_command("phys_bodies", _cmd_phys_bodies, "List every RigidBody2D / RigidBody3D in the current scene with sleep state: phys_bodies [root_path]", "game")
	_registry.register_command("phys_contacts", _cmd_phys_contacts, "List current contacts on a physics body: phys_contacts <body_path>", "game")
	_registry.register_command("phys_islands", _cmd_phys_islands, "Show 2D + 3D physics island counts: phys_islands", "game")
	_registry.register_command("phys_active_count", _cmd_phys_active_count, "Show 2D + 3D active physics object counts: phys_active_count", "game")
	_registry.register_command("phys_sleeping", _cmd_phys_sleeping, "List sleeping RigidBody2D / RigidBody3D nodes: phys_sleeping [root_path]", "game")
	_registry.register_command("phys_alarm", _cmd_phys_alarm, "Warn when a physics metric crosses a threshold: phys_alarm <metric> <threshold> | phys_alarm list | phys_alarm clear [metric]", "game")

#region Command implementations

func _cmd_phys_dump(args: Array, piped_input: String = "") -> String:
	var rows: Array[Array] = []
	rows.append(["metric", "2D", "3D"])
	rows.append(["active_objects", str(_perf(Performance.PHYSICS_2D_ACTIVE_OBJECTS)), str(_perf(Performance.PHYSICS_3D_ACTIVE_OBJECTS))])
	rows.append(["island_count", str(_perf(Performance.PHYSICS_2D_ISLAND_COUNT)), str(_perf(Performance.PHYSICS_3D_ISLAND_COUNT))])
	rows.append(["collision_pairs", str(_perf(Performance.PHYSICS_2D_COLLISION_PAIRS)), str(_perf(Performance.PHYSICS_3D_COLLISION_PAIRS))])

	var out := _color_header("Physics dump\n")
	out += _render_table(rows)
	var bodies := _collect_bodies(_get_scene_root())
	var sleeping_count: int = 0
	for b in bodies:
		if _is_body_sleeping(b):
			sleeping_count += 1
	out += "\nrigid bodies in scene: %s (sleeping: %s)" % [
		_color_number(str(bodies.size())),
		_color_number(str(sleeping_count)),
	]
	return out

func _cmd_phys_bodies(args: Array, piped_input: String = "") -> String:
	var root := _resolve_root_arg(args)
	if not root:
		return _format_error("Scene root unavailable; is a scene running?")
	var bodies := _collect_bodies(root)
	if bodies.is_empty():
		return "No RigidBody2D / RigidBody3D nodes found under %s." % _color_path(str(root.get_path()))
	var rows: Array[Array] = []
	rows.append(["path", "class", "sleep", "linear_velocity"])
	for body in bodies:
		var path_str: String = str(body.get_path()) if body.is_inside_tree() else body.name
		var sleep_str: String = "yes" if _is_body_sleeping(body) else "no"
		var vel_str: String = _velocity_to_string(body)
		rows.append([path_str, body.get_class(), sleep_str, vel_str])
	return _color_header("Rigid bodies (%d)\n" % bodies.size()) + _render_table(rows)

func _cmd_phys_contacts(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: phys_contacts <body_path>")
	var path: String = " ".join(args).strip_edges()
	var node := _resolve_node(path)
	if not node:
		return _format_error("Node not found: %s" % path)

	var contacts: Array = []
	var max_reported: int = 0
	if node is RigidBody3D:
		var body3d: RigidBody3D = node
		if not body3d.contact_monitor:
			body3d.contact_monitor = true
		if body3d.max_contacts_reported <= 0:
			body3d.max_contacts_reported = 8
		max_reported = body3d.max_contacts_reported
		contacts = body3d.get_colliding_bodies()
	elif node is RigidBody2D:
		var body2d: RigidBody2D = node
		if not body2d.contact_monitor:
			body2d.contact_monitor = true
		if body2d.max_contacts_reported <= 0:
			body2d.max_contacts_reported = 8
		max_reported = body2d.max_contacts_reported
		contacts = body2d.get_colliding_bodies()
	else:
		return _format_error("%s is %s, not a RigidBody2D / RigidBody3D" % [path, node.get_class()])

	if contacts.is_empty():
		return "No contacts on %s (max_contacts_reported=%s). Contacts may appear on the next physics frame after enabling contact_monitor." % [
			_color_path(path), _color_number(str(max_reported)),
		]
	var rows: Array[Array] = []
	rows.append(["#", "path", "class"])
	for i in contacts.size():
		var other = contacts[i]
		var other_path: String = "<freed>"
		var other_class: String = "<freed>"
		if is_instance_valid(other) and other is Node:
			var n: Node = other
			other_path = str(n.get_path()) if n.is_inside_tree() else n.name
			other_class = n.get_class()
		rows.append([str(i), other_path, other_class])
	return _color_header("Contacts on %s (%d / %d reported)\n" % [path, contacts.size(), max_reported]) + _render_table(rows)

func _cmd_phys_islands(args: Array, piped_input: String = "") -> String:
	var rows: Array[Array] = []
	rows.append(["dimension", "islands"])
	rows.append(["2D", str(_perf(Performance.PHYSICS_2D_ISLAND_COUNT))])
	rows.append(["3D", str(_perf(Performance.PHYSICS_3D_ISLAND_COUNT))])
	return _render_table(rows)

func _cmd_phys_active_count(args: Array, piped_input: String = "") -> String:
	var rows: Array[Array] = []
	rows.append(["dimension", "active_objects"])
	rows.append(["2D", str(_perf(Performance.PHYSICS_2D_ACTIVE_OBJECTS))])
	rows.append(["3D", str(_perf(Performance.PHYSICS_3D_ACTIVE_OBJECTS))])
	return _render_table(rows)

func _cmd_phys_sleeping(args: Array, piped_input: String = "") -> String:
	var root := _resolve_root_arg(args)
	if not root:
		return _format_error("Scene root unavailable; is a scene running?")
	var bodies := _collect_bodies(root)
	var sleeping: Array[Node] = []
	for body in bodies:
		if _is_body_sleeping(body):
			sleeping.append(body)
	if sleeping.is_empty():
		return "No sleeping RigidBody2D / RigidBody3D nodes under %s (%d awake)." % [
			_color_path(str(root.get_path())), bodies.size(),
		]
	var rows: Array[Array] = []
	rows.append(["path", "class"])
	for body in sleeping:
		var path_str: String = str(body.get_path()) if body.is_inside_tree() else body.name
		rows.append([path_str, body.get_class()])
	return _color_header("Sleeping bodies (%d / %d)\n" % [sleeping.size(), bodies.size()]) + _render_table(rows)

func _cmd_phys_alarm(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: phys_alarm <metric> <threshold> | phys_alarm list | phys_alarm clear [metric]")

	var sub: String = str(args[0]).strip_edges().to_lower()
	if sub == "list":
		if _alarms.is_empty():
			return "No physics alarms armed. Metrics: %s" % ", ".join(_METRIC_KEYS)
		var rows: Array[Array] = []
		rows.append(["metric", "threshold"])
		for k in _alarms.keys():
			rows.append([str(k), str(_alarms[k])])
		return _color_header("Active phys_alarms\n") + _render_table(rows)
	if sub == "clear":
		if args.size() < 2:
			_alarms.clear()
			_ensure_watcher(false)
			return _format_success("Cleared all physics alarms.")
		var key: String = str(args[1]).strip_edges().to_lower()
		if _alarms.erase(key):
			if _alarms.is_empty():
				_ensure_watcher(false)
			return _format_success("Cleared phys_alarm for %s." % key)
		return _format_error("No alarm armed for metric: %s" % key)

	if args.size() < 2:
		return _format_error("Usage: phys_alarm <metric> <threshold>. Metrics: %s" % ", ".join(_METRIC_KEYS))
	var metric: String = sub
	if not _METRIC_KEYS.has(metric):
		return _format_error("Unknown metric '%s'. Valid: %s" % [metric, ", ".join(_METRIC_KEYS)])
	var raw_threshold: String = str(args[1]).strip_edges()
	if not (raw_threshold.is_valid_int() or raw_threshold.is_valid_float()):
		return _format_error("Threshold must be numeric: %s" % raw_threshold)
	var threshold: float = raw_threshold.to_float()
	_alarms[metric] = threshold
	_ensure_watcher(true)
	return _format_success("Armed phys_alarm: %s > %s" % [metric, _color_number(str(threshold))])

#endregion

#region Watcher / metric plumbing

func _metric_value(metric: String) -> float:
	match metric:
		"active_2d": return _perf(Performance.PHYSICS_2D_ACTIVE_OBJECTS)
		"active_3d": return _perf(Performance.PHYSICS_3D_ACTIVE_OBJECTS)
		"islands_2d": return _perf(Performance.PHYSICS_2D_ISLAND_COUNT)
		"islands_3d": return _perf(Performance.PHYSICS_3D_ISLAND_COUNT)
		"pairs_2d": return _perf(Performance.PHYSICS_2D_COLLISION_PAIRS)
		"pairs_3d": return _perf(Performance.PHYSICS_3D_COLLISION_PAIRS)
		_: return 0.0

func _perf(monitor: int) -> float:
	return float(Performance.get_monitor(monitor))

func _ensure_watcher(should_exist: bool) -> void:
	if should_exist:
		if is_instance_valid(_watcher):
			return
		var tree := Engine.get_main_loop() as SceneTree
		if not tree or not tree.root:
			return
		var t := Timer.new()
		t.name = "_DebugConsolePhysicsAlarmTimer"
		t.wait_time = 0.5
		t.one_shot = false
		t.autostart = true
		t.process_callback = Timer.TIMER_PROCESS_IDLE
		t.timeout.connect(_on_watcher_tick)
		tree.root.add_child(t)
		_watcher = t
	else:
		if is_instance_valid(_watcher):
			_watcher.queue_free()
		_watcher = null

func _on_watcher_tick() -> void:
	for metric in _alarms.keys():
		var threshold: float = float(_alarms[metric])
		var value: float = _metric_value(metric)
		if value > threshold:
			var msg: String = "phys_alarm: %s = %s > %s" % [metric, value, threshold]
			if _core and _core.has_method("print_to_console"):
				_core.print_to_console("[color=%s]%s[/color]" % [_COLOR_WARN, msg], "warning")
			else:
				push_warning(msg)

#endregion

#region Helpers

func _resolve_root_arg(args: Array) -> Node:
	if args.is_empty():
		return _get_scene_root()
	var path: String = " ".join(args).strip_edges()
	if path.is_empty():
		return _get_scene_root()
	return _resolve_node(path)

func _get_scene_root() -> Node:
	if Engine.is_editor_hint():
		return EditorInterface.get_edited_scene_root()
	var tree := Engine.get_main_loop() as SceneTree
	if not tree:
		return null
	if tree.current_scene:
		return tree.current_scene
	return tree.root

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
	if not scene:
		return null
	return scene.get_node_or_null(p)

func _collect_bodies(root: Node) -> Array[Node]:
	var out: Array[Node] = []
	if not root:
		return out
	_walk_bodies(root, out)
	return out

func _walk_bodies(node: Node, out: Array[Node]) -> void:
	if node is RigidBody2D or node is RigidBody3D:
		out.append(node)
	for child in node.get_children():
		_walk_bodies(child, out)

func _is_body_sleeping(body: Node) -> bool:
	if body is RigidBody3D:
		return (body as RigidBody3D).sleeping
	if body is RigidBody2D:
		return (body as RigidBody2D).sleeping
	return false

func _velocity_to_string(body: Node) -> String:
	if body is RigidBody3D:
		var v := (body as RigidBody3D).linear_velocity
		return "(%.2f, %.2f, %.2f)" % [v.x, v.y, v.z]
	if body is RigidBody2D:
		var v2 := (body as RigidBody2D).linear_velocity
		return "(%.2f, %.2f)" % [v2.x, v2.y]
	return "-"

func _render_table(rows: Array) -> String:
	if rows.is_empty():
		return ""
	var col_count: int = 0
	for row in rows:
		col_count = max(col_count, (row as Array).size())
	var widths: Array[int] = []
	widths.resize(col_count)
	for i in col_count:
		widths[i] = 0
	for row in rows:
		var r: Array = row
		for i in r.size():
			var cell: String = str(r[i])
			if cell.length() > widths[i]:
				widths[i] = cell.length()
	var out := ""
	for row_idx in rows.size():
		var r2: Array = rows[row_idx]
		var parts: PackedStringArray = []
		for i in col_count:
			var cell2: String = str(r2[i]) if i < r2.size() else ""
			parts.append(cell2.rpad(widths[i]))
		out += "  ".join(parts) + "\n"
		if row_idx == 0:
			var seps: PackedStringArray = []
			for i in col_count:
				seps.append("-".repeat(widths[i]))
			out += "  ".join(seps) + "\n"
	return out

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

func _color_header(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_HEADER, s]

#endregion

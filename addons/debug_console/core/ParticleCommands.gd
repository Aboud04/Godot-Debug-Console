@tool
class_name DebugConsoleParticleCommands extends RefCounted

# GPUParticles2D / GPUParticles3D spawn + tweak commands. Shipped as
# a separate module so BuiltInCommands.gd stays small. The orchestrator
# instantiates one of these and holds a strong reference so the Callables
# registered below stay valid for the plugin lifetime.
#
# The burst commands create a brand-new particle system, parent it under the
# scene root, fire it as a one-shot, and queue_free the node after the
# lifetime expires via a SceneTree timer. The other commands operate on
# already-existing GPUParticles* nodes resolved by path.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_HEADER := "#7EE787"

const _AMOUNT_MIN: int = 1
const _AMOUNT_MAX: int = 10000

const _BURST_LIFETIME: float = 1.0
const _BURST_DEFAULT_COUNT: int = 50
const _FREE_GRACE_SECS: float = 0.5

var _registry: Node
var _core: Node

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("particles_burst", _cmd_particles_burst, "Spawn one-shot 3D burst: particles_burst <x,y,z> [count] [color] [scale]", "game")
	_registry.register_command("particles_burst2d", _cmd_particles_burst2d, "Spawn one-shot 2D burst: particles_burst2d <x,y> [count] [color] [scale]", "game")
	_registry.register_command("particles_emit", _cmd_particles_emit, "Restart emission on a GPUParticles2D/3D: particles_emit <particles_path>", "both")
	_registry.register_command("particles_stop", _cmd_particles_stop, "Set emitting = false: particles_stop <particles_path>", "both")
	_registry.register_command("particles_resume", _cmd_particles_resume, "Set emitting = true: particles_resume <particles_path>", "both")
	_registry.register_command("particles_amount", _cmd_particles_amount, "Set particle amount (1-10000): particles_amount <particles_path> <n>", "both")
	_registry.register_command("particles_lifetime", _cmd_particles_lifetime, "Set lifetime in seconds: particles_lifetime <particles_path> <secs>", "both")
	_registry.register_command("particles_speed", _cmd_particles_speed, "Set speed_scale multiplier: particles_speed <particles_path> <speed_scale>", "both")
	_registry.register_command("particles_dump", _cmd_particles_dump, "Print all key params: particles_dump <particles_path>", "both")
	_registry.register_command("particles_clear", _cmd_particles_clear, "Remove all GPUParticles2D/3D children: particles_clear [parent_path]", "game")

#region Command implementations

func _cmd_particles_burst(args: Array) -> String:
	if args.is_empty():
		return _format_error("Usage: particles_burst <x,y,z> [count] [color] [scale]")
	var pos: Vector3 = _parse_vec3(str(args[0]))
	var count: int = clampi(int(args[1]) if args.size() > 1 else _BURST_DEFAULT_COUNT, _AMOUNT_MIN, _AMOUNT_MAX)
	var color_str: String = str(args[2]).strip_edges() if args.size() > 2 else ""
	var color: Color = _parse_color(color_str) if not color_str.is_empty() else Color.WHITE
	var scale_val: float = float(args[3]) if args.size() > 3 else 1.0
	if scale_val <= 0.0:
		scale_val = 1.0

	var root: Node = _get_scene_root()
	if not root:
		return _format_error("No scene root available")

	var p: GPUParticles3D = _make_burst_3d(pos, count, color, scale_val)
	root.add_child(p)
	p.restart()
	_defer_free(p, p.lifetime + _FREE_GRACE_SECS)

	var path_str: String = str(p.get_path()) if p.is_inside_tree() else p.name
	return _format_success("Burst spawned at %s with %s particles -> %s" % [
		_color_number(str(pos)),
		_color_number(str(count)),
		_color_path(path_str),
	])

func _cmd_particles_burst2d(args: Array) -> String:
	if args.is_empty():
		return _format_error("Usage: particles_burst2d <x,y> [count] [color] [scale]")
	var pos: Vector2 = _parse_vec2(str(args[0]))
	var count: int = clampi(int(args[1]) if args.size() > 1 else _BURST_DEFAULT_COUNT, _AMOUNT_MIN, _AMOUNT_MAX)
	var color_str: String = str(args[2]).strip_edges() if args.size() > 2 else ""
	var color: Color = _parse_color(color_str) if not color_str.is_empty() else Color.WHITE
	var scale_val: float = float(args[3]) if args.size() > 3 else 1.0
	if scale_val <= 0.0:
		scale_val = 1.0

	var root: Node = _get_scene_root()
	if not root:
		return _format_error("No scene root available")

	var p: GPUParticles2D = _make_burst_2d(pos, count, color, scale_val)
	root.add_child(p)
	p.restart()
	_defer_free(p, p.lifetime + _FREE_GRACE_SECS)

	var path_str: String = str(p.get_path()) if p.is_inside_tree() else p.name
	return _format_success("Burst2D spawned at %s with %s particles -> %s" % [
		_color_number(str(pos)),
		_color_number(str(count)),
		_color_path(path_str),
	])

func _cmd_particles_emit(args: Array) -> String:
	if args.is_empty():
		return _format_error("Usage: particles_emit <particles_path>")
	var n: Node = _resolve_particles(str(args[0]))
	if not n:
		return _format_error("Not a GPUParticles2D/3D node: %s" % str(args[0]))
	n.call("restart")
	return _format_success("Restarted %s" % _color_path(_path_of(n)))

func _cmd_particles_stop(args: Array) -> String:
	if args.is_empty():
		return _format_error("Usage: particles_stop <particles_path>")
	var n: Node = _resolve_particles(str(args[0]))
	if not n:
		return _format_error("Not a GPUParticles2D/3D node: %s" % str(args[0]))
	n.set("emitting", false)
	return _format_success("Stopped %s" % _color_path(_path_of(n)))

func _cmd_particles_resume(args: Array) -> String:
	if args.is_empty():
		return _format_error("Usage: particles_resume <particles_path>")
	var n: Node = _resolve_particles(str(args[0]))
	if not n:
		return _format_error("Not a GPUParticles2D/3D node: %s" % str(args[0]))
	n.set("emitting", true)
	return _format_success("Resumed %s" % _color_path(_path_of(n)))

func _cmd_particles_amount(args: Array) -> String:
	if args.size() < 2:
		return _format_error("Usage: particles_amount <particles_path> <n>")
	var n: Node = _resolve_particles(str(args[0]))
	if not n:
		return _format_error("Not a GPUParticles2D/3D node: %s" % str(args[0]))
	var requested: int = int(args[1])
	var clamped: int = clampi(requested, _AMOUNT_MIN, _AMOUNT_MAX)
	n.set("amount", clamped)
	var suffix: String = "" if clamped == requested else " (clamped from %d)" % requested
	return _format_success("amount = %s%s on %s" % [_color_number(str(clamped)), suffix, _color_path(_path_of(n))])

func _cmd_particles_lifetime(args: Array) -> String:
	if args.size() < 2:
		return _format_error("Usage: particles_lifetime <particles_path> <secs>")
	var n: Node = _resolve_particles(str(args[0]))
	if not n:
		return _format_error("Not a GPUParticles2D/3D node: %s" % str(args[0]))
	var secs: float = float(args[1])
	if secs <= 0.0:
		return _format_error("lifetime must be > 0")
	n.set("lifetime", secs)
	return _format_success("lifetime = %s s on %s" % [_color_number(str(secs)), _color_path(_path_of(n))])

func _cmd_particles_speed(args: Array) -> String:
	if args.size() < 2:
		return _format_error("Usage: particles_speed <particles_path> <speed_scale>")
	var n: Node = _resolve_particles(str(args[0]))
	if not n:
		return _format_error("Not a GPUParticles2D/3D node: %s" % str(args[0]))
	var s: float = float(args[1])
	n.set("speed_scale", s)
	return _format_success("speed_scale = %s on %s" % [_color_number(str(s)), _color_path(_path_of(n))])

func _cmd_particles_dump(args: Array) -> String:
	if args.is_empty():
		return _format_error("Usage: particles_dump <particles_path>")
	var n: Node = _resolve_particles(str(args[0]))
	if not n:
		return _format_error("Not a GPUParticles2D/3D node: %s" % str(args[0]))
	var lines: Array[String] = []
	lines.append("%s %s" % [_format_header("Particles"), _color_path(_path_of(n))])
	lines.append("  class:        %s" % n.get_class())
	lines.append("  amount:       %s" % _color_number(str(n.get("amount"))))
	lines.append("  lifetime:     %s" % _color_number(str(n.get("lifetime"))))
	lines.append("  speed_scale:  %s" % _color_number(str(n.get("speed_scale"))))
	lines.append("  emitting:     %s" % str(n.get("emitting")))
	lines.append("  one_shot:     %s" % str(n.get("one_shot")))
	lines.append("  fixed_fps:    %s" % _color_number(str(n.get("fixed_fps"))))
	return "\n".join(lines)

func _cmd_particles_clear(args: Array) -> String:
	var parent_path: String = str(args[0]).strip_edges() if args.size() > 0 else ""
	var parent: Node = _resolve_node(parent_path) if not parent_path.is_empty() else _get_scene_root()
	if not parent:
		return _format_error("Parent not found: %s" % parent_path)
	var removed: int = 0
	for child in parent.get_children():
		if child is GPUParticles2D or child is GPUParticles3D:
			child.queue_free()
			removed += 1
	return _format_success("Removed %s particle system(s) from %s" % [
		_color_number(str(removed)),
		_color_path(_path_of(parent)),
	])

#endregion

#region Builders

# Builds a one-shot upward-spray 3D burst using ParticleProcessMaterial and a
# billboarded QuadMesh whose albedo carries the user-supplied color. The mesh
# size scales with `scale_val` so a single knob controls visible burst size.
func _make_burst_3d(pos: Vector3, count: int, color: Color, scale_val: float) -> GPUParticles3D:
	var p: GPUParticles3D = GPUParticles3D.new()
	p.name = "DC_Burst3D_%d" % Time.get_ticks_msec()
	p.position = pos
	p.amount = max(_AMOUNT_MIN, count)
	p.lifetime = _BURST_LIFETIME
	p.one_shot = true
	p.explosiveness = 1.0

	var pm: ParticleProcessMaterial = ParticleProcessMaterial.new()
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 180.0
	pm.initial_velocity_min = 5.0
	pm.initial_velocity_max = 10.0
	pm.gravity = Vector3(0, -9.8, 0)
	pm.color = color
	p.process_material = pm

	var mesh: QuadMesh = QuadMesh.new()
	var quad_size: float = 0.1 * scale_val
	mesh.size = Vector2(quad_size, quad_size)

	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mesh.material = mat

	p.draw_pass_1 = mesh
	return p

# Builds a one-shot downward-spray 2D burst. Particles use a small white
# ImageTexture so they remain visible without requiring an external asset;
# the user-supplied color is applied via modulate.
func _make_burst_2d(pos: Vector2, count: int, color: Color, scale_val: float) -> GPUParticles2D:
	var p: GPUParticles2D = GPUParticles2D.new()
	p.name = "DC_Burst2D_%d" % Time.get_ticks_msec()
	p.position = pos
	p.amount = max(_AMOUNT_MIN, count)
	p.lifetime = _BURST_LIFETIME
	p.one_shot = true
	p.explosiveness = 1.0

	var pm: ParticleProcessMaterial = ParticleProcessMaterial.new()
	pm.direction = Vector3(0, -1, 0)
	pm.spread = 180.0
	pm.initial_velocity_min = 80.0
	pm.initial_velocity_max = 180.0
	pm.gravity = Vector3(0, 400, 0)
	pm.color = Color.WHITE
	p.process_material = pm

	var px: int = int(max(2.0, 8.0 * scale_val))
	var img: Image = Image.create(px, px, false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	p.texture = ImageTexture.create_from_image(img)
	p.modulate = color
	return p

#endregion

#region Helpers

func _resolve_particles(path: String) -> Node:
	var n: Node = _resolve_node(path)
	if not n:
		return null
	if n is GPUParticles2D or n is GPUParticles3D:
		return n
	return null

func _resolve_node(path: String) -> Node:
	var p: String = path.strip_edges()
	if p.is_empty():
		return null
	if Engine.is_editor_hint():
		var root: Node = _get_scene_root()
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

func _get_scene_root() -> Node:
	if Engine.is_editor_hint():
		return EditorInterface.get_edited_scene_root()
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if not tree:
		return null
	if tree.current_scene:
		return tree.current_scene
	return tree.root

# Schedules queue_free after `secs` using the spawned node's own SceneTree.
# The lambda checks is_instance_valid so manual deletion before the timeout
# does not double-free.
func _defer_free(node: Node, secs: float) -> void:
	if not is_instance_valid(node):
		return
	var tree: SceneTree = node.get_tree()
	if not tree:
		return
	var timer: SceneTreeTimer = tree.create_timer(secs)
	timer.timeout.connect(func() -> void:
		if is_instance_valid(node):
			node.queue_free()
	)

func _path_of(n: Node) -> String:
	if not is_instance_valid(n):
		return "<invalid>"
	return str(n.get_path()) if n.is_inside_tree() else n.name

func _parse_vec3(s: String) -> Vector3:
	var parts: PackedStringArray = s.strip_edges().split(",")
	if parts.size() < 3:
		return Vector3.ZERO
	return Vector3(parts[0].to_float(), parts[1].to_float(), parts[2].to_float())

func _parse_vec2(s: String) -> Vector2:
	var parts: PackedStringArray = s.strip_edges().split(",")
	if parts.size() < 2:
		return Vector2.ZERO
	return Vector2(parts[0].to_float(), parts[1].to_float())

# Parses "#RRGGBB", "#RRGGBBAA", or "#AARRGGBB" (Godot's to_html() default).
# Falls back to white on malformed input rather than throwing so a typo in a
# console command never aborts the burst.
func _parse_color(s: String) -> Color:
	var trimmed: String = s.strip_edges()
	if trimmed.is_empty():
		return Color.WHITE
	if not trimmed.begins_with("#"):
		trimmed = "#" + trimmed
	if trimmed.length() == 9:
		var aa: String = trimmed.substr(1, 2)
		var rr: String = trimmed.substr(3, 2)
		var gg: String = trimmed.substr(5, 2)
		var bb: String = trimmed.substr(7, 2)
		var reordered: String = "#" + rr + gg + bb + aa
		return Color.html(reordered) if Color.html_is_valid(reordered) else Color.WHITE
	if Color.html_is_valid(trimmed):
		return Color.html(trimmed)
	return Color.WHITE

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _format_header(text: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_HEADER, text]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

#endregion

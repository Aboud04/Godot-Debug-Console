@tool
class_name DebugConsoleCameraCommands extends RefCounted

# Live camera control commands. Mirrors the same module shape as
# SceneCommands / UICommands / RuntimeCommands: the orchestrator
# (BuiltInCommands.register_universal_commands) instantiates one of these,
# keeps a strong reference, and calls register_commands(registry, core).
# Strong reference matters because the Callables we hand the registry are
# bound methods on this instance; the instance must outlive them.
#
# 2D vs 3D handling: cam_list, cam_make_current, cam_pos, cam_zoom auto-detect
# the camera type. cam_look_at and cam_fov are 3D-only and return a clear
# error against a Camera2D. The shake/follow/screen_to_world commands need a
# live SceneTree (Tween + _process), so they are registered as "game" context.
#
# cam_follow strategy: we add a small "DebugConsoleCameraFollower" Node child
# under the current SceneTree's root that runs the per-frame lerp in
# _process(delta). This avoids monkeypatching the camera itself, survives
# scene reloads gracefully (the follower frees itself when its targets go
# invalid), and is trivially torn down by cam_unfollow. We keep at most one
# follower node at a time; calling cam_follow again replaces the previous
# target.
#
# cam_shake strategy: a Tween is created against the current SceneTree and
# the live Tween reference is parked in _active_shakes keyed by the camera's
# absolute node path. Without that strong reference Tween would be eligible
# for GC mid-animation. We finish_callback off the entry when the tween
# completes so the dictionary does not leak entries over a long session.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"

const _FOLLOWER_NODE_NAME := "DebugConsoleCameraFollower"

var _registry: Node
var _core: Node

# Camera path (String) -> Tween. Kept so running shakes are not GC'd mid-run.
var _active_shakes: Dictionary = {}

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("cam_list", _cmd_cam_list, "List all Camera2D and Camera3D nodes in the scene with current flag", "both")
	_registry.register_command("cam_make_current", _cmd_cam_make_current, "Make a camera current: cam_make_current <camera_path>", "both")
	_registry.register_command("cam_pos", _cmd_cam_pos, "Report or set current camera's global_position: cam_pos [x,y(,z)]", "both")
	_registry.register_command("cam_look_at", _cmd_cam_look_at, "Camera3D look_at target: cam_look_at <x,y,z>", "both")
	_registry.register_command("cam_zoom", _cmd_cam_zoom, "Set zoom on current camera (2D zoom factor, 3D inverse fov): cam_zoom <factor>", "both")
	_registry.register_command("cam_fov", _cmd_cam_fov, "Set Camera3D fov in degrees: cam_fov <degrees>", "both")
	_registry.register_command("cam_shake", _cmd_cam_shake, "Shake current camera: cam_shake <intensity> <duration> [frequency=30]", "game")
	_registry.register_command("cam_follow", _cmd_cam_follow, "Follow a target with the current camera: cam_follow <target_path> [smoothing=0.1]", "game")
	_registry.register_command("cam_unfollow", _cmd_cam_unfollow, "Stop the active cam_follow follower", "game")
	_registry.register_command("cam_screen_to_world", _cmd_cam_screen_to_world, "Project screen coords to a 3D ray from the current camera: cam_screen_to_world <x,y>", "game")

#region commands

func _cmd_cam_list(args: Array, piped_input: String = "") -> String:
	var root: Node = _get_scene_root()
	if not root:
		return _format_error("No scene available")
	var cameras: Array[Node] = []
	_collect_cameras(root, cameras)
	if cameras.is_empty():
		return "No Camera2D or Camera3D nodes found under %s" % _color_path(_node_label(root))

	var current_2d: Camera2D = null
	var current_3d: Camera3D = null
	var vp: Viewport = _get_viewport()
	if vp:
		current_2d = vp.get_camera_2d()
		current_3d = vp.get_camera_3d()

	var lines: Array[String] = []
	lines.append("%d camera(s):" % cameras.size())
	for cam in cameras:
		var is_current: bool = (cam == current_2d) or (cam == current_3d)
		var marker: String = "*" if is_current else " "
		var kind: String = "Camera3D" if cam is Camera3D else "Camera2D"
		lines.append("  %s [%s] %s" % [marker, kind, _color_path(_node_label(cam))])
	return "\n".join(lines)

func _cmd_cam_make_current(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: cam_make_current <camera_path>")
	var path: String = str(args[0]).strip_edges()
	var cam: Node = _resolve_camera(path)
	if not cam:
		return _format_error("Not a Camera2D or Camera3D: %s" % path)
	cam.call("make_current")
	return _format_success("Made current: %s" % _color_path(_node_label(cam)))

func _cmd_cam_pos(args: Array, piped_input: String = "") -> String:
	var cam: Node = _get_current_camera()
	if not cam:
		return _format_error("No current camera found")

	if args.is_empty():
		# Report mode.
		if cam is Camera3D:
			var p3: Vector3 = (cam as Camera3D).global_position
			return "%s @ %s" % [_color_path(_node_label(cam)), _color_number("(%s, %s, %s)" % [p3.x, p3.y, p3.z])]
		var p2: Vector2 = (cam as Camera2D).global_position
		return "%s @ %s" % [_color_path(_node_label(cam)), _color_number("(%s, %s)" % [p2.x, p2.y])]

	# Set mode.
	var raw: String = str(args[0]).strip_edges()
	if cam is Camera3D:
		var v3: Vector3 = _parse_vec3(raw)
		if v3 == Vector3.INF:
			return _format_error("Expected 3 comma-separated numbers, got: %s" % raw)
		(cam as Camera3D).global_position = v3
		return _format_success("Set %s.global_position = %s" % [_color_path(_node_label(cam)), _color_number(str(v3))])

	var v2: Vector2 = _parse_vec2(raw)
	if v2 == Vector2.INF:
		return _format_error("Expected 2 comma-separated numbers, got: %s" % raw)
	(cam as Camera2D).global_position = v2
	return _format_success("Set %s.global_position = %s" % [_color_path(_node_label(cam)), _color_number(str(v2))])

func _cmd_cam_look_at(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: cam_look_at <x,y,z>")
	var cam: Node = _get_current_camera()
	if not cam:
		return _format_error("No current camera found")
	if not (cam is Camera3D):
		return _format_error("cam_look_at requires a Camera3D (current is Camera2D)")

	var raw: String = str(args[0]).strip_edges()
	var target: Vector3 = _parse_vec3(raw)
	if target == Vector3.INF:
		return _format_error("Expected 3 comma-separated numbers, got: %s" % raw)
	# Refuse to look at our own position, which would produce an undefined basis.
	var cam3: Camera3D = cam as Camera3D
	if cam3.global_position.is_equal_approx(target):
		return _format_error("Target equals camera position; look_at would be undefined")
	cam3.look_at(target)
	return _format_success("%s looking at %s" % [_color_path(_node_label(cam)), _color_number(str(target))])

func _cmd_cam_zoom(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: cam_zoom <factor>")
	var cam: Node = _get_current_camera()
	if not cam:
		return _format_error("No current camera found")

	var raw: String = str(args[0]).strip_edges()
	if not (raw.is_valid_float() or raw.is_valid_int()):
		return _format_error("Zoom factor must be a number: %s" % raw)
	var factor: float = raw.to_float()
	if factor <= 0.0:
		return _format_error("Zoom factor must be > 0")

	if cam is Camera2D:
		(cam as Camera2D).zoom = factor * Vector2.ONE
		return _format_success("Set %s.zoom = %s" % [_color_path(_node_label(cam)), _color_number(str(factor))])

	# Camera3D: invert factor so factor > 1 zooms IN (lower fov). Anchor at the
	# default fov of 75 degrees rather than the current fov so repeated calls
	# do not compound and drift.
	var cam3: Camera3D = cam as Camera3D
	var new_fov: float = clamp(75.0 / factor, 1.0, 179.0)
	cam3.fov = new_fov
	return _format_success("Set %s.fov = %s (zoom %sx)" % [_color_path(_node_label(cam)), _color_number(str(new_fov)), _color_number(str(factor))])

func _cmd_cam_fov(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: cam_fov <degrees>")
	var cam: Node = _get_current_camera()
	if not cam:
		return _format_error("No current camera found")
	if not (cam is Camera3D):
		return _format_error("cam_fov requires a Camera3D (current is Camera2D)")

	var raw: String = str(args[0]).strip_edges()
	if not (raw.is_valid_float() or raw.is_valid_int()):
		return _format_error("FOV must be a number: %s" % raw)
	var degrees: float = raw.to_float()
	if degrees < 1.0 or degrees > 179.0:
		return _format_error("FOV must be in [1, 179] degrees")
	(cam as Camera3D).fov = degrees
	return _format_success("Set %s.fov = %s" % [_color_path(_node_label(cam)), _color_number(str(degrees))])

func _cmd_cam_shake(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: cam_shake <intensity> <duration> [frequency=30]")
	var cam: Node = _get_current_camera()
	if not cam:
		return _format_error("No current camera found")

	var intensity: float = str(args[0]).to_float()
	var duration: float = str(args[1]).to_float()
	var frequency: float = str(args[2]).to_float() if args.size() > 2 else 30.0
	if intensity <= 0.0:
		return _format_error("Intensity must be > 0")
	if duration <= 0.0:
		return _format_error("Duration must be > 0")
	if frequency <= 0.0:
		return _format_error("Frequency must be > 0")

	var tree: SceneTree = cam.get_tree() if cam.is_inside_tree() else (Engine.get_main_loop() as SceneTree)
	if not tree:
		return _format_error("No SceneTree available")

	# Snapshot the starting position so we always return there at the end and
	# noise samples are offsets from a stable anchor.
	var is_3d: bool = cam is Camera3D
	var anchor_3d: Vector3 = (cam as Camera3D).position if is_3d else Vector3.ZERO
	var anchor_2d: Vector2 = (cam as Camera2D).position if not is_3d else Vector2.ZERO
	var key: String = _node_label(cam)

	# If a shake is already running on this camera, kill it so the new one
	# starts from a clean state instead of compounding.
	if _active_shakes.has(key):
		var prev: Tween = _active_shakes[key]
		if is_instance_valid(prev) and prev.is_valid():
			prev.kill()
		_active_shakes.erase(key)

	var tween: Tween = tree.create_tween()
	if not tween:
		return _format_error("Failed to create Tween")
	_active_shakes[key] = tween

	# Build the shake as a sequence of small offset jumps at the requested
	# frequency. Each step decays linearly so the shake "rings out" by the
	# end of the duration. method_callable() runs without a separate tween,
	# so we use tween_callback to set the position at each beat.
	var step_count: int = max(int(round(duration * frequency)), 1)
	var step_time: float = duration / float(step_count)
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	for i in range(step_count):
		var t_norm: float = float(i) / float(step_count)
		var decay: float = 1.0 - t_norm
		if is_3d:
			var off3: Vector3 = Vector3(
				rng.randf_range(-1.0, 1.0),
				rng.randf_range(-1.0, 1.0),
				rng.randf_range(-1.0, 1.0),
			) * intensity * decay
			tween.tween_property(cam, "position", anchor_3d + off3, step_time)
		else:
			var off2: Vector2 = Vector2(
				rng.randf_range(-1.0, 1.0),
				rng.randf_range(-1.0, 1.0),
			) * intensity * decay
			tween.tween_property(cam, "position", anchor_2d + off2, step_time)
	# Snap back to the anchor on the final beat so the camera never gets
	# stuck off-center.
	if is_3d:
		tween.tween_property(cam, "position", anchor_3d, step_time)
	else:
		tween.tween_property(cam, "position", anchor_2d, step_time)

	tween.finished.connect(_on_shake_finished.bind(key))
	return _format_success("Shaking %s: intensity=%s, duration=%ss, freq=%sHz" % [
		_color_path(key), _color_number(str(intensity)), _color_number(str(duration)), _color_number(str(frequency)),
	])

func _cmd_cam_follow(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: cam_follow <target_path> [smoothing=0.1]")
	var cam: Node = _get_current_camera()
	if not cam:
		return _format_error("No current camera found")

	var target_path: String = str(args[0]).strip_edges()
	var target: Node = _resolve_node(target_path)
	if not target:
		return _format_error("Target not found: %s" % target_path)

	var smoothing: float = 0.1
	if args.size() > 1:
		var raw_s: String = str(args[1]).strip_edges()
		if not (raw_s.is_valid_float() or raw_s.is_valid_int()):
			return _format_error("Smoothing must be a number in [0,1]: %s" % raw_s)
		smoothing = clamp(raw_s.to_float(), 0.0, 1.0)

	var tree: SceneTree = cam.get_tree() if cam.is_inside_tree() else (Engine.get_main_loop() as SceneTree)
	if not tree:
		return _format_error("No SceneTree available")

	# Tear down any previous follower so we never have two competing for the
	# same camera. The follower is parented at /root so it survives a current
	# scene swap until the user explicitly stops it (or until the camera or
	# target it points at go invalid, in which case it frees itself).
	_remove_existing_follower(tree)

	var follower: Node = Node.new()
	follower.name = _FOLLOWER_NODE_NAME
	follower.set_script(_make_follower_script())
	tree.root.add_child(follower)
	follower.set("camera", cam)
	follower.set("target", target)
	follower.set("smoothing", smoothing)

	return _format_success("Following %s with %s (smoothing=%s)" % [
		_color_path(_node_label(target)), _color_path(_node_label(cam)), _color_number(str(smoothing)),
	])

func _cmd_cam_unfollow(args: Array, piped_input: String = "") -> String:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if not tree:
		return _format_error("No SceneTree available")
	var existed: bool = _remove_existing_follower(tree)
	if not existed:
		return "No active cam_follow follower"
	return _format_success("cam_follow stopped")

func _cmd_cam_screen_to_world(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: cam_screen_to_world <x,y>")
	var cam: Node = _get_current_camera()
	if not cam:
		return _format_error("No current camera found")
	if not (cam is Camera3D):
		return _format_error("cam_screen_to_world requires a Camera3D (current is Camera2D)")

	var raw: String = str(args[0]).strip_edges()
	var screen: Vector2 = _parse_vec2(raw)
	if screen == Vector2.INF:
		return _format_error("Expected 2 comma-separated numbers, got: %s" % raw)

	var cam3: Camera3D = cam as Camera3D
	var origin: Vector3 = cam3.project_ray_origin(screen)
	var normal: Vector3 = cam3.project_ray_normal(screen)
	return "Ray from %s:\n  origin: %s\n  normal: %s" % [
		_color_path(_node_label(cam)),
		_color_number("(%s, %s, %s)" % [origin.x, origin.y, origin.z]),
		_color_number("(%s, %s, %s)" % [normal.x, normal.y, normal.z]),
	]

#endregion

#region helpers

func _on_shake_finished(key: String) -> void:
	if _active_shakes.has(key):
		_active_shakes.erase(key)

func _make_follower_script() -> GDScript:
	# Built inline so this module stays single-file. The follower lerps the
	# camera toward the target every frame; smoothing of 1.0 snaps instantly,
	# 0.0 never moves. We bail and free ourselves the moment either side
	# becomes invalid, which avoids dangling references after scene reloads.
	var src: String = """
extends Node

var camera: Node = null
var target: Node = null
var smoothing: float = 0.1

func _process(_delta: float) -> void:
	if not is_instance_valid(camera) or not is_instance_valid(target):
		queue_free()
		return
	if camera is Camera3D and target is Node3D:
		var cp3: Vector3 = (camera as Camera3D).global_position
		var tp3: Vector3 = (target as Node3D).global_position
		(camera as Camera3D).global_position = cp3.lerp(tp3, smoothing)
	elif camera is Camera2D and target is Node2D:
		var cp2: Vector2 = (camera as Camera2D).global_position
		var tp2: Vector2 = (target as Node2D).global_position
		(camera as Camera2D).global_position = cp2.lerp(tp2, smoothing)
	else:
		queue_free()
"""
	var script := GDScript.new()
	script.source_code = src
	script.reload()
	return script

func _remove_existing_follower(tree: SceneTree) -> bool:
	if not tree or not tree.root:
		return false
	var existing: Node = tree.root.get_node_or_null(_FOLLOWER_NODE_NAME)
	if existing:
		existing.queue_free()
		return true
	return false

func _get_viewport() -> Viewport:
	if Engine.is_editor_hint():
		# Editor camera lookup uses the edited scene's viewport when running,
		# which only exists for the live tree. Outside of play mode there is
		# no "current" camera; we return null and let callers report cleanly.
		var root: Node = _get_scene_root()
		if root and root.is_inside_tree():
			return root.get_viewport()
		return null
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if not tree:
		return null
	return tree.root.get_viewport()

func _get_current_camera() -> Node:
	var vp: Viewport = _get_viewport()
	if not vp:
		return null
	var cam2: Camera2D = vp.get_camera_2d()
	if cam2:
		return cam2
	var cam3: Camera3D = vp.get_camera_3d()
	if cam3:
		return cam3
	return null

func _resolve_camera(path: String) -> Node:
	var n: Node = _resolve_node(path)
	if not n:
		return null
	if n is Camera2D or n is Camera3D:
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

func _collect_cameras(node: Node, out: Array[Node]) -> void:
	if node is Camera2D or node is Camera3D:
		out.append(node)
	for child in node.get_children():
		_collect_cameras(child, out)

func _node_label(n: Node) -> String:
	if n and n.is_inside_tree():
		return str(n.get_path())
	return n.name if n else "<null>"

func _parse_vec3(raw: String) -> Vector3:
	var parts: PackedStringArray = raw.split(",")
	if parts.size() != 3:
		return Vector3.INF
	var nums: Array[float] = []
	for p in parts:
		var t: String = p.strip_edges()
		if not (t.is_valid_float() or t.is_valid_int()):
			return Vector3.INF
		nums.append(t.to_float())
	return Vector3(nums[0], nums[1], nums[2])

func _parse_vec2(raw: String) -> Vector2:
	var parts: PackedStringArray = raw.split(",")
	if parts.size() != 2:
		return Vector2.INF
	var nums: Array[float] = []
	for p in parts:
		var t: String = p.strip_edges()
		if not (t.is_valid_float() or t.is_valid_int()):
			return Vector2.INF
		nums.append(t.to_float())
	return Vector2(nums[0], nums[1])

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

#endregion

@tool
class_name DebugConsoleShaderCommands extends RefCounted

# Live shader/material tweaking commands. This module ships separately
# from BuiltInCommands.gd to keep that file under control as the command surface
# grows. The orchestrator (BuiltInCommands.register_universal_commands)
# instantiates one of these, holds a strong reference, and calls
# register_commands(registry, core). The strong reference is what keeps the
# Callables here valid for the lifetime of the plugin.
#
# Two flavours of command live here:
#   * shader_*  operate directly on a node's currently-applied ShaderMaterial.
#   * mat_*     manage a side table of fabricated materials (StandardMaterial3D,
#               CanvasItemMaterial, ShaderMaterial) so users can build a
#               material once and apply it to many nodes. Stored material
#               resources are held in _materials by string id so RefCounted
#               does not free them between commands.
#
# Both flavours work in editor and runtime; node resolution is delegated to
# _resolve_node which branches on Engine.is_editor_hint() exactly like the
# other modules.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_ID := "#C9A0FF"

var _registry: Node
var _core: Node

# Side table of materials created via mat_new. Keys are "mat_<n>" strings,
# values are the actual Material resources. Holding the reference here keeps
# them alive across commands; if they were stack-local they would be freed
# the moment mat_new returned.
var _materials: Dictionary = {}
var _next_id: int = 1

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	# All shader/material commands work in both editor and runtime; the editor
	# variant edits the open scene's tree, the runtime variant mutates the live
	# tree. _resolve_node hides that distinction.
	_registry.register_command("shader_load", _cmd_shader_load, "Load a Shader resource and apply as ShaderMaterial: shader_load <node_path> <res://shader.gdshader>", "both")
	_registry.register_command("shader_set", _cmd_shader_set, "Set a shader uniform: shader_set <node_path> <uniform> <value>", "both")
	_registry.register_command("shader_get", _cmd_shader_get, "Read a shader uniform: shader_get <node_path> <uniform>", "both")
	_registry.register_command("shader_dump", _cmd_shader_dump, "List all uniforms with types and current values: shader_dump <node_path>", "both")
	_registry.register_command("shader_clear", _cmd_shader_clear, "Remove the ShaderMaterial from a node: shader_clear <node_path>", "both")
	_registry.register_command("mat_new", _cmd_mat_new, "Create a material resource: mat_new <standard3d|standard2d|shader> [param=value ...]", "both")
	_registry.register_command("mat_apply", _cmd_mat_apply, "Apply a stored material to a node: mat_apply <mat_id> <node_path>", "both")
	_registry.register_command("mat_set", _cmd_mat_set, "Set a property on a stored material: mat_set <mat_id> <property> <value>", "both")
	_registry.register_command("mat_list", _cmd_mat_list, "List stored materials by id and type: mat_list", "both")
	_registry.register_command("mat_drop", _cmd_mat_drop, "Drop a stored material (or all): mat_drop <mat_id|all>", "both")

#region Command implementations

func _cmd_shader_load(args: Array, _piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: shader_load <node_path> <res://shader.gdshader>")
	var node_path: String = str(args[0]).strip_edges()
	var shader_path: String = str(args[1]).strip_edges()

	var node: Node = _resolve_node(node_path)
	if not node:
		return _format_error("Node not found: %s" % node_path)
	var visual: Node = _resolve_visual(node)
	if not visual:
		return _format_error("Node is not a CanvasItem or GeometryInstance3D: %s" % node_path)

	if not ResourceLoader.exists(shader_path):
		return _format_error("Shader not found: %s" % shader_path)
	var shader: Shader = load(shader_path) as Shader
	if not shader:
		return _format_error("Not a Shader resource: %s" % shader_path)

	var mat: ShaderMaterial = ShaderMaterial.new()
	mat.shader = shader
	_assign_material(visual, mat)

	# Reading line count gives the user a quick sanity check that the file
	# actually loaded its source rather than coming back empty.
	var line_count: int = shader.code.count("\n") + (1 if not shader.code.is_empty() else 0)
	return _format_success("Loaded %s on %s (%s lines)" % [_color_path(shader_path), _color_path(node_path), _color_number(str(line_count))])

func _cmd_shader_set(args: Array, _piped_input: String = "") -> String:
	if args.size() < 3:
		return _format_error("Usage: shader_set <node_path> <uniform> <value>")
	var node_path: String = str(args[0]).strip_edges()
	var uniform: String = str(args[1]).strip_edges()
	# Join remaining tokens so values containing whitespace inside quotes still
	# round-trip through the CommandRegistry tokenizer.
	var value_str: String = ""
	for i in range(2, args.size()):
		if i > 2:
			value_str += " "
		value_str += str(args[i])
	value_str = value_str.strip_edges()

	var node: Node = _resolve_node(node_path)
	if not node:
		return _format_error("Node not found: %s" % node_path)
	var mat: ShaderMaterial = _get_shader_material(node)
	if not mat:
		return _format_error("Node has no ShaderMaterial: %s" % node_path)
	if not _has_uniform(mat, uniform):
		return _format_error("Shader has no uniform '%s'" % uniform)

	var parsed: Variant = _parse_shader_value(value_str)
	mat.set_shader_parameter(uniform, parsed)
	return _format_success("Set %s.%s = %s" % [_color_path(node_path), uniform, _color_number(str(parsed))])

func _cmd_shader_get(args: Array, _piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: shader_get <node_path> <uniform>")
	var node_path: String = str(args[0]).strip_edges()
	var uniform: String = str(args[1]).strip_edges()

	var node: Node = _resolve_node(node_path)
	if not node:
		return _format_error("Node not found: %s" % node_path)
	var mat: ShaderMaterial = _get_shader_material(node)
	if not mat:
		return _format_error("Node has no ShaderMaterial: %s" % node_path)
	if not _has_uniform(mat, uniform):
		return _format_error("Shader has no uniform '%s'" % uniform)

	var value: Variant = mat.get_shader_parameter(uniform)
	var label: String = "<default>" if value == null else str(value)
	return "%s.%s = %s" % [_color_path(node_path), uniform, _color_number(label)]

func _cmd_shader_dump(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: shader_dump <node_path>")
	var node_path: String = str(args[0]).strip_edges()

	var node: Node = _resolve_node(node_path)
	if not node:
		return _format_error("Node not found: %s" % node_path)
	var mat: ShaderMaterial = _get_shader_material(node)
	if not mat:
		return _format_error("Node has no ShaderMaterial: %s" % node_path)
	if not mat.shader:
		return _format_error("ShaderMaterial has no shader assigned")

	var uniforms: Array = mat.shader.get_shader_uniform_list()
	if uniforms.is_empty():
		return "ShaderMaterial on %s exposes no uniforms" % _color_path(node_path)

	var lines: PackedStringArray = []
	lines.append("Uniforms on %s:" % _color_path(node_path))
	for u in uniforms:
		var uname: String = str(u.get("name", "?"))
		var utype: String = _type_name(int(u.get("type", TYPE_NIL)))
		var current: Variant = mat.get_shader_parameter(uname)
		var current_str: String = "<default>" if current == null else str(current)
		lines.append("  %s : %s = %s" % [uname, utype, _color_number(current_str)])
	return "\n".join(lines)

func _cmd_shader_clear(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: shader_clear <node_path>")
	var node_path: String = str(args[0]).strip_edges()

	var node: Node = _resolve_node(node_path)
	if not node:
		return _format_error("Node not found: %s" % node_path)
	var visual: Node = _resolve_visual(node)
	if not visual:
		return _format_error("Node is not a CanvasItem or GeometryInstance3D: %s" % node_path)

	_assign_material(visual, null)
	return _format_success("Cleared material on %s" % _color_path(node_path))

func _cmd_mat_new(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: mat_new <standard3d|standard2d|shader> [param=value ...]")
	var type_name: String = str(args[0]).strip_edges().to_lower()
	var kv: Dictionary = _parse_kv_args(args.slice(1))

	var mat: Material = null
	match type_name:
		"standard3d":
			mat = StandardMaterial3D.new()
		"standard2d":
			mat = CanvasItemMaterial.new()
		"shader":
			var shader_path: String = str(kv.get("shader", "")).strip_edges()
			if shader_path.is_empty():
				return _format_error("mat_new shader requires shader=<res://...> param")
			if not ResourceLoader.exists(shader_path):
				return _format_error("Shader not found: %s" % shader_path)
			var shader: Shader = load(shader_path) as Shader
			if not shader:
				return _format_error("Not a Shader resource: %s" % shader_path)
			var sm: ShaderMaterial = ShaderMaterial.new()
			sm.shader = shader
			mat = sm
			kv.erase("shader")
		_:
			return _format_error("Unknown material type: %s (expected standard3d, standard2d, or shader)" % type_name)

	# Apply any inline property=value pairs the user passed in; silently skip
	# ones that do not match a real property so a typo does not lose the whole
	# material.
	for k in kv.keys():
		var prop: String = str(k)
		var raw: String = str(kv[k])
		var parsed: Variant = _parse_shader_value(raw)
		if prop in mat:
			mat.set(prop, parsed)

	var mat_id: String = _next_mat_id()
	_materials[mat_id] = mat
	return _format_success("Created %s as %s" % [_color_id(mat_id), mat.get_class()])

func _cmd_mat_apply(args: Array, _piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: mat_apply <mat_id> <node_path>")
	var mat_id: String = str(args[0]).strip_edges()
	var node_path: String = str(args[1]).strip_edges()

	if not _materials.has(mat_id):
		return _format_error("Unknown material id: %s" % mat_id)
	var mat: Material = _materials[mat_id] as Material
	if not mat:
		return _format_error("Material slot %s is empty" % mat_id)

	var node: Node = _resolve_node(node_path)
	if not node:
		return _format_error("Node not found: %s" % node_path)
	var visual: Node = _resolve_visual(node)
	if not visual:
		return _format_error("Node is not a CanvasItem or GeometryInstance3D: %s" % node_path)

	# Cross-check: CanvasItemMaterial only makes sense on CanvasItem; a
	# StandardMaterial3D only makes sense on GeometryInstance3D. ShaderMaterial
	# works on either. Reject the obviously-wrong combinations so the user does
	# not get a silent visual no-op.
	if mat is CanvasItemMaterial and not (visual is CanvasItem):
		return _format_error("CanvasItemMaterial cannot apply to a 3D node")
	if mat is BaseMaterial3D and not (visual is GeometryInstance3D):
		return _format_error("StandardMaterial3D cannot apply to a 2D node")

	_assign_material(visual, mat)
	return _format_success("Applied %s to %s" % [_color_id(mat_id), _color_path(node_path)])

func _cmd_mat_set(args: Array, _piped_input: String = "") -> String:
	if args.size() < 3:
		return _format_error("Usage: mat_set <mat_id> <property> <value>")
	var mat_id: String = str(args[0]).strip_edges()
	var prop: String = str(args[1]).strip_edges()
	var value_str: String = ""
	for i in range(2, args.size()):
		if i > 2:
			value_str += " "
		value_str += str(args[i])
	value_str = value_str.strip_edges()

	if not _materials.has(mat_id):
		return _format_error("Unknown material id: %s" % mat_id)
	var mat: Material = _materials[mat_id] as Material
	if not mat:
		return _format_error("Material slot %s is empty" % mat_id)
	if not (prop in mat):
		return _format_error("Material %s has no property '%s'" % [mat.get_class(), prop])

	var parsed: Variant = _parse_shader_value(value_str)
	mat.set(prop, parsed)
	return _format_success("Set %s.%s = %s" % [_color_id(mat_id), prop, _color_number(str(parsed))])

func _cmd_mat_list(_args: Array, _piped_input: String = "") -> String:
	if _materials.is_empty():
		return "No stored materials. Use mat_new to create one."
	var keys: Array = _materials.keys()
	keys.sort()
	var lines: PackedStringArray = []
	lines.append("Stored materials (%s):" % _color_number(str(_materials.size())))
	for k in keys:
		var m: Material = _materials[k] as Material
		var type_str: String = m.get_class() if m else "<freed>"
		lines.append("  %s : %s" % [_color_id(str(k)), type_str])
	return "\n".join(lines)

func _cmd_mat_drop(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: mat_drop <mat_id|all>")
	var target: String = str(args[0]).strip_edges()
	if target == "all":
		var count: int = _materials.size()
		_materials.clear()
		return _format_success("Dropped %s stored material(s)" % _color_number(str(count)))
	if not _materials.has(target):
		return _format_error("Unknown material id: %s" % target)
	_materials.erase(target)
	return _format_success("Dropped %s" % _color_id(target))

#endregion

#region Helpers

func _get_scene_root() -> Node:
	if Engine.is_editor_hint():
		return EditorInterface.get_edited_scene_root()
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if not tree:
		return null
	if tree.current_scene:
		return tree.current_scene
	return tree.root

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

func _resolve_visual(node: Node) -> Node:
	# Returns the node itself if it is a CanvasItem or a GeometryInstance3D,
	# otherwise null. These are the two Godot base classes that actually carry
	# a material slot (CanvasItem.material / GeometryInstance3D.material_override).
	if node is CanvasItem:
		return node
	if node is GeometryInstance3D:
		return node
	return null

func _assign_material(visual: Node, mat: Material) -> void:
	# Branches on the actual node type rather than the material type because
	# GeometryInstance3D uses material_override and CanvasItem uses material.
	# Passing null clears the slot (matches shader_clear and mat_apply with
	# the user removing the override).
	if visual is GeometryInstance3D:
		(visual as GeometryInstance3D).material_override = mat
	elif visual is CanvasItem:
		(visual as CanvasItem).material = mat

func _get_current_material(node: Node) -> Material:
	if node is GeometryInstance3D:
		return (node as GeometryInstance3D).material_override
	if node is CanvasItem:
		return (node as CanvasItem).material
	return null

func _get_shader_material(node: Node) -> ShaderMaterial:
	var mat: Material = _get_current_material(node)
	return mat as ShaderMaterial

func _get_or_create_shader_material(node: Node) -> ShaderMaterial:
	# Reuses the node's existing ShaderMaterial if one is already assigned, so
	# multiple shader_set calls all hit the same material rather than each call
	# clobbering the previous one's uniforms.
	var visual: Node = _resolve_visual(node)
	if not visual:
		return null
	var existing: Material = _get_current_material(visual)
	if existing is ShaderMaterial:
		return existing
	var mat: ShaderMaterial = ShaderMaterial.new()
	_assign_material(visual, mat)
	return mat

func _has_uniform(mat: ShaderMaterial, uniform: String) -> bool:
	if not mat or not mat.shader:
		return false
	for u in mat.shader.get_shader_uniform_list():
		if str(u.get("name", "")) == uniform:
			return true
	return false

func _parse_shader_value(raw: String) -> Variant:
	var s: String = raw.strip_edges()
	if s.is_empty():
		return ""
	# Booleans first so "true"/"false" do not get misread as strings.
	if s == "true":
		return true
	if s == "false":
		return false
	# Hex color: #RGB / #RRGGBB / #RRGGBBAA. Color.html accepts all three but
	# returns Color() on garbage, so we guard with a regex-ish length check.
	if s.begins_with("#"):
		var hex: String = s.substr(1)
		if hex.length() in [3, 6, 8] and _is_hex(hex):
			return Color(s)
	# Comma-separated numbers map to Vector2 / Vector3 / Vector4 the same way
	# the scene commands do.
	if s.contains(","):
		var parts: PackedStringArray = s.split(",")
		var nums: Array[float] = []
		var all_num: bool = true
		for p in parts:
			var t: String = p.strip_edges()
			if not (t.is_valid_float() or t.is_valid_int()):
				all_num = false
				break
			nums.append(t.to_float())
		if all_num:
			match nums.size():
				2: return Vector2(nums[0], nums[1])
				3: return Vector3(nums[0], nums[1], nums[2])
				4: return Vector4(nums[0], nums[1], nums[2], nums[3])
	# Quoted string passthrough so a literal "12" can be forced to String.
	if (s.begins_with("\"") and s.ends_with("\"")) or (s.begins_with("'") and s.ends_with("'")):
		return s.substr(1, s.length() - 2)
	if s.is_valid_int():
		return s.to_int()
	if s.is_valid_float():
		return s.to_float()
	return s

func _is_hex(s: String) -> bool:
	for i in s.length():
		var c: String = s.substr(i, 1).to_lower()
		var is_digit: bool = c >= "0" and c <= "9"
		var is_af: bool = c >= "a" and c <= "f"
		if not (is_digit or is_af):
			return false
	return true

func _parse_kv_args(args: Array) -> Dictionary:
	# Accepts ["key=value", "key2=value2", ...]. Tokens without '=' are stored
	# under "" so callers can still see positional args; today no command needs
	# them so they are effectively ignored.
	var out: Dictionary = {}
	for a in args:
		var s: String = str(a)
		var idx: int = s.find("=")
		if idx <= 0:
			continue
		var key: String = s.substr(0, idx).strip_edges()
		var val: String = s.substr(idx + 1).strip_edges()
		if not key.is_empty():
			out[key] = val
	return out

func _next_mat_id() -> String:
	var id: String = "mat_%d" % _next_id
	_next_id += 1
	return id

func _type_name(type_id: int) -> String:
	match type_id:
		TYPE_NIL: return "void"
		TYPE_BOOL: return "bool"
		TYPE_INT: return "int"
		TYPE_FLOAT: return "float"
		TYPE_STRING: return "String"
		TYPE_STRING_NAME: return "StringName"
		TYPE_VECTOR2: return "Vector2"
		TYPE_VECTOR2I: return "Vector2i"
		TYPE_VECTOR3: return "Vector3"
		TYPE_VECTOR3I: return "Vector3i"
		TYPE_VECTOR4: return "Vector4"
		TYPE_COLOR: return "Color"
		TYPE_TRANSFORM2D: return "Transform2D"
		TYPE_TRANSFORM3D: return "Transform3D"
		TYPE_OBJECT: return "Object"
		_: return "Variant"

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

func _color_id(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_ID, s]

#endregion

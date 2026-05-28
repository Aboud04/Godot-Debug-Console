@tool
class_name DebugConsoleResourceFactoryCommands extends RefCounted

# Tier 6 extension - in-memory Resource factory commands. Mirrors the layout of
# core/SceneCommands.gd: the orchestrator instantiates one of these, holds a
# strong reference, and calls register_commands(registry, core). All Callables
# remain valid for the lifetime of that strong reference.
#
# Resources are kept in the _resources dictionary keyed by string id (e.g.
# "res_1"). The factory does NOT add anything to the scene tree; it is purely
# a workbench for Resource manipulation, with save/load to .tres on demand.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"

var _registry: Node
var _core: Node
var _resources: Dictionary = {}
var _next_id: int = 1

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("res_new", _cmd_res_new, "Instantiate a Resource by class name: res_new <ClassName>", "both")
	_registry.register_command("res_set", _cmd_res_set, "Set a property on a stored resource: res_set <id> <prop> <value>", "both")
	_registry.register_command("res_get", _cmd_res_get, "Read a property from a stored resource: res_get <id> <prop>", "both")
	_registry.register_command("res_dump", _cmd_res_dump, "Dump all properties of a stored resource: res_dump <id>", "both")
	_registry.register_command("res_save", _cmd_res_save, "Save a stored resource to disk: res_save <id> <res://path.tres>", "both")
	_registry.register_command("res_load", _cmd_res_load, "Load a resource from disk into the factory: res_load <res://path> [as_id]", "both")
	_registry.register_command("res_dup", _cmd_res_dup, "Deep-duplicate a stored resource: res_dup <id> [as_id]", "both")
	_registry.register_command("res_list", _cmd_res_list, "List all resources currently stored in the factory: res_list", "both")

#region Command implementations

func _cmd_res_new(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: res_new <ClassName>")
	var type_name := str(args[0]).strip_edges()
	if not ClassDB.class_exists(type_name):
		return _format_error("Unknown class: %s" % type_name)
	if not ClassDB.can_instantiate(type_name):
		return _format_error("Class is not instantiable: %s" % type_name)

	var created: Object = ClassDB.instantiate(type_name)
	if not (created is Resource):
		if created:
			# Avoid leaking Node instances if someone passes a Node class.
			if created is Node:
				(created as Node).free()
		return _format_error("Class is not a Resource: %s" % type_name)

	var res: Resource = created
	var id := _allocate_id("")
	_resources[id] = res
	return _format_success("Created %s [%s] as %s" % [type_name, _color_path(res.resource_path if res.resource_path != "" else "<unsaved>"), _color_path(id)])

func _cmd_res_set(args: Array, piped_input: String = "") -> String:
	if args.size() < 3:
		return _format_error("Usage: res_set <id> <prop> <value>")
	var id := str(args[0]).strip_edges()
	var prop := str(args[1]).strip_edges()
	var raw_value := str(args[2]).strip_edges()

	var res := _resolve_resource(id)
	if not res:
		return _format_error("Unknown resource id: %s" % id)
	if not _resource_has_property(res, prop):
		return _format_error("Property not found: %s on %s" % [prop, res.get_class()])

	var value: Variant = _parse_value(raw_value)
	res.set(prop, value)
	return _format_success("%s.%s = %s" % [_color_path(id), prop, str(res.get(prop))])

func _cmd_res_get(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: res_get <id> <prop>")
	var id := str(args[0]).strip_edges()
	var prop := str(args[1]).strip_edges()

	var res := _resolve_resource(id)
	if not res:
		return _format_error("Unknown resource id: %s" % id)
	if not _resource_has_property(res, prop):
		return _format_error("Property not found: %s on %s" % [prop, res.get_class()])

	var val: Variant = res.get(prop)
	return "%s.%s = %s" % [_color_path(id), prop, str(val) if val != null else "<null>"]

func _cmd_res_dump(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: res_dump <id>")
	var id := str(args[0]).strip_edges()
	var res := _resolve_resource(id)
	if not res:
		return _format_error("Unknown resource id: %s" % id)

	var prop_list: Array = res.get_property_list()
	var lines: Array[String] = []
	var path_label: String = res.resource_path if res.resource_path != "" else "<unsaved>"
	lines.append("%s [%s] @ %s" % [_color_path(id), res.get_class(), _color_path(path_label)])

	var shown: int = 0
	for p in prop_list:
		var usage: int = int(p.get("usage", 0))
		if (usage & PROPERTY_USAGE_STORAGE) == 0 and (usage & PROPERTY_USAGE_EDITOR) == 0:
			continue
		var pname: String = str(p.get("name", ""))
		if pname.is_empty() or pname.begins_with("_"):
			continue
		var type_id: int = int(p.get("type", TYPE_NIL))
		var val: Variant = res.get(pname)
		var val_str: String = str(val) if val != null else "<null>"
		lines.append("  %-32s %-14s = %s" % [pname, _type_name(type_id), val_str])
		shown += 1
	if shown == 0:
		lines.append("  (no storable/editor properties)")
	return "\n".join(lines)

func _cmd_res_save(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: res_save <id> <res://path.tres>")
	var id := str(args[0]).strip_edges()
	var path := str(args[1]).strip_edges()
	if not path.begins_with("res://"):
		return _format_error("Path must start with res://: %s" % path)

	var res := _resolve_resource(id)
	if not res:
		return _format_error("Unknown resource id: %s" % id)

	var err: int = ResourceSaver.save(res, path)
	if err != OK:
		return _format_error("ResourceSaver.save failed (%d) for %s" % [err, path])
	return _format_success("Saved %s -> %s" % [_color_path(id), _color_path(path)])

func _cmd_res_load(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: res_load <res://path> [as_id]")
	var path := str(args[0]).strip_edges()
	var requested_id := str(args[1]).strip_edges() if args.size() > 1 else ""
	if not path.begins_with("res://"):
		return _format_error("Path must start with res://: %s" % path)
	if not ResourceLoader.exists(path):
		return _format_error("Resource not found: %s" % path)

	var loaded: Resource = ResourceLoader.load(path)
	if not loaded:
		return _format_error("Failed to load resource: %s" % path)

	var id := _allocate_id(requested_id)
	_resources[id] = loaded
	return _format_success("Loaded %s [%s] as %s" % [_color_path(path), loaded.get_class(), _color_path(id)])

func _cmd_res_dup(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: res_dup <id> [as_id]")
	var id := str(args[0]).strip_edges()
	var requested_id := str(args[1]).strip_edges() if args.size() > 1 else ""

	var res := _resolve_resource(id)
	if not res:
		return _format_error("Unknown resource id: %s" % id)

	var copy: Resource = res.duplicate(true)
	if not copy:
		return _format_error("duplicate() returned null for %s" % id)

	var new_id := _allocate_id(requested_id)
	_resources[new_id] = copy
	return _format_success("Duplicated %s -> %s [%s]" % [_color_path(id), _color_path(new_id), copy.get_class()])

func _cmd_res_list(args: Array, piped_input: String = "") -> String:
	if _resources.is_empty():
		return "(no resources in factory)"
	var ids: Array = _resources.keys()
	ids.sort()
	var lines: Array[String] = []
	lines.append("Resources: %s" % _color_number(str(_resources.size())))
	for id in ids:
		var res: Resource = _resources[id]
		if not is_instance_valid(res):
			lines.append("  %-12s <freed>" % str(id))
			continue
		var path_label: String = res.resource_path if res.resource_path != "" else "<unsaved>"
		lines.append("  %-12s %-24s %s" % [str(id), res.get_class(), _color_path(path_label)])
	return "\n".join(lines)

#endregion

#region Helpers

func _allocate_id(requested: String) -> String:
	if not requested.is_empty():
		return requested
	var id: String = "res_%d" % _next_id
	_next_id += 1
	while _resources.has(id):
		id = "res_%d" % _next_id
		_next_id += 1
	return id

func _resolve_resource(id: String) -> Resource:
	if not _resources.has(id):
		return null
	var res: Resource = _resources[id]
	if not is_instance_valid(res):
		_resources.erase(id)
		return null
	return res

func _resource_has_property(res: Resource, prop: String) -> bool:
	for p in res.get_property_list():
		if str(p.get("name", "")) == prop:
			return true
	return false

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
		for p in parts:
			var t := p.strip_edges()
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
		TYPE_NODE_PATH: return "NodePath"
		TYPE_RID: return "RID"
		TYPE_OBJECT: return "Object"
		TYPE_CALLABLE: return "Callable"
		TYPE_SIGNAL: return "Signal"
		TYPE_DICTIONARY: return "Dictionary"
		TYPE_ARRAY: return "Array"
		TYPE_PACKED_BYTE_ARRAY: return "PackedByteArray"
		TYPE_PACKED_STRING_ARRAY: return "PackedStringArray"
		TYPE_TRANSFORM2D: return "Transform2D"
		TYPE_TRANSFORM3D: return "Transform3D"
		TYPE_BASIS: return "Basis"
		_: return "Variant"

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

#endregion

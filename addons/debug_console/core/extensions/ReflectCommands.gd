@tool
class_name DebugConsoleReflectCommands extends RefCounted

# Extension module - deep ClassDB introspection commands.
# Complements the existing `methods` and `class_db` helpers in SceneCommands.gd
# by exposing inheritance chains, full method signatures (with named args and
# default values), exported-property filtering, the complete ClassDB tree as an
# ASCII drawing, user-defined class_name registrations, and class constants /
# enum members.
#
# Follows the SceneCommands.gd contract: register_commands(registry, core)
# wires Callables (args: Array, piped_input: String = "") -> String that return
# BBCode-formatted strings. Registered as mode="both" because all queries are
# read-only and equally useful at edit time and at runtime.
#
# The orchestrator must keep a strong reference to the instance so the bound
# Callables survive for the lifetime of the plugin.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_MUTED := "#888888"
const _COLOR_KEYWORD := "#C792EA"

const _HIERARCHY_NODE_LIMIT := 2000
const _TREE_LIMIT := 4000

var _registry: Node
var _core: Node

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("reflect_class", _cmd_reflect_class, "Inheritance chain and summary for a class: reflect_class <ClassName>", "both")
	_registry.register_command("reflect_methods", _cmd_reflect_methods, "Method signatures (arg names, types, defaults): reflect_methods <ClassName> [--inherited]", "both")
	_registry.register_command("reflect_signals", _cmd_reflect_signals, "Signal declarations for a class: reflect_signals <ClassName>", "both")
	_registry.register_command("reflect_properties", _cmd_reflect_properties, "Properties for a class: reflect_properties <ClassName> [--exported]", "both")
	_registry.register_command("reflect_class_hierarchy", _cmd_reflect_class_hierarchy, "Full ClassDB tree as ASCII drawing: reflect_class_hierarchy [root_class]", "both")
	_registry.register_command("reflect_custom", _cmd_reflect_custom, "List user-defined class_name registrations from project.godot", "both")
	_registry.register_command("reflect_constants", _cmd_reflect_constants, "Integer constants and enums for a class: reflect_constants <ClassName>", "both")

#region Command implementations

func _cmd_reflect_class(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: reflect_class <ClassName>")
	var cls := str(args[0]).strip_edges()
	if not ClassDB.class_exists(cls):
		var custom := _find_custom_class(cls)
		if not custom.is_empty():
			return _describe_custom_class(custom)
		return _format_error("Unknown class: %s" % cls)

	var chain := _inheritance_chain(cls)
	var inheriters: PackedStringArray = ClassDB.get_inheriters_from_class(cls)
	var direct_children: Array[String] = _direct_children(cls)

	var lines: Array[String] = []
	lines.append("[color=%s]=== %s ===[/color]" % [_COLOR_PATH, cls])
	lines.append("Instantiable: %s  |  Engine class: yes" % str(ClassDB.can_instantiate(cls)))
	lines.append("[color=%s]Inheritance:[/color] %s" % [_COLOR_KEYWORD, " -> ".join(chain)])

	var api: String = _api_type_label(cls)
	lines.append("API: %s" % api)

	# Godot has no first-class interfaces. Surface the closest equivalents so
	# the user can reason about substitutability without us inventing data.
	var traits: Array[String] = _pseudo_interfaces(cls)
	if traits.is_empty():
		lines.append("[color=%s]Interfaces:[/color] (Godot has no interfaces; engine reports none)" % _COLOR_MUTED)
	else:
		lines.append("[color=%s]Behaviour markers:[/color] %s" % [_COLOR_KEYWORD, ", ".join(traits)])

	var own_methods: int = ClassDB.class_get_method_list(cls, true).size()
	var own_props: int = ClassDB.class_get_property_list(cls, true).size()
	var own_signals: int = ClassDB.class_get_signal_list(cls, true).size()
	var own_consts: int = ClassDB.class_get_integer_constant_list(cls, true).size()
	lines.append("Own surface: methods=%s  properties=%s  signals=%s  constants=%s" % [
		_color_number(str(own_methods)),
		_color_number(str(own_props)),
		_color_number(str(own_signals)),
		_color_number(str(own_consts)),
	])

	lines.append("Inheriters (total): %s" % _color_number(str(inheriters.size())))
	if not direct_children.is_empty():
		var preview: Array[String] = []
		var limit: int = mini(direct_children.size(), 12)
		for i in range(limit):
			preview.append(direct_children[i])
		var suffix: String = "" if direct_children.size() <= 12 else " ... (+%d more)" % (direct_children.size() - 12)
		lines.append("  Direct children: %s%s" % [", ".join(preview), suffix])

	return "\n".join(lines)

func _cmd_reflect_methods(args: Array, piped_input: String = "") -> String:
	var include_inherited := false
	var positional: Array[String] = []
	for a in args:
		var t := str(a).strip_edges()
		if t == "--inherited" or t == "-i":
			include_inherited = true
		elif not t.is_empty():
			positional.append(t)
	if positional.is_empty():
		return _format_error("Usage: reflect_methods <ClassName> [--inherited]")
	var cls := positional[0]
	if not ClassDB.class_exists(cls):
		return _format_error("Unknown class: %s" % cls)

	var methods: Array = ClassDB.class_get_method_list(cls, not include_inherited)
	methods.sort_custom(func(a, b): return str(a.get("name", "")) < str(b.get("name", "")))

	var lines: Array[String] = []
	var scope_label: String = "all (incl. inherited)" if include_inherited else "own only"
	lines.append("[color=%s]=== %s - methods (%s) ===[/color]" % [_COLOR_PATH, cls, scope_label])
	lines.append("Count: %s" % _color_number(str(methods.size())))

	for m in methods:
		var mname: String = str(m.get("name", ""))
		if mname.is_empty():
			continue
		var ret_info: Dictionary = m.get("return", {})
		var ret_label: String = _resolve_type_label(ret_info)
		var args_list: Array = m.get("args", [])
		var defaults: Array = m.get("default_args", [])
		var default_offset: int = args_list.size() - defaults.size()
		var arg_pieces: Array[String] = []
		for i in range(args_list.size()):
			var arg_info: Dictionary = args_list[i]
			var arg_name: String = str(arg_info.get("name", "arg%d" % i))
			var arg_type: String = _resolve_type_label(arg_info)
			var piece: String = "%s: %s" % [arg_name, arg_type]
			var default_idx: int = i - default_offset
			if default_idx >= 0 and default_idx < defaults.size():
				piece += " = %s" % _format_default(defaults[default_idx])
			arg_pieces.append(piece)
		var flags: int = int(m.get("flags", 0))
		var prefix: String = ""
		if flags & METHOD_FLAG_STATIC:
			prefix += "static "
		if flags & METHOD_FLAG_VIRTUAL:
			prefix += "virtual "
		if flags & METHOD_FLAG_CONST:
			prefix += "const "
		lines.append("  %s%s %s(%s)" % [prefix, ret_label, mname, ", ".join(arg_pieces)])

	if methods.is_empty():
		lines.append("  (no methods reported by ClassDB)")
	return "\n".join(lines)

func _cmd_reflect_signals(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: reflect_signals <ClassName>")
	var cls := str(args[0]).strip_edges()
	if not ClassDB.class_exists(cls):
		return _format_error("Unknown class: %s" % cls)

	var own: Array = ClassDB.class_get_signal_list(cls, true)
	var inherited: Array = ClassDB.class_get_signal_list(cls, false)
	own.sort_custom(func(a, b): return str(a.get("name", "")) < str(b.get("name", "")))

	var lines: Array[String] = []
	lines.append("[color=%s]=== %s - signals ===[/color]" % [_COLOR_PATH, cls])
	lines.append("Own: %s  |  With inherited: %s" % [
		_color_number(str(own.size())),
		_color_number(str(inherited.size())),
	])
	for s in own:
		lines.append("  signal %s" % _format_signal_signature(s))

	var inherited_only: Array = []
	var own_names: Dictionary = {}
	for s in own:
		own_names[str(s.get("name", ""))] = true
	for s in inherited:
		var n: String = str(s.get("name", ""))
		if not own_names.has(n):
			inherited_only.append(s)
	if not inherited_only.is_empty():
		lines.append("[color=%s]Inherited:[/color]" % _COLOR_KEYWORD)
		inherited_only.sort_custom(func(a, b): return str(a.get("name", "")) < str(b.get("name", "")))
		for s in inherited_only:
			lines.append("  signal %s" % _format_signal_signature(s))

	if own.is_empty() and inherited_only.is_empty():
		lines.append("  (no signals)")
	return "\n".join(lines)

func _cmd_reflect_properties(args: Array, piped_input: String = "") -> String:
	var only_exported := false
	var positional: Array[String] = []
	for a in args:
		var t := str(a).strip_edges()
		if t == "--exported" or t == "-e":
			only_exported = true
		elif not t.is_empty():
			positional.append(t)
	if positional.is_empty():
		return _format_error("Usage: reflect_properties <ClassName> [--exported]")
	var cls := positional[0]
	if not ClassDB.class_exists(cls):
		return _format_error("Unknown class: %s" % cls)

	var props: Array = ClassDB.class_get_property_list(cls, true)
	props.sort_custom(func(a, b): return str(a.get("name", "")) < str(b.get("name", "")))

	var lines: Array[String] = []
	var filter_label: String = "exported only" if only_exported else "all own"
	lines.append("[color=%s]=== %s - properties (%s) ===[/color]" % [_COLOR_PATH, cls, filter_label])

	var shown: int = 0
	for p in props:
		var pname: String = str(p.get("name", ""))
		if pname.is_empty():
			continue
		var usage: int = int(p.get("usage", 0))
		if only_exported and not (usage & PROPERTY_USAGE_EDITOR):
			continue
		# Group separators clutter output; skip them.
		if usage & PROPERTY_USAGE_GROUP or usage & PROPERTY_USAGE_SUBGROUP or usage & PROPERTY_USAGE_CATEGORY:
			continue
		var type_label: String = _resolve_type_label(p)
		var flag_pieces: Array[String] = []
		if usage & PROPERTY_USAGE_EDITOR:
			flag_pieces.append("editor")
		if usage & PROPERTY_USAGE_STORAGE:
			flag_pieces.append("storage")
		if usage & PROPERTY_USAGE_READ_ONLY:
			flag_pieces.append("readonly")
		var hint_int: int = int(p.get("hint", PROPERTY_HINT_NONE))
		var hint_string: String = str(p.get("hint_string", ""))
		var hint_label: String = ""
		if hint_int != PROPERTY_HINT_NONE and not hint_string.is_empty():
			hint_label = "  [color=%s]hint=%s(%s)[/color]" % [_COLOR_MUTED, _hint_name(hint_int), hint_string]
		var flag_label: String = ""
		if not flag_pieces.is_empty():
			flag_label = "  [color=%s][%s][/color]" % [_COLOR_MUTED, ", ".join(flag_pieces)]
		lines.append("  %s: %s%s%s" % [pname, type_label, flag_label, hint_label])
		shown += 1
	if shown == 0:
		lines.append("  (no matching properties)")
	else:
		lines.append("Shown: %s" % _color_number(str(shown)))
	return "\n".join(lines)

func _cmd_reflect_class_hierarchy(args: Array, piped_input: String = "") -> String:
	var root: String = "Object"
	if not args.is_empty():
		root = str(args[0]).strip_edges()
	if not ClassDB.class_exists(root):
		return _format_error("Unknown class: %s" % root)

	# Build parent -> children map once over the whole ClassDB list. This is
	# much faster than recursing with get_inheriters_from_class (which is
	# transitive) and keeps the traversal strictly tree-shaped.
	var children_of: Dictionary = {}
	var all_classes: PackedStringArray = ClassDB.get_class_list()
	for c in all_classes:
		var parent: String = ClassDB.get_parent_class(c)
		if parent.is_empty():
			continue
		if not children_of.has(parent):
			children_of[parent] = []
		(children_of[parent] as Array).append(c)
	for k in children_of.keys():
		(children_of[k] as Array).sort()

	var lines: Array[String] = []
	lines.append("[color=%s]=== ClassDB hierarchy from %s ===[/color]" % [_COLOR_PATH, root])
	var counter: Array[int] = [0]
	_render_tree(root, "", true, children_of, lines, counter)
	if counter[0] >= _HIERARCHY_NODE_LIMIT:
		lines.append("[color=%s](truncated at %d nodes; rerun with a narrower root class)[/color]" % [_COLOR_MUTED, _HIERARCHY_NODE_LIMIT])
	return "\n".join(lines)

func _cmd_reflect_custom(args: Array, piped_input: String = "") -> String:
	var globals: Array = ProjectSettings.get_global_class_list()
	var lines: Array[String] = []
	lines.append("[color=%s]=== User-defined class_name registrations ===[/color]" % _COLOR_PATH)
	lines.append("Count: %s" % _color_number(str(globals.size())))
	if globals.is_empty():
		lines.append("  (no class_name declarations registered in project.godot)")
		return "\n".join(lines)

	var sorted_globals: Array = globals.duplicate()
	sorted_globals.sort_custom(func(a, b): return str(a.get("class", "")) < str(b.get("class", "")))
	for entry in sorted_globals:
		var cls_name: String = str(entry.get("class", ""))
		var base: String = str(entry.get("base", ""))
		var path: String = str(entry.get("path", ""))
		var lang: String = str(entry.get("language", ""))
		var icon: String = str(entry.get("icon", ""))
		lines.append("  [color=%s]%s[/color] extends %s  [color=%s](%s)[/color]" % [
			_COLOR_SUCCESS, cls_name, base, _COLOR_MUTED, lang,
		])
		lines.append("    path: %s" % _color_path(path))
		if not icon.is_empty():
			lines.append("    icon: %s" % _color_path(icon))
	return "\n".join(lines)

func _cmd_reflect_constants(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: reflect_constants <ClassName>")
	var cls := str(args[0]).strip_edges()
	if not ClassDB.class_exists(cls):
		return _format_error("Unknown class: %s" % cls)

	var consts: PackedStringArray = ClassDB.class_get_integer_constant_list(cls, true)
	var enums: PackedStringArray = ClassDB.class_get_enum_list(cls, true)

	var enum_member_lookup: Dictionary = {}
	for en in enums:
		for member in ClassDB.class_get_enum_constants(cls, en, true):
			enum_member_lookup[str(member)] = en

	var lines: Array[String] = []
	lines.append("[color=%s]=== %s - constants & enums ===[/color]" % [_COLOR_PATH, cls])

	if enums.is_empty():
		lines.append("[color=%s]Enums:[/color] (none declared on this class)" % _COLOR_KEYWORD)
	else:
		lines.append("[color=%s]Enums:[/color] %s" % [_COLOR_KEYWORD, _color_number(str(enums.size()))])
		var enum_names_sorted: Array = []
		for en in enums:
			enum_names_sorted.append(en)
		enum_names_sorted.sort()
		for en in enum_names_sorted:
			lines.append("  enum %s {" % str(en))
			var members: PackedStringArray = ClassDB.class_get_enum_constants(cls, en, true)
			var member_list: Array = []
			for m in members:
				member_list.append(m)
			member_list.sort_custom(func(a, b):
				return ClassDB.class_get_integer_constant(cls, a) < ClassDB.class_get_integer_constant(cls, b)
			)
			for m in member_list:
				var val: int = ClassDB.class_get_integer_constant(cls, m)
				lines.append("    %s = %s" % [str(m), _color_number(str(val))])
			lines.append("  }")

	var loose_consts: Array = []
	for c in consts:
		if not enum_member_lookup.has(str(c)):
			loose_consts.append(c)
	loose_consts.sort_custom(func(a, b):
		return ClassDB.class_get_integer_constant(cls, a) < ClassDB.class_get_integer_constant(cls, b)
	)
	if loose_consts.is_empty():
		lines.append("[color=%s]Constants:[/color] (no standalone integer constants)" % _COLOR_KEYWORD)
	else:
		lines.append("[color=%s]Constants:[/color] %s" % [_COLOR_KEYWORD, _color_number(str(loose_consts.size()))])
		for c in loose_consts:
			var val: int = ClassDB.class_get_integer_constant(cls, c)
			lines.append("  const %s = %s" % [str(c), _color_number(str(val))])

	return "\n".join(lines)

#endregion

#region Helpers

func _inheritance_chain(cls: String) -> Array[String]:
	var chain: Array[String] = []
	var current: String = cls
	var guard: int = 32
	while not current.is_empty() and guard > 0:
		chain.append(current)
		current = ClassDB.get_parent_class(current)
		guard -= 1
	chain.reverse()
	return chain

func _direct_children(cls: String) -> Array[String]:
	var result: Array[String] = []
	for c in ClassDB.get_class_list():
		if ClassDB.get_parent_class(c) == cls:
			result.append(c)
	result.sort()
	return result

func _pseudo_interfaces(cls: String) -> Array[String]:
	# Godot doesn't expose interfaces, but several base classes act as
	# behavioural markers users care about. Report any that apply.
	var markers: Array[String] = []
	var probes: Array[String] = [
		"Node", "Resource", "RefCounted", "CanvasItem", "Node2D", "Node3D",
		"Control", "Container", "CollisionObject2D", "CollisionObject3D",
		"PhysicsBody2D", "PhysicsBody3D",
	]
	for p in probes:
		if p == cls:
			continue
		if ClassDB.is_parent_class(cls, p):
			markers.append(p)
	return markers

func _api_type_label(cls: String) -> String:
	var api: int = ClassDB.class_get_api_type(cls)
	match api:
		ClassDB.API_CORE: return "core"
		ClassDB.API_EDITOR: return "editor"
		ClassDB.API_EXTENSION: return "extension (GDExtension)"
		ClassDB.API_EDITOR_EXTENSION: return "editor extension"
		_: return "unknown"

func _format_signal_signature(info: Dictionary) -> String:
	var sname: String = str(info.get("name", ""))
	var arg_pieces: Array[String] = []
	for a in info.get("args", []):
		var an: String = str(a.get("name", ""))
		var at: String = _resolve_type_label(a)
		if an.is_empty():
			arg_pieces.append(at)
		else:
			arg_pieces.append("%s: %s" % [an, at])
	return "%s(%s)" % [sname, ", ".join(arg_pieces)]

func _resolve_type_label(info: Dictionary) -> String:
	# Prefer explicit class_name when the field carries it (objects, resources),
	# fall back to the variant type id otherwise.
	var class_name_hint: String = str(info.get("class_name", ""))
	if not class_name_hint.is_empty():
		return class_name_hint
	var t: int = int(info.get("type", TYPE_NIL))
	return _type_name(t)

func _format_default(v: Variant) -> String:
	if v == null:
		return "null"
	if v is String:
		return "\"%s\"" % v
	if v is StringName:
		return "&\"%s\"" % str(v)
	if v is NodePath:
		return "^\"%s\"" % str(v)
	return str(v)

func _hint_name(hint_id: int) -> String:
	match hint_id:
		PROPERTY_HINT_NONE: return "NONE"
		PROPERTY_HINT_RANGE: return "RANGE"
		PROPERTY_HINT_ENUM: return "ENUM"
		PROPERTY_HINT_FLAGS: return "FLAGS"
		PROPERTY_HINT_FILE: return "FILE"
		PROPERTY_HINT_DIR: return "DIR"
		PROPERTY_HINT_GLOBAL_FILE: return "GLOBAL_FILE"
		PROPERTY_HINT_GLOBAL_DIR: return "GLOBAL_DIR"
		PROPERTY_HINT_RESOURCE_TYPE: return "RESOURCE_TYPE"
		PROPERTY_HINT_MULTILINE_TEXT: return "MULTILINE_TEXT"
		PROPERTY_HINT_EXPRESSION: return "EXPRESSION"
		PROPERTY_HINT_PLACEHOLDER_TEXT: return "PLACEHOLDER"
		PROPERTY_HINT_COLOR_NO_ALPHA: return "COLOR_NO_ALPHA"
		PROPERTY_HINT_NODE_TYPE: return "NODE_TYPE"
		PROPERTY_HINT_LAYERS_2D_PHYSICS: return "LAYERS_2D_PHYSICS"
		PROPERTY_HINT_LAYERS_3D_PHYSICS: return "LAYERS_3D_PHYSICS"
		_: return "HINT_%d" % hint_id

func _render_tree(cls: String, prefix: String, is_last: bool, children_of: Dictionary, out: Array[String], counter: Array[int]) -> void:
	if counter[0] >= _HIERARCHY_NODE_LIMIT:
		return
	counter[0] += 1
	var connector: String = "└── " if is_last else "├── "
	var label: String = cls
	if not ClassDB.can_instantiate(cls):
		label += "  [color=%s](abstract)[/color]" % _COLOR_MUTED
	if prefix.is_empty() and cls == "Object":
		out.append(cls)
	else:
		out.append("%s%s%s" % [prefix, connector, label])
	if out.size() >= _TREE_LIMIT:
		return
	var kids: Array = children_of.get(cls, [])
	if kids.is_empty():
		return
	var child_prefix: String
	if prefix.is_empty() and cls == "Object":
		child_prefix = ""
	else:
		child_prefix = prefix + ("    " if is_last else "│   ")
	for i in range(kids.size()):
		var last: bool = (i == kids.size() - 1)
		_render_tree(kids[i], child_prefix, last, children_of, out, counter)
		if counter[0] >= _HIERARCHY_NODE_LIMIT or out.size() >= _TREE_LIMIT:
			return

func _find_custom_class(cls: String) -> Dictionary:
	for entry in ProjectSettings.get_global_class_list():
		if str(entry.get("class", "")) == cls:
			return entry
	return {}

func _describe_custom_class(entry: Dictionary) -> String:
	var cls_name: String = str(entry.get("class", ""))
	var base: String = str(entry.get("base", ""))
	var path: String = str(entry.get("path", ""))
	var lang: String = str(entry.get("language", ""))
	var lines: Array[String] = []
	lines.append("[color=%s]=== %s (user-defined) ===[/color]" % [_COLOR_PATH, cls_name])
	lines.append("Source: %s" % _color_path(path))
	lines.append("Language: %s" % lang)
	lines.append("Declared base: %s" % base)
	if ClassDB.class_exists(base):
		lines.append("[color=%s]Engine inheritance:[/color] %s -> %s" % [
			_COLOR_KEYWORD,
			" -> ".join(_inheritance_chain(base)),
			cls_name,
		])
	lines.append("[color=%s]Note:[/color] ClassDB does not index user-defined script classes; use reflect_methods on the declared base, or load(%s) to introspect the script directly." % [
		_COLOR_MUTED, _format_default(path),
	])
	return "\n".join(lines)

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
		TYPE_VECTOR4I: return "Vector4i"
		TYPE_RECT2: return "Rect2"
		TYPE_RECT2I: return "Rect2i"
		TYPE_PLANE: return "Plane"
		TYPE_QUATERNION: return "Quaternion"
		TYPE_AABB: return "AABB"
		TYPE_COLOR: return "Color"
		TYPE_NODE_PATH: return "NodePath"
		TYPE_RID: return "RID"
		TYPE_OBJECT: return "Object"
		TYPE_CALLABLE: return "Callable"
		TYPE_SIGNAL: return "Signal"
		TYPE_DICTIONARY: return "Dictionary"
		TYPE_ARRAY: return "Array"
		TYPE_PACKED_BYTE_ARRAY: return "PackedByteArray"
		TYPE_PACKED_INT32_ARRAY: return "PackedInt32Array"
		TYPE_PACKED_INT64_ARRAY: return "PackedInt64Array"
		TYPE_PACKED_FLOAT32_ARRAY: return "PackedFloat32Array"
		TYPE_PACKED_FLOAT64_ARRAY: return "PackedFloat64Array"
		TYPE_PACKED_STRING_ARRAY: return "PackedStringArray"
		TYPE_PACKED_VECTOR2_ARRAY: return "PackedVector2Array"
		TYPE_PACKED_VECTOR3_ARRAY: return "PackedVector3Array"
		TYPE_PACKED_COLOR_ARRAY: return "PackedColorArray"
		TYPE_TRANSFORM2D: return "Transform2D"
		TYPE_TRANSFORM3D: return "Transform3D"
		TYPE_BASIS: return "Basis"
		TYPE_PROJECTION: return "Projection"
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

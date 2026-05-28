@tool
class_name DebugConsoleSaveSlotCommands extends RefCounted

# Save-slot system for game state. A fuller cousin of the existing
# `save_world` command: each slot bundles every @export / storage variable
# in the live scene tree, the runtime-spawned dynamic nodes (so they can be
# reinstantiated on load), an optional user-supplied meta dict, and a small
# header (version, timestamp, source scene). All slots live under
# user://slots/<id>.json.
#
# Mirrors the shape of SceneCommands.gd / ImportExportCommands.gd: same
# color palette, same scene-root resolution semantics (_get_scene_root /
# _format_error / _format_success), same "both" context registration so
# commands work in editor and runtime. The orchestrator
# (BuiltInCommands.register_universal_commands) instantiates one of these
# and keeps a strong reference so the Callables stay valid for the
# plugin's lifetime.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"

const _SLOTS_DIR := "user://slots"
const _SLOT_VERSION := 1

var _registry: Node
var _core: Node

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("slot_save", _cmd_slot_save, "Save scene tree state + optional meta dict to a slot: slot_save <slot_id> [meta_json]", "both")
	_registry.register_command("slot_load", _cmd_slot_load, "Restore a slot's state into the current scene: slot_load <slot_id>", "both")
	_registry.register_command("slot_list", _cmd_slot_list, "List all save slots with size + timestamp: slot_list", "both")
	_registry.register_command("slot_delete", _cmd_slot_delete, "Delete a slot, or 'all' to clear every slot: slot_delete <slot_id|all>", "both")
	_registry.register_command("slot_meta", _cmd_slot_meta, "Read the meta dict stored in a slot: slot_meta <slot_id>", "both")
	_registry.register_command("slot_info", _cmd_slot_info, "Show slot size / timestamp / version / node count: slot_info <slot_id>", "both")
	_registry.register_command("slot_export", _cmd_slot_export, "Copy a slot to an arbitrary user:// path: slot_export <slot_id> <user://path.json>", "both")
	_registry.register_command("slot_import", _cmd_slot_import, "Copy an external slot JSON into the slots dir: slot_import <user://path.json> [as_slot]", "both")

#region Command implementations

func _cmd_slot_save(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: slot_save <slot_id> [meta_json]")
	var slot_id := str(args[0]).strip_edges()
	var id_err := _validate_slot_id(slot_id)
	if not id_err.is_empty():
		return _format_error(id_err)

	var meta: Dictionary = {}
	if args.size() > 1:
		var meta_src: String = ""
		for i in range(1, args.size()):
			if meta_src.length() > 0:
				meta_src += " "
			meta_src += str(args[i])
		meta_src = meta_src.strip_edges()
		if not meta_src.is_empty():
			var parsed: Variant = JSON.parse_string(meta_src)
			if parsed == null:
				return _format_error("meta must be a valid JSON object: %s" % meta_src)
			if not (parsed is Dictionary):
				return _format_error("meta must be a JSON object (got %s)" % type_string(typeof(parsed)))
			meta = parsed

	var root: Node = _get_scene_root()
	if not root:
		return _format_error("No active scene to save")

	var ensure_err := _ensure_slots_dir()
	if not ensure_err.is_empty():
		return _format_error(ensure_err)

	var tree_dict: Dictionary = _node_to_slot_dict(root, root)
	var payload: Dictionary = {
		"version": _SLOT_VERSION,
		"slot_id": slot_id,
		"timestamp": int(Time.get_unix_time_from_system()),
		"scene_file_path": root.scene_file_path,
		"scene_root_name": root.name,
		"meta": meta,
		"tree": tree_dict,
	}

	var out_path: String = _slot_path(slot_id)
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	if not f:
		return _format_error("Cannot open slot file for write: %s (err %d)" % [out_path, FileAccess.get_open_error()])
	f.store_string(JSON.stringify(payload, "  "))
	f.close()

	var saved_nodes: int = _count_slot_nodes(tree_dict)
	var byte_count: int = _file_size(out_path)
	return _format_success("Saved slot %s: %s nodes, %s bytes -> %s" % [
		_color_path(slot_id),
		_color_number(str(saved_nodes)),
		_color_number(str(byte_count)),
		_color_path(out_path),
	])

func _cmd_slot_load(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: slot_load <slot_id>")
	var slot_id := str(args[0]).strip_edges()
	var id_err := _validate_slot_id(slot_id)
	if not id_err.is_empty():
		return _format_error(id_err)

	var slot_path: String = _slot_path(slot_id)
	var payload_or_err: Variant = _read_slot(slot_path)
	if payload_or_err is String:
		return _format_error(payload_or_err)
	var payload: Dictionary = payload_or_err

	var root: Node = _get_scene_root()
	if not root:
		return _format_error("No active scene to restore into")

	var tree_dict: Variant = payload.get("tree", null)
	if not (tree_dict is Dictionary):
		return _format_error("Slot has no tree data: %s" % slot_path)

	var saved_scene: String = String(payload.get("scene_file_path", ""))
	var warn: String = ""
	if saved_scene != "" and saved_scene != root.scene_file_path:
		warn = "  (saved from %s, current is %s)" % [saved_scene, root.scene_file_path if root.scene_file_path != "" else "<unsaved>"]

	var stats: Dictionary = {"restored": 0, "spawned": 0, "missing": 0, "errors": 0}
	_apply_slot_dict(tree_dict, root, root, stats)

	return _format_success("Loaded slot %s: %s restored, %s spawned, %s missing, %s errors%s" % [
		_color_path(slot_id),
		_color_number(str(stats["restored"])),
		_color_number(str(stats["spawned"])),
		_color_number(str(stats["missing"])),
		_color_number(str(stats["errors"])),
		warn,
	])

func _cmd_slot_list(_args: Array, _piped_input: String = "") -> String:
	var dir := DirAccess.open(_SLOTS_DIR)
	if not dir:
		return "No slots saved yet (%s does not exist)" % _SLOTS_DIR
	var rows: Array = []
	dir.list_dir_begin()
	while true:
		var fname := dir.get_next()
		if fname == "":
			break
		if fname == "." or fname == "..":
			continue
		if dir.current_is_dir():
			continue
		if not fname.ends_with(".json"):
			continue
		var slot_id: String = fname.get_basename()
		var abs_path: String = _SLOTS_DIR.path_join(fname)
		var size: int = _file_size(abs_path)
		var ts: int = _read_slot_timestamp(abs_path)
		rows.append({"id": slot_id, "size": size, "ts": ts, "path": abs_path})
	dir.list_dir_end()

	if rows.is_empty():
		return "No slots saved in %s" % _SLOTS_DIR
	rows.sort_custom(func(a, b): return int(a["ts"]) > int(b["ts"]))

	var lines: Array[String] = []
	lines.append("%s slot(s) in %s:" % [_color_number(str(rows.size())), _color_path(_SLOTS_DIR)])
	for r in rows:
		lines.append("  %-24s %10s bytes  %s" % [
			_color_path(String(r["id"])),
			_color_number(str(r["size"])),
			_format_timestamp(int(r["ts"])),
		])
	return "\n".join(lines)

func _cmd_slot_delete(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: slot_delete <slot_id|all>")
	var token := str(args[0]).strip_edges()

	if token == "all":
		var dir := DirAccess.open(_SLOTS_DIR)
		if not dir:
			return "No slots to delete (%s does not exist)" % _SLOTS_DIR
		var deleted: int = 0
		var failed: int = 0
		dir.list_dir_begin()
		while true:
			var fname := dir.get_next()
			if fname == "":
				break
			if fname == "." or fname == "..":
				continue
			if dir.current_is_dir():
				continue
			if not fname.ends_with(".json"):
				continue
			var err: int = dir.remove(fname)
			if err == OK:
				deleted += 1
			else:
				failed += 1
		dir.list_dir_end()
		return _format_success("Deleted %s slot(s), %s failed" % [
			_color_number(str(deleted)),
			_color_number(str(failed)),
		])

	var id_err := _validate_slot_id(token)
	if not id_err.is_empty():
		return _format_error(id_err)
	var slot_path: String = _slot_path(token)
	if not FileAccess.file_exists(slot_path):
		return _format_error("Slot not found: %s" % slot_path)
	var rm_err: int = DirAccess.remove_absolute(slot_path)
	if rm_err != OK:
		return _format_error("Failed to delete %s (err %d)" % [slot_path, rm_err])
	return _format_success("Deleted slot %s" % _color_path(token))

func _cmd_slot_meta(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: slot_meta <slot_id>")
	var slot_id := str(args[0]).strip_edges()
	var id_err := _validate_slot_id(slot_id)
	if not id_err.is_empty():
		return _format_error(id_err)

	var payload_or_err: Variant = _read_slot(_slot_path(slot_id))
	if payload_or_err is String:
		return _format_error(payload_or_err)
	var payload: Dictionary = payload_or_err
	var meta: Variant = payload.get("meta", {})
	if not (meta is Dictionary):
		meta = {}
	return "%s meta: %s" % [_color_path(slot_id), JSON.stringify(meta, "  ")]

func _cmd_slot_info(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: slot_info <slot_id>")
	var slot_id := str(args[0]).strip_edges()
	var id_err := _validate_slot_id(slot_id)
	if not id_err.is_empty():
		return _format_error(id_err)

	var slot_path: String = _slot_path(slot_id)
	if not FileAccess.file_exists(slot_path):
		return _format_error("Slot not found: %s" % slot_path)
	var payload_or_err: Variant = _read_slot(slot_path)
	if payload_or_err is String:
		return _format_error(payload_or_err)
	var payload: Dictionary = payload_or_err

	var size: int = _file_size(slot_path)
	var ts: int = int(payload.get("timestamp", 0))
	var version: int = int(payload.get("version", 0))
	var scene_path: String = String(payload.get("scene_file_path", ""))
	var tree_dict: Variant = payload.get("tree", {})
	var node_count: int = 0
	var dynamic_count: int = 0
	if tree_dict is Dictionary:
		node_count = _count_slot_nodes(tree_dict)
		dynamic_count = _count_dynamic_nodes(tree_dict)
	var meta_keys: int = 0
	var meta: Variant = payload.get("meta", {})
	if meta is Dictionary:
		meta_keys = (meta as Dictionary).size()

	var lines: Array[String] = []
	lines.append("Slot %s" % _color_path(slot_id))
	lines.append("  path        : %s" % _color_path(slot_path))
	lines.append("  size        : %s bytes" % _color_number(str(size)))
	lines.append("  timestamp   : %s" % _format_timestamp(ts))
	lines.append("  version     : %s" % _color_number(str(version)))
	lines.append("  scene       : %s" % (scene_path if scene_path != "" else "<unsaved>"))
	lines.append("  nodes       : %s (%s dynamic)" % [_color_number(str(node_count)), _color_number(str(dynamic_count))])
	lines.append("  meta keys   : %s" % _color_number(str(meta_keys)))
	return "\n".join(lines)

func _cmd_slot_export(args: Array, _piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: slot_export <slot_id> <user://path.json>")
	var slot_id := str(args[0]).strip_edges()
	var out_path := str(args[1]).strip_edges()
	var id_err := _validate_slot_id(slot_id)
	if not id_err.is_empty():
		return _format_error(id_err)
	if not (out_path.begins_with("user://") or out_path.begins_with("res://")):
		return _format_error("Output path must start with user:// or res://")

	var slot_path: String = _slot_path(slot_id)
	if not FileAccess.file_exists(slot_path):
		return _format_error("Slot not found: %s" % slot_path)

	var src := FileAccess.open(slot_path, FileAccess.READ)
	if not src:
		return _format_error("Cannot read slot file: %s" % slot_path)
	var bytes: PackedByteArray = src.get_buffer(src.get_length())
	src.close()

	var dst := FileAccess.open(out_path, FileAccess.WRITE)
	if not dst:
		return _format_error("Cannot open output for write: %s (err %d)" % [out_path, FileAccess.get_open_error()])
	dst.store_buffer(bytes)
	dst.close()

	return _format_success("Exported slot %s (%s bytes) -> %s" % [
		_color_path(slot_id),
		_color_number(str(bytes.size())),
		_color_path(out_path),
	])

func _cmd_slot_import(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: slot_import <user://path.json> [as_slot]")
	var in_path := str(args[0]).strip_edges()
	if not (in_path.begins_with("user://") or in_path.begins_with("res://")):
		return _format_error("Input path must start with user:// or res://")
	if not FileAccess.file_exists(in_path):
		return _format_error("Input file not found: %s" % in_path)

	var as_slot: String = ""
	if args.size() > 1:
		as_slot = str(args[1]).strip_edges()
	if as_slot.is_empty():
		as_slot = in_path.get_file().get_basename()
	var id_err := _validate_slot_id(as_slot)
	if not id_err.is_empty():
		return _format_error(id_err)

	var src := FileAccess.open(in_path, FileAccess.READ)
	if not src:
		return _format_error("Cannot read input: %s" % in_path)
	var bytes: PackedByteArray = src.get_buffer(src.get_length())
	src.close()

	# Validate the file is actually slot JSON before we copy it.
	var text: String = bytes.get_string_from_utf8()
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary) or not (parsed as Dictionary).has("tree"):
		return _format_error("Input does not look like a slot JSON (missing 'tree' field)")

	var ensure_err := _ensure_slots_dir()
	if not ensure_err.is_empty():
		return _format_error(ensure_err)
	var dst_path: String = _slot_path(as_slot)
	var dst := FileAccess.open(dst_path, FileAccess.WRITE)
	if not dst:
		return _format_error("Cannot open slot file for write: %s (err %d)" % [dst_path, FileAccess.get_open_error()])
	dst.store_buffer(bytes)
	dst.close()

	return _format_success("Imported %s -> slot %s (%s bytes)" % [
		_color_path(in_path),
		_color_path(as_slot),
		_color_number(str(bytes.size())),
	])

#endregion

#region Slot serialization

func _node_to_slot_dict(node: Node, scene_root: Node) -> Dictionary:
	var rel_path: String = _relative_path(scene_root, node)
	var parent: Node = node.get_parent()
	var parent_path: String = ""
	if parent and parent != node and scene_root.is_ancestor_of(node):
		parent_path = _relative_path(scene_root, parent)
	# A node is "dynamic" (spawned at runtime, not part of the .tscn) when
	# its owner is anything other than the scene root. Built-in scene nodes
	# always have their owner set to the scene root on load.
	var is_dynamic: bool = node != scene_root and node.owner != scene_root

	var script: Script = node.get_script() as Script
	var script_path: String = script.resource_path if script and script.resource_path != "" else ""

	var props: Dictionary = {}
	for entry in node.get_property_list():
		var usage: int = int(entry.get("usage", 0))
		if (usage & PROPERTY_USAGE_STORAGE) == 0:
			continue
		var pname: String = String(entry.get("name", ""))
		if pname.is_empty() or pname.begins_with("_"):
			continue
		if pname in ["script", "owner", "multiplayer", "name"]:
			continue
		var value: Variant = node.get(pname)
		props[pname] = _variant_to_json(value)

	var dict: Dictionary = {
		"name": node.name,
		"path": rel_path,
		"parent_path": parent_path,
		"class": node.get_class(),
		"dynamic": is_dynamic,
		"properties": props,
	}
	if script_path != "":
		dict["script"] = script_path
	if node.scene_file_path != "":
		dict["scene_file_path"] = node.scene_file_path

	var kids: Array = []
	for child in node.get_children():
		kids.append(_node_to_slot_dict(child, scene_root))
	dict["children"] = kids
	return dict

func _apply_slot_dict(entry: Dictionary, scene_root: Node, expected_parent: Node, stats: Dictionary) -> void:
	var rel_path: String = String(entry.get("path", ""))
	var is_dynamic: bool = bool(entry.get("dynamic", false))

	var target: Node = _resolve_relative(scene_root, rel_path)

	if not target:
		if is_dynamic:
			var spawned: Node = _spawn_dynamic_from_entry(entry, scene_root, expected_parent)
			if spawned:
				target = spawned
				stats["spawned"] = int(stats["spawned"]) + 1
			else:
				stats["errors"] = int(stats["errors"]) + 1
				return
		else:
			stats["missing"] = int(stats["missing"]) + 1
			return
	else:
		_apply_properties(target, entry.get("properties", {}))
		stats["restored"] = int(stats["restored"]) + 1

	var children: Array = entry.get("children", [])
	for c in children:
		if c is Dictionary:
			_apply_slot_dict(c, scene_root, target, stats)

func _spawn_dynamic_from_entry(entry: Dictionary, scene_root: Node, fallback_parent: Node) -> Node:
	var parent_path: String = String(entry.get("parent_path", ""))
	var parent: Node = _resolve_relative(scene_root, parent_path) if parent_path != "" else fallback_parent
	if not parent:
		parent = fallback_parent
	if not parent:
		return null

	var spawned: Node = null
	var scene_file_path: String = String(entry.get("scene_file_path", ""))
	if scene_file_path != "" and ResourceLoader.exists(scene_file_path):
		var packed := load(scene_file_path) as PackedScene
		if packed:
			spawned = packed.instantiate()

	if not spawned:
		var cls_name: String = String(entry.get("class", "Node"))
		if not ClassDB.class_exists(cls_name) or not ClassDB.can_instantiate(cls_name):
			cls_name = "Node"
		var raw: Object = ClassDB.instantiate(cls_name)
		if raw is Node:
			spawned = raw
		elif raw:
			raw.free()

	if not spawned:
		return null

	var entry_name: String = String(entry.get("name", ""))
	if not entry_name.is_empty():
		spawned.name = entry_name

	var script_path: String = String(entry.get("script", ""))
	if script_path != "" and ResourceLoader.exists(script_path):
		var script_res := load(script_path) as Script
		if script_res:
			spawned.set_script(script_res)

	parent.add_child(spawned)
	if Engine.is_editor_hint():
		spawned.owner = scene_root

	_apply_properties(spawned, entry.get("properties", {}))
	return spawned

func _apply_properties(node: Node, props_raw: Variant) -> void:
	if not (props_raw is Dictionary):
		return
	var props: Dictionary = props_raw
	for pname in props.keys():
		var key: String = String(pname)
		if key.is_empty() or key.begins_with("_"):
			continue
		if key in ["script", "owner", "multiplayer", "name"]:
			continue
		if not (key in node):
			continue
		var current: Variant = node.get(key)
		var raw_v: Variant = props[key]
		var restored: Variant = _json_to_variant(raw_v, typeof(current))
		# _json_to_variant returns null for markers it can't reconstruct
		# (Object refs, Transform2D/3D, Basis, Quaternion, Plane, AABB).
		# In those cases the saved value was non-null but we have nothing
		# safe to write, so leave the live reference alone.
		if restored == null and raw_v != null:
			continue
		node.set(key, restored)

#endregion

#region Helpers - variant / json round-tripping

func _variant_to_json(value: Variant) -> Variant:
	var t := typeof(value)
	match t:
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING, TYPE_STRING_NAME:
			return value
		TYPE_VECTOR2, TYPE_VECTOR2I:
			return {"type": "Vector2", "x": value.x, "y": value.y}
		TYPE_VECTOR3, TYPE_VECTOR3I:
			return {"type": "Vector3", "x": value.x, "y": value.y, "z": value.z}
		TYPE_VECTOR4, TYPE_VECTOR4I:
			return {"type": "Vector4", "x": value.x, "y": value.y, "z": value.z, "w": value.w}
		TYPE_RECT2, TYPE_RECT2I:
			return {"type": "Rect2", "x": value.position.x, "y": value.position.y, "w": value.size.x, "h": value.size.y}
		TYPE_COLOR:
			return {"type": "Color", "r": value.r, "g": value.g, "b": value.b, "a": value.a}
		TYPE_NODE_PATH:
			return {"type": "NodePath", "path": String(value)}
		TYPE_TRANSFORM2D, TYPE_TRANSFORM3D, TYPE_BASIS, TYPE_QUATERNION, TYPE_PLANE, TYPE_AABB:
			return {"type": type_string(t), "str": str(value)}
		TYPE_OBJECT:
			if value == null:
				return null
			var obj: Object = value
			var res: Resource = obj as Resource
			if res and res.resource_path != "":
				return {"type": "Resource", "class": res.get_class(), "path": res.resource_path}
			return {"type": "Object", "class": obj.get_class()}
		TYPE_ARRAY, TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_STRING_ARRAY, TYPE_PACKED_VECTOR2_ARRAY, TYPE_PACKED_VECTOR3_ARRAY, TYPE_PACKED_COLOR_ARRAY:
			var arr_out: Array = []
			for item in value:
				arr_out.append(_variant_to_json(item))
			return arr_out
		TYPE_DICTIONARY:
			var dict_out: Dictionary = {}
			for k in value.keys():
				dict_out[str(k)] = _variant_to_json(value[k])
			return dict_out
		_:
			return str(value)

func _json_to_variant(raw: Variant, hint_type: int = TYPE_NIL) -> Variant:
	if raw == null:
		return null
	var t := typeof(raw)
	if t == TYPE_BOOL or t == TYPE_INT or t == TYPE_FLOAT or t == TYPE_STRING or t == TYPE_STRING_NAME:
		# Coerce common numeric/string mismatches back to the live type so
		# Vector / int / float fields accept JSON's looser numeric model.
		match hint_type:
			TYPE_INT: return int(raw)
			TYPE_FLOAT: return float(raw)
			TYPE_STRING: return String(raw)
			TYPE_STRING_NAME: return StringName(String(raw))
		return raw
	if raw is Array:
		var arr_in: Array = raw
		var out: Array = []
		for item in arr_in:
			out.append(_json_to_variant(item))
		return out
	if raw is Dictionary:
		var d: Dictionary = raw
		var marker: String = String(d.get("type", ""))
		match marker:
			"Vector2":
				return Vector2(float(d.get("x", 0)), float(d.get("y", 0)))
			"Vector3":
				return Vector3(float(d.get("x", 0)), float(d.get("y", 0)), float(d.get("z", 0)))
			"Vector4":
				return Vector4(float(d.get("x", 0)), float(d.get("y", 0)), float(d.get("z", 0)), float(d.get("w", 0)))
			"Rect2":
				return Rect2(float(d.get("x", 0)), float(d.get("y", 0)), float(d.get("w", 0)), float(d.get("h", 0)))
			"Color":
				return Color(float(d.get("r", 0)), float(d.get("g", 0)), float(d.get("b", 0)), float(d.get("a", 1)))
			"NodePath":
				return NodePath(String(d.get("path", "")))
			"Resource":
				var rp: String = String(d.get("path", ""))
				if rp != "" and ResourceLoader.exists(rp):
					return load(rp)
				return null
			"Object":
				# Plain Object references can't be reconstructed safely; leave
				# the live ref untouched by signalling failure to the caller.
				return null
			"Transform2D", "Transform3D", "Basis", "Quaternion", "Plane", "AABB":
				# Stringified math types aren't worth reparsing here; preserve
				# the live value by returning the marker dict back, which
				# _apply_properties guards against assigning.
				return null
		var out_d: Dictionary = {}
		for k in d.keys():
			out_d[k] = _json_to_variant(d[k])
		return out_d
	return raw

#endregion

#region Helpers - paths / files / scene root

func _get_scene_root() -> Node:
	if Engine.is_editor_hint():
		return EditorInterface.get_edited_scene_root()
	var tree := Engine.get_main_loop() as SceneTree
	if not tree:
		return null
	if tree.current_scene:
		return tree.current_scene
	return tree.root

func _resolve_relative(scene_root: Node, rel: String) -> Node:
	if rel.is_empty() or rel == ".":
		return scene_root
	return scene_root.get_node_or_null(rel)

func _relative_path(scene_root: Node, node: Node) -> String:
	if node == scene_root:
		return ""
	if not scene_root.is_ancestor_of(node):
		return ""
	var rel: String = String(scene_root.get_path_to(node))
	return "" if rel == "." else rel

func _slot_path(slot_id: String) -> String:
	return _SLOTS_DIR.path_join("%s.json" % slot_id)

func _ensure_slots_dir() -> String:
	if DirAccess.dir_exists_absolute(_SLOTS_DIR):
		return ""
	var err: int = DirAccess.make_dir_recursive_absolute(_SLOTS_DIR)
	if err != OK:
		return "Failed to create slots dir %s (err %d)" % [_SLOTS_DIR, err]
	return ""

func _validate_slot_id(slot_id: String) -> String:
	if slot_id.is_empty():
		return "slot_id must not be empty"
	if slot_id == "all":
		return "'all' is reserved (used by slot_delete)"
	for ch in slot_id:
		var c: String = ch
		var ok: bool = (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or (c >= "0" and c <= "9") or c == "_" or c == "-" or c == "."
		if not ok:
			return "slot_id may only contain [A-Za-z0-9_.-]: %s" % slot_id
	if slot_id.begins_with("."):
		return "slot_id must not start with '.'"
	return ""

func _read_slot(slot_path: String) -> Variant:
	if not FileAccess.file_exists(slot_path):
		return "Slot file not found: %s" % slot_path
	var f := FileAccess.open(slot_path, FileAccess.READ)
	if not f:
		return "Cannot open slot file: %s" % slot_path
	var text: String = f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	if parsed == null:
		return "Slot file is not valid JSON: %s" % slot_path
	if not (parsed is Dictionary):
		return "Slot file root must be an object: %s" % slot_path
	return parsed

func _read_slot_timestamp(slot_path: String) -> int:
	var f := FileAccess.open(slot_path, FileAccess.READ)
	if not f:
		return 0
	var text: String = f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	if parsed is Dictionary:
		return int((parsed as Dictionary).get("timestamp", 0))
	return 0

func _count_slot_nodes(entry: Dictionary) -> int:
	var total: int = 1
	var kids: Array = entry.get("children", [])
	for c in kids:
		if c is Dictionary:
			total += _count_slot_nodes(c)
	return total

func _count_dynamic_nodes(entry: Dictionary) -> int:
	var total: int = 1 if bool(entry.get("dynamic", false)) else 0
	var kids: Array = entry.get("children", [])
	for c in kids:
		if c is Dictionary:
			total += _count_dynamic_nodes(c)
	return total

func _file_size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if not f:
		return 0
	var n := f.get_length()
	f.close()
	return int(n)

func _format_timestamp(ts: int) -> String:
	if ts <= 0:
		return "<unknown>"
	return Time.get_datetime_string_from_unix_time(ts, true)

#endregion

#region Helpers - formatting

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

#endregion

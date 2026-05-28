@tool
class_name DebugConsoleImportExportCommands extends RefCounted

# Import/export commands. Auto-loaded by the extensions loader; the
# orchestrator (BuiltInCommands.register_universal_commands) instantiates one
# of these and keeps a strong reference in BuiltInCommands._t6_keepalive so
# the Callables stay alive for the plugin's lifetime.
#
# Mirrors the shape of SceneCommands.gd: same color palette, same helper
# semantics (_resolve_node / _get_scene_root / _format_error / _format_success),
# same "both" context registration so commands work in editor and runtime.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"

const _PROJECT_FILES: PackedStringArray = [
	"res://project.godot",
	"res://icon.svg",
	"res://icon.png",
	"res://README.md",
	"res://AGENTS.md",
	"res://CLAUDE.md",
	"res://.gdignore",
]

const _MAX_ZIP_ENTRY_BYTES: int = 64 * 1024 * 1024

var _registry: Node
var _core: Node

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("export_scene", _cmd_export_scene, "Pack a node subtree as a PackedScene: export_scene <node_path> <user://out.tscn>", "both")
	_registry.register_command("export_node_tree", _cmd_export_node_tree, "Dump node tree (class + storage props + children) as JSON: export_node_tree <node_path> <user://out.json>", "both")
	_registry.register_command("import_tscn", _cmd_import_tscn, "Instance a .tscn and add it to the current scene: import_tscn <res://path.tscn> [parent_path]", "both")
	_registry.register_command("export_project_files", _cmd_export_project_files, "Zip an addon directory + key project files: export_project_files <user://out.zip> [addon_name]", "both")
	_registry.register_command("export_scripts", _cmd_export_scripts, "Zip every .gd file under a directory (recursive): export_scripts <res://dir> <user://out.zip>", "both")
	_registry.register_command("import_zip", _cmd_import_zip, "Unpack a zip archive into a target directory: import_zip <user://file.zip> <res://target_dir>", "both")

#region Command implementations

func _cmd_export_scene(args: Array, _piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: export_scene <node_path> <user://out.tscn>")
	var node_path := str(args[0]).strip_edges()
	var out_path := str(args[1]).strip_edges()
	if not (out_path.begins_with("user://") or out_path.begins_with("res://")):
		return _format_error("Output path must start with user:// or res://")

	var node: Node = _resolve_node(node_path)
	if not node:
		return _format_error("Node not found: %s" % node_path)

	var saved_owners: Dictionary = {}
	_snapshot_owners(node, saved_owners)
	_assign_owner_recursive(node, node)
	# The packed root itself must have owner == null for PackedScene.pack to
	# treat it as the scene root rather than a foreign-owned child.
	node.owner = null

	var packed := PackedScene.new()
	var pack_err: int = packed.pack(node)
	_restore_owners(saved_owners)
	if pack_err != OK:
		return _format_error("PackedScene.pack failed (err %d)" % pack_err)

	var save_err: int = ResourceSaver.save(packed, out_path)
	if save_err != OK:
		return _format_error("ResourceSaver.save failed (err %d) at %s" % [save_err, out_path])

	var byte_count: int = _file_size(out_path)
	return _format_success("Exported %s to %s (%s bytes)" % [
		_color_path(str(node.get_path()) if node.is_inside_tree() else node.name),
		_color_path(out_path),
		_color_number(str(byte_count)),
	])

func _cmd_export_node_tree(args: Array, _piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: export_node_tree <node_path> <user://out.json>")
	var node_path := str(args[0]).strip_edges()
	var out_path := str(args[1]).strip_edges()
	if not (out_path.begins_with("user://") or out_path.begins_with("res://")):
		return _format_error("Output path must start with user:// or res://")

	var node: Node = _resolve_node(node_path)
	if not node:
		return _format_error("Node not found: %s" % node_path)

	var tree_dict: Dictionary = _node_to_dict(node)
	var json_text := JSON.stringify(tree_dict, "\t")
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	if not f:
		return _format_error("Cannot open for write: %s (err %d)" % [out_path, FileAccess.get_open_error()])
	f.store_string(json_text)
	f.close()

	var nodes_dumped: int = _count_dict_nodes(tree_dict)
	return _format_success("Dumped %s nodes from %s to %s" % [
		_color_number(str(nodes_dumped)),
		_color_path(node_path),
		_color_path(out_path),
	])

func _cmd_import_tscn(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: import_tscn <res://path.tscn> [parent_path]")
	var scene_path := str(args[0]).strip_edges()
	var parent_path := str(args[1]).strip_edges() if args.size() > 1 else ""

	if not ResourceLoader.exists(scene_path):
		return _format_error("Scene not found: %s" % scene_path)
	var packed := load(scene_path) as PackedScene
	if not packed:
		return _format_error("Not a PackedScene: %s" % scene_path)
	var instance: Node = packed.instantiate()
	if not instance:
		return _format_error("Failed to instantiate: %s" % scene_path)

	var parent: Node
	if parent_path.is_empty():
		parent = _get_default_parent()
	else:
		parent = _resolve_node(parent_path)
	if not parent:
		instance.free()
		return _format_error("Parent not found: %s" % (parent_path if not parent_path.is_empty() else "<default>"))

	parent.add_child(instance)
	if Engine.is_editor_hint():
		var root := _get_scene_root()
		if root and instance != root:
			instance.owner = root
			_assign_owner_recursive(instance, root)

	var added_path: String = str(instance.get_path()) if instance.is_inside_tree() else instance.name
	return _format_success("Imported %s as %s" % [_color_path(scene_path), _color_path(added_path)])

func _cmd_export_project_files(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: export_project_files <user://out.zip> [addon_name]")
	var out_path := str(args[0]).strip_edges()
	if not (out_path.begins_with("user://") or out_path.begins_with("res://")):
		return _format_error("Output path must start with user:// or res://")

	var addon_name := str(args[1]).strip_edges() if args.size() > 1 else ""
	var addon_dirs: Array[String] = []
	if addon_name.is_empty():
		addon_dirs = _list_dirs("res://addons")
	else:
		var single := "res://addons/%s" % addon_name
		if DirAccess.dir_exists_absolute(single):
			addon_dirs.append(single)
		else:
			return _format_error("Addon dir not found: %s" % single)

	var packer := ZIPPacker.new()
	var open_err: int = packer.open(out_path)
	if open_err != OK:
		return _format_error("ZIPPacker.open failed (err %d) at %s" % [open_err, out_path])

	var written: int = 0
	var skipped: int = 0
	for addon_dir in addon_dirs:
		var pair := _pack_dir_into_zip(packer, addon_dir, "", PackedStringArray())
		written += pair[0]
		skipped += pair[1]

	for proj_file in _PROJECT_FILES:
		if not FileAccess.file_exists(proj_file):
			continue
		var rel := proj_file.substr("res://".length())
		if _pack_single_file(packer, proj_file, rel):
			written += 1
		else:
			skipped += 1

	packer.close()
	var byte_count: int = _file_size(out_path)
	return _format_success("Zipped %s files (%s skipped) into %s (%s bytes)" % [
		_color_number(str(written)),
		_color_number(str(skipped)),
		_color_path(out_path),
		_color_number(str(byte_count)),
	])

func _cmd_export_scripts(args: Array, _piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: export_scripts <res://dir> <user://out.zip>")
	var src_dir := str(args[0]).strip_edges()
	var out_path := str(args[1]).strip_edges()
	if not (src_dir.begins_with("res://") or src_dir.begins_with("user://")):
		return _format_error("Source dir must start with res:// or user://")
	if not (out_path.begins_with("user://") or out_path.begins_with("res://")):
		return _format_error("Output path must start with user:// or res://")
	if not DirAccess.dir_exists_absolute(src_dir):
		return _format_error("Directory not found: %s" % src_dir)

	var packer := ZIPPacker.new()
	var open_err: int = packer.open(out_path)
	if open_err != OK:
		return _format_error("ZIPPacker.open failed (err %d) at %s" % [open_err, out_path])

	var only_gd := PackedStringArray(["gd"])
	var pair := _pack_dir_into_zip(packer, src_dir, "", only_gd)
	packer.close()

	var byte_count: int = _file_size(out_path)
	return _format_success("Zipped %s .gd files (%s skipped) into %s (%s bytes)" % [
		_color_number(str(pair[0])),
		_color_number(str(pair[1])),
		_color_path(out_path),
		_color_number(str(byte_count)),
	])

func _cmd_import_zip(args: Array, _piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: import_zip <user://file.zip> <res://target_dir>")
	var zip_path := str(args[0]).strip_edges()
	var target_dir := str(args[1]).strip_edges()
	if not FileAccess.file_exists(zip_path):
		return _format_error("Zip file not found: %s" % zip_path)
	if not (target_dir.begins_with("res://") or target_dir.begins_with("user://")):
		return _format_error("Target dir must start with res:// or user://")

	if not DirAccess.dir_exists_absolute(target_dir):
		var mk_err: int = DirAccess.make_dir_recursive_absolute(target_dir)
		if mk_err != OK:
			return _format_error("Cannot create target dir %s (err %d)" % [target_dir, mk_err])

	var reader := ZIPReader.new()
	var open_err: int = reader.open(zip_path)
	if open_err != OK:
		return _format_error("ZIPReader.open failed (err %d) at %s" % [open_err, zip_path])

	var written: int = 0
	var skipped: int = 0
	var base := target_dir
	if not base.ends_with("/"):
		base += "/"

	for entry in reader.get_files():
		if entry.ends_with("/"):
			continue
		var clean: String = _sanitize_zip_entry(entry)
		if clean.is_empty():
			skipped += 1
			continue
		var dest := base + clean
		var dest_dir := dest.get_base_dir()
		if not DirAccess.dir_exists_absolute(dest_dir):
			var mk_err2: int = DirAccess.make_dir_recursive_absolute(dest_dir)
			if mk_err2 != OK:
				skipped += 1
				continue
		var bytes: PackedByteArray = reader.read_file(entry)
		var out := FileAccess.open(dest, FileAccess.WRITE)
		if not out:
			skipped += 1
			continue
		out.store_buffer(bytes)
		out.close()
		written += 1

	reader.close()
	return _format_success("Extracted %s files (%s skipped) into %s" % [
		_color_number(str(written)),
		_color_number(str(skipped)),
		_color_path(target_dir),
	])

#endregion

#region Helpers - serialization

func _node_to_dict(node: Node) -> Dictionary:
	var props: Dictionary = {}
	for entry in node.get_property_list():
		var usage: int = int(entry.get("usage", 0))
		if (usage & PROPERTY_USAGE_STORAGE) == 0:
			continue
		var pname: String = String(entry.get("name", ""))
		if pname.is_empty() or pname.begins_with("_"):
			continue
		# Skip noisy internals that bloat the JSON without explaining the node.
		if pname in ["script", "owner", "multiplayer"]:
			continue
		var value: Variant = node.get(pname)
		props[pname] = _variant_to_json(value)

	var dict: Dictionary = {
		"name": node.name,
		"class": node.get_class(),
		"properties": props,
	}
	var script: Script = node.get_script() as Script
	if script:
		dict["script"] = script.resource_path
	if node.scene_file_path != "":
		dict["scene_file_path"] = node.scene_file_path

	var kids: Array = []
	for child in node.get_children():
		kids.append(_node_to_dict(child))
	dict["children"] = kids
	return dict

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

func _count_dict_nodes(d: Dictionary) -> int:
	var total: int = 1
	var kids: Array = d.get("children", [])
	for c in kids:
		if c is Dictionary:
			total += _count_dict_nodes(c)
	return total

#endregion

#region Helpers - owner snapshot

func _snapshot_owners(node: Node, into: Dictionary) -> void:
	into[node] = node.owner
	for child in node.get_children():
		_snapshot_owners(child, into)

func _assign_owner_recursive(root: Node, owner_node: Node) -> void:
	for child in root.get_children():
		child.owner = owner_node
		_assign_owner_recursive(child, owner_node)

func _restore_owners(saved: Dictionary) -> void:
	for n in saved.keys():
		if n is Node and is_instance_valid(n):
			n.owner = saved[n]

#endregion

#region Helpers - zip / fs

func _pack_dir_into_zip(packer: ZIPPacker, src_root: String, zip_prefix: String, ext_filter: PackedStringArray) -> Array:
	var written: int = 0
	var skipped: int = 0
	var root_name := src_root.get_file()
	var prefix: String = zip_prefix
	if prefix.is_empty():
		prefix = root_name
	var stack: Array = [{"abs": src_root, "rel": prefix}]
	while not stack.is_empty():
		var entry: Dictionary = stack.pop_back()
		var abs_dir: String = entry["abs"]
		var rel_dir: String = entry["rel"]
		var dir := DirAccess.open(abs_dir)
		if not dir:
			skipped += 1
			continue
		dir.list_dir_begin()
		while true:
			var name := dir.get_next()
			if name == "":
				break
			if name == "." or name == "..":
				continue
			var abs_path: String = abs_dir.path_join(name)
			var rel_path: String = rel_dir.path_join(name)
			if dir.current_is_dir():
				stack.append({"abs": abs_path, "rel": rel_path})
				continue
			if ext_filter.size() > 0:
				var ext := name.get_extension().to_lower()
				if not ext_filter.has(ext):
					skipped += 1
					continue
			if _pack_single_file(packer, abs_path, rel_path):
				written += 1
			else:
				skipped += 1
		dir.list_dir_end()
	return [written, skipped]

func _pack_single_file(packer: ZIPPacker, abs_path: String, rel_path: String) -> bool:
	var f := FileAccess.open(abs_path, FileAccess.READ)
	if not f:
		return false
	var size := f.get_length()
	if size > _MAX_ZIP_ENTRY_BYTES:
		f.close()
		return false
	var bytes: PackedByteArray = f.get_buffer(size)
	f.close()
	var start_err: int = packer.start_file(rel_path)
	if start_err != OK:
		return false
	var write_err: int = packer.write_file(bytes)
	packer.close_file()
	return write_err == OK

func _sanitize_zip_entry(entry: String) -> String:
	var s := entry.replace("\\", "/")
	while s.begins_with("/"):
		s = s.substr(1)
	if s.contains("../") or s == ".." or s.begins_with("../"):
		return ""
	return s

func _list_dirs(parent: String) -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(parent)
	if not dir:
		return out
	dir.list_dir_begin()
	while true:
		var name := dir.get_next()
		if name == "":
			break
		if name == "." or name == "..":
			continue
		if dir.current_is_dir():
			out.append(parent.path_join(name))
	dir.list_dir_end()
	return out

func _file_size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if not f:
		return -1
	var size := f.get_length()
	f.close()
	return size

#endregion

#region Helpers - scene resolution / formatting (mirror SceneCommands)

func _get_scene_root() -> Node:
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

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

#endregion

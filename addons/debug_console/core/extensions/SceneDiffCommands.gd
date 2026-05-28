@tool
class_name DebugConsoleSceneDiffCommands extends RefCounted

# Tier 8 extension - structural scene diffing.
# Parses .tscn files via ConfigFile (no git, no external diff tools) and
# reports node / connection deltas. Also captures lightweight in-memory
# snapshots of the live scene tree so structural drift can be tracked
# across a single editor/runtime session.
#
# Mirrors the shape of core/SceneCommands.gd (RefCounted module with
# register_commands(registry, core)). The orchestrator picks this file
# up via the extensions auto-loader in BuiltInCommands.gd and keeps a
# strong reference in _t8_extensions so the registered Callables stay
# valid for the plugin lifetime.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_DEL := "#FF6666"
const _COLOR_ADD := "#66FF66"
const _COLOR_HUNK := "#C586C0"
const _COLOR_DIM := "#888888"

const _LIVE_TMP_PATH := "user://_debug_console_scene_diff_live.tscn"
const _MAX_SNAPSHOTS := 64

var _registry: Node
var _core: Node

# name -> snapshot dict {name, timestamp, source, nodes, connections}
var _snapshots: Dictionary = {}
var _snap_counter: int = 0

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("scene_diff", _cmd_scene_diff, "Structural diff between two .tscn files: scene_diff <res://a.tscn> <res://b.tscn>", "both")
	_registry.register_command("scene_diff_live", _cmd_scene_diff_live, "Diff disk .tscn vs current edited scene: scene_diff_live <res://a.tscn>", "both")
	_registry.register_command("scene_snapshot", _cmd_scene_snapshot, "Record structural snapshot of current scene (node tree + connections): scene_snapshot [name]", "both")
	_registry.register_command("scene_snap_diff", _cmd_scene_snap_diff, "Diff two structural snapshots: scene_snap_diff <a> <b>", "both")
	_registry.register_command("scene_snap_drop", _cmd_scene_snap_drop, "Drop a snapshot, or 'all': scene_snap_drop <name|all>", "both")
	_registry.register_command("scene_snap_export", _cmd_scene_snap_export, "Export a snapshot to JSON: scene_snap_export <name> <user://path.json>", "both")

#region Command implementations

func _cmd_scene_diff(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: scene_diff <res://a.tscn> <res://b.tscn>")
	var path_a := _normalize_path(str(args[0]))
	var path_b := _normalize_path(str(args[1]))
	if not FileAccess.file_exists(path_a):
		return _format_error("Not found: %s" % path_a)
	if not FileAccess.file_exists(path_b):
		return _format_error("Not found: %s" % path_b)
	var model_a := _load_tscn_model(path_a)
	if model_a.has("error"):
		return _format_error("Parse failed for %s: %s" % [path_a, model_a["error"]])
	var model_b := _load_tscn_model(path_b)
	if model_b.has("error"):
		return _format_error("Parse failed for %s: %s" % [path_b, model_b["error"]])
	return _render_diff(model_a, model_b, path_a, path_b, true)

func _cmd_scene_diff_live(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: scene_diff_live <res://a.tscn>")
	var disk_path := _normalize_path(str(args[0]))
	if not FileAccess.file_exists(disk_path):
		return _format_error("Not found: %s" % disk_path)
	var live_root := _get_scene_root()
	if not live_root:
		return _format_error("No edited/current scene available to compare against")
	var packed := PackedScene.new()
	var pack_err: int = packed.pack(live_root)
	if pack_err != OK:
		return _format_error("Could not pack live scene (err %d)" % pack_err)
	var save_err: int = ResourceSaver.save(packed, _LIVE_TMP_PATH)
	if save_err != OK:
		return _format_error("Could not save temp tscn at %s (err %d)" % [_LIVE_TMP_PATH, save_err])

	var model_disk := _load_tscn_model(disk_path)
	var model_live := _load_tscn_model(_LIVE_TMP_PATH)
	_remove_tmp_file(_LIVE_TMP_PATH)

	if model_disk.has("error"):
		return _format_error("Parse failed for %s: %s" % [disk_path, model_disk["error"]])
	if model_live.has("error"):
		return _format_error("Parse failed for live snapshot: %s" % model_live["error"])
	var live_label := "<live:%s>" % str(live_root.name)
	return _render_diff(model_disk, model_live, disk_path, live_label, true)

func _cmd_scene_snapshot(args: Array, piped_input: String = "") -> String:
	var root := _get_scene_root()
	if not root:
		return _format_error("No scene available to snapshot")
	var snap_name: String = ""
	if not args.is_empty():
		snap_name = str(args[0]).strip_edges()
	if snap_name.is_empty():
		_snap_counter += 1
		snap_name = "snap_%d" % _snap_counter
	var snap := _build_live_snapshot(root, snap_name)
	_snapshots[snap_name] = snap
	while _snapshots.size() > _MAX_SNAPSHOTS:
		var first_key = _snapshots.keys()[0]
		_snapshots.erase(first_key)
	return _format_success("Snapshot %s saved  (%s nodes, %s connections, source %s)" % [
		_color_path(snap_name),
		_color_number(str((snap["nodes"] as Dictionary).size())),
		_color_number(str((snap["connections"] as Dictionary).size())),
		_color_dim(str(snap["source"])),
	])

func _cmd_scene_snap_diff(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: scene_snap_diff <a> <b>")
	var name_a := str(args[0]).strip_edges()
	var name_b := str(args[1]).strip_edges()
	if not _snapshots.has(name_a):
		return _format_error("Snapshot not found: %s" % name_a)
	if not _snapshots.has(name_b):
		return _format_error("Snapshot not found: %s" % name_b)
	var snap_a: Dictionary = _snapshots[name_a]
	var snap_b: Dictionary = _snapshots[name_b]
	return _render_diff(snap_a, snap_b, "snap:" + name_a, "snap:" + name_b, false)

func _cmd_scene_snap_drop(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: scene_snap_drop <name|all>")
	var target := str(args[0]).strip_edges()
	if target == "all":
		var n: int = _snapshots.size()
		_snapshots.clear()
		return _format_success("Dropped %s snapshot(s)" % _color_number(str(n)))
	if not _snapshots.has(target):
		return _format_error("Snapshot not found: %s" % target)
	_snapshots.erase(target)
	return _format_success("Dropped snapshot %s" % _color_path(target))

func _cmd_scene_snap_export(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: scene_snap_export <name> <user://path.json>")
	var name := str(args[0]).strip_edges()
	var out_path := _normalize_path(str(args[1]))
	if not _snapshots.has(name):
		return _format_error("Snapshot not found: %s" % name)
	if not (out_path.begins_with("user://") or out_path.begins_with("res://") or out_path.begins_with("/")):
		return _format_error("Path must start with user://, res://, or '/': %s" % out_path)
	var fa := FileAccess.open(out_path, FileAccess.WRITE)
	if not fa:
		var err: int = FileAccess.get_open_error()
		return _format_error("Cannot write %s (error %d)" % [out_path, err])
	var snap: Dictionary = _snapshots[name]
	fa.store_string(JSON.stringify(snap, "  "))
	fa.close()
	var size: int = 0
	var fa2 := FileAccess.open(out_path, FileAccess.READ)
	if fa2:
		size = int(fa2.get_length())
		fa2.close()
	return _format_success("Exported %s -> %s  (%s bytes)" % [
		_color_path(name), _color_path(out_path), _color_number(str(size)),
	])

#endregion

#region Model building

# Loads a .tscn via ConfigFile and produces a comparable model:
#   {nodes: {id -> {class, parent, name, properties}},
#    connections: {id -> {signal, from, to, method, properties}}}
# On failure returns {error: msg}.
func _load_tscn_model(path: String) -> Dictionary:
	var cf := ConfigFile.new()
	var err: int = cf.load(path)
	if err != OK:
		return {"error": "ConfigFile.load returned %d" % err}
	var nodes: Dictionary = {}
	var connections: Dictionary = {}
	for section in cf.get_sections():
		if section.begins_with("node "):
			var attrs := _parse_section_attrs(section)
			var node_name: String = str(attrs.get("name", ""))
			if node_name.is_empty():
				continue
			var parent: String = str(attrs.get("parent", ""))
			var type_name: String = str(attrs.get("type", attrs.get("instance_placeholder", "")))
			var node_id := _node_id(parent, node_name)
			var props: Dictionary = {}
			for key in cf.get_section_keys(section):
				props[str(key)] = _stringify_value(cf.get_value(section, key))
			nodes[node_id] = {
				"class": type_name,
				"parent": parent,
				"name": node_name,
				"properties": props,
			}
		elif section.begins_with("connection "):
			var attrs := _parse_section_attrs(section)
			var sig: String = str(attrs.get("signal", ""))
			var src: String = str(attrs.get("from", ""))
			var dst: String = str(attrs.get("to", ""))
			var method: String = str(attrs.get("method", ""))
			var cid := "%s::%s->%s::%s" % [sig, src, dst, method]
			var props: Dictionary = {}
			for key in cf.get_section_keys(section):
				props[str(key)] = _stringify_value(cf.get_value(section, key))
			connections[cid] = {
				"signal": sig,
				"from": src,
				"to": dst,
				"method": method,
				"properties": props,
			}
	return {"nodes": nodes, "connections": connections}

# Parses the body of a section header like 'node name="X" type="Y" parent="."'
# into {key:value} string pairs. The leading section verb is discarded.
func _parse_section_attrs(section: String) -> Dictionary:
	var attrs: Dictionary = {}
	var s := section.strip_edges()
	var space := s.find(" ")
	if space < 0:
		return attrs
	var rest := s.substr(space + 1)
	var i: int = 0
	var n: int = rest.length()
	while i < n:
		while i < n and rest[i] == " ":
			i += 1
		if i >= n:
			break
		var key_start: int = i
		while i < n and rest[i] != "=" and rest[i] != " ":
			i += 1
		if i >= n or rest[i] != "=":
			# Malformed token; skip to next space.
			while i < n and rest[i] != " ":
				i += 1
			continue
		var key: String = rest.substr(key_start, i - key_start)
		i += 1  # consume '='
		var value: String = ""
		if i < n and rest[i] == "\"":
			i += 1
			var v_start: int = i
			while i < n and rest[i] != "\"":
				# Tolerate escaped quotes inside the value.
				if rest[i] == "\\" and i + 1 < n:
					i += 2
					continue
				i += 1
			value = rest.substr(v_start, i - v_start)
			if i < n:
				i += 1  # consume closing quote
		else:
			var v_start2: int = i
			while i < n and rest[i] != " ":
				i += 1
			value = rest.substr(v_start2, i - v_start2)
		attrs[key] = value
	return attrs

# Identity for a node entry; mirrors the .tscn parent/name scheme so a
# live-snapshot id and a ConfigFile id compare equal for the same node.
#   root           -> "<root:Name>"
#   parent == "."  -> "/Name"
#   nested         -> "/Parent/Name" or "/A/B/Name"
func _node_id(parent: String, node_name: String) -> String:
	if parent.is_empty():
		return "<root:%s>" % node_name
	if parent == ".":
		return "/" + node_name
	return "/" + parent + "/" + node_name

# Build a structural snapshot from a live scene tree.
# Properties are intentionally omitted (snapshots are about structure, not
# inspector state) so the diff stays focused and cheap.
func _build_live_snapshot(root: Node, snap_name: String) -> Dictionary:
	var nodes: Dictionary = {}
	var connections: Dictionary = {}
	_walk_snapshot(root, root, nodes, connections, ".")
	var src: String = "<live:%s>" % str(root.name)
	if "scene_file_path" in root:
		var sfp: String = str(root.scene_file_path)
		if not sfp.is_empty():
			src = sfp
	return {
		"name": snap_name,
		"timestamp": int(Time.get_unix_time_from_system()),
		"source": src,
		"nodes": nodes,
		"connections": connections,
	}

func _walk_snapshot(root: Node, node: Node, nodes: Dictionary, connections: Dictionary, parent_path: String) -> void:
	var node_name: String = str(node.name)
	var node_id: String
	var parent_for_id: String
	if node == root:
		parent_for_id = ""
		node_id = _node_id("", node_name)
	else:
		parent_for_id = parent_path
		node_id = _node_id(parent_path, node_name)
	nodes[node_id] = {
		"class": node.get_class(),
		"parent": parent_for_id,
		"name": node_name,
		"properties": {},
	}
	for sig_info in node.get_signal_list():
		var sig_name: String = str(sig_info.get("name", ""))
		if sig_name.is_empty():
			continue
		for c in node.get_signal_connection_list(sig_name):
			var cb: Callable = c.get("callable", Callable())
			if not cb.is_valid():
				continue
			var target: Object = cb.get_object()
			var method: String = str(cb.get_method())
			var src_path: String = _live_relative_path(root, node)
			var dst_path: String = "<external>"
			if target is Node:
				dst_path = _live_relative_path(root, target)
			var cid := "%s::%s->%s::%s" % [sig_name, src_path, dst_path, method]
			connections[cid] = {
				"signal": sig_name,
				"from": src_path,
				"to": dst_path,
				"method": method,
				"properties": {},
			}
	var child_parent_path: String
	if node == root:
		child_parent_path = "."
	elif parent_path == ".":
		child_parent_path = node_name
	else:
		child_parent_path = parent_path + "/" + node_name
	for child in node.get_children():
		_walk_snapshot(root, child, nodes, connections, child_parent_path)

# Mirrors how .tscn writes parent attrs:
#   root        -> "."
#   direct kid  -> "Name"
#   deeper      -> "A/B/Name"
func _live_relative_path(root: Node, target: Node) -> String:
	if target == root:
		return "."
	if not target.is_inside_tree() or not root.is_ancestor_of(target):
		return str(target.name)
	return str(root.get_path_to(target))

#endregion

#region Diff rendering

# Diffs two models (either both from .tscn or both from live snapshots).
# include_properties=true emits per-property add/remove/change lines (only
# meaningful for ConfigFile-sourced models which carry property dicts).
func _render_diff(a: Dictionary, b: Dictionary, label_a: String, label_b: String, include_properties: bool) -> String:
	var nodes_a: Dictionary = a.get("nodes", {})
	var nodes_b: Dictionary = b.get("nodes", {})
	var conns_a: Dictionary = a.get("connections", {})
	var conns_b: Dictionary = b.get("connections", {})

	var node_added: Array[String] = []
	var node_removed: Array[String] = []
	var node_changed: Array[String] = []
	for id in nodes_a.keys():
		if not nodes_b.has(id):
			node_removed.append(str(id))
	for id in nodes_b.keys():
		if not nodes_a.has(id):
			node_added.append(str(id))
		elif _nodes_differ(nodes_a[id], nodes_b[id], include_properties):
			node_changed.append(str(id))

	var conn_added: Array[String] = []
	var conn_removed: Array[String] = []
	for id in conns_a.keys():
		if not conns_b.has(id):
			conn_removed.append(str(id))
	for id in conns_b.keys():
		if not conns_a.has(id):
			conn_added.append(str(id))

	node_added.sort()
	node_removed.sort()
	node_changed.sort()
	conn_added.sort()
	conn_removed.sort()

	var out: Array[String] = []
	out.append("%s %s" % [_color_dim("---"), _color_path("a/" + label_a)])
	out.append("%s %s" % [_color_dim("+++"), _color_path("b/" + label_b)])
	out.append("%s %s" % [_color_dim("summary:"), _summary_line(node_added.size(), node_removed.size(), node_changed.size(), conn_added.size(), conn_removed.size())])

	var anything: bool = not (node_added.is_empty() and node_removed.is_empty() and node_changed.is_empty() and conn_added.is_empty() and conn_removed.is_empty())
	if not anything:
		out.append(_color_dim("(no structural differences)"))
		return "\n".join(out)

	if not (node_added.is_empty() and node_removed.is_empty() and node_changed.is_empty()):
		out.append("[color=%s]@@ nodes @@[/color]" % _COLOR_HUNK)
		for id in node_removed:
			var rec: Dictionary = nodes_a[id]
			out.append("[color=%s]- %s  (%s)[/color]" % [
				_COLOR_DEL, _escape_bbcode(str(id)), _escape_bbcode(str(rec.get("class", "")))
			])
		for id in node_added:
			var rec: Dictionary = nodes_b[id]
			out.append("[color=%s]+ %s  (%s)[/color]" % [
				_COLOR_ADD, _escape_bbcode(str(id)), _escape_bbcode(str(rec.get("class", "")))
			])
		for id in node_changed:
			out.append("  ~ %s" % _escape_bbcode(str(id)))
			_emit_node_change(out, nodes_a[id], nodes_b[id], include_properties)

	if not (conn_added.is_empty() and conn_removed.is_empty()):
		out.append("[color=%s]@@ connections @@[/color]" % _COLOR_HUNK)
		for id in conn_removed:
			var c: Dictionary = conns_a[id]
			out.append("[color=%s]- %s: %s -> %s::%s[/color]" % [
				_COLOR_DEL,
				_escape_bbcode(str(c["signal"])),
				_escape_bbcode(str(c["from"])),
				_escape_bbcode(str(c["to"])),
				_escape_bbcode(str(c["method"])),
			])
		for id in conn_added:
			var c: Dictionary = conns_b[id]
			out.append("[color=%s]+ %s: %s -> %s::%s[/color]" % [
				_COLOR_ADD,
				_escape_bbcode(str(c["signal"])),
				_escape_bbcode(str(c["from"])),
				_escape_bbcode(str(c["to"])),
				_escape_bbcode(str(c["method"])),
			])

	return "\n".join(out)

func _summary_line(na: int, nr: int, nc: int, ca: int, cr: int) -> String:
	return "nodes %s/%s/%s  connections %s/%s" % [
		_signed_count("+", _COLOR_ADD, na),
		_signed_count("-", _COLOR_DEL, nr),
		_signed_count("~", _COLOR_HUNK, nc),
		_signed_count("+", _COLOR_ADD, ca),
		_signed_count("-", _COLOR_DEL, cr),
	]

func _signed_count(prefix: String, color: String, count: int) -> String:
	if count == 0:
		return "[color=%s]%s0[/color]" % [_COLOR_DIM, prefix]
	return "[color=%s]%s%d[/color]" % [color, prefix, count]

func _nodes_differ(a: Dictionary, b: Dictionary, include_properties: bool) -> bool:
	if str(a.get("class", "")) != str(b.get("class", "")):
		return true
	if str(a.get("parent", "")) != str(b.get("parent", "")):
		return true
	if not include_properties:
		return false
	var pa: Dictionary = a.get("properties", {})
	var pb: Dictionary = b.get("properties", {})
	if pa.size() != pb.size():
		return true
	for k in pa.keys():
		if not pb.has(k):
			return true
		if str(pa[k]) != str(pb[k]):
			return true
	for k in pb.keys():
		if not pa.has(k):
			return true
	return false

func _emit_node_change(out: Array[String], a: Dictionary, b: Dictionary, include_properties: bool) -> void:
	var ca: String = str(a.get("class", ""))
	var cb: String = str(b.get("class", ""))
	if ca != cb:
		out.append("    [color=%s]- class = %s[/color]" % [_COLOR_DEL, _escape_bbcode(ca)])
		out.append("    [color=%s]+ class = %s[/color]" % [_COLOR_ADD, _escape_bbcode(cb)])
	var pa_par: String = str(a.get("parent", ""))
	var pb_par: String = str(b.get("parent", ""))
	if pa_par != pb_par:
		out.append("    [color=%s]- parent = %s[/color]" % [_COLOR_DEL, _escape_bbcode(pa_par)])
		out.append("    [color=%s]+ parent = %s[/color]" % [_COLOR_ADD, _escape_bbcode(pb_par)])
	if not include_properties:
		return
	var pa: Dictionary = a.get("properties", {})
	var pb: Dictionary = b.get("properties", {})
	var all_keys: Dictionary = {}
	for k in pa.keys():
		all_keys[k] = true
	for k in pb.keys():
		all_keys[k] = true
	var keys: Array = all_keys.keys()
	keys.sort()
	for k in keys:
		var has_a: bool = pa.has(k)
		var has_b: bool = pb.has(k)
		if has_a and has_b:
			if str(pa[k]) != str(pb[k]):
				out.append("    [color=%s]- %s = %s[/color]" % [_COLOR_DEL, _escape_bbcode(str(k)), _escape_bbcode(str(pa[k]))])
				out.append("    [color=%s]+ %s = %s[/color]" % [_COLOR_ADD, _escape_bbcode(str(k)), _escape_bbcode(str(pb[k]))])
		elif has_a:
			out.append("    [color=%s]- %s = %s[/color]" % [_COLOR_DEL, _escape_bbcode(str(k)), _escape_bbcode(str(pa[k]))])
		else:
			out.append("    [color=%s]+ %s = %s[/color]" % [_COLOR_ADD, _escape_bbcode(str(k)), _escape_bbcode(str(pb[k]))])

#endregion

#region Helpers

func _get_scene_root() -> Node:
	# Mirrors the convention in core/extensions/SceneStreamCommands.gd:
	# in editor we trust EditorInterface (returns null when no scene is
	# open, which we surface as a clean error); at runtime we fall back
	# to current_scene, then SceneTree.root as a last resort.
	if Engine.is_editor_hint():
		return EditorInterface.get_edited_scene_root()
	var tree := Engine.get_main_loop() as SceneTree
	if not tree:
		return null
	if tree.current_scene:
		return tree.current_scene
	return tree.root

# Compact, comparable string for any ConfigFile value. Two values that
# round-trip identically through .tscn must produce identical strings here
# so the diff doesn't flap on harmless representation changes.
func _stringify_value(v: Variant) -> String:
	if v == null:
		return "null"
	if v is String:
		return v
	if v is bool or v is int or v is float:
		return str(v)
	if v is Vector2:
		return "Vector2(%s, %s)" % [v.x, v.y]
	if v is Vector2i:
		return "Vector2i(%s, %s)" % [v.x, v.y]
	if v is Vector3:
		return "Vector3(%s, %s, %s)" % [v.x, v.y, v.z]
	if v is Vector3i:
		return "Vector3i(%s, %s, %s)" % [v.x, v.y, v.z]
	if v is Color:
		return "Color(%s, %s, %s, %s)" % [v.r, v.g, v.b, v.a]
	if v is NodePath:
		return "NodePath(%s)" % str(v)
	if v is Array or v is Dictionary:
		return JSON.stringify(v)
	return str(v)

func _remove_tmp_file(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	# ResourceSaver may also emit a sibling .uid file; clean it too.
	var uid_path := path + ".uid"
	if FileAccess.file_exists(uid_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(uid_path))

func _normalize_path(raw: String) -> String:
	var p := raw.strip_edges()
	if (p.begins_with("\"") and p.ends_with("\"")) or (p.begins_with("'") and p.ends_with("'")):
		if p.length() >= 2:
			p = p.substr(1, p.length() - 2)
	return p

# BBCode-escape so bracketed values from .tscn don't get parsed as tags
# by the console RichTextLabel.
func _escape_bbcode(s: String) -> String:
	return s.replace("[", "[lb]")

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

func _color_dim(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_DIM, s]

#endregion

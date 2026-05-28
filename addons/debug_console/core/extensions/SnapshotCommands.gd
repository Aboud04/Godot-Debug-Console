@tool
class_name DebugConsoleSnapshotCommands extends RefCounted

# Deeper-than-SaveSlot scene snapshots. Where SaveSlotCommands.gd serializes
# only @export / PROPERTY_USAGE_STORAGE fields and the dynamic-node skeleton,
# this module captures the full live state of a scope subtree:
#   * every readable property (including non-STORAGE ones like custom
#     _get / _set bag fields, runtime-only scratch state, and editor-only
#     fields that the script exposes via _get_property_list)
#   * every outgoing signal connection (source signal -> target node.method)
#   * the live state of any "tween-like" node reachable from the scope
#     (see the tween limitation below)
#
# All snapshots live in memory under names the caller supplies; snap_save /
# snap_load serialize one to disk on demand. The orchestrator
# (BuiltInCommands.register_universal_commands) instantiates one of these
# and keeps a strong reference so the Callables stay valid for the lifetime
# of the plugin.
#
# LIMITATIONS (the data-only contract):
#   * Functions, closures, lambdas, and bound Callables cannot be captured.
#     Signal connections are stored as "node_path.method_name" strings;
#     connections to lambdas, bound callables, or to objects outside the
#     scope are recorded as "<unbound>" and skipped on restore.
#   * Object / Node references inside properties become {class, path?}
#     stubs. They are not rebound on restore (the live ref is left alone).
#   * Tweens in Godot 4 are RefCounted, not Nodes, and are owned by
#     SceneTree (via `SceneTree.create_tween()`). There is no public API
#     to enumerate them, so the tweens spawned by the console's own
#     `tween` command and by most game code are INVISIBLE to snapshots.
#     We can only capture user-authored Node subclasses that expose a
#     tween-like interface (is_running / speed_scale / playing). Mid-tween
#     interpolation phase is never recoverable; restore only writes back
#     speed_scale / playing on those wrapper nodes.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_DIFF_ADD := "#A0E0A0"
const _COLOR_DIFF_REMOVE := "#FF7878"
const _COLOR_DIFF_CHANGE := "#F7DC6F"

const _SNAP_VERSION := 1

var _registry: Node
var _core: Node

# name -> snapshot dict. Lives for the plugin's lifetime; survives scene
# reloads but not editor restarts.
var _snapshots: Dictionary = {}

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("snap_create", _cmd_snap_create, "Capture full state of a scope (default: scene root) into named snapshot: snap_create <name> [scope_node]", "both")
	_registry.register_command("snap_restore", _cmd_snap_restore, "Restore properties + connections from a named snapshot: snap_restore <name>", "both")
	_registry.register_command("snap_diff", _cmd_snap_diff, "Show what changed between two snapshots: snap_diff <a> <b>", "both")
	_registry.register_command("snap_list", _cmd_snap_list, "List all in-memory snapshots: snap_list", "both")
	_registry.register_command("snap_save", _cmd_snap_save, "Persist a snapshot to disk as JSON: snap_save <name> <user://path.json>", "both")
	_registry.register_command("snap_load", _cmd_snap_load, "Load a snapshot from disk into memory (name = file basename): snap_load <user://path.json>", "both")

#region Command implementations

func _cmd_snap_create(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: snap_create <name> [scope_node]")
	var snap_name := str(args[0]).strip_edges()
	var name_err := _validate_snap_name(snap_name)
	if not name_err.is_empty():
		return _format_error(name_err)

	var scope_path := str(args[1]).strip_edges() if args.size() > 1 else ""
	var scope: Node = null
	if scope_path.is_empty():
		scope = _get_scene_root()
	else:
		scope = _resolve_node(scope_path)
	if not scope:
		return _format_error("Scope node not found: %s" % (scope_path if not scope_path.is_empty() else "<scene root>"))

	var counters: Dictionary = {"nodes": 0, "props": 0, "connections": 0, "tweens": 0}
	var tree_dict: Dictionary = _capture_node(scope, scope, counters)
	var payload: Dictionary = {
		"version": _SNAP_VERSION,
		"name": snap_name,
		"timestamp": int(Time.get_unix_time_from_system()),
		"scope_path": String(scope.get_path()) if scope.is_inside_tree() else scope.name,
		"scope_name": scope.name,
		"tree": tree_dict,
	}
	_snapshots[snap_name] = payload

	return _format_success("Snapshot %s: %s nodes, %s props, %s connections, %s tweens" % [
		_color_path(snap_name),
		_color_number(str(counters["nodes"])),
		_color_number(str(counters["props"])),
		_color_number(str(counters["connections"])),
		_color_number(str(counters["tweens"])),
	])

func _cmd_snap_restore(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: snap_restore <name>")
	var snap_name := str(args[0]).strip_edges()
	if not _snapshots.has(snap_name):
		return _format_error("Snapshot not in memory: %s" % snap_name)
	var payload: Dictionary = _snapshots[snap_name]
	var tree_dict: Variant = payload.get("tree", null)
	if not (tree_dict is Dictionary):
		return _format_error("Snapshot has no tree data: %s" % snap_name)

	var scope_path: String = String(payload.get("scope_path", ""))
	var scope: Node = _resolve_node(scope_path) if scope_path != "" else _get_scene_root()
	if not scope:
		scope = _get_scene_root()
	if not scope:
		return _format_error("Cannot resolve restore scope: %s" % scope_path)

	var stats: Dictionary = {
		"restored": 0,
		"missing": 0,
		"props_set": 0,
		"props_skipped": 0,
		"connections_made": 0,
		"connections_skipped": 0,
		"tweens_touched": 0,
	}
	_apply_node(tree_dict, scope, scope, stats)

	return _format_success("Restored %s: %s nodes, %s props, %s connections, %s tweens%s" % [
		_color_path(snap_name),
		_color_number(str(stats["restored"])),
		_color_number(str(stats["props_set"])),
		_color_number(str(stats["connections_made"])),
		_color_number(str(stats["tweens_touched"])),
		"  (%d missing, %d props skipped, %d conns skipped)" % [
			int(stats["missing"]),
			int(stats["props_skipped"]),
			int(stats["connections_skipped"]),
		],
	])

func _cmd_snap_diff(args: Array, _piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: snap_diff <a> <b>")
	var name_a := str(args[0]).strip_edges()
	var name_b := str(args[1]).strip_edges()
	if not _snapshots.has(name_a):
		return _format_error("Snapshot not in memory: %s" % name_a)
	if not _snapshots.has(name_b):
		return _format_error("Snapshot not in memory: %s" % name_b)
	var a: Dictionary = _snapshots[name_a]
	var b: Dictionary = _snapshots[name_b]
	var tree_a: Variant = a.get("tree", {})
	var tree_b: Variant = b.get("tree", {})
	if not (tree_a is Dictionary) or not (tree_b is Dictionary):
		return _format_error("One of the snapshots has no tree data")

	var flat_a: Dictionary = {}
	var flat_b: Dictionary = {}
	_flatten(tree_a, "", flat_a)
	_flatten(tree_b, "", flat_b)

	var diff_lines: Array[String] = []
	diff_lines.append("Diff %s -> %s" % [_color_path(name_a), _color_path(name_b)])

	var only_in_a: Array = []
	var only_in_b: Array = []
	var in_both: Array = []
	for k in flat_a.keys():
		if flat_b.has(k):
			in_both.append(k)
		else:
			only_in_a.append(k)
	for k in flat_b.keys():
		if not flat_a.has(k):
			only_in_b.append(k)
	only_in_a.sort()
	only_in_b.sort()
	in_both.sort()

	for path in only_in_a:
		diff_lines.append("  %s node %s" % [_diff_remove("- "), _color_path(_display_path(path))])
	for path in only_in_b:
		diff_lines.append("  %s node %s" % [_diff_add("+ "), _color_path(_display_path(path))])

	var changed_nodes: int = 0
	for path in in_both:
		var node_a: Dictionary = flat_a[path]
		var node_b: Dictionary = flat_b[path]
		var node_lines: Array[String] = []

		var props_a: Dictionary = node_a.get("properties", {})
		var props_b: Dictionary = node_b.get("properties", {})
		var prop_keys: Dictionary = {}
		for k in props_a.keys():
			prop_keys[k] = true
		for k in props_b.keys():
			prop_keys[k] = true
		var sorted_keys: Array = prop_keys.keys()
		sorted_keys.sort()
		for k in sorted_keys:
			var key: String = String(k)
			var has_a: bool = props_a.has(key)
			var has_b: bool = props_b.has(key)
			if has_a and not has_b:
				node_lines.append("    %s prop %s = %s" % [_diff_remove("- "), key, _short(props_a[key])])
			elif has_b and not has_a:
				node_lines.append("    %s prop %s = %s" % [_diff_add("+ "), key, _short(props_b[key])])
			elif not _values_equal(props_a[key], props_b[key]):
				node_lines.append("    %s prop %s: %s -> %s" % [
					_diff_change("~ "), key,
					_short(props_a[key]), _short(props_b[key]),
				])

		var conn_a: Array = node_a.get("connections", [])
		var conn_b: Array = node_b.get("connections", [])
		var ca_set: Dictionary = {}
		var cb_set: Dictionary = {}
		for c in conn_a:
			ca_set[_conn_key(c)] = c
		for c in conn_b:
			cb_set[_conn_key(c)] = c
		for ck in ca_set.keys():
			if not cb_set.has(ck):
				node_lines.append("    %s conn %s" % [_diff_remove("- "), String(ck)])
		for ck in cb_set.keys():
			if not ca_set.has(ck):
				node_lines.append("    %s conn %s" % [_diff_add("+ "), String(ck)])

		var tw_a: Dictionary = node_a.get("tween_state", {})
		var tw_b: Dictionary = node_b.get("tween_state", {})
		if not _values_equal(tw_a, tw_b):
			node_lines.append("    %s tween_state: %s -> %s" % [
				_diff_change("~ "),
				_short(tw_a),
				_short(tw_b),
			])

		if not node_lines.is_empty():
			changed_nodes += 1
			diff_lines.append("  node %s" % _color_path(_display_path(path)))
			diff_lines.append_array(node_lines)

	diff_lines.append("Summary: %s only-in-a, %s only-in-b, %s changed" % [
		_color_number(str(only_in_a.size())),
		_color_number(str(only_in_b.size())),
		_color_number(str(changed_nodes)),
	])
	return "\n".join(diff_lines)

func _cmd_snap_list(_args: Array, _piped_input: String = "") -> String:
	if _snapshots.is_empty():
		return "No snapshots in memory."
	var names: Array = _snapshots.keys()
	names.sort()
	var lines: Array[String] = []
	lines.append("%s snapshot(s) in memory:" % _color_number(str(names.size())))
	for n in names:
		var payload: Dictionary = _snapshots[n]
		var tree_dict: Variant = payload.get("tree", {})
		var node_count: int = _count_nodes(tree_dict) if tree_dict is Dictionary else 0
		var ts: int = int(payload.get("timestamp", 0))
		var scope: String = String(payload.get("scope_path", "<root>"))
		lines.append("  %-24s %6s nodes  scope=%s  %s" % [
			_color_path(String(n)),
			_color_number(str(node_count)),
			_color_path(scope),
			_format_timestamp(ts),
		])
	return "\n".join(lines)

func _cmd_snap_save(args: Array, _piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: snap_save <name> <user://path.json>")
	var snap_name := str(args[0]).strip_edges()
	var out_path := str(args[1]).strip_edges()
	if not _snapshots.has(snap_name):
		return _format_error("Snapshot not in memory: %s" % snap_name)
	if not (out_path.begins_with("user://") or out_path.begins_with("res://")):
		return _format_error("Output path must start with user:// or res://")

	var payload: Dictionary = _snapshots[snap_name]
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	if not f:
		return _format_error("Cannot open output for write: %s (err %d)" % [out_path, FileAccess.get_open_error()])
	f.store_string(JSON.stringify(payload, "  "))
	f.close()

	var size: int = _file_size(out_path)
	return _format_success("Saved snapshot %s (%s bytes) -> %s" % [
		_color_path(snap_name),
		_color_number(str(size)),
		_color_path(out_path),
	])

func _cmd_snap_load(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: snap_load <user://path.json>")
	var in_path := str(args[0]).strip_edges()
	if not (in_path.begins_with("user://") or in_path.begins_with("res://")):
		return _format_error("Input path must start with user:// or res://")
	if not FileAccess.file_exists(in_path):
		return _format_error("Input file not found: %s" % in_path)

	var f := FileAccess.open(in_path, FileAccess.READ)
	if not f:
		return _format_error("Cannot read input: %s" % in_path)
	var text: String = f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return _format_error("Input is not a JSON object: %s" % in_path)
	var payload: Dictionary = parsed
	if not payload.has("tree"):
		return _format_error("Input does not look like a snapshot (missing 'tree' field)")

	var snap_name: String = String(payload.get("name", ""))
	if snap_name.is_empty():
		snap_name = in_path.get_file().get_basename()
	var name_err := _validate_snap_name(snap_name)
	if not name_err.is_empty():
		return _format_error("Loaded snapshot has invalid name '%s': %s" % [snap_name, name_err])

	_snapshots[snap_name] = payload
	var tree_dict: Variant = payload.get("tree", {})
	var node_count: int = _count_nodes(tree_dict) if tree_dict is Dictionary else 0
	return _format_success("Loaded snapshot %s (%s nodes) from %s" % [
		_color_path(snap_name),
		_color_number(str(node_count)),
		_color_path(in_path),
	])

#endregion

#region Capture

func _capture_node(node: Node, scope: Node, counters: Dictionary) -> Dictionary:
	counters["nodes"] = int(counters["nodes"]) + 1
	var rel: String = _relative_path(scope, node)
	var script: Script = node.get_script() as Script
	var script_path: String = script.resource_path if script and script.resource_path != "" else ""

	var props: Dictionary = _capture_properties(node)
	counters["props"] = int(counters["props"]) + props.size()

	var connections: Array = _capture_connections(node, scope)
	counters["connections"] = int(counters["connections"]) + connections.size()

	var tween_state: Dictionary = {}
	if _is_tween_like(node):
		tween_state = _capture_tween_state(node)
		counters["tweens"] = int(counters["tweens"]) + 1

	var entry: Dictionary = {
		"name": node.name,
		"path": rel,
		"class": node.get_class(),
		"properties": props,
		"connections": connections,
	}
	if script_path != "":
		entry["script"] = script_path
	if node.scene_file_path != "":
		entry["scene_file_path"] = node.scene_file_path
	if not tween_state.is_empty():
		entry["tween_state"] = tween_state

	var kids: Array = []
	for child in node.get_children():
		kids.append(_capture_node(child, scope, counters))
	entry["children"] = kids
	return entry

func _capture_properties(node: Node) -> Dictionary:
	# Deeper than SaveSlot: we include any property that's readable, not just
	# PROPERTY_USAGE_STORAGE. That picks up custom _get / _set bag fields
	# and runtime-only scratch state defined via _get_property_list.
	var out: Dictionary = {}
	for entry in node.get_property_list():
		var usage: int = int(entry.get("usage", 0))
		var pname: String = String(entry.get("name", ""))
		if pname.is_empty() or pname.begins_with("_"):
			continue
		if pname in ["script", "owner", "multiplayer", "name", "scene_file_path"]:
			continue
		# Category / group headers in the inspector have no value to read.
		if (usage & PROPERTY_USAGE_CATEGORY) != 0 or (usage & PROPERTY_USAGE_GROUP) != 0 or (usage & PROPERTY_USAGE_SUBGROUP) != 0:
			continue
		# We accept STORAGE, EDITOR, or anything the script chose to expose;
		# skip pure-internal flags that aren't meant to be read.
		var ptype: int = int(entry.get("type", TYPE_NIL))
		if ptype == TYPE_CALLABLE or ptype == TYPE_SIGNAL or ptype == TYPE_RID:
			continue
		var value: Variant = node.get(pname)
		out[pname] = _variant_to_json(value)
	return out

func _capture_connections(node: Node, scope: Node) -> Array:
	var out: Array = []
	for sig in node.get_signal_list():
		var sname: String = String(sig.get("name", ""))
		if sname.is_empty():
			continue
		var conns: Array = node.get_signal_connection_list(sname)
		for c in conns:
			var callable: Callable = c.get("callable")
			var flags: int = int(c.get("flags", 0))
			var target_path: String = "<unbound>"
			var target_method: String = ""
			if callable.is_valid():
				var target_obj: Object = callable.get_object()
				target_method = String(callable.get_method())
				if target_obj is Node:
					var tn: Node = target_obj
					if scope.is_ancestor_of(tn) or tn == scope:
						target_path = _relative_path(scope, tn)
					elif tn.is_inside_tree():
						target_path = "@absolute:%s" % String(tn.get_path())
					else:
						target_path = "<external>"
				else:
					# Lambdas, bound callables, or non-Node objects can't be
					# round-tripped through JSON.
					target_path = "<unbound>"
					target_method = "<unbound>"
			out.append({
				"signal": sname,
				"target_path": target_path,
				"target_method": target_method,
				"flags": flags,
			})
	return out

func _capture_tween_state(node: Node) -> Dictionary:
	# Tween (the RefCounted) exposes very little introspection in Godot 4
	# and is unreachable from the scene tree anyway. We duck-type against
	# user-authored Node wrappers that expose a tween-like interface so
	# snap_diff can still observe meaningful state changes on them.
	var state: Dictionary = {}
	if node.has_method("is_running"):
		state["is_running"] = bool(node.call("is_running"))
	if node.has_method("is_valid"):
		state["is_valid"] = bool(node.call("is_valid"))
	if "speed_scale" in node:
		state["speed_scale"] = float(node.get("speed_scale"))
	if "playing" in node:
		state["playing"] = bool(node.get("playing"))
	if "paused" in node:
		state["paused"] = bool(node.get("paused"))
	return state

func _is_tween_like(node: Node) -> bool:
	# We treat a node as "tween-like" only when it exposes both a
	# speed_scale property and at least one of the runtime-state hooks.
	# This avoids matching arbitrary nodes that happen to have one or the
	# other field.
	if not ("speed_scale" in node):
		return false
	return node.has_method("is_running") or ("playing" in node) or ("paused" in node)

#endregion

#region Apply

func _apply_node(entry: Dictionary, scope: Node, _parent: Node, stats: Dictionary) -> void:
	var rel: String = String(entry.get("path", ""))
	var target: Node = _resolve_relative(scope, rel)
	if not target:
		stats["missing"] = int(stats["missing"]) + 1
	else:
		stats["restored"] = int(stats["restored"]) + 1
		_apply_properties(target, entry.get("properties", {}), stats)
		_apply_connections(target, entry.get("connections", []), scope, stats)
		if target is Node and _is_tween_like(target) and entry.has("tween_state"):
			_apply_tween_state(target, entry["tween_state"])
			stats["tweens_touched"] = int(stats["tweens_touched"]) + 1

	var kids: Array = entry.get("children", [])
	for c in kids:
		if c is Dictionary:
			_apply_node(c, scope, target if target else scope, stats)

func _apply_properties(node: Node, props_raw: Variant, stats: Dictionary) -> void:
	if not (props_raw is Dictionary):
		return
	var props: Dictionary = props_raw
	for pname in props.keys():
		var key: String = String(pname)
		if key.is_empty() or key.begins_with("_"):
			continue
		if key in ["script", "owner", "multiplayer", "name", "scene_file_path"]:
			continue
		if not (key in node):
			stats["props_skipped"] = int(stats["props_skipped"]) + 1
			continue
		var current: Variant = node.get(key)
		var raw_v: Variant = props[key]
		var restored: Variant = _json_to_variant(raw_v, typeof(current))
		if restored == null and raw_v != null:
			# Markers we can't reconstruct (Object refs, Transform/Basis,
			# Quaternion, Plane, AABB). Leave the live value alone.
			stats["props_skipped"] = int(stats["props_skipped"]) + 1
			continue
		node.set(key, restored)
		stats["props_set"] = int(stats["props_set"]) + 1

func _apply_connections(node: Node, conns_raw: Variant, scope: Node, stats: Dictionary) -> void:
	if not (conns_raw is Array):
		return
	for c in conns_raw:
		if not (c is Dictionary):
			continue
		var conn: Dictionary = c
		var sname: String = String(conn.get("signal", ""))
		var tpath: String = String(conn.get("target_path", ""))
		var tmethod: String = String(conn.get("target_method", ""))
		var flags: int = int(conn.get("flags", 0))
		if sname.is_empty() or tmethod.is_empty() or tmethod == "<unbound>" or tpath == "<unbound>" or tpath == "<external>":
			stats["connections_skipped"] = int(stats["connections_skipped"]) + 1
			continue
		if not node.has_signal(sname):
			stats["connections_skipped"] = int(stats["connections_skipped"]) + 1
			continue
		var target: Node = null
		if tpath.begins_with("@absolute:"):
			var abs_path: String = tpath.substr("@absolute:".length())
			var tree := Engine.get_main_loop() as SceneTree
			if tree:
				target = tree.root.get_node_or_null(abs_path)
		else:
			target = _resolve_relative(scope, tpath)
		if not target or not target.has_method(tmethod):
			stats["connections_skipped"] = int(stats["connections_skipped"]) + 1
			continue
		var callable: Callable = Callable(target, tmethod)
		if node.is_connected(sname, callable):
			continue
		var err: int = node.connect(sname, callable, flags)
		if err == OK:
			stats["connections_made"] = int(stats["connections_made"]) + 1
		else:
			stats["connections_skipped"] = int(stats["connections_skipped"]) + 1

func _apply_tween_state(tw: Node, state_raw: Variant) -> void:
	# We can't seek a Tween's interpolation phase from script. Restore is
	# best-effort and only writes the small set of writable runtime
	# properties on user-authored tween-like wrappers.
	if not (state_raw is Dictionary):
		return
	var state: Dictionary = state_raw
	if state.has("speed_scale") and "speed_scale" in tw:
		tw.set("speed_scale", float(state["speed_scale"]))
	if state.has("playing") and "playing" in tw:
		tw.set("playing", bool(state["playing"]))
	if state.has("paused") and "paused" in tw:
		tw.set("paused", bool(state["paused"]))

#endregion

#region Diff helpers

func _flatten(entry: Dictionary, prefix: String, out: Dictionary) -> void:
	var rel: String = String(entry.get("path", ""))
	var key: String = rel if rel != "" else (prefix if prefix != "" else "<root>")
	out[key] = entry
	var kids: Array = entry.get("children", [])
	for c in kids:
		if c is Dictionary:
			_flatten(c, key, out)

func _conn_key(c: Variant) -> String:
	if not (c is Dictionary):
		return str(c)
	var d: Dictionary = c
	return "%s -> %s.%s" % [
		String(d.get("signal", "")),
		String(d.get("target_path", "")),
		String(d.get("target_method", "")),
	]

func _values_equal(a: Variant, b: Variant) -> bool:
	if typeof(a) != typeof(b):
		return false
	if a is Dictionary and b is Dictionary:
		var da: Dictionary = a
		var db: Dictionary = b
		if da.size() != db.size():
			return false
		for k in da.keys():
			if not db.has(k):
				return false
			if not _values_equal(da[k], db[k]):
				return false
		return true
	if a is Array and b is Array:
		var aa: Array = a
		var ab: Array = b
		if aa.size() != ab.size():
			return false
		for i in range(aa.size()):
			if not _values_equal(aa[i], ab[i]):
				return false
		return true
	return a == b

func _short(v: Variant) -> String:
	var s: String = str(v) if not (v is Dictionary or v is Array) else JSON.stringify(v)
	if s.length() > 80:
		return s.substr(0, 77) + "..."
	return s

func _display_path(p: String) -> String:
	return p if p != "" else "<root>"

func _count_nodes(entry: Dictionary) -> int:
	var total: int = 1
	var kids: Array = entry.get("children", [])
	for c in kids:
		if c is Dictionary:
			total += _count_nodes(c)
	return total

#endregion

#region Variant <-> JSON (mirrors SaveSlotCommands so persisted snapshots round-trip the same way)

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
			if obj is Node and (obj as Node).is_inside_tree():
				return {"type": "NodeRef", "class": obj.get_class(), "path": String((obj as Node).get_path())}
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
			"NodeRef", "Object":
				# Live Node / Object refs can't be safely rebound from JSON.
				return null
			"Transform2D", "Transform3D", "Basis", "Quaternion", "Plane", "AABB":
				return null
		var out_d: Dictionary = {}
		for k in d.keys():
			out_d[k] = _json_to_variant(d[k])
		return out_d
	return raw

#endregion

#region Helpers - scene root / paths / files

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

func _resolve_relative(scope: Node, rel: String) -> Node:
	if rel.is_empty() or rel == ".":
		return scope
	return scope.get_node_or_null(rel)

func _relative_path(scope: Node, node: Node) -> String:
	if node == scope:
		return ""
	if not scope.is_ancestor_of(node):
		return ""
	var rel: String = String(scope.get_path_to(node))
	return "" if rel == "." else rel

func _validate_snap_name(snap_name: String) -> String:
	if snap_name.is_empty():
		return "name must not be empty"
	for ch in snap_name:
		var c: String = ch
		var ok: bool = (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or (c >= "0" and c <= "9") or c == "_" or c == "-" or c == "."
		if not ok:
			return "name may only contain [A-Za-z0-9_.-]: %s" % snap_name
	if snap_name.begins_with("."):
		return "name must not start with '.'"
	return ""

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

func _diff_add(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_DIFF_ADD, s]

func _diff_remove(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_DIFF_REMOVE, s]

func _diff_change(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_DIFF_CHANGE, s]

#endregion

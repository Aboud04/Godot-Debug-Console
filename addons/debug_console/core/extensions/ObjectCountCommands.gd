@tool
class_name DebugConsoleObjectCountCommands extends RefCounted

# Tier 6 extension - class-count, top-N, leak-tracking, orphan, and dump
# commands. Auto-loaded by BuiltInCommands.register_universal_commands via
# the extensions loader; the orchestrator keeps a strong reference to this
# instance so the registered Callables stay valid for the plugin's lifetime.
#
# All commands route through a single _walk_counts() pass over the scene
# tree (or any user-provided root), matching SceneCommands' count_nodes
# implementation so behaviour is consistent.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_WARN := "#E0B070"

const _DEFAULT_FIND_LIMIT: int = 50
const _DEFAULT_TOP_N: int = 10
const _ORPHAN_SAMPLE_CAP: int = 32

var _registry: Node
var _core: Node

var _baseline: Dictionary = {}
var _baseline_total: int = 0
var _baseline_root_path: String = ""
var _baseline_time_us: int = 0
var _baseline_taken: bool = false

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("obj_count", _cmd_obj_count, "Walk the scene tree and count nodes by class: obj_count [root_path]", "both")
	_registry.register_command("obj_track_start", _cmd_obj_track_start, "Record a baseline class-count snapshot for leak tracking: obj_track_start [root_path]", "both")
	_registry.register_command("obj_track_stop", _cmd_obj_track_stop, "Report deltas vs the last baseline (positive deltas = potential leaks): obj_track_stop [root_path]", "both")
	_registry.register_command("obj_top", _cmd_obj_top, "List the top N most-instantiated classes in the scene: obj_top [n]", "both")
	_registry.register_command("obj_find_class", _cmd_obj_find_class, "List node paths for instances of a class (capped): obj_find_class <ClassName> [limit]", "both")
	_registry.register_command("obj_find_orphan", _cmd_obj_find_orphan, "Report nodes with no parent that are not inside the tree (potential leaks): obj_find_orphan", "both")
	_registry.register_command("obj_dump", _cmd_obj_dump, "Write the full class-count map as JSON: obj_dump <res://path.json>", "both")

#region Command implementations

func _cmd_obj_count(args: Array, piped_input: String = "") -> String:
	var root_path: String = " ".join(args).strip_edges() if args.size() > 0 else ""
	var root: Node = _resolve_root(root_path)
	if not root:
		return _format_error("Root not found: %s" % (root_path if not root_path.is_empty() else "<scene root>"))

	var counts: Dictionary = {}
	var total: int = _walk_counts(root, counts)
	var class_names: Array = counts.keys()
	class_names.sort()

	var lines: Array[String] = []
	lines.append("Total: %s under %s" % [_color_number(str(total)), _color_path(_path_of(root))])
	for c in class_names:
		lines.append("  %-32s %s" % [str(c), _color_number(str(counts[c]))])
	return "\n".join(lines)

func _cmd_obj_track_start(args: Array, piped_input: String = "") -> String:
	var root_path: String = " ".join(args).strip_edges() if args.size() > 0 else ""
	var root: Node = _resolve_root(root_path)
	if not root:
		return _format_error("Root not found: %s" % (root_path if not root_path.is_empty() else "<scene root>"))

	_baseline.clear()
	_baseline_total = _walk_counts(root, _baseline)
	_baseline_root_path = _path_of(root)
	_baseline_time_us = Time.get_ticks_usec()
	_baseline_taken = true
	return _format_success("Baseline recorded: %s nodes across %s classes (root: %s)" % [
		_color_number(str(_baseline_total)),
		_color_number(str(_baseline.size())),
		_color_path(_baseline_root_path),
	])

func _cmd_obj_track_stop(args: Array, piped_input: String = "") -> String:
	if not _baseline_taken:
		return _format_error("No baseline recorded. Call obj_track_start first.")
	var root_path: String = " ".join(args).strip_edges() if args.size() > 0 else ""
	var root: Node = _resolve_root(root_path)
	if not root:
		return _format_error("Root not found: %s" % (root_path if not root_path.is_empty() else "<scene root>"))

	var current: Dictionary = {}
	var current_total: int = _walk_counts(root, current)
	var elapsed_ms: float = float(Time.get_ticks_usec() - _baseline_time_us) / 1000.0

	var keys: Dictionary = {}
	for k in _baseline.keys():
		keys[k] = true
	for k in current.keys():
		keys[k] = true
	var sorted_keys: Array = keys.keys()
	sorted_keys.sort()

	var lines: Array[String] = []
	lines.append("Delta vs baseline (%.1f ms elapsed, baseline root: %s):" % [elapsed_ms, _baseline_root_path])
	lines.append("  Total: %s -> %s (%s)" % [
		_color_number(str(_baseline_total)),
		_color_number(str(current_total)),
		_format_signed(current_total - _baseline_total),
	])
	var leak_classes: int = 0
	var change_count: int = 0
	for c in sorted_keys:
		var was: int = int(_baseline.get(c, 0))
		var now: int = int(current.get(c, 0))
		var delta: int = now - was
		if delta == 0:
			continue
		change_count += 1
		if delta > 0:
			leak_classes += 1
		lines.append("  %-32s %s -> %s (%s)" % [str(c), str(was), str(now), _format_signed(delta)])
	if change_count == 0:
		lines.append("  (no class-level changes)")
	else:
		lines.append("Classes with positive delta (potential leaks): %s" % _color_number(str(leak_classes)))
	return "\n".join(lines)

func _cmd_obj_top(args: Array, piped_input: String = "") -> String:
	var n: int = _DEFAULT_TOP_N
	if args.size() > 0:
		var parsed: int = int(str(args[0]).strip_edges())
		if parsed > 0:
			n = parsed

	var root: Node = _resolve_root("")
	if not root:
		return _format_error("Root not found: <scene root>")

	var counts: Dictionary = {}
	var total: int = _walk_counts(root, counts)
	var ranked: Array = []
	for c in counts.keys():
		ranked.append([str(c), int(counts[c])])
	ranked.sort_custom(func(a, b): return int(a[1]) > int(b[1]))

	var limit: int = min(n, ranked.size())
	var lines: Array[String] = []
	lines.append("Top %s of %s classes under %s, total %s:" % [
		_color_number(str(limit)),
		_color_number(str(ranked.size())),
		_color_path(_path_of(root)),
		_color_number(str(total)),
	])
	for i in range(limit):
		var entry: Array = ranked[i]
		lines.append("  %2d. %-32s %s" % [i + 1, str(entry[0]), _color_number(str(entry[1]))])
	return "\n".join(lines)

func _cmd_obj_find_class(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: obj_find_class <ClassName> [limit]")
	var target: String = str(args[0]).strip_edges()
	if target.is_empty():
		return _format_error("Usage: obj_find_class <ClassName> [limit]")
	var limit: int = _DEFAULT_FIND_LIMIT
	if args.size() > 1:
		var parsed: int = int(str(args[1]).strip_edges())
		if parsed > 0:
			limit = parsed

	var root: Node = _resolve_root("")
	if not root:
		return _format_error("Root not found: <scene root>")

	var hits: Array[String] = []
	var total_found: int = _collect_by_class(root, target, hits, limit)

	var lines: Array[String] = []
	lines.append("Found %s %s (showing %s, limit %s):" % [
		_color_number(str(total_found)),
		target,
		_color_number(str(hits.size())),
		_color_number(str(limit)),
	])
	for p in hits:
		lines.append("  %s" % _color_path(p))
	if total_found > hits.size():
		lines.append("[color=%s]... %d more truncated (raise limit to see)[/color]" % [_COLOR_WARN, total_found - hits.size()])
	return "\n".join(lines)

func _cmd_obj_find_orphan(args: Array, piped_input: String = "") -> String:
	# The authoritative orphan count comes from the engine performance
	# monitor; ObjectDB enumeration is not exposed to GDScript so we cannot
	# walk every orphaned Node by id. We still surface a small sampler that
	# checks instance ids derived from currently-reachable nodes plus their
	# free siblings, which catches the most common leak shape (a Node whose
	# parent removed it via remove_child but never queue_free()d it).
	var orphan_count: int = int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))

	var samples: Array[String] = []
	var seen_ids: Dictionary = {}
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree and tree.root:
		_collect_known_ids(tree.root, seen_ids)
	var scene_root: Node = _get_scene_root()
	if scene_root and scene_root != (tree.root if tree else null):
		_collect_known_ids(scene_root, seen_ids)

	# Try the small id space first; in practice Godot hands out small
	# sequential ids early so this catches many short-lived leaks.
	for id_int in range(1, 4096):
		if samples.size() >= _ORPHAN_SAMPLE_CAP:
			break
		if seen_ids.has(id_int):
			continue
		var obj: Object = instance_from_id(id_int)
		if obj == null:
			continue
		if not (obj is Node):
			continue
		var n: Node = obj
		if n.get_parent() == null and not n.is_inside_tree():
			samples.append("@%d %s [%s]" % [id_int, n.name, n.get_class()])

	var lines: Array[String] = []
	lines.append("Orphan node count (Performance monitor): %s" % _color_number(str(orphan_count)))
	lines.append("Sampled %s parent-less, out-of-tree nodes (cap %s):" % [
		_color_number(str(samples.size())),
		_color_number(str(_ORPHAN_SAMPLE_CAP)),
	])
	if samples.is_empty():
		lines.append("  (none surfaced in id sample range)")
	else:
		for s in samples:
			lines.append("  %s" % s)
	if orphan_count > samples.size():
		lines.append("[color=%s]Note: GDScript cannot enumerate ObjectDB; listing is a bounded sample only.[/color]" % _COLOR_WARN)
	return "\n".join(lines)

func _cmd_obj_dump(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: obj_dump <res://path.json>")
	var path: String = str(args[0]).strip_edges()
	if path.is_empty():
		return _format_error("Usage: obj_dump <res://path.json>")

	var root: Node = _resolve_root("")
	if not root:
		return _format_error("Root not found: <scene root>")

	var counts: Dictionary = {}
	var total: int = _walk_counts(root, counts)
	var payload: Dictionary = {
		"root": _path_of(root),
		"total": total,
		"class_count": counts.size(),
		"timestamp_unix": int(Time.get_unix_time_from_system()),
		"counts": counts,
	}

	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return _format_error("Failed to open for write: %s (err %d)" % [path, FileAccess.get_open_error()])
	file.store_string(JSON.stringify(payload, "  "))
	file.close()

	return _format_success("Dumped %s nodes / %s classes to %s" % [
		_color_number(str(total)),
		_color_number(str(counts.size())),
		_color_path(path),
	])

#endregion

#region Helpers

func _resolve_root(path: String) -> Node:
	if path.is_empty():
		return _get_scene_root()
	return _resolve_node(path)

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

func _path_of(node: Node) -> String:
	if node == null:
		return "<null>"
	if node.is_inside_tree():
		return str(node.get_path())
	return node.name

func _walk_counts(node: Node, counts: Dictionary) -> int:
	var cls: String = node.get_class()
	counts[cls] = int(counts.get(cls, 0)) + 1
	var total: int = 1
	for child in node.get_children():
		total += _walk_counts(child, counts)
	return total

func _collect_by_class(node: Node, target: String, out: Array[String], limit: int) -> int:
	var found: int = 0
	# Match either the exact engine class or any engine base class via
	# is_class(); script class_names are not visible to either, but
	# get_class() will still surface the underlying engine type.
	if node.get_class() == target or node.is_class(target):
		found += 1
		if out.size() < limit:
			out.append(_path_of(node))
	for child in node.get_children():
		found += _collect_by_class(child, target, out, limit)
	return found

func _collect_known_ids(node: Node, out: Dictionary) -> void:
	out[node.get_instance_id()] = true
	for child in node.get_children():
		_collect_known_ids(child, out)

func _format_signed(delta: int) -> String:
	if delta > 0:
		return "[color=%s]+%d[/color]" % [_COLOR_ERROR, delta]
	if delta < 0:
		return "[color=%s]%d[/color]" % [_COLOR_SUCCESS, delta]
	return "0"

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

#endregion

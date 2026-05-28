@tool
class_name DebugConsoleSceneStreamCommands extends RefCounted

# Tier 8 - threaded scene streaming. Lives in the auto-loaded extensions/
# directory so BuiltInCommands.register_universal_commands picks it up via
# the extensions loader on plugin enable. The module is held alive by the
# _t6_keepalive static array on BuiltInCommands; no edits to that file are
# required to add it.
#
# Active threaded loads are tracked by short numeric ids that map to the
# underlying res:// path passed to ResourceLoader.load_threaded_request, so
# users don't have to retype the full path on every progress/get call. The
# id is the canonical handle exposed to console users; the path is the
# canonical handle ResourceLoader actually keys on internally.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_INFO := "#C8C8C8"

var _registry: Node
var _core: Node

# stream_id -> { "path": String, "started_unix": int }
var _streams: Dictionary = {}
var _next_id: int = 1

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("scene_load_async", _cmd_scene_load_async, "Begin a threaded scene load: scene_load_async <res://scene.tscn>", "both")
	_registry.register_command("scene_load_progress", _cmd_scene_load_progress, "Check progress of a threaded load: scene_load_progress <id>", "both")
	_registry.register_command("scene_load_get", _cmd_scene_load_get, "Instance a completed threaded load: scene_load_get <id> [parent_path]", "both")
	_registry.register_command("scene_unload", _cmd_scene_unload, "Queue-free a node subtree: scene_unload <node_path>", "both")
	_registry.register_command("scene_streaming_dump", _cmd_scene_streaming_dump, "List active threaded scene loads with status + percent", "both")
	_registry.register_command("scene_swap_section", _cmd_scene_swap_section, "Replace a subtree with a freshly-instanced scene: scene_swap_section <from_path> <to_subscene>", "both")
	_registry.register_command("scene_cache_drop", _cmd_scene_cache_drop, "Force ResourceLoader to drop a cached resource: scene_cache_drop <res://path>", "both")

#region Command implementations

func _cmd_scene_load_async(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: scene_load_async <res://scene.tscn>")
	var scene_path := str(args[0]).strip_edges()
	if not ResourceLoader.exists(scene_path):
		return _format_error("Scene not found: %s" % scene_path)
	var err: int = ResourceLoader.load_threaded_request(scene_path, "PackedScene", true)
	if err != OK:
		return _format_error("load_threaded_request failed (err=%d): %s" % [err, scene_path])
	var id: int = _next_id
	_next_id += 1
	_streams[id] = {
		"path": scene_path,
		"started_unix": int(Time.get_unix_time_from_system()),
	}
	return _format_success("Streaming %s as id=%s" % [_color_path(scene_path), _color_number(str(id))])

func _cmd_scene_load_progress(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: scene_load_progress <id>")
	var raw_id := str(args[0]).strip_edges()
	if not raw_id.is_valid_int():
		return _format_error("Stream id must be an integer: %s" % raw_id)
	var id: int = raw_id.to_int()
	if not _streams.has(id):
		return _format_error("Unknown stream id: %s" % str(id))
	var path: String = str(_streams[id]["path"])
	var progress: Array = []
	var status: int = ResourceLoader.load_threaded_get_status(path, progress)
	var percent: float = 0.0
	if progress.size() > 0 and (progress[0] is float or progress[0] is int):
		percent = float(progress[0]) * 100.0
	return "id=%s %s %s [%s%%]" % [
		_color_number(str(id)),
		_color_path(path),
		_status_name(status),
		_color_number("%.1f" % percent),
	]

func _cmd_scene_load_get(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: scene_load_get <id> [parent_path]")
	var raw_id := str(args[0]).strip_edges()
	if not raw_id.is_valid_int():
		return _format_error("Stream id must be an integer: %s" % raw_id)
	var id: int = raw_id.to_int()
	var parent_path := str(args[1]).strip_edges() if args.size() > 1 else ""
	if not _streams.has(id):
		return _format_error("Unknown stream id: %s" % str(id))
	var path: String = str(_streams[id]["path"])
	var status: int = ResourceLoader.load_threaded_get_status(path)
	if status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		return _format_error("Still loading id=%s (%s) - call scene_load_progress" % [str(id), path])
	if status == ResourceLoader.THREAD_LOAD_FAILED:
		_streams.erase(id)
		return _format_error("Threaded load failed: %s" % path)
	if status == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
		_streams.erase(id)
		return _format_error("Invalid threaded resource: %s" % path)

	var res: Resource = ResourceLoader.load_threaded_get(path)
	_streams.erase(id)
	if not res:
		return _format_error("load_threaded_get returned null: %s" % path)
	if not (res is PackedScene):
		return _format_error("Resource is not a PackedScene: %s [%s]" % [path, res.get_class()])
	var packed: PackedScene = res
	var instance := packed.instantiate()
	if not instance:
		return _format_error("Failed to instantiate: %s" % path)

	var parent: Node = null
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
		if root:
			instance.owner = root

	var spawned_path: String = str(instance.get_path()) if instance.is_inside_tree() else instance.name
	return _format_success("Instanced %s at %s" % [_color_path(path), _color_path(spawned_path)])

func _cmd_scene_unload(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: scene_unload <node_path>")
	var path := " ".join(args).strip_edges()
	var node := _resolve_node(path)
	if not node:
		return _format_error("Node not found: %s" % path)

	# Mirrors SceneCommands._cmd_delete_node guardrails. Refuse to unload
	# tree.root or autoload nodes; either would corrupt the running session.
	if not Engine.is_editor_hint():
		var tree := Engine.get_main_loop() as SceneTree
		if tree:
			if node == tree.root:
				return _format_error("Refusing to unload /root")
			if node.get_parent() == tree.root and node != tree.current_scene:
				return _format_error("Refusing to unload autoload: %s" % node.name)

	var node_name: String = node.name
	var node_class: String = node.get_class()
	var subtree_total: int = _walk_node_total(node)
	node.queue_free()
	return _format_success("Unloaded %s [%s] (%s nodes queued for free)" % [
		node_name,
		node_class,
		_color_number(str(subtree_total)),
	])

func _cmd_scene_streaming_dump(args: Array, piped_input: String = "") -> String:
	if _streams.is_empty():
		return _format_success("No active threaded loads.")
	var ids: Array = _streams.keys()
	ids.sort()
	var now: int = int(Time.get_unix_time_from_system())
	var lines: Array[String] = []
	lines.append("Active threaded loads: %s" % _color_number(str(_streams.size())))
	for id in ids:
		var entry: Dictionary = _streams[id]
		var path: String = str(entry.get("path", ""))
		var started: int = int(entry.get("started_unix", now))
		var progress: Array = []
		var status: int = ResourceLoader.load_threaded_get_status(path, progress)
		var percent: float = 0.0
		if progress.size() > 0 and (progress[0] is float or progress[0] is int):
			percent = float(progress[0]) * 100.0
		lines.append("  id=%s  %s  %s  [%s%%]  age=%ss" % [
			_color_number(str(id)),
			_color_path(path),
			_status_name(status),
			_color_number("%.1f" % percent),
			_color_number(str(now - started)),
		])
	return "\n".join(lines)

func _cmd_scene_swap_section(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: scene_swap_section <from_path> <to_subscene>")
	var from_path := str(args[0]).strip_edges()
	var scene_path := str(args[1]).strip_edges()

	var old_node := _resolve_node(from_path)
	if not old_node:
		return _format_error("Node not found: %s" % from_path)
	if not Engine.is_editor_hint():
		var tree := Engine.get_main_loop() as SceneTree
		if tree:
			if old_node == tree.root:
				return _format_error("Refusing to swap /root")
			if old_node.get_parent() == tree.root and old_node != tree.current_scene:
				return _format_error("Refusing to swap autoload: %s" % old_node.name)
	var parent := old_node.get_parent()
	if not parent:
		return _format_error("Cannot swap a node with no parent: %s" % from_path)
	if not ResourceLoader.exists(scene_path):
		return _format_error("Scene not found: %s" % scene_path)
	var packed := load(scene_path) as PackedScene
	if not packed:
		return _format_error("Not a PackedScene: %s" % scene_path)
	var new_node := packed.instantiate()
	if not new_node:
		return _format_error("Failed to instantiate: %s" % scene_path)

	var swap_name: String = old_node.name
	var swap_index: int = old_node.get_index()
	var dropped: int = _walk_node_total(old_node)

	# Detach the old subtree first so the replacement can take the original
	# name without colliding with the about-to-be-freed sibling. queue_free
	# defers the actual delete, but remove_child takes effect immediately.
	parent.remove_child(old_node)
	old_node.queue_free()

	new_node.name = swap_name
	parent.add_child(new_node)
	parent.move_child(new_node, swap_index)
	if Engine.is_editor_hint():
		var root := _get_scene_root()
		if root:
			new_node.owner = root

	var new_path: String = str(new_node.get_path()) if new_node.is_inside_tree() else new_node.name
	return _format_success("Swapped %s -> %s [%s nodes dropped]" % [
		_color_path(from_path),
		_color_path(new_path),
		_color_number(str(dropped)),
	])

func _cmd_scene_cache_drop(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: scene_cache_drop <res://path>")
	var path := str(args[0]).strip_edges()
	if not ResourceLoader.has_cached(path):
		return _format_error("Resource not in ResourceLoader cache: %s" % path)

	# ResourceLoader has no public "drop" call. The supported eviction trick
	# is to fetch the cached ref, rename its path to "" via take_over_path
	# (which removes the path->resource entry from the cache map), then drop
	# the local reference so the cache slot is fully freed once external
	# references release it.
	var res: Resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REUSE)
	if res and res.has_method("take_over_path"):
		res.take_over_path("")
	res = null

	# Ask the editor filesystem to re-stat the file so any subsequent loads
	# rebuild from disk instead of from an in-flight import cache.
	if Engine.is_editor_hint():
		var fs := EditorInterface.get_resource_filesystem()
		if fs:
			fs.update_file(path)

	var still_cached: bool = ResourceLoader.has_cached(path)
	if still_cached:
		return _format_success("Released local ref to %s (cache may persist while other refs are live)" % _color_path(path))
	return _format_success("Dropped %s from ResourceLoader cache" % _color_path(path))

#endregion

#region Helpers

func _status_name(status: int) -> String:
	match status:
		ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
			return "[color=%s]INVALID[/color]" % _COLOR_ERROR
		ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			return "[color=%s]LOADING[/color]" % _COLOR_INFO
		ResourceLoader.THREAD_LOAD_FAILED:
			return "[color=%s]FAILED[/color]" % _COLOR_ERROR
		ResourceLoader.THREAD_LOAD_LOADED:
			return "[color=%s]LOADED[/color]" % _COLOR_SUCCESS
		_:
			return "UNKNOWN(%d)" % status

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

func _walk_node_total(node: Node) -> int:
	var total: int = 1
	for child in node.get_children():
		total += _walk_node_total(child)
	return total

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

#endregion

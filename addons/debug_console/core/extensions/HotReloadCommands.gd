@tool
class_name DebugConsoleHotReloadCommands extends RefCounted

# Tier 7 - hot-reload / hot-swap / live state preservation. Lives in the
# auto-loaded extensions/ directory so BuiltInCommands.register_universal_commands
# picks it up via the extensions loader on plugin enable. Module is held alive
# by the _t6_keepalive static array on BuiltInCommands; no edits to that file
# are required to add it.
#
# All six commands route through this strong-referenced instance so their
# Callables stay valid for the lifetime of the plugin. The hot_watch poller
# lives on a Timer parented to the host Node (_core), which keeps a stable
# reference into the SceneTree without needing a custom main loop.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_INFO := "#C8C8C8"

const _WATCH_TIMER_NAME := "_HotReloadWatchTimer"
const _WATCH_POLL_INTERVAL := 2.0

var _registry: Node
var _core: Node

# Cached @export snapshots, keyed by absolute node path string.
# snapshot value = Dictionary of { property_name : value }
var _snapshots: Dictionary = {}

# Active script-file watches, keyed by res:// path.
# entry value = { "mtime": int, "last_reload_unix": int }
var _watches: Dictionary = {}

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("hot_reload", _cmd_hot_reload, "Reload a script and take new source live: hot_reload <res://path.gd>", "both")
	_registry.register_command("hot_reload_all", _cmd_hot_reload_all, "Walk the tree and reload every unique script resource: hot_reload_all", "both")
	_registry.register_command("hot_swap", _cmd_hot_swap, "Swap a node's script while preserving @export state: hot_swap <node_path> <res://new.gd>", "both")
	_registry.register_command("hot_state_snap", _cmd_hot_state_snap, "Snapshot @export var values for later restore: hot_state_snap <node_path>", "both")
	_registry.register_command("hot_state_restore", _cmd_hot_state_restore, "Restore a previous @export snapshot: hot_state_restore <node_path>", "both")
	_registry.register_command("hot_watch", _cmd_hot_watch, "Auto-reload a script when its file mtime changes (poll 2s): hot_watch <res://path.gd>", "both")

#region Command implementations

func _cmd_hot_reload(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: hot_reload <res://path.gd>")
	var script_path := str(args[0]).strip_edges()
	var script := _load_script(script_path)
	if not script:
		return _format_error("Script not loaded: %s" % script_path)

	var err: int = script.reload(true)
	if err != OK:
		return _format_error("script.reload(true) failed for %s (err=%d)" % [script_path, err])

	_editor_scan()
	var affected: int = _count_nodes_with_script(script)
	return _format_success("Reloaded %s - %s node(s) affected" % [
		_color_path(script_path),
		_color_number(str(affected)),
	])

func _cmd_hot_reload_all(args: Array, piped_input: String = "") -> String:
	var root := _get_scene_root()
	if not root:
		return _format_error("No scene root available")

	var scripts: Dictionary = {}
	_collect_scripts(root, scripts)

	if scripts.is_empty():
		return "No scripts found under %s" % _color_path(str(root.get_path()) if root.is_inside_tree() else root.name)

	var ok_count: int = 0
	var fail_count: int = 0
	var lines: Array[String] = []
	var paths: Array = scripts.keys()
	paths.sort()
	for p in paths:
		var s: Script = scripts[p]
		if not is_instance_valid(s):
			fail_count += 1
			lines.append("  %s  %s" % [_format_error("FAIL"), str(p)])
			continue
		var err: int = s.reload(true)
		if err == OK:
			ok_count += 1
			lines.append("  %s  %s" % [_format_success("OK  "), _color_path(str(p))])
		else:
			fail_count += 1
			lines.append("  %s  %s (err=%d)" % [_format_error("FAIL"), str(p), err])

	_editor_scan()
	var header := "Reloaded %s ok, %s failed (of %s unique scripts)" % [
		_color_number(str(ok_count)),
		_color_number(str(fail_count)),
		_color_number(str(scripts.size())),
	]
	return "%s\n%s" % [header, "\n".join(lines)]

func _cmd_hot_swap(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: hot_swap <node_path> <res://new.gd>")
	var node_path := str(args[0]).strip_edges()
	var script_path := str(args[1]).strip_edges()

	var node := _resolve_node(node_path)
	if not node:
		return _format_error("Node not found: %s" % node_path)
	var new_script := _load_script(script_path)
	if not new_script:
		return _format_error("Script not loaded: %s" % script_path)

	var snapshot: Dictionary = _snapshot_exports(node)
	node.set_script(new_script)
	var restored: int = _restore_exports(node, snapshot)
	_editor_scan()

	var resolved_path: String = str(node.get_path()) if node.is_inside_tree() else node.name
	return _format_success("Swapped %s -> %s (%s of %s @export var(s) restored)" % [
		_color_path(resolved_path),
		_color_path(script_path),
		_color_number(str(restored)),
		_color_number(str(snapshot.size())),
	])

func _cmd_hot_state_snap(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: hot_state_snap <node_path>")
	var node_path := " ".join(args).strip_edges()
	var node := _resolve_node(node_path)
	if not node:
		return _format_error("Node not found: %s" % node_path)

	var snapshot: Dictionary = _snapshot_exports(node)
	var key: String = str(node.get_path()) if node.is_inside_tree() else node.name
	_snapshots[key] = snapshot
	return _format_success("Snapshotted %s @export var(s) on %s" % [
		_color_number(str(snapshot.size())),
		_color_path(key),
	])

func _cmd_hot_state_restore(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: hot_state_restore <node_path>")
	var node_path := " ".join(args).strip_edges()
	var node := _resolve_node(node_path)
	if not node:
		return _format_error("Node not found: %s" % node_path)

	var key: String = str(node.get_path()) if node.is_inside_tree() else node.name
	if not _snapshots.has(key):
		# Try matching by relative name as a fallback.
		var alt: String = node.name
		if _snapshots.has(alt):
			key = alt
		else:
			return _format_error("No snapshot for %s (use hot_state_snap first)" % key)

	var snapshot: Dictionary = _snapshots[key]
	var restored: int = _restore_exports(node, snapshot)
	return _format_success("Restored %s of %s @export var(s) on %s" % [
		_color_number(str(restored)),
		_color_number(str(snapshot.size())),
		_color_path(key),
	])

func _cmd_hot_watch(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		# Listing mode: with no args, print current watches.
		if _watches.is_empty():
			return "No active watches. Usage: hot_watch <res://path.gd>"
		var lines: Array[String] = ["Active hot_watch entries:"]
		var keys: Array = _watches.keys()
		keys.sort()
		for k in keys:
			var entry: Dictionary = _watches[k]
			lines.append("  %s  (mtime=%s)" % [_color_path(str(k)), _color_number(str(entry.get("mtime", 0)))])
		return "\n".join(lines)

	var script_path := str(args[0]).strip_edges()
	if not ResourceLoader.exists(script_path):
		return _format_error("Script not found: %s" % script_path)
	if not script_path.ends_with(".gd"):
		return _format_error("hot_watch only supports .gd files: %s" % script_path)

	var mtime: int = FileAccess.get_modified_time(script_path)
	_watches[script_path] = {
		"mtime": mtime,
		"last_reload_unix": 0,
	}
	_ensure_watch_timer()
	return _format_success("Watching %s (poll every %ss, currently %s tracked)" % [
		_color_path(script_path),
		_color_number(str(_WATCH_POLL_INTERVAL)),
		_color_number(str(_watches.size())),
	])

#endregion

#region Hot-watch poller

func _ensure_watch_timer() -> void:
	if not _core:
		return
	var existing: Node = _core.get_node_or_null(_WATCH_TIMER_NAME)
	if existing is Timer:
		return
	var timer: Timer = Timer.new()
	timer.name = _WATCH_TIMER_NAME
	timer.wait_time = _WATCH_POLL_INTERVAL
	timer.one_shot = false
	timer.autostart = false
	# Editor: Timers do not tick without process; the editor host node still
	# drives _process so timeout fires. Game: standard scene-tree behaviour.
	_core.add_child(timer)
	timer.timeout.connect(_on_watch_tick)
	timer.start()

func _on_watch_tick() -> void:
	if _watches.is_empty():
		return
	var paths: Array = _watches.keys()
	for p in paths:
		var path: String = str(p)
		var entry: Dictionary = _watches[path]
		var current: int = FileAccess.get_modified_time(path)
		var previous: int = int(entry.get("mtime", 0))
		if current == 0:
			# File gone - drop the watch silently.
			_watches.erase(path)
			continue
		if current == previous:
			continue
		entry["mtime"] = current
		entry["last_reload_unix"] = int(Time.get_unix_time_from_system())
		_watches[path] = entry
		var script := _load_script(path)
		if not script:
			continue
		script.reload(true)
		_editor_scan()

#endregion

#region @export snapshot/restore

# Returns Dictionary of { property_name : value } for every @export var on the
# node's current script. Uses get_property_list() + PROPERTY_USAGE_EDITOR +
# PROPERTY_USAGE_SCRIPT_VARIABLE, which is the actual signature of @export.
func _snapshot_exports(node: Node) -> Dictionary:
	var out: Dictionary = {}
	if not is_instance_valid(node):
		return out
	for prop in node.get_property_list():
		var usage: int = int(prop.get("usage", 0))
		if not (usage & PROPERTY_USAGE_SCRIPT_VARIABLE):
			continue
		if not (usage & PROPERTY_USAGE_EDITOR):
			continue
		var pname: String = str(prop.get("name", ""))
		if pname.is_empty():
			continue
		out[pname] = node.get(pname)
	return out

# Returns the number of properties successfully written back onto the node.
# Properties that no longer exist on the (possibly swapped) script are skipped
# silently; this is expected when hot_swap targets a different class.
func _restore_exports(node: Node, snapshot: Dictionary) -> int:
	if not is_instance_valid(node):
		return 0
	var restored: int = 0
	var current_names: Dictionary = {}
	for prop in node.get_property_list():
		var usage: int = int(prop.get("usage", 0))
		if not (usage & PROPERTY_USAGE_SCRIPT_VARIABLE):
			continue
		current_names[str(prop.get("name", ""))] = true
	for k in snapshot.keys():
		var pname: String = str(k)
		if not current_names.has(pname):
			continue
		node.set(pname, snapshot[k])
		restored += 1
	return restored

#endregion

#region Helpers

func _load_script(path: String) -> Script:
	if path.is_empty():
		return null
	if not ResourceLoader.exists(path):
		return null
	var res: Resource = load(path)
	if res is Script:
		return res
	return null

func _count_nodes_with_script(script: Script) -> int:
	var root := _get_scene_root()
	if not root:
		return 0
	var script_path: String = script.resource_path
	return _walk_count_script(root, script_path)

func _walk_count_script(node: Node, script_path: String) -> int:
	var hits: int = 0
	var s: Script = node.get_script() as Script
	if s and s.resource_path == script_path:
		hits += 1
	for child in node.get_children():
		hits += _walk_count_script(child, script_path)
	return hits

func _collect_scripts(node: Node, out: Dictionary) -> void:
	var s: Script = node.get_script() as Script
	if s and not s.resource_path.is_empty():
		out[s.resource_path] = s
	for child in node.get_children():
		_collect_scripts(child, out)

func _editor_scan() -> void:
	if not Engine.is_editor_hint():
		return
	if not Engine.has_singleton("EditorInterface"):
		# In a @tool RefCounted EditorInterface is available as a global, but
		# guard against running this in odd contexts where it is not.
		pass
	var fs := EditorInterface.get_resource_filesystem()
	if fs:
		fs.scan()

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

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

func _color_info(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_INFO, s]

#endregion

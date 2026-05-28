@tool
class_name DebugConsoleEnvCommands extends RefCounted

# Extension module - manages the REPL evaluation environment: a dictionary of
# short aliases pointing at live Node instances so that `evalp player.health`
# works without retyping a full /root/Main/... path on every call.
#
# This is the Panku-style `register_env` pattern. PersistentReplCommands owns
# the session variable scope (literal values), while this module owns named
# Node references. PersistentReplCommands calls our public get_env() during
# every evalp() to merge our names into the Expression's input names array.
#
# Storage is path-based, not pointer-based. We re-resolve each entry on every
# lookup so freed nodes and scene reloads don't strand stale references in
# the eval scope. env_save/env_load round-trip through JSON: only the alias
# and the path are persisted - the live Node is re-resolved on env_load.
#
# Registration contract matches SceneCommands.gd / PersistentReplCommands.gd:
# the orchestrator instantiates this once, holds a strong reference, and
# calls register_commands(registry, core). Callables stay valid for the
# lifetime of the plugin.

const _COLOR_ERROR := "#FF4444"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NAME := "#5FBEE0"
const _COLOR_TYPE := "#C792EA"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_VALUE := "#F7DC6F"

var _registry: Node
var _core: Node
# alias_name -> { "path": String, "kind": String ("node"|"autoload"|"current") }
var _envs: Dictionary = {}

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("env_show", _cmd_env_show, "List all registered REPL env names with their target paths/types", "both")
	_registry.register_command("env_register", _cmd_env_register, "Alias a node under a short name: env_register <name> <node_path>", "both")
	_registry.register_command("env_unregister", _cmd_env_unregister, "Remove an env alias: env_unregister <name|all>", "both")
	_registry.register_command("env_auto", _cmd_env_auto, "Auto-register all autoloads plus the current scene root as 'current'", "both")
	_registry.register_command("env_save", _cmd_env_save, "Persist env aliases to JSON: env_save <user://path.json>", "both")
	_registry.register_command("env_load", _cmd_env_load, "Restore env aliases from JSON: env_load <user://path.json>", "both")
	_registry.register_command("env_search", _cmd_env_search, "Glob-search registered env names: env_search <pattern>", "both")

#region Public API for PersistentReplCommands

func get_env() -> Dictionary:
	# Resolve every alias to a live Node on demand. Freed or unresolvable
	# entries are skipped so the eval scope never carries a dangling pointer.
	var out: Dictionary = {}
	for alias in _envs.keys():
		var entry: Dictionary = _envs[alias]
		var path: String = str(entry.get("path", ""))
		var node: Node = _resolve_node(path)
		if node != null and is_instance_valid(node):
			out[str(alias)] = node
	return out

#endregion

#region Command implementations

func _cmd_env_show(args: Array, piped_input: String = "") -> String:
	if _envs.is_empty():
		return "(no env aliases registered)"
	var keys: Array = _envs.keys()
	keys.sort()
	var lines: Array[String] = []
	for k in keys:
		var entry: Dictionary = _envs[k]
		var path: String = str(entry.get("path", ""))
		var kind: String = str(entry.get("kind", "node"))
		var node: Node = _resolve_node(path)
		var type_label: String
		if node != null and is_instance_valid(node):
			type_label = node.get_class()
			var script: Script = node.get_script() as Script
			if script and script.resource_path != "":
				type_label = "%s<%s>" % [type_label, script.resource_path.get_file()]
		else:
			type_label = "<unresolved>"
		lines.append("%s [%s] -> %s : %s" % [
			_color_name(str(k)),
			_color_type(kind),
			_color_path(path),
			_color_type(type_label),
		])
	return "\n".join(lines)

func _cmd_env_register(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: env_register <name> <node_path>")
	var alias: String = str(args[0]).strip_edges()
	var path: String = str(args[1]).strip_edges()
	if alias.is_empty() or path.is_empty():
		return _format_error("Usage: env_register <name> <node_path>")
	if not _is_valid_identifier(alias):
		return _format_error("Invalid identifier: %s" % alias)
	var node: Node = _resolve_node(path)
	if node == null:
		return _format_error("Node not found: %s" % path)
	_envs[alias] = {"path": path, "kind": "node"}
	return _format_success("Registered %s -> %s (%s)" % [
		_color_name(alias),
		_color_path(path),
		_color_type(node.get_class()),
	])

func _cmd_env_unregister(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: env_unregister <name|all>")
	var target: String = str(args[0]).strip_edges()
	if target == "all":
		var n: int = _envs.size()
		_envs.clear()
		return _format_success("Unregistered %d env alias(es)" % n)
	if not _envs.has(target):
		return _format_error("No such env alias: %s" % target)
	_envs.erase(target)
	return _format_success("Unregistered %s" % _color_name(target))

func _cmd_env_auto(args: Array, piped_input: String = "") -> String:
	var added: Array[String] = []
	var skipped: Array[String] = []

	var tree := Engine.get_main_loop() as SceneTree
	var current_scene: Node = null
	if tree:
		current_scene = tree.current_scene
		if tree.root:
			for child in tree.root.get_children():
				# Autoloads live as direct children of /root. The current scene
				# is also a /root child - we register it separately under
				# 'current' rather than under its scene-root name.
				if current_scene != null and child == current_scene:
					continue
				var alias: String = child.name
				if not _is_valid_identifier(alias):
					skipped.append(alias)
					continue
				var path: String = "/root/%s" % alias
				_envs[alias] = {"path": path, "kind": "autoload"}
				added.append(alias)

	if current_scene != null:
		var current_path: String = current_scene.get_path()
		_envs["current"] = {"path": current_path, "kind": "current"}
		added.append("current")
	elif Engine.is_editor_hint():
		var editor_root: Node = _get_scene_root()
		if editor_root != null:
			_envs["current"] = {"path": str(editor_root.get_path()), "kind": "current"}
			added.append("current")

	var msg: String = "Registered %d alias(es): %s" % [added.size(), ", ".join(added)]
	if not skipped.is_empty():
		msg += " (skipped non-identifier names: %s)" % ", ".join(skipped)
	return _format_success(msg)

func _cmd_env_save(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: env_save <user://path.json>")
	var path: String = str(args[0]).strip_edges()
	var serializable: Dictionary = {}
	for k in _envs.keys():
		var entry: Dictionary = _envs[k]
		serializable[str(k)] = {
			"path": str(entry.get("path", "")),
			"kind": str(entry.get("kind", "node")),
		}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return _format_error("Could not open for write: %s (err %d)" % [path, FileAccess.get_open_error()])
	file.store_string(JSON.stringify(serializable, "\t"))
	file.close()
	return _format_success("Saved %d env alias(es) to %s" % [_envs.size(), path])

func _cmd_env_load(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: env_load <user://path.json>")
	var path: String = str(args[0]).strip_edges()
	if not FileAccess.file_exists(path):
		return _format_error("File not found: %s" % path)
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return _format_error("Could not open for read: %s (err %d)" % [path, FileAccess.get_open_error()])
	var text: String = file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return _format_error("JSON root is not an object in: %s" % path)
	_envs.clear()
	var loaded: Dictionary = parsed
	var unresolved: Array[String] = []
	for k in loaded.keys():
		var raw: Variant = loaded[k]
		var alias: String = str(k)
		var entry: Dictionary = {}
		if raw is Dictionary:
			var d: Dictionary = raw
			entry["path"] = str(d.get("path", ""))
			entry["kind"] = str(d.get("kind", "node"))
		else:
			# Tolerate flat {alias: path} dumps.
			entry["path"] = str(raw)
			entry["kind"] = "node"
		_envs[alias] = entry
		if _resolve_node(entry["path"]) == null:
			unresolved.append(alias)
	var msg: String = "Loaded %d env alias(es) from %s" % [_envs.size(), path]
	if not unresolved.is_empty():
		msg += " (unresolved: %s)" % ", ".join(unresolved)
	return _format_success(msg)

func _cmd_env_search(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: env_search <pattern>")
	var pattern: String = str(args[0]).strip_edges()
	if pattern.is_empty():
		return _format_error("Usage: env_search <pattern>")
	var keys: Array = _envs.keys()
	keys.sort()
	var matches: Array[String] = []
	for k in keys:
		var alias: String = str(k)
		if alias.matchn(pattern):
			var entry: Dictionary = _envs[k]
			matches.append("%s -> %s" % [_color_name(alias), _color_path(str(entry.get("path", "")))])
	if matches.is_empty():
		return "(no env aliases match: %s)" % pattern
	return "\n".join(matches)

#endregion

#region Internals

func _resolve_node(path: String) -> Node:
	var p: String = path.strip_edges()
	if p.is_empty():
		return null

	if Engine.is_editor_hint():
		var root: Node = _get_scene_root()
		if root == null:
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
	if scene == null:
		return null
	return scene.get_node_or_null(p)

func _get_scene_root() -> Node:
	if Engine.is_editor_hint():
		return EditorInterface.get_edited_scene_root()
	var tree := Engine.get_main_loop() as SceneTree
	if not tree:
		return null
	if tree.current_scene:
		return tree.current_scene
	return tree.root

func _is_valid_identifier(s: String) -> bool:
	if s.is_empty():
		return false
	var first: String = s.substr(0, 1)
	if not (first == "_" or _is_alpha(first)):
		return false
	for i in range(1, s.length()):
		var ch: String = s.substr(i, 1)
		if not (ch == "_" or _is_alpha(ch) or _is_digit(ch)):
			return false
	return true

func _is_alpha(ch: String) -> bool:
	return (ch >= "a" and ch <= "z") or (ch >= "A" and ch <= "Z")

func _is_digit(ch: String) -> bool:
	return ch >= "0" and ch <= "9"

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_name(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NAME, s]

func _color_type(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_TYPE, s]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_value(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_VALUE, s]

#endregion

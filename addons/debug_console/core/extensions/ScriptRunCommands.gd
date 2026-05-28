@tool
class_name DebugConsoleScriptRunCommands extends RefCounted

# Extension module - ad-hoc GDScript execution and live script attachment.
# Follows the same module contract as DebugConsoleSceneCommands: the
# orchestrator instantiates one of these, holds a strong reference, and calls
# register_commands(registry, core). All commands here register with the
# "both" context so they are usable from the editor dock and from a running
# game's overlay.
#
# Commands provided:
#   script_run            load a .gd file and invoke its static main()/_run()
#   script_exec           compile and run an inline GDScript snippet
#   script_attach         set_script on a node, with exported-property fixup
#   script_detach         clear the script attached to a node
#   script_replace        swap a node's script and migrate matching state
#   script_list_attached  list nodes whose script is a user script (.gd file)

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"

var _registry: Node
var _core: Node

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("script_run", _cmd_script_run, "Load a .gd file and invoke its static main()/_run(): script_run <res://path.gd>", "both")
	_registry.register_command("script_exec", _cmd_script_exec, "Compile and run an inline GDScript snippet: script_exec <inline_gdscript>", "both")
	_registry.register_command("script_attach", _cmd_script_attach, "Attach a script to a node: script_attach <node_path> <res://path.gd>", "both")
	_registry.register_command("script_detach", _cmd_script_detach, "Detach the script from a node: script_detach <node_path>", "both")
	_registry.register_command("script_replace", _cmd_script_replace, "Replace a node's script and migrate state: script_replace <node_path> <res://new.gd>", "both")
	_registry.register_command("script_list_attached", _cmd_script_list_attached, "List nodes with custom .gd scripts: script_list_attached [root_path]", "both")

#region Command implementations

func _cmd_script_run(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: script_run <res://path.gd>")
	var path := str(args[0]).strip_edges()
	if not ResourceLoader.exists(path):
		return _format_error("Script not found: %s" % path)
	var script := load(path) as GDScript
	if not script:
		return _format_error("Not a GDScript: %s" % path)
	var err := script.reload()
	if err != OK:
		return _format_error("Script failed to compile (err=%d): %s" % [err, path])

	var entry := ""
	if script.has_method("main"):
		entry = "main"
	elif script.has_method("_run"):
		entry = "_run"
	else:
		return _format_error("Script has no static main() or _run(): %s" % path)

	var result: Variant = script.call(entry)
	var label := "%s.%s()" % [_color_path(path), entry]
	if result == null:
		return _format_success("Ran %s" % label)
	return _format_success("Ran %s -> %s" % [label, str(result)])

func _cmd_script_exec(args: Array, piped_input: String = "") -> String:
	var body := " ".join(args).strip_edges()
	if body.is_empty() and not piped_input.is_empty():
		body = piped_input.strip_edges()
	if body.is_empty():
		return _format_error("Usage: script_exec <inline_gdscript>")

	var indented_body := _indent_block(body, "\t")
	var src := "extends RefCounted\nstatic func _r():\n%s\n" % indented_body

	var script := GDScript.new()
	script.source_code = src
	var err := script.reload()
	if err != OK:
		return _format_error("Inline script failed to compile (err=%d)" % err)

	var result: Variant = script.call("_r")
	if result == null:
		return _format_success("Ran inline script")
	return _format_success("Ran inline script -> %s" % str(result))

func _cmd_script_attach(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: script_attach <node_path> <res://path.gd>")
	var node_path := str(args[0]).strip_edges()
	var script_path := str(args[1]).strip_edges()

	var node := _resolve_node(node_path)
	if not node:
		return _format_error("Node not found: %s" % node_path)
	if not ResourceLoader.exists(script_path):
		return _format_error("Script not found: %s" % script_path)
	var script := load(script_path) as GDScript
	if not script:
		return _format_error("Not a GDScript: %s" % script_path)
	var err := script.reload()
	if err != OK:
		return _format_error("Script failed to compile (err=%d): %s" % [err, script_path])

	var preserved := _snapshot_properties(node)
	node.set_script(script)
	var restored := _apply_snapshot(node, preserved)

	var display_path: String = str(node.get_path()) if node.is_inside_tree() else node.name
	return _format_success("Attached %s to %s (restored %s prop(s))" % [
		_color_path(script_path),
		_color_path(display_path),
		_color_number(str(restored)),
	])

func _cmd_script_detach(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: script_detach <node_path>")
	var node_path := str(args[0]).strip_edges()
	var node := _resolve_node(node_path)
	if not node:
		return _format_error("Node not found: %s" % node_path)
	var current: Variant = node.get_script()
	if current == null:
		return _format_error("Node has no script: %s" % node_path)
	var prev_path: String = ""
	if current is Script:
		prev_path = (current as Script).resource_path
	node.set_script(null)
	var display_path: String = str(node.get_path()) if node.is_inside_tree() else node.name
	if prev_path.is_empty():
		return _format_success("Detached script from %s" % _color_path(display_path))
	return _format_success("Detached %s from %s" % [_color_path(prev_path), _color_path(display_path)])

func _cmd_script_replace(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: script_replace <node_path> <res://new.gd>")
	var node_path := str(args[0]).strip_edges()
	var script_path := str(args[1]).strip_edges()

	var node := _resolve_node(node_path)
	if not node:
		return _format_error("Node not found: %s" % node_path)
	if not ResourceLoader.exists(script_path):
		return _format_error("Script not found: %s" % script_path)
	var new_script := load(script_path) as GDScript
	if not new_script:
		return _format_error("Not a GDScript: %s" % script_path)
	var err := new_script.reload()
	if err != OK:
		return _format_error("Script failed to compile (err=%d): %s" % [err, script_path])

	var old_path: String = ""
	var existing: Variant = node.get_script()
	if existing is Script:
		old_path = (existing as Script).resource_path

	var preserved := _snapshot_properties(node)
	node.set_script(new_script)
	var restored := _apply_snapshot(node, preserved)

	var display_path: String = str(node.get_path()) if node.is_inside_tree() else node.name
	var prefix: String = "Replaced %s -> %s on %s" % [
		_color_path(old_path if not old_path.is_empty() else "<none>"),
		_color_path(script_path),
		_color_path(display_path),
	]
	return _format_success("%s (migrated %s prop(s))" % [prefix, _color_number(str(restored))])

func _cmd_script_list_attached(args: Array, piped_input: String = "") -> String:
	var root_path := " ".join(args).strip_edges() if args.size() > 0 else ""
	var root: Node = null
	if root_path.is_empty():
		root = _get_scene_root()
	else:
		root = _resolve_node(root_path)
	if not root:
		return _format_error("Root not found: %s" % (root_path if not root_path.is_empty() else "<scene root>"))

	var entries: Array[String] = []
	_collect_scripted(root, entries, 200)
	if entries.is_empty():
		return "No custom-scripted nodes under %s" % _color_path(str(root.get_path()) if root.is_inside_tree() else root.name)
	var header: String = "%s scripted node(s) under %s:" % [
		_color_number(str(entries.size())),
		_color_path(str(root.get_path()) if root.is_inside_tree() else root.name),
	]
	if entries.size() >= 200:
		header += "  (limit reached)"
	return "%s\n%s" % [header, "\n".join(entries)]

#endregion

#region Helpers

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

func _indent_block(body: String, indent: String) -> String:
	var normalized := body.replace("\r\n", "\n").replace("\r", "\n")
	var lines: PackedStringArray = normalized.split("\n")
	var out: Array[String] = []
	for line in lines:
		if line.is_empty():
			out.append("")
		else:
			out.append(indent + line)
	return "\n".join(out)

func _snapshot_properties(node: Node) -> Dictionary:
	var snapshot: Dictionary = {}
	if node == null:
		return snapshot
	var props: Array = node.get_property_list()
	for prop in props:
		var name_str: String = str(prop.get("name", ""))
		if name_str.is_empty():
			continue
		var usage: int = int(prop.get("usage", 0))
		if (usage & PROPERTY_USAGE_STORAGE) == 0 and (usage & PROPERTY_USAGE_SCRIPT_VARIABLE) == 0:
			continue
		if name_str.begins_with("_") or name_str == "script":
			continue
		snapshot[name_str] = node.get(name_str)
	return snapshot

func _apply_snapshot(node: Node, snapshot: Dictionary) -> int:
	if node == null or snapshot.is_empty():
		return 0
	var restored: int = 0
	var props: Array = node.get_property_list()
	var valid_names: Dictionary = {}
	for prop in props:
		var name_str: String = str(prop.get("name", ""))
		if name_str.is_empty():
			continue
		valid_names[name_str] = true
	for key in snapshot.keys():
		var key_str: String = str(key)
		if not valid_names.has(key_str):
			continue
		var prev_value: Variant = node.get(key_str)
		var new_value: Variant = snapshot[key]
		if typeof(prev_value) != typeof(new_value) and prev_value != null:
			continue
		node.set(key_str, new_value)
		restored += 1
	return restored

func _collect_scripted(node: Node, out: Array[String], limit: int) -> void:
	if out.size() >= limit:
		return
	var script_value: Variant = node.get_script()
	if script_value is Script:
		var res_path: String = (script_value as Script).resource_path
		if not res_path.is_empty():
			var node_display: String = str(node.get_path()) if node.is_inside_tree() else node.name
			out.append("  %s  ->  %s" % [_color_path(node_display), _color_path(res_path)])
	for child in node.get_children():
		if out.size() >= limit:
			return
		_collect_scripted(child, out, limit)

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

#endregion

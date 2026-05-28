@tool
class_name DebugConsoleSceneSaveDialogCommands extends RefCounted

# Tier 8 - scene save / open / export through Godot's native FileDialog widget
# so console users can point-and-click a target file instead of typing full
# res:// paths. Tracks recently picked scenes in user://recent_scenes.cfg
# (capped at 16 entries) for quick re-use. Lives in the auto-loaded
# extensions/ directory; kept alive by the _t6_keepalive static array on
# BuiltInCommands so its Callables stay valid for the plugin lifetime.
#
# All six commands work in both editor and runtime contexts:
#  - Editor: dialogs parent to the EditorInterface base control;
#    scene_open_dialog uses EditorInterface.open_scene_from_path; the scene
#    that scene_save_dialog packs is EditorInterface.get_edited_scene_root.
#  - Runtime: dialogs parent to the SceneTree root Window; scene_open_dialog
#    load()+instantiate()s the picked scene under current_scene;
#    scene_save_dialog packs SceneTree.current_scene.
#
# Results are delivered asynchronously: every command that spawns a dialog
# returns immediately with a dlg_N id and emits the final path / status via
# _emit_result once the user confirms or cancels. scene_pick_root emits the
# bare chosen path (no decoration) so it can be piped into other commands.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_ID := "#F7DC6F"
const _COLOR_NUMBER := "#C8C8C8"

const _RECENTS_PATH := "user://recent_scenes.cfg"
const _RECENTS_SECTION := "recents"
const _RECENTS_KEY := "paths"
const _RECENTS_MAX := 16

var _registry: Node
var _core: Node

# Maps dialog_id -> FileDialog awaiting user input. Cleared by
# _on_dialog_finalized when the dialog confirms / cancels / is closed.
var _active: Dictionary = {}

# Monotonic so IDs stay unique across the session. Matches DialogCommands so
# users see the familiar `dlg_N` format in output.
var _next_id_counter: int = 0

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("scene_save_dialog", _cmd_scene_save_dialog, "Save current scene via FileDialog (*.tscn): scene_save_dialog [default_dir]", "both")
	_registry.register_command("scene_open_dialog", _cmd_scene_open_dialog, "Open scene via FileDialog (editor: open in editor; runtime: load+instance): scene_open_dialog [default_dir]", "both")
	_registry.register_command("scene_export_dialog", _cmd_scene_export_dialog, "Pack a node subtree to a chosen file: scene_export_dialog <node_path>", "both")
	_registry.register_command("scene_pick_root", _cmd_scene_pick_root, "Pick any file under res:// and emit just the path (pipe-friendly): scene_pick_root", "both")
	_registry.register_command("scene_recents", _cmd_scene_recents, "List recently saved/opened scenes from user://recent_scenes.cfg", "both")
	_registry.register_command("scene_recents_clear", _cmd_scene_recents_clear, "Clear the recent-scenes list", "both")

#region Command implementations

func _cmd_scene_save_dialog(args: Array, piped_input: String = "") -> String:
	var default_dir: String = str(args[0]).strip_edges() if args.size() > 0 else "res://"
	var root_node: Node = _get_root_for_dialog()
	if not root_node:
		return _format_error("scene_save_dialog: no SceneTree root available")

	# Resolve the scene-to-pack up front so we fail fast and never spawn a
	# dialog the user fills out only to discover there's nothing to save.
	var scene_node: Node = _get_current_scene()
	if not scene_node:
		return _format_error("scene_save_dialog: no current scene to save")

	var id: String = _next_id()
	var dialog: FileDialog = _make_file_dialog(id, FileDialog.FILE_MODE_SAVE_FILE, "Save Scene", default_dir, PackedStringArray(["*.tscn ; Godot Scene"]))
	# Seed with the current node's name so the user just confirms a directory
	# in the common case (it's editable in the dialog if they want otherwise).
	dialog.current_file = "%s.tscn" % scene_node.name
	root_node.add_child(dialog)

	var on_selected: Callable = func(path: String):
		var result: String = _do_save_scene(scene_node, path)
		_emit_result(id, result)
		_push_recent(path)
		_on_dialog_finalized(id, "")
	var on_cancel: Callable = func():
		_emit_result(id, "scene_save_dialog %s: cancelled" % id)
		_on_dialog_finalized(id, "")
	dialog.file_selected.connect(on_selected)
	dialog.canceled.connect(on_cancel)
	dialog.close_requested.connect(on_cancel)

	_active[id] = dialog
	dialog.popup_centered(Vector2i(720, 480))
	return _format_success("Awaiting save target: %s" % _color_id(id))

func _cmd_scene_open_dialog(args: Array, piped_input: String = "") -> String:
	var default_dir: String = str(args[0]).strip_edges() if args.size() > 0 else "res://"
	var root_node: Node = _get_root_for_dialog()
	if not root_node:
		return _format_error("scene_open_dialog: no SceneTree root available")

	var id: String = _next_id()
	# Accept both *.tscn and *.scn so the user can open binary scenes too;
	# both are valid PackedScene resources at runtime and in the editor.
	var dialog: FileDialog = _make_file_dialog(id, FileDialog.FILE_MODE_OPEN_FILE, "Open Scene", default_dir, PackedStringArray(["*.tscn ; Godot Scene", "*.scn ; Binary Scene"]))
	root_node.add_child(dialog)

	var on_selected: Callable = func(path: String):
		var result: String = _do_open_scene(path)
		_emit_result(id, result)
		_push_recent(path)
		_on_dialog_finalized(id, "")
	var on_cancel: Callable = func():
		_emit_result(id, "scene_open_dialog %s: cancelled" % id)
		_on_dialog_finalized(id, "")
	dialog.file_selected.connect(on_selected)
	dialog.canceled.connect(on_cancel)
	dialog.close_requested.connect(on_cancel)

	_active[id] = dialog
	dialog.popup_centered(Vector2i(720, 480))
	return _format_success("Awaiting scene to open: %s" % _color_id(id))

func _cmd_scene_export_dialog(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: scene_export_dialog <node_path>")
	var node_path: String = str(args[0]).strip_edges()
	var subtree: Node = _resolve_node(node_path)
	if not subtree:
		return _format_error("scene_export_dialog: node not found: %s" % node_path)
	var root_node: Node = _get_root_for_dialog()
	if not root_node:
		return _format_error("scene_export_dialog: no SceneTree root available")

	var id: String = _next_id()
	var dialog: FileDialog = _make_file_dialog(id, FileDialog.FILE_MODE_SAVE_FILE, "Export Subtree", "res://", PackedStringArray(["*.tscn ; Godot Scene"]))
	dialog.current_file = "%s.tscn" % subtree.name
	root_node.add_child(dialog)

	var on_selected: Callable = func(path: String):
		var result: String = _do_export_subtree(subtree, path)
		_emit_result(id, result)
		_push_recent(path)
		_on_dialog_finalized(id, "")
	var on_cancel: Callable = func():
		_emit_result(id, "scene_export_dialog %s: cancelled" % id)
		_on_dialog_finalized(id, "")
	dialog.file_selected.connect(on_selected)
	dialog.canceled.connect(on_cancel)
	dialog.close_requested.connect(on_cancel)

	_active[id] = dialog
	dialog.popup_centered(Vector2i(720, 480))
	return _format_success("Awaiting export target for %s: %s" % [_color_path(node_path), _color_id(id)])

func _cmd_scene_pick_root(args: Array, piped_input: String = "") -> String:
	var root_node: Node = _get_root_for_dialog()
	if not root_node:
		return _format_error("scene_pick_root: no SceneTree root available")

	var id: String = _next_id()
	# Empty filter list = any file under res:// is selectable. This is what
	# makes the command generic enough to feed arbitrary downstream commands
	# (e.g. `scene_pick_root | spawn`) once the user picks something.
	var dialog: FileDialog = _make_file_dialog(id, FileDialog.FILE_MODE_OPEN_FILE, "Pick File", "res://", PackedStringArray([]))
	root_node.add_child(dialog)

	var on_selected: Callable = func(path: String):
		# Emit ONLY the bare path so callers piping `scene_pick_root | ...`
		# see a clean value instead of a decorated success line.
		_emit_result(id, path)
		_on_dialog_finalized(id, "")
	var on_cancel: Callable = func():
		# Emit an empty line on cancel so any pipe sees an empty value rather
		# than the previous selection or a stale buffer.
		_emit_result(id, "")
		_on_dialog_finalized(id, "")
	dialog.file_selected.connect(on_selected)
	dialog.canceled.connect(on_cancel)
	dialog.close_requested.connect(on_cancel)

	_active[id] = dialog
	dialog.popup_centered(Vector2i(720, 480))
	return _format_success("Awaiting file pick: %s" % _color_id(id))

func _cmd_scene_recents(args: Array, piped_input: String = "") -> String:
	var paths: Array = _load_recents()
	if paths.is_empty():
		return "No recent scenes recorded"
	var lines: Array[String] = []
	lines.append("Recent scenes (%d):" % paths.size())
	for i in range(paths.size()):
		lines.append("  %s  %s" % [_color_number(str(i + 1).pad_zeros(2)), _color_path(str(paths[i]))])
	return "\n".join(lines)

func _cmd_scene_recents_clear(args: Array, piped_input: String = "") -> String:
	var existed: bool = FileAccess.file_exists(_RECENTS_PATH)
	# Save an empty array rather than deleting the file so subsequent reads
	# don't trip the "file does not exist" branch and trigger a re-create on
	# every load. This keeps the user:// surface tidy.
	var cfg: ConfigFile = ConfigFile.new()
	cfg.set_value(_RECENTS_SECTION, _RECENTS_KEY, PackedStringArray())
	var err: int = cfg.save(_RECENTS_PATH)
	if err != OK:
		return _format_error("scene_recents_clear: save failed (err %d)" % err)
	return _format_success("Recents cleared%s" % ("" if existed else " (was already empty)"))

#endregion

#region Save / open / export workers

func _do_save_scene(scene_node: Node, path: String) -> String:
	if not is_instance_valid(scene_node):
		return _format_error("Save failed: scene node was freed before user confirmed")
	# Be forgiving if the user typed a name without the extension; default to
	# .tscn (text) which is what the SAVE_FILE filter advertised.
	var lower: String = path.to_lower()
	if not lower.ends_with(".tscn") and not lower.ends_with(".scn"):
		path += ".tscn"
	var packed: PackedScene = PackedScene.new()
	var err: int = packed.pack(scene_node)
	if err != OK:
		return _format_error("Pack failed for %s (err %d)" % [scene_node.name, err])
	err = ResourceSaver.save(packed, path)
	if err != OK:
		return _format_error("Save failed for %s (err %d)" % [path, err])
	return _format_success("Saved scene to %s" % _color_path(path))

func _do_open_scene(path: String) -> String:
	if not ResourceLoader.exists(path):
		return _format_error("Scene not found: %s" % path)
	if Engine.is_editor_hint():
		# EditorInterface.open_scene_from_path is the user-equivalent of the
		# File > Open Scene menu; it respects unsaved-changes prompts and
		# updates the editor tab strip, which load()+set_main_scene cannot.
		if Engine.has_singleton("EditorInterface"):
			var ei: Object = Engine.get_singleton("EditorInterface")
			if ei and ei.has_method("open_scene_from_path"):
				ei.call("open_scene_from_path", path)
				return _format_success("Opened in editor: %s" % _color_path(path))
		return _format_error("EditorInterface unavailable; cannot open in editor")
	var packed: PackedScene = load(path) as PackedScene
	if not packed:
		return _format_error("Not a PackedScene: %s" % path)
	var instance: Node = packed.instantiate()
	if not instance:
		return _format_error("Failed to instantiate: %s" % path)
	# At runtime we add under current_scene so the new tree is visible to
	# game code. Falling back to root keeps the operation succeeding even
	# during a mid-transition where current_scene is briefly null.
	var parent: Node = _get_current_scene()
	if not parent:
		var tree: SceneTree = Engine.get_main_loop() as SceneTree
		parent = tree.root if tree else null
	if not parent:
		instance.free()
		return _format_error("No parent available for instanced scene")
	parent.add_child(instance)
	return _format_success("Instanced %s under %s" % [_color_path(path), _color_path(parent.name)])

func _do_export_subtree(subtree: Node, path: String) -> String:
	if not is_instance_valid(subtree):
		return _format_error("Export failed: node was freed before user confirmed")
	var lower: String = path.to_lower()
	if not lower.ends_with(".tscn") and not lower.ends_with(".scn"):
		path += ".tscn"
	# PackedScene.pack walks descendants and includes only those whose
	# `owner` equals the pack root. Subtrees that were instanced or built at
	# runtime often have null owners, which would silently produce an empty
	# scene. Reparent ownership to the subtree root for the pack and restore
	# originals afterward so we don't dirty the editor session.
	var original_owners: Dictionary = {}
	_stamp_owner(subtree, subtree, original_owners)
	var packed: PackedScene = PackedScene.new()
	var err: int = packed.pack(subtree)
	_restore_owner(original_owners)
	if err != OK:
		return _format_error("Pack failed for %s (err %d)" % [subtree.name, err])
	err = ResourceSaver.save(packed, path)
	if err != OK:
		return _format_error("Save failed for %s (err %d)" % [path, err])
	return _format_success("Exported %s to %s" % [_color_path(subtree.name), _color_path(path)])

func _stamp_owner(node: Node, new_owner: Node, original: Dictionary) -> void:
	for child in node.get_children():
		original[child] = child.owner
		child.owner = new_owner
		_stamp_owner(child, new_owner, original)

func _restore_owner(original: Dictionary) -> void:
	for node in original.keys():
		if is_instance_valid(node):
			node.owner = original[node]

#endregion

#region Recents store (ConfigFile-backed, capped LRU)

func _push_recent(path: String) -> void:
	if path.is_empty():
		return
	var paths: Array = _load_recents()
	# Deduplicate so re-picking an existing entry promotes it to the front
	# instead of producing duplicate rows in `scene_recents` output.
	var existing_idx: int = paths.find(path)
	if existing_idx != -1:
		paths.remove_at(existing_idx)
	paths.push_front(path)
	while paths.size() > _RECENTS_MAX:
		paths.pop_back()
	var cfg: ConfigFile = ConfigFile.new()
	cfg.set_value(_RECENTS_SECTION, _RECENTS_KEY, PackedStringArray(paths))
	# Best-effort save: a failed write here shouldn't surface as a console
	# error because the user's primary action (save/open) already succeeded.
	cfg.save(_RECENTS_PATH)

func _load_recents() -> Array:
	var out: Array = []
	if not FileAccess.file_exists(_RECENTS_PATH):
		return out
	var cfg: ConfigFile = ConfigFile.new()
	var err: int = cfg.load(_RECENTS_PATH)
	if err != OK:
		return out
	var raw: Variant = cfg.get_value(_RECENTS_SECTION, _RECENTS_KEY, PackedStringArray())
	# Be liberal in what we accept (PackedStringArray or untyped Array) so a
	# user hand-editing the cfg won't break the reader.
	if raw is PackedStringArray:
		for p in raw:
			out.append(p)
	elif raw is Array:
		for p in raw:
			out.append(str(p))
	return out

#endregion

#region Helpers (FileDialog, node resolution, scene root, formatting)

func _make_file_dialog(id: String, file_mode: int, title: String, dir: String, filters: PackedStringArray) -> FileDialog:
	var dialog: FileDialog = FileDialog.new()
	dialog.title = title
	dialog.file_mode = file_mode
	# ACCESS_RESOURCES restricts the dialog to res:// which is the only
	# location PackedScenes can sensibly be opened/saved against in both
	# editor and runtime (the project files always live under res://).
	dialog.access = FileDialog.ACCESS_RESOURCES
	dialog.current_dir = dir if not dir.is_empty() else "res://"
	dialog.filters = filters
	dialog.name = "DebugConsoleSceneDialog_%s" % id
	return dialog

func _get_current_scene() -> Node:
	if Engine.is_editor_hint():
		if Engine.has_singleton("EditorInterface"):
			var ei: Object = Engine.get_singleton("EditorInterface")
			if ei and ei.has_method("get_edited_scene_root"):
				var edited: Node = ei.call("get_edited_scene_root")
				if edited:
					return edited
		return null
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if not tree:
		return null
	return tree.current_scene

func _get_root_for_dialog() -> Node:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if not tree:
		return null
	if Engine.is_editor_hint():
		# Prefer the editor base control so the dialog appears on top of the
		# editor chrome instead of being parented inside the edited scene
		# (which would dirty the scene and stack with viewport rendering).
		if Engine.has_singleton("EditorInterface"):
			var ei: Object = Engine.get_singleton("EditorInterface")
			if ei and ei.has_method("get_base_control"):
				var base: Node = ei.call("get_base_control")
				if base:
					return base
		return tree.root
	return tree.root

func _resolve_node(path: String) -> Node:
	var p: String = path.strip_edges()
	if p.is_empty():
		return null
	if Engine.is_editor_hint():
		# Mirror SceneCommands._resolve_node: strip /root and the scene-root
		# name so editor users can paste the same paths they see in the
		# remote scene tree (`/root/MainScene/Foo`) and still reach `Foo`.
		var root: Node = _get_current_scene()
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

func _next_id() -> String:
	_next_id_counter += 1
	return "dlg_%d" % _next_id_counter

# Async result delivery. Mirrors DialogCommands._emit_result so async output
# from this module surfaces in the same sinks (DebugCore.print_to_console /
# .info, the registry echo fallback, and finally OS print() for headless).
func _emit_result(id: String, msg: String) -> void:
	if _core and is_instance_valid(_core):
		if _core.has_method("print_to_console"):
			_core.call("print_to_console", msg)
			return
		if _core.has_method("info"):
			_core.call("info", msg)
			return
	if _registry and is_instance_valid(_registry) and _registry.has_method("execute_command"):
		_registry.call("execute_command", "echo " + msg)
		return
	print(msg)

func _on_dialog_finalized(id: String, follow_up: String) -> void:
	if _active.has(id):
		var dialog: Object = _active.get(id)
		if is_instance_valid(dialog):
			dialog.queue_free()
		_active.erase(id)
	if not follow_up.is_empty():
		_emit_result(id, follow_up)

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_id(id: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_ID, id]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

#endregion

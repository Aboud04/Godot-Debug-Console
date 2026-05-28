@tool
class_name DebugConsoleFuzzyPaletteCommands extends RefCounted

# Tier 7 - fzf-style fuzzy picker over the registered command surface, the
# live scene tree, the host console's command history, and the project
# filesystem. With ~500 commands shipped by the plugin, linear scrolling of
# `help` is intolerable; this module replaces that with subsequence matching
# so users can type "fznd" and jump straight to fuzzy_nodes.
#
# Six commands:
#   fuzzy_open / fuzzy_close - centered Window with LineEdit + ItemList,
#       Enter runs the highlighted command, Esc closes. Game-context only
#       because it spawns a SceneTree-owned Window.
#   fuzzy_pick    <pat> - non-interactive, returns top-5 command matches for piping
#   fuzzy_files   <pat> - fuzzy match files under res:// recursively
#   fuzzy_nodes   <pat> - fuzzy match nodes in the current scene tree
#   fuzzy_history <pat> - fuzzy match the host console's command history
#
# The scorer is a single static function shared by every command. Piped input
# is delivered as a prepended args element by CommandRegistry (since we don't
# opt-in to supports_input), so `_join_args` naturally absorbs it.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_MUTED := "#888888"

# Characters that count as word boundaries for the scoring bonus. Matches the
# common conventions across the codebase: snake_case, kebab-case, dotted
# paths, and node paths.
const _WORD_BREAKS := "_-. /\\"
const _PICK_LIMIT := 5
const _PALETTE_LIMIT := 100
const _FILE_MAX_DEPTH := 6
const _COLLECT_CAP := 5000

var _registry: Node
var _core: Node

# WeakRef to the open palette Window. We deliberately avoid a strong Node
# reference so that a scene reload, queue_free, or manual close cannot leave
# the module pointing at a freed instance.
var _window_ref: WeakRef = null

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("fuzzy_open", _cmd_fuzzy_open, "Open a centered fuzzy command palette (LineEdit + ItemList; Enter runs, Esc closes)", "game")
	_registry.register_command("fuzzy_close", _cmd_fuzzy_close, "Close the fuzzy command palette window if open", "game")
	_registry.register_command("fuzzy_pick", _cmd_fuzzy_pick, "Non-interactive top-5 fuzzy matches across registered commands: fuzzy_pick <pattern>", "both")
	_registry.register_command("fuzzy_files", _cmd_fuzzy_files, "Fuzzy match files under res:// recursively: fuzzy_files <pattern>", "both")
	_registry.register_command("fuzzy_nodes", _cmd_fuzzy_nodes, "Fuzzy match nodes in the current scene tree: fuzzy_nodes <pattern>", "both")
	_registry.register_command("fuzzy_history", _cmd_fuzzy_history, "Fuzzy match the host console's command history: fuzzy_history <pattern>", "both")

#region Command implementations

func _cmd_fuzzy_open(args: Array, piped_input: String = "") -> String:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if not tree:
		return _format_error("fuzzy_open: no SceneTree available (game context required)")

	# Close any prior palette before opening a new one so we never stack two.
	_close_window()

	var window: Window = Window.new()
	window.name = "DebugConsoleFuzzyPalette"
	window.title = "Fuzzy Command Palette"
	window.size = Vector2i(600, 380)
	window.always_on_top = true
	window.unresizable = false

	var vbox: VBoxContainer = VBoxContainer.new()
	vbox.name = "VBox"
	vbox.anchor_right = 1.0
	vbox.anchor_bottom = 1.0
	vbox.offset_left = 8
	vbox.offset_top = 8
	vbox.offset_right = -8
	vbox.offset_bottom = -8
	window.add_child(vbox)

	var line: LineEdit = LineEdit.new()
	line.name = "Query"
	line.placeholder_text = "Type to filter commands... (Enter runs, Esc closes, Up/Down navigates)"
	vbox.add_child(line)

	var list: ItemList = ItemList.new()
	list.name = "Results"
	list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	list.allow_reselect = true
	vbox.add_child(list)

	tree.root.add_child(window)
	_window_ref = weakref(window)

	# All interactivity is wired through Callables captured here so each
	# closure carries its own list/line/window references. Disconnecting is
	# not necessary - the connections die with the window's children.
	var refresh := func(_q: String) -> void:
		_palette_refresh(list, line.text)
	line.text_changed.connect(refresh)

	var run_selected := func() -> void:
		var sel: PackedInt32Array = list.get_selected_items()
		var cmd: String = ""
		if sel.size() > 0:
			cmd = str(list.get_item_metadata(sel[0]))
		elif list.item_count > 0:
			cmd = str(list.get_item_metadata(0))
		if cmd.is_empty():
			return
		_close_window()
		if _registry:
			_registry.execute_command(cmd)

	line.text_submitted.connect(func(_t: String) -> void: run_selected.call())
	list.item_activated.connect(func(_i: int) -> void: run_selected.call())

	# LineEdit consumes most keys, but gui_input fires before consumption,
	# which is the only reliable hook for Up/Down/Esc while the field has
	# focus. Without this, arrow keys would just move the text caret.
	var key_handler := func(ev: InputEvent) -> void:
		if not (ev is InputEventKey):
			return
		var k: InputEventKey = ev
		if not k.pressed:
			return
		match k.keycode:
			KEY_ESCAPE:
				_close_window()
			KEY_DOWN:
				if list.item_count > 0:
					var sel: PackedInt32Array = list.get_selected_items()
					var next_idx: int = (sel[0] + 1) if sel.size() > 0 else 0
					list.select(mini(next_idx, list.item_count - 1))
			KEY_UP:
				if list.item_count > 0:
					var sel: PackedInt32Array = list.get_selected_items()
					var prev_idx: int = (sel[0] - 1) if sel.size() > 0 else 0
					list.select(maxi(prev_idx, 0))
	line.gui_input.connect(key_handler)
	window.close_requested.connect(func() -> void: _close_window())

	window.popup_centered()
	line.grab_focus()
	_palette_refresh(list, "")
	return _format_success("fuzzy_open: palette ready (%s commands indexed)" % _color_number(str(_collect_commands().size())))

func _cmd_fuzzy_close(args: Array, piped_input: String = "") -> String:
	if _close_window():
		return _format_success("fuzzy_close: palette closed")
	return _format_error("fuzzy_close: no palette is open")

func _cmd_fuzzy_pick(args: Array, piped_input: String = "") -> String:
	var pattern: String = _join_args(args)
	if pattern.is_empty():
		return _format_error("Usage: fuzzy_pick <pattern>")
	return _format_matches(_rank(pattern, _collect_commands(), _PICK_LIMIT), "commands")

func _cmd_fuzzy_files(args: Array, piped_input: String = "") -> String:
	var pattern: String = _join_args(args)
	if pattern.is_empty():
		return _format_error("Usage: fuzzy_files <pattern>")
	var entries: Array = []
	_collect_files("res://", entries, 0)
	return _format_matches(_rank(pattern, entries, _PICK_LIMIT), "files")

func _cmd_fuzzy_nodes(args: Array, piped_input: String = "") -> String:
	var pattern: String = _join_args(args)
	if pattern.is_empty():
		return _format_error("Usage: fuzzy_nodes <pattern>")
	var root: Node = _get_scene_root()
	if not root:
		return _format_error("fuzzy_nodes: no active scene")
	var entries: Array = []
	_collect_nodes(root, entries)
	return _format_matches(_rank(pattern, entries, _PICK_LIMIT), "nodes")

func _cmd_fuzzy_history(args: Array, piped_input: String = "") -> String:
	var pattern: String = _join_args(args)
	if pattern.is_empty():
		return _format_error("Usage: fuzzy_history <pattern>")
	var hist: Array = _collect_history()
	if hist.is_empty():
		return _format_error("fuzzy_history: no command history found on the host console")
	var entries: Array = []
	for h in hist:
		var s: String = str(h)
		entries.append({"label": s, "value": s})
	return _format_matches(_rank(pattern, entries, _PICK_LIMIT), "history")

#endregion

#region Fuzzy scorer

# Subsequence scorer. Returns -1 if pattern is not an in-order subsequence of
# candidate; otherwise a non-negative score where higher is better.
#   +1  per matched char (base)
#   +8  bonus if a char matches at index 0
#   +6  bonus if a char matches right after a word-break character
#   +5  bonus if a char matches immediately after the previous match (consecutive)
#   -1  per character of gap skipped to find the next match
#   -N  length penalty so shorter candidates win ties on equal pattern length
static func _fuzzy_score(pattern: String, candidate: String) -> int:
	if pattern.is_empty():
		return 0
	var p: String = pattern.to_lower()
	var c: String = candidate.to_lower()
	if p.length() > c.length():
		return -1
	var score: int = 0
	var ci: int = 0
	var last_match: int = -1
	for pi in range(p.length()):
		var pch: String = p[pi]
		var found: int = -1
		for j in range(ci, c.length()):
			if c[j] == pch:
				found = j
				break
		if found == -1:
			return -1
		score += 1
		if found == 0:
			score += 8
		elif _WORD_BREAKS.contains(c[found - 1]):
			score += 6
		if last_match != -1 and found == last_match + 1:
			score += 5
		score -= (found - ci)
		last_match = found
		ci = found + 1
	score -= (c.length() - p.length())
	return score

#endregion

#region Ranking, formatting, and palette refresh

func _rank(pattern: String, entries: Array, limit: int) -> Array:
	var scored: Array = []
	for e in entries:
		var label: String = str(e.get("label", ""))
		var aux: String = str(e.get("aux", ""))
		# Score against the user-visible label AND any auxiliary text (e.g.
		# the command description), keeping the best of the two so that
		# typing words from the description still surfaces the command.
		var s1: int = _fuzzy_score(pattern, label)
		var s2: int = -1
		if not aux.is_empty():
			s2 = _fuzzy_score(pattern, aux)
		var best: int = maxi(s1, s2)
		if best >= 0:
			scored.append({
				"label": label,
				"value": str(e.get("value", label)),
				"score": best,
			})
	scored.sort_custom(func(a, b): return int(a["score"]) > int(b["score"]))
	if scored.size() > limit:
		scored.resize(limit)
	return scored

func _format_matches(matches: Array, kind: String) -> String:
	if matches.is_empty():
		return _color_muted("no %s matched" % kind)
	var lines: Array[String] = []
	for m in matches:
		lines.append("%s  %s" % [_color_number(str(m["score"])), _color_path(str(m["value"]))])
	return "\n".join(lines)

func _palette_refresh(list: ItemList, query: String) -> void:
	list.clear()
	var ranked: Array = _rank(query, _collect_commands(), _PALETTE_LIMIT)
	for m in ranked:
		var idx: int = list.add_item(str(m["label"]))
		list.set_item_metadata(idx, str(m["value"]))
	if list.item_count > 0:
		list.select(0)

#endregion

#region Collectors

func _collect_commands() -> Array:
	var out: Array = []
	if not _registry:
		return out
	var raw: Variant = _registry.get("_commands")
	var commands_dict: Dictionary = raw if raw is Dictionary else {}
	for cmd_name in _registry.get_available_commands():
		var data: Dictionary = commands_dict.get(cmd_name, {})
		var desc: String = str(data.get("description", ""))
		out.append({
			"label": "%s  -  %s" % [cmd_name, desc],
			"value": str(cmd_name),
			"aux": desc,
		})
	return out

func _collect_files(path: String, out: Array, depth: int) -> void:
	if depth > _FILE_MAX_DEPTH or out.size() > _COLLECT_CAP:
		return
	var dir: DirAccess = DirAccess.open(path)
	if not dir:
		return
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while entry != "":
		# Skip hidden entries and Godot's import cache so we don't drown the
		# results in noise. node_modules is excluded for the same reason.
		if entry.begins_with(".") or entry == "node_modules":
			entry = dir.get_next()
			continue
		var full: String = path.path_join(entry)
		if dir.current_is_dir():
			_collect_files(full, out, depth + 1)
		else:
			out.append({"label": full, "value": full})
		entry = dir.get_next()
	dir.list_dir_end()

func _collect_nodes(node: Node, out: Array) -> void:
	if not node or out.size() > _COLLECT_CAP:
		return
	var p: String = str(node.get_path())
	out.append({
		"label": "%s  [%s]" % [p, node.get_class()],
		"value": p,
		"aux": node.name,
	})
	for c in node.get_children():
		_collect_nodes(c, out)

func _collect_history() -> Array:
	# The registry exposes a stub get_command_history(); the real store lives
	# on whichever console hosts the input field (GameConsole/EditorConsole).
	# Walk the scene tree looking for the first node that exposes a
	# `command_history` property holding an Array.
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if not tree:
		return []
	var holder: Node = _find_history_holder(tree.root)
	if holder == null:
		# Fallback to the registry stub - currently always [] but keeps the
		# command future-proof if that stub is ever filled in.
		if _registry and _registry.has_method("get_command_history"):
			var r: Variant = _registry.get_command_history()
			if r is Array:
				return r
		return []
	var h: Variant = holder.get("command_history")
	if h is Array:
		return h
	return []

func _find_history_holder(node: Node) -> Node:
	if node == null:
		return null
	if "command_history" in node and node.get("command_history") is Array:
		return node
	for c in node.get_children():
		var r: Node = _find_history_holder(c)
		if r:
			return r
	return null

#endregion

#region Window lifecycle and helpers

func _close_window() -> bool:
	if _window_ref == null:
		return false
	var w: Object = _window_ref.get_ref()
	_window_ref = null
	if is_instance_valid(w):
		(w as Node).queue_free()
		return true
	return false

func _get_scene_root() -> Node:
	if Engine.is_editor_hint():
		return EditorInterface.get_edited_scene_root()
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if not tree:
		return null
	if tree.current_scene:
		return tree.current_scene
	return tree.root

#endregion

#region Formatting helpers

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

func _color_muted(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_MUTED, s]

func _join_args(args: Array) -> String:
	var parts: Array[String] = []
	for a in args:
		parts.append(str(a))
	return " ".join(parts).strip_edges()

#endregion

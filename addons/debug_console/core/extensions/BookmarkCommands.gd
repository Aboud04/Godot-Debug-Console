@tool
class_name DebugConsoleBookmarkCommands extends RefCounted

# Tier 6 extension - per-project bookmarks for node paths and script
# (res://) paths. Auto-loaded by the extensions loader and kept alive
# by the shared _t6_keepalive static array on BuiltInCommands; no edits
# to BuiltInCommands.gd are required to ship this module.
#
# Bookmarks let the user save a short alias for a long node path or a
# script path, then jump back later with bookmark_goto <name>. The goto
# command does not own any inspector / editor opening logic itself - it
# delegates back through the registry to the existing "inspect" command
# (for node-path bookmarks) or "script_open" command (for res:// script
# path bookmarks). That keeps this module orthogonal to whichever
# inspector / editor module is installed.
#
# Storage:
# - Bookmarks dictionary {name: path} is persisted to
#   user://bookmarks_<project>.cfg under the "bookmarks" section.
# - Recent jump history (last 10 names, oldest first) is persisted to the
#   same file under the "recent" section as a single PackedStringArray.
# - Every mutating command (add / remove / rename) saves immediately, so
#   the user never has to remember to call bookmark_save. The explicit
#   bookmark_save / bookmark_load commands are kept for power users who
#   want to force a reload from disk or confirm a write.
#
# Context: every command is registered under "both" - bookmarks are pure
# data and meaningful in either the editor dock or a running game build.

const _COLOR_ERROR := "#FF4444"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NAME := "#F7DC6F"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_DIM := "#888888"

const _SECTION_BOOKMARKS := "bookmarks"
const _SECTION_RECENT := "recent"
const _RECENT_KEY := "names"
const _RECENT_LIMIT := 10

var _registry: Node
var _core: Node

# In-memory cache; mirrored to disk on every mutation.
var _bookmarks: Dictionary = {}

# Most recent goto names; newest is at the END of the array so the
# natural iteration order matches "in order, oldest first" which is what
# bookmark_recent prints.
var _recent: Array[String] = []

# Cached config path. Lazily computed on first use, then reused so the
# project-name lookup only happens once.
var _cfg_path_cached: String = ""

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("bookmark_add", _cmd_bookmark_add, "Record a node path or res:// script path under a name: bookmark_add <name> <node_path|res://path>", "both")
	_registry.register_command("bookmark_remove", _cmd_bookmark_remove, "Remove a bookmark, or pass 'all' to clear: bookmark_remove <name|all>", "both")
	_registry.register_command("bookmark_list", _cmd_bookmark_list, "List all bookmarks sorted by name", "both")
	_registry.register_command("bookmark_goto", _cmd_bookmark_goto, "Jump to a bookmark - runs 'inspect <path>' for nodes or 'script_open <path>' for scripts: bookmark_goto <name>", "both")
	_registry.register_command("bookmark_rename", _cmd_bookmark_rename, "Rename a bookmark: bookmark_rename <old> <new>", "both")
	_registry.register_command("bookmark_save", _cmd_bookmark_save, "Force-save bookmarks to user://bookmarks_<project>.cfg", "both")
	_registry.register_command("bookmark_load", _cmd_bookmark_load, "Reload bookmarks from user://bookmarks_<project>.cfg (discards unsaved in-memory changes)", "both")
	_registry.register_command("bookmark_recent", _cmd_bookmark_recent, "Show the last 10 jumps in chronological order (oldest first)", "both")

	# Best-effort initial load. We swallow the result because a missing
	# file on first run is not an error - it just means there is nothing
	# to load yet.
	_load_from_disk()

#region Command implementations

func _cmd_bookmark_add(args: Array, _piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: bookmark_add <name> <node_path|res://path>")
	var name := str(args[0]).strip_edges()
	# Join remaining args so paths with spaces still work (Godot node
	# names can technically contain spaces).
	var path_parts: Array = []
	for i in range(1, args.size()):
		path_parts.append(str(args[i]))
	var path := " ".join(path_parts).strip_edges()

	if name.is_empty():
		return _format_error("Bookmark name must not be empty")
	if path.is_empty():
		return _format_error("Bookmark target path must not be empty")
	if name == "all":
		# Would collide with bookmark_remove all's sentinel - refuse so
		# the user never ends up with a literal bookmark called "all"
		# that can't be removed individually.
		return _format_error("'all' is reserved (used by bookmark_remove all)")

	var existed: bool = _bookmarks.has(name)
	_bookmarks[name] = path
	_save_to_disk()

	var verb := "Updated" if existed else "Added"
	var kind := "script" if _is_script_path(path) else "node"
	return _format_success("%s %s %s -> %s" % [verb, kind, _color_name(name), _color_path(path)])

func _cmd_bookmark_remove(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: bookmark_remove <name|all>")
	var target := str(args[0]).strip_edges()
	if target.is_empty():
		return _format_error("Usage: bookmark_remove <name|all>")

	if target == "all":
		var count: int = _bookmarks.size()
		_bookmarks.clear()
		_save_to_disk()
		return _format_success("Removed all bookmarks (%d)" % count)

	if not _bookmarks.has(target):
		return _format_error("No such bookmark: %s" % target)
	var path: String = str(_bookmarks[target])
	_bookmarks.erase(target)
	_save_to_disk()
	return _format_success("Removed %s -> %s" % [_color_name(target), _color_path(path)])

func _cmd_bookmark_list(_args: Array, _piped_input: String = "") -> String:
	if _bookmarks.is_empty():
		return "[color=%s](no bookmarks - use bookmark_add to record one)[/color]" % _COLOR_DIM
	var names: Array = _bookmarks.keys()
	names.sort()
	var lines: Array[String] = []
	lines.append("Bookmarks (%d):" % names.size())
	for n in names:
		var path: String = str(_bookmarks[n])
		var tag := "[script]" if _is_script_path(path) else "[node]  "
		lines.append("  [color=%s]%s[/color] %-20s -> %s" % [_COLOR_DIM, tag, _color_name(str(n)), _color_path(path)])
	return "\n".join(lines)

func _cmd_bookmark_goto(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: bookmark_goto <name>")
	var name := str(args[0]).strip_edges()
	if name.is_empty():
		return _format_error("Usage: bookmark_goto <name>")
	if not _bookmarks.has(name):
		return _format_error("No such bookmark: %s" % name)

	var path: String = str(_bookmarks[name])
	var sub_command: String
	if _is_script_path(path):
		sub_command = "script_open " + path
	else:
		sub_command = "inspect " + path

	# Record the jump BEFORE delegating, so that a failure in the
	# downstream command (e.g. inspector not installed, node freed)
	# still leaves a record of where the user tried to go - that's
	# usually what they want when debugging "why didn't this jump?".
	_record_recent(name)

	if not _registry:
		return _format_error("Registry unavailable; cannot dispatch '%s'" % sub_command)
	if not _registry.has_method("execute_command"):
		return _format_error("Registry has no execute_command(); cannot dispatch '%s'" % sub_command)

	var sub_result: String = str(_registry.execute_command(sub_command))
	var header := "[color=%s]goto %s -> %s[/color]\n" % [_COLOR_DIM, _color_name(name), _color_path(path)]
	return header + sub_result

func _cmd_bookmark_rename(args: Array, _piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: bookmark_rename <old> <new>")
	var old_name := str(args[0]).strip_edges()
	var new_name := str(args[1]).strip_edges()
	if old_name.is_empty() or new_name.is_empty():
		return _format_error("Both <old> and <new> must be non-empty")
	if new_name == "all":
		return _format_error("'all' is reserved (used by bookmark_remove all)")
	if not _bookmarks.has(old_name):
		return _format_error("No such bookmark: %s" % old_name)
	if old_name == new_name:
		return _format_error("Old and new names are identical: %s" % old_name)
	if _bookmarks.has(new_name):
		return _format_error("Bookmark already exists: %s" % new_name)

	var path: Variant = _bookmarks[old_name]
	_bookmarks.erase(old_name)
	_bookmarks[new_name] = path

	# Recent history references names, not paths, so we have to rewrite
	# any entries in-place to keep the rename consistent. Without this,
	# bookmark_recent would still print the old name (and a follow-up
	# bookmark_goto on that string would say "no such bookmark").
	for i in _recent.size():
		if _recent[i] == old_name:
			_recent[i] = new_name

	_save_to_disk()
	return _format_success("Renamed %s -> %s (target: %s)" % [_color_name(old_name), _color_name(new_name), _color_path(str(path))])

func _cmd_bookmark_save(_args: Array, _piped_input: String = "") -> String:
	var path := _get_cfg_path()
	var err := _save_to_disk()
	if err != OK:
		return _format_error("Save failed (%s) to %s" % [error_string(err), path])
	return _format_success("Saved %d bookmark(s) to %s" % [_bookmarks.size(), _color_path(path)])

func _cmd_bookmark_load(_args: Array, _piped_input: String = "") -> String:
	var path := _get_cfg_path()
	var err := _load_from_disk()
	if err != OK and err != ERR_FILE_NOT_FOUND:
		return _format_error("Load failed (%s) from %s" % [error_string(err), path])
	if err == ERR_FILE_NOT_FOUND:
		return "[color=%s](no bookmarks file yet at %s)[/color]" % [_COLOR_DIM, path]
	return _format_success("Loaded %d bookmark(s) from %s" % [_bookmarks.size(), _color_path(path)])

func _cmd_bookmark_recent(_args: Array, _piped_input: String = "") -> String:
	if _recent.is_empty():
		return "[color=%s](no recent jumps yet)[/color]" % _COLOR_DIM
	var lines: Array[String] = []
	lines.append("Recent jumps (oldest first, up to %d):" % _RECENT_LIMIT)
	for i in _recent.size():
		var n: String = _recent[i]
		var target: String = str(_bookmarks.get(n, "<deleted>"))
		lines.append("  %d. %s -> %s" % [i + 1, _color_name(n), _color_path(target)])
	return "\n".join(lines)

#endregion

#region Helpers

func _is_script_path(path: String) -> bool:
	# Treat anything that looks like a Godot resource URI as a script /
	# file path. The downstream script_open command is the one that
	# actually validates the file exists; we only need a heuristic that
	# routes correctly between inspect (nodes) and script_open (files).
	var p := path.strip_edges()
	return p.begins_with("res://") or p.begins_with("user://")

func _record_recent(name: String) -> void:
	# Remove any earlier occurrence so the same name doesn't fill the
	# list - moving it to the end is more useful than duplicating it.
	var existing := _recent.find(name)
	if existing != -1:
		_recent.remove_at(existing)
	_recent.append(name)
	while _recent.size() > _RECENT_LIMIT:
		_recent.pop_front()
	_save_to_disk()

func _get_cfg_path() -> String:
	if not _cfg_path_cached.is_empty():
		return _cfg_path_cached
	var raw: String = str(ProjectSettings.get_setting("application/config/name", "project"))
	var slug := _slugify(raw)
	if slug.is_empty():
		slug = "project"
	_cfg_path_cached = "user://bookmarks_%s.cfg" % slug
	return _cfg_path_cached

func _slugify(s: String) -> String:
	# Strip everything that isn't safe for a filename. ConfigFile itself
	# accepts arbitrary paths, but a clean slug makes the file findable
	# in the user data folder and avoids OS-specific path traps.
	var out := ""
	for i in s.length():
		var c := s.substr(i, 1)
		var cc := c.to_lower()
		if (cc >= "a" and cc <= "z") or (cc >= "0" and cc <= "9"):
			out += cc
		elif c == " " or c == "-" or c == "_":
			out += "_"
	return out

func _save_to_disk() -> int:
	var path := _get_cfg_path()
	var cfg := ConfigFile.new()
	# We don't merge with existing on-disk state: the in-memory cache is
	# the source of truth, and was hydrated from disk at register time.
	for key in _bookmarks.keys():
		cfg.set_value(_SECTION_BOOKMARKS, str(key), str(_bookmarks[key]))
	var recent_packed: PackedStringArray = PackedStringArray()
	for n in _recent:
		recent_packed.append(n)
	cfg.set_value(_SECTION_RECENT, _RECENT_KEY, recent_packed)
	return cfg.save(path)

func _load_from_disk() -> int:
	var path := _get_cfg_path()
	var cfg := ConfigFile.new()
	var err := cfg.load(path)
	if err != OK:
		# Leave the in-memory state alone on a missing / unreadable
		# file; that way an accidental bookmark_load on a fresh install
		# doesn't wipe whatever the user just added in this session.
		return err

	_bookmarks.clear()
	if cfg.has_section(_SECTION_BOOKMARKS):
		for key in cfg.get_section_keys(_SECTION_BOOKMARKS):
			_bookmarks[str(key)] = str(cfg.get_value(_SECTION_BOOKMARKS, key, ""))

	_recent.clear()
	if cfg.has_section_key(_SECTION_RECENT, _RECENT_KEY):
		var loaded: Variant = cfg.get_value(_SECTION_RECENT, _RECENT_KEY, PackedStringArray())
		if loaded is PackedStringArray:
			for n in loaded:
				_recent.append(str(n))
		elif loaded is Array:
			for n in loaded:
				_recent.append(str(n))
		# Guard against a hand-edited file that overflows the cap.
		while _recent.size() > _RECENT_LIMIT:
			_recent.pop_front()
	return OK

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_name(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NAME, s]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

#endregion

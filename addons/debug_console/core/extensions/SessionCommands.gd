@tool
class_name DebugConsoleSessionCommands extends RefCounted

# Session snapshot module. Captures the full console session state -
# DebugCore log history, current_directory, aliases, pinned commands,
# persistent REPL vars (PersistentReplCommands._vars) and active
# watchpoints (WatchpointCommands._watchpoints) - into a single versioned
# JSON bundle under user://sessions/<name>.json so a user can hop between
# debugging contexts without losing setup.
#
# Mirrors the shape of SceneCommands.gd / PinnedCommandCommands.gd:
# @tool + class_name + RefCounted, the same _COLOR_* palette and
# _format_error / _format_success / _color_* helpers, "both" context
# registration so commands work in editor and runtime. The orchestrator
# (BuiltInCommands.register_universal_commands) auto-discovers any
# *Commands.gd dropped into core/extensions/ and parks it in the static
# _t8_extensions array, so this module is wired up without touching
# BuiltInCommands.gd.
#
# This module owns:
#   * the snapshot dict format (see _capture_snapshot)
#   * user://sessions/ directory creation, listing, deletion
#   * the rules for what "session state" means - any new console-wide
#     persistent thing should add a capture/restore pair here.
#
# Sibling module state is read by walking BuiltInCommands._t8_extensions
# and BuiltInCommands._t6_keepalive to find live module instances by
# their script resource_path. When the live instance isn't reachable
# (e.g. plugin reload between save and load), capture falls back to
# reading the on-disk persistent files those modules also write to
# (user://debug_console_aliases.cfg, user://pinned_commands.json).
# REPL vars and watchpoints are pure in-memory state with no on-disk
# mirror, so they're skipped silently when the live module is gone.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_WARN := "#F5B041"

const _SESSIONS_DIR := "user://sessions"
const _ALIAS_CFG_PATH := "user://debug_console_aliases.cfg"
const _PINS_PATH := "user://pinned_commands.json"
const _SNAPSHOT_VERSION := 1
const _NAME_MAX_LEN := 64

const _REPL_SCRIPT := "res://addons/debug_console/core/extensions/PersistentReplCommands.gd"
const _WATCH_SCRIPT := "res://addons/debug_console/core/extensions/WatchpointCommands.gd"
const _PIN_SCRIPT := "res://addons/debug_console/core/extensions/PinnedCommandCommands.gd"
const _BIC_SCRIPT := "res://addons/debug_console/core/BuiltInCommands.gd"

var _registry: Node
var _core: Node

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_ensure_sessions_dir()
	_registry.register_command("session_save", _cmd_session_save, "Snapshot console state to user://sessions/<name>.json: session_save <name>", "both")
	_registry.register_command("session_load", _cmd_session_load, "Restore a saved session by name: session_load <name>", "both")
	_registry.register_command("session_list", _cmd_session_list, "List saved sessions in user://sessions/", "both")
	_registry.register_command("session_delete", _cmd_session_delete, "Delete a saved session: session_delete <name|all>", "both")
	_registry.register_command("session_export", _cmd_session_export, "Copy a session snapshot to an arbitrary path: session_export <name> <user://path.json>", "both")
	_registry.register_command("session_diff", _cmd_session_diff, "Diff two saved sessions: session_diff <a> <b>", "both")

#region Command implementations

func _cmd_session_save(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: session_save <name>")
	var name := _sanitize_name(str(args[0]))
	if name.is_empty():
		return _format_error("Invalid session name (allowed: letters, digits, '_' '-' '.', max %d chars)" % _NAME_MAX_LEN)
	var dir_err := _ensure_sessions_dir()
	if not dir_err.is_empty():
		return _format_error(dir_err)
	var bundle := _capture_snapshot(name)
	var path := _path_for(name)
	var write_err := _write_json(path, bundle)
	if not write_err.is_empty():
		return _format_error(write_err)
	return _format_success("Saved session %s -> %s\n%s" % [
		_color_path(name),
		_color_path(path),
		_summarize_bundle(bundle),
	])

func _cmd_session_load(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: session_load <name>")
	var name := _sanitize_name(str(args[0]))
	if name.is_empty():
		return _format_error("Invalid session name: %s" % str(args[0]))
	var path := _path_for(name)
	var bundle_or_err: Variant = _read_json(path)
	if bundle_or_err is String:
		return _format_error(bundle_or_err)
	if not (bundle_or_err is Dictionary):
		return _format_error("Snapshot is not a JSON object: %s" % path)
	var bundle: Dictionary = bundle_or_err
	if int(bundle.get("version", 0)) > _SNAPSHOT_VERSION:
		return _format_error("Snapshot version %s is newer than supported (%d): %s" % [
			str(bundle.get("version")), _SNAPSHOT_VERSION, path,
		])
	var summary := _restore_snapshot(bundle)
	var lines: Array[String] = []
	lines.append(_format_success("Loaded session %s <- %s" % [_color_path(name), _color_path(path)]))
	lines.append("  history       restored=%s" % _color_number(str(summary.get("history", 0))))
	lines.append("  cwd           %s" % _color_path(str(summary.get("cwd", ""))))
	lines.append("  aliases       restored=%s" % _color_number(str(summary.get("aliases", 0))))
	lines.append("  pins          restored=%s" % _color_number(str(summary.get("pins", 0))))
	lines.append("  repl_vars     restored=%s" % _color_number(str(summary.get("repl_vars", 0))))
	lines.append("  watches       restored=%s skipped=%s" % [
		_color_number(str(summary.get("watches", 0))),
		_color_number(str(summary.get("watches_skipped", 0))),
	])
	var warnings: Array = summary.get("warnings", [])
	for w in warnings:
		lines.append("  [color=%s]warn[/color] %s" % [_COLOR_WARN, str(w)])
	return "\n".join(lines)

func _cmd_session_list(_args: Array, _piped_input: String = "") -> String:
	var names := _list_session_names()
	if names.is_empty():
		return "No saved sessions in %s" % _color_path(_SESSIONS_DIR)
	var lines: Array[String] = []
	lines.append("Saved sessions (%s) in %s:" % [_color_number(str(names.size())), _color_path(_SESSIONS_DIR)])
	for name in names:
		var path := _path_for(name)
		var meta := _peek_meta(path)
		var ts: int = int(meta.get("timestamp", 0))
		var iso: String = str(meta.get("iso_time", ""))
		if iso.is_empty() and ts > 0:
			iso = Time.get_datetime_string_from_unix_time(ts, true)
		lines.append("  %-32s  %s  history=%s aliases=%s pins=%s vars=%s watches=%s" % [
			_color_path(name),
			iso if not iso.is_empty() else "-",
			_color_number(str(meta.get("history", 0))),
			_color_number(str(meta.get("aliases", 0))),
			_color_number(str(meta.get("pins", 0))),
			_color_number(str(meta.get("repl_vars", 0))),
			_color_number(str(meta.get("watches", 0))),
		])
	return "\n".join(lines)

func _cmd_session_delete(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: session_delete <name|all>")
	var target := str(args[0]).strip_edges()
	if target.to_lower() == "all":
		var names := _list_session_names()
		if names.is_empty():
			return "No saved sessions to delete."
		var removed: int = 0
		var failed: Array[String] = []
		for n in names:
			if DirAccess.remove_absolute(_path_for(n)) == OK:
				removed += 1
			else:
				failed.append(n)
		if not failed.is_empty():
			return _format_error("Deleted %d, failed to delete: %s" % [removed, ", ".join(failed)])
		return _format_success("Deleted %s session(s) from %s" % [
			_color_number(str(removed)), _color_path(_SESSIONS_DIR),
		])
	var name := _sanitize_name(target)
	if name.is_empty():
		return _format_error("Invalid session name: %s" % target)
	var path := _path_for(name)
	if not FileAccess.file_exists(path):
		return _format_error("No such session: %s" % name)
	var err := DirAccess.remove_absolute(path)
	if err != OK:
		return _format_error("Failed to delete %s (err %d)" % [path, err])
	return _format_success("Deleted session %s" % _color_path(name))

func _cmd_session_export(args: Array, _piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: session_export <name> <user://path.json>")
	var name := _sanitize_name(str(args[0]))
	if name.is_empty():
		return _format_error("Invalid session name: %s" % str(args[0]))
	var dest := str(args[1]).strip_edges()
	if dest.is_empty():
		return _format_error("Destination path is empty")
	if not (dest.begins_with("user://") or dest.begins_with("res://")):
		return _format_error("Destination must start with user:// or res:// (got: %s)" % dest)
	var src := _path_for(name)
	if not FileAccess.file_exists(src):
		return _format_error("No such session: %s" % name)
	var base_dir := dest.get_base_dir()
	if not base_dir.is_empty() and not DirAccess.dir_exists_absolute(base_dir):
		var make_err := DirAccess.make_dir_recursive_absolute(base_dir)
		if make_err != OK:
			return _format_error("Cannot create directory %s (err %d)" % [base_dir, make_err])
	var copy_err := DirAccess.copy_absolute(src, dest)
	if copy_err != OK:
		return _format_error("Copy failed %s -> %s (err %d)" % [src, dest, copy_err])
	return _format_success("Exported %s -> %s" % [_color_path(name), _color_path(dest)])

func _cmd_session_diff(args: Array, _piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: session_diff <a> <b>")
	var name_a := _sanitize_name(str(args[0]))
	var name_b := _sanitize_name(str(args[1]))
	if name_a.is_empty() or name_b.is_empty():
		return _format_error("Invalid session name(s): %s, %s" % [str(args[0]), str(args[1])])
	var a_or_err: Variant = _read_json(_path_for(name_a))
	if a_or_err is String:
		return _format_error(a_or_err)
	var b_or_err: Variant = _read_json(_path_for(name_b))
	if b_or_err is String:
		return _format_error(b_or_err)
	if not (a_or_err is Dictionary) or not (b_or_err is Dictionary):
		return _format_error("One or both snapshots are not JSON objects")
	return _diff_bundles(name_a, a_or_err, name_b, b_or_err)

#endregion

#region Snapshot capture

func _capture_snapshot(name: String) -> Dictionary:
	var bundle: Dictionary = {
		"version": _SNAPSHOT_VERSION,
		"name": name,
		"timestamp": int(Time.get_unix_time_from_system()),
		"iso_time": Time.get_datetime_string_from_system(true),
		"history": _capture_history(),
		"current_directory": _capture_cwd(),
		"aliases": _capture_aliases(),
		"pins": _capture_pins(),
		"repl_vars": _capture_repl_vars(),
		"watches": _capture_watches(),
	}
	return bundle

func _capture_history() -> Array:
	if _core and _core.has_method("get_history"):
		var raw: Array = _core.get_history()
		var out: Array = []
		for s in raw:
			out.append(str(s))
		return out
	return []

func _capture_cwd() -> String:
	# BuiltInCommands keeps a static global_current_directory so even a
	# transient orchestrator instance can answer; prefer it over hunting
	# the live instance. class_name BuiltInCommands is registered before
	# this extension can run, because the orchestrator is what loads us.
	var cwd: String = str(BuiltInCommands.get_current_directory())
	if not cwd.is_empty():
		return cwd
	var bic_inst := _find_built_in_instance()
	if bic_inst and "current_directory" in bic_inst:
		return str(bic_inst.current_directory)
	return "res://"

func _capture_aliases() -> Dictionary:
	var out: Dictionary = {}
	var bic_inst := _find_built_in_instance()
	if bic_inst and "_aliases" in bic_inst:
		for k in (bic_inst._aliases as Dictionary).keys():
			out[str(k)] = str((bic_inst._aliases as Dictionary)[k])
		return out
	# Fallback: alias state is mirrored to disk on every change, so the
	# .cfg is authoritative when the live instance is gone.
	var cfg := ConfigFile.new()
	if cfg.load(_ALIAS_CFG_PATH) != OK:
		return out
	if not cfg.has_section("aliases"):
		return out
	for key in cfg.get_section_keys("aliases"):
		out[str(key)] = str(cfg.get_value("aliases", key, ""))
	return out

func _capture_pins() -> Array:
	var out: Array = []
	var inst := _find_extension(_PIN_SCRIPT)
	if inst and "_pins" in inst:
		for p in (inst._pins as Array):
			if not (p is Dictionary):
				continue
			out.append({
				"command": str((p as Dictionary).get("command", "")),
				"label": str((p as Dictionary).get("label", "")),
			})
		return out
	# Fallback: pins are also persisted on disk.
	if not FileAccess.file_exists(_PINS_PATH):
		return out
	var f := FileAccess.open(_PINS_PATH, FileAccess.READ)
	if not f:
		return out
	var text: String = f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return out
	var raw_pins: Variant = (parsed as Dictionary).get("pins", [])
	if not (raw_pins is Array):
		return out
	for p in raw_pins:
		if p is Dictionary:
			out.append({
				"command": str((p as Dictionary).get("command", "")),
				"label": str((p as Dictionary).get("label", "")),
			})
	return out

func _capture_repl_vars() -> Dictionary:
	var out: Dictionary = {}
	var inst := _find_extension(_REPL_SCRIPT)
	if not inst or not ("_vars" in inst):
		return out
	# var_to_str round-trips every native Variant cleanly (Vector*, Color,
	# Dictionary, Array...) which JSON.stringify cannot. Restore uses
	# str_to_var to invert.
	for k in (inst._vars as Dictionary).keys():
		out[str(k)] = var_to_str((inst._vars as Dictionary)[k])
	return out

func _capture_watches() -> Array:
	var out: Array = []
	var inst := _find_extension(_WATCH_SCRIPT)
	if not inst or not ("_watchpoints" in inst):
		return out
	var ids: Array = (inst._watchpoints as Dictionary).keys()
	ids.sort()
	for id in ids:
		var wp_v: Variant = (inst._watchpoints as Dictionary)[id]
		if not (wp_v is Dictionary):
			continue
		var wp: Dictionary = wp_v
		var entry: Dictionary = {
			"node_path": str(wp.get("node_path", "")),
			"prop": str(wp.get("prop", "")),
			"log": bool(wp.get("log", false)),
			"break": bool(wp.get("break", false)),
			"log_file_path": str(wp.get("log_file_path", "")),
			"has_expected": bool(wp.get("has_expected", false)),
		}
		if entry.has_expected:
			entry["expected"] = var_to_str(wp.get("expected"))
		out.append(entry)
	return out

#endregion

#region Snapshot restore

func _restore_snapshot(bundle: Dictionary) -> Dictionary:
	var summary: Dictionary = {
		"history": 0, "cwd": "", "aliases": 0, "pins": 0,
		"repl_vars": 0, "watches": 0, "watches_skipped": 0,
		"warnings": [],
	}

	# history -> DebugCore._message_history. DebugCore exposes get_history
	# but no setter, so we splice the typed array directly.
	var hist: Variant = bundle.get("history", [])
	if hist is Array and _core and "_message_history" in _core:
		var typed: Array[String] = []
		for s in (hist as Array):
			typed.append(str(s))
		_core._message_history = typed
		summary["history"] = typed.size()
	elif hist is Array and not (hist as Array).is_empty():
		(summary["warnings"] as Array).append("DebugCore unavailable, history not restored")

	# current_directory -> BuiltInCommands static + live instance var.
	var cwd: String = str(bundle.get("current_directory", "")).strip_edges()
	if not cwd.is_empty():
		BuiltInCommands.set_current_directory(cwd)
		var bic_inst := _find_built_in_instance()
		if bic_inst and "current_directory" in bic_inst:
			bic_inst.current_directory = cwd
		summary["cwd"] = cwd

	# aliases -> write .cfg (source of truth between reloads) + sync the
	# live instance dict + re-register alias commands so they fire today.
	var aliases_v: Variant = bundle.get("aliases", {})
	if aliases_v is Dictionary:
		var aliases: Dictionary = aliases_v
		var cfg := ConfigFile.new()
		for k in aliases.keys():
			cfg.set_value("aliases", str(k), str(aliases[k]))
		var save_err := cfg.save(_ALIAS_CFG_PATH)
		if save_err != OK:
			(summary["warnings"] as Array).append("Failed to write %s (err %d)" % [_ALIAS_CFG_PATH, save_err])
		var bic_inst := _find_built_in_instance()
		if bic_inst and "_aliases" in bic_inst:
			(bic_inst._aliases as Dictionary).clear()
			for k in aliases.keys():
				(bic_inst._aliases as Dictionary)[str(k).to_lower()] = str(aliases[k])
			if bic_inst.has_method("_register_alias_commands"):
				bic_inst._register_alias_commands()
		else:
			(summary["warnings"] as Array).append("BuiltInCommands instance not reachable, alias commands will activate on next plugin reload")
		summary["aliases"] = aliases.size()

	# pins -> rewrite user://pinned_commands.json in the schema
	# PinnedCommandCommands expects, then ask the live instance to reload.
	var pins_v: Variant = bundle.get("pins", [])
	if pins_v is Array:
		var pins: Array = pins_v
		var clean: Array = []
		for p in pins:
			if not (p is Dictionary):
				continue
			var cmd: String = str((p as Dictionary).get("command", "")).strip_edges()
			if cmd.is_empty():
				continue
			clean.append({"command": cmd, "label": str((p as Dictionary).get("label", ""))})
		var payload: Dictionary = {
			"version": 1,
			"timestamp": int(Time.get_unix_time_from_system()),
			"pins": clean,
		}
		var f := FileAccess.open(_PINS_PATH, FileAccess.WRITE)
		if f:
			f.store_string(JSON.stringify(payload, "  "))
			f.close()
			summary["pins"] = clean.size()
		else:
			(summary["warnings"] as Array).append("Failed to write %s" % _PINS_PATH)
		var pin_inst := _find_extension(_PIN_SCRIPT)
		if pin_inst and pin_inst.has_method("_load_pins"):
			pin_inst._load_pins()

	# repl_vars -> live PersistentReplCommands._vars only (no on-disk mirror).
	var rv_v: Variant = bundle.get("repl_vars", {})
	if rv_v is Dictionary:
		var rv: Dictionary = rv_v
		var repl_inst := _find_extension(_REPL_SCRIPT)
		if repl_inst and "_vars" in repl_inst:
			(repl_inst._vars as Dictionary).clear()
			for k in rv.keys():
				var raw: Variant = rv[k]
				var value: Variant = str_to_var(str(raw)) if raw is String else raw
				(repl_inst._vars as Dictionary)[str(k)] = value
			summary["repl_vars"] = rv.size()
		elif not rv.is_empty():
			(summary["warnings"] as Array).append("PersistentReplCommands not loaded, %d repl var(s) skipped" % rv.size())

	# watches -> re-issue wp_add / wp_break through the registry. That
	# rebuilds the node lookup and the polling state correctly; raw dict
	# restoration would leak stale Node references from the previous run.
	var watches_v: Variant = bundle.get("watches", [])
	if watches_v is Array:
		for w in (watches_v as Array):
			if not (w is Dictionary):
				continue
			var node_path: String = str((w as Dictionary).get("node_path", "")).strip_edges()
			var prop: String = str((w as Dictionary).get("prop", "")).strip_edges()
			if node_path.is_empty() or prop.is_empty():
				summary["watches_skipped"] = int(summary["watches_skipped"]) + 1
				continue
			var cmd: String = "wp_break" if bool((w as Dictionary).get("break", false)) else "wp_add"
			if not _registry or not _registry.has_method("execute_command"):
				summary["watches_skipped"] = int(summary["watches_skipped"]) + 1
				continue
			var result: Variant = _registry.execute_command("%s %s.%s" % [cmd, node_path, prop])
			var text: String = str(result)
			# wp_* commands return BBCode-formatted errors; detect both
			# the "Error:" prefix from this module's siblings and the
			# explicit registry "command not found" path so a missing
			# WatchpointCommands module doesn't silently inflate the
			# success count.
			if text.findn("Error:") != -1 or text.findn("not found") != -1 or text.findn("Usage:") != -1:
				summary["watches_skipped"] = int(summary["watches_skipped"]) + 1
			else:
				summary["watches"] = int(summary["watches"]) + 1

	return summary

#endregion

#region Diff

func _diff_bundles(name_a: String, a: Dictionary, name_b: String, b: Dictionary) -> String:
	var lines: Array[String] = []
	lines.append("Diff: %s vs %s" % [_color_path(name_a), _color_path(name_b)])

	# Scalar: current_directory
	var cwd_a: String = str(a.get("current_directory", ""))
	var cwd_b: String = str(b.get("current_directory", ""))
	if cwd_a != cwd_b:
		lines.append("  cwd          %s -> %s" % [_color_path(cwd_a), _color_path(cwd_b)])
	else:
		lines.append("  cwd          (same: %s)" % _color_path(cwd_a))

	# Counted: history
	var hist_a: int = (a.get("history", []) as Array).size() if a.get("history") is Array else 0
	var hist_b: int = (b.get("history", []) as Array).size() if b.get("history") is Array else 0
	lines.append("  history      lines %s -> %s (Δ %s)" % [
		_color_number(str(hist_a)),
		_color_number(str(hist_b)),
		_signed(hist_b - hist_a),
	])

	# Dict diffs (added / removed / changed).
	var ali_a: Dictionary = (a.get("aliases", {}) as Dictionary) if a.get("aliases") is Dictionary else {}
	var ali_b: Dictionary = (b.get("aliases", {}) as Dictionary) if b.get("aliases") is Dictionary else {}
	_append_dict_diff(lines, "aliases", ali_a, ali_b)

	var rv_a: Dictionary = (a.get("repl_vars", {}) as Dictionary) if a.get("repl_vars") is Dictionary else {}
	var rv_b: Dictionary = (b.get("repl_vars", {}) as Dictionary) if b.get("repl_vars") is Dictionary else {}
	_append_dict_diff(lines, "repl_vars", rv_a, rv_b)

	# Set diffs (added / removed; treat key as identity).
	_append_set_diff(lines, "pins", _pin_keys(a), _pin_keys(b))
	_append_set_diff(lines, "watches", _watch_keys(a), _watch_keys(b))

	return "\n".join(lines)

func _append_dict_diff(lines: Array[String], label: String, a: Dictionary, b: Dictionary) -> void:
	var added: Array[String] = []
	var removed: Array[String] = []
	var changed: Array[String] = []
	for k in b.keys():
		if not a.has(k):
			added.append(str(k))
		elif str(a[k]) != str(b[k]):
			changed.append(str(k))
	for k in a.keys():
		if not b.has(k):
			removed.append(str(k))
	added.sort()
	removed.sort()
	changed.sort()
	lines.append("  %-12s +%s  -%s  ~%s" % [
		label,
		_color_number(str(added.size())),
		_color_number(str(removed.size())),
		_color_number(str(changed.size())),
	])
	if not added.is_empty():
		lines.append("    + %s" % ", ".join(added))
	if not removed.is_empty():
		lines.append("    - %s" % ", ".join(removed))
	if not changed.is_empty():
		lines.append("    ~ %s" % ", ".join(changed))

func _append_set_diff(lines: Array[String], label: String, a: Array, b: Array) -> void:
	var set_a: Dictionary = {}
	var set_b: Dictionary = {}
	for k in a: set_a[k] = true
	for k in b: set_b[k] = true
	var added: Array[String] = []
	var removed: Array[String] = []
	for k in set_b.keys():
		if not set_a.has(k):
			added.append(str(k))
	for k in set_a.keys():
		if not set_b.has(k):
			removed.append(str(k))
	added.sort()
	removed.sort()
	lines.append("  %-12s +%s  -%s" % [
		label,
		_color_number(str(added.size())),
		_color_number(str(removed.size())),
	])
	if not added.is_empty():
		lines.append("    + %s" % ", ".join(added))
	if not removed.is_empty():
		lines.append("    - %s" % ", ".join(removed))

func _pin_keys(bundle: Dictionary) -> Array:
	var out: Array = []
	var arr: Variant = bundle.get("pins", [])
	if not (arr is Array):
		return out
	for p in (arr as Array):
		if p is Dictionary:
			out.append(str((p as Dictionary).get("command", "")))
	return out

func _watch_keys(bundle: Dictionary) -> Array:
	var out: Array = []
	var arr: Variant = bundle.get("watches", [])
	if not (arr is Array):
		return out
	for w in (arr as Array):
		if w is Dictionary:
			out.append("%s.%s" % [
				str((w as Dictionary).get("node_path", "")),
				str((w as Dictionary).get("prop", "")),
			])
	return out

func _signed(n: int) -> String:
	return ("+%d" % n) if n >= 0 else str(n)

#endregion

#region Helpers

func _sanitize_name(raw: String) -> String:
	var s := raw.strip_edges()
	if s.is_empty() or s.length() > _NAME_MAX_LEN:
		return ""
	# Allow letters, digits, '_', '-', '.'. Reject path separators, '..',
	# leading dot (hidden file) and anything else to keep the snapshot
	# strictly inside user://sessions/.
	if s == "." or s == ".." or s.begins_with("."):
		return ""
	for i in range(s.length()):
		var c := s.substr(i, 1)
		var is_alpha := (c >= "a" and c <= "z") or (c >= "A" and c <= "Z")
		var is_digit := c >= "0" and c <= "9"
		if not (is_alpha or is_digit or c == "_" or c == "-" or c == "."):
			return ""
	return s

func _path_for(name: String) -> String:
	return "%s/%s.json" % [_SESSIONS_DIR, name]

func _ensure_sessions_dir() -> String:
	if DirAccess.dir_exists_absolute(_SESSIONS_DIR):
		return ""
	var err := DirAccess.make_dir_recursive_absolute(_SESSIONS_DIR)
	if err != OK:
		return "Cannot create %s (err %d)" % [_SESSIONS_DIR, err]
	return ""

func _list_session_names() -> Array[String]:
	var out: Array[String] = []
	if not DirAccess.dir_exists_absolute(_SESSIONS_DIR):
		return out
	var dir := DirAccess.open(_SESSIONS_DIR)
	if not dir:
		return out
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while not entry.is_empty():
		if not dir.current_is_dir() and entry.ends_with(".json"):
			out.append(entry.get_basename())
		entry = dir.get_next()
	dir.list_dir_end()
	out.sort()
	return out

func _write_json(path: String, payload: Dictionary) -> String:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if not f:
		return "Cannot open %s for write (err %d)" % [path, FileAccess.get_open_error()]
	f.store_string(JSON.stringify(payload, "  "))
	f.close()
	return ""

func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return "No such session file: %s" % path
	var f := FileAccess.open(path, FileAccess.READ)
	if not f:
		return "Cannot open %s (err %d)" % [path, FileAccess.get_open_error()]
	var text: String = f.get_as_text()
	f.close()
	if text.strip_edges().is_empty():
		return "Empty snapshot: %s" % path
	var parsed: Variant = JSON.parse_string(text)
	if parsed == null:
		return "Snapshot is not valid JSON: %s" % path
	return parsed

func _peek_meta(path: String) -> Dictionary:
	var out: Dictionary = {
		"timestamp": 0, "iso_time": "",
		"history": 0, "aliases": 0, "pins": 0, "repl_vars": 0, "watches": 0,
	}
	var parsed: Variant = _read_json(path)
	if not (parsed is Dictionary):
		return out
	var d: Dictionary = parsed
	out["timestamp"] = int(d.get("timestamp", 0))
	out["iso_time"] = str(d.get("iso_time", ""))
	out["history"] = (d.get("history", []) as Array).size() if d.get("history") is Array else 0
	out["aliases"] = (d.get("aliases", {}) as Dictionary).size() if d.get("aliases") is Dictionary else 0
	out["pins"] = (d.get("pins", []) as Array).size() if d.get("pins") is Array else 0
	out["repl_vars"] = (d.get("repl_vars", {}) as Dictionary).size() if d.get("repl_vars") is Dictionary else 0
	out["watches"] = (d.get("watches", []) as Array).size() if d.get("watches") is Array else 0
	return out

func _summarize_bundle(bundle: Dictionary) -> String:
	return "  history=%s cwd=%s aliases=%s pins=%s repl_vars=%s watches=%s" % [
		_color_number(str((bundle.get("history", []) as Array).size())),
		_color_path(str(bundle.get("current_directory", ""))),
		_color_number(str((bundle.get("aliases", {}) as Dictionary).size())),
		_color_number(str((bundle.get("pins", []) as Array).size())),
		_color_number(str((bundle.get("repl_vars", {}) as Dictionary).size())),
		_color_number(str((bundle.get("watches", []) as Array).size())),
	]

func _find_extension(script_path: String) -> Object:
	# Walks BuiltInCommands' two static module arrays (T6 = core modules,
	# T8 = extensions/) and returns the first instance whose script
	# resource_path matches. Returns null if the module hasn't been loaded
	# yet - the orchestrator populates these arrays the first time
	# register_universal_commands runs, so this works as soon as the
	# console has been touched.
	var arrays: Array = []
	if BuiltInCommands._t8_extensions is Array:
		arrays.append(BuiltInCommands._t8_extensions)
	if BuiltInCommands._t6_keepalive is Array:
		arrays.append(BuiltInCommands._t6_keepalive)
	for arr in arrays:
		for m in arr:
			if m == null:
				continue
			var s: Script = m.get_script()
			if s and s.resource_path == script_path:
				return m
	return null

func _find_built_in_instance() -> Object:
	# The orchestrator does NOT register itself in its own keepalive
	# arrays, so we recover it from the "alias" command Callable that it
	# binds to itself when register_universal_commands runs. Any of its
	# self-bound built-ins would work; "alias" was picked because it's
	# the most stable - the alias command exists in every plugin build.
	if not _registry or not ("_commands" in _registry):
		return null
	var commands: Variant = _registry._commands
	if not (commands is Dictionary):
		return null
	var entry: Variant = (commands as Dictionary).get("alias", null)
	if not (entry is Dictionary):
		return null
	var cb: Callable = (entry as Dictionary).get("callable", Callable())
	if not cb.is_valid():
		return null
	var obj: Object = cb.get_object()
	if obj == null:
		return null
	var s: Script = obj.get_script()
	if s and s.resource_path == _BIC_SCRIPT:
		return obj
	return null

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

#endregion

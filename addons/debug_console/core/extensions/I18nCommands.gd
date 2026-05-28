@tool
class_name DebugConsoleI18nCommands extends RefCounted

# Tier 6 extension - localization / TranslationServer commands. Follows the
# same shape as SceneCommands.gd: the orchestrator instantiates one of these,
# holds a strong reference to it, and calls register_commands(registry, core).
# Every command is registered for the "both" context so they work in editor
# and at runtime.

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
	_registry.register_command("i18n_get", _cmd_i18n_get, "Translate a key in the active locale: i18n_get <key>", "both")
	_registry.register_command("i18n_locale", _cmd_i18n_locale, "Get or set the active locale: i18n_locale [code]", "both")
	_registry.register_command("i18n_locales", _cmd_i18n_locales, "List all loaded translations with their key counts", "both")
	_registry.register_command("i18n_load", _cmd_i18n_load, "Load translations from a CSV file: i18n_load <res://file.csv> [delimiter]", "both")
	_registry.register_command("i18n_missing", _cmd_i18n_missing, "Compare every locale against locale[0] and report missing keys", "both")
	_registry.register_command("i18n_keys", _cmd_i18n_keys, "List the union of translation keys across all loaded locales", "both")
	_registry.register_command("i18n_test", _cmd_i18n_test, "Temporarily switch locale, scan tree Labels, then restore: i18n_test <locale>", "both")

#region Command implementations

func _cmd_i18n_get(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: i18n_get <key>")
	var key := str(args[0]).strip_edges()
	if key.is_empty():
		return _format_error("Key is empty")
	var value: String = TranslationServer.translate(key)
	return "%s = \"%s\" [locale=%s]" % [_color_path(key), value, _color_path(TranslationServer.get_locale())]

func _cmd_i18n_locale(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		var current: String = TranslationServer.get_locale()
		var loaded: PackedStringArray = TranslationServer.get_loaded_locales()
		var lines: Array[String] = []
		lines.append("Active locale: %s" % _color_path(current))
		lines.append("Loaded locales (%s):" % _color_number(str(loaded.size())))
		if loaded.is_empty():
			lines.append("  (none)")
		else:
			for l in loaded:
				lines.append("  %s" % _color_path(str(l)))
		return "\n".join(lines)
	var code := str(args[0]).strip_edges()
	if code.is_empty():
		return _format_error("Locale code is empty")
	var previous: String = TranslationServer.get_locale()
	TranslationServer.set_locale(code)
	return _format_success("Locale: %s -> %s" % [_color_path(previous), _color_path(TranslationServer.get_locale())])

func _cmd_i18n_locales(args: Array, piped_input: String = "") -> String:
	var loaded: PackedStringArray = TranslationServer.get_loaded_locales()
	if loaded.is_empty():
		return "(no translations loaded)"
	var lines: Array[String] = []
	lines.append("Loaded translations (%s):" % _color_number(str(loaded.size())))
	for l in loaded:
		var locale_str := str(l)
		var tr_obj: Translation = TranslationServer.get_translation_object(locale_str)
		var count: int = 0
		if tr_obj:
			count = tr_obj.get_message_count()
		lines.append("  %s  %s keys" % [_color_path(locale_str), _color_number(str(count))])
	return "\n".join(lines)

func _cmd_i18n_load(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: i18n_load <res://path.csv> [delimiter]")
	var path := str(args[0]).strip_edges()
	var delim := str(args[1]).strip_edges() if args.size() > 1 else ","
	if delim.is_empty():
		delim = ","

	if not FileAccess.file_exists(path):
		return _format_error("File not found: %s" % path)
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		return _format_error("Cannot open %s (error %s)" % [path, FileAccess.get_open_error()])

	var header: PackedStringArray = file.get_csv_line(delim)
	if header.size() < 2:
		file.close()
		return _format_error("CSV must have a key column plus at least one locale column")

	var translations: Array[Translation] = []
	for i in range(1, header.size()):
		var locale_code := str(header[i]).strip_edges()
		if locale_code.is_empty():
			continue
		var t := Translation.new()
		t.locale = locale_code
		translations.append(t)

	var rows: int = 0
	while not file.eof_reached():
		var row: PackedStringArray = file.get_csv_line(delim)
		if row.size() < 2:
			continue
		var key := str(row[0]).strip_edges()
		if key.is_empty():
			continue
		for i in range(translations.size()):
			var col := i + 1
			if col < row.size():
				translations[i].add_message(key, str(row[col]))
		rows += 1
	file.close()

	for t in translations:
		TranslationServer.add_translation(t)

	var locale_names: Array[String] = []
	for t in translations:
		locale_names.append(str(t.locale))
	return _format_success("Loaded %s rows from %s into %s locale(s): %s" % [
		_color_number(str(rows)),
		_color_path(path),
		_color_number(str(translations.size())),
		", ".join(locale_names),
	])

func _cmd_i18n_missing(args: Array, piped_input: String = "") -> String:
	var loaded: PackedStringArray = TranslationServer.get_loaded_locales()
	if loaded.size() < 2:
		return _format_error("Need at least 2 loaded locales to compare (have %s)" % loaded.size())

	var ref_locale := str(loaded[0])
	var ref_obj: Translation = TranslationServer.get_translation_object(ref_locale)
	if not ref_obj:
		return _format_error("Cannot resolve reference locale: %s" % ref_locale)

	var ref_keys: PackedStringArray = ref_obj.get_message_list()
	var lines: Array[String] = []
	lines.append("Reference locale: %s [%s keys]" % [_color_path(ref_locale), _color_number(str(ref_keys.size()))])

	var total_missing: int = 0
	for i in range(1, loaded.size()):
		var lc := str(loaded[i])
		var obj: Translation = TranslationServer.get_translation_object(lc)
		if not obj:
			lines.append("  %s  (translation object unavailable)" % _color_path(lc))
			continue
		var has := {}
		for k in obj.get_message_list():
			has[str(k)] = true
		var missing: Array[String] = []
		for k in ref_keys:
			if not has.has(str(k)):
				missing.append(str(k))
		total_missing += missing.size()
		lines.append("  %s  missing %s key(s)" % [_color_path(lc), _color_number(str(missing.size()))])
		for m in missing:
			lines.append("    - %s" % m)

	if total_missing == 0:
		lines.append(_format_success("All locales fully cover the reference locale"))
	else:
		lines.append("Total missing entries: %s" % _color_number(str(total_missing)))
	return "\n".join(lines)

func _cmd_i18n_keys(args: Array, piped_input: String = "") -> String:
	var loaded: PackedStringArray = TranslationServer.get_loaded_locales()
	if loaded.is_empty():
		return "(no translations loaded)"
	var union := {}
	for lc in loaded:
		var obj: Translation = TranslationServer.get_translation_object(str(lc))
		if not obj:
			continue
		for k in obj.get_message_list():
			union[str(k)] = true
	var keys: Array = union.keys()
	keys.sort()
	var lines: Array[String] = []
	lines.append("Translation keys (%s unique across %s locale(s)):" % [
		_color_number(str(keys.size())),
		_color_number(str(loaded.size())),
	])
	if keys.is_empty():
		lines.append("  (no keys found)")
	else:
		for k in keys:
			lines.append("  %s" % str(k))
	return "\n".join(lines)

func _cmd_i18n_test(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: i18n_test <locale>")
	var target := str(args[0]).strip_edges()
	if target.is_empty():
		return _format_error("Locale code is empty")

	var previous: String = TranslationServer.get_locale()
	TranslationServer.set_locale(target)
	var applied: String = TranslationServer.get_locale()

	var root := _get_scene_root()
	if not root:
		TranslationServer.set_locale(previous)
		return _format_error("No scene root available to scan")

	var labels: Array[Label] = []
	_collect_labels(root, labels)

	var lines: Array[String] = []
	lines.append("Locale: %s -> %s (temporary)" % [_color_path(previous), _color_path(applied)])
	lines.append("Scanned %s Label node(s):" % _color_number(str(labels.size())))
	for lbl in labels:
		var lpath: String = str(lbl.get_path()) if lbl.is_inside_tree() else lbl.name
		var raw: String = lbl.text
		var translated: String = TranslationServer.translate(raw) if not raw.is_empty() else ""
		lines.append("  %s : \"%s\" -> \"%s\"" % [_color_path(lpath), raw, translated])

	TranslationServer.set_locale(previous)
	lines.append(_format_success("Restored locale to %s" % _color_path(previous)))
	return "\n".join(lines)

#endregion

#region Helpers

func _collect_labels(node: Node, out: Array[Label]) -> void:
	if node is Label:
		out.append(node)
	for child in node.get_children():
		_collect_labels(child, out)

func _get_scene_root() -> Node:
	if Engine.is_editor_hint():
		return EditorInterface.get_edited_scene_root()
	var tree := Engine.get_main_loop() as SceneTree
	if not tree:
		return null
	if tree.current_scene:
		return tree.current_scene
	return tree.root

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

#endregion

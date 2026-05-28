@tool
class_name DebugConsoleDiagnosticCommands extends RefCounted

# One-shot comprehensive diagnostics extension. The "give me everything"
# command for bug reports: a single `diag` invocation gathers OS info,
# Godot version, project settings, autoload list, scene tree summary,
# performance counters, recent errors, captured logs, memory, and the
# enabled-addon list into one plain-text dump that can be pasted into an
# issue tracker.
#
# Follows the SceneCommands / MemorySnapshotCommands pattern: the
# orchestrator (BuiltInCommands.register_universal_commands) instantiates
# this RefCounted, holds a strong reference to it, and calls
# register_commands(registry, core). All Callables are bound to that
# instance so they stay valid for the plugin's lifetime.
#
# The section bodies are intentionally plain text (no BBCode) so they
# render cleanly in saved files and bug-report pastes. The console wrapper
# only adds colour to section headers / status lines, leaving the body
# verbatim. That also keeps `diag_compare` reliable: two files saved via
# `diag_save` can be diffed without colour-tag noise.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_HEADER := "#9FD8FF"
const _COLOR_DIM := "#888888"
const _COLOR_ADD := "#7CFC8C"
const _COLOR_REMOVE := "#FF6B6B"

const _SECTION_NAMES: Array[String] = [
	"os", "godot", "project", "scene", "perf", "errors", "memory", "addons", "logs",
]
const _SECTION_HEADER_PREFIX := "=== SECTION: "
const _SECTION_HEADER_SUFFIX := " ==="
const _LOG_TAIL_DEFAULT := 50

var _registry: Node
var _core: Node

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("diag", _cmd_diag, "Comprehensive diagnostics snapshot (OS/Godot/project/scene/perf/errors/memory/addons/logs)", "both")
	_registry.register_command("diag_save", _cmd_diag_save, "Save a diag dump to a file: diag_save <user://path.txt>", "both")
	_registry.register_command("diag_section", _cmd_diag_section, "Run a single diag section: diag_section <os|godot|project|scene|perf|errors|memory|addons>", "both")
	_registry.register_command("diag_compare", _cmd_diag_compare, "Diff two diag dump files: diag_compare <res://a.txt> <res://b.txt>", "both")
	_registry.register_command("diag_versions", _cmd_diag_versions, "Print Godot / OS / addon versions only", "both")
	_registry.register_command("diag_minimal", _cmd_diag_minimal, "Compact ~10 line snapshot for quick bug reports", "both")

#region Command implementations

func _cmd_diag(args: Array, piped_input: String = "") -> String:
	var dump: String = _build_full_dump()
	return _colorize_dump(dump)

func _cmd_diag_save(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: diag_save <user://path.txt>")
	var path: String = str(args[0]).strip_edges()
	if path.is_empty():
		return _format_error("Empty path")

	var dump: String = _build_full_dump()
	var file := FileAccess.open(path, FileAccess.WRITE)
	if not file:
		var err: int = FileAccess.get_open_error()
		return _format_error("Cannot open '%s' for write (err=%d)" % [path, err])
	file.store_string(dump)
	file.close()

	var line_count: int = dump.count("\n") + 1
	return _format_success("Saved diag dump (%s lines) to %s" % [
		_color_number(str(line_count)),
		_color_path(path),
	])

func _cmd_diag_section(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: diag_section <%s>" % "|".join(_SECTION_NAMES))
	var name: String = str(args[0]).strip_edges().to_lower()
	if not _SECTION_NAMES.has(name):
		return _format_error("Unknown section '%s' (expected one of: %s)" % [
			name, ", ".join(_SECTION_NAMES),
		])
	var body: String = _build_section(name)
	return _colorize_dump(_format_section(name, body))

func _cmd_diag_compare(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: diag_compare <path_a> <path_b>")
	var path_a: String = str(args[0]).strip_edges()
	var path_b: String = str(args[1]).strip_edges()
	var read_a := _read_text_file(path_a)
	if read_a.has("error"):
		return _format_error(str(read_a["error"]))
	var read_b := _read_text_file(path_b)
	if read_b.has("error"):
		return _format_error(str(read_b["error"]))

	return _diff_dumps(str(read_a["text"]), str(read_b["text"]), path_a, path_b)

func _cmd_diag_versions(args: Array, piped_input: String = "") -> String:
	var lines: Array[String] = []
	var v: Dictionary = Engine.get_version_info()
	lines.append("Godot:    %s (%s)" % [str(v.get("string", "?")), str(v.get("status", "?"))])
	lines.append("Build:    %s (%s)" % [
		"debug" if OS.is_debug_build() else "release",
		str(v.get("build", "?")),
	])
	lines.append("OS:       %s %s" % [OS.get_name(), OS.get_distribution_name()])
	lines.append("Version:  %s" % OS.get_version())
	lines.append("Model:    %s" % OS.get_model_name())
	var addons: Array = _list_addons()
	if addons.is_empty():
		lines.append("Addons:   (none under res://addons)")
	else:
		lines.append("Addons:")
		for a in addons:
			lines.append("  - %s v%s%s" % [
				str(a.get("name", a.get("dir", "?"))),
				str(a.get("version", "?")),
				"" if bool(a.get("enabled", false)) else "  (disabled)",
			])
	var body: String = "\n".join(lines)
	return _colorize_dump(_format_section("versions", body))

func _cmd_diag_minimal(args: Array, piped_input: String = "") -> String:
	# Roughly 10 lines: enough to triage a bug report at a glance.
	var v: Dictionary = Engine.get_version_info()
	var fps: float = Performance.get_monitor(Performance.TIME_FPS)
	var static_mem: int = int(Performance.get_monitor(Performance.MEMORY_STATIC))
	var nodes: int = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	var orphans: int = int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
	var scene_path: String = _current_scene_path()
	var main_scene: String = str(ProjectSettings.get_setting("application/run/main_scene", ""))
	var proj_name: String = str(ProjectSettings.get_setting("application/config/name", "(unnamed)"))
	var error_count: int = _recent_errors(_LOG_TAIL_DEFAULT).size()
	var addon_count: int = _list_addons().size()

	var lines: Array[String] = []
	lines.append("# %s @ %s" % [proj_name, Time.get_datetime_string_from_system()])
	lines.append("godot=%s (%s, %s)" % [
		str(v.get("string", "?")),
		str(v.get("status", "?")),
		"debug" if OS.is_debug_build() else "release",
	])
	lines.append("os=%s %s | %s" % [OS.get_name(), OS.get_version(), OS.get_distribution_name()])
	lines.append("ctx=%s | scene=%s | main=%s" % [
		"editor" if Engine.is_editor_hint() else "runtime",
		scene_path,
		main_scene if not main_scene.is_empty() else "(unset)",
	])
	lines.append("fps=%.1f | nodes=%d | orphans=%d | mem=%s" % [
		fps, nodes, orphans, _format_bytes(static_mem),
	])
	lines.append("recent_errors=%d | addons=%d" % [error_count, addon_count])
	lines.append("# end diag_minimal")
	return _colorize_dump(_format_section("minimal", "\n".join(lines)))

#endregion

#region Dump assembly

func _build_full_dump() -> String:
	var parts: Array[String] = []
	parts.append("# Debug Console Diagnostic Dump")
	parts.append("# Generated: %s" % Time.get_datetime_string_from_system())
	parts.append("# Context:   %s" % ("editor" if Engine.is_editor_hint() else "runtime"))
	parts.append("")
	for name in _SECTION_NAMES:
		parts.append(_format_section(name, _build_section(name)))
	return "\n".join(parts)

func _build_section(name: String) -> String:
	match name:
		"os": return _section_os()
		"godot": return _section_godot()
		"project": return _section_project()
		"scene": return _section_scene()
		"perf": return _section_perf()
		"errors": return _section_errors()
		"memory": return _section_memory()
		"addons": return _section_addons()
		"logs": return _section_logs()
		_: return "(unknown section: %s)" % name

func _format_section(name: String, body: String) -> String:
	return "%s%s%s\n%s\n" % [
		_SECTION_HEADER_PREFIX,
		name.to_upper(),
		_SECTION_HEADER_SUFFIX,
		body,
	]

#endregion

#region Sections

func _section_os() -> String:
	var lines: Array[String] = []
	lines.append("name              = %s" % OS.get_name())
	lines.append("distribution      = %s" % OS.get_distribution_name())
	lines.append("version           = %s" % OS.get_version())
	lines.append("model             = %s" % OS.get_model_name())
	lines.append("processor         = %s" % OS.get_processor_name())
	lines.append("processor_count   = %d" % OS.get_processor_count())
	lines.append("locale            = %s" % OS.get_locale())
	lines.append("locale_language   = %s" % OS.get_locale_language())
	lines.append("user_data_dir     = %s" % OS.get_user_data_dir())
	lines.append("executable_path   = %s" % OS.get_executable_path())
	lines.append("cmdline_args      = %s" % str(OS.get_cmdline_args()))
	lines.append("debug_build       = %s" % str(OS.is_debug_build()))
	lines.append("primary_screen    = %d" % DisplayServer.get_primary_screen())
	lines.append("screen_count      = %d" % DisplayServer.get_screen_count())
	var size: Vector2i = DisplayServer.screen_get_size()
	lines.append("screen_size       = %dx%d" % [size.x, size.y])
	lines.append("screen_dpi        = %d" % DisplayServer.screen_get_dpi())
	lines.append("screen_refresh_hz = %.2f" % DisplayServer.screen_get_refresh_rate())
	return "\n".join(lines)

func _section_godot() -> String:
	var v: Dictionary = Engine.get_version_info()
	var lines: Array[String] = []
	lines.append("version_string    = %s" % str(v.get("string", "?")))
	lines.append("major.minor.patch = %s.%s.%s" % [
		str(v.get("major", "?")), str(v.get("minor", "?")), str(v.get("patch", "?")),
	])
	lines.append("status            = %s" % str(v.get("status", "?")))
	lines.append("build             = %s" % str(v.get("build", "?")))
	lines.append("hash              = %s" % str(v.get("hash", "?")))
	lines.append("year              = %s" % str(v.get("year", "?")))
	lines.append("is_editor_hint    = %s" % str(Engine.is_editor_hint()))
	lines.append("physics_ticks/s   = %d" % Engine.physics_ticks_per_second)
	lines.append("max_fps           = %d" % Engine.max_fps)
	lines.append("time_scale        = %s" % str(Engine.time_scale))
	lines.append("frames_drawn      = %d" % Engine.get_frames_drawn())
	lines.append("process_frames    = %d" % Engine.get_process_frames())
	lines.append("physics_frames    = %d" % Engine.get_physics_frames())
	return "\n".join(lines)

func _section_project() -> String:
	var lines: Array[String] = []
	lines.append("name              = %s" % str(ProjectSettings.get_setting("application/config/name", "(unnamed)")))
	lines.append("description       = %s" % str(ProjectSettings.get_setting("application/config/description", "")))
	lines.append("version           = %s" % str(ProjectSettings.get_setting("application/config/version", "")))
	lines.append("main_scene        = %s" % str(ProjectSettings.get_setting("application/run/main_scene", "")))
	lines.append("renderer          = %s" % str(ProjectSettings.get_setting("rendering/renderer/rendering_method", "?")))
	lines.append("mobile_renderer   = %s" % str(ProjectSettings.get_setting("rendering/renderer/rendering_method.mobile", "?")))
	var ws: Vector2i = Vector2i(
		int(ProjectSettings.get_setting("display/window/size/viewport_width", 0)),
		int(ProjectSettings.get_setting("display/window/size/viewport_height", 0)),
	)
	lines.append("window_size       = %dx%d" % [ws.x, ws.y])
	lines.append("physics_3d_engine = %s" % str(ProjectSettings.get_setting("physics/3d/physics_engine", "?")))
	lines.append("physics_2d_engine = %s" % str(ProjectSettings.get_setting("physics/2d/physics_engine", "?")))

	lines.append("")
	lines.append("autoloads:")
	var autoloads: Array = _list_autoloads()
	if autoloads.is_empty():
		lines.append("  (none)")
	else:
		for entry in autoloads:
			lines.append("  - %s = %s%s" % [
				str(entry.get("name", "?")),
				str(entry.get("path", "?")),
				"  (singleton)" if bool(entry.get("singleton", false)) else "",
			])
	return "\n".join(lines)

func _section_scene() -> String:
	var lines: Array[String] = []
	var loop := Engine.get_main_loop()
	if not (loop is SceneTree):
		lines.append("(no SceneTree available)")
		return "\n".join(lines)

	var tree: SceneTree = loop
	var current: Node = tree.current_scene
	lines.append("current_scene     = %s" % (current.scene_file_path if current else "(none)"))
	lines.append("current_node      = %s" % (str(current.get_path()) if current else "(none)"))

	var root: Node = tree.root
	if root:
		lines.append("root              = %s" % str(root.get_path()))
		lines.append("root_children     = %d" % root.get_child_count())
		var total: int = _count_descendants(root)
		lines.append("total_nodes       = %d" % total)
		lines.append("")
		lines.append("root child summary:")
		for child in root.get_children():
			lines.append("  - %s [%s] children=%d" % [
				child.name, child.get_class(), child.get_child_count(),
			])
	else:
		lines.append("(no root)")

	if current:
		lines.append("")
		lines.append("current_scene top-level nodes:")
		for child in current.get_children():
			lines.append("  - %s [%s] children=%d" % [
				child.name, child.get_class(), child.get_child_count(),
			])
	return "\n".join(lines)

func _section_perf() -> String:
	var lines: Array[String] = []
	lines.append("fps               = %.2f" % Performance.get_monitor(Performance.TIME_FPS))
	lines.append("frame_time_ms     = %.3f" % (Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0))
	lines.append("physics_time_ms   = %.3f" % (Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0))
	lines.append("nav_time_ms       = %.3f" % (Performance.get_monitor(Performance.TIME_NAVIGATION_PROCESS) * 1000.0))
	lines.append("draw_calls/frame  = %d" % int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)))
	lines.append("primitives/frame  = %d" % int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)))
	lines.append("objects_drawn     = %d" % int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)))
	lines.append("audio_latency_ms  = %.3f" % (Performance.get_monitor(Performance.AUDIO_OUTPUT_LATENCY) * 1000.0))
	lines.append("physics_active_2d = %d" % int(Performance.get_monitor(Performance.PHYSICS_2D_ACTIVE_OBJECTS)))
	lines.append("physics_active_3d = %d" % int(Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS)))
	return "\n".join(lines)

func _section_errors() -> String:
	var errors: Array[String] = _recent_errors(_LOG_TAIL_DEFAULT)
	if errors.is_empty():
		return "(no recent ERROR-level log entries)"
	var lines: Array[String] = []
	lines.append("count = %d (most recent first)" % errors.size())
	# Reverse iteration: newest first is friendlier in a bug report.
	for i in range(errors.size() - 1, -1, -1):
		lines.append("  %s" % errors[i])
	return "\n".join(lines)

func _section_memory() -> String:
	var lines: Array[String] = []
	lines.append("static_mem        = %s" % _format_bytes(int(Performance.get_monitor(Performance.MEMORY_STATIC))))
	lines.append("static_max        = %s" % _format_bytes(int(Performance.get_monitor(Performance.MEMORY_STATIC_MAX))))
	lines.append("message_buffer    = %s" % _format_bytes(int(Performance.get_monitor(Performance.MEMORY_MESSAGE_BUFFER_MAX))))
	lines.append("video_mem         = %s" % _format_bytes(int(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED))))
	lines.append("texture_mem       = %s" % _format_bytes(int(Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED))))
	lines.append("buffer_mem        = %s" % _format_bytes(int(Performance.get_monitor(Performance.RENDER_BUFFER_MEM_USED))))
	lines.append("objects           = %d" % int(Performance.get_monitor(Performance.OBJECT_COUNT)))
	lines.append("resources         = %d" % int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)))
	lines.append("nodes             = %d" % int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)))
	lines.append("orphan_nodes      = %d" % int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)))
	return "\n".join(lines)

func _section_addons() -> String:
	var addons: Array = _list_addons()
	if addons.is_empty():
		return "(no plugins found under res://addons)"
	var lines: Array[String] = []
	lines.append("count = %d" % addons.size())
	for a in addons:
		lines.append("  - dir=%s name=%s version=%s author=%s enabled=%s" % [
			str(a.get("dir", "?")),
			str(a.get("name", "?")),
			str(a.get("version", "?")),
			str(a.get("author", "?")),
			str(a.get("enabled", false)),
		])
	return "\n".join(lines)

func _section_logs() -> String:
	var history: Array[String] = _get_history()
	if history.is_empty():
		return "(no captured log history)"
	var tail_size: int = min(_LOG_TAIL_DEFAULT, history.size())
	var tail: Array = history.slice(history.size() - tail_size)
	var lines: Array[String] = []
	lines.append("showing last %d of %d captured entries" % [tail_size, history.size()])
	for entry in tail:
		lines.append("  %s" % str(entry))
	return "\n".join(lines)

#endregion

#region Diff / comparison

func _diff_dumps(text_a: String, text_b: String, label_a: String, label_b: String) -> String:
	var lines_a: PackedStringArray = text_a.split("\n")
	var lines_b: PackedStringArray = text_b.split("\n")
	# Strip BBCode colour tags so coloured saves still compare cleanly.
	var stripped_a: Array[String] = _strip_color_tags(lines_a)
	var stripped_b: Array[String] = _strip_color_tags(lines_b)

	var set_a: Dictionary = {}
	var set_b: Dictionary = {}
	for line in stripped_a:
		set_a[line] = int(set_a.get(line, 0)) + 1
	for line in stripped_b:
		set_b[line] = int(set_b.get(line, 0)) + 1

	var only_a: Array[String] = []
	var only_b: Array[String] = []
	for line in stripped_a:
		if int(set_b.get(line, 0)) == 0:
			only_a.append(line)
	for line in stripped_b:
		if int(set_a.get(line, 0)) == 0:
			only_b.append(line)

	var out: Array[String] = []
	out.append(_color_header("=== diff: %s vs %s ===" % [label_a, label_b]))
	out.append("a (%s): %d lines" % [label_a, stripped_a.size()])
	out.append("b (%s): %d lines" % [label_b, stripped_b.size()])
	out.append("only in a: %d" % only_a.size())
	out.append("only in b: %d" % only_b.size())
	out.append("")

	if only_a.is_empty() and only_b.is_empty():
		out.append(_format_success("Files are equivalent (ignoring colour tags)."))
		return "\n".join(out)

	if not only_a.is_empty():
		out.append(_color_header("--- only in %s ---" % label_a))
		for line in only_a:
			out.append("[color=%s]- %s[/color]" % [_COLOR_REMOVE, line])
	if not only_b.is_empty():
		if not only_a.is_empty():
			out.append("")
		out.append(_color_header("--- only in %s ---" % label_b))
		for line in only_b:
			out.append("[color=%s]+ %s[/color]" % [_COLOR_ADD, line])
	return "\n".join(out)

func _strip_color_tags(lines: PackedStringArray) -> Array[String]:
	var out: Array[String] = []
	var regex := RegEx.new()
	# Matches [color=...] and [/color]; cheap and good enough for our dumps.
	regex.compile("\\[/?color(=[^\\]]*)?\\]")
	for line in lines:
		out.append(regex.sub(line, "", true))
	return out

#endregion

#region Collectors

func _list_autoloads() -> Array:
	var out: Array = []
	for setting in ProjectSettings.get_property_list():
		var name: String = str(setting.get("name", ""))
		if not name.begins_with("autoload/"):
			continue
		var key: String = name.substr("autoload/".length())
		var raw: String = str(ProjectSettings.get_setting(name, ""))
		var is_singleton: bool = raw.begins_with("*")
		var path: String = raw.substr(1) if is_singleton else raw
		out.append({
			"name": key,
			"path": path,
			"singleton": is_singleton,
		})
	return out

func _list_addons() -> Array:
	var out: Array = []
	var dir := DirAccess.open("res://addons")
	if not dir:
		return out
	var enabled_set: Dictionary = {}
	var enabled_raw: Variant = ProjectSettings.get_setting("editor_plugins/enabled", PackedStringArray())
	if enabled_raw is PackedStringArray or enabled_raw is Array:
		for entry in enabled_raw:
			enabled_set[str(entry)] = true

	dir.list_dir_begin()
	var name: String = dir.get_next()
	while name != "":
		if dir.current_is_dir() and name != "." and name != "..":
			var cfg_path: String = "res://addons/%s/plugin.cfg" % name
			if FileAccess.file_exists(cfg_path):
				var cfg := ConfigFile.new()
				var err: int = cfg.load(cfg_path)
				var entry: Dictionary = {
					"dir": name,
					"path": cfg_path,
					"enabled": bool(enabled_set.get(cfg_path, false)),
				}
				if err == OK:
					entry["name"] = str(cfg.get_value("plugin", "name", name))
					entry["version"] = str(cfg.get_value("plugin", "version", "?"))
					entry["author"] = str(cfg.get_value("plugin", "author", "?"))
					entry["description"] = str(cfg.get_value("plugin", "description", ""))
				else:
					entry["name"] = name
					entry["version"] = "?"
					entry["author"] = "?"
					entry["error"] = "failed to read plugin.cfg (err=%d)" % err
				out.append(entry)
		name = dir.get_next()
	dir.list_dir_end()
	out.sort_custom(func(a, b): return str(a.get("dir", "")) < str(b.get("dir", "")))
	return out

func _recent_errors(limit: int) -> Array[String]:
	var out: Array[String] = []
	var history: Array[String] = _get_history()
	for line in history:
		# DebugCore formats as "[HH:MM:SS] [ERROR] message".
		if line.find("[ERROR]") != -1:
			out.append(line)
	if out.size() > limit:
		out = out.slice(out.size() - limit)
	return out

func _get_history() -> Array[String]:
	var empty: Array[String] = []
	if not _core:
		return empty
	if not _core.has_method("get_history"):
		return empty
	var raw: Variant = _core.get_history()
	if raw is Array:
		var out: Array[String] = []
		for item in raw:
			out.append(str(item))
		return out
	return empty

func _count_descendants(node: Node) -> int:
	var total: int = 1
	for child in node.get_children():
		total += _count_descendants(child)
	return total

func _current_scene_path() -> String:
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		var current: Node = (loop as SceneTree).current_scene
		if current:
			return current.scene_file_path if not current.scene_file_path.is_empty() else str(current.get_path())
	return "(none)"

#endregion

#region File / formatting helpers

func _read_text_file(path: String) -> Dictionary:
	if path.is_empty():
		return {"error": "Empty path"}
	if not FileAccess.file_exists(path):
		return {"error": "File not found: %s" % path}
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		var err: int = FileAccess.get_open_error()
		return {"error": "Cannot open '%s' (err=%d)" % [path, err]}
	var text: String = file.get_as_text()
	file.close()
	return {"text": text}

func _format_bytes(bytes: int) -> String:
	if bytes < 1024:
		return "%d B" % bytes
	var kb: float = float(bytes) / 1024.0
	if kb < 1024.0:
		return "%.2f KB" % kb
	var mb: float = kb / 1024.0
	if mb < 1024.0:
		return "%.2f MB" % mb
	return "%.2f GB" % (mb / 1024.0)

func _colorize_dump(dump: String) -> String:
	# Wrap "=== SECTION: NAME ===" header lines in colour without disturbing
	# the plain-text body. Keeps the on-disk format stable while making the
	# console output skimmable.
	var out: Array[String] = []
	for line in dump.split("\n"):
		var s: String = String(line)
		if s.begins_with(_SECTION_HEADER_PREFIX):
			out.append(_color_header(s))
		elif s.begins_with("#"):
			out.append("[color=%s]%s[/color]" % [_COLOR_DIM, s])
		else:
			out.append(s)
	return "\n".join(out)

func _color_header(s: String) -> String:
	return "[color=%s][b]%s[/b][/color]" % [_COLOR_HEADER, s]

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

#endregion

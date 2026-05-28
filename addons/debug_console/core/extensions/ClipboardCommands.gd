@tool
class_name DebugConsoleClipboardCommands extends RefCounted

# OS clipboard interaction commands. Thin wrapper over `DisplayServer.clipboard_*`
# plus a tiny rolling history so values that briefly hit the clipboard can be
# recovered after they have been overwritten by the OS or another app.
#
# Mirrors the SceneCommands.gd pattern: orchestrator instantiates one of these,
# holds a strong reference, and calls register_commands(registry, core).
#
# RefCounted has no _process, so a small inner Node poller is lazily attached
# to the SceneTree root the first time `clip_history` is invoked. It samples
# `DisplayServer.clipboard_get()` once per second, deduplicates against the
# last sampled value, and pushes new values into a bounded ring buffer. The
# poller holds a weakref back into this extension so it self-frees if the
# plugin is torn down.
#
# All commands run in "both" context. DisplayServer is available in editor and
# game, and file writes use FileAccess which respects user:// / res:// rules.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_MUTED := "#888888"

const _HISTORY_CAPACITY := 50
const _POLL_INTERVAL_SECONDS := 1.0

var _registry: Node
var _core: Node

var _poller: Node = null
var _history: PackedStringArray = PackedStringArray()
var _last_sampled: String = ""
var _has_last_sample: bool = false

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("clip_set", _cmd_clip_set, "Set the OS clipboard to a string: clip_set <text...>", "both", true)
	_registry.register_command("clip_get", _cmd_clip_get, "Print the current OS clipboard contents", "both")
	_registry.register_command("clip_pipe", _cmd_clip_pipe, "Set the OS clipboard from the upstream pipe output: <cmd> | clip_pipe", "both", true)
	_registry.register_command("clip_history", _cmd_clip_history, "Show the rolling clipboard history (polled every 1s, last %d values)" % _HISTORY_CAPACITY, "both")
	_registry.register_command("clip_history_clear", _cmd_clip_history_clear, "Forget the recorded clipboard history", "both")
	_registry.register_command("clip_paste_run", _cmd_clip_paste_run, "Execute the current clipboard contents as a console command line", "both")
	_registry.register_command("clip_dump", _cmd_clip_dump, "Write the current clipboard to a file: clip_dump <user://path or res://path>", "both")

#region Command implementations

func _cmd_clip_set(args: Array, piped_input: String = "") -> String:
	if not _clipboard_available():
		return _format_error("DisplayServer reports no clipboard feature on this platform")
	var text: String = ""
	if args.size() > 0:
		var parts: PackedStringArray = PackedStringArray()
		for a in args:
			parts.append(str(a))
		text = " ".join(parts)
	elif not piped_input.is_empty():
		text = piped_input
	else:
		return _format_error("Usage: clip_set <text...>  (or pipe input: <cmd> | clip_set)")
	DisplayServer.clipboard_set(text)
	_record_sample(text)
	return _format_success("Clipboard set (%s chars)" % _color_number(str(text.length())))

func _cmd_clip_get(_args: Array, _piped_input: String = "") -> String:
	if not _clipboard_available():
		return _format_error("DisplayServer reports no clipboard feature on this platform")
	var text: String = DisplayServer.clipboard_get()
	_record_sample(text)
	if text.is_empty():
		return "%s %s" % [_color_muted("(clipboard empty)"), _color_muted("0 chars")]
	return text

func _cmd_clip_pipe(_args: Array, piped_input: String = "") -> String:
	if not _clipboard_available():
		return _format_error("DisplayServer reports no clipboard feature on this platform")
	if piped_input.is_empty():
		return _format_error("clip_pipe expects upstream pipe output. Usage: <cmd> | clip_pipe")
	DisplayServer.clipboard_set(piped_input)
	_record_sample(piped_input)
	return _format_success("Clipboard set from pipe (%s chars)" % _color_number(str(piped_input.length())))

func _cmd_clip_history(_args: Array, _piped_input: String = "") -> String:
	_ensure_poller()
	if _history.is_empty():
		return "%s %s" % [
			_color_muted("(no history yet; polling every 1s, capacity %d)" % _HISTORY_CAPACITY),
			_color_muted("clip_set or copy something to populate it"),
		]
	var lines: PackedStringArray = PackedStringArray()
	lines.append(_color_muted("Clipboard history (%d / %d, oldest first):" % [_history.size(), _HISTORY_CAPACITY]))
	for i in range(_history.size()):
		var entry: String = _history[i]
		var preview: String = entry.replace("\n", "\\n").replace("\t", "\\t")
		if preview.length() > 200:
			preview = preview.substr(0, 200) + "..."
		lines.append("  [%s] %s" % [_color_number(str(i)), preview])
	return "\n".join(lines)

func _cmd_clip_history_clear(_args: Array, _piped_input: String = "") -> String:
	var prev: int = _history.size()
	_history = PackedStringArray()
	_last_sampled = ""
	_has_last_sample = false
	return _format_success("Cleared clipboard history (%s entries)" % _color_number(str(prev)))

func _cmd_clip_paste_run(_args: Array, _piped_input: String = "") -> String:
	if not _clipboard_available():
		return _format_error("DisplayServer reports no clipboard feature on this platform")
	if not _registry or not _registry.has_method("execute_command_with_pipes"):
		return _format_error("Registry unavailable; cannot route clipboard contents as a command")
	var text: String = DisplayServer.clipboard_get().strip_edges()
	_record_sample(text)
	if text.is_empty():
		return _format_error("Clipboard is empty; nothing to run")
	var result: Variant = _registry.call("execute_command_with_pipes", text)
	var header: String = "%s %s" % [_color_muted("[clip_paste_run]"), _color_path(text)]
	return "%s\n%s" % [header, str(result)]

func _cmd_clip_dump(args: Array, _piped_input: String = "") -> String:
	if not _clipboard_available():
		return _format_error("DisplayServer reports no clipboard feature on this platform")
	if args.is_empty():
		return _format_error("Usage: clip_dump <user://path or res://path>")
	var path: String = str(args[0]).strip_edges()
	if path.is_empty():
		return _format_error("Usage: clip_dump <user://path or res://path>")
	var text: String = DisplayServer.clipboard_get()
	_record_sample(text)
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if not f:
		var err: int = FileAccess.get_open_error()
		return _format_error("Failed to open %s for writing (FileAccess error %d)" % [path, err])
	f.store_string(text)
	f.close()
	return _format_success("Wrote clipboard (%s chars) to %s" % [
		_color_number(str(text.length())),
		_color_path(path),
	])

#endregion

#region Polling

func _ensure_poller() -> void:
	if is_instance_valid(_poller):
		return
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if not tree or not tree.root:
		return
	var PollerClass := _ClipboardPoller
	var p: Node = PollerClass.new()
	p.name = "DebugConsole_ClipboardPoller"
	p.owner_ref = weakref(self)
	p.interval = _POLL_INTERVAL_SECONDS
	tree.root.add_child(p)
	_poller = p
	# Seed with the current value so the first sample after copy is recognised
	# as a change rather than as the initial sample.
	if _clipboard_available():
		_record_sample(DisplayServer.clipboard_get())

func _on_poll_tick() -> void:
	if not _clipboard_available():
		return
	var current: String = DisplayServer.clipboard_get()
	_record_sample(current)

func _record_sample(text: String) -> void:
	if _has_last_sample and text == _last_sampled:
		return
	_last_sampled = text
	_has_last_sample = true
	if text.is_empty():
		return
	_history.append(text)
	if _history.size() > _HISTORY_CAPACITY:
		_history = _history.slice(_history.size() - _HISTORY_CAPACITY, _history.size())

#endregion

#region Helpers

func _clipboard_available() -> bool:
	return DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD)

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

#endregion

#region Inner classes

class _ClipboardPoller extends Node:
	var owner_ref: WeakRef
	var interval: float = 1.0
	var _accum: float = 0.0

	func _process(delta: float) -> void:
		if owner_ref == null:
			return
		var owner: Object = owner_ref.get_ref()
		if owner == null:
			queue_free()
			return
		_accum += delta
		if _accum < interval:
			return
		_accum = 0.0
		owner.call("_on_poll_tick")

#endregion

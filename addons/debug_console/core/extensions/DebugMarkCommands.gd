@tool
class_name DebugConsoleDebugMarkCommands extends RefCounted

# Tier 6 extension - debug pause / step / marker / breadcrumb commands.
# Auto-loaded by the extensions loader and kept alive by the shared
# _t6_keepalive static array on BuiltInCommands. The orchestrator passes in
# the registry + core through register_commands(); no edits to
# BuiltInCommands.gd are required to add this module.
#
# The pause/step commands only make sense at runtime so they register under
# the "game" context. The marker/breadcrumb commands are pure data and work
# in either context, so they register under "both".

const _COLOR_ERROR := "#FF4444"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_MARKER := "#F7DC6F"
const _COLOR_NAME := "#5FBEE0"

var _registry: Node
var _core: Node

# Breadcrumb stack lives on the module instance. Because BuiltInCommands
# holds a strong reference via _t6_keepalive, this array persists for the
# lifetime of the plugin / editor session.
var _breadcrumbs: Array[String] = []

# Monotonic counter feeding _make_unique_marker so two markers sharing a
# name still produce distinct lines for log correlation.
var _marker_seq: int = 0

# Physics-frame stepping state. Only one window may be active at a time;
# calling dbg_step_n while another is in flight cancels the previous window
# and starts a fresh one with the new frame count.
var _step_remaining: int = 0
var _step_connected: bool = false

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("dbg_pause", _cmd_pause, "Pause the SceneTree: dbg_pause", "game")
	_registry.register_command("dbg_resume", _cmd_resume, "Resume the SceneTree: dbg_resume", "game")
	_registry.register_command("dbg_toggle", _cmd_toggle, "Toggle SceneTree pause: dbg_toggle", "game")
	_registry.register_command("dbg_breakpoint", _cmd_breakpoint, "Pause the tree and emit a named marker: dbg_breakpoint <name>", "game")
	_registry.register_command("dbg_step_n", _cmd_step_n, "Resume for N physics frames, then auto-pause: dbg_step_n <frames>", "game")
	_registry.register_command("dbg_log_marker", _cmd_log_marker, "Print a UNIQUE marker line to the engine log for correlation: dbg_log_marker <name>", "both")
	_registry.register_command("dbg_breadcrumb", _cmd_breadcrumb, "Push text onto the breadcrumb stack: dbg_breadcrumb <text>", "both")
	_registry.register_command("dbg_breadcrumbs", _cmd_breadcrumbs_dump, "Dump the breadcrumb stack; pass 'clear' to also empty it: dbg_breadcrumbs [clear]", "both")

#region Command implementations

func _cmd_pause(args: Array, piped_input: String = "") -> String:
	var tree := _get_tree()
	if not tree:
		return _format_error("No SceneTree available")
	if tree.paused:
		return _format_success("SceneTree already paused")
	tree.paused = true
	return _format_success("Paused SceneTree")

func _cmd_resume(args: Array, piped_input: String = "") -> String:
	var tree := _get_tree()
	if not tree:
		return _format_error("No SceneTree available")
	# Cancel any pending step-window so a manual resume sticks.
	_cancel_step_window(tree)
	if not tree.paused:
		return _format_success("SceneTree already running")
	tree.paused = false
	return _format_success("Resumed SceneTree")

func _cmd_toggle(args: Array, piped_input: String = "") -> String:
	var tree := _get_tree()
	if not tree:
		return _format_error("No SceneTree available")
	if not tree.paused:
		_cancel_step_window(tree)
	tree.paused = not tree.paused
	return _format_success("SceneTree paused = %s" % str(tree.paused))

func _cmd_breakpoint(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: dbg_breakpoint <name>")
	var label: String = " ".join(args).strip_edges()
	if label.is_empty():
		return _format_error("Usage: dbg_breakpoint <name>")
	var tree := _get_tree()
	if not tree:
		return _format_error("No SceneTree available")
	_cancel_step_window(tree)
	tree.paused = true
	var marker := _make_unique_marker(label)
	# Also surface the marker through Godot's print() so it lands in the
	# engine log next to any other gameplay prints we want to correlate.
	print("[DBG-BREAKPOINT] %s" % marker)
	return _format_breakpoint(marker)

func _cmd_step_n(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: dbg_step_n <frames>")
	var raw := str(args[0]).strip_edges()
	if not raw.is_valid_int():
		return _format_error("Frames must be a positive integer: %s" % raw)
	var frames := raw.to_int()
	if frames <= 0:
		return _format_error("Frames must be > 0: %d" % frames)

	var tree := _get_tree()
	if not tree:
		return _format_error("No SceneTree available")

	_cancel_step_window(tree)
	_step_remaining = frames
	tree.physics_frame.connect(_on_step_physics_frame)
	_step_connected = true
	tree.paused = false
	return _format_success("Stepping %d physics frame(s) before re-pausing" % frames)

func _cmd_log_marker(args: Array, piped_input: String = "") -> String:
	var label: String = " ".join(args).strip_edges() if not args.is_empty() else ""
	if label.is_empty():
		label = "marker"
	var marker := _make_unique_marker(label)
	print("[DBG-MARKER] %s" % marker)
	return _format_marker(marker)

func _cmd_breadcrumb(args: Array, piped_input: String = "") -> String:
	var joined: String = " ".join(args).strip_edges() if not args.is_empty() else ""
	var text: String = joined if not joined.is_empty() else piped_input.strip_edges()
	if text.is_empty():
		return _format_error("Usage: dbg_breadcrumb <text>")
	var entry := "%s | %s" % [_timestamp(), text]
	_breadcrumbs.append(entry)
	return _format_success("Breadcrumb #%d pushed: %s" % [_breadcrumbs.size(), text])

func _cmd_breadcrumbs_dump(args: Array, piped_input: String = "") -> String:
	var should_clear := false
	for a in args:
		if str(a).strip_edges().to_lower() == "clear":
			should_clear = true
	if _breadcrumbs.is_empty():
		var msg := _format_success("Breadcrumb stack is empty")
		if should_clear:
			# Nothing to clear, but be explicit so scripted callers see it.
			msg += "\n" + _format_success("(nothing to clear)")
		return msg
	var lines: Array[String] = []
	lines.append("Breadcrumbs (%d):" % _breadcrumbs.size())
	for i in _breadcrumbs.size():
		lines.append("  [%d] %s" % [i + 1, _breadcrumbs[i]])
	if should_clear:
		_breadcrumbs.clear()
		lines.append(_format_success("Cleared breadcrumb stack"))
	return "\n".join(lines)

#endregion

#region Internals

func _on_step_physics_frame() -> void:
	_step_remaining -= 1
	if _step_remaining > 0:
		return
	var tree := _get_tree()
	if not tree:
		_step_connected = false
		return
	tree.paused = true
	if _step_connected and tree.physics_frame.is_connected(_on_step_physics_frame):
		tree.physics_frame.disconnect(_on_step_physics_frame)
	_step_connected = false
	_step_remaining = 0
	print("[DBG-STEP] window complete - tree re-paused")

func _cancel_step_window(tree: SceneTree) -> void:
	if not _step_connected:
		return
	if tree and tree.physics_frame.is_connected(_on_step_physics_frame):
		tree.physics_frame.disconnect(_on_step_physics_frame)
	_step_connected = false
	_step_remaining = 0

func _get_tree() -> SceneTree:
	# Game-context only. In the editor there is no usable scene SceneTree
	# for pausing user gameplay, so we return null and let the caller emit
	# a clean error message.
	if Engine.is_editor_hint():
		return null
	return Engine.get_main_loop() as SceneTree

func _make_unique_marker(label: String) -> String:
	_marker_seq += 1
	return "%s#%04d %s" % [_timestamp(), _marker_seq, label]

func _timestamp() -> String:
	var dt := Time.get_datetime_dict_from_system()
	var ms := Time.get_ticks_msec()
	return "%04d-%02d-%02dT%02d:%02d:%02d.%03d" % [
		int(dt.get("year", 0)), int(dt.get("month", 0)), int(dt.get("day", 0)),
		int(dt.get("hour", 0)), int(dt.get("minute", 0)), int(dt.get("second", 0)),
		ms % 1000
	]

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _format_marker(msg: String) -> String:
	return "[color=%s]MARKER %s[/color]" % [_COLOR_MARKER, msg]

func _format_breakpoint(msg: String) -> String:
	return "[color=%s]BREAKPOINT %s[/color] [color=%s](tree paused - dbg_resume to continue)[/color]" % [_COLOR_MARKER, msg, _COLOR_NAME]

#endregion

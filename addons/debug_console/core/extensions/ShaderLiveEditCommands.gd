@tool
class_name DebugConsoleShaderLiveEditCommands extends RefCounted

# Tier 8 - live shader file watcher. Sits in core/extensions/ so the auto-
# discovery loader in BuiltInCommands.register_universal_commands picks it up
# on plugin enable. A strong reference is kept on the _t6_keepalive static
# array there, which is what keeps the Callables registered below valid for
# the lifetime of the plugin.
#
# Companion to ShaderCommands.gd. Where that module is the imperative API
# (shader_load / shader_set / shader_dump), this one is a poll loop:
# shader_watch <node> <res://shader.gdshader>
# spawns a 1s poll on FileAccess.get_modified_time. When the file changes on
# disk the loaded Shader resource is reloaded with CACHE_MODE_REPLACE (which
# bypasses Godot's resource cache and re-reads the source) and dropped onto
# the node's ShaderMaterial. Existing uniform values are snapshotted before
# the swap and re-applied after, so an artist can edit a .gdshader in their
# external editor and see the result without losing their tweaked params.
#
# Polling lives on a dedicated child Node helper parented to _core ("the
# host"). That helper owns a Timer child; the indirection keeps all watcher
# state under one detachable subtree so a future shader_watch_clear could
# wipe everything by free-ing the helper node alone. Both editor and runtime
# contexts work the same way - _resolve_node mirrors the branching used in
# ShaderCommands.gd.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_INFO := "#C8C8C8"

const _POLLER_NAME := "_ShaderLiveEditPoller"
const _TIMER_NAME := "Tick"
const _DEFAULT_POLL_INTERVAL := 1.0
const _DEFAULT_LOG_TAIL := 16
const _MAX_LOG_ENTRIES := 256

var _registry: Node
var _core: Node

# Active watches keyed by the node-path string the user typed. Resolving the
# node fresh on each tick means a watch survives the node being re-parented
# or freed-and-recreated under the same path; if the path stops resolving
# the tick records an "error" log entry and leaves the watch in place so
# the user can decide whether to unwatch.
#
# Entry shape:
#   {
#     "node_path": String,           # echo of the user-typed path
#     "shader_path": String,
#     "mtime": int,                  # last seen FileAccess.get_modified_time
#     "reload_count": int,
#     "last_reload_unix": float,
#   }
var _watches: Dictionary = {}

# Global preserve-uniforms toggle. Default on per spec - the common case for
# a live shader edit is tweak-and-see, so blowing away the artist's current
# parameter values on every reload would be the wrong default.
var _preserve_uniforms: bool = true

# Global throttle in seconds. 0.0 means "no throttle, reload on every poll
# tick that detects an mtime change". When > 0, reloads inside this window
# are dropped and logged as "throttled".
var _throttle_secs: float = 0.0

# Ring buffer of recent hot-swap events (newest last). Capped at
# _MAX_LOG_ENTRIES so a runaway file-watcher does not balloon plugin memory.
# Entry shape:
#   { "time": String, "node_path": String, "shader_path": String,
#     "status": String ("ok"|"throttled"|"error"), "message": String }
var _log: Array = []

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("shader_watch", _cmd_shader_watch, "Watch a shader file and hot-swap on disk change: shader_watch <node_path> <res://shader.gdshader>", "both")
	_registry.register_command("shader_unwatch", _cmd_shader_unwatch, "Stop watching a node (or all): shader_unwatch <node_path|all>", "both")
	_registry.register_command("shader_watch_list", _cmd_shader_watch_list, "List active shader file watches", "both")
	_registry.register_command("shader_watch_log", _cmd_shader_watch_log, "Show last N hot-swap events: shader_watch_log [count]", "both")
	_registry.register_command("shader_watch_uniforms_preserve", _cmd_shader_watch_uniforms_preserve, "Preserve uniform values across reload: shader_watch_uniforms_preserve <on|off>", "both")
	_registry.register_command("shader_watch_throttle", _cmd_shader_watch_throttle, "Minimum seconds between reloads: shader_watch_throttle <secs>", "both")

#region Command implementations

func _cmd_shader_watch(args: Array, _piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: shader_watch <node_path> <res://shader.gdshader>")
	var node_path: String = str(args[0]).strip_edges()
	var shader_path: String = str(args[1]).strip_edges()

	var node: Node = _resolve_node(node_path)
	if not node:
		return _format_error("Node not found: %s" % node_path)
	var visual: Node = _resolve_visual(node)
	if not visual:
		return _format_error("Node is not a CanvasItem or GeometryInstance3D: %s" % node_path)

	if not ResourceLoader.exists(shader_path):
		return _format_error("Shader not found: %s" % shader_path)
	var initial_mtime: int = int(FileAccess.get_modified_time(shader_path))
	if initial_mtime == 0:
		# get_modified_time returns 0 when the file is unreadable. Refuse the
		# watch up front rather than spinning on a file we can never poll.
		return _format_error("Cannot stat shader file: %s" % shader_path)

	# Bootstrap convenience: if the node has no ShaderMaterial yet, build one
	# and assign the shader so shader_watch is a one-step command. If a
	# ShaderMaterial is already there we leave it untouched - the next mtime
	# tick will hot-swap it.
	var existing: Material = _get_current_material(visual)
	if not (existing is ShaderMaterial):
		var shader: Shader = load(shader_path) as Shader
		if not shader:
			return _format_error("Not a Shader resource: %s" % shader_path)
		var mat: ShaderMaterial = ShaderMaterial.new()
		mat.shader = shader
		_assign_material(visual, mat)

	_watches[node_path] = {
		"node_path": node_path,
		"shader_path": shader_path,
		"mtime": initial_mtime,
		"reload_count": 0,
		"last_reload_unix": 0.0,
	}
	_ensure_poller()
	return _format_success("Watching %s on %s (poll %ss)" % [
		_color_path(shader_path),
		_color_path(node_path),
		_color_number(str(_DEFAULT_POLL_INTERVAL)),
	])

func _cmd_shader_unwatch(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: shader_unwatch <node_path|all>")
	var target: String = str(args[0]).strip_edges()
	if target == "all":
		var count: int = _watches.size()
		_watches.clear()
		return _format_success("Unwatched %s shader(s)" % _color_number(str(count)))
	if not _watches.has(target):
		return _format_error("Not watching: %s" % target)
	_watches.erase(target)
	return _format_success("Unwatched %s" % _color_path(target))

func _cmd_shader_watch_list(_args: Array, _piped_input: String = "") -> String:
	if _watches.is_empty():
		return "No active shader watches. Use shader_watch <node_path> <res://shader.gdshader> to start one."
	var keys: Array = _watches.keys()
	keys.sort()
	var lines: PackedStringArray = []
	lines.append("Active shader watches (%s):" % _color_number(str(_watches.size())))
	for k in keys:
		var entry: Dictionary = _watches[k]
		lines.append("  %s <- %s (reloads=%s)" % [
			_color_path(str(entry.get("node_path", k))),
			_color_path(str(entry.get("shader_path", ""))),
			_color_number(str(entry.get("reload_count", 0))),
		])
	lines.append("preserve_uniforms=%s, throttle=%ss, poll=%ss" % [
		_color_number("on" if _preserve_uniforms else "off"),
		_color_number(str(_throttle_secs)),
		_color_number(str(_DEFAULT_POLL_INTERVAL)),
	])
	return "\n".join(lines)

func _cmd_shader_watch_log(args: Array, _piped_input: String = "") -> String:
	var n: int = _DEFAULT_LOG_TAIL
	if not args.is_empty():
		var v: String = str(args[0]).strip_edges()
		if v.is_valid_int():
			n = max(1, v.to_int())
	if _log.is_empty():
		return "No shader-watch events recorded yet."
	var start: int = max(0, _log.size() - n)
	var lines: PackedStringArray = []
	lines.append("Last %s shader-watch event(s):" % _color_number(str(_log.size() - start)))
	for i in range(start, _log.size()):
		var e: Dictionary = _log[i]
		var status: String = str(e.get("status", "ok"))
		var status_str: String = status
		match status:
			"ok":
				status_str = "[color=%s]ok[/color]" % _COLOR_SUCCESS
			"error":
				status_str = "[color=%s]err[/color]" % _COLOR_ERROR
			_:
				status_str = "[color=%s]%s[/color]" % [_COLOR_INFO, status]
		lines.append("  [%s] %s %s <- %s : %s" % [
			str(e.get("time", "")),
			status_str,
			_color_path(str(e.get("node_path", ""))),
			_color_path(str(e.get("shader_path", ""))),
			str(e.get("message", "")),
		])
	return "\n".join(lines)

func _cmd_shader_watch_uniforms_preserve(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: shader_watch_uniforms_preserve <on|off>")
	var v: String = str(args[0]).strip_edges().to_lower()
	match v:
		"on", "true", "1", "yes":
			_preserve_uniforms = true
		"off", "false", "0", "no":
			_preserve_uniforms = false
		_:
			return _format_error("Expected on|off, got: %s" % v)
	return _format_success("uniform preservation: %s" % _color_number("on" if _preserve_uniforms else "off"))

func _cmd_shader_watch_throttle(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: shader_watch_throttle <secs>")
	var v: String = str(args[0]).strip_edges()
	if not (v.is_valid_float() or v.is_valid_int()):
		return _format_error("Throttle must be a number, got: %s" % v)
	var secs: float = max(0.0, v.to_float())
	_throttle_secs = secs
	return _format_success("throttle = %ss" % _color_number(str(secs)))

#endregion

#region Poller helper

# Lazily build a Node-with-Timer subtree under _core. The dedicated wrapper
# Node (instead of a bare Timer) keeps all watcher infrastructure in one
# detachable place; freeing the helper kills the Timer with it. Idempotent
# so repeated shader_watch calls do not stack timers.
func _ensure_poller() -> void:
	if not _core:
		return
	var existing: Node = _core.get_node_or_null(_POLLER_NAME)
	if existing:
		return
	var helper: Node = Node.new()
	helper.name = _POLLER_NAME
	_core.add_child(helper)
	var timer: Timer = Timer.new()
	timer.name = _TIMER_NAME
	timer.wait_time = _DEFAULT_POLL_INTERVAL
	timer.one_shot = false
	timer.autostart = false
	# Editor host runs _process so the Timer ticks under @tool exactly the
	# same way it does in game; HotReloadCommands relies on the same trick.
	helper.add_child(timer)
	timer.timeout.connect(_on_poll_tick)
	timer.start()

func _on_poll_tick() -> void:
	if _watches.is_empty():
		return
	# Snapshot keys before iterating - the swap path is read-only against the
	# watch dict but a future extension might erase entries from within the
	# loop, and iterating a mutating Dictionary is undefined.
	var keys: Array = _watches.keys()
	for k in keys:
		var node_path: String = str(k)
		if not _watches.has(node_path):
			continue
		var entry: Dictionary = _watches[node_path]
		var shader_path: String = str(entry.get("shader_path", ""))
		if shader_path.is_empty():
			continue

		var current_mtime: int = int(FileAccess.get_modified_time(shader_path))
		if current_mtime == 0:
			# File is gone or temporarily unreadable (common during an editor
			# save - the source is truncated and rewritten). Skip this tick;
			# do not bump mtime, so we will catch the real change on the next
			# tick once the writer finishes.
			continue
		var previous_mtime: int = int(entry.get("mtime", 0))
		if current_mtime == previous_mtime:
			continue

		# Throttle: if the user set shader_watch_throttle and we just reloaded
		# this watch within the window, drop the reload and log it. We DO
		# advance mtime so the throttled change is considered "consumed";
		# otherwise every tick during the window would re-log throttled.
		var now_unix: float = Time.get_unix_time_from_system()
		var last_unix: float = float(entry.get("last_reload_unix", 0.0))
		if _throttle_secs > 0.0 and last_unix > 0.0 and (now_unix - last_unix) < _throttle_secs:
			entry["mtime"] = current_mtime
			_watches[node_path] = entry
			_push_log(node_path, shader_path, "throttled", "skipped (throttle %ss)" % str(_throttle_secs))
			continue

		var result: Dictionary = _hot_swap(node_path, shader_path)
		entry["mtime"] = current_mtime
		if bool(result.get("ok", false)):
			entry["reload_count"] = int(entry.get("reload_count", 0)) + 1
			entry["last_reload_unix"] = now_unix
		_watches[node_path] = entry

# Reloads the shader resource from disk (bypassing the cache) and slots it
# into the node's ShaderMaterial. Returns { ok: bool, restored: int }.
# Caller is responsible for updating watch bookkeeping (mtime / counts).
func _hot_swap(node_path: String, shader_path: String) -> Dictionary:
	var node: Node = _resolve_node(node_path)
	if not node:
		_push_log(node_path, shader_path, "error", "node not found")
		return {"ok": false, "restored": 0}
	var visual: Node = _resolve_visual(node)
	if not visual:
		_push_log(node_path, shader_path, "error", "node is not a CanvasItem or GeometryInstance3D")
		return {"ok": false, "restored": 0}
	# CACHE_MODE_REPLACE forces the resource loader to re-read the file from
	# disk and update the existing Shader resource in place. Plain load()
	# would return the cached Shader without the new source.
	var fresh: Shader = ResourceLoader.load(shader_path, "Shader", ResourceLoader.CACHE_MODE_REPLACE) as Shader
	if not fresh:
		_push_log(node_path, shader_path, "error", "shader load failed")
		return {"ok": false, "restored": 0}

	var existing: Material = _get_current_material(visual)
	var mat: ShaderMaterial = existing as ShaderMaterial
	var saved_params: Dictionary = {}
	if mat and _preserve_uniforms and mat.shader:
		saved_params = _snapshot_uniforms(mat)

	if not mat:
		# Node lost its ShaderMaterial since shader_watch was registered. Re-
		# create one rather than failing - the user clearly wants this shader
		# applied.
		mat = ShaderMaterial.new()
		_assign_material(visual, mat)

	mat.shader = fresh

	var restored: int = 0
	if _preserve_uniforms and not saved_params.is_empty():
		restored = _restore_uniforms(mat, saved_params)

	_push_log(node_path, shader_path, "ok", "%s uniform(s) preserved" % str(restored))
	return {"ok": true, "restored": restored}

# Returns { uniform_name : value } for every uniform that has been explicitly
# set on the material. Null returns from get_shader_parameter are intentionally
# skipped: null means "default", and re-applying it would override the new
# shader's default value with a hard null.
func _snapshot_uniforms(mat: ShaderMaterial) -> Dictionary:
	var out: Dictionary = {}
	if not mat or not mat.shader:
		return out
	for u in mat.shader.get_shader_uniform_list():
		var uname: String = str(u.get("name", ""))
		if uname.is_empty():
			continue
		var v: Variant = mat.get_shader_parameter(uname)
		if v == null:
			continue
		out[uname] = v
	return out

# Re-applies snapshotted uniforms, but only those that still exist on the
# (possibly edited) new shader. Returns the number actually restored so the
# log can show "3 of 5 preserved" when the shader removes a uniform.
func _restore_uniforms(mat: ShaderMaterial, saved: Dictionary) -> int:
	if not mat or not mat.shader:
		return 0
	var current_names: Dictionary = {}
	for u in mat.shader.get_shader_uniform_list():
		current_names[str(u.get("name", ""))] = true
	var restored: int = 0
	for k in saved.keys():
		var uname: String = str(k)
		if not current_names.has(uname):
			continue
		mat.set_shader_parameter(uname, saved[k])
		restored += 1
	return restored

func _push_log(node_path: String, shader_path: String, status: String, msg: String) -> void:
	_log.append({
		"time": Time.get_time_string_from_system(),
		"node_path": node_path,
		"shader_path": shader_path,
		"status": status,
		"message": msg,
	})
	if _log.size() > _MAX_LOG_ENTRIES:
		_log = _log.slice(_log.size() - _MAX_LOG_ENTRIES)

#endregion

#region Node / material helpers (mirrors ShaderCommands.gd)

func _get_scene_root() -> Node:
	if Engine.is_editor_hint():
		return EditorInterface.get_edited_scene_root()
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if not tree:
		return null
	if tree.current_scene:
		return tree.current_scene
	return tree.root

func _resolve_node(path: String) -> Node:
	var p: String = path.strip_edges()
	if p.is_empty():
		return null

	if Engine.is_editor_hint():
		var root: Node = _get_scene_root()
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

func _resolve_visual(node: Node) -> Node:
	if node is CanvasItem:
		return node
	if node is GeometryInstance3D:
		return node
	return null

func _assign_material(visual: Node, mat: Material) -> void:
	if visual is GeometryInstance3D:
		(visual as GeometryInstance3D).material_override = mat
	elif visual is CanvasItem:
		(visual as CanvasItem).material = mat

func _get_current_material(node: Node) -> Material:
	if node is GeometryInstance3D:
		return (node as GeometryInstance3D).material_override
	if node is CanvasItem:
		return (node as CanvasItem).material
	return null

#endregion

#region Formatting

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

#endregion

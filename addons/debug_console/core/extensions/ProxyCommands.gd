@tool
class_name DebugConsoleProxyCommands extends RefCounted

# Tier 7 extension - HTTP proxy logger. Sits passively next to HttpCommands.gd
# and records every request/response pair so they can be listed, filtered,
# and replayed from the console. No network interception happens here; the
# module is a pure ring-buffer + filter that HttpCommands pushes into.
#
# Lifetime mirrors the other extension modules: BuiltInCommands instantiates
# one ProxyCommands, holds a strong reference, and calls register_commands().
#
# ============================================================================
# INTEGRATION CONTRACT (HttpCommands.gd <-> ProxyCommands.gd)
# ============================================================================
#
# ProxyCommands publishes itself on the core node as a meta entry so any
# extension (notably HttpCommands.gd) can locate it without a hard import:
#
#     _core.set_meta("debug_console_proxy", self)
#
# HttpCommands.gd is expected to do, once per completed request:
#
#     var proxy = null
#     if _core and _core.has_meta("debug_console_proxy"):
#         proxy = _core.get_meta("debug_console_proxy")
#     if proxy and proxy.has_method("record"):
#         proxy.record(method, url, headers, body, status, response)
#
# Calling record() is always safe; the module:
#   1. drops the entry silently when logging is OFF (proxy_log_off),
#   2. drops the entry when a filter is set and the URL does not contain
#      the filter substring,
#   3. otherwise appends a Dictionary to `_log` with shape:
#        {
#          id: int,                    # 1-based, monotonically increasing
#          ts_msec: int,               # Time.get_ticks_msec() at record time
#          method: String,             # "GET" / "POST" / ...
#          url: String,
#          headers: PackedStringArray, # raw outgoing headers
#          body: String,               # full request body, no truncation
#          status: int,                # HTTP response code (0 on failure)
#          response: String,           # full response body, no truncation
#        }
#
# `_log` is intentionally an `Array[Dictionary]` (typed) so consumers can
# rely on element shape. A soft ring-buffer cap (`_LOG_LIMIT`) keeps memory
# bounded; oldest entries are dropped first.
#
# Replay routes back through the registry's normal command path
# (`_registry.execute_command("http_get <url> ...")`) so it reuses the
# real HTTPRequest pipeline, queueing, and result printing. Body and
# headers from the logged entry are NOT re-attached on replay for GET/
# DELETE; for POST/PUT the original body is reused verbatim.
#
# Editor context is intentionally excluded: HTTP calls only fire from the
# game side, so logging them in the editor would only collect noise.
# ============================================================================

const _COLOR_ERROR := "#FF4444"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_MUTED := "#888888"
const _COLOR_HEADER := "#D7B4F3"

const _LOG_LIMIT := 500
const _DEFAULT_SHOW_LIMIT := 20
const _META_KEY := "debug_console_proxy"

var _registry: Node
var _core: Node

var _enabled: bool = false
var _filter: String = ""
var _log: Array[Dictionary] = []
var _next_id: int = 1

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return

	# Publish ourselves so HttpCommands.gd (and any other producer) can
	# find us without a class-name dependency.
	if _core:
		_core.set_meta(_META_KEY, self)

	_registry.register_command("proxy_log_on", _cmd_proxy_log_on, "Start logging HTTP requests fired through HttpCommands", "game")
	_registry.register_command("proxy_log_off", _cmd_proxy_log_off, "Stop logging HTTP requests (keeps existing log)", "game")
	_registry.register_command("proxy_log_show", _cmd_proxy_log_show, "Dump the most recent logged requests: proxy_log_show [limit]", "game")
	_registry.register_command("proxy_filter", _cmd_proxy_filter, "Only log URLs containing substring (empty to clear): proxy_filter <substring>", "game")
	_registry.register_command("proxy_replay", _cmd_proxy_replay, "Re-run a logged request by id: proxy_replay <id>", "game")

#region Public API used by HttpCommands.gd

# Called by HttpCommands.gd once per completed request. See file header
# for the full contract. Method is a no-op when logging is OFF or when
# the URL does not match the active filter.
func record(method: String, url: String, headers, body: String, status: int, response: String) -> void:
	if not _enabled:
		return
	if not _filter.is_empty() and url.findn(_filter) == -1:
		return

	var typed_headers: PackedStringArray = PackedStringArray()
	if headers is PackedStringArray:
		typed_headers = headers
	elif headers is Array:
		for h in headers:
			typed_headers.append(str(h))
	elif headers != null:
		typed_headers.append(str(headers))

	var entry: Dictionary = {
		"id": _next_id,
		"ts_msec": Time.get_ticks_msec(),
		"method": method.to_upper(),
		"url": url,
		"headers": typed_headers,
		"body": body,
		"status": status,
		"response": response,
	}
	_next_id += 1
	_log.append(entry)

	while _log.size() > _LOG_LIMIT:
		_log.pop_front()

#endregion

#region Command implementations

func _cmd_proxy_log_on(_args: Array, _piped_input: String = "") -> String:
	if _enabled:
		return _format_muted("Proxy log already ON (entries: %d)" % _log.size())
	_enabled = true
	var filter_note := ""
	if not _filter.is_empty():
		filter_note = " (filter: \"%s\")" % _filter
	return _format_success("Proxy log ON%s" % filter_note)

func _cmd_proxy_log_off(_args: Array, _piped_input: String = "") -> String:
	if not _enabled:
		return _format_muted("Proxy log already OFF (entries: %d)" % _log.size())
	_enabled = false
	return _format_success("Proxy log OFF (kept %d entries)" % _log.size())

func _cmd_proxy_log_show(args: Array, _piped_input: String = "") -> String:
	var limit: int = _DEFAULT_SHOW_LIMIT
	if args.size() > 0:
		var raw := str(args[0]).strip_edges()
		if raw.is_valid_int():
			limit = max(1, raw.to_int())
		else:
			return _format_error("Usage: proxy_log_show [limit]")

	if _log.is_empty():
		var hint := "" if _enabled else " (logging is OFF; run proxy_log_on first)"
		return _format_muted("Proxy log is empty%s" % hint)

	var start: int = max(0, _log.size() - limit)
	var lines: PackedStringArray = PackedStringArray()
	var header := "[color=%s]Proxy log[/color]: showing %d of %d (filter: %s, state: %s)" % [
		_COLOR_HEADER,
		min(limit, _log.size()),
		_log.size(),
		("\"%s\"" % _filter) if not _filter.is_empty() else "none",
		"ON" if _enabled else "OFF",
	]
	lines.append(header)

	for i in range(start, _log.size()):
		var entry: Dictionary = _log[i]
		lines.append(_format_entry_brief(entry))
		var body_val := str(entry.get("body", ""))
		if not body_val.is_empty():
			lines.append("    [color=%s]body:[/color] %s" % [_COLOR_MUTED, body_val])
		var resp_val := str(entry.get("response", ""))
		if not resp_val.is_empty():
			lines.append("    [color=%s]resp:[/color] %s" % [_COLOR_MUTED, resp_val])

	return "\n".join(lines)

func _cmd_proxy_filter(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		if _filter.is_empty():
			return _format_muted("Proxy filter: <none>")
		return _format_muted("Proxy filter: \"%s\"" % _filter)

	var substring := str(args[0]).strip_edges()
	if substring.is_empty():
		_filter = ""
		return _format_success("Proxy filter cleared")
	_filter = substring
	return _format_success("Proxy filter: \"%s\"" % _filter)

func _cmd_proxy_replay(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: proxy_replay <id>")
	var raw := str(args[0]).strip_edges()
	if not raw.is_valid_int():
		return _format_error("id must be an integer (got: %s)" % raw)
	var target_id: int = raw.to_int()

	var entry: Dictionary = _find_entry(target_id)
	if entry.is_empty():
		return _format_error("No logged request with id=%d" % target_id)

	if not _registry or not _registry.has_method("execute_command"):
		return _format_error("Command registry unavailable; cannot replay")

	var method: String = str(entry.get("method", "GET")).to_upper()
	var url: String = str(entry.get("url", ""))
	var body: String = str(entry.get("body", ""))
	if url.is_empty():
		return _format_error("Logged entry id=%d has empty URL" % target_id)

	var command_line := ""
	match method:
		"GET":
			command_line = "http_get %s" % url
		"DELETE":
			command_line = "http_delete %s" % url
		"POST":
			command_line = "http_post %s %s" % [url, body]
		"PUT":
			command_line = "http_put %s %s" % [url, body]
		_:
			return _format_error("Replay unsupported for method: %s" % method)

	var prefix := "[color=%s]replay[/color] [color=%s]#%d[/color] %s %s\n" % [
		_COLOR_HEADER, _COLOR_NUMBER, target_id, method, _color_path(url),
	]
	var result: String = str(_registry.execute_command(command_line))
	return prefix + result

#endregion

#region Helpers

func _find_entry(target_id: int) -> Dictionary:
	for entry in _log:
		if int(entry.get("id", -1)) == target_id:
			return entry
	return {}

func _format_entry_brief(entry: Dictionary) -> String:
	var status: int = int(entry.get("status", 0))
	var status_color := _COLOR_SUCCESS
	if status == 0 or status >= 400:
		status_color = _COLOR_ERROR
	elif status >= 300:
		status_color = _COLOR_NUMBER
	return "[color=%s]#%d[/color] %s %s [color=%s]%d[/color]" % [
		_COLOR_NUMBER,
		int(entry.get("id", 0)),
		str(entry.get("method", "?")),
		_color_path(str(entry.get("url", ""))),
		status_color,
		status,
	]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _format_error(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _format_muted(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_MUTED, msg]

#endregion

@tool
class_name DebugConsoleHttpCommands extends RefCounted

# Async HTTP commands. Each call spawns a dedicated HTTPRequest node under
# /root so the request lifetime is independent of the current scene, the
# command can return immediately with a request id, and `http_cancel` can
# free a single in-flight request without disturbing any other.
#
# Async result delivery mirrors DialogCommands._emit_result: the command
# returns the id synchronously, then on `request_completed` we push the
# rendered summary back into the console via `_core.print_to_console`
# (forward-compat hook) with fallbacks to `_core.info`, the registry's
# `echo` command, and finally plain `print()`.
#
# Game context only; the editor has no business firing HTTP requests
# through the live console.

const _COLOR_ERROR := "#FF4444"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_MUTED := "#888888"

const _DUMP_BODY_LIMIT := 4096
const _HISTORY_LIMIT := 200

var _registry: Node
var _core: Node

var _next_id_counter: int = 0
# request_id -> { node: HTTPRequest, method: String, url: String, out_var: String, started_at: int }
var _active: Dictionary = {}
# Ordered log of completed requests (most recent appended at end).
var _history: Array = []
# request_id -> full result dict { id, method, url, status, response_code, headers, body, error, completed_at }
var _results: Dictionary = {}
# Named results from `http_get <url> <var_name>` so users can recall by name.
var _named_results: Dictionary = {}
var _last_result_id: String = ""

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("http_get", _cmd_http_get, "Async HTTP GET: http_get <url> [out_var_name]", "game")
	_registry.register_command("http_post", _cmd_http_post, "Async HTTP POST: http_post <url> <body_json>", "game")
	_registry.register_command("http_put", _cmd_http_put, "Async HTTP PUT: http_put <url> <body_json>", "game")
	_registry.register_command("http_delete", _cmd_http_delete, "Async HTTP DELETE: http_delete <url>", "game")
	_registry.register_command("http_history", _cmd_http_history, "List all requests fired this session with status codes", "game")
	_registry.register_command("http_cancel", _cmd_http_cancel, "Cancel an in-flight request: http_cancel <request_id|all>", "game")
	_registry.register_command("http_dump_last", _cmd_http_dump_last, "Print the full body of the most recent completed response", "game")

#region Command implementations

func _cmd_http_get(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: http_get <url> [out_var_name]")
	var url: String = str(args[0]).strip_edges()
	var out_var: String = str(args[1]).strip_edges() if args.size() > 1 else ""
	return _dispatch(HTTPClient.METHOD_GET, url, "", out_var)

func _cmd_http_post(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: http_post <url> <body_json>")
	var url: String = str(args[0]).strip_edges()
	var body: String = _join_from(args, 1)
	return _dispatch(HTTPClient.METHOD_POST, url, body, "")

func _cmd_http_put(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: http_put <url> <body_json>")
	var url: String = str(args[0]).strip_edges()
	var body: String = _join_from(args, 1)
	return _dispatch(HTTPClient.METHOD_PUT, url, body, "")

func _cmd_http_delete(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: http_delete <url>")
	var url: String = str(args[0]).strip_edges()
	return _dispatch(HTTPClient.METHOD_DELETE, url, "", "")

func _cmd_http_history(args: Array, piped_input: String = "") -> String:
	if _history.is_empty() and _active.is_empty():
		return _format_muted("No HTTP requests this session.")
	var lines: Array[String] = []
	lines.append("HTTP history (%s completed, %s in-flight):" % [
		_color_number(str(_history.size())),
		_color_number(str(_active.size()))
	])
	for entry in _history:
		lines.append("  %s %s %s -> %s%s" % [
			_color_path(str(entry.get("id", "?"))),
			str(entry.get("method", "?")),
			str(entry.get("url", "")),
			_status_color(int(entry.get("status", 0))),
			(" (%s)" % str(entry.get("error", ""))) if str(entry.get("error", "")) != "" else ""
		])
	if not _active.is_empty():
		lines.append("In-flight:")
		var ids: Array = _active.keys()
		ids.sort()
		for id in ids:
			var info: Dictionary = _active[id]
			lines.append("  %s %s %s [pending]" % [
				_color_path(str(id)),
				str(info.get("method", "?")),
				str(info.get("url", ""))
			])
	return "\n".join(lines)

func _cmd_http_cancel(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: http_cancel <request_id|all>")
	var target: String = str(args[0]).strip_edges()
	if target == "all":
		if _active.is_empty():
			return _format_muted("No in-flight requests.")
		var count: int = _active.size()
		var ids: Array = _active.keys().duplicate()
		for id in ids:
			_cancel_one(str(id), "cancelled (all)")
		return _format_success("Cancelled %s requests." % _color_number(str(count)))
	if not _active.has(target):
		return _format_error("Request not active: %s" % target)
	_cancel_one(target, "cancelled")
	return _format_success("Cancelled %s" % _color_path(target))

func _cmd_http_dump_last(args: Array, piped_input: String = "") -> String:
	if _last_result_id.is_empty() or not _results.has(_last_result_id):
		return _format_muted("No completed HTTP response yet.")
	var result: Dictionary = _results[_last_result_id]
	var body: String = str(result.get("body", ""))
	var header: String = "[%s] %s %s -> %s (%s bytes)" % [
		_color_path(str(result.get("id", ""))),
		str(result.get("method", "")),
		str(result.get("url", "")),
		_status_color(int(result.get("status", 0))),
		_color_number(str(body.length()))
	]
	if body.is_empty():
		return header + "\n" + _format_muted("<empty body>")
	return header + "\n" + body

#endregion

#region Async plumbing

func _dispatch(method: int, url: String, body: String, out_var: String) -> String:
	if url.is_empty():
		return _format_error("URL is required.")
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if not tree or not tree.root:
		return _format_error("No SceneTree root available for HTTPRequest.")

	var id: String = _next_id()
	var http: HTTPRequest = HTTPRequest.new()
	http.name = "DebugConsoleHttp_%s" % id
	tree.root.add_child(http)

	var headers: PackedStringArray = PackedStringArray()
	if method == HTTPClient.METHOD_POST or method == HTTPClient.METHOD_PUT:
		headers.append("Content-Type: application/json")

	var method_name: String = _method_name(method)
	_active[id] = {
		"node": http,
		"method": method_name,
		"url": url,
		"out_var": out_var,
		"started_at": Time.get_ticks_msec(),
	}
	http.request_completed.connect(_on_request_completed.bind(id))

	var err: int = http.request(url, headers, method, body)
	if err != OK:
		http.queue_free()
		_active.erase(id)
		_record_history({
			"id": id, "method": method_name, "url": url, "status": 0,
			"error": "request() failed (err=%d)" % err,
		})
		return _format_error("http %s failed to start: err=%d (%s)" % [method_name, err, url])

	return _format_success("%s %s queued as %s" % [
		method_name,
		url,
		_color_path(id)
	])

func _on_request_completed(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray, id: String) -> void:
	if not _active.has(id):
		# Already cancelled; nothing to deliver.
		return
	var info: Dictionary = _active[id]
	var http: HTTPRequest = info.get("node") as HTTPRequest
	var method_name: String = str(info.get("method", "?"))
	var url: String = str(info.get("url", ""))
	var out_var: String = str(info.get("out_var", ""))

	_active.erase(id)
	if is_instance_valid(http):
		http.queue_free()

	var body_text: String = body.get_string_from_utf8() if body.size() > 0 else ""
	var error_text: String = ""
	if result != HTTPRequest.RESULT_SUCCESS:
		error_text = _result_name(result)

	var entry: Dictionary = {
		"id": id,
		"method": method_name,
		"url": url,
		"status": response_code,
		"response_code": response_code,
		"headers": headers,
		"body": body_text,
		"body_size": body.size(),
		"result": result,
		"error": error_text,
		"completed_at": Time.get_ticks_msec(),
		"out_var": out_var,
	}
	_results[id] = entry
	_last_result_id = id
	if not out_var.is_empty():
		_named_results[out_var] = entry
	_record_history(entry)

	var preview: String = body_text.substr(0, 200)
	if body_text.length() > 200:
		preview += "..."
	var summary: String = "[%s] %s %s -> %s%s%s" % [
		_color_path(id),
		method_name,
		url,
		_status_color(response_code),
		(" (err=%s)" % error_text) if error_text != "" else "",
		("\n  " + preview) if not preview.is_empty() else ""
	]
	if not out_var.is_empty():
		summary += "\n  stored as $" + out_var
	_emit_result(id, summary)

func _cancel_one(id: String, reason: String) -> void:
	if not _active.has(id):
		return
	var info: Dictionary = _active[id]
	var http: HTTPRequest = info.get("node") as HTTPRequest
	if is_instance_valid(http):
		http.cancel_request()
		http.queue_free()
	_active.erase(id)
	_record_history({
		"id": id,
		"method": str(info.get("method", "?")),
		"url": str(info.get("url", "")),
		"status": 0,
		"error": reason,
	})

func _record_history(entry: Dictionary) -> void:
	_history.append(entry)
	while _history.size() > _HISTORY_LIMIT:
		_history.pop_front()

# Mirrors DialogCommands._emit_result: tries forward-compat
# `_core.print_to_console`, then current `_core.info`, then echo via the
# registry, then plain print so unit tests still see the line.
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

#endregion

#region Helpers

func _next_id() -> String:
	_next_id_counter += 1
	return "http_%d" % _next_id_counter

func _join_from(args: Array, start: int) -> String:
	var parts: Array[String] = []
	for i in range(start, args.size()):
		parts.append(str(args[i]))
	return " ".join(parts).strip_edges()

func _method_name(method: int) -> String:
	match method:
		HTTPClient.METHOD_GET: return "GET"
		HTTPClient.METHOD_POST: return "POST"
		HTTPClient.METHOD_PUT: return "PUT"
		HTTPClient.METHOD_DELETE: return "DELETE"
		HTTPClient.METHOD_HEAD: return "HEAD"
		HTTPClient.METHOD_OPTIONS: return "OPTIONS"
		HTTPClient.METHOD_PATCH: return "PATCH"
		_: return "M%d" % method

func _result_name(result: int) -> String:
	match result:
		HTTPRequest.RESULT_SUCCESS: return "success"
		HTTPRequest.RESULT_CHUNKED_BODY_SIZE_MISMATCH: return "chunked_size_mismatch"
		HTTPRequest.RESULT_CANT_CONNECT: return "cant_connect"
		HTTPRequest.RESULT_CANT_RESOLVE: return "cant_resolve"
		HTTPRequest.RESULT_CONNECTION_ERROR: return "connection_error"
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR: return "tls_handshake_error"
		HTTPRequest.RESULT_NO_RESPONSE: return "no_response"
		HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED: return "body_size_limit"
		HTTPRequest.RESULT_REQUEST_FAILED: return "request_failed"
		HTTPRequest.RESULT_DOWNLOAD_FILE_CANT_OPEN: return "download_file_cant_open"
		HTTPRequest.RESULT_DOWNLOAD_FILE_WRITE_ERROR: return "download_file_write_error"
		HTTPRequest.RESULT_REDIRECT_LIMIT_REACHED: return "redirect_limit"
		HTTPRequest.RESULT_TIMEOUT: return "timeout"
		_: return "result_%d" % result

func _status_color(code: int) -> String:
	if code <= 0:
		return _color_error(str(code))
	if code >= 200 and code < 300:
		return _color_success(str(code))
	if code >= 300 and code < 400:
		return _color_number(str(code))
	return _color_error(str(code))

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _format_muted(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_MUTED, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

func _color_success(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, s]

func _color_error(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_ERROR, s]

#endregion

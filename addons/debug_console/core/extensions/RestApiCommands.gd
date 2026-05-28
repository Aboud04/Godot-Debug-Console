@tool
class_name DebugConsoleRestApiCommands extends RefCounted

# Higher-level REST API commands layered on top of HTTPRequest. While
# HttpCommands.gd is the raw "fire-and-forget" verb (one URL per call,
# zero state), this module keeps a small session:
#
#   * a persistent base URL prepended to every rest_get / rest_post path
#   * a dictionary of persistent headers attached to every request
#   * an Authorization bearer token kept separately so it can be masked
#     in `rest_session` and overwritten cleanly by rest_auth_bearer
#
# We spawn HTTPRequest nodes under /root on demand, the same way
# HttpCommands does, so the two modules coexist without fighting over a
# single shared node. If HttpCommands.gd is loaded in the same session
# (detected by checking the registry for an "http_get" command) we note
# it in rest_session so the user can see they have both verb sets
# available. We deliberately do NOT mutate HttpCommands' state or
# history; "sharing" here means "the same SceneTree root hosts both
# kinds of HTTPRequest nodes peacefully."
#
# Async result delivery mirrors HttpCommands._emit_result: synchronous
# return is the queued request id, then on `request_completed` we push
# the rendered summary back into the console via the first available
# of _core.print_to_console, _core.info, registry.execute_command echo,
# or plain print() as a unit-test fallback.
#
# Game context only; firing REST traffic from the editor live console
# is not a workflow we want to encourage.

const _COLOR_ERROR := "#FF4444"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_MUTED := "#888888"

var _registry: Node
var _core: Node

var _base_url: String = ""
# Header name (preserved case) -> value. We do not lowercase the key
# because HTTP servers can be picky and the user typed it the way they
# want it on the wire.
var _headers: Dictionary = {}
var _auth_bearer: String = ""

var _next_id_counter: int = 0
# request_id -> { node: HTTPRequest, method: String, url: String, started_at: int }
var _active: Dictionary = {}

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("rest_base", _cmd_rest_base, "Set the base URL prepended to rest_get/rest_post paths: rest_base <url>", "game")
	_registry.register_command("rest_header", _cmd_rest_header, "Set or clear a persistent request header: rest_header <name> <value> (empty value clears)", "game")
	_registry.register_command("rest_auth_bearer", _cmd_rest_auth_bearer, "Set the Authorization: Bearer <token> header for subsequent requests: rest_auth_bearer <token> (empty clears)", "game")
	_registry.register_command("rest_get", _cmd_rest_get, "Async REST GET using base URL + auth: rest_get <path>", "game")
	_registry.register_command("rest_post", _cmd_rest_post, "Async REST POST with JSON body: rest_post <path> <json>", "game")
	_registry.register_command("rest_session", _cmd_rest_session, "Print current base URL, headers, and (masked) auth token", "game")

#region Command implementations

func _cmd_rest_base(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		if _base_url.is_empty():
			return _format_muted("No base URL set.")
		return "Base URL: " + _color_path(_base_url)
	var url: String = _join_from(args, 0)
	if url.is_empty():
		_base_url = ""
		return _format_success("Cleared base URL.")
	_base_url = url
	return _format_success("Base URL set to " + _color_path(_base_url))

func _cmd_rest_header(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: rest_header <name> <value> (empty value clears the header)")
	var name: String = str(args[0]).strip_edges()
	if name.is_empty():
		return _format_error("Header name cannot be empty.")
	var value: String = _join_from(args, 1)
	if value.is_empty():
		if _headers.erase(name):
			return _format_success("Cleared header %s" % _color_path(name))
		return _format_muted("Header %s was not set." % name)
	_headers[name] = value
	return _format_success("Header %s = %s" % [_color_path(name), value])

func _cmd_rest_auth_bearer(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: rest_auth_bearer <token> (empty clears)")
	var token: String = _join_from(args, 0)
	if token.is_empty():
		_auth_bearer = ""
		return _format_success("Cleared bearer token.")
	_auth_bearer = token
	return _format_success("Bearer token set (%s chars)." % _color_number(str(token.length())))

func _cmd_rest_get(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: rest_get <path>")
	var path: String = str(args[0]).strip_edges()
	return _dispatch(HTTPClient.METHOD_GET, path, "")

func _cmd_rest_post(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: rest_post <path> <json>")
	var path: String = str(args[0]).strip_edges()
	var body: String = _join_from(args, 1)
	return _dispatch(HTTPClient.METHOD_POST, path, body)

func _cmd_rest_session(args: Array, piped_input: String = "") -> String:
	var lines: Array[String] = []
	lines.append("REST session state:")
	if _base_url.is_empty():
		lines.append("  base: " + _format_muted("<unset>"))
	else:
		lines.append("  base: " + _color_path(_base_url))

	if _auth_bearer.is_empty():
		lines.append("  auth: " + _format_muted("<no bearer token>"))
	else:
		lines.append("  auth: Bearer " + _mask_token(_auth_bearer))

	if _headers.is_empty():
		lines.append("  headers: " + _format_muted("<none>"))
	else:
		lines.append("  headers (%s):" % _color_number(str(_headers.size())))
		var keys: Array = _headers.keys()
		keys.sort()
		for k in keys:
			lines.append("    %s: %s" % [_color_path(str(k)), str(_headers[k])])

	lines.append("  in-flight: " + _color_number(str(_active.size())))
	if _registry and is_instance_valid(_registry) and _registry.has_method("has_command"):
		if bool(_registry.call("has_command", "http_get")):
			lines.append("  " + _format_muted("HttpCommands (http_get/http_post/...) also loaded."))
	return "\n".join(lines)

#endregion

#region Async plumbing

func _dispatch(method: int, path: String, body: String) -> String:
	var url: String = _resolve_url(path)
	if url.is_empty():
		return _format_error("Cannot dispatch: no base URL set and path is not an absolute URL.")

	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if not tree or not tree.root:
		return _format_error("No SceneTree root available for HTTPRequest.")

	var id: String = _next_id()
	var http: HTTPRequest = HTTPRequest.new()
	http.name = "DebugConsoleRest_%s" % id
	tree.root.add_child(http)

	var headers: PackedStringArray = _build_headers(method)
	var method_name: String = _method_name(method)
	_active[id] = {
		"node": http,
		"method": method_name,
		"url": url,
		"started_at": Time.get_ticks_msec(),
	}
	http.request_completed.connect(_on_request_completed.bind(id))

	var err: int = http.request(url, headers, method, body)
	if err != OK:
		http.queue_free()
		_active.erase(id)
		return _format_error("rest %s failed to start: err=%d (%s)" % [method_name, err, url])

	return _format_success("%s %s queued as %s" % [
		method_name,
		url,
		_color_path(id)
	])

func _on_request_completed(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray, id: String) -> void:
	if not _active.has(id):
		return
	var info: Dictionary = _active[id]
	var http: HTTPRequest = info.get("node") as HTTPRequest
	var method_name: String = str(info.get("method", "?"))
	var url: String = str(info.get("url", ""))

	_active.erase(id)
	if is_instance_valid(http):
		http.queue_free()

	var body_text: String = body.get_string_from_utf8() if body.size() > 0 else ""
	var error_text: String = ""
	if result != HTTPRequest.RESULT_SUCCESS:
		error_text = _result_name(result)

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
	_emit_result(summary)

func _emit_result(msg: String) -> void:
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

func _resolve_url(path: String) -> String:
	var p: String = path.strip_edges()
	if p.begins_with("http://") or p.begins_with("https://"):
		return p
	if _base_url.is_empty():
		# Allow absolute URL only when no base is set.
		return ""
	if p.is_empty():
		return _base_url
	var base: String = _base_url
	if base.ends_with("/") and p.begins_with("/"):
		return base + p.substr(1)
	if not base.ends_with("/") and not p.begins_with("/"):
		return base + "/" + p
	return base + p

func _build_headers(method: int) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var seen_content_type: bool = false
	var seen_authorization: bool = false
	for k in _headers.keys():
		var key: String = str(k)
		out.append("%s: %s" % [key, str(_headers[k])])
		var lower: String = key.to_lower()
		if lower == "content-type":
			seen_content_type = true
		elif lower == "authorization":
			seen_authorization = true
	if not _auth_bearer.is_empty() and not seen_authorization:
		out.append("Authorization: Bearer %s" % _auth_bearer)
	if (method == HTTPClient.METHOD_POST or method == HTTPClient.METHOD_PUT) and not seen_content_type:
		out.append("Content-Type: application/json")
	return out

func _mask_token(token: String) -> String:
	if token.length() <= 8:
		return "*".repeat(token.length())
	return token.substr(0, 4) + "..." + token.substr(token.length() - 4, 4) + (" (%d chars)" % token.length())

func _next_id() -> String:
	_next_id_counter += 1
	return "rest_%d" % _next_id_counter

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

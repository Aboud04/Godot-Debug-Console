@tool
class_name DebugConsoleWebhookCommands extends RefCounted

# Tier 7 extension - HTTP webhook listener + sender commands.
# Mirrors WebSocketCommands: the outer RefCounted module is a thin facade.
# A child _PollHelper Node lives under _core inside the game scene tree so
# TCPServer / StreamPeerTCP get polled every frame. The helper owns the
# server table, the received-payload buffers, and the per-server
# "run this command on every payload" template wiring.
#
# `webhook_send` uses a one-shot HTTPRequest under /root (mirrors
# HttpCommands._dispatch) so the call is fire-and-forget and the summary is
# delivered back to the console asynchronously via _emit_result.
#
# All commands register under the "game" context: opening a listening socket
# from the editor process would be both surprising and dangerous, so we hard
# gate on Engine.is_editor_hint() in register_commands.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_DIM := "#808080"
const _COLOR_MUTED := "#888888"

const _DEFAULT_RECV_COUNT := 10
const _MAX_BUFFER := 100
const _MAX_HEADER_BYTES := 16384
const _MAX_BODY_BYTES := 1048576

var _registry: Node
var _core: Node
var _helper: Node

var _next_send_counter: int = 0

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return

	if not Engine.is_editor_hint() and _core:
		_helper = _PollHelper.new()
		_helper.name = "DebugConsoleWebhookHelper"
		_helper.registry = registry
		_helper.core = core
		_core.add_child(_helper)

	_registry.register_command("webhook_listen", _cmd_listen, "Start an HTTP listener: webhook_listen <port> <path> (returns id)", "game")
	_registry.register_command("webhook_list", _cmd_list, "List active webhook listeners", "game")
	_registry.register_command("webhook_stop", _cmd_stop, "Stop a webhook listener: webhook_stop <id|all>", "game")
	_registry.register_command("webhook_recv", _cmd_recv, "Show last N received payloads: webhook_recv <id> [n]", "game")
	_registry.register_command("webhook_send", _cmd_send, "Fire-and-forget HTTP POST: webhook_send <url> <json_text>", "game")
	_registry.register_command("webhook_to_command", _cmd_to_command, "Run a command for every received webhook (substitutes {body}): webhook_to_command <id> <command_template>", "game")

#region Command implementations

func _cmd_listen(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: webhook_listen <port> <path>")
	var helper := _require_helper()
	if not helper:
		return _format_error("Webhook helper unavailable (editor context?)")

	var port_raw := str(args[0]).strip_edges()
	if not port_raw.is_valid_int():
		return _format_error("Port must be an integer: %s" % port_raw)
	var port := port_raw.to_int()
	if port <= 0 or port > 65535:
		return _format_error("Port out of range (1-65535): %d" % port)

	var path := str(args[1]).strip_edges()
	if path.is_empty():
		return _format_error("Path is required (e.g. /hook)")
	if not path.begins_with("/"):
		path = "/" + path

	var result: Dictionary = helper.start_listener(port, path)
	if not bool(result.get("ok", false)):
		return _format_error(str(result.get("error", "listen failed")))
	var id: String = str(result.get("id", ""))
	return _format_success("listening id=%s port=%s path=%s" % [
		_color_path(id),
		_color_number(str(port)),
		_color_path(path),
	])

func _cmd_list(args: Array, piped_input: String = "") -> String:
	var helper := _require_helper()
	if not helper:
		return _format_error("Webhook helper unavailable")
	var servers: Dictionary = helper.servers
	if servers.is_empty():
		return "[color=%s](no active webhook listeners)[/color]" % _COLOR_DIM

	var ids: Array = servers.keys()
	ids.sort()
	var lines: Array[String] = []
	lines.append("%s active webhook listener(s)" % _color_number(str(ids.size())))
	for id in ids:
		var entry: Dictionary = servers[id]
		var port: int = int(entry.get("port", 0))
		var path: String = str(entry.get("path", ""))
		var received: Array = entry.get("received", [])
		var template: String = str(entry.get("template", ""))
		var template_str: String = template if not template.is_empty() else "<none>"
		lines.append("  %s  port=%s  path=%s  recv=%s  to_cmd=%s" % [
			_color_path(str(id)),
			_color_number(str(port)),
			_color_path(path),
			_color_number(str(received.size())),
			template_str,
		])
	return "\n".join(lines)

func _cmd_stop(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: webhook_stop <id|all>")
	var helper := _require_helper()
	if not helper:
		return _format_error("Webhook helper unavailable")
	var target := str(args[0]).strip_edges()
	if target.to_lower() == "all":
		var n: int = helper.stop_all()
		return _format_success("Stopped %s listener(s)" % _color_number(str(n)))
	if not helper.servers.has(target):
		return _format_error("Unknown webhook id: %s" % target)
	helper.stop_one(target)
	return _format_success("Stopped %s" % _color_path(target))

func _cmd_recv(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: webhook_recv <id> [n]")
	var helper := _require_helper()
	if not helper:
		return _format_error("Webhook helper unavailable")
	var id := str(args[0]).strip_edges()
	if not helper.servers.has(id):
		return _format_error("Unknown webhook id: %s" % id)

	var n: int = _DEFAULT_RECV_COUNT
	if args.size() > 1:
		var n_raw := str(args[1]).strip_edges()
		if not n_raw.is_valid_int():
			return _format_error("n must be an integer: %s" % n_raw)
		n = max(1, n_raw.to_int())

	var entry: Dictionary = helper.servers[id]
	var buf: Array = entry.get("received", [])
	if buf.is_empty():
		return "[color=%s](webhook %s: no payloads received)[/color]" % [_COLOR_DIM, id]

	var start: int = max(0, buf.size() - n)
	var lines: Array[String] = []
	lines.append("webhook %s: last %s of %s payload(s)" % [
		_color_path(id),
		_color_number(str(buf.size() - start)),
		_color_number(str(buf.size())),
	])
	for i in range(start, buf.size()):
		var msg: Dictionary = buf[i]
		var ts := float(msg.get("ts", 0.0))
		var body := str(msg.get("body", ""))
		var remote := str(msg.get("remote", ""))
		lines.append("  [%s] %s  %s bytes" % [_format_ts(ts), remote, _color_number(str(body.length()))])
		lines.append("    %s" % _truncate(body, 512))
	return "\n".join(lines)

func _cmd_send(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: webhook_send <url> <json_text>")
	var url := str(args[0]).strip_edges()
	if url.is_empty():
		return _format_error("URL is required")
	if not (url.begins_with("http://") or url.begins_with("https://")):
		return _format_error("URL must start with http:// or https:// (got %s)" % url)

	var body := _join_from(args, 1)
	if body.is_empty() and not piped_input.is_empty():
		body = piped_input
	if body.is_empty():
		return _format_error("Body is required")

	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if not tree or not tree.root:
		return _format_error("No SceneTree root available for HTTPRequest")

	_next_send_counter += 1
	var id: String = "wh_send_%d" % _next_send_counter
	var http: HTTPRequest = HTTPRequest.new()
	http.name = "DebugConsoleWebhookSend_%s" % id
	tree.root.add_child(http)

	var headers: PackedStringArray = PackedStringArray(["Content-Type: application/json"])
	http.request_completed.connect(_on_send_completed.bind(id, url, http))

	var err: int = http.request(url, headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		http.queue_free()
		return _format_error("webhook_send failed to start: err=%d (%s)" % [err, url])

	return _format_success("POST %s queued as %s" % [url, _color_path(id)])

func _cmd_to_command(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: webhook_to_command <id> <command_template>")
	var helper := _require_helper()
	if not helper:
		return _format_error("Webhook helper unavailable")
	var id := str(args[0]).strip_edges()
	if not helper.servers.has(id):
		return _format_error("Unknown webhook id: %s" % id)

	var template: String = _join_from(args, 1)
	if template.is_empty() and not piped_input.is_empty():
		template = piped_input.strip_edges()

	if template.is_empty():
		helper.set_template(id, "")
		return _format_success("Cleared command template for %s" % _color_path(id))

	helper.set_template(id, template)
	var note: String = "" if template.contains("{body}") else " [color=%s](no {body} placeholder; payload will be ignored)[/color]" % _COLOR_MUTED
	return _format_success("Template set for %s -> %s%s" % [_color_path(id), template, note])

#endregion

#region Send async plumbing

func _on_send_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray, id: String, url: String, http: HTTPRequest) -> void:
	if is_instance_valid(http):
		http.queue_free()
	var body_text: String = body.get_string_from_utf8() if body.size() > 0 else ""
	var preview: String = _truncate(body_text, 200)
	var status_str: String = _status_color(response_code)
	var err_str: String = ""
	if result != HTTPRequest.RESULT_SUCCESS:
		err_str = " (err=%d)" % result
	var summary: String = "[%s] POST %s -> %s%s%s" % [
		_color_path(id),
		url,
		status_str,
		err_str,
		("\n  " + preview) if not preview.is_empty() else "",
	]
	_emit_result(summary)

# Mirrors HttpCommands._emit_result: try print_to_console, then info,
# then registry echo, then plain print as a last resort.
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

func _require_helper() -> Node:
	if _helper and is_instance_valid(_helper):
		return _helper
	return null

func _join_from(args: Array, start: int) -> String:
	var parts: Array[String] = []
	for i in range(start, args.size()):
		parts.append(str(args[i]))
	return " ".join(parts).strip_edges()

func _truncate(s: String, limit: int) -> String:
	if s.length() <= limit:
		return s
	return s.substr(0, limit) + "..."

func _format_ts(ts: float) -> String:
	if ts <= 0.0:
		return "0"
	var dt := Time.get_datetime_dict_from_unix_time(int(ts))
	return "%02d:%02d:%02d" % [int(dt.hour), int(dt.minute), int(dt.second)]

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

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

func _color_success(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, s]

func _color_error(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_ERROR, s]

#endregion

#region Poll helper (inner Node)

# Lives as a child of _core inside the game scene tree so _process() runs every
# frame. Owns the listener table; the outer RefCounted module forwards calls.
# Each entry:
#   servers[id] = {
#       server: TCPServer, port: int, path: String,
#       peers: Array of { stream: StreamPeerTCP, buf: PackedByteArray,
#                          headers_done: bool, content_length: int,
#                          method: String, req_path: String, remote: String },
#       received: Array of { ts: float, body: String, remote: String, headers: Dictionary },
#       template: String, next_peer_id: int,
#   }
class _PollHelper extends Node:
	var servers: Dictionary = {}
	var next_id: int = 1
	var registry: Node
	var core: Node

	const MAX_BUFFER := 100
	const MAX_HEADER_BYTES := 16384
	const MAX_BODY_BYTES := 1048576

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS

	func _exit_tree() -> void:
		stop_all()

	func _process(_delta: float) -> void:
		if servers.is_empty():
			return
		for id in servers.keys():
			_poll_server(id)

	func start_listener(port: int, path: String) -> Dictionary:
		var server := TCPServer.new()
		var err := server.listen(port)
		if err != OK:
			return {"ok": false, "error": "TCPServer.listen(%d) failed (code %d)" % [port, err]}
		var id: String = "wh_%d" % next_id
		next_id += 1
		servers[id] = {
			"server": server,
			"port": port,
			"path": path,
			"peers": [],
			"received": [],
			"template": "",
			"created": Time.get_unix_time_from_system(),
		}
		return {"ok": true, "id": id}

	func stop_one(id: String) -> bool:
		if not servers.has(id):
			return false
		var entry: Dictionary = servers[id]
		var server: TCPServer = entry.get("server")
		if server:
			server.stop()
		var peers: Array = entry.get("peers", [])
		for peer in peers:
			var stream: StreamPeerTCP = peer.get("stream")
			if stream:
				stream.disconnect_from_host()
		servers.erase(id)
		return true

	func stop_all() -> int:
		var count: int = servers.size()
		for id in servers.keys():
			var entry: Dictionary = servers[id]
			var server: TCPServer = entry.get("server")
			if server:
				server.stop()
			var peers: Array = entry.get("peers", [])
			for peer in peers:
				var stream: StreamPeerTCP = peer.get("stream")
				if stream:
					stream.disconnect_from_host()
		servers.clear()
		return count

	func set_template(id: String, template: String) -> void:
		if not servers.has(id):
			return
		servers[id]["template"] = template

	func _poll_server(id: String) -> void:
		var entry: Dictionary = servers[id]
		var server: TCPServer = entry.get("server")
		if not server:
			return

		# Accept any new pending connections.
		while server.is_connection_available():
			var stream: StreamPeerTCP = server.take_connection()
			if not stream:
				break
			var remote_host: String = stream.get_connected_host()
			var remote_port: int = stream.get_connected_port()
			(entry.peers as Array).append({
				"stream": stream,
				"buf": PackedByteArray(),
				"headers_done": false,
				"content_length": -1,
				"method": "",
				"req_path": "",
				"remote": "%s:%d" % [remote_host, remote_port],
				"headers": {},
			})

		# Drain bytes from each open peer; finish requests that have arrived in full.
		var kept: Array = []
		for peer in (entry.peers as Array):
			if _advance_peer(entry, peer):
				kept.append(peer)
		entry.peers = kept

	# Returns true if the peer should be kept in the active list, false if it
	# is done and its stream has been disconnected.
	func _advance_peer(entry: Dictionary, peer: Dictionary) -> bool:
		var stream: StreamPeerTCP = peer.get("stream")
		if not stream:
			return false
		stream.poll()
		var status: int = stream.get_status()
		if status == StreamPeerTCP.STATUS_ERROR or status == StreamPeerTCP.STATUS_NONE:
			stream.disconnect_from_host()
			return false

		var available: int = stream.get_available_bytes()
		if available > 0:
			var chunk_size: int = min(available, 65536)
			var got: Array = stream.get_partial_data(chunk_size)
			var err: int = int(got[0])
			var bytes: PackedByteArray = got[1]
			if err == OK and bytes.size() > 0:
				(peer.buf as PackedByteArray).append_array(bytes)

		var buf: PackedByteArray = peer.buf

		if not peer.headers_done:
			if buf.size() > MAX_HEADER_BYTES:
				_send_response(stream, 431, "Request Header Fields Too Large")
				stream.disconnect_from_host()
				return false
			var sep: int = _find_header_end(buf)
			if sep < 0:
				# Need more bytes. If the remote already disconnected and we
				# never saw the end of headers, give up.
				if status == StreamPeerTCP.STATUS_NONE:
					stream.disconnect_from_host()
					return false
				return true
			var header_text: String = buf.slice(0, sep).get_string_from_utf8()
			var header_end: int = sep + 4  # past "\r\n\r\n"
			peer.buf = buf.slice(header_end, buf.size())
			peer.headers_done = true
			if not _parse_headers(peer, header_text):
				_send_response(stream, 400, "Bad Request")
				stream.disconnect_from_host()
				return false

		var needed: int = int(peer.content_length)
		if needed < 0:
			needed = 0
		if needed > MAX_BODY_BYTES:
			_send_response(stream, 413, "Payload Too Large")
			stream.disconnect_from_host()
			return false

		if (peer.buf as PackedByteArray).size() < needed:
			if status == StreamPeerTCP.STATUS_NONE:
				stream.disconnect_from_host()
				return false
			return true

		# Full request received - body is the first `needed` bytes.
		var body_bytes: PackedByteArray = (peer.buf as PackedByteArray).slice(0, needed)
		var body_text: String = body_bytes.get_string_from_utf8()
		_dispatch_request(entry, peer, body_text)
		stream.disconnect_from_host()
		return false

	func _parse_headers(peer: Dictionary, header_text: String) -> bool:
		var lines: PackedStringArray = header_text.split("\r\n")
		if lines.is_empty():
			return false
		var request_line: String = lines[0]
		var parts: PackedStringArray = request_line.split(" ")
		if parts.size() < 3:
			return false
		peer.method = parts[0].to_upper()
		peer.req_path = parts[1]

		var headers: Dictionary = {}
		for i in range(1, lines.size()):
			var line: String = lines[i]
			if line.is_empty():
				continue
			var colon: int = line.find(":")
			if colon <= 0:
				continue
			var key: String = line.substr(0, colon).strip_edges().to_lower()
			var value: String = line.substr(colon + 1).strip_edges()
			headers[key] = value
		peer.headers = headers

		var cl_raw: String = str(headers.get("content-length", "0")).strip_edges()
		if cl_raw.is_valid_int():
			peer.content_length = max(0, cl_raw.to_int())
		else:
			peer.content_length = 0
		return true

	func _dispatch_request(entry: Dictionary, peer: Dictionary, body_text: String) -> void:
		var stream: StreamPeerTCP = peer.get("stream")
		var method: String = str(peer.get("method", ""))
		var req_path: String = str(peer.get("req_path", ""))
		var expected_path: String = str(entry.get("path", ""))

		# Strip query string for matching.
		var match_path: String = req_path
		var q: int = match_path.find("?")
		if q >= 0:
			match_path = match_path.substr(0, q)

		if method != "POST":
			_send_response(stream, 405, "Method Not Allowed", "Only POST is accepted.")
			return
		if match_path != expected_path:
			_send_response(stream, 404, "Not Found", "No webhook at %s" % match_path)
			return

		var received: Array = entry.get("received", [])
		received.append({
			"ts": Time.get_unix_time_from_system(),
			"body": body_text,
			"remote": str(peer.get("remote", "")),
			"headers": peer.get("headers", {}),
		})
		while received.size() > MAX_BUFFER:
			received.pop_front()
		entry.received = received

		_send_response(stream, 200, "OK", "received")

		var template: String = str(entry.get("template", ""))
		if not template.is_empty() and registry and is_instance_valid(registry) and registry.has_method("execute_command"):
			var command: String = template.replace("{body}", body_text)
			registry.call("execute_command", command)

	func _find_header_end(buf: PackedByteArray) -> int:
		# Locate "\r\n\r\n" (13 10 13 10) in buf; returns start index of the
		# blank-line separator or -1 if not yet present.
		var size: int = buf.size()
		if size < 4:
			return -1
		for i in range(size - 3):
			if buf[i] == 13 and buf[i + 1] == 10 and buf[i + 2] == 13 and buf[i + 3] == 10:
				return i
		return -1

	func _send_response(stream: StreamPeerTCP, code: int, reason: String, body: String = "") -> void:
		if not stream:
			return
		var body_bytes: PackedByteArray = body.to_utf8_buffer()
		var header: String = "HTTP/1.1 %d %s\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % [code, reason, body_bytes.size()]
		var header_bytes: PackedByteArray = header.to_utf8_buffer()
		stream.put_data(header_bytes)
		if body_bytes.size() > 0:
			stream.put_data(body_bytes)

#endregion

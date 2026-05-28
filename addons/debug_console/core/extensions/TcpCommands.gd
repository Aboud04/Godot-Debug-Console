@tool
class_name DebugConsoleTcpCommands extends RefCounted

# Tier 7 extension - raw TCP commands for live debugging.
# Mirrors the WebSocketCommands pattern: the orchestrator instantiates one of
# these, holds a strong reference, and calls register_commands(registry, core).
#
# Connections and listening servers live inside a child helper Node
# (_PollHelper) attached to the core node so StreamPeerTCP / TCPServer
# instances get polled every frame inside the game scene tree. The RefCounted
# module itself is a thin facade that forwards command Callables to the helper.
#
# Commands are registered with the "game" context: TCP traffic only makes
# sense at runtime, and we avoid opening live sockets from the editor process.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_DIM := "#808080"

const _MAX_RECV_BUFFER := 65536
const _MAX_EVENT_LOG := 50
const _HEX_PREVIEW_BYTES := 64

var _registry: Node
var _core: Node
var _helper: Node

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return

	if not Engine.is_editor_hint() and _core:
		_helper = _PollHelper.new()
		_helper.name = "DebugConsoleTcpHelper"
		_core.add_child(_helper)

	_registry.register_command("tcp_connect", _cmd_tcp_connect, "Open a TCP connection: tcp_connect <host> <port> (returns conn_id)", "game")
	_registry.register_command("tcp_send", _cmd_tcp_send, "Send bytes on a TCP connection: tcp_send <conn_id> <bytes_hex_or_text> (prefix hex with 0x or hex:)", "game")
	_registry.register_command("tcp_recv", _cmd_tcp_recv, "Read buffered bytes: tcp_recv <conn_id> [bytes_n]", "game")
	_registry.register_command("tcp_close", _cmd_tcp_close, "Close a TCP socket: tcp_close <conn_id|all> (matches both client conns and servers)", "game")
	_registry.register_command("tcp_listen", _cmd_tcp_listen, "Listen for incoming TCP connections: tcp_listen <port> (returns server_id)", "game")
	_registry.register_command("tcp_servers", _cmd_tcp_servers, "List active listening TCP sockets with their port and peer count", "game")

#region Command implementations

func _cmd_tcp_connect(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: tcp_connect <host> <port>")
	var helper := _require_helper()
	if not helper:
		return _format_error("TCP helper unavailable (editor context?)")
	var host := str(args[0]).strip_edges()
	if host.is_empty():
		return _format_error("Empty host")
	var port_raw := str(args[1]).strip_edges()
	if not port_raw.is_valid_int():
		return _format_error("Port must be an integer: %s" % port_raw)
	var port := port_raw.to_int()
	if port <= 0 or port > 65535:
		return _format_error("Port out of range (1-65535): %d" % port)

	var result: Dictionary = helper.connect_host(host, port)
	if not bool(result.get("ok", false)):
		return _format_error(str(result.get("error", "connect failed")))
	var id: int = int(result.get("id", 0))
	return _format_success("conn_id=%s host=%s port=%s" % [
		_color_number(str(id)),
		_color_path(host),
		_color_number(str(port)),
	])

func _cmd_tcp_send(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: tcp_send <conn_id> <bytes_hex_or_text>")
	var helper := _require_helper()
	if not helper:
		return _format_error("TCP helper unavailable")
	var id_parsed := _parse_id(str(args[0]))
	if id_parsed < 0:
		return _format_error("Invalid conn_id: %s" % str(args[0]))
	var tail: Array = args.slice(1)
	var payload := " ".join(tail)
	if payload.is_empty() and not piped_input.is_empty():
		payload = piped_input

	var bytes := _parse_payload(payload)
	if bytes.is_empty():
		return _format_error("Empty payload")

	var result: Dictionary = helper.send_bytes(id_parsed, bytes)
	if not bool(result.get("ok", false)):
		return _format_error(str(result.get("error", "send failed")))
	return _format_success("sent %s bytes on conn %s" % [
		_color_number(str(bytes.size())),
		_color_number(str(id_parsed)),
	])

func _cmd_tcp_recv(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: tcp_recv <conn_id> [bytes_n]")
	var helper := _require_helper()
	if not helper:
		return _format_error("TCP helper unavailable")
	var id_parsed := _parse_id(str(args[0]))
	if id_parsed < 0:
		return _format_error("Invalid conn_id: %s" % str(args[0]))
	if not helper.connections.has(id_parsed):
		return _format_error("Unknown conn_id: %d" % id_parsed)

	var want_all: bool = true
	var n: int = 0
	if args.size() > 1:
		var n_raw := str(args[1]).strip_edges()
		if not n_raw.is_valid_int():
			return _format_error("bytes_n must be an integer: %s" % n_raw)
		n = max(0, n_raw.to_int())
		want_all = false

	var entry: Dictionary = helper.connections[id_parsed]
	var buf: PackedByteArray = entry.received
	if buf.is_empty():
		return "[color=%s](conn %d: no buffered bytes)[/color]" % [_COLOR_DIM, id_parsed]

	var take: int = buf.size() if want_all else min(n, buf.size())
	var slice: PackedByteArray = buf.slice(0, take)
	var remaining: PackedByteArray = buf.slice(take)
	entry.received = remaining

	var preview_count: int = min(slice.size(), _HEX_PREVIEW_BYTES)
	var hex_preview: String = _to_hex(slice.slice(0, preview_count))
	var text_preview: String = slice.get_string_from_utf8()
	var lines: Array[String] = []
	lines.append("conn %s: read %s of %s buffered byte(s), %s remaining" % [
		_color_number(str(id_parsed)),
		_color_number(str(slice.size())),
		_color_number(str(buf.size())),
		_color_number(str(remaining.size())),
	])
	lines.append("  hex : %s%s" % [hex_preview, ("..." if slice.size() > preview_count else "")])
	if not text_preview.is_empty():
		lines.append("  text: %s" % text_preview)
	return "\n".join(lines)

func _cmd_tcp_close(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: tcp_close <conn_id|all>")
	var helper := _require_helper()
	if not helper:
		return _format_error("TCP helper unavailable")
	var target := str(args[0]).strip_edges().to_lower()

	if target == "all":
		var counts: Dictionary = helper.close_all()
		return _format_success("Closed %s conn(s) and %s server(s)" % [
			_color_number(str(int(counts.get("connections", 0)))),
			_color_number(str(int(counts.get("servers", 0)))),
		])

	var id_parsed := _parse_id(target)
	if id_parsed < 0:
		return _format_error("Invalid id: %s" % target)
	var kind: String = helper.close_id(id_parsed)
	if kind.is_empty():
		return _format_error("Unknown id: %d (not a connection or server)" % id_parsed)
	return _format_success("Closed %s %s" % [kind, _color_number(str(id_parsed))])

func _cmd_tcp_listen(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: tcp_listen <port>")
	var helper := _require_helper()
	if not helper:
		return _format_error("TCP helper unavailable (editor context?)")
	var port_raw := str(args[0]).strip_edges()
	if not port_raw.is_valid_int():
		return _format_error("Port must be an integer: %s" % port_raw)
	var port := port_raw.to_int()
	if port < 0 or port > 65535:
		return _format_error("Port out of range (0-65535): %d" % port)

	var result: Dictionary = helper.listen_port(port)
	if not bool(result.get("ok", false)):
		return _format_error(str(result.get("error", "listen failed")))
	var id: int = int(result.get("id", 0))
	var bound: int = int(result.get("port", port))
	return _format_success("server_id=%s listening on port %s" % [
		_color_number(str(id)),
		_color_number(str(bound)),
	])

func _cmd_tcp_servers(args: Array, piped_input: String = "") -> String:
	var helper := _require_helper()
	if not helper:
		return _format_error("TCP helper unavailable")
	var servers: Dictionary = helper.servers
	if servers.is_empty():
		return "[color=%s](no active TCP servers)[/color]" % _COLOR_DIM
	var ids: Array = servers.keys()
	ids.sort()
	var lines: Array[String] = []
	lines.append("%s active TCP server(s)" % _color_number(str(ids.size())))
	for id in ids:
		var entry: Dictionary = servers[id]
		var server: TCPServer = entry.server
		var listening: bool = server != null and server.is_listening()
		var peers: Array = entry.peers
		var events: Array = entry.events
		var last_event: String = ""
		if not events.is_empty():
			var e: Dictionary = events[events.size() - 1]
			last_event = " last=[%s] %s" % [_format_ts(float(e.get("ts", 0.0))), str(e.get("msg", ""))]
		lines.append("  %s  port=%s  listening=%s  peers=%s  events=%s%s" % [
			_color_number("[" + str(id) + "]"),
			_color_number(str(int(entry.get("port", 0)))),
			("yes" if listening else "[color=%s]no[/color]" % _COLOR_ERROR),
			_color_number(str(peers.size())),
			_color_number(str(events.size())),
			last_event,
		])
	return "\n".join(lines)

#endregion

#region Helpers

func _require_helper() -> Node:
	if _helper and is_instance_valid(_helper):
		return _helper
	return null

func _parse_id(raw: String) -> int:
	var s := raw.strip_edges()
	if not s.is_valid_int():
		return -1
	var v := s.to_int()
	if v < 0:
		return -1
	return v

func _parse_payload(raw: String) -> PackedByteArray:
	var s := raw
	var hex_src := ""
	if s.begins_with("hex:") or s.begins_with("HEX:"):
		hex_src = s.substr(4).strip_edges()
	elif s.begins_with("0x") or s.begins_with("0X"):
		hex_src = s.substr(2).strip_edges()
	if not hex_src.is_empty():
		return _hex_to_bytes(hex_src)
	return s.to_utf8_buffer()

func _hex_to_bytes(hex: String) -> PackedByteArray:
	var clean := hex.replace(" ", "").replace("\t", "").replace("\n", "").replace("\r", "")
	var out: PackedByteArray = PackedByteArray()
	if clean.is_empty():
		return out
	if (clean.length() % 2) != 0:
		return out
	for i in range(0, clean.length(), 2):
		var pair := clean.substr(i, 2)
		var v := pair.hex_to_int()
		if v < 0 or v > 255:
			return PackedByteArray()
		out.append(v)
	return out

func _to_hex(bytes: PackedByteArray) -> String:
	if bytes.is_empty():
		return ""
	var parts: Array[String] = []
	for b in bytes:
		parts.append("%02X" % int(b))
	return " ".join(parts)

func _format_ts(ts: float) -> String:
	if ts <= 0.0:
		return "0"
	var dt := Time.get_datetime_dict_from_unix_time(int(ts))
	return "%02d:%02d:%02d" % [int(dt.hour), int(dt.minute), int(dt.second)]

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

#endregion

#region Poll helper (inner Node)

# Lives as a child of _core inside the game scene tree so _process() runs every
# frame. Owns the connection and server tables; the outer RefCounted module
# forwards calls. A single next_id counter unifies client conn ids, accepted
# peer ids, and server ids so `tcp_close <id>` is unambiguous.
class _PollHelper extends Node:
	const _BUFFER_CAP: int = 65536
	const _EVENT_CAP: int = 50
	const _HEX_LIMIT: int = 32

	var connections: Dictionary = {}
	var servers: Dictionary = {}
	var next_id: int = 1

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS

	func _process(_delta: float) -> void:
		_poll_servers()
		_poll_connections()

	func _poll_servers() -> void:
		if servers.is_empty():
			return
		for sid in servers.keys():
			var entry: Dictionary = servers[sid]
			var server: TCPServer = entry.server
			if server == null or not server.is_listening():
				continue
			while server.is_connection_available():
				var peer: StreamPeerTCP = server.take_connection()
				if peer == null:
					break
				var pid: int = next_id
				next_id += 1
				var host: String = ""
				var port: int = 0
				if peer.has_method("get_connected_host"):
					host = str(peer.get_connected_host())
				if peer.has_method("get_connected_port"):
					port = int(peer.get_connected_port())
				connections[pid] = {
					"peer": peer,
					"host": host,
					"port": port,
					"received": PackedByteArray(),
					"created": Time.get_unix_time_from_system(),
					"server_id": sid,
				}
				var peers: Array = entry.peers
				peers.append(pid)
				var msg: String = "accepted conn_id=%d from %s:%d" % [pid, host, port]
				_log_event(entry, msg)
				print("[TCP server %d] %s" % [sid, msg])

	func _poll_connections() -> void:
		if connections.is_empty():
			return
		var dead: Array[int] = []
		for id in connections.keys():
			var entry: Dictionary = connections[id]
			var peer: StreamPeerTCP = entry.peer
			if peer == null:
				dead.append(id)
				continue
			peer.poll()
			var status: int = peer.get_status()
			if status == StreamPeerTCP.STATUS_ERROR:
				dead.append(id)
				continue
			if status != StreamPeerTCP.STATUS_CONNECTED:
				continue
			var avail: int = peer.get_available_bytes()
			while avail > 0:
				var chunk: int = min(avail, 4096)
				var got: Array = peer.get_partial_data(chunk)
				var err: int = int(got[0])
				if err != OK:
					break
				var data: PackedByteArray = got[1]
				if data.is_empty():
					break
				var buf: PackedByteArray = entry.received
				buf.append_array(data)
				if buf.size() > _BUFFER_CAP:
					var overflow: int = buf.size() - _BUFFER_CAP
					buf = buf.slice(overflow)
				entry.received = buf
				avail = peer.get_available_bytes()
		for id in dead:
			var entry2: Dictionary = connections.get(id, {})
			if entry2.has("server_id"):
				var sid: int = int(entry2.get("server_id", -1))
				if servers.has(sid):
					var sentry: Dictionary = servers[sid]
					var peers: Array = sentry.peers
					peers.erase(id)
					_log_event(sentry, "conn_id=%d disconnected" % id)
			connections.erase(id)

	func connect_host(host: String, port: int) -> Dictionary:
		var peer := StreamPeerTCP.new()
		var err := peer.connect_to_host(host, port)
		if err != OK:
			return {"ok": false, "error": "connect_to_host failed (code %d)" % err}
		var id: int = next_id
		next_id += 1
		connections[id] = {
			"peer": peer,
			"host": host,
			"port": port,
			"received": PackedByteArray(),
			"created": Time.get_unix_time_from_system(),
		}
		return {"ok": true, "id": id}

	func send_bytes(id: int, data: PackedByteArray) -> Dictionary:
		if not connections.has(id):
			return {"ok": false, "error": "Unknown conn_id: %d" % id}
		var peer: StreamPeerTCP = connections[id].peer
		if peer == null:
			return {"ok": false, "error": "Connection has no peer"}
		peer.poll()
		var status: int = peer.get_status()
		if status != StreamPeerTCP.STATUS_CONNECTED:
			return {"ok": false, "error": "Connection not open (status=%d)" % status}
		var err := peer.put_data(data)
		if err != OK:
			return {"ok": false, "error": "put_data failed (code %d)" % err}
		return {"ok": true}

	func listen_port(port: int) -> Dictionary:
		var server := TCPServer.new()
		var err := server.listen(port)
		if err != OK:
			return {"ok": false, "error": "listen failed on port %d (code %d)" % [port, err]}
		var id: int = next_id
		next_id += 1
		servers[id] = {
			"server": server,
			"port": server.get_local_port() if server.has_method("get_local_port") else port,
			"peers": [],
			"events": [],
			"created": Time.get_unix_time_from_system(),
		}
		_log_event(servers[id], "listening on port %d" % int(servers[id].port))
		return {"ok": true, "id": id, "port": int(servers[id].port)}

	func close_id(id: int) -> String:
		if connections.has(id):
			_close_conn(id)
			return "conn"
		if servers.has(id):
			_close_server(id)
			return "server"
		return ""

	func close_all() -> Dictionary:
		var conn_count: int = connections.size()
		var server_count: int = servers.size()
		for id in connections.keys():
			var peer: StreamPeerTCP = connections[id].peer
			if peer:
				peer.disconnect_from_host()
		connections.clear()
		for sid in servers.keys():
			var server: TCPServer = servers[sid].server
			if server:
				server.stop()
		servers.clear()
		return {"connections": conn_count, "servers": server_count}

	func _close_conn(id: int) -> void:
		if not connections.has(id):
			return
		var entry: Dictionary = connections[id]
		var peer: StreamPeerTCP = entry.peer
		if peer:
			peer.disconnect_from_host()
		if entry.has("server_id"):
			var sid: int = int(entry.get("server_id", -1))
			if servers.has(sid):
				var sentry: Dictionary = servers[sid]
				var peers: Array = sentry.peers
				peers.erase(id)
				_log_event(sentry, "conn_id=%d closed by tcp_close" % id)
		connections.erase(id)

	func _close_server(id: int) -> void:
		if not servers.has(id):
			return
		var entry: Dictionary = servers[id]
		var peers: Array = entry.peers
		for pid in peers.duplicate():
			_close_conn(pid)
		var server: TCPServer = entry.server
		if server:
			server.stop()
		servers.erase(id)

	func _log_event(entry: Dictionary, msg: String) -> void:
		var events: Array = entry.events
		events.append({"ts": Time.get_unix_time_from_system(), "msg": msg})
		if events.size() > _EVENT_CAP:
			events.pop_front()

#endregion

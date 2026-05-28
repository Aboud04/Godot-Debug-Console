@tool
class_name DebugConsoleWebSocketCommands extends RefCounted

# Tier 7 extension - WebSocket client commands for live debugging.
# Mirrors the SceneCommands pattern: the orchestrator instantiates one of
# these, holds a strong reference, and calls register_commands(registry, core).
#
# Connections live inside a child helper Node (_PollHelper) attached to the
# core node so WebSocketPeer instances get polled every frame inside the game
# scene tree. The RefCounted module itself is a thin facade that forwards
# command Callables to the helper.
#
# All commands are registered with the "game" context: WebSocket traffic only
# makes sense at runtime, and we avoid spinning up live sockets from the
# editor process.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_DIM := "#808080"

const _DEFAULT_RECV_COUNT := 10
const _MAX_BUFFER := 100

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
		_helper.name = "DebugConsoleWebSocketHelper"
		_core.add_child(_helper)

	_registry.register_command("ws_connect", _cmd_ws_connect, "Open a WebSocket: ws_connect <url> (returns conn_id)", "game")
	_registry.register_command("ws_send", _cmd_ws_send, "Send text on a WebSocket: ws_send <conn_id> <text>", "game")
	_registry.register_command("ws_send_json", _cmd_ws_send_json, "Send a JSON payload (validated): ws_send_json <conn_id> <json_text>", "game")
	_registry.register_command("ws_close", _cmd_ws_close, "Close a WebSocket: ws_close <conn_id|all>", "game")
	_registry.register_command("ws_list", _cmd_ws_list, "List active WebSocket connections", "game")
	_registry.register_command("ws_recv", _cmd_ws_recv, "Dump last received messages: ws_recv <conn_id> [n]", "game")
	_registry.register_command("ws_dump", _cmd_ws_dump, "Dump full state for a connection: ws_dump <conn_id>", "game")

#region Command implementations

func _cmd_ws_connect(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: ws_connect <url>")
	var helper := _require_helper()
	if not helper:
		return _format_error("WebSocket helper unavailable (editor context?)")
	var url := str(args[0]).strip_edges()
	if url.is_empty():
		return _format_error("Empty url")
	if not (url.begins_with("ws://") or url.begins_with("wss://")):
		return _format_error("Url must start with ws:// or wss:// (got %s)" % url)

	var result: Dictionary = helper.connect_url(url)
	if not bool(result.get("ok", false)):
		return _format_error(str(result.get("error", "connect failed")))
	var id: int = int(result.get("id", 0))
	return _format_success("conn_id=%s url=%s" % [_color_number(str(id)), _color_path(url)])

func _cmd_ws_send(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: ws_send <conn_id> <text>")
	var helper := _require_helper()
	if not helper:
		return _format_error("WebSocket helper unavailable")
	var id_parsed := _parse_id(str(args[0]))
	if id_parsed < 0:
		return _format_error("Invalid conn_id: %s" % str(args[0]))
	var tail: Array = args.slice(1)
	var text := " ".join(tail)
	if text.is_empty() and not piped_input.is_empty():
		text = piped_input

	var result: Dictionary = helper.send_text_msg(id_parsed, text)
	if not bool(result.get("ok", false)):
		return _format_error(str(result.get("error", "send failed")))
	return _format_success("sent %s bytes on conn %s" % [_color_number(str(text.to_utf8_buffer().size())), _color_number(str(id_parsed))])

func _cmd_ws_send_json(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: ws_send_json <conn_id> <json_text>")
	var helper := _require_helper()
	if not helper:
		return _format_error("WebSocket helper unavailable")
	var id_parsed := _parse_id(str(args[0]))
	if id_parsed < 0:
		return _format_error("Invalid conn_id: %s" % str(args[0]))
	var tail: Array = args.slice(1)
	var json_text := " ".join(tail).strip_edges()
	if json_text.is_empty() and not piped_input.is_empty():
		json_text = piped_input.strip_edges()
	if json_text.is_empty():
		return _format_error("Empty JSON payload")

	var json := JSON.new()
	var err := json.parse(json_text)
	if err != OK:
		return _format_error("Invalid JSON at line %d: %s" % [json.get_error_line(), json.get_error_message()])

	var result: Dictionary = helper.send_text_msg(id_parsed, json_text)
	if not bool(result.get("ok", false)):
		return _format_error(str(result.get("error", "send failed")))
	return _format_success("sent JSON (%s bytes) on conn %s" % [_color_number(str(json_text.to_utf8_buffer().size())), _color_number(str(id_parsed))])

func _cmd_ws_close(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: ws_close <conn_id|all>")
	var helper := _require_helper()
	if not helper:
		return _format_error("WebSocket helper unavailable")
	var target := str(args[0]).strip_edges().to_lower()

	if target == "all":
		var n: int = helper.close_all()
		return _format_success("Closed %s connections" % _color_number(str(n)))

	var id_parsed := _parse_id(target)
	if id_parsed < 0:
		return _format_error("Invalid conn_id: %s" % target)
	if not helper.close_conn(id_parsed):
		return _format_error("Unknown conn_id: %d" % id_parsed)
	return _format_success("Closed conn %s" % _color_number(str(id_parsed)))

func _cmd_ws_list(args: Array, piped_input: String = "") -> String:
	var helper := _require_helper()
	if not helper:
		return _format_error("WebSocket helper unavailable")
	var conns: Dictionary = helper.connections
	if conns.is_empty():
		return "[color=%s](no active WebSocket connections)[/color]" % _COLOR_DIM
	var ids: Array = conns.keys()
	ids.sort()
	var lines: Array[String] = []
	lines.append("%s active WebSocket connection(s)" % _color_number(str(ids.size())))
	for id in ids:
		var entry: Dictionary = conns[id]
		var peer: WebSocketPeer = entry.peer
		var state := peer.get_ready_state()
		var last_ts: float = float(entry.get("last_msg_time", 0.0))
		var last_str: String = _format_ts(last_ts) if last_ts > 0.0 else "never"
		lines.append("  %s  %s  state=%s  recv=%s  last_msg=%s  url=%s" % [
			_color_number("[" + str(id) + "]"),
			_color_path(_short_url(str(entry.get("url", "")))),
			_state_name(state),
			_color_number(str((entry.received as Array).size())),
			last_str,
			str(entry.get("url", "")),
		])
	return "\n".join(lines)

func _cmd_ws_recv(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: ws_recv <conn_id> [n]")
	var helper := _require_helper()
	if not helper:
		return _format_error("WebSocket helper unavailable")
	var id_parsed := _parse_id(str(args[0]))
	if id_parsed < 0:
		return _format_error("Invalid conn_id: %s" % str(args[0]))
	if not helper.connections.has(id_parsed):
		return _format_error("Unknown conn_id: %d" % id_parsed)

	var n: int = _DEFAULT_RECV_COUNT
	if args.size() > 1:
		var n_raw := str(args[1]).strip_edges()
		if not n_raw.is_valid_int():
			return _format_error("n must be an integer: %s" % n_raw)
		n = max(1, n_raw.to_int())

	var entry: Dictionary = helper.connections[id_parsed]
	var buf: Array = entry.received
	if buf.is_empty():
		return "[color=%s](conn %d: no messages received)[/color]" % [_COLOR_DIM, id_parsed]

	var start := max(0, buf.size() - n)
	var lines: Array[String] = []
	lines.append("conn %s: last %s of %s message(s)" % [
		_color_number(str(id_parsed)),
		_color_number(str(buf.size() - start)),
		_color_number(str(buf.size())),
	])
	for i in range(start, buf.size()):
		var msg: Dictionary = buf[i]
		var ts := float(msg.get("ts", 0.0))
		lines.append("  [%s] %s" % [_format_ts(ts), str(msg.get("text", ""))])
	return "\n".join(lines)

func _cmd_ws_dump(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: ws_dump <conn_id>")
	var helper := _require_helper()
	if not helper:
		return _format_error("WebSocket helper unavailable")
	var id_parsed := _parse_id(str(args[0]))
	if id_parsed < 0:
		return _format_error("Invalid conn_id: %s" % str(args[0]))
	if not helper.connections.has(id_parsed):
		return _format_error("Unknown conn_id: %d" % id_parsed)

	var entry: Dictionary = helper.connections[id_parsed]
	var peer: WebSocketPeer = entry.peer
	var state := peer.get_ready_state()
	var buf: Array = entry.received
	var last_ts: float = float(entry.get("last_msg_time", 0.0))
	var created_ts: float = float(entry.get("created", 0.0))

	var lines: Array[String] = []
	lines.append("conn %s dump" % _color_number(str(id_parsed)))
	lines.append("  url           = %s" % _color_path(str(entry.get("url", ""))))
	lines.append("  ready_state   = %s (%s)" % [_color_number(str(state)), _state_name(state)])
	lines.append("  received      = %s message(s) (buffer cap %s)" % [_color_number(str(buf.size())), _color_number(str(_MAX_BUFFER))])
	lines.append("  last_msg_time = %s" % (_format_ts(last_ts) if last_ts > 0.0 else "never"))
	lines.append("  created       = %s" % (_format_ts(created_ts) if created_ts > 0.0 else "?"))
	if state == WebSocketPeer.STATE_CLOSED or state == WebSocketPeer.STATE_CLOSING:
		lines.append("  close_code    = %s" % _color_number(str(peer.get_close_code())))
		lines.append("  close_reason  = %s" % str(peer.get_close_reason()))
	if peer.has_method("get_selected_protocol"):
		var proto: String = str(peer.get_selected_protocol())
		if not proto.is_empty():
			lines.append("  protocol      = %s" % proto)
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

func _state_name(state: int) -> String:
	match state:
		WebSocketPeer.STATE_CONNECTING: return "CONNECTING"
		WebSocketPeer.STATE_OPEN: return "OPEN"
		WebSocketPeer.STATE_CLOSING: return "CLOSING"
		WebSocketPeer.STATE_CLOSED: return "CLOSED"
		_: return "UNKNOWN(%d)" % state

func _short_url(url: String) -> String:
	if url.length() <= 48:
		return url
	return url.substr(0, 45) + "..."

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
# frame. Owns the connection table; the outer RefCounted module forwards calls.
class _PollHelper extends Node:
	var connections: Dictionary = {}
	var next_id: int = 1

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS

	func _process(_delta: float) -> void:
		if connections.is_empty():
			return
		for id in connections.keys():
			var entry: Dictionary = connections[id]
			var peer: WebSocketPeer = entry.peer
			if not peer:
				continue
			peer.poll()
			while peer.get_ready_state() == WebSocketPeer.STATE_OPEN and peer.get_available_packet_count() > 0:
				var pkt: PackedByteArray = peer.get_packet()
				var text: String = pkt.get_string_from_utf8()
				var now: float = Time.get_unix_time_from_system()
				var buf: Array = entry.received
				buf.append({"ts": now, "text": text})
				if buf.size() > 100:
					buf.pop_front()
				entry.last_msg_time = now

	func connect_url(url: String) -> Dictionary:
		var peer := WebSocketPeer.new()
		var err := peer.connect_to_url(url)
		if err != OK:
			return {"ok": false, "error": "connect_to_url failed (code %d)" % err}
		var id: int = next_id
		next_id += 1
		connections[id] = {
			"peer": peer,
			"url": url,
			"received": [],
			"last_msg_time": 0.0,
			"created": Time.get_unix_time_from_system(),
		}
		return {"ok": true, "id": id}

	func send_text_msg(id: int, text: String) -> Dictionary:
		if not connections.has(id):
			return {"ok": false, "error": "Unknown conn_id: %d" % id}
		var peer: WebSocketPeer = connections[id].peer
		# Poll once so the state we report matches reality if the caller is
		# sending immediately after _process ran on a different frame.
		peer.poll()
		var state := peer.get_ready_state()
		if state != WebSocketPeer.STATE_OPEN:
			return {"ok": false, "error": "Connection not open (state=%d)" % state}
		var err := peer.send_text(text)
		if err != OK:
			return {"ok": false, "error": "send_text failed (code %d)" % err}
		return {"ok": true}

	func close_conn(id: int) -> bool:
		if not connections.has(id):
			return false
		var peer: WebSocketPeer = connections[id].peer
		if peer:
			peer.close()
		connections.erase(id)
		return true

	func close_all() -> int:
		var count: int = connections.size()
		for id in connections.keys():
			var peer: WebSocketPeer = connections[id].peer
			if peer:
				peer.close()
		connections.clear()
		return count

#endregion

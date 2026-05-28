@tool
class_name DebugConsoleUdpCommands extends RefCounted

# Async UDP commands. Each `udp_listen` binds a dedicated PacketPeerUDP to a
# port and keeps it alive for the lifetime of the listener. A single hidden
# poller Node, attached under `_core` (so it shares the plugin's lifetime),
# drains incoming packets every frame and forwards them to the console via
# `_emit_result()` so they appear inline with normal command output.
#
# Async delivery mirrors HttpCommands._emit_result: try `_core.print_to_console`
# first, then `_core.info`, then the registry's `echo` command, then plain
# `print()` so headless tests still see the line.
#
# Game context only; the editor has no reason to bind sockets or fire packets
# through the live console. Registered with mode="game" so the editor surface
# never sees these commands.
#
# Payload syntax for `udp_send` and `udp_broadcast`:
#   - "hello world"   -> UTF-8 bytes
#   - "0xDEADBEEF"    -> raw hex (separators ` `, `-`, `:` are ignored)
#   - "hex:48656c6c"  -> explicit hex prefix
# `udp_send_via` always sends UTF-8 text (per spec).

const _COLOR_ERROR := "#FF4444"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_MUTED := "#888888"

const _POLLER_NAME := "_DebugConsoleUdpPoller"
const _MAX_PACKETS_PER_POLL := 64
const _MAX_PREVIEW_BYTES := 256

var _registry: Node
var _core: Node

var _next_id_counter: int = 0
# id (String "udp_N") -> {
#   peer: PacketPeerUDP, port: int, broadcast: bool,
#   packets_received: int, packets_sent: int,
#   last_packet_ts: int, last_from: String, last_size: int,
#   created_at: int
# }
var _listeners: Dictionary = {}
var _poller: Node = null

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("udp_send", _cmd_udp_send,
		"Send one UDP packet (one-shot): udp_send <host> <port> <text_or_hex>", "game")
	_registry.register_command("udp_listen", _cmd_udp_listen,
		"Bind a UDP port and log incoming packets: udp_listen <port>", "game")
	_registry.register_command("udp_send_via", _cmd_udp_send_via,
		"Reuse a bound socket to send text: udp_send_via <listener_id> <host> <port> <text>", "game")
	_registry.register_command("udp_close", _cmd_udp_close,
		"Close a listener (or all): udp_close <listener_id|all>", "game")
	_registry.register_command("udp_listeners", _cmd_udp_listeners,
		"List bound listeners with port + last-packet timestamp", "game")
	_registry.register_command("udp_broadcast", _cmd_udp_broadcast,
		"Send a broadcast packet to 255.255.255.255: udp_broadcast <port> <text>", "game")

#region Command implementations

func _cmd_udp_send(args: Array, _piped_input: String = "") -> String:
	if args.size() < 3:
		return _format_error("Usage: udp_send <host> <port> <text_or_hex>")
	var host: String = str(args[0]).strip_edges()
	var port: int = _parse_port(str(args[1]))
	if port <= 0:
		return _format_error("Invalid port: %s" % str(args[1]))
	if host.is_empty():
		return _format_error("Host cannot be empty")

	var payload_raw: String = _join_from(args, 2)
	var payload: PackedByteArray = _parse_payload(payload_raw)
	if payload.is_empty() and not payload_raw.is_empty():
		return _format_error("Could not parse payload as text or hex")

	var peer: PacketPeerUDP = PacketPeerUDP.new()
	var dest_err: int = peer.set_dest_address(host, port)
	if dest_err != OK:
		peer.close()
		return _format_error("set_dest_address(%s, %d) failed: %s" % [host, port, error_string(dest_err)])
	var send_err: int = peer.put_packet(payload)
	peer.close()
	if send_err != OK:
		return _format_error("put_packet failed: %s" % error_string(send_err))

	return _format_success("Sent %s bytes to %s" % [
		_color_number(str(payload.size())),
		_color_path("%s:%d" % [host, port]),
	])

func _cmd_udp_listen(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: udp_listen <port>")
	var port: int = _parse_port(str(args[0]))
	if port < 0 or port > 65535:
		return _format_error("Invalid port: %s" % str(args[0]))

	var peer: PacketPeerUDP = PacketPeerUDP.new()
	var bind_err: int = peer.bind(port)
	if bind_err != OK:
		peer.close()
		return _format_error("bind(%d) failed: %s" % [port, error_string(bind_err)])

	var id: String = _next_id()
	var actual_port: int = peer.get_local_port() if peer.has_method("get_local_port") else port
	_listeners[id] = {
		"peer": peer,
		"port": actual_port,
		"broadcast": false,
		"packets_received": 0,
		"packets_sent": 0,
		"last_packet_ts": 0,
		"last_from": "",
		"last_size": 0,
		"created_at": Time.get_ticks_msec(),
	}
	_ensure_poller()
	return _format_success("Listening on %s as %s" % [
		_color_path("udp/*:%d" % actual_port),
		_color_path(id),
	])

func _cmd_udp_send_via(args: Array, _piped_input: String = "") -> String:
	if args.size() < 4:
		return _format_error("Usage: udp_send_via <listener_id> <host> <port> <text>")
	var id: String = str(args[0]).strip_edges()
	if not _listeners.has(id):
		return _format_error("No such listener: %s" % id)
	var host: String = str(args[1]).strip_edges()
	var port: int = _parse_port(str(args[2]))
	if port <= 0:
		return _format_error("Invalid port: %s" % str(args[2]))
	if host.is_empty():
		return _format_error("Host cannot be empty")

	var text: String = _join_from(args, 3)
	var payload: PackedByteArray = text.to_utf8_buffer()

	var info: Dictionary = _listeners[id]
	var peer: PacketPeerUDP = info.get("peer") as PacketPeerUDP
	if not peer:
		return _format_error("Listener %s has no peer" % id)

	var dest_err: int = peer.set_dest_address(host, port)
	if dest_err != OK:
		return _format_error("set_dest_address(%s, %d) failed: %s" % [host, port, error_string(dest_err)])
	var send_err: int = peer.put_packet(payload)
	if send_err != OK:
		return _format_error("put_packet failed: %s" % error_string(send_err))

	info["packets_sent"] = int(info.get("packets_sent", 0)) + 1
	return _format_success("Sent %s bytes via %s to %s" % [
		_color_number(str(payload.size())),
		_color_path(id),
		_color_path("%s:%d" % [host, port]),
	])

func _cmd_udp_close(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: udp_close <listener_id|all>")
	var target: String = str(args[0]).strip_edges()
	if target == "all":
		var n: int = _listeners.size()
		for id in _listeners.keys():
			_close_one(id)
		_listeners.clear()
		_maybe_free_poller()
		return _format_success("Closed %s listener(s)" % _color_number(str(n)))
	if not _listeners.has(target):
		return _format_error("No such listener: %s" % target)
	_close_one(target)
	_listeners.erase(target)
	_maybe_free_poller()
	return _format_success("Closed %s" % _color_path(target))

func _cmd_udp_listeners(_args: Array, _piped_input: String = "") -> String:
	if _listeners.is_empty():
		return "[color=%s]No active UDP listeners[/color]" % _COLOR_MUTED
	var ids: Array = _listeners.keys()
	ids.sort()
	var lines: Array[String] = []
	lines.append("%s active listener(s):" % _color_number(str(_listeners.size())))
	var now_ms: int = Time.get_ticks_msec()
	for id in ids:
		var info: Dictionary = _listeners[id]
		var port: int = int(info.get("port", 0))
		var rx: int = int(info.get("packets_received", 0))
		var tx: int = int(info.get("packets_sent", 0))
		var last_ts: int = int(info.get("last_packet_ts", 0))
		var last_from: String = str(info.get("last_from", ""))
		var last_str: String = "never"
		if last_ts > 0:
			var ago_ms: int = now_ms - last_ts
			last_str = "%s ago" % _format_duration_ms(ago_ms)
			if not last_from.is_empty():
				last_str += " from %s" % last_from
		lines.append("  %s  port=%s  rx=%s  tx=%s  last=%s" % [
			_color_path(id),
			_color_number(str(port)),
			_color_number(str(rx)),
			_color_number(str(tx)),
			last_str,
		])
	return "\n".join(lines)

func _cmd_udp_broadcast(args: Array, _piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: udp_broadcast <port> <text>")
	var port: int = _parse_port(str(args[0]))
	if port <= 0:
		return _format_error("Invalid port: %s" % str(args[0]))
	var text: String = _join_from(args, 1)
	var payload: PackedByteArray = text.to_utf8_buffer()

	var peer: PacketPeerUDP = PacketPeerUDP.new()
	# Binding to port 0 picks an ephemeral local port; without a bound socket
	# many OSes silently drop broadcast packets.
	var bind_err: int = peer.bind(0)
	if bind_err != OK:
		peer.close()
		return _format_error("bind(0) failed: %s" % error_string(bind_err))
	peer.set_broadcast_enabled(true)
	var dest_err: int = peer.set_dest_address("255.255.255.255", port)
	if dest_err != OK:
		peer.close()
		return _format_error("set_dest_address(255.255.255.255, %d) failed: %s" % [port, error_string(dest_err)])
	var send_err: int = peer.put_packet(payload)
	peer.close()
	if send_err != OK:
		return _format_error("put_packet failed: %s" % error_string(send_err))

	return _format_success("Broadcast %s bytes to %s" % [
		_color_number(str(payload.size())),
		_color_path("255.255.255.255:%d" % port),
	])

#endregion

#region Polling

func _poll_all() -> void:
	if _listeners.is_empty():
		return
	for id in _listeners.keys():
		var info: Dictionary = _listeners[id]
		var peer: PacketPeerUDP = info.get("peer") as PacketPeerUDP
		if not peer:
			continue
		var drained: int = 0
		while peer.get_available_packet_count() > 0 and drained < _MAX_PACKETS_PER_POLL:
			var bytes: PackedByteArray = peer.get_packet()
			var src_ip: String = peer.get_packet_ip()
			var src_port: int = peer.get_packet_port()
			var src: String = "%s:%d" % [src_ip, src_port]
			info["packets_received"] = int(info.get("packets_received", 0)) + 1
			info["last_packet_ts"] = Time.get_ticks_msec()
			info["last_from"] = src
			info["last_size"] = bytes.size()
			var preview: String = _preview_bytes(bytes)
			_emit_result("[color=%s]udp[%s]<- %s (%s bytes)[/color] %s" % [
				_COLOR_PATH, id, src, str(bytes.size()), preview,
			])
			drained += 1

#endregion

#region Poller node management

class _UdpPoller extends Node:
	var poll_cb: Callable
	func _process(_delta: float) -> void:
		if poll_cb.is_valid():
			poll_cb.call()

func _ensure_poller() -> void:
	if is_instance_valid(_poller) and _poller.is_inside_tree():
		return
	var parent: Node = _resolve_poller_parent()
	if not parent:
		return
	if is_instance_valid(_poller):
		_poller.queue_free()
	var node: Node = _UdpPoller.new()
	node.name = _POLLER_NAME
	node.set("poll_cb", Callable(self, "_poll_all"))
	parent.add_child(node)
	_poller = node

func _maybe_free_poller() -> void:
	if not _listeners.is_empty():
		return
	if is_instance_valid(_poller):
		_poller.queue_free()
	_poller = null

func _resolve_poller_parent() -> Node:
	if _core and is_instance_valid(_core) and _core.is_inside_tree():
		return _core
	var loop: MainLoop = Engine.get_main_loop()
	if loop is SceneTree:
		return (loop as SceneTree).root
	return null

func _close_one(id: String) -> void:
	if not _listeners.has(id):
		return
	var info: Dictionary = _listeners[id]
	var peer: PacketPeerUDP = info.get("peer") as PacketPeerUDP
	if peer:
		peer.close()

#endregion

#region Async delivery (mirrors HttpCommands._emit_result)

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

func _next_id() -> String:
	_next_id_counter += 1
	return "udp_%d" % _next_id_counter

func _parse_port(raw: String) -> int:
	var s: String = raw.strip_edges()
	if not s.is_valid_int():
		return -1
	var v: int = s.to_int()
	if v < 0 or v > 65535:
		return -1
	return v

func _join_from(args: Array, start_idx: int) -> String:
	var parts: Array[String] = []
	for i in range(start_idx, args.size()):
		parts.append(str(args[i]))
	return " ".join(parts)

func _parse_payload(raw: String) -> PackedByteArray:
	var s: String = raw
	if s.begins_with("0x") or s.begins_with("0X"):
		return _hex_to_bytes(s.substr(2))
	if s.begins_with("hex:") or s.begins_with("HEX:"):
		return _hex_to_bytes(s.substr(4))
	return s.to_utf8_buffer()

func _hex_to_bytes(hex_in: String) -> PackedByteArray:
	var cleaned: String = hex_in.replace(" ", "").replace(":", "").replace("-", "").replace("_", "")
	var out: PackedByteArray = PackedByteArray()
	if cleaned.is_empty() or cleaned.length() % 2 != 0:
		return out
	for i in range(0, cleaned.length(), 2):
		var pair: String = cleaned.substr(i, 2)
		if not _is_hex_pair(pair):
			return PackedByteArray()
		out.append(("0x" + pair).hex_to_int())
	return out

func _is_hex_pair(pair: String) -> bool:
	if pair.length() != 2:
		return false
	for c in pair:
		var lo: String = c.to_lower()
		var is_digit: bool = lo >= "0" and lo <= "9"
		var is_alpha: bool = lo >= "a" and lo <= "f"
		if not (is_digit or is_alpha):
			return false
	return true

func _preview_bytes(bytes: PackedByteArray) -> String:
	if bytes.is_empty():
		return "[color=%s]<empty>[/color]" % _COLOR_MUTED
	var slice: PackedByteArray = bytes
	var truncated: bool = false
	if bytes.size() > _MAX_PREVIEW_BYTES:
		slice = bytes.slice(0, _MAX_PREVIEW_BYTES)
		truncated = true
	var text: String = slice.get_string_from_utf8()
	if text.is_empty() or _has_unprintable(text):
		var hex_parts: Array[String] = []
		for b in slice:
			hex_parts.append("%02x" % int(b))
		text = "0x" + "".join(hex_parts)
	if truncated:
		text += "[color=%s]...(+%d bytes)[/color]" % [_COLOR_MUTED, bytes.size() - _MAX_PREVIEW_BYTES]
	return text

func _has_unprintable(text: String) -> bool:
	for i in text.length():
		var cp: int = text.unicode_at(i)
		if cp == 9 or cp == 10 or cp == 13:
			continue
		if cp < 32 or cp == 127:
			return true
	return false

func _format_duration_ms(ms: int) -> String:
	if ms < 1000:
		return "%dms" % ms
	var secs: float = float(ms) / 1000.0
	if secs < 60.0:
		return "%.1fs" % secs
	var mins: float = secs / 60.0
	if mins < 60.0:
		return "%.1fm" % mins
	return "%.1fh" % (mins / 60.0)

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

#endregion

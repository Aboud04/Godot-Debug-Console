@tool
class_name DebugConsoleNetworkPerfCommands extends RefCounted

# Tier 7 - multiplayer / network performance commands. Mirrors the structure
# of core/SceneCommands.gd: BuiltInCommands instantiates this class, holds a
# strong reference to it, and calls register_commands(registry, core). All
# state (RTT cache, sampled counters, alarm thresholds) lives on this
# RefCounted; a lazy helper Node lives under /root to host RPC endpoints
# and the per-frame sampler/alarm tick so commands survive scene changes.
#
# Commands are registered with the "game" context because they query the
# live SceneTree multiplayer peer and Performance monitors at runtime.

const _COLOR_ERROR := "#FF4444"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_WARN := "#FFB347"

const _HELPER_NAME := "__DebugConsoleNetPerf__"
const _PING_METHOD := "_dbg_net_ping"
const _PONG_METHOD := "_dbg_net_pong"
const _SAMPLE_WINDOW := 60
const _SAMPLE_INTERVAL_MS := 250
const _PING_TIMEOUT_MS := 5000
const _ALARM_COOLDOWN_MS := 2000

# Logical metric name -> Performance enum constant name (varies across Godot
# builds; we resolve via ClassDB so missing constants degrade gracefully).
const _NETWORK_METRICS := {
	"rpcs_out": "NETWORK_RPCS_OUT_PER_SECOND",
	"rpcs_in": "NETWORK_RPCS_IN_PER_SECOND",
	"bytes_out": "NETWORK_BYTES_OUT_PER_SECOND",
	"bytes_in": "NETWORK_BYTES_IN_PER_SECOND",
}

var _registry: Node
var _core: Node

var _rtt_cache: Dictionary = {}
var _pending_pings: Dictionary = {}
var _ping_seq: int = 0

var _samples: Dictionary = {}
var _last_sample_ms: int = 0

var _alarms: Dictionary = {}

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("net_perf", _cmd_net_perf,
		"Report network performance counters (RPCs/s, Bytes/s) or fall back to peer connection status: net_perf", "game")
	_registry.register_command("net_peers", _cmd_net_peers,
		"List MultiplayerPeer connected peer IDs: net_peers", "game")
	_registry.register_command("net_latency", _cmd_net_latency,
		"Measure RTT to a peer via custom ping RPC (omit id to list cached RTTs): net_latency [peer_id]", "game")
	_registry.register_command("net_packet_loss", _cmd_net_packet_loss,
		"Heuristic packet-loss estimate from RPC out/in counter ratios over the sample window: net_packet_loss", "game")
	_registry.register_command("net_alarm", _cmd_net_alarm,
		"Warn when a network metric exceeds threshold (metric: rpcs_out|rpcs_in|bytes_out|bytes_in or 'clear'): net_alarm <metric> <threshold>", "game")

#region Command implementations

func _cmd_net_perf(_args: Array, _piped_input: String = "") -> String:
	if Engine.is_editor_hint():
		return _format_error("net_perf requires a running game context")
	var multiplayer := _get_multiplayer()
	if not multiplayer:
		return _format_error("No MultiplayerAPI available")
	_ensure_helper()
	var lines: PackedStringArray = PackedStringArray()
	var any_metric: bool = false
	for key in _NETWORK_METRICS.keys():
		var id := _resolve_metric_id(String(_NETWORK_METRICS[key]))
		if id < 0:
			continue
		any_metric = true
		var value: float = float(Performance.get_monitor(id))
		lines.append("  %s: %s" % [_metric_label(key), _format_metric_value(key, value)])
	if not any_metric:
		lines.append("  %s" % _color_path("Performance.NETWORK_* monitors unavailable on this build"))
	var peer := multiplayer.multiplayer_peer
	if peer:
		var status := peer.get_connection_status()
		lines.append("  Connection: %s" % _connection_status_label(status))
		lines.append("  Unique ID: %s" % _color_number(str(multiplayer.get_unique_id())))
		lines.append("  Peers: %s" % _color_number(str(_peer_ids(multiplayer).size())))
	else:
		lines.append("  Connection: %s" % _color_path("no multiplayer_peer"))
	return "[color=%s]Network performance:[/color]\n%s" % [_COLOR_SUCCESS, "\n".join(lines)]

func _cmd_net_peers(_args: Array, _piped_input: String = "") -> String:
	if Engine.is_editor_hint():
		return _format_error("net_peers requires a running game context")
	var multiplayer := _get_multiplayer()
	if not multiplayer:
		return _format_error("No MultiplayerAPI available")
	var peer := multiplayer.multiplayer_peer
	if not peer:
		return _format_error("No multiplayer_peer assigned")
	var ids: PackedInt32Array = _peer_ids(multiplayer)
	if ids.is_empty():
		return _format_success("No connected peers (unique_id=%s)" % str(multiplayer.get_unique_id()))
	var lines: PackedStringArray = PackedStringArray()
	for id in ids:
		lines.append("  %s" % _color_number(str(id)))
	return "[color=%s]Connected peers (%d):[/color]\n%s" % [_COLOR_SUCCESS, ids.size(), "\n".join(lines)]

func _cmd_net_latency(args: Array, _piped_input: String = "") -> String:
	if Engine.is_editor_hint():
		return _format_error("net_latency requires a running game context")
	var multiplayer := _get_multiplayer()
	if not multiplayer or not multiplayer.multiplayer_peer:
		return _format_error("No active multiplayer_peer")
	_prune_pings()
	if args.is_empty():
		if _rtt_cache.is_empty():
			return _format_success("No RTT samples cached. Usage: net_latency <peer_id>")
		var lines: PackedStringArray = PackedStringArray()
		for peer_id in _rtt_cache.keys():
			var entry: Dictionary = _rtt_cache[peer_id]
			var age_ms: int = Time.get_ticks_msec() - int(entry.get("ts", 0))
			lines.append("  peer %s: %s ms (age %s ms)" % [
				_color_number(str(peer_id)),
				_color_number("%.2f" % float(entry.get("rtt_ms", 0.0))),
				_color_number(str(age_ms)),
			])
		return "[color=%s]Cached RTTs:[/color]\n%s" % [_COLOR_SUCCESS, "\n".join(lines)]

	var raw := str(args[0]).strip_edges()
	if not raw.is_valid_int():
		return _format_error("peer_id must be an integer: %s" % raw)
	var peer_id: int = raw.to_int()
	if peer_id == multiplayer.get_unique_id():
		return _format_error("Cannot ping self (id %d)" % peer_id)
	if not _peer_ids(multiplayer).has(peer_id):
		var engine_ping := _try_engine_ping(multiplayer, peer_id)
		if engine_ping >= 0.0:
			return _format_success("Engine-reported ping to peer %s: %s ms" % [
				_color_number(str(peer_id)),
				_color_number("%.2f" % engine_ping),
			])
		return _format_error("Peer %d not connected" % peer_id)

	var helper := _ensure_helper()
	if not helper:
		return _format_error("Failed to create network helper node")
	_ping_seq += 1
	var req_id := _ping_seq
	var send_ts := Time.get_ticks_usec()
	_pending_pings[req_id] = {"peer": peer_id, "ts": send_ts}
	var err: int = helper.rpc_id(peer_id, _PING_METHOD, req_id, send_ts)
	if err != OK:
		_pending_pings.erase(req_id)
		var engine_ping_fallback := _try_engine_ping(multiplayer, peer_id)
		if engine_ping_fallback >= 0.0:
			return _format_success("Engine-reported ping to peer %s: %s ms (rpc unavailable, err=%d)" % [
				_color_number(str(peer_id)),
				_color_number("%.2f" % engine_ping_fallback),
				err,
			])
		return _format_error("Failed to send ping RPC (err=%d). Is %s present on the remote?" % [err, _HELPER_NAME])
	return _format_success("Ping req=%s sent to peer %s. Run %s to view RTT once pong returns." % [
		_color_number(str(req_id)),
		_color_number(str(peer_id)),
		_color_path("net_latency"),
	])

func _cmd_net_packet_loss(_args: Array, _piped_input: String = "") -> String:
	if Engine.is_editor_hint():
		return _format_error("net_packet_loss requires a running game context")
	var multiplayer := _get_multiplayer()
	if not multiplayer or not multiplayer.multiplayer_peer:
		return _format_error("No active multiplayer_peer")
	_ensure_helper()
	var out_id := _resolve_metric_id(String(_NETWORK_METRICS["rpcs_out"]))
	var in_id := _resolve_metric_id(String(_NETWORK_METRICS["rpcs_in"]))
	if out_id < 0 or in_id < 0:
		return _format_error("Performance.NETWORK_RPCS_*_PER_SECOND monitors unavailable on this build")
	var out_samples: Array = _samples.get("rpcs_out", [])
	var in_samples: Array = _samples.get("rpcs_in", [])
	if out_samples.size() < 2:
		return _format_success("Collecting samples (%d/%d). Re-run after a moment." % [out_samples.size(), _SAMPLE_WINDOW])
	var out_sum: float = 0.0
	var in_sum: float = 0.0
	for v in out_samples:
		out_sum += float(v)
	for v in in_samples:
		in_sum += float(v)
	var loss_pct: float = 0.0
	if out_sum > 0.0:
		loss_pct = clampf((out_sum - in_sum) / out_sum, 0.0, 1.0) * 100.0
	var lines: PackedStringArray = PackedStringArray()
	lines.append("  Window: %s samples (%s ms each)" % [
		_color_number(str(out_samples.size())),
		_color_number(str(_SAMPLE_INTERVAL_MS)),
	])
	lines.append("  RPCs out (avg/s): %s" % _color_number("%.2f" % (out_sum / float(out_samples.size()))))
	lines.append("  RPCs in  (avg/s): %s" % _color_number("%.2f" % (in_sum / float(max(in_samples.size(), 1)))))
	lines.append("  Heuristic loss: %s" % _color_number("%.1f%%" % loss_pct))
	lines.append("  [color=%s]Note:[/color] derived from local out/in counter ratios; not a true per-peer loss." % _COLOR_WARN)
	return "[color=%s]Packet loss estimate:[/color]\n%s" % [_COLOR_SUCCESS, "\n".join(lines)]

func _cmd_net_alarm(args: Array, _piped_input: String = "") -> String:
	if Engine.is_editor_hint():
		return _format_error("net_alarm requires a running game context")
	if args.is_empty():
		if _alarms.is_empty():
			return _format_success("No alarms configured. Usage: net_alarm <metric> <threshold>")
		var lines: PackedStringArray = PackedStringArray()
		for metric in _alarms.keys():
			var entry: Dictionary = _alarms[metric]
			lines.append("  %s > %s" % [
				_color_path(String(metric)),
				_color_number("%.2f" % float(entry.get("threshold", 0.0))),
			])
		return "[color=%s]Active alarms:[/color]\n%s" % [_COLOR_SUCCESS, "\n".join(lines)]

	var metric := str(args[0]).strip_edges().to_lower()
	if metric == "clear":
		var removed: int = _alarms.size()
		_alarms.clear()
		return _format_success("Cleared %s alarm(s)" % _color_number(str(removed)))
	if not _NETWORK_METRICS.has(metric):
		return _format_error("Unknown metric: %s (known: %s)" % [metric, ", ".join(_NETWORK_METRICS.keys())])
	if args.size() < 2:
		return _format_error("Usage: net_alarm <metric> <threshold>")
	var threshold_raw := str(args[1]).strip_edges()
	if not (threshold_raw.is_valid_float() or threshold_raw.is_valid_int()):
		return _format_error("threshold must be numeric: %s" % threshold_raw)
	var threshold: float = threshold_raw.to_float()
	if _resolve_metric_id(String(_NETWORK_METRICS[metric])) < 0:
		return _format_error("Metric %s not available on this Godot build" % metric)
	_alarms[metric] = {"threshold": threshold, "last_warn": 0}
	_ensure_helper()
	return _format_success("Alarm set: %s > %s" % [
		_color_path(metric),
		_color_number("%.2f" % threshold),
	])

#endregion

#region Helper node lifecycle

func _ensure_helper() -> Node:
	var existing := _find_helper()
	if existing:
		return existing
	var tree := Engine.get_main_loop() as SceneTree
	if not tree or not tree.root:
		return null
	var helper := Node.new()
	helper.name = _HELPER_NAME
	var helper_script := GDScript.new()
	helper_script.source_code = _helper_source()
	helper_script.reload()
	helper.set_script(helper_script)
	helper.set("owner_ref", weakref(self))
	tree.root.add_child(helper)
	return helper

func _find_helper() -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if not tree or not tree.root:
		return null
	return tree.root.get_node_or_null(_HELPER_NAME)

func _helper_source() -> String:
	return "extends Node\n" \
		+ "var owner_ref: WeakRef\n" \
		+ "var _last_sample_ms: int = 0\n" \
		+ "func _ready() -> void:\n" \
		+ "\tvar cfg := {\n" \
		+ "\t\t\"rpc_mode\": MultiplayerAPI.RPC_MODE_ANY_PEER,\n" \
		+ "\t\t\"transfer_mode\": MultiplayerPeer.TRANSFER_MODE_RELIABLE,\n" \
		+ "\t\t\"call_local\": false,\n" \
		+ "\t\t\"channel\": 0,\n" \
		+ "\t}\n" \
		+ "\trpc_config(\"%s\", cfg)\n" % _PING_METHOD \
		+ "\trpc_config(\"%s\", cfg)\n" % _PONG_METHOD \
		+ "func %s(req_id: int, sender_ts: int) -> void:\n" % _PING_METHOD \
		+ "\tvar sender: int = multiplayer.get_remote_sender_id()\n" \
		+ "\tif sender == 0:\n" \
		+ "\t\treturn\n" \
		+ "\trpc_id(sender, \"%s\", req_id, sender_ts)\n" % _PONG_METHOD \
		+ "func %s(req_id: int, sender_ts: int) -> void:\n" % _PONG_METHOD \
		+ "\tvar owner = owner_ref.get_ref() if owner_ref else null\n" \
		+ "\tif owner == null:\n" \
		+ "\t\treturn\n" \
		+ "\tvar sender: int = multiplayer.get_remote_sender_id()\n" \
		+ "\towner._on_pong_received(sender, req_id, sender_ts)\n" \
		+ "func _process(_delta: float) -> void:\n" \
		+ "\tvar owner = owner_ref.get_ref() if owner_ref else null\n" \
		+ "\tif owner == null:\n" \
		+ "\t\treturn\n" \
		+ "\towner._tick()\n"

func _on_pong_received(peer_id: int, req_id: int, sender_ts: int) -> void:
	var pending: Dictionary = _pending_pings.get(req_id, {})
	_pending_pings.erase(req_id)
	var send_ts: int = int(pending.get("ts", sender_ts))
	var rtt_us: int = Time.get_ticks_usec() - send_ts
	var rtt_ms: float = float(rtt_us) / 1000.0
	_rtt_cache[peer_id] = {"rtt_ms": rtt_ms, "ts": Time.get_ticks_msec()}

func _tick() -> void:
	var now: int = Time.get_ticks_msec()
	if now - _last_sample_ms >= _SAMPLE_INTERVAL_MS:
		_last_sample_ms = now
		_sample_metrics()
		_check_alarms(now)

func _sample_metrics() -> void:
	for key in _NETWORK_METRICS.keys():
		var id := _resolve_metric_id(String(_NETWORK_METRICS[key]))
		if id < 0:
			continue
		var value: float = float(Performance.get_monitor(id))
		var arr: Array = _samples.get(key, [])
		arr.append(value)
		while arr.size() > _SAMPLE_WINDOW:
			arr.remove_at(0)
		_samples[key] = arr

func _check_alarms(now: int) -> void:
	for metric in _alarms.keys():
		var entry: Dictionary = _alarms[metric]
		var id := _resolve_metric_id(String(_NETWORK_METRICS.get(metric, "")))
		if id < 0:
			continue
		var value: float = float(Performance.get_monitor(id))
		var threshold: float = float(entry.get("threshold", 0.0))
		if value <= threshold:
			continue
		var last_warn: int = int(entry.get("last_warn", 0))
		if now - last_warn < _ALARM_COOLDOWN_MS:
			continue
		entry["last_warn"] = now
		_alarms[metric] = entry
		var msg := "net_alarm: %s = %.2f exceeds threshold %.2f" % [metric, value, threshold]
		push_warning(msg)
		printerr(msg)

func _prune_pings() -> void:
	var now_us: int = Time.get_ticks_usec()
	var stale: Array = []
	for req_id in _pending_pings.keys():
		var entry: Dictionary = _pending_pings[req_id]
		var ts: int = int(entry.get("ts", 0))
		if now_us - ts > _PING_TIMEOUT_MS * 1000:
			stale.append(req_id)
	for req_id in stale:
		_pending_pings.erase(req_id)

#endregion

#region Multiplayer + Performance helpers

func _get_multiplayer() -> MultiplayerAPI:
	var tree := Engine.get_main_loop() as SceneTree
	if not tree:
		return null
	return tree.get_multiplayer()

func _peer_ids(multiplayer: MultiplayerAPI) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	if not multiplayer or not multiplayer.multiplayer_peer:
		return out
	var peer := multiplayer.multiplayer_peer
	if peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return out
	for id in multiplayer.get_peers():
		out.append(int(id))
	return out

func _try_engine_ping(multiplayer: MultiplayerAPI, peer_id: int) -> float:
	var peer := multiplayer.multiplayer_peer
	if not peer:
		return -1.0
	if peer.has_method("get_peer"):
		var p: Variant = peer.call("get_peer", peer_id)
		if p != null and typeof(p) == TYPE_OBJECT:
			var obj: Object = p
			if obj.has_method("get_statistic"):
				var enet_round_trip_time: int = 6
				var v: Variant = obj.call("get_statistic", enet_round_trip_time)
				if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
					return float(v)
	return -1.0

func _resolve_metric_id(constant_name: String) -> int:
	if constant_name.is_empty():
		return -1
	var consts: PackedStringArray = ClassDB.class_get_integer_constant_list("Performance")
	for c in consts:
		if String(c) == constant_name:
			return ClassDB.class_get_integer_constant("Performance", constant_name)
	return -1

func _metric_label(key: String) -> String:
	match key:
		"rpcs_out": return "RPCs out/s"
		"rpcs_in": return "RPCs in/s"
		"bytes_out": return "Bytes out/s"
		"bytes_in": return "Bytes in/s"
		_: return key

func _format_metric_value(key: String, value: float) -> String:
	if key.begins_with("bytes"):
		return _color_number(_format_bytes_per_sec(value))
	if value == floor(value):
		return _color_number("%d" % int(value))
	return _color_number("%.2f" % value)

func _format_bytes_per_sec(bytes: float) -> String:
	if bytes < 1024.0:
		return "%.0f B/s" % bytes
	var kb: float = bytes / 1024.0
	if kb < 1024.0:
		return "%.2f KB/s" % kb
	var mb: float = kb / 1024.0
	return "%.2f MB/s" % mb

func _connection_status_label(status: int) -> String:
	match status:
		MultiplayerPeer.CONNECTION_DISCONNECTED: return _color_path("disconnected")
		MultiplayerPeer.CONNECTION_CONNECTING: return _color_path("connecting")
		MultiplayerPeer.CONNECTION_CONNECTED: return _color_path("connected")
		_: return _color_path("unknown(%d)" % status)

#endregion

#region Formatting helpers

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

#endregion

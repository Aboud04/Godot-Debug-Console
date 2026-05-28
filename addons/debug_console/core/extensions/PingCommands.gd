@tool
class_name DebugConsolePingCommands extends RefCounted

# HTTP HEAD-based "ping" commands. Godot has no native ICMP, so we approximate
# round-trip time by firing an HTTPRequest with METHOD_HEAD and measuring the
# wall-clock between request() and request_completed. The HEAD verb keeps the
# response body empty so timing is dominated by network + server handshake,
# which is the metric users actually want when they type "ping".
#
# Per-request plumbing mirrors HttpCommands: each ping owns a dedicated
# HTTPRequest under /root, lives in `_active` until it finishes, and the
# async result is pushed through `_emit_result` (print_to_console -> info ->
# echo -> print) so output reaches the console regardless of which Core API
# version is installed.
#
# Higher-level commands (ping_loop, ping_table) are built on top of the same
# single-shot dispatch and tracked under "session" dictionaries so they can
# be cancelled cleanly by `ping_cancel`.
#
# Game context only; the editor has no business holding network sockets open
# from the live console.

const _COLOR_ERROR := "#FF4444"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_MUTED := "#888888"

const _HISTORY_PER_HOST_LIMIT := 50
const _TABLE_DEFAULT_TIMEOUT_SECS := 10.0
const _LOOP_DEFAULT_INTERVAL := 1.0
const _LOOP_DEFAULT_COUNT := 4
const _HISTORY_DEFAULT_TAIL := 10

var _registry: Node
var _core: Node

var _next_id_counter: int = 0
# request_id -> { node, host, url, started_at, kind, session_id }
var _active: Dictionary = {}
# host -> Array of completed result dicts (capped at _HISTORY_PER_HOST_LIMIT)
var _history: Dictionary = {}
# loop_session_id -> { host, interval, remaining, total, cancelled, results }
var _loops: Dictionary = {}
# table_session_id -> { hosts, pending, results, started_at, cancelled }
var _tables: Dictionary = {}

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("ping", _cmd_ping, "HTTP HEAD ping (round-trip ms): ping <host>", "game")
	_registry.register_command("ping_loop", _cmd_ping_loop, "Repeat pings: ping_loop <host> [interval_secs=1.0] [count=4]", "game")
	_registry.register_command("ping_table", _cmd_ping_table, "Parallel ping multiple hosts and render a table: ping_table <host_a> <host_b> ...", "game")
	_registry.register_command("ping_history", _cmd_ping_history, "Show recent ping results: ping_history [host] [tail=10]", "game")
	_registry.register_command("ping_cancel", _cmd_ping_cancel, "Cancel in-flight pings: ping_cancel <host|all>", "game")

#region Command implementations

func _cmd_ping(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: ping <host>")
	var host: String = str(args[0]).strip_edges()
	var id: String = _dispatch_single(host, "single", "")
	if id.is_empty():
		return _format_error("Failed to start ping for %s" % host)
	return _format_success("ping %s queued as %s" % [host, _color_path(id)])

func _cmd_ping_loop(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: ping_loop <host> [interval_secs=1.0] [count=4]")
	var host: String = str(args[0]).strip_edges()
	var interval: float = _LOOP_DEFAULT_INTERVAL
	var count: int = _LOOP_DEFAULT_COUNT
	if args.size() > 1:
		var raw_interval: String = str(args[1]).strip_edges()
		if raw_interval.is_valid_float() or raw_interval.is_valid_int():
			interval = max(0.05, raw_interval.to_float())
	if args.size() > 2:
		var raw_count: String = str(args[2]).strip_edges()
		if raw_count.is_valid_int():
			count = max(1, raw_count.to_int())
	var session_id: String = _next_loop_id()
	_loops[session_id] = {
		"host": host,
		"interval": interval,
		"remaining": count,
		"total": count,
		"cancelled": false,
		"results": [],
	}
	# Fire the first ping immediately; subsequent ones are scheduled after each completion.
	var loop_data: Dictionary = _loops[session_id]
	loop_data["remaining"] = int(loop_data["remaining"]) - 1
	var req_id: String = _dispatch_single(host, "loop", session_id)
	if req_id.is_empty():
		_loops.erase(session_id)
		return _format_error("Failed to start ping_loop for %s" % host)
	return _format_success("ping_loop %s x%s (every %ss) -> %s" % [
		host,
		_color_number(str(count)),
		_color_number(str(interval)),
		_color_path(session_id),
	])

func _cmd_ping_table(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: ping_table <host_a> <host_b> ...")
	var hosts: Array[String] = []
	for raw in args:
		var h: String = str(raw).strip_edges()
		if not h.is_empty():
			hosts.append(h)
	if hosts.is_empty():
		return _format_error("No hosts supplied.")
	var session_id: String = _next_table_id()
	var pending: Dictionary = {}
	for h in hosts:
		pending[h] = true
	_tables[session_id] = {
		"hosts": hosts.duplicate(),
		"pending": pending,
		"results": {},
		"started_at": Time.get_ticks_msec(),
		"cancelled": false,
	}
	var started: int = 0
	for h in hosts:
		var req_id: String = _dispatch_single(h, "table", session_id)
		if not req_id.is_empty():
			started += 1
		else:
			# Record an immediate failure entry so the table still reconciles.
			_record_table_result(session_id, h, {
				"host": h, "url": h, "rtt_ms": -1, "status": 0,
				"error": "dispatch_failed", "completed_at": Time.get_ticks_msec(),
			})
	# Safety net: if a host never reports back (e.g., DNS hung past Godot's
	# internal timeout), flush the table after a generous wait so the user
	# always sees output.
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree:
		tree.create_timer(_TABLE_DEFAULT_TIMEOUT_SECS).timeout.connect(
			_on_table_timeout.bind(session_id)
		)
	return _format_success("ping_table %s host(s) -> %s" % [
		_color_number(str(started)),
		_color_path(session_id),
	])

func _cmd_ping_history(args: Array, piped_input: String = "") -> String:
	var host_filter: String = ""
	var tail: int = _HISTORY_DEFAULT_TAIL
	if args.size() > 0:
		host_filter = str(args[0]).strip_edges()
	if args.size() > 1:
		var raw_tail: String = str(args[1]).strip_edges()
		if raw_tail.is_valid_int():
			tail = max(1, raw_tail.to_int())
	if _history.is_empty():
		return _format_muted("No ping history yet.")
	var hosts: Array = []
	if host_filter.is_empty():
		hosts = _history.keys()
		hosts.sort()
	else:
		if not _history.has(host_filter):
			return _format_muted("No history for host: %s" % host_filter)
		hosts = [host_filter]
	var lines: Array[String] = []
	lines.append("Ping history (last %s per host):" % _color_number(str(tail)))
	for h in hosts:
		var entries: Array = _history.get(h, [])
		lines.append("%s  (%s recorded)" % [_color_path(str(h)), _color_number(str(entries.size()))])
		var start: int = max(0, entries.size() - tail)
		for i in range(start, entries.size()):
			var e: Dictionary = entries[i]
			lines.append("  %s  %s  %s%s" % [
				_format_rtt(int(e.get("rtt_ms", -1))),
				_status_color(int(e.get("status", 0))),
				str(e.get("url", h)),
				(" (%s)" % str(e.get("error", ""))) if str(e.get("error", "")) != "" else "",
			])
	return "\n".join(lines)

func _cmd_ping_cancel(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: ping_cancel <host|all>")
	var target: String = str(args[0]).strip_edges()
	var cancel_all: bool = target == "all"
	var cancelled_reqs: int = 0
	var cancelled_loops: int = 0
	var cancelled_tables: int = 0
	# Cancel in-flight single requests.
	var ids: Array = _active.keys().duplicate()
	for id in ids:
		var info: Dictionary = _active.get(id, {})
		var host: String = str(info.get("host", ""))
		if cancel_all or host == target:
			_cancel_one(str(id), "cancelled" if cancel_all else "cancelled (%s)" % target)
			cancelled_reqs += 1
	# Mark matching loop sessions as cancelled so the next scheduled tick stops.
	for sid in _loops.keys().duplicate():
		var loop_data: Dictionary = _loops[sid]
		if cancel_all or str(loop_data.get("host", "")) == target:
			loop_data["cancelled"] = true
			loop_data["remaining"] = 0
			cancelled_loops += 1
	# Mark matching table sessions as cancelled and flush them.
	for sid in _tables.keys().duplicate():
		var table_data: Dictionary = _tables[sid]
		var hosts: Array = table_data.get("hosts", [])
		if cancel_all or (target in hosts):
			table_data["cancelled"] = true
			cancelled_tables += 1
			_flush_table(str(sid), "cancelled")
	if cancelled_reqs == 0 and cancelled_loops == 0 and cancelled_tables == 0:
		return _format_muted("Nothing to cancel for: %s" % target)
	return _format_success("Cancelled %s request(s), %s loop(s), %s table(s)." % [
		_color_number(str(cancelled_reqs)),
		_color_number(str(cancelled_loops)),
		_color_number(str(cancelled_tables)),
	])

#endregion

#region Async plumbing

func _dispatch_single(host: String, kind: String, session_id: String) -> String:
	if host.is_empty():
		return ""
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if not tree or not tree.root:
		return ""
	var url: String = _normalize_url(host)
	var id: String = _next_req_id()
	var http: HTTPRequest = HTTPRequest.new()
	http.name = "DebugConsolePing_%s" % id
	tree.root.add_child(http)
	_active[id] = {
		"node": http,
		"host": host,
		"url": url,
		"started_at": Time.get_ticks_msec(),
		"kind": kind,
		"session_id": session_id,
	}
	http.request_completed.connect(_on_request_completed.bind(id))
	var err: int = http.request(url, PackedStringArray(), HTTPClient.METHOD_HEAD, "")
	if err != OK:
		_active.erase(id)
		if is_instance_valid(http):
			http.queue_free()
		var entry: Dictionary = {
			"host": host, "url": url, "rtt_ms": -1, "status": 0,
			"error": "request() err=%d" % err, "completed_at": Time.get_ticks_msec(),
		}
		_record_history(host, entry)
		_finalize_kind(kind, session_id, host, entry)
		return ""
	return id

func _on_request_completed(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray, id: String) -> void:
	if not _active.has(id):
		return
	var info: Dictionary = _active[id]
	var http: HTTPRequest = info.get("node") as HTTPRequest
	var host: String = str(info.get("host", ""))
	var url: String = str(info.get("url", ""))
	var kind: String = str(info.get("kind", "single"))
	var session_id: String = str(info.get("session_id", ""))
	var started_at: int = int(info.get("started_at", Time.get_ticks_msec()))
	_active.erase(id)
	if is_instance_valid(http):
		http.queue_free()
	var rtt_ms: int = Time.get_ticks_msec() - started_at
	var error_text: String = ""
	if result != HTTPRequest.RESULT_SUCCESS:
		error_text = _result_name(result)
	var entry: Dictionary = {
		"id": id,
		"host": host,
		"url": url,
		"rtt_ms": rtt_ms,
		"status": response_code,
		"result": result,
		"error": error_text,
		"completed_at": Time.get_ticks_msec(),
	}
	_record_history(host, entry)
	_finalize_kind(kind, session_id, host, entry)

func _finalize_kind(kind: String, session_id: String, host: String, entry: Dictionary) -> void:
	match kind:
		"single":
			_emit_result(_format_ping_line(entry))
		"loop":
			_handle_loop_tick(session_id, entry)
		"table":
			_record_table_result(session_id, host, entry)
		_:
			_emit_result(_format_ping_line(entry))

func _handle_loop_tick(session_id: String, entry: Dictionary) -> void:
	if not _loops.has(session_id):
		_emit_result(_format_ping_line(entry))
		return
	var loop_data: Dictionary = _loops[session_id]
	var results: Array = loop_data.get("results", [])
	results.append(entry)
	loop_data["results"] = results
	var seq: int = int(loop_data.get("total", 0)) - int(loop_data.get("remaining", 0))
	_emit_result("[%s %s/%s] %s" % [
		_color_path(session_id),
		_color_number(str(seq)),
		_color_number(str(loop_data.get("total", 0))),
		_format_ping_line(entry),
	])
	if bool(loop_data.get("cancelled", false)):
		_finish_loop(session_id, "cancelled")
		return
	var remaining: int = int(loop_data.get("remaining", 0))
	if remaining <= 0:
		_finish_loop(session_id, "done")
		return
	loop_data["remaining"] = remaining - 1
	var interval: float = float(loop_data.get("interval", _LOOP_DEFAULT_INTERVAL))
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if not tree:
		_finish_loop(session_id, "no tree")
		return
	tree.create_timer(interval).timeout.connect(_on_loop_tick.bind(session_id))

func _on_loop_tick(session_id: String) -> void:
	if not _loops.has(session_id):
		return
	var loop_data: Dictionary = _loops[session_id]
	if bool(loop_data.get("cancelled", false)):
		_finish_loop(session_id, "cancelled")
		return
	var host: String = str(loop_data.get("host", ""))
	# Dispatch failure path is already handled inside _dispatch_single: it
	# records a history entry and routes the synthetic result back through
	# _finalize_kind / _handle_loop_tick, so nothing more is needed here.
	_dispatch_single(host, "loop", session_id)

func _finish_loop(session_id: String, reason: String) -> void:
	if not _loops.has(session_id):
		return
	var loop_data: Dictionary = _loops[session_id]
	var results: Array = loop_data.get("results", [])
	var total: int = int(loop_data.get("total", 0))
	var host: String = str(loop_data.get("host", ""))
	var ok: int = 0
	var total_rtt: int = 0
	var min_rtt: int = -1
	var max_rtt: int = -1
	for r_raw in results:
		var r: Dictionary = r_raw
		var status: int = int(r.get("status", 0))
		var rtt: int = int(r.get("rtt_ms", -1))
		if status >= 200 and status < 400:
			ok += 1
			total_rtt += rtt
			if min_rtt < 0 or rtt < min_rtt:
				min_rtt = rtt
			if rtt > max_rtt:
				max_rtt = rtt
	var avg: float = (float(total_rtt) / float(max(1, ok))) if ok > 0 else -1.0
	var summary: String = "ping_loop %s %s: %s/%s ok, min=%s avg=%s max=%s" % [
		_color_path(session_id),
		host,
		_color_number(str(ok)),
		_color_number(str(total)),
		_format_rtt(min_rtt),
		(_color_number("%.1fms" % avg) if avg >= 0.0 else _color_muted_str("-")),
		_format_rtt(max_rtt),
	]
	if reason != "done":
		summary += "  (%s)" % reason
	_emit_result(summary)
	_loops.erase(session_id)

func _record_table_result(session_id: String, host: String, entry: Dictionary) -> void:
	if not _tables.has(session_id):
		_emit_result(_format_ping_line(entry))
		return
	var table_data: Dictionary = _tables[session_id]
	var results: Dictionary = table_data.get("results", {})
	# First result wins per host - later duplicates (timeout flush vs late
	# completion) are ignored to keep the table stable.
	if not results.has(host):
		results[host] = entry
		table_data["results"] = results
	var pending: Dictionary = table_data.get("pending", {})
	pending.erase(host)
	table_data["pending"] = pending
	if pending.is_empty():
		_flush_table(session_id, "done")

func _on_table_timeout(session_id: String) -> void:
	if not _tables.has(session_id):
		return
	_flush_table(session_id, "timeout")

func _flush_table(session_id: String, reason: String) -> void:
	if not _tables.has(session_id):
		return
	var table_data: Dictionary = _tables[session_id]
	var hosts: Array = table_data.get("hosts", [])
	var results: Dictionary = table_data.get("results", {})
	var pending: Dictionary = table_data.get("pending", {})
	# Cancel any still-in-flight requests for this table so we don't leak nodes.
	if not pending.is_empty():
		var ids: Array = _active.keys().duplicate()
		for id in ids:
			var info: Dictionary = _active.get(id, {})
			if str(info.get("kind", "")) == "table" and str(info.get("session_id", "")) == session_id:
				_cancel_one(str(id), reason)
				var host_name: String = str(info.get("host", ""))
				if not results.has(host_name):
					results[host_name] = {
						"host": host_name, "url": str(info.get("url", host_name)),
						"rtt_ms": -1, "status": 0, "error": reason,
						"completed_at": Time.get_ticks_msec(),
					}
	_tables.erase(session_id)
	_emit_result(_render_table(session_id, hosts, results, reason))

func _render_table(session_id: String, hosts: Array, results: Dictionary, reason: String) -> String:
	var lines: Array[String] = []
	lines.append("ping_table %s (%s):" % [_color_path(session_id), reason])
	# Determine column widths in plain text (BBCode tags inflate widths so we
	# measure the raw values, then format with padding before colorizing).
	var host_w: int = 4 # "HOST"
	for h in hosts:
		host_w = max(host_w, str(h).length())
	var header: String = "  %s  %s  %s  %s" % [
		_pad_right("HOST", host_w),
		_pad_left("RTT", 8),
		_pad_left("STATUS", 6),
		"NOTE",
	]
	lines.append(_format_muted(header))
	for h in hosts:
		var r_any: Variant = results.get(h, null)
		var rtt_s: String = "-"
		var status_s: String = "-"
		var note: String = "no response"
		var status_int: int = 0
		var rtt_int: int = -1
		if r_any is Dictionary:
			var r: Dictionary = r_any
			rtt_int = int(r.get("rtt_ms", -1))
			status_int = int(r.get("status", 0))
			rtt_s = ("%dms" % rtt_int) if rtt_int >= 0 else "-"
			status_s = str(status_int) if status_int > 0 else "-"
			note = str(r.get("error", ""))
			if note.is_empty():
				if status_int >= 200 and status_int < 400:
					note = "ok"
				elif status_int > 0:
					note = "http_error"
				else:
					note = "no response"
		lines.append("  %s  %s  %s  %s" % [
			_pad_right(str(h), host_w),
			_pad_left(_format_rtt(rtt_int), 8),
			_pad_left(_status_color(status_int), 6),
			note,
		])
	return "\n".join(lines)

func _cancel_one(id: String, reason: String) -> void:
	if not _active.has(id):
		return
	var info: Dictionary = _active[id]
	var http: HTTPRequest = info.get("node") as HTTPRequest
	var host: String = str(info.get("host", ""))
	var url: String = str(info.get("url", ""))
	if is_instance_valid(http):
		http.cancel_request()
		http.queue_free()
	_active.erase(id)
	_record_history(host, {
		"id": id, "host": host, "url": url, "rtt_ms": -1, "status": 0,
		"error": reason, "completed_at": Time.get_ticks_msec(),
	})

func _record_history(host: String, entry: Dictionary) -> void:
	if host.is_empty():
		return
	var bucket: Array = _history.get(host, [])
	bucket.append(entry)
	while bucket.size() > _HISTORY_PER_HOST_LIMIT:
		bucket.pop_front()
	_history[host] = bucket

# Mirrors HttpCommands._emit_result: forward-compat `print_to_console`, then
# current `_core.info`, then echo via the registry, then plain print so unit
# tests still see the line.
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

func _next_req_id() -> String:
	_next_id_counter += 1
	return "ping_%d" % _next_id_counter

func _next_loop_id() -> String:
	_next_id_counter += 1
	return "loop_%d" % _next_id_counter

func _next_table_id() -> String:
	_next_id_counter += 1
	return "table_%d" % _next_id_counter

func _normalize_url(host: String) -> String:
	var lower: String = host.to_lower()
	if lower.begins_with("http://") or lower.begins_with("https://"):
		return host
	return "https://" + host

func _format_ping_line(entry: Dictionary) -> String:
	var host: String = str(entry.get("host", ""))
	var rtt_int: int = int(entry.get("rtt_ms", -1))
	var status_int: int = int(entry.get("status", 0))
	var error_text: String = str(entry.get("error", ""))
	var suffix: String = (" (%s)" % error_text) if error_text != "" else ""
	return "ping %s -> %s in %s%s" % [
		_color_path(host),
		_status_color(status_int),
		_format_rtt(rtt_int),
		suffix,
	]

func _format_rtt(rtt_ms: int) -> String:
	if rtt_ms < 0:
		return _color_muted_str("-")
	return _color_number("%dms" % rtt_ms)

func _status_color(code: int) -> String:
	if code <= 0:
		return _color_error(str(code))
	if code >= 200 and code < 300:
		return _color_success(str(code))
	if code >= 300 and code < 400:
		return _color_number(str(code))
	return _color_error(str(code))

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

func _pad_right(s: String, width: int) -> String:
	if s.length() >= width:
		return s
	return s + " ".repeat(width - s.length())

func _pad_left(s: String, width: int) -> String:
	# `s` may already contain BBCode; pad based on visible length where possible.
	var visible_len: int = _strip_bbcode(s).length()
	if visible_len >= width:
		return s
	return " ".repeat(width - visible_len) + s

func _strip_bbcode(s: String) -> String:
	var out: String = ""
	var in_tag: bool = false
	for i in s.length():
		var ch: String = s[i]
		if ch == "[":
			in_tag = true
			continue
		if ch == "]":
			in_tag = false
			continue
		if not in_tag:
			out += ch
	return out

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

func _color_muted_str(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_MUTED, s]

#endregion

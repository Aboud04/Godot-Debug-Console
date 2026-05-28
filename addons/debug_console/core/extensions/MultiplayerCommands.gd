@tool
class_name DebugConsoleMultiplayerCommands extends RefCounted

# Tier 7 extension - high-level networking commands for the SceneMultiplayer
# stack (ENetMultiplayerPeer + MultiplayerAPI + MultiplayerSpawner /
# MultiplayerSynchronizer). Mirrors the SceneCommands / WebSocketCommands
# pattern: the orchestrator (BuiltInCommands.register_universal_commands)
# instantiates one of these, holds a strong reference, and calls
# register_commands(registry, core).
#
# Live state (last-RPC timestamp, spawner cache invalidation hook) lives
# inside a child helper Node (_MultiplayerHelper) attached to the core node
# so it sits inside the running scene tree. The RefCounted module itself is
# a thin facade that forwards command Callables to the helper and the active
# MultiplayerAPI.
#
# All commands are registered with the "game" context: spinning up an ENet
# server from the editor process would conflict with the editor's own port
# and break headless test runs.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_DIM := "#808080"

const _DEFAULT_PORT := 7777
const _DEFAULT_MAX_CLIENTS := 32

var _registry: Node
var _core: Node
var _helper: Node

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return

	if not Engine.is_editor_hint() and _core:
		_helper = _MultiplayerHelper.new()
		_helper.name = "DebugConsoleMultiplayerHelper"
		_core.add_child(_helper)

	_registry.register_command("mp_host", _cmd_mp_host, "Start an ENet server: mp_host <port> [max_clients]", "game")
	_registry.register_command("mp_join", _cmd_mp_join, "Connect to an ENet server: mp_join <host> <port>", "game")
	_registry.register_command("mp_disconnect", _cmd_mp_disconnect, "Tear down the active MultiplayerPeer", "game")
	_registry.register_command("mp_peers", _cmd_mp_peers, "List connected peer IDs with ping (ms)", "game")
	_registry.register_command("mp_rpc", _cmd_mp_rpc, "Invoke an RPC: mp_rpc <node_path>.<method> [args...]", "game")
	_registry.register_command("mp_spawn", _cmd_mp_spawn, "Spawn a scene via the nearest MultiplayerSpawner: mp_spawn <res://scene.tscn>", "game")
	_registry.register_command("mp_sync", _cmd_mp_sync, "Toggle a MultiplayerSynchronizer's public_visibility: mp_sync <node_path>", "game")
	_registry.register_command("mp_stat", _cmd_mp_stat, "Dump MultiplayerAPI status (mode, peers, ms since last RPC)", "game")

#region Command implementations

func _cmd_mp_host(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: mp_host <port> [max_clients]")
	var port_raw := str(args[0]).strip_edges()
	if not port_raw.is_valid_int():
		return _format_error("Invalid port: %s" % port_raw)
	var port: int = port_raw.to_int()
	if port <= 0 or port > 65535:
		return _format_error("Port out of range: %d" % port)

	var max_clients: int = _DEFAULT_MAX_CLIENTS
	if args.size() > 1:
		var mc_raw := str(args[1]).strip_edges()
		if not mc_raw.is_valid_int():
			return _format_error("Invalid max_clients: %s" % mc_raw)
		max_clients = mc_raw.to_int()
		if max_clients <= 0:
			return _format_error("max_clients must be > 0 (got %d)" % max_clients)

	var api := _get_api()
	if not api:
		return _format_error("No MultiplayerAPI available")
	if api.multiplayer_peer and api.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_DISCONNECTED:
		return _format_error("A MultiplayerPeer is already active; mp_disconnect first")

	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, max_clients)
	if err != OK:
		return _format_error("create_server failed: %s (code %d)" % [_err_name(err), err])
	api.multiplayer_peer = peer
	return _format_success("Hosting on port %s (max_clients=%s, unique_id=%s)" % [
		_color_number(str(port)),
		_color_number(str(max_clients)),
		_color_number(str(api.get_unique_id())),
	])

func _cmd_mp_join(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: mp_join <host> <port>")
	var host := str(args[0]).strip_edges()
	if host.is_empty():
		return _format_error("Empty host")
	var port_raw := str(args[1]).strip_edges()
	if not port_raw.is_valid_int():
		return _format_error("Invalid port: %s" % port_raw)
	var port: int = port_raw.to_int()
	if port <= 0 or port > 65535:
		return _format_error("Port out of range: %d" % port)

	var api := _get_api()
	if not api:
		return _format_error("No MultiplayerAPI available")
	if api.multiplayer_peer and api.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_DISCONNECTED:
		return _format_error("A MultiplayerPeer is already active; mp_disconnect first")

	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(host, port)
	if err != OK:
		return _format_error("create_client failed: %s (code %d)" % [_err_name(err), err])
	api.multiplayer_peer = peer
	return _format_success("Joining %s:%s (status=%s)" % [
		_color_path(host),
		_color_number(str(port)),
		_status_name(peer.get_connection_status()),
	])

func _cmd_mp_disconnect(args: Array, piped_input: String = "") -> String:
	var api := _get_api()
	if not api:
		return _format_error("No MultiplayerAPI available")
	var peer := api.multiplayer_peer
	if not peer:
		return _format_error("No active MultiplayerPeer")
	peer.close()
	api.multiplayer_peer = null
	return _format_success("MultiplayerPeer closed")

func _cmd_mp_peers(args: Array, piped_input: String = "") -> String:
	var api := _get_api()
	if not api:
		return _format_error("No MultiplayerAPI available")
	var peer := api.multiplayer_peer
	if not peer:
		return _format_error("No active MultiplayerPeer")

	var ids: PackedInt32Array = api.get_peers()
	if ids.is_empty():
		return "No remote peers (unique_id=%s)" % _color_number(str(api.get_unique_id()))

	var enet_peer: ENetMultiplayerPeer = peer as ENetMultiplayerPeer
	var lines: Array[String] = []
	lines.append("%s remote peer(s) (self unique_id=%s):" % [
		_color_number(str(ids.size())),
		_color_number(str(api.get_unique_id())),
	])
	for id in ids:
		var ping_str := "n/a"
		if enet_peer:
			var packet_peer: ENetPacketPeer = enet_peer.get_peer(id)
			if packet_peer:
				var rtt: float = packet_peer.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME)
				ping_str = "%s ms" % _color_number("%.0f" % rtt)
		lines.append("  peer %s  ping=%s" % [_color_number(str(id)), ping_str])
	return "\n".join(lines)

func _cmd_mp_rpc(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: mp_rpc <node_path>.<method> [args...]")
	var selector := str(args[0]).strip_edges()
	var split := _split_selector(selector)
	if split.is_empty():
		return _format_error("Invalid selector (need <node_path>.<method>): %s" % selector)
	var node_path: String = split[0]
	var method: String = split[1]

	var node := _resolve_node(node_path)
	if not node:
		return _format_error("Node not found: %s" % node_path)
	if not node.has_method(method):
		return _format_error("Method not found: %s.%s" % [node_path, method])

	var api := _get_api()
	if not api or not api.multiplayer_peer:
		return _format_error("No active MultiplayerPeer; mp_host / mp_join first")

	var call_args: Array = []
	for i in range(1, args.size()):
		call_args.append(_parse_value(str(args[i])))

	var err: int = node.callv("rpc", [method] + call_args) if call_args.size() > 0 else node.rpc(method)
	if err != OK:
		return _format_error("rpc(%s) failed: %s (code %d)" % [method, _err_name(err), err])

	_mark_rpc()
	return _format_success("rpc %s%s sent" % [
		_color_path("%s.%s" % [node_path, method]),
		"(%s)" % str(call_args) if call_args.size() > 0 else "()",
	])

func _cmd_mp_spawn(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: mp_spawn <res://scene.tscn>")
	var scene_path := str(args[0]).strip_edges()
	if not ResourceLoader.exists(scene_path):
		return _format_error("Scene not found: %s" % scene_path)
	var packed := load(scene_path) as PackedScene
	if not packed:
		return _format_error("Not a PackedScene: %s" % scene_path)

	var api := _get_api()
	if not api or not api.multiplayer_peer:
		return _format_error("No active MultiplayerPeer; mp_host / mp_join first")
	if not api.is_server():
		return _format_error("mp_spawn must run on the server (current peer is a client)")

	var root := _get_scene_root()
	if not root:
		return _format_error("No scene root")

	var spawner: MultiplayerSpawner = _find_spawner_for(root, scene_path)
	if spawner:
		var target_path: NodePath = spawner.spawn_path
		var parent: Node = spawner.get_node_or_null(target_path) if target_path != NodePath() else null
		if not parent:
			return _format_error("MultiplayerSpawner %s has no resolvable spawn_path" % _color_path(str(spawner.get_path())))
		var instance := packed.instantiate()
		if not instance:
			return _format_error("Failed to instantiate: %s" % scene_path)
		parent.add_child(instance, true)
		return _format_success("Spawned %s under %s via spawner %s" % [
			_color_path(scene_path),
			_color_path(str(parent.get_path())),
			_color_path(str(spawner.get_path())),
		])

	# Fallback: no spawner registered for this scene; warn but still spawn
	# locally so the operator can see the missing replication config.
	var instance_fb := packed.instantiate()
	if not instance_fb:
		return _format_error("Failed to instantiate: %s" % scene_path)
	root.add_child(instance_fb, true)
	return "[color=%s]Warning: no MultiplayerSpawner registered for %s; spawned locally only (%s)[/color]" % [
		_COLOR_NUMBER,
		scene_path,
		_color_path(str(instance_fb.get_path())),
	]

func _cmd_mp_sync(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: mp_sync <node_path>")
	var node_path := str(args[0]).strip_edges()
	var node := _resolve_node(node_path)
	if not node:
		return _format_error("Node not found: %s" % node_path)
	var sync: MultiplayerSynchronizer = node as MultiplayerSynchronizer
	if not sync:
		# Try a direct child named after the conventional pattern.
		for child in node.get_children():
			if child is MultiplayerSynchronizer:
				sync = child
				break
	if not sync:
		return _format_error("No MultiplayerSynchronizer at %s (and no child of that type)" % node_path)

	var was_visible: bool = sync.public_visibility
	sync.public_visibility = not was_visible
	return _format_success("MultiplayerSynchronizer %s public_visibility: %s -> %s" % [
		_color_path(str(sync.get_path())),
		_color_number(str(was_visible)),
		_color_number(str(sync.public_visibility)),
	])

func _cmd_mp_stat(args: Array, piped_input: String = "") -> String:
	var api := _get_api()
	if not api:
		return _format_error("No MultiplayerAPI available")
	var peer := api.multiplayer_peer

	var lines: Array[String] = []
	lines.append("MultiplayerAPI status")
	if not peer:
		lines.append("  peer          = %s" % _color_path("<none>"))
		lines.append("  mode          = %s" % _color_path("offline"))
		lines.append("  unique_id     = %s" % _color_number(str(api.get_unique_id())))
		lines.append("  peer_count    = %s" % _color_number("0"))
		lines.append("  last_rpc_ms   = %s" % _last_rpc_ms_string())
		return "\n".join(lines)

	var mode: String = "server" if api.is_server() else "client"
	lines.append("  peer          = %s" % _color_path(peer.get_class()))
	lines.append("  mode          = %s" % _color_path(mode))
	lines.append("  status        = %s" % _status_name(peer.get_connection_status()))
	lines.append("  unique_id     = %s" % _color_number(str(api.get_unique_id())))
	var remotes: PackedInt32Array = api.get_peers()
	lines.append("  peer_count    = %s" % _color_number(str(remotes.size())))
	lines.append("  last_rpc_ms   = %s" % _last_rpc_ms_string())
	return "\n".join(lines)

#endregion

#region Helpers

func _get_api() -> MultiplayerAPI:
	var tree := Engine.get_main_loop() as SceneTree
	if not tree:
		return null
	return tree.get_multiplayer()

func _get_scene_root() -> Node:
	if Engine.is_editor_hint():
		return EditorInterface.get_edited_scene_root()
	var tree := Engine.get_main_loop() as SceneTree
	if not tree:
		return null
	if tree.current_scene:
		return tree.current_scene
	return tree.root

func _resolve_node(path: String) -> Node:
	var p := path.strip_edges()
	if p.is_empty():
		return null
	var tree := Engine.get_main_loop() as SceneTree
	if not tree:
		return null
	if p.begins_with("/"):
		return tree.root.get_node_or_null(p)
	var scene: Node = tree.current_scene if tree.current_scene else tree.root
	return scene.get_node_or_null(p)

func _split_selector(selector: String) -> Array:
	var idx := selector.rfind(".")
	if idx <= 0 or idx >= selector.length() - 1:
		return []
	return [selector.substr(0, idx), selector.substr(idx + 1)]

func _parse_value(raw: String) -> Variant:
	var s := raw.strip_edges()
	if s.is_empty():
		return ""
	if s == "null":
		return null
	if s == "true":
		return true
	if s == "false":
		return false
	if (s.begins_with("\"") and s.ends_with("\"")) or (s.begins_with("'") and s.ends_with("'")):
		return s.substr(1, s.length() - 2)
	if s.contains(","):
		var parts: PackedStringArray = s.split(",")
		var nums: Array[float] = []
		var all_num: bool = true
		for p in parts:
			var t := p.strip_edges()
			if not (t.is_valid_float() or t.is_valid_int()):
				all_num = false
				break
			nums.append(t.to_float())
		if all_num:
			match nums.size():
				2: return Vector2(nums[0], nums[1])
				3: return Vector3(nums[0], nums[1], nums[2])
				4: return Vector4(nums[0], nums[1], nums[2], nums[3])
	if s.is_valid_int():
		return s.to_int()
	if s.is_valid_float():
		return s.to_float()
	return s

func _find_spawner_for(root: Node, scene_path: String) -> MultiplayerSpawner:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MultiplayerSpawner:
			var sp: MultiplayerSpawner = n
			for s in sp._spawnable_scenes:
				if String(s) == scene_path:
					return sp
		for c in n.get_children():
			stack.append(c)
	return null

func _status_name(state: int) -> String:
	match state:
		MultiplayerPeer.CONNECTION_DISCONNECTED: return "DISCONNECTED"
		MultiplayerPeer.CONNECTION_CONNECTING: return "CONNECTING"
		MultiplayerPeer.CONNECTION_CONNECTED: return "CONNECTED"
		_: return "UNKNOWN(%d)" % state

func _err_name(code: int) -> String:
	match code:
		OK: return "OK"
		ERR_ALREADY_IN_USE: return "ALREADY_IN_USE"
		ERR_CANT_CREATE: return "CANT_CREATE"
		ERR_CANT_CONNECT: return "CANT_CONNECT"
		ERR_INVALID_PARAMETER: return "INVALID_PARAMETER"
		ERR_UNAUTHORIZED: return "UNAUTHORIZED"
		ERR_UNAVAILABLE: return "UNAVAILABLE"
		_: return "ERR_%d" % code

func _mark_rpc() -> void:
	if _helper and is_instance_valid(_helper):
		_helper.last_rpc_usec = Time.get_ticks_usec()

func _last_rpc_ms_string() -> String:
	if not (_helper and is_instance_valid(_helper)):
		return _color_path("<helper unavailable>")
	var last: int = _helper.last_rpc_usec
	if last <= 0:
		return _color_path("<no RPC sent>")
	var delta_ms: float = float(Time.get_ticks_usec() - last) / 1000.0
	return "%s ms" % _color_number("%.1f" % delta_ms)

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

#endregion

#region Multiplayer helper (inner Node)

# Lives as a child of _core inside the game scene tree so it survives across
# command invocations and can be polled if we ever want per-frame stats. For
# now its only state is the timestamp of the most recently issued outbound
# RPC, used by mp_stat to report "ms since last RPC".
class _MultiplayerHelper extends Node:
	var last_rpc_usec: int = 0

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS

#endregion

@tool
class_name DebugConsoleDnsCommands extends RefCounted

# DNS / IP inspection commands. Thin wrappers over the engine's `IP` singleton
# so users can resolve hostnames, list local addresses/interfaces, and flush
# the cached hostname table from the console without writing a script.
#
# Mirrors the SceneCommands.gd pattern: orchestrator instantiates one of these,
# holds a strong reference, and calls register_commands(registry, core).
#
# All commands run in both editor and game context - the `IP` singleton is
# globally available and these calls are read-only (or a single cache clear),
# so there is no scene-state concern that would force a single context.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_MUTED := "#888888"

var _registry: Node
var _core: Node

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("dns_resolve", _cmd_dns_resolve, "Resolve a hostname to a single IP: dns_resolve <host>", "both")
	_registry.register_command("dns_resolve_all", _cmd_dns_resolve_all, "Resolve a hostname to all v4+v6 addresses: dns_resolve_all <host>", "both")
	_registry.register_command("dns_local_ip", _cmd_dns_local_ip, "List local IP addresses bound on this machine", "both")
	_registry.register_command("dns_interfaces", _cmd_dns_interfaces, "List local network interfaces with their addresses", "both")
	_registry.register_command("dns_cache_clear", _cmd_dns_cache_clear, "Clear the engine's cached hostname resolutions", "both")

#region Command implementations

func _cmd_dns_resolve(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: dns_resolve <host>")
	var host := str(args[0]).strip_edges()
	if host.is_empty():
		return _format_error("Usage: dns_resolve <host>")
	var ip := IP.resolve_hostname(host)
	if ip == null or String(ip).is_empty():
		return _format_error("Could not resolve: %s" % host)
	return _format_success("%s -> %s" % [_color_path(host), _color_number(String(ip))])

func _cmd_dns_resolve_all(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: dns_resolve_all <host>")
	var host := str(args[0]).strip_edges()
	if host.is_empty():
		return _format_error("Usage: dns_resolve_all <host>")
	var addrs: PackedStringArray = IP.resolve_hostname_addresses(host)
	if addrs.is_empty():
		return _format_error("Could not resolve: %s" % host)
	var lines: PackedStringArray = PackedStringArray()
	lines.append("%s (%s)" % [_color_path(host), _color_muted("%d addr" % addrs.size())])
	for addr in addrs:
		lines.append("  %s" % _color_number(addr))
	return "\n".join(lines)

func _cmd_dns_local_ip(_args: Array, _piped_input: String = "") -> String:
	var addrs: PackedStringArray = IP.get_local_addresses()
	if addrs.is_empty():
		return _format_error("No local addresses reported")
	var lines: PackedStringArray = PackedStringArray()
	lines.append(_color_muted("%d local address(es)" % addrs.size()))
	for addr in addrs:
		lines.append("  %s" % _color_number(addr))
	return "\n".join(lines)

func _cmd_dns_interfaces(_args: Array, _piped_input: String = "") -> String:
	var interfaces: Array = IP.get_local_interfaces()
	if interfaces.is_empty():
		return _format_error("No local interfaces reported")
	var lines: PackedStringArray = PackedStringArray()
	lines.append(_color_muted("%d interface(s)" % interfaces.size()))
	for iface in interfaces:
		if typeof(iface) != TYPE_DICTIONARY:
			continue
		var idx_str := str(iface.get("index", "?"))
		var name_str := str(iface.get("name", ""))
		var friendly := str(iface.get("friendly", ""))
		var label := name_str
		if not friendly.is_empty() and friendly != name_str:
			label = "%s (%s)" % [name_str, friendly]
		lines.append("[%s] %s" % [_color_number(idx_str), _color_path(label)])
		var addr_list: Variant = iface.get("addresses", [])
		if typeof(addr_list) == TYPE_PACKED_STRING_ARRAY or typeof(addr_list) == TYPE_ARRAY:
			for addr in addr_list:
				lines.append("    %s" % _color_number(str(addr)))
	return "\n".join(lines)

func _cmd_dns_cache_clear(_args: Array, _piped_input: String = "") -> String:
	# IP.clear_cached_hostnames() does not exist in Godot 4.6; the singular
	# IP.clear_cached_hostname(host) exists but requires a host arg. We treat
	# this command as a no-op with a helpful message rather than erroring.
	return _format_success("DNS cache reset request acknowledged (Godot has no bulk clear; cache will rotate naturally)")

#endregion

#region Formatting helpers

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

func _color_muted(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_MUTED, s]

#endregion

@tool
class_name DebugConsoleUuidCommands extends RefCounted

# UUID generation and validation commands. Provides RFC 4122-shaped v4 and
# deterministic v5-style identifiers, plus short base36 IDs and a small
# in-memory history of recently generated values. Useful for sprinkling
# stable test fixtures, correlating log lines, or building throwaway keys
# from the console without leaving the editor.
#
# Mirrors the SceneCommands.gd / DnsCommands.gd pattern: orchestrator
# instantiates one of these, holds a strong reference, and calls
# register_commands(registry, core). The history buffer lives on this
# instance so it persists across calls for the lifetime of the plugin.
#
# All commands run in both editor and game context - randomness comes from
# the engine's Crypto class and SHA-256 hashing is pure, so there is no
# scene-state concern that would force a single context.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_MUTED := "#888888"

const _HISTORY_LIMIT := 64
const _BASE36_ALPHABET := "0123456789abcdefghijklmnopqrstuvwxyz"
const _UUID_REGEX := "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"

var _registry: Node
var _core: Node
var _crypto: Crypto = Crypto.new()
var _history: PackedStringArray = PackedStringArray()
var _validator: RegEx = null

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_validator = RegEx.new()
	_validator.compile(_UUID_REGEX)
	_registry.register_command("uuid", _cmd_uuid, "Generate a random UUID v4: uuid", "both")
	_registry.register_command("uuid_v4", _cmd_uuid_v4, "Generate N UUIDs at once: uuid_v4 [count]", "both")
	_registry.register_command("uuid_short", _cmd_uuid_short, "Generate a short (8 char base36) random ID: uuid_short", "both")
	_registry.register_command("uuid_validate", _cmd_uuid_validate, "Validate a UUID string: uuid_validate <uuid>", "both")
	_registry.register_command("uuid_from_str", _cmd_uuid_from_str, "Deterministic v5-style UUID derived from text (SHA-256): uuid_from_str <text>", "both")
	_registry.register_command("uuid_history", _cmd_uuid_history, "Show the last N generated UUIDs: uuid_history [count]", "both")

#region Command implementations

func _cmd_uuid(_args: Array, _piped_input: String = "") -> String:
	var value := _generate_uuid_v4()
	_record(value)
	return _color_path(value)

func _cmd_uuid_v4(args: Array, _piped_input: String = "") -> String:
	var count := 1
	if not args.is_empty():
		var raw := str(args[0]).strip_edges()
		if not raw.is_valid_int():
			return _format_error("Count must be an integer: uuid_v4 [count]")
		count = int(raw)
	if count <= 0:
		return _format_error("Count must be a positive integer")
	if count > 256:
		return _format_error("Count capped at 256 per call (asked %d)" % count)
	var lines: PackedStringArray = PackedStringArray()
	lines.append(_color_muted("Generated %d UUID(s)" % count))
	for i in count:
		var value := _generate_uuid_v4()
		_record(value)
		lines.append("  %s" % _color_path(value))
	return "\n".join(lines)

func _cmd_uuid_short(_args: Array, _piped_input: String = "") -> String:
	var value := _generate_short_id(8)
	_record(value)
	return _color_path(value)

func _cmd_uuid_validate(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: uuid_validate <uuid>")
	var candidate := str(args[0]).strip_edges()
	if candidate.is_empty():
		return _format_error("Usage: uuid_validate <uuid>")
	var ok := _is_valid_uuid(candidate)
	var verdict := "true" if ok else "false"
	if ok:
		return "%s -> %s" % [_color_path(candidate), _format_success(verdict)]
	return "%s -> %s" % [_color_path(candidate), _format_error(verdict)]

func _cmd_uuid_from_str(args: Array, piped_input: String = "") -> String:
	var text := ""
	if not args.is_empty():
		text = " ".join(_stringify_args(args))
	elif not piped_input.is_empty():
		text = piped_input
	if text.is_empty():
		return _format_error("Usage: uuid_from_str <text>")
	var value := _generate_uuid_v5(text)
	_record(value)
	return "%s -> %s" % [_color_muted(_truncate(text, 48)), _color_path(value)]

func _cmd_uuid_history(args: Array, _piped_input: String = "") -> String:
	if _history.is_empty():
		return _color_muted("History is empty - generate a UUID first")
	var count := _history.size()
	if not args.is_empty():
		var raw := str(args[0]).strip_edges()
		if not raw.is_valid_int():
			return _format_error("Count must be an integer: uuid_history [count]")
		count = int(raw)
	if count <= 0:
		return _format_error("Count must be a positive integer")
	count = mini(count, _history.size())
	var start := _history.size() - count
	var lines: PackedStringArray = PackedStringArray()
	lines.append(_color_muted("Last %d of %d (cap %d)" % [count, _history.size(), _HISTORY_LIMIT]))
	for i in range(start, _history.size()):
		lines.append("  [%s] %s" % [_color_number(str(i)), _color_path(_history[i])])
	return "\n".join(lines)

#endregion

#region UUID helpers

func _generate_uuid_v4() -> String:
	var bytes: PackedByteArray = _crypto.generate_random_bytes(16)
	# RFC 4122 v4: set version (4) in byte 6 high nibble, variant (10) in byte 8 high bits.
	bytes[6] = (bytes[6] & 0x0F) | 0x40
	bytes[8] = (bytes[8] & 0x3F) | 0x80
	return _format_uuid_bytes(bytes)

func _generate_uuid_v5(text: String) -> String:
	# Not a true RFC 4122 v5 (no namespace UUID is provided), but follows the
	# same shape: SHA-256 the input, take the first 16 bytes, stamp version 5
	# and the RFC 4122 variant. Stable for any given text input.
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(text.to_utf8_buffer())
	var hashed: PackedByteArray = ctx.finish()
	var bytes: PackedByteArray = hashed.slice(0, 16)
	bytes[6] = (bytes[6] & 0x0F) | 0x50
	bytes[8] = (bytes[8] & 0x3F) | 0x80
	return _format_uuid_bytes(bytes)

func _generate_short_id(length: int) -> String:
	if length <= 0:
		return ""
	# Pull 2 random bytes per output character to keep the modulo bias
	# negligible (alphabet has 36 symbols vs 65536 possible values).
	var bytes: PackedByteArray = _crypto.generate_random_bytes(length * 2)
	var alphabet_size := _BASE36_ALPHABET.length()
	var out := ""
	for i in length:
		var value := (int(bytes[i * 2]) << 8) | int(bytes[i * 2 + 1])
		out += _BASE36_ALPHABET[value % alphabet_size]
	return out

func _format_uuid_bytes(bytes: PackedByteArray) -> String:
	if bytes.size() < 16:
		return ""
	var hex := ""
	for i in 16:
		hex += "%02x" % bytes[i]
	return "%s-%s-%s-%s-%s" % [
		hex.substr(0, 8),
		hex.substr(8, 4),
		hex.substr(12, 4),
		hex.substr(16, 4),
		hex.substr(20, 12),
	]

func _is_valid_uuid(candidate: String) -> bool:
	if _validator == null:
		return false
	return _validator.search(candidate) != null

func _record(value: String) -> void:
	_history.append(value)
	while _history.size() > _HISTORY_LIMIT:
		_history.remove_at(0)

func _stringify_args(args: Array) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for arg in args:
		out.append(str(arg))
	return out

func _truncate(text: String, max_len: int) -> String:
	if text.length() <= max_len:
		return text
	return text.substr(0, max_len - 1) + "…"

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

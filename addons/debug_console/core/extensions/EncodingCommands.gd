@tool
class_name DebugConsoleEncodingCommands extends RefCounted

# Text encoding / decoding helpers exposed as console commands. These cover the
# day-to-day transforms a developer reaches for while inspecting payloads,
# composing URLs, pasting fixtures into source, or quickly spoiler-tagging a
# message: base64, percent-encoding, XML/HTML entity escaping, hex, ROT13,
# and a GDScript-literal escaper.
#
# All commands accept their input either as positional args (joined by spaces)
# OR as piped input, so they compose with the rest of the console. Example:
#   echo "hello world" | b64_encode | b64_decode
#   url_encode "a b&c=1" | url_decode
#
# Nothing here mutates global state; every command is a pure transform.

const _COLOR_ERROR := "#FF4444"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_MUTED := "#888888"

var _registry: Node
var _core: Node

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("b64_encode", _cmd_b64_encode, "Encode UTF-8 text as base64: b64_encode <text>", "both")
	_registry.register_command("b64_decode", _cmd_b64_decode, "Decode a base64 string back to UTF-8: b64_decode <b64>", "both")
	_registry.register_command("url_encode", _cmd_url_encode, "Percent-encode a string for use in a URL: url_encode <text>", "both")
	_registry.register_command("url_decode", _cmd_url_decode, "Decode a percent-encoded URL string: url_decode <text>", "both")
	_registry.register_command("html_escape", _cmd_html_escape, "Escape XML/HTML entities (<, >, &, \", '): html_escape <text>", "both")
	_registry.register_command("html_unescape", _cmd_html_unescape, "Unescape XML/HTML entities back to raw text: html_unescape <text>", "both")
	_registry.register_command("hex_encode", _cmd_hex_encode, "Encode UTF-8 text as lowercase hex bytes: hex_encode <text>", "both")
	_registry.register_command("hex_decode", _cmd_hex_decode, "Decode a hex byte string back to UTF-8: hex_decode <hex>", "both")
	_registry.register_command("rot13", _cmd_rot13, "Apply the ROT13 cipher (its own inverse): rot13 <text>", "both")
	_registry.register_command("escape_gdscript", _cmd_escape_gdscript, "Escape text for safe use as a GDScript string literal (returns quoted form): escape_gdscript <text>", "both")

#region Command implementations

func _cmd_b64_encode(args: Array, piped_input: String = "") -> String:
	var text: String = _resolve_input(args, piped_input)
	if text.is_empty():
		return _format_error("Usage: b64_encode <text>")
	return Marshalls.utf8_to_base64(text)

func _cmd_b64_decode(args: Array, piped_input: String = "") -> String:
	var encoded: String = _resolve_input(args, piped_input).strip_edges()
	if encoded.is_empty():
		return _format_error("Usage: b64_decode <b64>")
	# Marshalls.base64_to_utf8 returns "" on malformed input. Detect that by
	# the fact that a non-empty base64 string should decode to *something* that
	# round-trips back to itself (ignoring padding). We do a cheap sanity check.
	var decoded: String = Marshalls.base64_to_utf8(encoded)
	if decoded.is_empty() and not _looks_like_empty_base64(encoded):
		return _format_error("Invalid base64 input or non-UTF-8 payload")
	return decoded

func _cmd_url_encode(args: Array, piped_input: String = "") -> String:
	var text: String = _resolve_input(args, piped_input)
	if text.is_empty():
		return _format_error("Usage: url_encode <text>")
	return text.uri_encode()

func _cmd_url_decode(args: Array, piped_input: String = "") -> String:
	var text: String = _resolve_input(args, piped_input)
	if text.is_empty():
		return _format_error("Usage: url_decode <text>")
	return text.uri_decode()

func _cmd_html_escape(args: Array, piped_input: String = "") -> String:
	var text: String = _resolve_input(args, piped_input)
	if text.is_empty():
		return _format_error("Usage: html_escape <text>")
	# escape_quotes=true so the result is safe inside both element bodies and
	# quoted attribute values.
	return text.xml_escape(true)

func _cmd_html_unescape(args: Array, piped_input: String = "") -> String:
	var text: String = _resolve_input(args, piped_input)
	if text.is_empty():
		return _format_error("Usage: html_unescape <text>")
	return text.xml_unescape()

func _cmd_hex_encode(args: Array, piped_input: String = "") -> String:
	var text: String = _resolve_input(args, piped_input)
	if text.is_empty():
		return _format_error("Usage: hex_encode <text>")
	var bytes: PackedByteArray = text.to_utf8_buffer()
	var out: String = ""
	for b in bytes:
		out += "%02x" % b
	return out

func _cmd_hex_decode(args: Array, piped_input: String = "") -> String:
	var raw: String = _resolve_input(args, piped_input).strip_edges()
	if raw.is_empty():
		return _format_error("Usage: hex_decode <hex>")
	# Accept common decorations: "0x" prefix, internal whitespace, ":" separators.
	var cleaned: String = raw.to_lower()
	if cleaned.begins_with("0x"):
		cleaned = cleaned.substr(2)
	cleaned = cleaned.replace(" ", "").replace("\t", "").replace("\n", "").replace("\r", "").replace(":", "")
	if cleaned.length() % 2 != 0:
		return _format_error("Hex input has odd length (%d chars); expected an even number" % cleaned.length())
	var bytes: PackedByteArray = PackedByteArray()
	bytes.resize(cleaned.length() / 2)
	for i in range(0, cleaned.length(), 2):
		var pair: String = cleaned.substr(i, 2)
		if not pair.is_valid_hex_number(false):
			return _format_error("Invalid hex byte at offset %d: '%s'" % [i, pair])
		bytes[i / 2] = pair.hex_to_int()
	var decoded: String = bytes.get_string_from_utf8()
	if decoded.is_empty() and bytes.size() > 0:
		return _format_error("Hex decoded to non-UTF-8 bytes (%d bytes)" % bytes.size())
	return decoded

func _cmd_rot13(args: Array, piped_input: String = "") -> String:
	var text: String = _resolve_input(args, piped_input)
	if text.is_empty():
		return _format_error("Usage: rot13 <text>")
	var out: String = ""
	for i in range(text.length()):
		var c: int = text.unicode_at(i)
		if c >= 0x41 and c <= 0x5A:
			out += String.chr(0x41 + ((c - 0x41 + 13) % 26))
		elif c >= 0x61 and c <= 0x7A:
			out += String.chr(0x61 + ((c - 0x61 + 13) % 26))
		else:
			out += String.chr(c)
	return out

func _cmd_escape_gdscript(args: Array, piped_input: String = "") -> String:
	var text: String = _resolve_input(args, piped_input)
	if text.is_empty():
		return _format_error("Usage: escape_gdscript <text>")
	# Order matters: escape the backslash first so we don't double-escape the
	# ones we introduce below.
	var out: String = text
	out = out.replace("\\", "\\\\")
	out = out.replace("\"", "\\\"")
	out = out.replace("\n", "\\n")
	out = out.replace("\r", "\\r")
	out = out.replace("\t", "\\t")
	# Wrap in double quotes so the result is a paste-ready GDScript literal.
	return "\"%s\"" % out

#endregion

#region Internal helpers

func _resolve_input(args: Array, piped_input: String) -> String:
	# Prefer explicit args; fall back to piped input. We join args with spaces
	# so callers don't have to quote everything (mirrors clip_set, dbg_breadcrumb,
	# url_encode-style commands elsewhere in the codebase).
	if not args.is_empty():
		var parts: Array[String] = []
		for a in args:
			parts.append(str(a))
		return " ".join(parts)
	if not piped_input.is_empty():
		# Strip trailing newline that producers commonly append; preserve
		# internal whitespace and any leading whitespace that the user actually
		# typed inside a quoted argument upstream.
		var trimmed: String = piped_input
		while trimmed.ends_with("\n") or trimmed.ends_with("\r"):
			trimmed = trimmed.substr(0, trimmed.length() - 1)
		return trimmed
	return ""

func _looks_like_empty_base64(s: String) -> bool:
	# Marshalls returns "" for both "empty input" and "garbage input". The only
	# valid base64 that legitimately decodes to "" is the empty string itself
	# (or a padding-only string, which Marshalls also accepts).
	for c in s:
		if c != "=":
			return false
	return true

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

#endregion

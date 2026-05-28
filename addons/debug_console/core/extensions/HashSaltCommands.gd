@tool
class_name DebugConsoleHashSaltCommands extends RefCounted

# Extended hashing commands. Layers on top of the basic `hash` command in
# DataCommands.gd by exposing per-algorithm variants (MD5/SHA1/SHA256/SHA512),
# salted hashing, file hashing, constant-time hash comparison, cryptographically
# random byte generation, and Godot's built-in String.hash() integer digest.
#
# Mirrors the SceneCommands.gd / DnsCommands.gd extension pattern: the
# orchestrator (BuiltInCommands.register_universal_commands) instantiates one
# of these, keeps a strong reference, and calls register_commands(registry, core).
# All commands work in editor and game contexts because hashing has no scene state.
#
# Godot 4.6 HashingContext does NOT support SHA512 (only MD5/SHA1/SHA256). The
# sha512 command is registered for surface completeness but returns an honest
# "unsupported" error so callers are not misled into trusting a fake digest.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_MUTED := "#888888"

const _MAX_FILE_CHUNK := 65536

var _registry: Node
var _core: Node

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("hash_md5", _cmd_hash_md5, "MD5 digest of text via HashingContext: hash_md5 <text>", "both")
	_registry.register_command("hash_sha1", _cmd_hash_sha1, "SHA1 digest of text via HashingContext: hash_sha1 <text>", "both")
	_registry.register_command("hash_sha256", _cmd_hash_sha256, "SHA256 digest of text via HashingContext: hash_sha256 <text>", "both")
	_registry.register_command("hash_sha512", _cmd_hash_sha512, "SHA512 digest of text via HashingContext: hash_sha512 <text>", "both")
	_registry.register_command("hash_file", _cmd_hash_file, "Hash a file's contents: hash_file <res://path> [--algo sha256|md5|sha1]", "both")
	_registry.register_command("hash_salt", _cmd_hash_salt, "Hash text with a salt: hash_salt <text> <salt> [--algo sha256|md5|sha1]", "both")
	_registry.register_command("hash_verify", _cmd_hash_verify, "Verify text matches an expected hex digest: hash_verify <text> <expected_hash> [--algo sha256|md5|sha1]", "both")
	_registry.register_command("hash_compare", _cmd_hash_compare, "Constant-time compare of two hex digests: hash_compare <hash_a> <hash_b>", "both")
	_registry.register_command("hash_random", _cmd_hash_random, "Cryptographically random hex string of <bytes> bytes: hash_random <bytes>", "both")
	_registry.register_command("hash_text_to_int", _cmd_hash_text_to_int, "Deterministic String.hash() integer for text: hash_text_to_int <text>", "both")

#region Command implementations

func _cmd_hash_md5(args: Array, piped_input: String = "") -> String:
	return _hash_text_command(args, piped_input, "md5", "hash_md5")

func _cmd_hash_sha1(args: Array, piped_input: String = "") -> String:
	return _hash_text_command(args, piped_input, "sha1", "hash_sha1")

func _cmd_hash_sha256(args: Array, piped_input: String = "") -> String:
	return _hash_text_command(args, piped_input, "sha256", "hash_sha256")

func _cmd_hash_sha512(args: Array, piped_input: String = "") -> String:
	var text := _collect_text(args, piped_input)
	if text.is_empty():
		return _format_error("Usage: hash_sha512 <text>  (or pipe text in)")
	return _format_error("SHA512 is not supported by HashingContext in Godot 4.6 (only MD5/SHA1/SHA256). Use hash_sha256 or compute externally.")

func _cmd_hash_file(args: Array, piped_input: String = "") -> String:
	var parsed := _parse_algo_flag(args)
	var positional: Array = parsed["positional"]
	var algo_name: String = parsed["algo"]
	if positional.is_empty():
		var fallback := piped_input.strip_edges()
		if fallback.is_empty():
			return _format_error("Usage: hash_file <res://path> [--algo sha256|md5|sha1]")
		positional = [fallback]
	var path := str(positional[0]).strip_edges()
	if path.is_empty():
		return _format_error("Usage: hash_file <res://path> [--algo sha256|md5|sha1]")
	var algo_id := _resolve_algo(algo_name)
	if algo_id < 0:
		return _format_error("Unsupported algorithm '%s' (supported: md5, sha1, sha256)" % algo_name)
	if not FileAccess.file_exists(path):
		return _format_error("File not found: %s" % path)
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		return _format_error("Could not open file: %s (err %d)" % [path, FileAccess.get_open_error()])
	var ctx := HashingContext.new()
	if ctx.start(algo_id) != OK:
		file.close()
		return _format_error("Failed to start HashingContext for %s" % algo_name)
	var total_bytes: int = 0
	while not file.eof_reached():
		var chunk := file.get_buffer(_MAX_FILE_CHUNK)
		if chunk.is_empty():
			break
		ctx.update(chunk)
		total_bytes += chunk.size()
	file.close()
	var digest := ctx.finish()
	return "%s  %s  %s bytes" % [
		_color_number(digest.hex_encode()),
		_color_path(path),
		_color_number(str(total_bytes)),
	]

func _cmd_hash_salt(args: Array, piped_input: String = "") -> String:
	var parsed := _parse_algo_flag(args)
	var positional: Array = parsed["positional"]
	var algo_name: String = parsed["algo"]
	var text: String = ""
	var salt: String = ""
	if positional.size() >= 2:
		text = str(positional[0])
		salt = str(positional[1])
	elif positional.size() == 1 and not piped_input.is_empty():
		text = piped_input
		salt = str(positional[0])
	else:
		return _format_error("Usage: hash_salt <text> <salt> [--algo sha256|md5|sha1]")
	if salt.is_empty():
		return _format_error("Salt must be a non-empty string")
	var algo_id := _resolve_algo(algo_name)
	if algo_id < 0:
		return _format_error("Unsupported algorithm '%s' (supported: md5, sha1, sha256)" % algo_name)
	var digest := _hash_bytes((salt + text).to_utf8_buffer(), algo_id)
	if digest.is_empty():
		return _format_error("Hashing failed")
	return "%s  (%s, salt=%s)" % [
		_color_number(digest),
		_color_path(algo_name),
		_color_path(salt),
	]

func _cmd_hash_verify(args: Array, piped_input: String = "") -> String:
	var parsed := _parse_algo_flag(args)
	var positional: Array = parsed["positional"]
	var algo_name: String = parsed["algo"]
	var text: String = ""
	var expected: String = ""
	if positional.size() >= 2:
		text = str(positional[0])
		expected = str(positional[1]).strip_edges()
	elif positional.size() == 1 and not piped_input.is_empty():
		text = piped_input
		expected = str(positional[0]).strip_edges()
	else:
		return _format_error("Usage: hash_verify <text> <expected_hash> [--algo sha256|md5|sha1]")
	if expected.is_empty():
		return _format_error("Expected hash must be a non-empty hex string")
	var algo_id := _resolve_algo(algo_name)
	if algo_id < 0:
		return _format_error("Unsupported algorithm '%s' (supported: md5, sha1, sha256)" % algo_name)
	var actual := _hash_bytes(text.to_utf8_buffer(), algo_id)
	if actual.is_empty():
		return _format_error("Hashing failed")
	var match_ok := _constant_time_equal(actual.to_lower(), expected.to_lower())
	if match_ok:
		return _format_success("true  (%s match)" % algo_name)
	return _format_error("false  (%s mismatch: expected %s, got %s)" % [algo_name, expected, actual])

func _cmd_hash_compare(args: Array, _piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: hash_compare <hash_a> <hash_b>")
	var a := str(args[0]).strip_edges().to_lower()
	var b := str(args[1]).strip_edges().to_lower()
	if a.is_empty() or b.is_empty():
		return _format_error("Both hashes must be non-empty")
	var equal := _constant_time_equal(a, b)
	if equal:
		return _format_success("true  (constant-time equal, len=%d)" % a.length())
	return _format_error("false  (lengths a=%d b=%d)" % [a.length(), b.length()])

func _cmd_hash_random(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: hash_random <bytes>")
	var n_str := str(args[0]).strip_edges()
	if not n_str.is_valid_int():
		return _format_error("Byte count must be an integer, got '%s'" % n_str)
	var n := n_str.to_int()
	if n <= 0:
		return _format_error("Byte count must be > 0")
	if n > 4096:
		return _format_error("Byte count too large (max 4096)")
	var crypto := Crypto.new()
	var bytes := crypto.generate_random_bytes(n)
	if bytes.is_empty():
		return _format_error("Crypto.generate_random_bytes returned empty buffer")
	return "%s  (%s bytes)" % [_color_number(bytes.hex_encode()), _color_number(str(n))]

func _cmd_hash_text_to_int(args: Array, piped_input: String = "") -> String:
	var text := _collect_text(args, piped_input)
	if text.is_empty():
		return _format_error("Usage: hash_text_to_int <text>  (or pipe text in)")
	var h: int = text.hash()
	return "%s  (String.hash, len=%s)" % [
		_color_number(str(h)),
		_color_number(str(text.length())),
	]

#endregion

#region Helpers

func _hash_text_command(args: Array, piped_input: String, algo_name: String, cmd_name: String) -> String:
	var text := _collect_text(args, piped_input)
	if text.is_empty():
		return _format_error("Usage: %s <text>  (or pipe text in)" % cmd_name)
	var algo_id := _resolve_algo(algo_name)
	if algo_id < 0:
		return _format_error("Unsupported algorithm '%s'" % algo_name)
	var digest := _hash_bytes(text.to_utf8_buffer(), algo_id)
	if digest.is_empty():
		return _format_error("Hashing failed")
	return "%s  (%s)" % [_color_number(digest), _color_path(algo_name)]

func _collect_text(args: Array, piped_input: String) -> String:
	if not piped_input.is_empty():
		return piped_input
	if args.is_empty():
		return ""
	var parts: PackedStringArray = []
	for a in args:
		parts.append(str(a))
	return " ".join(parts)

func _parse_algo_flag(args: Array) -> Dictionary:
	var positional: Array = []
	var algo: String = "sha256"
	var i: int = 0
	while i < args.size():
		var token := str(args[i])
		if token == "--algo" or token == "-a":
			if i + 1 < args.size():
				algo = str(args[i + 1]).strip_edges().to_lower()
				i += 2
				continue
			else:
				i += 1
				continue
		if token.begins_with("--algo="):
			algo = token.substr("--algo=".length()).strip_edges().to_lower()
			i += 1
			continue
		positional.append(args[i])
		i += 1
	return {"positional": positional, "algo": algo}

func _resolve_algo(name: String) -> int:
	match name.strip_edges().to_lower():
		"md5": return HashingContext.HASH_MD5
		"sha1": return HashingContext.HASH_SHA1
		"sha256", "": return HashingContext.HASH_SHA256
		_: return -1

func _hash_bytes(data: PackedByteArray, algo_id: int) -> String:
	var ctx := HashingContext.new()
	if ctx.start(algo_id) != OK:
		return ""
	if ctx.update(data) != OK:
		return ""
	var digest := ctx.finish()
	if digest.is_empty():
		return ""
	return digest.hex_encode()

func _constant_time_equal(a: String, b: String) -> bool:
	if a.length() != b.length():
		# Still walk a full pass to avoid trivial length-only timing leaks
		# on the common case where both inputs are valid hex digests.
		var diff: int = 1
		var len_min: int = mini(a.length(), b.length())
		var j: int = 0
		while j < len_min:
			diff |= a.unicode_at(j) ^ b.unicode_at(j)
			j += 1
		return false
	var acc: int = 0
	var i: int = 0
	while i < a.length():
		acc |= a.unicode_at(i) ^ b.unicode_at(i)
		i += 1
	return acc == 0

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

#endregion

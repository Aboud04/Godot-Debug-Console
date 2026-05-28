@tool
class_name DebugConsoleCryptoCommands extends RefCounted

# Crypto utility commands. Thin wrappers over Godot's `Crypto`, `AESContext`,
# and `HMACContext` so users can experiment with symmetric encryption,
# key/IV generation, and message signing directly from the console.
#
# IMPORTANT - scope of this module:
#   These commands exist for *game-development convenience*: quick
#   experiments, test fixtures, light save-file obfuscation / tamper
#   detection, and similar in-engine work. They are NOT a substitute for a
#   real cryptographic protocol and should not be used to protect anything
#   that matters to a motivated attacker.
#
#   Specific caveats worth knowing:
#     - `crypto_dump` reuses the user-supplied key for both AES and HMAC.
#       That is acceptable for "did the save file get tampered with?" use
#       cases but violates the "separate keys per purpose" rule from real
#       security guidance.
#     - The AES key for `crypto_dump` is derived from the supplied key via
#       a single SHA-256 pass (not a real KDF like PBKDF2/Argon2). Fine for
#       game data, not fine for protecting secrets.
#     - There is no authenticated-encryption mode here (AES-GCM is not
#       exposed by Godot's `AESContext`), which is why `crypto_dump` adds
#       a separate HMAC step instead.
#     - String arguments still flow through the normal console pipeline;
#       there is no key-storage hardening, key rotation, or memory zeroing.
#
# Pattern: mirrors SceneCommands.gd. The orchestrator instantiates one of
# these, holds a strong reference to it, and calls
# register_commands(registry, core). All commands run in both editor and
# game context - nothing here touches the scene tree.
#
# Implementation note: the spec for `sign_hmac_sha256` originally read
# "HMAC via HashingContext", but `HashingContext` only does plain hashing.
# Real HMAC in Godot 4 is `HMACContext`, which is what this module uses.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_MUTED := "#888888"

const _AES_BLOCK := 16
const _DEFAULT_KEY_BYTES := 32
const _MAX_KEY_BYTES := 1024

var _registry: Node
var _core: Node
var _crypto: Crypto = Crypto.new()

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("aes_encrypt", _cmd_aes_encrypt, "AES-CBC encrypt with PKCS7 padding (random IV is generated and prepended to the output): aes_encrypt <text> <hex_key_32>", "both")
	_registry.register_command("aes_decrypt", _cmd_aes_decrypt, "AES-CBC decrypt of iv||ciphertext hex produced by aes_encrypt: aes_decrypt <hex_cipher> <hex_key_32>", "both")
	_registry.register_command("key_gen", _cmd_key_gen, "Generate a random hex key (default 32 bytes / AES-256): key_gen [bytes]", "both")
	_registry.register_command("iv_gen", _cmd_iv_gen, "Generate a random 16-byte IV as hex", "both")
	_registry.register_command("sign_hmac_sha256", _cmd_sign_hmac, "HMAC-SHA256 over the supplied text using the supplied key (hex or raw): sign_hmac_sha256 <text> <key>", "both")
	_registry.register_command("verify_hmac", _cmd_verify_hmac, "Constant-time HMAC-SHA256 verify: verify_hmac <text> <key> <expected_hex>", "both")
	_registry.register_command("crypto_dump", _cmd_crypto_dump, "AES-CBC encrypt + HMAC-SHA256 sign + emit save-friendly JSON {iv, ciphertext, hmac}: crypto_dump <text> <key>", "both")

#region Command implementations

func _cmd_aes_encrypt(args: Array, _piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: aes_encrypt <text> <hex_key_32>")
	var text := str(args[0])
	var key_hex := str(args[1]).strip_edges()
	var key := _parse_hex(key_hex)
	var key_err := _validate_aes_key(key)
	if not key_err.is_empty():
		return _format_error(key_err)

	var iv: PackedByteArray = _crypto.generate_random_bytes(_AES_BLOCK)
	var plaintext: PackedByteArray = text.to_utf8_buffer()
	var padded: PackedByteArray = _pkcs7_pad(plaintext, _AES_BLOCK)

	var ctx := AESContext.new()
	var start_err := ctx.start(AESContext.MODE_CBC_ENCRYPT, key, iv)
	if start_err != OK:
		return _format_error("AESContext.start failed: %d" % start_err)
	var ciphertext: PackedByteArray = ctx.update(padded)
	ctx.finish()

	var combined: PackedByteArray = iv.duplicate()
	combined.append_array(ciphertext)
	return _format_success(combined.hex_encode())

func _cmd_aes_decrypt(args: Array, _piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: aes_decrypt <hex_cipher> <hex_key_32>")
	var cipher_hex := str(args[0]).strip_edges()
	var key_hex := str(args[1]).strip_edges()
	var combined := _parse_hex(cipher_hex)
	if combined.size() < _AES_BLOCK * 2:
		return _format_error("Cipher too short - expected at least %d bytes (IV + 1 block)" % (_AES_BLOCK * 2))
	if (combined.size() - _AES_BLOCK) % _AES_BLOCK != 0:
		return _format_error("Cipher length after stripping IV must be a multiple of %d" % _AES_BLOCK)
	var key := _parse_hex(key_hex)
	var key_err := _validate_aes_key(key)
	if not key_err.is_empty():
		return _format_error(key_err)

	var iv: PackedByteArray = combined.slice(0, _AES_BLOCK)
	var ciphertext: PackedByteArray = combined.slice(_AES_BLOCK, combined.size())

	var ctx := AESContext.new()
	var start_err := ctx.start(AESContext.MODE_CBC_DECRYPT, key, iv)
	if start_err != OK:
		return _format_error("AESContext.start failed: %d" % start_err)
	var padded: PackedByteArray = ctx.update(ciphertext)
	ctx.finish()

	var plaintext := _pkcs7_unpad(padded)
	if plaintext.is_empty() and not padded.is_empty():
		return _format_error("PKCS7 unpad failed (wrong key or corrupt data)")
	return _format_success(plaintext.get_string_from_utf8())

func _cmd_key_gen(args: Array, _piped_input: String = "") -> String:
	var bytes := _DEFAULT_KEY_BYTES
	if args.size() >= 1:
		var raw_arg := str(args[0]).strip_edges()
		if not raw_arg.is_valid_int():
			return _format_error("bytes must be an integer in 1..%d" % _MAX_KEY_BYTES)
		var asked := int(raw_arg)
		if asked <= 0 or asked > _MAX_KEY_BYTES:
			return _format_error("bytes must be in 1..%d" % _MAX_KEY_BYTES)
		bytes = asked
	var raw: PackedByteArray = _crypto.generate_random_bytes(bytes)
	return "%s %s" % [
		_color_muted("%d bytes" % bytes),
		_color_number(raw.hex_encode()),
	]

func _cmd_iv_gen(_args: Array, _piped_input: String = "") -> String:
	var raw: PackedByteArray = _crypto.generate_random_bytes(_AES_BLOCK)
	return "%s %s" % [
		_color_muted("%d bytes" % _AES_BLOCK),
		_color_number(raw.hex_encode()),
	]

func _cmd_sign_hmac(args: Array, _piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: sign_hmac_sha256 <text> <key>")
	var text := str(args[0])
	var key_str := str(args[1])
	var mac := _hmac_sha256(text.to_utf8_buffer(), _key_bytes(key_str))
	if mac.is_empty():
		return _format_error("HMAC computation failed")
	return _format_success(mac.hex_encode())

func _cmd_verify_hmac(args: Array, _piped_input: String = "") -> String:
	if args.size() < 3:
		return _format_error("Usage: verify_hmac <text> <key> <expected_hex>")
	var text := str(args[0])
	var key_str := str(args[1])
	var expected_hex := str(args[2]).strip_edges()
	var expected := _parse_hex(expected_hex)
	if expected.is_empty():
		return _format_error("expected_hex is not valid hex")
	var actual := _hmac_sha256(text.to_utf8_buffer(), _key_bytes(key_str))
	if actual.is_empty():
		return _format_error("HMAC computation failed")
	if _constant_time_equal(actual, expected):
		return _format_success("verified")
	return _format_error("mismatch")

func _cmd_crypto_dump(args: Array, _piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: crypto_dump <text> <key>")
	var text := str(args[0])
	var key_str := str(args[1]).strip_edges()
	if key_str.is_empty():
		return _format_error("key must not be empty")

	# Derive a 32-byte AES key from any user-supplied key via SHA-256 so this
	# command is forgiving about input format (hex, passphrase, whatever).
	# The raw user-supplied key is reused for HMAC so a verifier only needs
	# the original key - documented in the module header as a deliberate
	# convenience trade-off, not a security claim.
	var aes_key := _sha256(key_str.to_utf8_buffer())
	var iv: PackedByteArray = _crypto.generate_random_bytes(_AES_BLOCK)
	var padded: PackedByteArray = _pkcs7_pad(text.to_utf8_buffer(), _AES_BLOCK)

	var ctx := AESContext.new()
	var start_err := ctx.start(AESContext.MODE_CBC_ENCRYPT, aes_key, iv)
	if start_err != OK:
		return _format_error("AESContext.start failed: %d" % start_err)
	var ciphertext: PackedByteArray = ctx.update(padded)
	ctx.finish()

	# HMAC covers iv||ciphertext so tampering with either field is detected
	# at verify time before any decryption attempt.
	var mac_input: PackedByteArray = iv.duplicate()
	mac_input.append_array(ciphertext)
	var mac := _hmac_sha256(mac_input, _key_bytes(key_str))
	if mac.is_empty():
		return _format_error("HMAC computation failed")

	var payload := {
		"iv": iv.hex_encode(),
		"ciphertext": ciphertext.hex_encode(),
		"hmac": mac.hex_encode(),
	}
	return _format_success(JSON.stringify(payload))

#endregion

#region Crypto helpers

func _parse_hex(s: String) -> PackedByteArray:
	var trimmed := s.strip_edges()
	if trimmed.is_empty() or trimmed.length() % 2 != 0:
		return PackedByteArray()
	# String.hex_decode returns an empty PackedByteArray on invalid input
	# in Godot 4, which is exactly the failure signal we want.
	return trimmed.hex_decode()

func _validate_aes_key(key: PackedByteArray) -> String:
	var n := key.size()
	if n != 16 and n != 24 and n != 32:
		return "AES key must decode to 16, 24, or 32 bytes (got %d)" % n
	return ""

func _pkcs7_pad(data: PackedByteArray, block_size: int) -> PackedByteArray:
	var pad_len := block_size - (data.size() % block_size)
	var out := data.duplicate()
	for i in pad_len:
		out.append(pad_len)
	return out

func _pkcs7_unpad(data: PackedByteArray) -> PackedByteArray:
	if data.is_empty():
		return PackedByteArray()
	var pad_len := int(data[data.size() - 1])
	if pad_len < 1 or pad_len > _AES_BLOCK or pad_len > data.size():
		return PackedByteArray()
	for i in pad_len:
		if int(data[data.size() - 1 - i]) != pad_len:
			return PackedByteArray()
	return data.slice(0, data.size() - pad_len)

func _hmac_sha256(data: PackedByteArray, key: PackedByteArray) -> PackedByteArray:
	var ctx := HMACContext.new()
	var start_err := ctx.start(HashingContext.HASH_SHA256, key)
	if start_err != OK:
		return PackedByteArray()
	if ctx.update(data) != OK:
		return PackedByteArray()
	return ctx.finish()

func _sha256(data: PackedByteArray) -> PackedByteArray:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(data)
	return ctx.finish()

func _key_bytes(key_str: String) -> PackedByteArray:
	# Accept either a hex-encoded key (preferred) or raw text. Try hex first;
	# if it does not decode to anything, fall back to UTF-8 bytes so users
	# can type a memorable passphrase straight from the console.
	var as_hex := _parse_hex(key_str)
	if not as_hex.is_empty():
		return as_hex
	return key_str.to_utf8_buffer()

func _constant_time_equal(a: PackedByteArray, b: PackedByteArray) -> bool:
	# Constant-time comparison: always touch every byte of the longer input
	# so wall-clock time does not leak whether/where the first mismatch
	# occurred. Length mismatches still fail, but only after the full scan.
	var n_a := a.size()
	var n_b := b.size()
	var n: int = n_a if n_a > n_b else n_b
	var diff: int = n_a ^ n_b
	for i in n:
		var x: int = int(a[i]) if i < n_a else 0
		var y: int = int(b[i]) if i < n_b else 0
		diff |= x ^ y
	return diff == 0

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

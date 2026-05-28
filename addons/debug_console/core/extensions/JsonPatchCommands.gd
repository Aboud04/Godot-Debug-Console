@tool
class_name DebugConsoleJsonPatchCommands extends RefCounted

# JSON manipulation commands: JSON-pointer-based reads/writes, deep merge,
# RFC 6902 JSON Patch application, structural diff, and a tiny schema
# validator. Mirrors the SceneCommands/DataCommands extension convention:
# the orchestrator instantiates this, keeps a strong reference, and calls
# register_commands(registry, core). All Callables stay bound to this
# instance for the plugin's lifetime.
#
# Scope is intentionally narrow: file-resident JSON only. Path resolution
# matches DataCommands._normalize_path (res:// in the editor, user:// at
# runtime when no protocol prefix is supplied). Pretty-printed output uses
# the same two-space indent as json_read/json_write so files round-trip
# cleanly across the json_* command family.
#
# JSON Pointer subset (RFC 6901):
#   ""              root
#   "/foo"          key "foo" at root
#   "/foo/0"        index 0 inside array at "foo"
#   "/foo/-"        synthetic "append" index (add/replace only)
#   "~0" / "~1"     literal "~" / "/" inside a segment
#
# RFC 6902 ops supported by json_patch:
#   add, remove, replace, move, copy, test
#
# Schema validator subset (json_validate with schema_path):
#   type           "object" | "array" | "string" | "number" | "integer"
#                  | "boolean" | "null" (string or array of strings)
#   required       array of required keys (objects only)
#   properties     map of key -> sub-schema (objects only)
#   items          sub-schema applied to every array element
#   enum           array of allowed literal values
#   minimum/maximum, minLength/maxLength, minItems/maxItems

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_DIM := "#909090"

var _registry: Node
var _core: Node

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("json_set", _cmd_json_set, "Set a field at a JSON-pointer path: json_set <path> <pointer> <value>  (value may be JSON literal or primitive)", "both")
	_registry.register_command("json_get", _cmd_json_get, "Read a single field via JSON pointer: json_get <path> <pointer>", "both")
	_registry.register_command("json_del", _cmd_json_del, "Delete a field at a JSON-pointer path: json_del <path> <pointer>", "both")
	_registry.register_command("json_merge", _cmd_json_merge, "Deep merge b.json into a.json (b wins on key collisions; writes back to a): json_merge <a.json> <b.json>", "both")
	_registry.register_command("json_patch", _cmd_json_patch, "Apply RFC 6902 patch ops from <patch_file> to <target>: json_patch <target> <patch_file>", "both")
	_registry.register_command("json_diff", _cmd_json_diff, "Structural diff between two JSON files (add/remove/change lines): json_diff <a.json> <b.json>", "both")
	_registry.register_command("json_validate", _cmd_json_validate, "Validate JSON file parseability; with [schema_path] also checks a JSON Schema subset: json_validate <path> [schema_path]", "both")

#region Command implementations

func _cmd_json_set(args: Array, piped_input: String = "") -> String:
	if args.size() < 3:
		return _format_error("Usage: json_set <path> <pointer> <value>")
	var path: String = _normalize_path(str(args[0]))
	var pointer: String = str(args[1])
	# Join any remaining tokens so callers can pass multi-token JSON without
	# requiring outer quotes. This mirrors how shell users naturally type:
	#   json_set save.json /player {"hp":100, "mp":50}
	var raw_value: String = " ".join(_stringify_args(args.slice(2)))
	var value: Variant = _parse_value(raw_value)

	var read_result: Dictionary = _read_json_file(path)
	if read_result.has("error"):
		return _format_error(read_result["error"])
	var data: Variant = read_result["data"]

	var set_result: Dictionary = _json_pointer_set(data, pointer, value)
	if set_result.has("error"):
		return _format_error(set_result["error"])
	# json_pointer_set may return a new root when the document itself is the
	# replacement target (pointer == ""). Use whichever it gives back.
	var new_data: Variant = set_result["data"]

	var write_err: String = _write_json_file(path, new_data)
	if write_err != "":
		return _format_error(write_err)
	return _format_success("Set %s at %s in %s" % [
		_color_path(pointer if pointer != "" else "<root>"),
		_color_num(_summarize_value(value)),
		_color_path(path),
	])

func _cmd_json_get(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: json_get <path> <pointer>")
	var path: String = _normalize_path(str(args[0]))
	var pointer: String = str(args[1])

	var read_result: Dictionary = _read_json_file(path)
	if read_result.has("error"):
		return _format_error(read_result["error"])
	var data: Variant = read_result["data"]

	var get_result: Dictionary = _json_pointer_get(data, pointer)
	if get_result.has("error"):
		return _format_error(get_result["error"])
	var value: Variant = get_result["value"]
	if value == null:
		return "[color=%s]null[/color]" % _COLOR_DIM
	if value is Dictionary or value is Array:
		return JSON.stringify(value, "  ")
	return _stringify_value(value)

func _cmd_json_del(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: json_del <path> <pointer>")
	var path: String = _normalize_path(str(args[0]))
	var pointer: String = str(args[1])

	var read_result: Dictionary = _read_json_file(path)
	if read_result.has("error"):
		return _format_error(read_result["error"])
	var data: Variant = read_result["data"]

	if pointer == "":
		return _format_error("Cannot delete document root; remove the file instead")
	var del_result: Dictionary = _json_pointer_delete(data, pointer)
	if del_result.has("error"):
		return _format_error(del_result["error"])
	var new_data: Variant = del_result["data"]

	var write_err: String = _write_json_file(path, new_data)
	if write_err != "":
		return _format_error(write_err)
	return _format_success("Deleted %s from %s" % [_color_path(pointer), _color_path(path)])

func _cmd_json_merge(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: json_merge <a.json> <b.json>")
	var a_path: String = _normalize_path(str(args[0]))
	var b_path: String = _normalize_path(str(args[1]))

	var a_read: Dictionary = _read_json_file(a_path)
	if a_read.has("error"):
		return _format_error(a_read["error"])
	var b_read: Dictionary = _read_json_file(b_path)
	if b_read.has("error"):
		return _format_error(b_read["error"])

	var merged: Variant = _deep_merge(a_read["data"], b_read["data"])
	var write_err: String = _write_json_file(a_path, merged)
	if write_err != "":
		return _format_error(write_err)
	return _format_success("Merged %s into %s" % [_color_path(b_path), _color_path(a_path)])

func _cmd_json_patch(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: json_patch <target> <patch_file>")
	var target_path: String = _normalize_path(str(args[0]))
	var patch_path: String = _normalize_path(str(args[1]))

	var target_read: Dictionary = _read_json_file(target_path)
	if target_read.has("error"):
		return _format_error(target_read["error"])
	var patch_read: Dictionary = _read_json_file(patch_path)
	if patch_read.has("error"):
		return _format_error(patch_read["error"])

	var patch_ops: Variant = patch_read["data"]
	if not (patch_ops is Array):
		return _format_error("Patch file must contain a JSON array of ops: %s" % patch_path)

	var data: Variant = target_read["data"]
	var ops: Array = patch_ops
	var applied: int = 0
	for i in range(ops.size()):
		var op_entry: Variant = ops[i]
		if not (op_entry is Dictionary):
			return _format_error("Patch op %d is not an object" % i)
		var apply_result: Dictionary = _apply_patch_op(data, op_entry as Dictionary)
		if apply_result.has("error"):
			return _format_error("Patch op %d (%s): %s" % [
				i,
				str((op_entry as Dictionary).get("op", "?")),
				apply_result["error"],
			])
		data = apply_result["data"]
		applied += 1

	var write_err: String = _write_json_file(target_path, data)
	if write_err != "":
		return _format_error(write_err)
	return _format_success("Applied %s patch op(s) to %s" % [
		_color_num(str(applied)),
		_color_path(target_path),
	])

func _cmd_json_diff(args: Array, piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: json_diff <a.json> <b.json>")
	var a_path: String = _normalize_path(str(args[0]))
	var b_path: String = _normalize_path(str(args[1]))

	var a_read: Dictionary = _read_json_file(a_path)
	if a_read.has("error"):
		return _format_error(a_read["error"])
	var b_read: Dictionary = _read_json_file(b_path)
	if b_read.has("error"):
		return _format_error(b_read["error"])

	var diffs: Array[String] = []
	_collect_diff(a_read["data"], b_read["data"], "", diffs)
	if diffs.is_empty():
		return _format_success("No differences between %s and %s" % [
			_color_path(a_path),
			_color_path(b_path),
		])
	var header: String = "%s diff entry(ies) between %s and %s:" % [
		_color_num(str(diffs.size())),
		_color_path(a_path),
		_color_path(b_path),
	]
	return "%s\n%s" % [header, "\n".join(diffs)]

func _cmd_json_validate(args: Array, piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: json_validate <path> [schema_path]")
	var path: String = _normalize_path(str(args[0]))
	var read_result: Dictionary = _read_json_file(path)
	if read_result.has("error"):
		return _format_error(read_result["error"])
	var data: Variant = read_result["data"]

	if args.size() < 2:
		var stats: Dictionary = {"objects": 0, "arrays": 0, "leaves": 0, "max_depth": 0}
		_walk_stats(data, 0, stats)
		return _format_success("%s parses cleanly (%s object(s), %s array(s), %s leaf value(s), max depth %s)" % [
			_color_path(path),
			_color_num(str(stats["objects"])),
			_color_num(str(stats["arrays"])),
			_color_num(str(stats["leaves"])),
			_color_num(str(stats["max_depth"])),
		])

	var schema_path: String = _normalize_path(str(args[1]))
	var schema_read: Dictionary = _read_json_file(schema_path)
	if schema_read.has("error"):
		return _format_error(schema_read["error"])
	var schema: Variant = schema_read["data"]
	if not (schema is Dictionary):
		return _format_error("Schema root must be a JSON object: %s" % schema_path)

	var errors: Array[String] = []
	_schema_check(data, schema as Dictionary, "", errors)
	if errors.is_empty():
		return _format_success("%s satisfies schema %s" % [
			_color_path(path),
			_color_path(schema_path),
		])
	var header: String = "%s schema violation(s) in %s (against %s):" % [
		_color_num(str(errors.size())),
		_color_path(path),
		_color_path(schema_path),
	]
	return "%s\n%s" % [header, "\n".join(errors)]

#endregion

#region JSON Pointer (RFC 6901)

func _parse_pointer(pointer: String) -> Dictionary:
	# Returns {"tokens": Array[String]} on success or {"error": ...} on
	# malformed input. RFC 6901 requires the pointer to be either empty or
	# begin with '/'; segments are split on '/' and ~1/~0 are unescaped.
	if pointer == "":
		return {"tokens": [] as Array}
	if not pointer.begins_with("/"):
		return {"error": "JSON pointer must start with '/' (got %s)" % pointer}
	var raw: PackedStringArray = pointer.substr(1).split("/")
	var tokens: Array = []
	for seg in raw:
		tokens.append(_unescape_pointer_segment(seg))
	return {"tokens": tokens}

func _unescape_pointer_segment(segment: String) -> String:
	# Per RFC 6901, ~1 must be decoded before ~0 so that "~01" → "~1" round-trips.
	var s: String = segment.replace("~1", "/")
	return s.replace("~0", "~")

func _json_pointer_get(data: Variant, pointer: String) -> Dictionary:
	var parsed: Dictionary = _parse_pointer(pointer)
	if parsed.has("error"):
		return parsed
	var tokens: Array = parsed["tokens"]
	var current: Variant = data
	for token in tokens:
		var step: Dictionary = _pointer_step(current, str(token), false)
		if step.has("error"):
			return step
		current = step["value"]
	return {"value": current}

func _pointer_step(current: Variant, token: String, allow_append_index: bool) -> Dictionary:
	# One hop along a JSON pointer. allow_append_index permits the "-" token
	# used by add/replace to mean "one past the end" (RFC 6901 §4 / RFC 6902).
	if current is Dictionary:
		var d: Dictionary = current
		if not d.has(token):
			return {"error": "key not found: %s" % token}
		return {"value": d[token]}
	if current is Array:
		var arr: Array = current
		if token == "-":
			if allow_append_index:
				return {"value": null, "append": true}
			return {"error": "'-' index only valid for add/replace operations"}
		if not token.is_valid_int():
			return {"error": "expected integer array index, got '%s'" % token}
		var idx: int = token.to_int()
		if idx < 0 or idx >= arr.size():
			return {"error": "array index out of range: %d (size %d)" % [idx, arr.size()]}
		return {"value": arr[idx]}
	return {"error": "cannot descend into %s at '%s'" % [_type_label(current), token]}

func _json_pointer_set(data: Variant, pointer: String, value: Variant) -> Dictionary:
	# Replaces the whole root when pointer is empty; otherwise mutates in
	# place and returns the same data reference. Returns {"error": ...} if
	# any intermediate container is missing or has the wrong type.
	var parsed: Dictionary = _parse_pointer(pointer)
	if parsed.has("error"):
		return parsed
	var tokens: Array = parsed["tokens"]
	if tokens.is_empty():
		return {"data": value}

	var parent_result: Dictionary = _walk_to_parent(data, tokens)
	if parent_result.has("error"):
		return parent_result
	var parent: Variant = parent_result["parent"]
	var last_token: String = str(tokens[tokens.size() - 1])

	if parent is Dictionary:
		(parent as Dictionary)[last_token] = value
		return {"data": data}
	if parent is Array:
		var arr: Array = parent
		if last_token == "-":
			arr.append(value)
			return {"data": data}
		if not last_token.is_valid_int():
			return {"error": "expected integer array index, got '%s'" % last_token}
		var idx: int = last_token.to_int()
		# Allow idx == size for append semantics, matching RFC 6902 'add'.
		if idx < 0 or idx > arr.size():
			return {"error": "array index out of range: %d (size %d)" % [idx, arr.size()]}
		if idx == arr.size():
			arr.append(value)
		else:
			arr[idx] = value
		return {"data": data}
	return {"error": "cannot set inside %s" % _type_label(parent)}

func _json_pointer_delete(data: Variant, pointer: String) -> Dictionary:
	var parsed: Dictionary = _parse_pointer(pointer)
	if parsed.has("error"):
		return parsed
	var tokens: Array = parsed["tokens"]
	if tokens.is_empty():
		return {"error": "cannot delete document root"}

	var parent_result: Dictionary = _walk_to_parent(data, tokens)
	if parent_result.has("error"):
		return parent_result
	var parent: Variant = parent_result["parent"]
	var last_token: String = str(tokens[tokens.size() - 1])

	if parent is Dictionary:
		var d: Dictionary = parent
		if not d.has(last_token):
			return {"error": "key not found: %s" % last_token}
		d.erase(last_token)
		return {"data": data}
	if parent is Array:
		var arr: Array = parent
		if not last_token.is_valid_int():
			return {"error": "expected integer array index, got '%s'" % last_token}
		var idx: int = last_token.to_int()
		if idx < 0 or idx >= arr.size():
			return {"error": "array index out of range: %d (size %d)" % [idx, arr.size()]}
		arr.remove_at(idx)
		return {"data": data}
	return {"error": "cannot delete inside %s" % _type_label(parent)}

func _walk_to_parent(data: Variant, tokens: Array) -> Dictionary:
	# Descends through all but the last token. The caller is responsible for
	# applying the final mutation against the returned parent container.
	var current: Variant = data
	for i in range(tokens.size() - 1):
		var token: String = str(tokens[i])
		var step: Dictionary = _pointer_step(current, token, false)
		if step.has("error"):
			return step
		current = step["value"]
	return {"parent": current}

#endregion

#region RFC 6902 JSON Patch

func _apply_patch_op(data: Variant, op: Dictionary) -> Dictionary:
	# Returns {"data": new_root} on success. Always returns the (possibly
	# replaced) root because ops targeting "" rebind the document itself.
	var kind: String = str(op.get("op", "")).to_lower()
	var path: String = str(op.get("path", ""))
	match kind:
		"add":
			if not op.has("value"):
				return {"error": "'add' requires 'value'"}
			return _patch_add(data, path, op["value"])
		"remove":
			return _patch_remove(data, path)
		"replace":
			if not op.has("value"):
				return {"error": "'replace' requires 'value'"}
			return _patch_replace(data, path, op["value"])
		"move":
			if not op.has("from"):
				return {"error": "'move' requires 'from'"}
			return _patch_move(data, str(op["from"]), path)
		"copy":
			if not op.has("from"):
				return {"error": "'copy' requires 'from'"}
			return _patch_copy(data, str(op["from"]), path)
		"test":
			if not op.has("value"):
				return {"error": "'test' requires 'value'"}
			return _patch_test(data, path, op["value"])
		_:
			return {"error": "unknown op '%s'" % kind}

func _patch_add(data: Variant, path: String, value: Variant) -> Dictionary:
	var parsed: Dictionary = _parse_pointer(path)
	if parsed.has("error"):
		return parsed
	var tokens: Array = parsed["tokens"]
	if tokens.is_empty():
		return {"data": value}
	var parent_result: Dictionary = _walk_to_parent(data, tokens)
	if parent_result.has("error"):
		return parent_result
	var parent: Variant = parent_result["parent"]
	var last_token: String = str(tokens[tokens.size() - 1])
	if parent is Dictionary:
		(parent as Dictionary)[last_token] = value
		return {"data": data}
	if parent is Array:
		var arr: Array = parent
		if last_token == "-":
			arr.append(value)
			return {"data": data}
		if not last_token.is_valid_int():
			return {"error": "expected integer array index, got '%s'" % last_token}
		var idx: int = last_token.to_int()
		if idx < 0 or idx > arr.size():
			return {"error": "array index out of range: %d (size %d)" % [idx, arr.size()]}
		# RFC 6902 'add' on an array INSERTS rather than overwrites.
		arr.insert(idx, value)
		return {"data": data}
	return {"error": "cannot add inside %s" % _type_label(parent)}

func _patch_remove(data: Variant, path: String) -> Dictionary:
	var del_result: Dictionary = _json_pointer_delete(data, path)
	if del_result.has("error"):
		return del_result
	return {"data": del_result["data"]}

func _patch_replace(data: Variant, path: String, value: Variant) -> Dictionary:
	var parsed: Dictionary = _parse_pointer(path)
	if parsed.has("error"):
		return parsed
	var tokens: Array = parsed["tokens"]
	if tokens.is_empty():
		return {"data": value}
	# Replace requires the target to exist (per RFC 6902 §4.3).
	var get_result: Dictionary = _json_pointer_get(data, path)
	if get_result.has("error"):
		return {"error": "replace target missing: %s" % get_result["error"]}
	return _json_pointer_set(data, path, value)

func _patch_move(data: Variant, from_path: String, to_path: String) -> Dictionary:
	if from_path == to_path:
		return {"data": data}
	# RFC 6902 forbids moving a container into its own child.
	if to_path.begins_with(from_path + "/"):
		return {"error": "cannot move location into one of its children"}
	var get_result: Dictionary = _json_pointer_get(data, from_path)
	if get_result.has("error"):
		return {"error": "move source missing: %s" % get_result["error"]}
	var value: Variant = get_result["value"]
	var del_result: Dictionary = _json_pointer_delete(data, from_path)
	if del_result.has("error"):
		return del_result
	return _patch_add(del_result["data"], to_path, value)

func _patch_copy(data: Variant, from_path: String, to_path: String) -> Dictionary:
	var get_result: Dictionary = _json_pointer_get(data, from_path)
	if get_result.has("error"):
		return {"error": "copy source missing: %s" % get_result["error"]}
	# Duplicate via JSON round-trip so the copy is fully independent of the
	# source. Without this, mutating the copy would mutate the original
	# Dictionary/Array by reference.
	var snapshot: Variant = _clone_json(get_result["value"])
	return _patch_add(data, to_path, snapshot)

func _patch_test(data: Variant, path: String, expected: Variant) -> Dictionary:
	var get_result: Dictionary = _json_pointer_get(data, path)
	if get_result.has("error"):
		return {"error": "test target missing: %s" % get_result["error"]}
	if not _json_equal(get_result["value"], expected):
		return {"error": "test failed: %s != %s" % [
			_summarize_value(get_result["value"]),
			_summarize_value(expected),
		]}
	return {"data": data}

func _clone_json(value: Variant) -> Variant:
	# JSON-shaped values round-trip cleanly through stringify/parse.
	if value == null:
		return null
	if value is Dictionary or value is Array:
		var encoded: String = JSON.stringify(value)
		return JSON.parse_string(encoded)
	return value

#endregion

#region Deep merge + diff + structural equality

func _deep_merge(a: Variant, b: Variant) -> Variant:
	# Maps merge key-by-key; values that are both maps recurse, otherwise
	# b wins. Arrays and primitives are replaced wholesale by b - this is
	# the convention most save-file merges expect and matches Mozilla's
	# Object.assign semantics rather than JSON Merge Patch (RFC 7396 would
	# also wipe arrays element-wise, which is rarely what callers want).
	if a is Dictionary and b is Dictionary:
		var out: Dictionary = (a as Dictionary).duplicate(true)
		for key in (b as Dictionary).keys():
			if out.has(key):
				out[key] = _deep_merge(out[key], (b as Dictionary)[key])
			else:
				out[key] = (b as Dictionary)[key]
		return out
	return b

func _collect_diff(a: Variant, b: Variant, path: String, out: Array[String]) -> void:
	# Produces lines like:
	#   + /foo/bar    (added in b)
	#   - /foo/baz    (removed in b)
	#   ~ /foo/x      old → new   (changed)
	var display_path: String = path if path != "" else "/"
	if typeof(a) != typeof(b):
		out.append("%s %s   %s -> %s" % [
			_color_change("~"),
			_color_path(display_path),
			_summarize_value(a),
			_summarize_value(b),
		])
		return
	if a is Dictionary:
		var da: Dictionary = a
		var db: Dictionary = b
		var keys: Dictionary = {}
		for k in da.keys():
			keys[k] = true
		for k in db.keys():
			keys[k] = true
		var sorted_keys: Array = keys.keys()
		sorted_keys.sort()
		for k in sorted_keys:
			var sub_path: String = path + "/" + _escape_pointer_segment(str(k))
			if da.has(k) and not db.has(k):
				out.append("%s %s   %s" % [
					_color_remove("-"),
					_color_path(sub_path),
					_summarize_value(da[k]),
				])
			elif db.has(k) and not da.has(k):
				out.append("%s %s   %s" % [
					_color_add("+"),
					_color_path(sub_path),
					_summarize_value(db[k]),
				])
			else:
				_collect_diff(da[k], db[k], sub_path, out)
		return
	if a is Array:
		var aa: Array = a
		var ba: Array = b
		var max_len: int = max(aa.size(), ba.size())
		for i in range(max_len):
			var sub_path: String = path + "/" + str(i)
			if i >= aa.size():
				out.append("%s %s   %s" % [
					_color_add("+"),
					_color_path(sub_path),
					_summarize_value(ba[i]),
				])
			elif i >= ba.size():
				out.append("%s %s   %s" % [
					_color_remove("-"),
					_color_path(sub_path),
					_summarize_value(aa[i]),
				])
			else:
				_collect_diff(aa[i], ba[i], sub_path, out)
		return
	if not _json_equal(a, b):
		out.append("%s %s   %s -> %s" % [
			_color_change("~"),
			_color_path(display_path),
			_summarize_value(a),
			_summarize_value(b),
		])

func _json_equal(a: Variant, b: Variant) -> bool:
	# RFC 6902 §4.6 specifies structural (deep) equality for 'test'. Stringify
	# is a cheap deep-equality oracle for JSON-shaped data, though it only
	# works because object key order is preserved by GDScript dictionaries.
	if a == null and b == null:
		return true
	if typeof(a) != typeof(b):
		return false
	if a is Dictionary or a is Array:
		return JSON.stringify(a) == JSON.stringify(b)
	return a == b

func _escape_pointer_segment(segment: String) -> String:
	# Inverse of _unescape_pointer_segment for diff output paths. Order
	# matters: encode '~' before '/' so a literal '/' doesn't get its
	# replacement '~1' re-escaped to '~01'.
	var s: String = segment.replace("~", "~0")
	return s.replace("/", "~1")

#endregion

#region Schema validation (tiny JSON Schema subset)

func _schema_check(value: Variant, schema: Dictionary, path: String, errors: Array[String]) -> void:
	var display_path: String = path if path != "" else "/"

	if schema.has("type"):
		var allowed: Array = []
		var schema_type: Variant = schema["type"]
		if schema_type is Array:
			for t in schema_type:
				allowed.append(str(t))
		else:
			allowed.append(str(schema_type))
		if not _matches_any_type(value, allowed):
			errors.append("  %s: expected type %s, got %s" % [
				_color_path(display_path),
				str(allowed),
				_schema_type_of(value),
			])
			# Type mismatch means subsequent checks (properties, items, etc.)
			# are not meaningful, so bail early for this node.
			return

	if schema.has("enum"):
		var allowed_vals: Array = schema["enum"]
		var found: bool = false
		for candidate in allowed_vals:
			if _json_equal(value, candidate):
				found = true
				break
		if not found:
			errors.append("  %s: value %s not in enum" % [
				_color_path(display_path),
				_summarize_value(value),
			])

	if (value is int or value is float) and not (value is bool):
		var num: float = float(value)
		if schema.has("minimum") and num < float(schema["minimum"]):
			errors.append("  %s: %s < minimum %s" % [
				_color_path(display_path),
				str(num),
				str(schema["minimum"]),
			])
		if schema.has("maximum") and num > float(schema["maximum"]):
			errors.append("  %s: %s > maximum %s" % [
				_color_path(display_path),
				str(num),
				str(schema["maximum"]),
			])

	if value is String:
		var sv: String = value
		if schema.has("minLength") and sv.length() < int(schema["minLength"]):
			errors.append("  %s: length %d < minLength %d" % [
				_color_path(display_path),
				sv.length(),
				int(schema["minLength"]),
			])
		if schema.has("maxLength") and sv.length() > int(schema["maxLength"]):
			errors.append("  %s: length %d > maxLength %d" % [
				_color_path(display_path),
				sv.length(),
				int(schema["maxLength"]),
			])

	if value is Array:
		var arr: Array = value
		if schema.has("minItems") and arr.size() < int(schema["minItems"]):
			errors.append("  %s: %d items < minItems %d" % [
				_color_path(display_path),
				arr.size(),
				int(schema["minItems"]),
			])
		if schema.has("maxItems") and arr.size() > int(schema["maxItems"]):
			errors.append("  %s: %d items > maxItems %d" % [
				_color_path(display_path),
				arr.size(),
				int(schema["maxItems"]),
			])
		if schema.has("items") and schema["items"] is Dictionary:
			var item_schema: Dictionary = schema["items"]
			for i in range(arr.size()):
				_schema_check(arr[i], item_schema, path + "/" + str(i), errors)

	if value is Dictionary:
		var d: Dictionary = value
		if schema.has("required") and schema["required"] is Array:
			for req in (schema["required"] as Array):
				var req_key: String = str(req)
				if not d.has(req_key):
					errors.append("  %s: missing required key '%s'" % [
						_color_path(display_path),
						req_key,
					])
		if schema.has("properties") and schema["properties"] is Dictionary:
			var props: Dictionary = schema["properties"]
			for pk in props.keys():
				if d.has(pk) and props[pk] is Dictionary:
					_schema_check(d[pk], props[pk], path + "/" + _escape_pointer_segment(str(pk)), errors)

func _matches_any_type(value: Variant, allowed: Array) -> bool:
	for t in allowed:
		if _matches_schema_type(value, str(t)):
			return true
	return false

func _matches_schema_type(value: Variant, schema_type: String) -> bool:
	match schema_type:
		"null": return value == null
		"boolean": return value is bool
		# 'integer' must reject floats with fractional parts; GDScript JSON
		# parses 100 as float when there's a decimal point, so we accept both
		# representations as long as the value is a whole number.
		"integer":
			if value is int and not (value is bool):
				return true
			if value is float:
				var f: float = value
				return f == floor(f)
			return false
		"number": return (value is int or value is float) and not (value is bool)
		"string": return value is String or value is StringName
		"array": return value is Array
		"object": return value is Dictionary
		_: return false

func _schema_type_of(value: Variant) -> String:
	if value == null: return "null"
	if value is bool: return "boolean"
	if value is int: return "integer"
	if value is float:
		var f: float = value
		return "integer" if f == floor(f) else "number"
	if value is String or value is StringName: return "string"
	if value is Array: return "array"
	if value is Dictionary: return "object"
	return _type_label(value)

func _walk_stats(value: Variant, depth: int, stats: Dictionary) -> void:
	if depth > int(stats["max_depth"]):
		stats["max_depth"] = depth
	if value is Dictionary:
		stats["objects"] = int(stats["objects"]) + 1
		for k in (value as Dictionary).keys():
			_walk_stats((value as Dictionary)[k], depth + 1, stats)
		return
	if value is Array:
		stats["arrays"] = int(stats["arrays"]) + 1
		for entry in (value as Array):
			_walk_stats(entry, depth + 1, stats)
		return
	stats["leaves"] = int(stats["leaves"]) + 1

#endregion

#region File I/O helpers

func _read_json_file(path: String) -> Dictionary:
	# Returns {"data": Variant} or {"error": String}. Distinguishes the
	# literal "null" document from a parse failure by also inspecting the
	# stripped text, the same way DataCommands._cmd_json_read does.
	if not FileAccess.file_exists(path):
		return {"error": "File not found: %s" % path}
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if not file:
		return {"error": "Failed to open: %s (err %d)" % [path, FileAccess.get_open_error()]}
	var text: String = file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	if parsed == null and text.strip_edges() != "null":
		return {"error": "Invalid JSON in %s" % path}
	return {"data": parsed}

func _write_json_file(path: String, data: Variant) -> String:
	# Returns "" on success or an error message. Uses the same two-space
	# indent as DataCommands._cmd_json_write so files round-trip cleanly
	# across the json_* command family.
	var serialized: String = JSON.stringify(data, "  ")
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if not file:
		return "Failed to open for write: %s (err %d)" % [path, FileAccess.get_open_error()]
	file.store_string(serialized)
	file.close()
	return ""

#endregion

#region Value parsing + path helpers

func _stringify_args(slice_args: Array) -> Array:
	var out: Array = []
	for a in slice_args:
		out.append(str(a))
	return out

func _parse_value(raw: String) -> Variant:
	# JSON literal first (so `{"hp":100}` and `[1,2,3]` round-trip exactly),
	# then a small set of primitives (null/true/false/int/float), finally
	# a quoted or bare string. The JSON.parse_string return value of null
	# is ambiguous with parse failure, so we re-check the raw text.
	var s: String = raw.strip_edges()
	if s.is_empty():
		return ""
	var parsed: Variant = JSON.parse_string(s)
	if parsed != null or s == "null":
		return parsed
	if s == "true":
		return true
	if s == "false":
		return false
	if (s.begins_with("\"") and s.ends_with("\"")) or (s.begins_with("'") and s.ends_with("'")):
		return s.substr(1, s.length() - 2)
	if s.is_valid_int():
		return s.to_int()
	if s.is_valid_float():
		return s.to_float()
	return s

func _normalize_path(path: String) -> String:
	# Mirrors DataCommands._normalize_path: protocol-prefixed paths pass
	# through; bare names resolve to res:// in the editor and user:// at
	# runtime so the same command works in both contexts.
	var p: String = path.strip_edges()
	if p.is_empty():
		return ""
	if p.begins_with("res://") or p.begins_with("user://"):
		return p
	if Engine.is_editor_hint():
		return "res://".path_join(p)
	return "user://".path_join(p)

func _summarize_value(value: Variant) -> String:
	# Used for diff/test/set output - aims to fit on one line. Long
	# containers are truncated rather than dumped wholesale.
	if value == null:
		return "null"
	if value is bool:
		return "true" if value else "false"
	if value is String or value is StringName:
		return "\"%s\"" % str(value)
	if value is Dictionary or value is Array:
		var encoded: String = JSON.stringify(value)
		if encoded.length() > 60:
			return encoded.substr(0, 57) + "..."
		return encoded
	return str(value)

func _stringify_value(v: Variant) -> String:
	if v == null:
		return "null"
	if v is bool:
		return "true" if v else "false"
	if v is String or v is StringName:
		return str(v)
	if v is int or v is float:
		return str(v)
	return JSON.stringify(v)

func _type_label(v: Variant) -> String:
	if v == null: return "null"
	if v is bool: return "bool"
	if v is int: return "int"
	if v is float: return "float"
	if v is String or v is StringName: return "string"
	if v is Array: return "array"
	if v is Dictionary: return "object"
	return "Variant(%d)" % typeof(v)

#endregion

#region Formatting helpers

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_num(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

func _color_add(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, s]

func _color_remove(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_ERROR, s]

func _color_change(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

#endregion

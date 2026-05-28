@tool
class_name DebugConsoleXPathCommands extends RefCounted

# CSS/XPath-style selectors for scene tree search. More expressive than
# `find_node`'s glob: combines type, name, group, and attribute predicates,
# plus descendant (` `) and direct-child (`>`) combinators. Ships as a
# standalone extension following the SceneCommands.gd pattern - the
# orchestrator instantiates one of these, holds a strong reference, and
# calls register_commands(registry, core). All commands route through that
# strong-referenced instance so their Callables stay valid for the lifetime
# of the plugin.
#
# Selector grammar (compact):
#   Atom        := Class | "#" Name | "." Group | "[" AttrExpr "]"
#   Compound    := Atom+               (no whitespace between atoms)
#   Step        := Compound
#   Selector    := Step ( (" " | " > ") Step )*
#   AttrExpr    := dotted.path Op Value | dotted.path
#   Op          := "=" | "!=" | "<" | ">" | "<=" | ">=" | "~="
#
# `Class` matches via Node.get_class(), Node.is_class() (covers parents), and
# script `class_name` (walking the script chain). Attribute paths support
# nested access into built-in math types (Vector2/3/4, Color, Rect2).

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_MUTED := "#888888"

const _DEFAULT_LIMIT := 200

var _registry: Node
var _core: Node

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("xpath", _cmd_xpath, "CSS/XPath-style scene search: xpath <selector>  (e.g. CharacterBody3D#Player[position.y>5])", "both")
	_registry.register_command("xpath_count", _cmd_xpath_count, "Count nodes matching an xpath selector: xpath_count <selector>", "both")
	_registry.register_command("xpath_first", _cmd_xpath_first, "Return only the first match: xpath_first <selector>", "both")
	_registry.register_command("xpath_apply", _cmd_xpath_apply, "Run a command for each match; '{}' is substituted with the node path: xpath_apply <selector> -- <command_template>", "both")
	_registry.register_command("xpath_help", _cmd_xpath_help, "Show xpath selector syntax and examples: xpath_help", "both")
	_registry.register_command("xpath_test", _cmd_xpath_test, "Does this node match the selector? xpath_test <node_path> <selector>", "both")

#region Command implementations

func _cmd_xpath(args: Array, _piped_input: String = "") -> String:
	var sel := _join_args(args)
	if sel.is_empty():
		return _format_error("Usage: xpath <selector>   (try 'xpath_help')")
	var parsed := _parse_selector(sel)
	if parsed.is_empty():
		return _format_error("Could not parse selector: %s" % sel)
	var matches := _xpath_search(_get_scene_root(), parsed, _DEFAULT_LIMIT)
	if matches.is_empty():
		return "No matches for %s" % sel
	var lines: Array[String] = []
	var header: String = "%s match(es) for %s:" % [_color_number(str(matches.size())), sel]
	if matches.size() >= _DEFAULT_LIMIT:
		header += "  (limit reached)"
	lines.append(header)
	for n in matches:
		lines.append("  %s [%s]" % [_color_path(_path_of(n)), (n as Node).get_class()])
	return "\n".join(lines)

func _cmd_xpath_count(args: Array, _piped_input: String = "") -> String:
	var sel := _join_args(args)
	if sel.is_empty():
		return _format_error("Usage: xpath_count <selector>")
	var parsed := _parse_selector(sel)
	if parsed.is_empty():
		return _format_error("Could not parse selector: %s" % sel)
	var matches := _xpath_search(_get_scene_root(), parsed, _DEFAULT_LIMIT)
	var suffix: String = "  (limit reached, true count may be higher)" if matches.size() >= _DEFAULT_LIMIT else ""
	return "%s match(es) for %s%s" % [_color_number(str(matches.size())), sel, suffix]

func _cmd_xpath_first(args: Array, _piped_input: String = "") -> String:
	var sel := _join_args(args)
	if sel.is_empty():
		return _format_error("Usage: xpath_first <selector>")
	var parsed := _parse_selector(sel)
	if parsed.is_empty():
		return _format_error("Could not parse selector: %s" % sel)
	var matches := _xpath_search(_get_scene_root(), parsed, 1)
	if matches.is_empty():
		return "No matches for %s" % sel
	var n: Node = matches[0]
	return "%s [%s]" % [_color_path(_path_of(n)), n.get_class()]

func _cmd_xpath_apply(args: Array, _piped_input: String = "") -> String:
	# Split args around the "--" delimiter so selectors with spaces are unambiguous.
	var split_at: int = -1
	for i in range(args.size()):
		if str(args[i]) == "--":
			split_at = i
			break
	if split_at <= 0 or split_at >= args.size() - 1:
		return _format_error("Usage: xpath_apply <selector> -- <command_template>  ({} is replaced with the node path)")
	var sel_parts: Array = []
	for i in range(split_at):
		sel_parts.append(args[i])
	var sel := _join_args(sel_parts)
	var template_parts: Array = []
	for i in range(split_at + 1, args.size()):
		template_parts.append(str(args[i]))
	var template: String = " ".join(template_parts).strip_edges()
	if sel.is_empty() or template.is_empty():
		return _format_error("Usage: xpath_apply <selector> -- <command_template>")
	if not "{}" in template:
		return _format_error("Command template must contain '{}' as the substitution placeholder")
	if not _registry or not _registry.has_method("execute_command"):
		return _format_error("Registry does not support execute_command; cannot apply")

	var parsed := _parse_selector(sel)
	if parsed.is_empty():
		return _format_error("Could not parse selector: %s" % sel)
	var matches := _xpath_search(_get_scene_root(), parsed, _DEFAULT_LIMIT)
	if matches.is_empty():
		return "No matches for %s" % sel

	var lines: Array[String] = []
	lines.append("Applying to %s match(es):" % _color_number(str(matches.size())))
	for n in matches:
		var path: String = _path_of(n)
		var cmd: String = template.replace("{}", path)
		var output: Variant = _registry.call("execute_command", cmd)
		lines.append("[color=%s]> %s[/color]" % [_COLOR_MUTED, cmd])
		lines.append(str(output))
	return "\n".join(lines)

func _cmd_xpath_help(_args: Array, _piped_input: String = "") -> String:
	var lines: Array[String] = []
	lines.append("%s - selector syntax:" % _color_path("xpath"))
	lines.append("  %-26s match by class name (built-in, parent classes, or script class_name)" % "Class")
	lines.append("  %-26s match by node name" % "#NodeName")
	lines.append("  %-26s match by group membership" % ".group_name")
	lines.append("  %-26s attribute predicate; op in = != < > <= >= ~= (contains)" % "[prop OP value]")
	lines.append("  %-26s dotted path supported: [position.y>5], [global_transform.origin.x<0]" % "[a.b.c=v]")
	lines.append("  %-26s direct child combinator" % "A > B")
	lines.append("  %-26s descendant combinator (any depth)" % "A B")
	lines.append("")
	lines.append("Atoms with no whitespace form a compound (same element):")
	lines.append("  %s" % _color_path("CharacterBody3D#Player[position.y>5]"))
	lines.append("")
	lines.append("Examples:")
	lines.append("  %s" % _color_path("xpath Node3D"))
	lines.append("  %s" % _color_path("xpath #Player"))
	lines.append("  %s" % _color_path("xpath .enemies"))
	lines.append("  %s" % _color_path("xpath Button[disabled=false]"))
	lines.append("  %s" % _color_path("xpath Node3D > Sprite3D"))
	lines.append("  %s" % _color_path("xpath Level Enemy[hp<10]"))
	lines.append("  %s" % _color_path("xpath_apply .enemies -- delete_node {}"))
	return "\n".join(lines)

func _cmd_xpath_test(args: Array, _piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: xpath_test <node_path> <selector>")
	var path: String = str(args[0]).strip_edges()
	var sel_parts: Array = []
	for i in range(1, args.size()):
		sel_parts.append(args[i])
	var sel := _join_args(sel_parts)
	if sel.is_empty():
		return _format_error("Usage: xpath_test <node_path> <selector>")
	var node := _resolve_node(path)
	if not node:
		return _format_error("Node not found: %s" % path)
	var parsed := _parse_selector(sel)
	if parsed.is_empty():
		return _format_error("Could not parse selector: %s" % sel)
	# Compound-only test (single step): check node itself.
	# Multi-step test: walk ancestors / descendants to verify the chain ends at `node`.
	var ok := _node_matches_full(node, parsed)
	if ok:
		return _format_success("MATCH: %s satisfies %s" % [_color_path(_path_of(node)), sel])
	return "[color=%s]NO MATCH: %s does not satisfy %s[/color]" % [_COLOR_MUTED, _color_path(_path_of(node)), sel]

#endregion

#region Selector parser

func _parse_selector(sel: String) -> Array:
	# Returns Array[Dictionary] where each dict is a step:
	#   {"combinator": "descendant"|"child", "atoms": Array[Dictionary]}
	# Each atom is {"kind": "class"|"name"|"group"|"attr", "value": String}.
	var steps: Array = []
	var current: Dictionary = {"combinator": "descendant", "atoms": []}
	var i: int = 0
	var n: int = sel.length()
	while i < n:
		var ch: String = sel[i]
		if ch == " " or ch == "\t":
			# Skip whitespace; if more atoms follow without a `>`, it starts a new descendant step.
			while i < n and (sel[i] == " " or sel[i] == "\t"):
				i += 1
			if i >= n:
				break
			if sel[i] == ">":
				continue # let the next iteration consume `>`
			if not current.atoms.is_empty():
				steps.append(current)
				current = {"combinator": "descendant", "atoms": []}
			continue
		if ch == ">":
			if not current.atoms.is_empty():
				steps.append(current)
			current = {"combinator": "child", "atoms": []}
			i += 1
			while i < n and (sel[i] == " " or sel[i] == "\t"):
				i += 1
			continue
		if ch == "#":
			var j: int = i + 1
			while j < n and not _is_atom_sep(sel[j]):
				j += 1
			current.atoms.append({"kind": "name", "value": sel.substr(i + 1, j - i - 1)})
			i = j
			continue
		if ch == ".":
			var j: int = i + 1
			while j < n and not _is_atom_sep(sel[j]):
				j += 1
			current.atoms.append({"kind": "group", "value": sel.substr(i + 1, j - i - 1)})
			i = j
			continue
		if ch == "[":
			var j: int = sel.find("]", i + 1)
			if j == -1:
				return [] # unterminated bracket
			current.atoms.append({"kind": "attr", "value": sel.substr(i + 1, j - i - 1)})
			i = j + 1
			continue
		# Class identifier: consume up to the next atom separator.
		var jc: int = i
		while jc < n and not _is_atom_sep(sel[jc]):
			jc += 1
		var ident: String = sel.substr(i, jc - i)
		if ident.is_empty():
			return []
		current.atoms.append({"kind": "class", "value": ident})
		i = jc
	if not current.atoms.is_empty():
		steps.append(current)
	return steps

func _is_atom_sep(c: String) -> bool:
	return c == " " or c == "\t" or c == ">" or c == "#" or c == "." or c == "["

#endregion

#region Matching engine

func _xpath_search(root: Node, steps: Array, limit: int) -> Array:
	var results: Array = []
	if root == null or steps.is_empty():
		return results
	# First step: match root itself plus all descendants (descendant semantics).
	var first: Dictionary = steps[0]
	_walk_descendants_incl_self(root, first.atoms, results, limit)
	if steps.size() == 1:
		return results
	var current: Array = results
	for i in range(1, steps.size()):
		var step: Dictionary = steps[i]
		var next: Array = []
		for src in current:
			if not (src is Node):
				continue
			if step.combinator == "child":
				for c in (src as Node).get_children():
					if next.size() >= limit:
						break
					if _compound_matches(step.atoms, c):
						next.append(c)
			else:
				_walk_descendants(src, step.atoms, next, limit)
			if next.size() >= limit:
				break
		current = next
	return current

func _walk_descendants_incl_self(node: Node, atoms: Array, out: Array, limit: int) -> void:
	if out.size() >= limit:
		return
	if _compound_matches(atoms, node):
		out.append(node)
	for c in node.get_children():
		if out.size() >= limit:
			return
		_walk_descendants_incl_self(c, atoms, out, limit)

func _walk_descendants(node: Node, atoms: Array, out: Array, limit: int) -> void:
	for c in node.get_children():
		if out.size() >= limit:
			return
		if _compound_matches(atoms, c):
			out.append(c)
		_walk_descendants(c, atoms, out, limit)

func _compound_matches(atoms: Array, node: Node) -> bool:
	for atom in atoms:
		if not _matches_atom(node, atom):
			return false
	return true

func _matches_atom(node: Node, atom: Dictionary) -> bool:
	var kind: String = atom.kind
	var v: String = str(atom.value)
	match kind:
		"class":
			return _node_is_class(node, v)
		"name":
			return str(node.name) == v
		"group":
			return node.is_in_group(v)
		"attr":
			return _matches_attr(node, v)
	return false

func _node_is_class(node: Node, cls: String) -> bool:
	if node.get_class() == cls:
		return true
	if node.is_class(cls):
		return true
	var script: Script = node.get_script() as Script
	while script != null:
		var gname: StringName = script.get_global_name()
		if gname != StringName() and String(gname) == cls:
			return true
		script = script.get_base_script() as Script
	return false

func _matches_attr(node: Node, expr: String) -> bool:
	# Order matters: longer operators must be tested before their prefixes.
	var ops: Array[String] = ["<=", ">=", "!=", "~=", "=", "<", ">"]
	for op in ops:
		var idx: int = expr.find(op)
		if idx > 0:
			var prop_path: String = expr.substr(0, idx).strip_edges()
			var rhs: String = expr.substr(idx + op.length()).strip_edges()
			var actual: Variant = _get_nested_prop(node, prop_path)
			if actual == null:
				return false
			return _compare(actual, op, rhs)
	# Bare attribute (no operator): truthiness check.
	var actual_v: Variant = _get_nested_prop(node, expr.strip_edges())
	if actual_v == null:
		return false
	if actual_v is bool:
		return actual_v
	if actual_v is int or actual_v is float:
		return actual_v != 0
	if actual_v is String or actual_v is StringName:
		return not str(actual_v).is_empty()
	return true

func _get_nested_prop(obj: Variant, path: String) -> Variant:
	if path.is_empty():
		return null
	var parts: PackedStringArray = path.split(".")
	var cur: Variant = obj
	for p in parts:
		if cur == null:
			return null
		if cur is Object:
			cur = (cur as Object).get(p)
		else:
			cur = _builtin_get(cur, p)
		if cur == null:
			# Distinguish "missing" from "value is 0": only bail if truly null.
			return null
	return cur

func _builtin_get(v: Variant, key: String) -> Variant:
	match typeof(v):
		TYPE_VECTOR2, TYPE_VECTOR2I:
			if key == "x": return v.x
			if key == "y": return v.y
		TYPE_VECTOR3, TYPE_VECTOR3I:
			if key == "x": return v.x
			if key == "y": return v.y
			if key == "z": return v.z
		TYPE_VECTOR4, TYPE_VECTOR4I:
			if key == "x": return v.x
			if key == "y": return v.y
			if key == "z": return v.z
			if key == "w": return v.w
		TYPE_COLOR:
			if key == "r": return v.r
			if key == "g": return v.g
			if key == "b": return v.b
			if key == "a": return v.a
		TYPE_RECT2, TYPE_RECT2I:
			if key == "position": return v.position
			if key == "size": return v.size
			if key == "end": return v.end
		TYPE_TRANSFORM2D:
			if key == "origin": return v.origin
			if key == "x": return v.x
			if key == "y": return v.y
		TYPE_TRANSFORM3D:
			if key == "origin": return v.origin
			if key == "basis": return v.basis
		TYPE_DICTIONARY:
			return (v as Dictionary).get(key)
	return null

func _compare(actual: Variant, op: String, rhs: String) -> bool:
	var actual_str: String = str(actual)
	if op == "~=":
		return actual_str.findn(rhs) != -1
	# Try numeric comparison first if actual is numeric and rhs parses as number.
	if (actual is float or actual is int) and rhs.is_valid_float():
		var a: float = float(actual)
		var b: float = float(rhs)
		match op:
			"=": return a == b
			"!=": return a != b
			"<": return a < b
			">": return a > b
			"<=": return a <= b
			">=": return a >= b
	# Bool comparison: accept true/false/1/0 on rhs.
	if actual is bool:
		var b_bool: bool = (rhs == "true" or rhs == "1")
		match op:
			"=": return actual == b_bool
			"!=": return actual != b_bool
	# Fall back to string comparison; strip a single layer of quotes from rhs.
	var b_str: String = rhs
	if b_str.length() >= 2 and ((b_str.begins_with("\"") and b_str.ends_with("\"")) or (b_str.begins_with("'") and b_str.ends_with("'"))):
		b_str = b_str.substr(1, b_str.length() - 2)
	match op:
		"=": return actual_str == b_str
		"!=": return actual_str != b_str
		"<": return actual_str < b_str
		">": return actual_str > b_str
		"<=": return actual_str <= b_str
		">=": return actual_str >= b_str
	return false

func _node_matches_full(node: Node, steps: Array) -> bool:
	# Walk steps right-to-left from `node`: the last step's compound must match
	# `node`, then each preceding step must match an ancestor (or direct parent
	# for `>` combinator) of the previously matched node. The first step has
	# combinator "descendant", which we treat as "any ancestor or self".
	if steps.is_empty():
		return false
	var last: Dictionary = steps[steps.size() - 1]
	if not _compound_matches(last.atoms, node):
		return false
	var cursor: Node = node
	for i in range(steps.size() - 2, -1, -1):
		var step: Dictionary = steps[i]
		var next_combinator: String = (steps[i + 1] as Dictionary).combinator
		if next_combinator == "child":
			var parent := cursor.get_parent()
			if parent == null or not _compound_matches(step.atoms, parent):
				return false
			cursor = parent
		else:
			var found: Node = null
			var p := cursor.get_parent()
			while p != null:
				if _compound_matches(step.atoms, p):
					found = p
					break
				p = p.get_parent()
			if found == null:
				return false
			cursor = found
	return true

#endregion

#region Helpers (mirrored from SceneCommands so this module stays self-contained)

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
	if Engine.is_editor_hint():
		var root := _get_scene_root()
		if not root:
			return null
		if p == "/root":
			return root
		if p.begins_with("/root/"):
			p = p.substr(6)
		elif p.begins_with("/"):
			p = p.substr(1)
		if p == root.name:
			return root
		if p.begins_with(root.name + "/"):
			p = p.substr(root.name.length() + 1)
		if p.is_empty():
			return root
		return root.get_node_or_null(p)

	var tree := Engine.get_main_loop() as SceneTree
	if not tree:
		return null
	if p.begins_with("/"):
		return tree.root.get_node_or_null(p)
	var scene: Node = tree.current_scene if tree.current_scene else tree.root
	return scene.get_node_or_null(p)

func _path_of(node: Node) -> String:
	if not is_instance_valid(node):
		return "<freed>"
	return str(node.get_path()) if node.is_inside_tree() else str(node.name)

func _join_args(args: Array) -> String:
	var parts: Array[String] = []
	for a in args:
		parts.append(str(a))
	return " ".join(parts).strip_edges()

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_path(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, s]

func _color_number(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, s]

#endregion

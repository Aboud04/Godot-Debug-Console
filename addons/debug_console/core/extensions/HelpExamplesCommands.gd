@tool
class_name DebugConsoleHelpExamplesCommands extends RefCounted

# Help examples extension. Augments the built-in `help <cmd>` (which only shows
# a one-line description) with a registry of usage examples and "see also"
# cross-references. The orchestrator instantiates one of these, keeps a strong
# reference to it, and calls register_commands(registry, core). All command
# Callables are bound to this instance so they stay valid for the lifetime of
# the plugin.
#
# The extension does not modify the existing `help` command; it ships parallel
# commands (`help_full`, `help_example`, ...) that read the same registry the
# original `help` reads, and layer per-command examples on top.

const _COLOR_ERROR := "#FF4444"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_HEADER := "#5FBEE0"
const _COLOR_DIM := "#888888"
const _COLOR_MATCH := "#F7DC6F"

var _registry: Node
var _core: Node
var _examples: Dictionary[String, Array] = {}
var _see_also: Dictionary[String, Array] = {}

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("help_example", _cmd_help_example, "Register a usage example for a command: help_example <cmd> <example_string>", "both")
	_registry.register_command("help_examples_list", _cmd_help_examples_list, "List registered examples, optionally filtered: help_examples_list [cmd_pattern]", "both")
	_registry.register_command("help_full", _cmd_help_full, "Show description + examples + see_also for a command: help_full <cmd>", "both")
	_registry.register_command("help_see_also", _cmd_help_see_also, "Register a 'see also' cross-reference: help_see_also <cmd> <related_cmd>", "both")
	_registry.register_command("help_load_defaults", _cmd_help_load_defaults, "Preload a curated set of examples for the top 30 commands: help_load_defaults", "both")
	_registry.register_command("help_search", _cmd_help_search, "Search command descriptions and examples for text: help_search <text>", "both")

#region Command implementations

func _cmd_help_example(args: Array, _piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: help_example <cmd> <example_string>")
	var cmd: String = str(args[0]).strip_edges()
	if cmd.is_empty():
		return _format_error("Command name is required")
	var example_parts: Array = args.slice(1)
	var example: String = " ".join(example_parts).strip_edges()
	if example.is_empty():
		return _format_error("Example text is required")

	var list: Array = _examples.get(cmd, [])
	if list.has(example):
		return _format_error("Example already registered for '%s'" % cmd)
	list.append(example)
	_examples[cmd] = list
	return _format_success("Registered example #%d for '%s'" % [list.size(), cmd])

func _cmd_help_examples_list(args: Array, _piped_input: String = "") -> String:
	var pattern: String = str(args[0]).strip_edges() if args.size() > 0 else ""
	if _examples.is_empty():
		return _color_dim("No examples registered. Try 'help_load_defaults' or 'help_example <cmd> <text>'.")

	var cmd_names: Array = _examples.keys()
	cmd_names.sort()

	var lines: Array[String] = []
	var shown_cmds: int = 0
	var shown_examples: int = 0
	for cmd_variant in cmd_names:
		var cmd: String = str(cmd_variant)
		if not pattern.is_empty() and not cmd.match(pattern):
			continue
		var list: Array = _examples.get(cmd, [])
		if list.is_empty():
			continue
		shown_cmds += 1
		lines.append(_color_header(cmd) + _color_dim(" (%d)" % list.size()))
		for example in list:
			lines.append("  " + str(example))
			shown_examples += 1

	if lines.is_empty():
		return _color_dim("No examples match: %s" % pattern)
	lines.append("")
	lines.append(_color_dim("%d command(s), %d example(s)" % [shown_cmds, shown_examples]))
	return "\n".join(lines)

func _cmd_help_full(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: help_full <cmd>")
	var cmd: String = str(args[0]).strip_edges()
	if cmd.is_empty():
		return _format_error("Command name is required")

	var description: String = _lookup_description(cmd)
	if description.is_empty() and not _examples.has(cmd) and not _see_also.has(cmd):
		return _format_error("Unknown command: %s" % cmd)

	var lines: Array[String] = []
	lines.append(_color_header(cmd))
	if not description.is_empty():
		lines.append("  " + description)
	else:
		lines.append("  " + _color_dim("(no description registered)"))

	var examples: Array = _examples.get(cmd, [])
	if not examples.is_empty():
		lines.append("")
		lines.append(_color_header("Examples:"))
		for i in examples.size():
			lines.append("  %d. %s" % [i + 1, str(examples[i])])

	var related: Array = _see_also.get(cmd, [])
	if not related.is_empty():
		lines.append("")
		lines.append(_color_header("See also:"))
		lines.append("  " + ", ".join(_to_string_array(related)))

	return "\n".join(lines)

func _cmd_help_see_also(args: Array, _piped_input: String = "") -> String:
	if args.size() < 2:
		return _format_error("Usage: help_see_also <cmd> <related_cmd>")
	var cmd: String = str(args[0]).strip_edges()
	var related: String = str(args[1]).strip_edges()
	if cmd.is_empty() or related.is_empty():
		return _format_error("Both command names are required")
	if cmd == related:
		return _format_error("Cannot link a command to itself")

	var list: Array = _see_also.get(cmd, [])
	if list.has(related):
		return _format_error("'%s' is already linked to '%s'" % [related, cmd])
	list.append(related)
	_see_also[cmd] = list
	return _format_success("Linked '%s' -> '%s'" % [cmd, related])

func _cmd_help_load_defaults(_args: Array, _piped_input: String = "") -> String:
	var defaults: Dictionary = _curated_defaults()
	var added_examples: int = 0
	var added_links: int = 0
	for cmd_variant in defaults.keys():
		var cmd: String = str(cmd_variant)
		var entry: Dictionary = defaults[cmd]
		var ex_list: Array = entry.get("examples", [])
		if not ex_list.is_empty():
			var current: Array = _examples.get(cmd, [])
			for ex in ex_list:
				var ex_str: String = str(ex)
				if not current.has(ex_str):
					current.append(ex_str)
					added_examples += 1
			_examples[cmd] = current
		var see_list: Array = entry.get("see_also", [])
		if not see_list.is_empty():
			var current_see: Array = _see_also.get(cmd, [])
			for related in see_list:
				var related_str: String = str(related)
				if related_str != cmd and not current_see.has(related_str):
					current_see.append(related_str)
					added_links += 1
			_see_also[cmd] = current_see

	return _format_success("Loaded defaults: %d example(s) and %d 'see also' link(s) across %d command(s)" % [added_examples, added_links, defaults.size()])

func _cmd_help_search(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: help_search <text>")
	var needle: String = " ".join(args).strip_edges().to_lower()
	if needle.is_empty():
		return _format_error("Search text is required")

	var all_commands: Dictionary = _all_commands_dict()
	var matched_names: Array[String] = []
	var matched_lines: Dictionary[String, Array] = {}

	for cmd_variant in all_commands.keys():
		var cmd: String = str(cmd_variant)
		var hits: Array[String] = []
		var description: String = str(all_commands[cmd])
		if description.to_lower().contains(needle):
			hits.append("  desc: " + _highlight(description, needle))
		var examples: Array = _examples.get(cmd, [])
		for ex in examples:
			var ex_str: String = str(ex)
			if ex_str.to_lower().contains(needle):
				hits.append("  ex:   " + _highlight(ex_str, needle))
		if not hits.is_empty():
			matched_names.append(cmd)
			matched_lines[cmd] = hits

	# Examples registered for commands that are not (or no longer) in the
	# registry still get searched so authors can find stale entries.
	for cmd_variant in _examples.keys():
		var cmd: String = str(cmd_variant)
		if all_commands.has(cmd):
			continue
		var hits: Array[String] = []
		for ex in _examples[cmd]:
			var ex_str: String = str(ex)
			if ex_str.to_lower().contains(needle):
				hits.append("  ex:   " + _highlight(ex_str, needle))
		if not hits.is_empty():
			matched_names.append(cmd)
			matched_lines[cmd] = hits

	if matched_names.is_empty():
		return _color_dim("No matches for: %s" % needle)

	matched_names.sort()
	var lines: Array[String] = []
	for cmd in matched_names:
		lines.append(_color_header(cmd))
		for line in matched_lines[cmd]:
			lines.append(line)
	lines.append("")
	lines.append(_color_dim("%d command(s) matched" % matched_names.size()))
	return "\n".join(lines)

#endregion

#region Helpers

func _lookup_description(cmd: String) -> String:
	if not _registry:
		return ""
	if not "_commands" in _registry:
		return ""
	var commands: Dictionary = _registry.get("_commands")
	if not commands.has(cmd):
		return ""
	var data: Dictionary = commands[cmd]
	return str(data.get("description", ""))

func _all_commands_dict() -> Dictionary:
	# Returns {cmd_name: description}. Reads the registry's internal store so
	# the search covers every registered command, not just those with examples.
	var out: Dictionary = {}
	if not _registry or not "_commands" in _registry:
		return out
	var commands: Dictionary = _registry.get("_commands")
	for key in commands.keys():
		var data: Dictionary = commands[key]
		out[str(key)] = str(data.get("description", ""))
	return out

func _to_string_array(arr: Array) -> Array[String]:
	var out: Array[String] = []
	for item in arr:
		out.append(str(item))
	return out

func _highlight(text: String, needle_lower: String) -> String:
	# Wrap each case-insensitive match in a colored span so search hits are
	# visible. We rebuild the string segment-by-segment because BBCode does
	# not support a built-in highlight.
	if needle_lower.is_empty():
		return text
	var lower: String = text.to_lower()
	var out: String = ""
	var i: int = 0
	while i < text.length():
		var idx: int = lower.find(needle_lower, i)
		if idx < 0:
			out += text.substr(i)
			break
		out += text.substr(i, idx - i)
		out += "[color=%s]%s[/color]" % [_COLOR_MATCH, text.substr(idx, needle_lower.length())]
		i = idx + needle_lower.length()
	return out

func _curated_defaults() -> Dictionary:
	# Top 30 commands with one or more concrete usage examples plus a few
	# cross-references. Examples are intentionally short and copy-pastable.
	return {
		"spawn": {
			"examples": [
				"spawn res://scenes/enemy.tscn",
				"spawn res://scenes/pickup.tscn /root/Main/Pickups 5,1,0",
			],
			"see_also": ["instance_scene", "create_node", "delete_node"],
		},
		"instance_scene": {
			"examples": ["instance_scene res://ui/hud.tscn /root/Main/UI"],
			"see_also": ["spawn"],
		},
		"create_node": {
			"examples": [
				"create_node Timer /root/Main GameTimer",
				"create_node Node2D /root/Main Layer",
			],
			"see_also": ["spawn", "delete_node"],
		},
		"delete_node": {
			"examples": ["delete_node /root/Main/Enemy"],
			"see_also": ["create_node", "reparent"],
		},
		"reparent": {
			"examples": ["reparent /root/Main/Foo /root/Main/Container"],
			"see_also": ["create_node", "duplicate_node"],
		},
		"duplicate_node": {
			"examples": ["duplicate_node /root/Main/Enemy Enemy_Copy"],
			"see_also": ["spawn", "reparent"],
		},
		"call": {
			"examples": [
				"call /root/Main/Player.move_to 10,0,5",
				"call /root/Main.queue_redraw",
			],
			"see_also": ["methods", "signal_emit"],
		},
		"methods": {
			"examples": ["methods /root/Main/Player", "methods /root/Main/Player -a"],
			"see_also": ["call", "class_db"],
		},
		"class_db": {
			"examples": ["class_db CharacterBody3D"],
			"see_also": ["methods", "create_node"],
		},
		"signal_emit": {
			"examples": ["signal_emit /root/Main/Bus.score_changed 100"],
			"see_also": ["signal_connect", "signal_disconnect"],
		},
		"signal_connect": {
			"examples": ["signal_connect /root/Main/Btn.pressed /root/Main.on_pressed"],
			"see_also": ["signal_emit", "signal_disconnect"],
		},
		"signal_disconnect": {
			"examples": ["signal_disconnect /root/Main/Btn.pressed /root/Main.on_pressed"],
			"see_also": ["signal_connect"],
		},
		"tween": {
			"examples": [
				"tween /root/Main/Sprite.modulate:a 1 0 0.5",
				"tween /root/Main/Node3D.position 0,0,0 0,5,0 1.0 sine in_out",
			],
			"see_also": ["call"],
		},
		"find_node": {
			"examples": ["find_node Enemy*", "find_node *Spawner* /root/Main"],
			"see_also": ["count_nodes"],
		},
		"count_nodes": {
			"examples": ["count_nodes", "count_nodes /root/Main/Enemies"],
			"see_also": ["find_node"],
		},
		"eval": {
			"examples": [
				"eval 1 + 2 * 3",
				"eval Vector3(1,2,3).length()",
			],
			"see_also": ["exec", "call"],
		},
		"exec": {
			"examples": ["exec print(Engine.get_frames_per_second())"],
			"see_also": ["eval", "call"],
		},
		"watch": {
			"examples": [
				"watch /root/Main/Player.position",
				"watch /root/Main/Game.score",
			],
			"see_also": ["unwatch", "watch_list"],
		},
		"unwatch": {
			"examples": ["unwatch /root/Main/Player.position"],
			"see_also": ["watch"],
		},
		"watch_list": {
			"examples": ["watch_list"],
			"see_also": ["watch"],
		},
		"perf": {
			"examples": ["perf", "perf fps", "perf memory"],
			"see_also": ["fps", "perf_snapshot"],
		},
		"fps": {
			"examples": ["fps"],
			"see_also": ["perf"],
		},
		"ui_panel": {
			"examples": [
				"ui_panel show errors",
				"ui_panel toggle perf",
			],
			"see_also": ["ui_map", "screenshot"],
		},
		"ui_map": {
			"examples": ["ui_map", "ui_map brief"],
			"see_also": ["ui_panel"],
		},
		"screenshot": {
			"examples": ["screenshot", "screenshot user://shot.png"],
			"see_also": ["ui_panel"],
		},
		"log": {
			"examples": ["log info hello world", "log error something broke"],
			"see_also": ["clear", "history"],
		},
		"clear": {
			"examples": ["clear"],
			"see_also": ["history"],
		},
		"history": {
			"examples": ["history", "history 20"],
			"see_also": ["clear", "alias"],
		},
		"alias": {
			"examples": [
				"alias ll \"find_node * /root/Main\"",
				"alias gg \"perf | grep fps\"",
			],
			"see_also": ["help"],
		},
		"help": {
			"examples": ["help", "help spawn"],
			"see_also": ["help_full", "help_search", "help_examples_list"],
		},
	}

func _format_error(msg: String) -> String:
	return "[color=%s]Error: %s[/color]" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _color_header(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_HEADER, s]

func _color_dim(s: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_DIM, s]

#endregion

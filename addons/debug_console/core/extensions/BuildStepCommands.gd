@tool
class_name DebugConsoleBuildStepCommands extends RefCounted

# Build-step pipeline extension. Mirrors the structure of the other extensions
# under addons/debug_console/core/extensions/: the orchestrator instantiates one
# of these, holds a strong reference to it, and calls
# register_commands(registry, core). All commands route through the
# strong-referenced instance so the bound Callables stay valid for the lifetime
# of the plugin.
#
# A "pipeline" is an ordered list of named phases. Each phase is just a console
# command string that the pipeline runs via _registry.execute_command(). The
# pipeline records per-phase status (ok/fail), duration, and the captured
# output. In --strict mode `phase_run` aborts at the first failing phase;
# otherwise it runs every phase and reports the full table at the end.
#
# Failure detection: a phase is considered failed when its result starts with
# the same `[color=#FF4444]Error:` marker the other extensions emit through
# their `_format_error` helper. That is the only signal the registry exposes
# uniformly across commands, so it is the contract this module relies on.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_MUTED := "#888888"
const _COLOR_WARN := "#E0C060"

const PIPELINE_CONFIG_PATH := "user://pipelines.cfg"
const PIPELINE_CONFIG_SECTION := "pipelines"

const _ERROR_MARKER := "[color=%s]Error:" % _COLOR_ERROR

var _registry: Node
var _core: Node

# pipeline_name -> Array of { "name": String, "command": String } (insertion order).
var _pipelines: Dictionary = {}

# Last run report. Cleared at the start of every `phase_run`.
# {
#   "pipeline": String,
#   "strict": bool,
#   "started_at": int (unix seconds),
#   "total_ms": float,
#   "aborted": bool,
#   "phases": Array of {
#       "name": String, "command": String, "status": "ok"|"fail"|"skipped",
#       "duration_ms": float, "output": String
#   }
# }
var _last_report: Dictionary = {}

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return

	_registry.register_command("phase_def", _cmd_phase_def, "Register a phase in a pipeline: phase_def <pipeline> <phase> <command...>", "both")
	_registry.register_command("phase_run", _cmd_phase_run, "Run all phases of a pipeline in order: phase_run <pipeline> [--strict]", "both")
	_registry.register_command("phase_list", _cmd_phase_list, "List pipelines, or phases of one: phase_list [pipeline]", "both")
	_registry.register_command("phase_remove", _cmd_phase_remove, "Remove a pipeline or one of its phases: phase_remove <pipeline> [phase|all]", "both")
	_registry.register_command("phase_save", _cmd_phase_save, "Save pipelines to user://pipelines.cfg", "both")
	_registry.register_command("phase_load", _cmd_phase_load, "Load pipelines from user://pipelines.cfg", "both")
	_registry.register_command("phase_report", _cmd_phase_report, "Show the per-phase status table from the last phase_run", "both")

	_load_pipelines_from_config()

#region Command implementations

func _cmd_phase_def(args: Array, _piped_input: String = "") -> String:
	if args.size() < 3:
		return _format_error("Usage: phase_def <pipeline> <phase> <command...>")
	var pipeline_name := str(args[0]).strip_edges()
	var phase_name := str(args[1]).strip_edges()
	if not _is_valid_identifier(pipeline_name):
		return _format_error("Invalid pipeline name: %s" % pipeline_name)
	if not _is_valid_identifier(phase_name):
		return _format_error("Invalid phase name: %s" % phase_name)

	var command_parts: Array[String] = []
	for i in range(2, args.size()):
		command_parts.append(str(args[i]))
	var command := " ".join(command_parts).strip_edges()
	if command.is_empty():
		return _format_error("Phase command cannot be empty")

	var phases: Array = _pipelines.get(pipeline_name, []) as Array
	var replaced := false
	for entry_variant in phases:
		var entry: Dictionary = entry_variant
		if str(entry.get("name", "")) == phase_name:
			entry["command"] = command
			replaced = true
			break
	if not replaced:
		phases.append({"name": phase_name, "command": command})
	_pipelines[pipeline_name] = phases

	var verb := "Updated" if replaced else "Added"
	return _format_success("%s phase %s in pipeline %s -> %s" % [
		verb,
		_color_path(phase_name),
		_color_path(pipeline_name),
		command,
	])

func _cmd_phase_run(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: phase_run <pipeline> [--strict]")
	if not _registry:
		return _format_error("CommandRegistry is unavailable")

	var pipeline_name := ""
	var strict := false
	for a in args:
		var token := str(a).strip_edges()
		if token == "--strict":
			strict = true
		elif pipeline_name.is_empty():
			pipeline_name = token
	if pipeline_name.is_empty():
		return _format_error("Usage: phase_run <pipeline> [--strict]")
	if not _pipelines.has(pipeline_name):
		return _format_error("Pipeline not found: %s" % pipeline_name)

	var phases: Array = _pipelines.get(pipeline_name, []) as Array
	if phases.is_empty():
		return _format_error("Pipeline has no phases: %s" % pipeline_name)

	_last_report = {
		"pipeline": pipeline_name,
		"strict": strict,
		"started_at": int(Time.get_unix_time_from_system()),
		"total_ms": 0.0,
		"aborted": false,
		"phases": [],
	}

	var lines: Array[String] = []
	lines.append("Running pipeline %s (%s phase(s)%s):" % [
		_color_path(pipeline_name),
		_color_number(str(phases.size())),
		", strict" if strict else "",
	])

	var pipeline_start_us := Time.get_ticks_usec()
	var ok_count := 0
	var fail_count := 0
	var aborted := false
	var phase_index := 0

	for entry_variant in phases:
		var entry: Dictionary = entry_variant
		var phase_name := str(entry.get("name", "?"))
		var command := str(entry.get("command", ""))
		phase_index += 1

		if aborted:
			var skipped_record := {
				"name": phase_name,
				"command": command,
				"status": "skipped",
				"duration_ms": 0.0,
				"output": "",
			}
			(_last_report["phases"] as Array).append(skipped_record)
			lines.append("  [%s] %s %s %s" % [
				_color_number(str(phase_index)),
				_color_warn("SKIP"),
				_color_path(phase_name),
				_color_muted("(aborted earlier)"),
			])
			continue

		var phase_start_us := Time.get_ticks_usec()
		var output: String = _registry.execute_command(command)
		var duration_ms := float(Time.get_ticks_usec() - phase_start_us) / 1000.0
		var failed := _is_error_output(output)
		var status := "fail" if failed else "ok"

		var phase_record := {
			"name": phase_name,
			"command": command,
			"status": status,
			"duration_ms": duration_ms,
			"output": output,
		}
		(_last_report["phases"] as Array).append(phase_record)

		if failed:
			fail_count += 1
			lines.append("  [%s] %s %s %s %s" % [
				_color_number(str(phase_index)),
				_format_status_tag("fail"),
				_color_path(phase_name),
				_color_muted("(%.1f ms)" % duration_ms),
				_color_muted("-> " + command),
			])
			if strict:
				aborted = true
		else:
			ok_count += 1
			lines.append("  [%s] %s %s %s %s" % [
				_color_number(str(phase_index)),
				_format_status_tag("ok"),
				_color_path(phase_name),
				_color_muted("(%.1f ms)" % duration_ms),
				_color_muted("-> " + command),
			])

	var total_ms := float(Time.get_ticks_usec() - pipeline_start_us) / 1000.0
	_last_report["total_ms"] = total_ms
	_last_report["aborted"] = aborted

	var summary := "Pipeline %s: %s ok, %s fail, total %s" % [
		_color_path(pipeline_name),
		_color_number(str(ok_count)),
		_color_number(str(fail_count)),
		_color_muted("%.1f ms" % total_ms),
	]
	if aborted:
		summary += " " + _color_warn("(aborted in strict mode)")
	lines.append(summary)
	if fail_count == 0:
		return _format_success("\n".join(lines))
	return "\n".join(lines)

func _cmd_phase_list(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		if _pipelines.is_empty():
			return "No pipelines configured"
		var names := _pipelines.keys()
		names.sort()
		var out_lines: Array[String] = ["Pipelines (%s):" % _color_number(str(names.size()))]
		for n_variant in names:
			var n := str(n_variant)
			var count := (_pipelines.get(n, []) as Array).size()
			out_lines.append("  %s  %s" % [
				_color_path(n),
				_color_muted("(%d phase%s)" % [count, "" if count == 1 else "s"]),
			])
		return "\n".join(out_lines)

	var pipeline_name := str(args[0]).strip_edges()
	if not _pipelines.has(pipeline_name):
		return _format_error("Pipeline not found: %s" % pipeline_name)
	var phases: Array = _pipelines.get(pipeline_name, []) as Array
	if phases.is_empty():
		return "Pipeline %s has no phases" % _color_path(pipeline_name)
	var lines: Array[String] = ["Pipeline %s (%s phase(s)):" % [
		_color_path(pipeline_name),
		_color_number(str(phases.size())),
	]]
	var idx := 0
	for entry_variant in phases:
		var entry: Dictionary = entry_variant
		idx += 1
		lines.append("  [%s] %s -> %s" % [
			_color_number(str(idx)),
			_color_path(str(entry.get("name", "?"))),
			str(entry.get("command", "")),
		])
	return "\n".join(lines)

func _cmd_phase_remove(args: Array, _piped_input: String = "") -> String:
	if args.is_empty():
		return _format_error("Usage: phase_remove <pipeline> [phase|all]")
	var pipeline_name := str(args[0]).strip_edges()
	if not _pipelines.has(pipeline_name):
		return _format_error("Pipeline not found: %s" % pipeline_name)

	if args.size() == 1 or str(args[1]).strip_edges().to_lower() == "all":
		_pipelines.erase(pipeline_name)
		return _format_success("Removed pipeline %s" % _color_path(pipeline_name))

	var phase_name := str(args[1]).strip_edges()
	var phases: Array = _pipelines.get(pipeline_name, []) as Array
	var removed := false
	for i in range(phases.size()):
		var entry: Dictionary = phases[i]
		if str(entry.get("name", "")) == phase_name:
			phases.remove_at(i)
			removed = true
			break
	if not removed:
		return _format_error("Phase not found in %s: %s" % [pipeline_name, phase_name])
	_pipelines[pipeline_name] = phases
	return _format_success("Removed phase %s from pipeline %s" % [
		_color_path(phase_name),
		_color_path(pipeline_name),
	])

func _cmd_phase_save(_args: Array, _piped_input: String = "") -> String:
	var err := _save_pipelines_to_config()
	if err != OK:
		return _format_error("Failed to save (%d): %s" % [err, PIPELINE_CONFIG_PATH])
	return _format_success("Saved %s pipeline(s) to %s" % [
		_color_number(str(_pipelines.size())),
		_color_path(PIPELINE_CONFIG_PATH),
	])

func _cmd_phase_load(_args: Array, _piped_input: String = "") -> String:
	var loaded := _load_pipelines_from_config()
	if loaded < 0:
		return _format_error("Failed to load: %s" % PIPELINE_CONFIG_PATH)
	return _format_success("Loaded %s pipeline(s) from %s" % [
		_color_number(str(loaded)),
		_color_path(PIPELINE_CONFIG_PATH),
	])

func _cmd_phase_report(_args: Array, _piped_input: String = "") -> String:
	if _last_report.is_empty():
		return "No pipeline has been run in this session"
	var pipeline_name := str(_last_report.get("pipeline", "?"))
	var strict := bool(_last_report.get("strict", false))
	var aborted := bool(_last_report.get("aborted", false))
	var total_ms := float(_last_report.get("total_ms", 0.0))
	var phases: Array = _last_report.get("phases", []) as Array

	var ok_count := 0
	var fail_count := 0
	var skip_count := 0
	for entry_variant in phases:
		var entry: Dictionary = entry_variant
		match str(entry.get("status", "")):
			"ok":
				ok_count += 1
			"fail":
				fail_count += 1
			"skipped":
				skip_count += 1

	var lines: Array[String] = []
	lines.append("Last pipeline: %s %s" % [
		_color_path(pipeline_name),
		_color_muted("(strict)" if strict else "(non-strict)"),
	])
	lines.append("Totals: %s ok, %s fail, %s skipped, %s" % [
		_color_number(str(ok_count)),
		_color_number(str(fail_count)),
		_color_number(str(skip_count)),
		_color_muted("%.1f ms total" % total_ms),
	])
	if aborted:
		lines.append(_color_warn("Run was aborted by strict mode"))

	var idx := 0
	for entry_variant in phases:
		var entry: Dictionary = entry_variant
		idx += 1
		var status := str(entry.get("status", "?"))
		lines.append("  [%s] %s %s %s %s" % [
			_color_number(str(idx)),
			_format_status_tag(status),
			_color_path(str(entry.get("name", "?"))),
			_color_muted("(%.1f ms)" % float(entry.get("duration_ms", 0.0))),
			_color_muted("-> " + str(entry.get("command", ""))),
		])
	return "\n".join(lines)

#endregion

#region Helpers

func _is_error_output(output: String) -> bool:
	# Mirrors the `_format_error` convention used across the other extensions:
	# error strings begin with `[color=#FF4444]Error:`.
	return output.begins_with(_ERROR_MARKER)

func _is_valid_identifier(name: String) -> bool:
	if name.is_empty():
		return false
	if name.contains(" ") or name.contains("|") or name.contains("="):
		return false
	return true

#endregion

#region Persistence

# Pipelines are serialized as one config key per pipeline. The value is a
# Variant array of [phase_name, command] pairs, written via
# `var_to_str` so it round-trips through ConfigFile without losing types.
func _save_pipelines_to_config() -> int:
	var config := ConfigFile.new()
	for pipeline_name_variant in _pipelines.keys():
		var pipeline_name := str(pipeline_name_variant)
		var serialized: Array = []
		for entry_variant in (_pipelines.get(pipeline_name, []) as Array):
			var entry: Dictionary = entry_variant
			serialized.append([str(entry.get("name", "")), str(entry.get("command", ""))])
		config.set_value(PIPELINE_CONFIG_SECTION, pipeline_name, serialized)
	return config.save(PIPELINE_CONFIG_PATH)

# Returns the number of pipelines loaded, or -1 on failure. A missing file is
# treated as "nothing to load" and returns 0.
func _load_pipelines_from_config() -> int:
	_pipelines.clear()
	var config := ConfigFile.new()
	var err := config.load(PIPELINE_CONFIG_PATH)
	if err != OK:
		if err == ERR_FILE_NOT_FOUND:
			return 0
		return -1
	if not config.has_section(PIPELINE_CONFIG_SECTION):
		return 0
	var count := 0
	for key in config.get_section_keys(PIPELINE_CONFIG_SECTION):
		var pipeline_name := str(key)
		if not _is_valid_identifier(pipeline_name):
			continue
		var raw: Variant = config.get_value(PIPELINE_CONFIG_SECTION, key, [])
		if not (raw is Array):
			continue
		var phases: Array = []
		for entry_variant in (raw as Array):
			if not (entry_variant is Array) or (entry_variant as Array).size() < 2:
				continue
			var pair: Array = entry_variant
			var phase_name := str(pair[0]).strip_edges()
			var command := str(pair[1]).strip_edges()
			if phase_name.is_empty() or command.is_empty():
				continue
			phases.append({"name": phase_name, "command": command})
		_pipelines[pipeline_name] = phases
		count += 1
	return count

#endregion

#region Formatting helpers

func _format_error(msg: String) -> String:
	return "[color=%s]Error:[/color] %s" % [_COLOR_ERROR, msg]

func _format_success(msg: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_SUCCESS, msg]

func _format_status_tag(status: String) -> String:
	match status:
		"ok":
			return "[color=%s]OK[/color]  " % _COLOR_SUCCESS
		"fail":
			return "[color=%s]FAIL[/color]" % _COLOR_ERROR
		"skipped":
			return "[color=%s]SKIP[/color]" % _COLOR_WARN
		_:
			return "[color=%s]%s[/color]" % [_COLOR_MUTED, status.to_upper()]

func _color_path(text: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_PATH, text]

func _color_number(text: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_NUMBER, text]

func _color_muted(text: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_MUTED, text]

func _color_warn(text: String) -> String:
	return "[color=%s]%s[/color]" % [_COLOR_WARN, text]

#endregion

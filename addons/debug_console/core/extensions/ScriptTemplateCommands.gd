@tool
class_name DebugConsoleScriptTemplateCommands extends RefCounted

# Tier 6 extension - emits common gamedev script scaffolds to disk.
# Follows the standard extension contract documented in
# addons/debug_console/core/extensions/README.md: the orchestrator
# (BuiltInCommands.register_universal_commands) instantiates this module
# via the extensions loader, keeps a strong reference in _t6_keepalive,
# and calls register_commands(registry, core). Commands accept the same
# (args, piped_input) signature used elsewhere and return BBCode strings.
#
# Every command writes a .gd file under res://generated/<name>.gd by
# default. Pass --out=res://path/to/file.gd on any command to override.

const _COLOR_ERROR := "#FF4444"
const _COLOR_PATH := "#5FBEE0"
const _COLOR_SUCCESS := "#A0E0A0"
const _COLOR_NUMBER := "#F7DC6F"

const _DEFAULT_DIR := "res://generated"
const _PLACEHOLDER := "__CLASSNAME__"

var _registry: Node
var _core: Node

func register_commands(registry: Node, core: Node) -> void:
	_registry = registry
	_core = core
	if not _registry:
		return
	_registry.register_command("tpl_player", _cmd_tpl_player, "Emit a CharacterBody player scaffold: tpl_player <name> [2d|3d] [--out=res://...]", "both")
	_registry.register_command("tpl_enemy", _cmd_tpl_enemy, "Emit an enemy scaffold with health: tpl_enemy <name> [2d|3d] [--out=res://...]", "both")
	_registry.register_command("tpl_projectile", _cmd_tpl_projectile, "Emit a projectile scaffold: tpl_projectile <name> [2d|3d] [--out=res://...]", "both")
	_registry.register_command("tpl_pickup", _cmd_tpl_pickup, "Emit an Area pickup scaffold: tpl_pickup <name> [2d|3d] [--out=res://...]", "both")
	_registry.register_command("tpl_state", _cmd_tpl_state, "Emit a FSM state scaffold: tpl_state <name> [--out=res://...]", "both")
	_registry.register_command("tpl_autoload", _cmd_tpl_autoload, "Emit a singleton/autoload scaffold: tpl_autoload <name> [--out=res://...]", "both")
	_registry.register_command("tpl_resource", _cmd_tpl_resource, "Emit a Resource scaffold: tpl_resource <name> [export_props=field:Type=default,...] [--out=res://...]", "both")

#region Command implementations

func _cmd_tpl_player(args: Array, _piped_input: String = "") -> String:
	var parsed: Dictionary = _parse_args(args)
	if not parsed.get("ok", false):
		return _format_error("Usage: tpl_player <name> [2d|3d] [--out=res://path.gd]")
	var name: String = parsed["name"]
	var dim: String = _resolve_dim(parsed.get("dim", "3d"))
	var pascal: String = _to_pascal_case(name)
	var content: String = ""
	if dim == "2d":
		content = _player_2d_template().replace(_PLACEHOLDER, pascal)
	else:
		content = _player_3d_template().replace(_PLACEHOLDER, pascal)
	return _write_and_report(parsed.get("out", _default_path(name)), content, "tpl_player", pascal, dim)

func _cmd_tpl_enemy(args: Array, _piped_input: String = "") -> String:
	var parsed: Dictionary = _parse_args(args)
	if not parsed.get("ok", false):
		return _format_error("Usage: tpl_enemy <name> [2d|3d] [--out=res://path.gd]")
	var name: String = parsed["name"]
	var dim: String = _resolve_dim(parsed.get("dim", "3d"))
	var pascal: String = _to_pascal_case(name)
	var content: String = ""
	if dim == "2d":
		content = _enemy_2d_template().replace(_PLACEHOLDER, pascal)
	else:
		content = _enemy_3d_template().replace(_PLACEHOLDER, pascal)
	return _write_and_report(parsed.get("out", _default_path(name)), content, "tpl_enemy", pascal, dim)

func _cmd_tpl_projectile(args: Array, _piped_input: String = "") -> String:
	var parsed: Dictionary = _parse_args(args)
	if not parsed.get("ok", false):
		return _format_error("Usage: tpl_projectile <name> [2d|3d] [--out=res://path.gd]")
	var name: String = parsed["name"]
	var dim: String = _resolve_dim(parsed.get("dim", "3d"))
	var pascal: String = _to_pascal_case(name)
	var content: String = ""
	if dim == "2d":
		content = _projectile_2d_template().replace(_PLACEHOLDER, pascal)
	else:
		content = _projectile_3d_template().replace(_PLACEHOLDER, pascal)
	return _write_and_report(parsed.get("out", _default_path(name)), content, "tpl_projectile", pascal, dim)

func _cmd_tpl_pickup(args: Array, _piped_input: String = "") -> String:
	var parsed: Dictionary = _parse_args(args)
	if not parsed.get("ok", false):
		return _format_error("Usage: tpl_pickup <name> [2d|3d] [--out=res://path.gd]")
	var name: String = parsed["name"]
	var dim: String = _resolve_dim(parsed.get("dim", "3d"))
	var pascal: String = _to_pascal_case(name)
	var content: String = ""
	if dim == "2d":
		content = _pickup_2d_template().replace(_PLACEHOLDER, pascal)
	else:
		content = _pickup_3d_template().replace(_PLACEHOLDER, pascal)
	return _write_and_report(parsed.get("out", _default_path(name)), content, "tpl_pickup", pascal, dim)

func _cmd_tpl_state(args: Array, _piped_input: String = "") -> String:
	var parsed: Dictionary = _parse_args(args)
	if not parsed.get("ok", false):
		return _format_error("Usage: tpl_state <name> [--out=res://path.gd]")
	var name: String = parsed["name"]
	var pascal: String = _to_pascal_case(name)
	var content: String = _state_template().replace(_PLACEHOLDER, pascal)
	return _write_and_report(parsed.get("out", _default_path(name)), content, "tpl_state", pascal, "")

func _cmd_tpl_autoload(args: Array, _piped_input: String = "") -> String:
	var parsed: Dictionary = _parse_args(args)
	if not parsed.get("ok", false):
		return _format_error("Usage: tpl_autoload <name> [--out=res://path.gd]")
	var name: String = parsed["name"]
	var pascal: String = _to_pascal_case(name)
	var content: String = _autoload_template().replace(_PLACEHOLDER, pascal)
	return _write_and_report(parsed.get("out", _default_path(name)), content, "tpl_autoload", pascal, "")

func _cmd_tpl_resource(args: Array, _piped_input: String = "") -> String:
	var parsed: Dictionary = _parse_args(args)
	if not parsed.get("ok", false):
		return _format_error("Usage: tpl_resource <name> [export_props=field:Type=default,...] [--out=res://path.gd]")
	var name: String = parsed["name"]
	var pascal: String = _to_pascal_case(name)
	var props_spec: String = str(parsed.get("export_props", ""))
	var exports_block: String = _build_export_block(props_spec)
	var content: String = _resource_template().replace(_PLACEHOLDER, pascal).replace("__EXPORTS__", exports_block)
	return _write_and_report(parsed.get("out", _default_path(name)), content, "tpl_resource", pascal, "")

#endregion

#region Argument parsing

# Walks args once collecting flags, the required name (first non-flag token),
# an optional dim token ("2d"/"3d"), and any export_props=... spec. Returns
# {ok: bool, name: String, dim: String, out: String, export_props: String}.
func _parse_args(args: Array) -> Dictionary:
	var result: Dictionary = {"ok": false, "name": "", "dim": "", "out": "", "export_props": ""}
	var positional: Array = []
	for raw in args:
		var token: String = str(raw).strip_edges()
		if token.is_empty():
			continue
		if token.begins_with("--out="):
			result["out"] = token.substr(6).strip_edges()
		elif token.begins_with("out="):
			result["out"] = token.substr(4).strip_edges()
		elif token.begins_with("export_props="):
			result["export_props"] = token.substr(13).strip_edges()
		elif token == "--out" or token == "out":
			# Tolerate "--out PATH" if user splits the flag from the value.
			continue
		else:
			positional.append(token)
	if positional.is_empty():
		return result
	result["name"] = positional[0]
	if positional.size() > 1:
		result["dim"] = positional[1].to_lower()
	result["ok"] = true
	return result

func _resolve_dim(value: String) -> String:
	var v: String = value.to_lower().strip_edges()
	if v == "2d" or v == "2":
		return "2d"
	return "3d"

func _to_pascal_case(name: String) -> String:
	var cleaned: String = name.strip_edges().replace("-", "_").replace(".", "_").replace("/", "_")
	var parts: PackedStringArray = cleaned.split("_", false)
	var out: String = ""
	for part in parts:
		if part.is_empty():
			continue
		out += part.substr(0, 1).to_upper() + part.substr(1)
	if out.is_empty():
		out = "Generated"
	# A class name cannot start with a digit.
	if out[0].is_valid_int():
		out = "_" + out
	return out

func _to_snake_case(name: String) -> String:
	var cleaned: String = name.strip_edges().replace("-", "_").replace(".", "_").replace("/", "_")
	var out: String = ""
	for i in cleaned.length():
		var c: String = cleaned[i]
		if c >= "A" and c <= "Z":
			if i > 0 and out.length() > 0 and out[out.length() - 1] != "_":
				out += "_"
			out += c.to_lower()
		else:
			out += c
	if out.is_empty():
		out = "generated"
	return out

func _default_path(name: String) -> String:
	return "%s/%s.gd" % [_DEFAULT_DIR, _to_snake_case(name)]

#endregion

#region File output

func _write_and_report(out_path: String, content: String, cmd: String, pascal: String, dim: String) -> String:
	var path: String = out_path.strip_edges()
	if path.is_empty():
		return _format_error("Output path resolved to empty string")
	if not path.ends_with(".gd"):
		path += ".gd"
	if not path.begins_with("res://") and not path.begins_with("user://"):
		# Treat bare paths as res:// relative for convenience.
		path = "res://" + path.lstrip("/")
	var dir: String = path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		var mk_err: int = DirAccess.make_dir_recursive_absolute(dir)
		if mk_err != OK:
			return _format_error("Failed to create directory %s (err=%d)" % [dir, mk_err])
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return _format_error("Failed to open %s for writing (err=%d)" % [path, FileAccess.get_open_error()])
	f.store_string(content)
	f.close()
	_maybe_rescan_filesystem()
	var dim_suffix: String = (" [%s]" % dim) if not dim.is_empty() else ""
	return _format_success("%s -> %s (class %s)%s" % [cmd, _color_path(path), _color_number(pascal), dim_suffix])

func _maybe_rescan_filesystem() -> void:
	if not Engine.is_editor_hint():
		return
	if not Engine.has_singleton("EditorInterface"):
		return
	var ei: Object = Engine.get_singleton("EditorInterface")
	if ei == null or not ei.has_method("get_resource_filesystem"):
		return
	var fs: Object = ei.get_resource_filesystem()
	if fs and fs.has_method("scan"):
		fs.call("scan")

#endregion

#region Export prop parser (tpl_resource)

# Parses "health:int=100,name:String,speed:float=5.0" into a block of
# @export var lines with sensible defaults when none is supplied.
func _build_export_block(spec: String) -> String:
	var s: String = spec.strip_edges()
	if s.is_empty():
		return "@export var id: StringName = &\"\"\n"
	var lines: Array[String] = []
	for chunk in s.split(",", false):
		var entry: String = chunk.strip_edges()
		if entry.is_empty():
			continue
		var default_part: String = ""
		var name_type: String = entry
		var eq_idx: int = entry.find("=")
		if eq_idx >= 0:
			name_type = entry.substr(0, eq_idx).strip_edges()
			default_part = entry.substr(eq_idx + 1).strip_edges()
		var field_name: String = name_type
		var type_name: String = "Variant"
		var colon_idx: int = name_type.find(":")
		if colon_idx >= 0:
			field_name = name_type.substr(0, colon_idx).strip_edges()
			type_name = name_type.substr(colon_idx + 1).strip_edges()
		if field_name.is_empty():
			continue
		if type_name.is_empty():
			type_name = "Variant"
		var default_literal: String = default_part if not default_part.is_empty() else _default_for_type(type_name)
		lines.append("@export var %s: %s = %s" % [field_name, type_name, default_literal])
	if lines.is_empty():
		return "@export var id: StringName = &\"\"\n"
	return "\n".join(lines) + "\n"

func _default_for_type(type_name: String) -> String:
	match type_name:
		"int": return "0"
		"float": return "0.0"
		"bool": return "false"
		"String": return "\"\""
		"StringName": return "&\"\""
		"NodePath": return "^\"\""
		"Vector2": return "Vector2.ZERO"
		"Vector2i": return "Vector2i.ZERO"
		"Vector3": return "Vector3.ZERO"
		"Vector3i": return "Vector3i.ZERO"
		"Vector4": return "Vector4.ZERO"
		"Color": return "Color.WHITE"
		"Rect2": return "Rect2()"
		"Rect2i": return "Rect2i()"
		"Transform2D": return "Transform2D.IDENTITY"
		"Transform3D": return "Transform3D.IDENTITY"
		"Basis": return "Basis.IDENTITY"
		"Quaternion": return "Quaternion.IDENTITY"
		"Array": return "[]"
		"Dictionary": return "{}"
		"PackedByteArray": return "PackedByteArray()"
		"PackedInt32Array": return "PackedInt32Array()"
		"PackedFloat32Array": return "PackedFloat32Array()"
		"PackedStringArray": return "PackedStringArray()"
		"PackedVector2Array": return "PackedVector2Array()"
		"PackedVector3Array": return "PackedVector3Array()"
		"PackedColorArray": return "PackedColorArray()"
		_: return "null"

#endregion

#region Templates

func _player_3d_template() -> String:
	return "extends CharacterBody3D\n" + \
		"class_name " + _PLACEHOLDER + "\n\n" + \
		"@export var speed: float = 5.0\n" + \
		"@export var jump_velocity: float = 4.5\n" + \
		"@export var mouse_sensitivity: float = 0.0025\n\n" + \
		"var _gravity: float = ProjectSettings.get_setting(\"physics/3d/default_gravity\", 9.8)\n\n" + \
		"func _physics_process(delta: float) -> void:\n" + \
		"\tif not is_on_floor():\n" + \
		"\t\tvelocity.y -= _gravity * delta\n\n" + \
		"\tif Input.is_action_just_pressed(\"ui_accept\") and is_on_floor():\n" + \
		"\t\tvelocity.y = jump_velocity\n\n" + \
		"\tvar input_dir: Vector2 = Input.get_vector(\"ui_left\", \"ui_right\", \"ui_up\", \"ui_down\")\n" + \
		"\tvar direction: Vector3 = (transform.basis * Vector3(input_dir.x, 0.0, input_dir.y)).normalized()\n" + \
		"\tif direction.length() > 0.0:\n" + \
		"\t\tvelocity.x = direction.x * speed\n" + \
		"\t\tvelocity.z = direction.z * speed\n" + \
		"\telse:\n" + \
		"\t\tvelocity.x = move_toward(velocity.x, 0.0, speed)\n" + \
		"\t\tvelocity.z = move_toward(velocity.z, 0.0, speed)\n\n" + \
		"\tmove_and_slide()\n"

func _player_2d_template() -> String:
	return "extends CharacterBody2D\n" + \
		"class_name " + _PLACEHOLDER + "\n\n" + \
		"@export var speed: float = 300.0\n" + \
		"@export var jump_velocity: float = -400.0\n\n" + \
		"var _gravity: float = ProjectSettings.get_setting(\"physics/2d/default_gravity\", 980.0)\n\n" + \
		"func _physics_process(delta: float) -> void:\n" + \
		"\tif not is_on_floor():\n" + \
		"\t\tvelocity.y += _gravity * delta\n\n" + \
		"\tif Input.is_action_just_pressed(\"ui_accept\") and is_on_floor():\n" + \
		"\t\tvelocity.y = jump_velocity\n\n" + \
		"\tvar direction: float = Input.get_axis(\"ui_left\", \"ui_right\")\n" + \
		"\tif direction != 0.0:\n" + \
		"\t\tvelocity.x = direction * speed\n" + \
		"\telse:\n" + \
		"\t\tvelocity.x = move_toward(velocity.x, 0.0, speed)\n\n" + \
		"\tmove_and_slide()\n"

func _enemy_3d_template() -> String:
	return "extends CharacterBody3D\n" + \
		"class_name " + _PLACEHOLDER + "\n\n" + \
		"signal died\n" + \
		"signal health_changed(current: float, maximum: float)\n\n" + \
		"@export var max_health: float = 100.0\n" + \
		"@export var move_speed: float = 3.0\n\n" + \
		"var current_health: float\n\n" + \
		"func _ready() -> void:\n" + \
		"\tcurrent_health = max_health\n\n" + \
		"func take_damage(amount: float) -> void:\n" + \
		"\tif amount <= 0.0 or current_health <= 0.0:\n" + \
		"\t\treturn\n" + \
		"\tcurrent_health = max(current_health - amount, 0.0)\n" + \
		"\thealth_changed.emit(current_health, max_health)\n" + \
		"\tif current_health <= 0.0:\n" + \
		"\t\t_die()\n\n" + \
		"func heal(amount: float) -> void:\n" + \
		"\tif amount <= 0.0:\n" + \
		"\t\treturn\n" + \
		"\tcurrent_health = min(current_health + amount, max_health)\n" + \
		"\thealth_changed.emit(current_health, max_health)\n\n" + \
		"func _die() -> void:\n" + \
		"\tdied.emit()\n" + \
		"\tqueue_free()\n"

func _enemy_2d_template() -> String:
	return "extends CharacterBody2D\n" + \
		"class_name " + _PLACEHOLDER + "\n\n" + \
		"signal died\n" + \
		"signal health_changed(current: float, maximum: float)\n\n" + \
		"@export var max_health: float = 100.0\n" + \
		"@export var move_speed: float = 80.0\n\n" + \
		"var current_health: float\n\n" + \
		"func _ready() -> void:\n" + \
		"\tcurrent_health = max_health\n\n" + \
		"func take_damage(amount: float) -> void:\n" + \
		"\tif amount <= 0.0 or current_health <= 0.0:\n" + \
		"\t\treturn\n" + \
		"\tcurrent_health = max(current_health - amount, 0.0)\n" + \
		"\thealth_changed.emit(current_health, max_health)\n" + \
		"\tif current_health <= 0.0:\n" + \
		"\t\t_die()\n\n" + \
		"func heal(amount: float) -> void:\n" + \
		"\tif amount <= 0.0:\n" + \
		"\t\treturn\n" + \
		"\tcurrent_health = min(current_health + amount, max_health)\n" + \
		"\thealth_changed.emit(current_health, max_health)\n\n" + \
		"func _die() -> void:\n" + \
		"\tdied.emit()\n" + \
		"\tqueue_free()\n"

func _projectile_3d_template() -> String:
	return "extends Area3D\n" + \
		"class_name " + _PLACEHOLDER + "\n\n" + \
		"signal hit(body: Node)\n\n" + \
		"@export var velocity: Vector3 = Vector3(0.0, 0.0, -20.0)\n" + \
		"@export var lifetime: float = 5.0\n" + \
		"@export var damage: float = 10.0\n" + \
		"@export var ignore: Node = null\n\n" + \
		"var _age: float = 0.0\n\n" + \
		"func _ready() -> void:\n" + \
		"\tbody_entered.connect(_on_body_entered)\n\n" + \
		"func _physics_process(delta: float) -> void:\n" + \
		"\tglobal_position += velocity * delta\n" + \
		"\t_age += delta\n" + \
		"\tif _age >= lifetime:\n" + \
		"\t\tqueue_free()\n\n" + \
		"func _on_body_entered(body: Node) -> void:\n" + \
		"\tif body == ignore:\n" + \
		"\t\treturn\n" + \
		"\thit.emit(body)\n" + \
		"\tif body.has_method(\"take_damage\"):\n" + \
		"\t\tbody.call(\"take_damage\", damage)\n" + \
		"\tqueue_free()\n"

func _projectile_2d_template() -> String:
	return "extends Area2D\n" + \
		"class_name " + _PLACEHOLDER + "\n\n" + \
		"signal hit(body: Node)\n\n" + \
		"@export var velocity: Vector2 = Vector2(0.0, -400.0)\n" + \
		"@export var lifetime: float = 5.0\n" + \
		"@export var damage: float = 10.0\n" + \
		"@export var ignore: Node = null\n\n" + \
		"var _age: float = 0.0\n\n" + \
		"func _ready() -> void:\n" + \
		"\tbody_entered.connect(_on_body_entered)\n\n" + \
		"func _physics_process(delta: float) -> void:\n" + \
		"\tglobal_position += velocity * delta\n" + \
		"\t_age += delta\n" + \
		"\tif _age >= lifetime:\n" + \
		"\t\tqueue_free()\n\n" + \
		"func _on_body_entered(body: Node) -> void:\n" + \
		"\tif body == ignore:\n" + \
		"\t\treturn\n" + \
		"\thit.emit(body)\n" + \
		"\tif body.has_method(\"take_damage\"):\n" + \
		"\t\tbody.call(\"take_damage\", damage)\n" + \
		"\tqueue_free()\n"

func _pickup_3d_template() -> String:
	return "extends Area3D\n" + \
		"class_name " + _PLACEHOLDER + "\n\n" + \
		"signal picked_up(by: Node)\n\n" + \
		"@export var auto_destroy: bool = true\n" + \
		"@export var one_shot: bool = true\n\n" + \
		"var _consumed: bool = false\n\n" + \
		"func _ready() -> void:\n" + \
		"\tbody_entered.connect(_on_body_entered)\n\n" + \
		"func _on_body_entered(body: Node) -> void:\n" + \
		"\tif one_shot and _consumed:\n" + \
		"\t\treturn\n" + \
		"\t_consumed = true\n" + \
		"\tpicked_up.emit(body)\n" + \
		"\tif auto_destroy:\n" + \
		"\t\tqueue_free()\n"

func _pickup_2d_template() -> String:
	return "extends Area2D\n" + \
		"class_name " + _PLACEHOLDER + "\n\n" + \
		"signal picked_up(by: Node)\n\n" + \
		"@export var auto_destroy: bool = true\n" + \
		"@export var one_shot: bool = true\n\n" + \
		"var _consumed: bool = false\n\n" + \
		"func _ready() -> void:\n" + \
		"\tbody_entered.connect(_on_body_entered)\n\n" + \
		"func _on_body_entered(body: Node) -> void:\n" + \
		"\tif one_shot and _consumed:\n" + \
		"\t\treturn\n" + \
		"\t_consumed = true\n" + \
		"\tpicked_up.emit(body)\n" + \
		"\tif auto_destroy:\n" + \
		"\t\tqueue_free()\n"

func _state_template() -> String:
	return "extends Node\n" + \
		"class_name " + _PLACEHOLDER + "\n\n" + \
		"# FSM state - override the lifecycle hooks below. The owning state\n" + \
		"# machine is expected to pass its host node into each call so this\n" + \
		"# state remains stateless and reusable across instances.\n\n" + \
		"signal transition_requested(next_state: StringName)\n\n" + \
		"func enter(_host: Node, _msg: Dictionary = {}) -> void:\n" + \
		"\tpass\n\n" + \
		"func exit(_host: Node) -> void:\n" + \
		"\tpass\n\n" + \
		"func update(_host: Node, _delta: float) -> void:\n" + \
		"\tpass\n\n" + \
		"func physics_update(_host: Node, _delta: float) -> void:\n" + \
		"\tpass\n\n" + \
		"func handle_input(_host: Node, _event: InputEvent) -> void:\n" + \
		"\tpass\n\n" + \
		"func request_transition(next_state: StringName) -> void:\n" + \
		"\ttransition_requested.emit(next_state)\n"

func _autoload_template() -> String:
	return "extends Node\n" + \
		"class_name " + _PLACEHOLDER + "\n\n" + \
		"# Singleton scaffold. Register this script as an Autoload in\n" + \
		"# Project Settings -> Autoload to make it globally accessible.\n\n" + \
		"signal initialized\n" + \
		"signal value_changed(key: StringName, value: Variant)\n" + \
		"signal reset_requested\n\n" + \
		"var _state: Dictionary = {}\n" + \
		"var _ready_emitted: bool = false\n\n" + \
		"func _ready() -> void:\n" + \
		"\tif _ready_emitted:\n" + \
		"\t\treturn\n" + \
		"\t_ready_emitted = true\n" + \
		"\tinitialized.emit()\n\n" + \
		"func set_value(key: StringName, value: Variant) -> void:\n" + \
		"\t_state[key] = value\n" + \
		"\tvalue_changed.emit(key, value)\n\n" + \
		"func get_value(key: StringName, default_value: Variant = null) -> Variant:\n" + \
		"\treturn _state.get(key, default_value)\n\n" + \
		"func has_value(key: StringName) -> bool:\n" + \
		"\treturn _state.has(key)\n\n" + \
		"func reset() -> void:\n" + \
		"\t_state.clear()\n" + \
		"\treset_requested.emit()\n"

func _resource_template() -> String:
	return "extends Resource\n" + \
		"class_name " + _PLACEHOLDER + "\n\n" + \
		"__EXPORTS__"

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

#endregion

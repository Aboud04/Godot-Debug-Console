extends Node

const GAME_CONSOLE_SCENE = preload("res://addons/debug_console/game/GameConsole.tscn")
var console_instance: GameConsole = null
var is_console_enabled: bool = true
var builtin_commands: BuiltInCommands

func _ready():
	if Engine.is_editor_hint():
		return
	
	set_process_mode(Node.PROCESS_MODE_ALWAYS)
	
	is_console_enabled = _should_enable_console()
	
	if is_console_enabled:
		call_deferred("_create_console")

func _should_enable_console() -> bool:
	return (
		OS.is_debug_build() or
		"--debug-console" in OS.get_cmdline_args() or
		ProjectSettings.get_setting("debug/enable_game_console", true)
	)

func _create_console():
	console_instance = GAME_CONSOLE_SCENE.instantiate()
	
	var canvas_layer = CanvasLayer.new()
	canvas_layer.name = "DebugConsoleLayer"
	canvas_layer.layer = 1000
	canvas_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	
	get_tree().root.add_child(canvas_layer)
	canvas_layer.add_child(console_instance)
	
	console_instance.visible = false
	
	DebugCore.initialize_for_game(console_instance)
	
	builtin_commands = preload("res://addons/debug_console/core/BuiltInCommands.gd").new()
	builtin_commands.register_game_commands()

func _input(event):
	if not is_console_enabled or not console_instance:
		return
	
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F12 or (event.keycode == KEY_QUOTELEFT and event.ctrl_pressed):
			toggle_console()
			get_viewport().set_input_as_handled()

func toggle_console():
	if console_instance:
		console_instance.toggle_visibility()

func show_console():
	if console_instance:
		console_instance.show_console()

func hide_console():
	if console_instance:
		console_instance.hide_console()

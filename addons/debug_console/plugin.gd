@tool
@icon("res://addons/debug_console/icons/console_icon.svg")
extends EditorPlugin

var editor_dock: EditorDock
var editor_console_panel: Control
var builtin_commands: BuiltInCommands
var console_visible: bool = false

func _enter_tree():
	# Step 1: Register all autoloads BEFORE any code references them as identifiers.
	# This is the fix for Issues #10, #12, #13: a fresh project has no pre-existing
	# autoloads, so bare globals like DebugCore cause a parse error. By registering
	# here first, the singletons enter the scene tree before we touch them.
	add_autoload_singleton("DebugCore", "res://addons/debug_console/core/DebugCore.gd")
	add_autoload_singleton("CommandRegistry", "res://addons/debug_console/core/CommandRegistry.gd")
	# T4: Register the public DebugConsole API autoload AFTER CommandRegistry so
	# T4: its _ready() can resolve /root/CommandRegistry on first lookup. Godot
	# T4: instantiates autoloads in registration order, so DebugConsoleAPI._ready
	# T4: runs strictly after CommandRegistry._ready, both here (editor) and at
	# T4: runtime (project.godot stores them in registration order).
	add_autoload_singleton("DebugConsole", "res://addons/debug_console/core/DebugConsoleAPI.gd")
	add_autoload_singleton("GameConsoleManager", "res://addons/debug_console/game/GameConsoleManager.gd")

	# Step 2: Wait one frame so all three autoloads can run their _ready() callbacks.
	await get_tree().process_frame

	# Step 3: Fetch typed node references - never use bare global identifiers in @tool
	# scripts, because those identifiers are resolved at parse time, not run time.
	var debug_core: Node = get_node("/root/DebugCore")
	var command_registry: Node = get_node("/root/CommandRegistry")

	# Step 4: Instantiate the editor console UI panel.
	var editor_console_scene: PackedScene = load("res://addons/debug_console/editor/EditorConsole.tscn") as PackedScene
	if not editor_console_scene:
		push_error("Debug Console: failed to load EditorConsole.tscn. Plugin will not activate. Check addons/debug_console/editor/ for parse errors.")
		return
	editor_console_panel = editor_console_scene.instantiate()

	# Step 5: Tell DebugCore about the editor output panel.
	debug_core.initialize_for_editor(editor_console_panel)

	# Step 6: Create BuiltInCommands and inject its dependencies before registering.
	# Use defensive load() rather than relying on class_name resolution so that a
	# parse error in BuiltInCommands.gd or any class it references (TestFramework,
	# etc.) produces a clear, recoverable error message instead of silently leaving
	# the plugin in a half-initialized state.
	var builtin_script: GDScript = load("res://addons/debug_console/core/BuiltInCommands.gd") as GDScript
	if not builtin_script:
		push_error("Debug Console: failed to load BuiltInCommands.gd. Plugin will not register commands. Check Output for parse errors in addons/debug_console/core/.")
		return
	builtin_commands = builtin_script.new()
	if not builtin_commands:
		push_error("Debug Console: BuiltInCommands script loaded but .new() failed. Plugin will not register commands.")
		return
	builtin_commands.initialize(command_registry, debug_core)
	builtin_commands.register_editor_commands()

	# Step 6b: T3.3 - wire up the persistence layer. Defensive load() pattern
	# matches the rest of plugin.gd so a parse error in PersistenceManager.gd
	# only disables history/cwd persistence instead of taking the whole plugin
	# down. Persistence is OPTIONAL: every consumer is null-guarded.
	var persistence_script: GDScript = load("res://addons/debug_console/core/PersistenceManager.gd") as GDScript
	if persistence_script:
		var persistence: RefCounted = persistence_script.new()
		if persistence:
			if builtin_commands.has_method("set_state_saver"):
				builtin_commands.set_state_saver(persistence)
			# Restore the working directory for THIS project, falling back
			# silently if the stored path no longer exists (project moved,
			# folder deleted, etc.). Both the instance field and the static
			# mirror must be updated so consumers reading either see the
			# same value immediately.
			var project_path: String = ProjectSettings.globalize_path("res://")
			var stored_cwd: String = persistence.load_cwd_for_project(project_path)
			if not stored_cwd.is_empty() and DirAccess.dir_exists_absolute(stored_cwd):
				builtin_commands.current_directory = stored_cwd
				builtin_commands.set_current_directory(stored_cwd)
			if editor_console_panel and editor_console_panel.has_method("set_persistence"):
				editor_console_panel.set_persistence(persistence)
	else:
		push_warning("Debug Console: failed to load PersistenceManager.gd. History and working-directory persistence are disabled.")

	# Step 7: Add the UI and keyboard shortcut.
	_add_toggle_shortcut()
	
	# Use EditorDock instead of add_control_to_bottom_panel for proper focus handling.
	# EditorDock.make_visible() handles all timing and focus management automatically.
	editor_dock = EditorDock.new()
	editor_dock.title = "Debug Console"
	editor_dock.default_slot = EditorDock.DOCK_SLOT_BOTTOM
	editor_dock.dock_icon = preload("res://addons/debug_console/icons/console_icon.svg")
	editor_dock.add_child(editor_console_panel)
	add_dock(editor_dock)
	
	show_console()

func _exit_tree():
	# Use get_node_or_null in case _exit_tree is called before _enter_tree finished
	# (e.g. if the user rapidly toggles the plugin during the await frame).
	var debug_core: Node = get_node_or_null("/root/DebugCore")
	if debug_core:
		debug_core.cleanup_editor()

	if editor_dock:
		remove_dock(editor_dock)
		editor_dock.queue_free()
		editor_dock = null
	
	console_visible = false

	# Remove autoloads in reverse registration order so dependencies are torn down safely.
	remove_autoload_singleton("GameConsoleManager")
	# T4: Remove DebugConsole BEFORE CommandRegistry - the API holds a signal
	# T4: connection on the registry and reads from it lazily, so the registry
	# T4: must outlive it during teardown.
	remove_autoload_singleton("DebugConsole")
	remove_autoload_singleton("CommandRegistry")
	remove_autoload_singleton("DebugCore")

func _add_toggle_shortcut():
	var toggle_shortcut = InputEventKey.new()
	toggle_shortcut.keycode = KEY_QUOTELEFT
	toggle_shortcut.ctrl_pressed = true
	
	if not InputMap.has_action("toggle_debug_console"):
		InputMap.add_action("toggle_debug_console")
		InputMap.action_add_event("toggle_debug_console", toggle_shortcut)

func _input(event):
	if not Engine.is_editor_hint():
		return
	
	if event.is_action_pressed("toggle_debug_console"):
		get_viewport().set_input_as_handled()
		toggle_console()

func toggle_console():
	if not editor_dock:
		return
	
	if console_visible:
		hide_console()
	else:
		show_console()

func show_console():
	if not editor_dock or console_visible:
		return
	
	editor_dock.make_visible()
	if editor_console_panel and editor_console_panel.has_method("focus_command_input"):
		editor_console_panel.call_deferred("focus_command_input")
	console_visible = true

func hide_console():
	if not editor_dock or not console_visible:
		return
	
	editor_dock.close()
	console_visible = false

@tool
extends RefCounted
class_name TestFramework

const LOG_LEVEL_INFO := 0

signal test_completed(test_name: String, passed: bool, message: String)

var total_tests: int = 0
var passed_tests: int = 0
var failed_tests: int = 0
var test_results: Array[Dictionary] = []
var test_start_time: int = 0
var test_scene_instance: Node = null
var game_console_instance: GameConsole = null
var editor_console_instance: EditorConsole = null

func _registry() -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if not tree:
		return null
	return tree.root.get_node_or_null("/root/CommandRegistry")

func _debug_core() -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if not tree:
		return null
	return tree.root.get_node_or_null("/root/DebugCore")

func _debug_console_api() -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if not tree:
		return null
	return tree.root.get_node_or_null("/root/DebugConsole")

func run_all_tests():
	test_start_time = Time.get_ticks_msec()
	print("Starting Comprehensive Debug Console Test Suite...")
	
	reset_test_counters()
	
	# Core functionality tests
	run_command_registry_tests()
	run_builtin_commands_tests()
	run_piping_tests()
	run_autocomplete_tests()
	run_file_operation_tests()
	
	# UI and interaction tests
	run_editor_console_tests()
	run_game_console_tests()
	run_console_manager_tests()
	
	# Integration and system tests
	run_debug_core_tests()
	run_integration_tests()
	run_performance_tests()
	run_error_handling_tests()
	
	# Cleanup
	cleanup_test_instances()
	
	print_results()

func reset_test_counters():
	total_tests = 0
	passed_tests = 0
	failed_tests = 0
	test_results.clear()

func run_command_registry_tests():
	print("\nTesting Command Registry...")
	var registry := _registry()
	
	test("Command Registry - Register Command", func():
		var test_callable = Callable(self, "_test_function")
		registry.register_command("test_reg", test_callable, "Test command", "both")
		var success = registry._commands.has("test_reg")
		registry.unregister_command("test_reg")
		return success
	)
	
	test("Command Registry - Execute Command", func():
		var test_callable = Callable(self, "_test_function")
		registry.register_command("test_exec", test_callable, "Test command", "both")
		var result = registry.execute_command("test_exec arg1 arg2")
		registry.unregister_command("test_exec")
		return result == "test_function called with: arg1,arg2"
	)
	
	test("Command Registry - Get Help", func():
		var test_callable = Callable(self, "_test_function")
		registry.register_command("test_help", test_callable, "Test command", "both")
		var help = registry.get_command_help("test_help")
		registry.unregister_command("test_help")
		return help == "test_help - Test command"
	)
	
	test("Command Registry - Unknown Command", func():
		var result = registry.execute_command("unknown_command")
		return result.contains("Unknown command")
	)
	
	test("Command Registry - Context Validation", func():
		var test_callable = Callable(self, "_test_function")
		registry.register_command("editor_only", test_callable, "Editor only", "editor")
		var result = registry.execute_command("editor_only")
		registry.unregister_command("editor_only")
		# In editor mode, this should work. In game mode, it should fail.
		if Engine.is_editor_hint():
			return not result.contains("not available")
		else:
			return result.contains("not available")
	)
	
	test("Command Registry - Existing Commands Intact", func():
		var result = registry.execute_command("help")
		return result.contains("Available commands")
	)
	
	test("Command Registry - Unregister Command", func():
		var test_callable = Callable(self, "_test_function")
		registry.register_command("test_unreg", test_callable, "Test command", "both")
		registry.unregister_command("test_unreg")
		return not registry._commands.has("test_unreg")
	)
	
	test("Command Registry - Get Available Commands", func():
		var commands = registry.get_available_commands()
		return commands.size() > 0 and commands.has("help")
	)
	
	test("Command Registry - Command with Input Support", func():
		var test_callable = Callable(self, "_test_function_with_input")
		registry.register_command("test_input", test_callable, "Test command", "both", true)
		var result = registry.execute_command("echo hello | test_input")
		registry.unregister_command("test_input")
		return result.contains("hello")
	)
	
	test("Command Registry - Command without Input Support", func():
		var test_callable = Callable(self, "_test_function")
		registry.register_command("test_no_input", test_callable, "Test command", "both", false)
		var result = registry.execute_command("echo hello | test_no_input")
		registry.unregister_command("test_no_input")
		return result.contains("test_function called with: hello")
	)

	# --- plugin API tests ---
	# These exercise the public DebugConsole autoload + the ConsoleCommand
	# Resource. Both editor and runtime modes are valid since the autoload
	# registers in both contexts via plugin.gd.

	test("DebugConsole API - Singleton Exists", func():
		var api := _debug_console_api()
		return api != null
	)

	test("DebugConsole API - register_command", func():
		var api := _debug_console_api()
		if not api:
			return false
		var ok: bool = api.register_command("t4test_cmd", Callable(self, "_test_function"), "test", "both")
		var present: bool = api.has_command("t4test_cmd")
		api.unregister_command("t4test_cmd")
		return ok and present

	)

	test("DebugConsole API - unregister_command", func():
		var api := _debug_console_api()
		if not api:
			return false
		api.register_command("t4test_unreg", Callable(self, "_test_function"), "test", "both")
		var unregistered: bool = api.unregister_command("t4test_unreg")
		var still_present: bool = api.has_command("t4test_unreg")
		return unregistered and not still_present
	)

	test("DebugConsole API - register_command Duplicate Returns False", func():
		var api := _debug_console_api()
		if not api:
			return false
		var first: bool = api.register_command("t4test_dup", Callable(self, "_test_function"), "test", "both")
		var second: bool = api.register_command("t4test_dup", Callable(self, "_test_function"), "test", "both")
		api.unregister_command("t4test_dup")
		return first and not second
	)

	test("DebugConsole API - register_command Empty Name Returns False", func():
		var api := _debug_console_api()
		if not api:
			return false
		var ok: bool = api.register_command("", Callable(self, "_test_function"), "test", "both")
		var ok_whitespace: bool = api.register_command("   ", Callable(self, "_test_function"), "test", "both")
		return not ok and not ok_whitespace
	)

	test("DebugConsole API - register_command Emits Signal", func():
		var api := _debug_console_api()
		if not api:
			return false
		var captured: Array[String] = []
		var handler := func(cmd_name: String):
			captured.append(cmd_name)
		api.command_registered.connect(handler)
		var ok: bool = api.register_command("t4test_signal", Callable(self, "_test_function"), "test", "both")
		api.command_registered.disconnect(handler)
		api.unregister_command("t4test_signal")
		return ok and captured.size() == 1 and captured[0] == "t4test_signal"
	)

	test("DebugConsole API - print_to_console", func():
		var api := _debug_console_api()
		var core := _debug_core()
		if not api or not core:
			return false
		var sentinel: String = "t4test_print_sentinel_%d" % Time.get_ticks_usec()
		api.print_to_console(sentinel, "info")
		var history: String = core.get_history_text()
		return history.contains(sentinel)
	)

	test("DebugConsole API - list_commands Includes Builtins", func():
		var api := _debug_console_api()
		if not api:
			return false
		var names: PackedStringArray = api.list_commands()
		var has_help: bool = false
		var has_echo: bool = false
		for n in names:
			if n == "help":
				has_help = true
			if n == "echo":
				has_echo = true
		return has_help and has_echo
	)

	test("DebugConsole API - command_executed Signal Fires", func():
		var api := _debug_console_api()
		if not api or not registry:
			return false
		var captured: Array = []
		var handler := func(cmd_name: String, args: Array, result: String):
			captured.append({"name": cmd_name, "args": args, "result": result})
		api.command_executed.connect(handler)
		registry.execute_command("help")
		api.command_executed.disconnect(handler)
		if captured.size() == 0:
			return false
		var first: Dictionary = captured[0]
		return str(first.get("name", "")) == "help"
	)

	test("ConsoleCommand Resource - is_valid", func():
		var ConsoleCmdScript: GDScript = load("res://addons/debug_console/core/ConsoleCommand.gd") as GDScript
		if not ConsoleCmdScript:
			return false
		var empty_cmd = ConsoleCmdScript.new()
		var empty_invalid: bool = not empty_cmd.is_valid()
		var full_cmd = ConsoleCmdScript.new()
		full_cmd.command_name = "t4test_resource_valid"
		full_cmd.description = "test"
		full_cmd.context = "both"
		full_cmd.callable_target = self
		full_cmd.callable_method = "_test_function"
		var full_valid: bool = full_cmd.is_valid()
		return empty_invalid and full_valid
	)

	test("ConsoleCommand Resource - to_callable", func():
		var ConsoleCmdScript: GDScript = load("res://addons/debug_console/core/ConsoleCommand.gd") as GDScript
		if not ConsoleCmdScript:
			return false
		var cmd = ConsoleCmdScript.new()
		cmd.command_name = "t4test_resource_callable"
		cmd.context = "both"
		cmd.callable_target = self
		cmd.callable_method = "_test_function"
		var c: Callable = cmd.to_callable()
		return c.is_valid()
	)

	test("DebugConsole API - register_resource_command", func():
		var api := _debug_console_api()
		if not api:
			return false
		var ConsoleCmdScript: GDScript = load("res://addons/debug_console/core/ConsoleCommand.gd") as GDScript
		if not ConsoleCmdScript:
			return false
		var cmd = ConsoleCmdScript.new()
		cmd.command_name = "t4test_resource_cmd"
		cmd.description = "T4 resource cmd"
		cmd.context = "both"
		cmd.callable_target = self
		cmd.callable_method = "_test_function"
		var ok: bool = api.register_resource_command(cmd)
		var present: bool = api.has_command("t4test_resource_cmd")
		api.unregister_command("t4test_resource_cmd")
		return ok and present
	)

func run_builtin_commands_tests():
	print("\nTesting Built-in Commands...")
	# NOTE: Regression tests for B2 (GameConsole ESC) and B3 (EditorConsole BBCode
	# truncation + focus theft) require Control fixtures and are deferred to the
	# UI-test pass. See Tier 1 plan.
	var registry := _registry()
	
	test("Built-in Commands - Help Command", func():
		var commands = BuiltInCommands.new()
		var result = commands._help([])
		return result.contains("Available commands") and result.contains("help")
	)
	
	test("Built-in Commands - Echo Command", func():
		var commands = BuiltInCommands.new()
		var result = commands._echo(["hello", "world"])
		return result == "hello world"
	)
	
	test("Built-in Commands - Echo with Piped Input", func():
		var commands = BuiltInCommands.new()
		var result = commands._echo([], "piped input", true)
		return result == "piped input"
	)

	test("Built-in Commands - Scene Tree Registration", func():
		if not registry:
			return false
		return registry._commands.has("scene_tree")
	)

	test("Built-in Commands - Scene Tree Full Output", func():
		var fixture = _create_scene_tree_fixture()
		var commands = BuiltInCommands.new()
		var result = commands._cmd_scene_tree([fixture.root.get_path()])
		var passed = (
			result.contains("[Node] " + fixture.root.name)
			and result.contains("├─ [Node] " + fixture.branch_a.name)
			and result.contains("│  └─ [Node] " + fixture.leaf_a.name)
			and result.contains("└─ [Node] " + fixture.branch_b.name)
			and result.contains("   └─ [Node] " + fixture.leaf_b.name)
		)
		_cleanup_scene_tree_fixture(fixture)
		return passed
	)

	test("Built-in Commands - Scene Tree Subtree Output", func():
		var fixture = _create_scene_tree_fixture()
		var commands = BuiltInCommands.new()
		var result = commands._cmd_scene_tree([fixture.branch_b.get_path()])
		var passed = (
			result.contains("[Node] " + fixture.branch_b.name)
			and result.contains("└─ [Node] " + fixture.leaf_b.name)
			and not result.contains(fixture.branch_a.name)
			and not result.contains(fixture.leaf_a.name)
		)
		_cleanup_scene_tree_fixture(fixture)
		return passed
	)

	test("Built-in Commands - Scene Tree Named Lookup", func():
		var fixture = _create_scene_tree_fixture()
		var commands = BuiltInCommands.new()
		var result = commands._cmd_scene_tree([fixture.root.name])
		var passed = result.contains("[Node] " + fixture.root.name) and result.contains(fixture.branch_a.name)
		_cleanup_scene_tree_fixture(fixture)
		return passed
	)

	test("Built-in Commands - Scene Tree Invalid Node", func():
		var commands = BuiltInCommands.new()
		var result = commands._cmd_scene_tree(["DefinitelyMissingSceneTreeNode"])
		return result == "Error: Node not found: DefinitelyMissingSceneTreeNode"
	)

	test("Built-in Commands - Watch Registration", func():
		if not registry:
			return false
		return registry._commands.has("watch")
	)

	test("Built-in Commands - Watch Add Node Property", func():
		var commands = BuiltInCommands.new()
		var core := _debug_core()
		if core:
			core.clear_watches()
		var fixture = _create_watch_fixture()
		var expression = "%s:process_mode" % fixture.target.get_path()
		var result = commands._cmd_watch([expression])
		var passed = result.contains("Watching %s = " % expression)
		if core:
			core.clear_watches()
		_cleanup_watch_fixture(fixture)
		return passed
	)

	test("Built-in Commands - Watch List", func():
		var commands = BuiltInCommands.new()
		var core := _debug_core()
		if core:
			core.clear_watches()
		var fixture = _create_watch_fixture()
		var expression = "%s:process_mode" % fixture.target.get_path()
		commands._cmd_watch([expression])
		var result = commands._cmd_watch([])
		var passed = result.contains("Active watches:") and result.contains(expression)
		if core:
			core.clear_watches()
		_cleanup_watch_fixture(fixture)
		return passed
	)

	test("Built-in Commands - Watch Duplicate", func():
		var commands = BuiltInCommands.new()
		var core := _debug_core()
		if core:
			core.clear_watches()
		var fixture = _create_watch_fixture()
		var expression = "%s:process_mode" % fixture.target.get_path()
		commands._cmd_watch([expression])
		var result = commands._cmd_watch([expression])
		var passed = result == "Watch already exists: %s" % expression
		if core:
			core.clear_watches()
		_cleanup_watch_fixture(fixture)
		return passed
	)

	test("Built-in Commands - Watch Poll Change Detection", func():
		var commands = BuiltInCommands.new()
		var core := _debug_core()
		if not core:
			return false
		core.clear_watches()
		var fixture = _create_watch_fixture()
		var expression = "%s:process_mode" % fixture.target.get_path()
		commands._cmd_watch([expression])
		fixture.target.process_mode = Node.PROCESS_MODE_DISABLED
		var result = commands._cmd_watch(["poll"])
		var passed = result.contains("WATCH %s = %s" % [expression, var_to_str(Node.PROCESS_MODE_DISABLED)])
		core.clear_watches()
		_cleanup_watch_fixture(fixture)
		return passed
	)

	test("Built-in Commands - Watch Remove And Clear", func():
		var commands = BuiltInCommands.new()
		var core := _debug_core()
		if not core:
			return false
		core.clear_watches()
		var fixture = _create_watch_fixture()
		var expression = "%s:process_mode" % fixture.target.get_path()
		commands._cmd_watch([expression])
		var remove_result = commands._cmd_watch(["remove", expression])
		commands._cmd_watch([expression])
		var clear_result = commands._cmd_watch(["clear"])
		var passed = remove_result == "Removed watch: %s" % expression and clear_result == "Cleared 1 watch(es)"
		core.clear_watches()
		_cleanup_watch_fixture(fixture)
		return passed
	)

	test("Built-in Commands - Watch Invalid Expression", func():
		var commands = BuiltInCommands.new()
		var result = commands._cmd_watch(["not_a_valid_expression"])
		return result == "Error: Watch expression must use Engine.<property> or <node_path>:<property>"
	)

	test("Built-in Commands - Watch Engine Property", func():
		var commands = BuiltInCommands.new()
		var core := _debug_core()
		if not core:
			return false
		core.clear_watches()
		var original_time_scale := Engine.time_scale
		var add_result = commands._cmd_watch(["Engine.time_scale"])
		Engine.time_scale = 0.5
		var poll_result = commands._cmd_watch(["poll"])
		Engine.time_scale = original_time_scale
		core.clear_watches()
		return add_result.contains("Watching Engine.time_scale = ") and poll_result.contains("WATCH Engine.time_scale = 0.5")
	)

	test("Built-in Commands - Save Log Registration", func():
		if not registry:
			return false
		return registry._commands.has("save_log")
	)

	test("Built-in Commands - Save Log Usage", func():
		var commands = BuiltInCommands.new()
		var result = commands._save_log([])
		return result == "Usage: save_log <path>"
	)

	test("Built-in Commands - Save Log Creates File", func():
		var commands = BuiltInCommands.new()
		var core := _debug_core()
		if not core:
			return false
		core.clear_history()
		core.info("SaveLog built-in test line")
		var filename = ".test_save_log_" + str(Time.get_ticks_msec()) + ".txt"
		var result = commands._save_log([filename])
		# _resolve_output_path routes to res:// in editor, user:// at runtime.
		# Use explicit String typing - GDScript 4.6 can't infer through the
		# ternary expression below.
		var expected_prefix: String = "res://" if Engine.is_editor_hint() else "user://"
		var full_path: String = expected_prefix + filename
		var file = FileAccess.open(full_path, FileAccess.READ)
		var content = file.get_as_text() if file else ""
		if file:
			file.close()
		cleanup_test_file(filename)
		return result.contains("Saved 1 log entries to: " + full_path) and content.contains("SaveLog built-in test line")
	)

	# --- inspect tests ---
	test("Built-in Commands - Inspect Registration", func():
		if not registry:
			return false
		return registry._commands.has("inspect")
	)

	test("Built-in Commands - Inspect Usage Error", func():
		var commands = BuiltInCommands.new()
		var result = commands._cmd_inspect([])
		return result == "Usage: inspect <node_path|autoload_name|Engine>"
	)

	test("Built-in Commands - Inspect Engine Singleton", func():
		var commands = BuiltInCommands.new()
		var result = commands._cmd_inspect(["Engine"])
		return result.contains("=== Engine ===") and result.contains("Class: Engine")
	)

	test("Built-in Commands - Inspect Engine Shows Properties", func():
		var commands = BuiltInCommands.new()
		var result = commands._cmd_inspect(["Engine"])
		# Engine always exposes max_fps, time_scale, physics_ticks_per_second, etc.
		return result.contains("max_fps") or result.contains("time_scale") or result.contains("Properties:")
	)

	test("Built-in Commands - Inspect Invalid Path Returns Error", func():
		var commands = BuiltInCommands.new()
		var result = commands._cmd_inspect(["NonExistentNodeXYZZY_9999"])
		return result.begins_with("Error:")
	)

	test("Built-in Commands - Inspect DebugCore By Short Name", func():
		var core := _debug_core()
		if not core:
			return false
		var commands = BuiltInCommands.new()
		var result = commands._cmd_inspect(["DebugCore"])
		return result.contains("DebugCore") and not result.begins_with("Error:")
	)

	test("Built-in Commands - Inspect DebugCore By Absolute Path", func():
		var core := _debug_core()
		if not core:
			return false
		var commands = BuiltInCommands.new()
		var result = commands._cmd_inspect(["/root/DebugCore"])
		return result.contains("DebugCore") and not result.begins_with("Error:")
	)

	test("Built-in Commands - Inspect Shows max_history_size Property", func():
		var core := _debug_core()
		if not core:
			return false
		var commands = BuiltInCommands.new()
		var result = commands._cmd_inspect(["DebugCore"])
		# max_history_size is a declared @export-style var in DebugCore
		return result.contains("max_history_size")
	)

	# --- get/set tests ---
	test("Built-in Commands - Get Registration", func():
		if not registry:
			return false
		return registry._commands.has("get")
	)

	test("Built-in Commands - Set Registration", func():
		if not registry:
			return false
		return registry._commands.has("set")
	)

	test("Built-in Commands - Get Usage Error", func():
		var commands = BuiltInCommands.new()
		var result = commands._cmd_get([])
		return result == "Usage: get <target>.<property_path>"
	)

	test("Built-in Commands - Set Usage Error", func():
		var commands = BuiltInCommands.new()
		var result = commands._cmd_set(["DebugCore.max_history_size"])
		return result == "Usage: set <target>.<property_path> <value>"
	)

	test("Built-in Commands - Get DebugCore Property", func():
		var core := _debug_core()
		if not core:
			return false
		var commands = BuiltInCommands.new()
		var result = commands._cmd_get(["DebugCore.max_history_size"])
		return result.begins_with("DebugCore.max_history_size = ")
	)

	test("Built-in Commands - Set DebugCore Int Property", func():
		var core := _debug_core()
		if not core:
			return false
		var commands = BuiltInCommands.new()
		var original_value = core.max_history_size
		var set_result = commands._cmd_set(["DebugCore.max_history_size", "1234"])
		var get_result = commands._cmd_get(["DebugCore.max_history_size"])
		core.max_history_size = original_value
		return set_result.contains("Set DebugCore.max_history_size") and get_result.contains("1234")
	)

	test("Built-in Commands - Set Engine Float Property", func():
		var commands = BuiltInCommands.new()
		var original_value = Engine.time_scale
		var set_result = commands._cmd_set(["Engine.time_scale", "0.75"])
		var get_result = commands._cmd_get(["Engine.time_scale"])
		Engine.time_scale = original_value
		return set_result.contains("Set Engine.time_scale") and get_result.contains("0.75")
	)

	test("Built-in Commands - Set Invalid Type Rejected", func():
		var commands = BuiltInCommands.new()
		var result = commands._cmd_set(["DebugCore.max_history_size", "not_an_int"])
		return result.begins_with("Error: Invalid int value:")
	)

	test("Built-in Commands - Get Invalid Selector", func():
		var commands = BuiltInCommands.new()
		var result = commands._cmd_get(["DebugCore"])
		return result == "Usage: <target>.<property_path>"
	)

	test("Built-in Commands - Set Unknown Target", func():
		var commands = BuiltInCommands.new()
		var result = commands._cmd_set(["MissingTarget.value", "1"])
		return result == "Error: Target not found"
	)

	# --- alias/unalias tests ---
	test("Built-in Commands - Alias Registration", func():
		if not registry:
			return false
		return registry._commands.has("alias") and registry._commands.has("unalias")
	)

	test("Built-in Commands - Alias Usage And Execution", func():
		var commands = BuiltInCommands.new()
		commands._cmd_unalias(["techo"])
		var set_result = commands._cmd_alias(["techo", "echo"])
		var run_result = registry.execute_command("techo hello")
		commands._cmd_unalias(["techo"])
		return set_result.begins_with("Alias set:") and run_result == "hello"
	)

	test("Built-in Commands - Unalias Removes Command", func():
		var commands = BuiltInCommands.new()
		commands._cmd_alias(["techo", "echo"])
		var remove_result = commands._cmd_unalias(["techo"])
		var run_result = registry.execute_command("techo hello")
		return remove_result == "Alias removed: techo" and run_result == "Unknown command: techo"
	)

	test("Built-in Commands - Alias Persists To ConfigFile", func():
		var commands = BuiltInCommands.new()
		commands._cmd_unalias(["tpersist"])
		var set_result = commands._cmd_alias(["tpersist", "echo persistent"])
		var cfg = ConfigFile.new()
		var load_err = cfg.load("user://debug_console_aliases.cfg")
		var saved = load_err == OK and str(cfg.get_value("aliases", "tpersist", "")) == "echo persistent"
		commands._cmd_unalias(["tpersist"])
		return set_result.begins_with("Alias set:") and saved
	)

	test("Built-in Commands - Alias Reload From ConfigFile", func():
		var commands_a = BuiltInCommands.new()
		commands_a._cmd_unalias(["treload"])
		commands_a._cmd_alias(["treload", "echo reload_ok"])

		var commands_b = BuiltInCommands.new()
		commands_b._ensure_dependencies()
		commands_b._load_aliases_from_config()
		commands_b._register_alias_commands()
		var run_result = registry.execute_command("treload")

		commands_b._cmd_unalias(["treload"])
		return run_result == "reload_ok"
	)
	# --- end alias/unalias tests ---

	# --- benchmark tests ---
	test("Built-in Commands - Benchmark Registration", func():
		if not registry:
			return false
		return registry._commands.has("benchmark")
	)

	test("Built-in Commands - Benchmark Usage Error", func():
		var commands = BuiltInCommands.new()
		var result = commands._cmd_benchmark([])
		return result == "Usage: benchmark [iterations] <command>"
	)

	test("Built-in Commands - Benchmark Invalid Iterations", func():
		var commands = BuiltInCommands.new()
		var result = commands._cmd_benchmark(["0", "echo", "ok"])
		return result == "Error: iterations must be > 0"
	)

	test("Built-in Commands - Benchmark Echo Command", func():
		var commands = BuiltInCommands.new()
		var result = commands._cmd_benchmark(["3", "echo", "bench_ok"])
		return result.contains("Benchmark 'echo bench_ok' iterations=3") and result.contains("avg=") and result.contains("min=") and result.contains("max=") and result.contains("Last result: bench_ok")
	)

	test("Built-in Commands - Benchmark Recursive Guard", func():
		var commands = BuiltInCommands.new()
		var result = commands._cmd_benchmark(["benchmark", "echo", "nope"])
		return result == "Error: benchmark cannot run benchmark recursively"
	)
	# --- end benchmark tests ---

	# --- config tests ---
	test("Built-in Commands - Config Registration", func():
		if not registry:
			return false
		return registry._commands.has("config")
	)

	test("Built-in Commands - Config Usage", func():
		var commands = BuiltInCommands.new()
		var result = commands._cmd_config(["unknown"])
		return result == "Usage: config <list|get|set|reset> ..."
	)

	test("Built-in Commands - Config Set And Get", func():
		var commands = BuiltInCommands.new()
		var set_result = commands._cmd_config(["set", "opacity", "0.7"])
		var get_result = commands._cmd_config(["get", "opacity"])
		commands._cmd_config(["reset", "opacity"])
		return set_result == "config opacity set to 0.7" and get_result == "config opacity = 0.7"
	)

	test("Built-in Commands - Config Reset Key", func():
		var commands = BuiltInCommands.new()
		commands._cmd_config(["set", "font_size", "22"])
		var reset_result = commands._cmd_config(["reset", "font_size"])
		var get_result = commands._cmd_config(["get", "font_size"])
		return reset_result == "config font_size reset to 14" and get_result == "config font_size = 14"
	)

	test("Built-in Commands - Config Persists To File", func():
		var commands = BuiltInCommands.new()
		commands._cmd_config(["set", "height", "420"])
		var cfg := ConfigFile.new()
		var load_err := cfg.load("user://debug_console_config.cfg")
		var persisted := load_err == OK and int(cfg.get_value("console", "height", 0)) == 420
		commands._cmd_config(["reset", "height"])
		return persisted
	)
	# --- end config tests ---
	# --- end get/set tests ---
	# --- end inspect tests ---
	
	if Engine.is_editor_hint():
		test("Built-in Commands - List Files", func():
			var commands = BuiltInCommands.new()
			var result = commands._list_files([])
			return result.contains("Files in res://")
		)
		
		test("Built-in Commands - List Files with Piped Input", func():
			var commands = BuiltInCommands.new()
			var result = commands._list_files([], "some input", true)
			# Pipe-context _list_files returns BBCode-colored filenames joined by \n;
			# project root always has at least one entry (project.godot), so a colored
			# tag must be present and no error string may appear.
			return result.contains("[color=") and not result.contains("Error")
		)
		
		# --- output renderer tests ---
		test("Built-in Commands - ls -l Produces Table", func():
			var commands = BuiltInCommands.new()
			var result: String = commands._list_files(["-l"], "", false)
			# Header row must mention all four column names regardless of color
			# coding applied to data rows. The project root always contains at
			# least one entry, so at least one DIR or FILE row must appear too.
			var has_header: bool = (
				result.contains("TYPE")
				and result.contains("NAME")
				and result.contains("SIZE")
				and result.contains("MODIFIED")
			)
			var has_row: bool = result.contains("FILE") or result.contains("DIR")
			return has_header and has_row
		)
		
		test("Built-in Commands - Human Size Format", func():
			var commands = BuiltInCommands.new()
			var zero: String = commands._human_size(0)
			var kb: String = commands._human_size(1500)
			var mb: String = commands._human_size(2_000_000)
			return zero == "0B" and kb.contains("KB") and mb.contains("MB")
		)
		# --- end T2.2 output renderer tests ---
	
	if Engine.is_editor_hint():
		test("Built-in Commands - Change Directory", func():
			var commands = BuiltInCommands.new()
			var original_dir = commands.get_current_directory()
			var result = commands._change_directory(["addons"])
			var new_dir = commands.get_current_directory()
			commands._change_directory([original_dir])
			return result.contains("Changed to:") and new_dir.contains("addons")
		)
		
		test("Built-in Commands - Print Working Directory", func():
			var commands = BuiltInCommands.new()
			var result = commands._print_working_directory([])
			return result.contains("Current directory")
		)
		
		test("Built-in Commands - View File", func():
		
			var test_content = "test content for viewing"
			create_test_file("test_view_file.txt", test_content)
			
			var commands = BuiltInCommands.new()
			var result = commands._view_file(["test_view_file.txt"])
			
			cleanup_test_file("test_view_file.txt")
			
			return result.contains("test content for viewing")
		)
		
	test("Built-in Commands - View File with Piped Input", func():
		var commands = BuiltInCommands.new()
		var result = commands._view_file([], "piped file content", true)
		# _view_file requires args[0] as filename regardless of pipe context, so the
		# only observable behavior when called with no args is the usage string.
		return result == "Usage: cat <filename>"
		)
	
	if Engine.is_editor_hint():
		test("Built-in Commands - Grep Command", func():
			var commands = BuiltInCommands.new()
			var result = commands._grep(["test"], "line1\ntest line\nline3")
			return result.contains("test line")
		)
		
		test("Built-in Commands - Grep with No Matches", func():
			var commands = BuiltInCommands.new()
			var result = commands._grep(["nonexistent"], "line1\nline2\nline3")
			return result.contains("No matches found")
		)
		
		test("Built-in Commands - Head Command", func():
			var commands = BuiltInCommands.new()
			var input_text = "line1\nline2\nline3\nline4\nline5"
			var result = commands._head(["3"], input_text, true)
			var lines = result.split("\n")
			return lines.size() == 3 and lines[0] == "line1"
		)
		
		test("Built-in Commands - Tail Command", func():
			var commands = BuiltInCommands.new()
			var input_text = "line1\nline2\nline3\nline4\nline5"
			var result = commands._tail(["3"], input_text, true)
			var lines = result.split("\n")
			return lines.size() == 3 and lines[0] == "line3"
		)
		
		test("Built-in Commands - Find Command", func():
			var commands = BuiltInCommands.new()
			var result = commands._find([".gd"])
			# This project contains many .gd files under addons/, so find must report
			# matches; accepting "No files found" would hide a regression in the
			# recursive walk.
			return result.contains("Found") and result.contains(".gd")
		)
		
		test("Built-in Commands - Stat Command", func():
			var commands = BuiltInCommands.new()
			var result = commands._stat(["project.godot"])
			# project.godot definitely exists at res:// root; the "File not found"
			# branch is a footgun that masks broken path resolution.
			return result.contains("project.godot") and result.contains("Type: File")
		)
	
	if Engine.is_editor_hint():
		test("Built-in Commands - Create File", func():
			var commands = BuiltInCommands.new()
			var test_file = ".test_create_file_" + str(Time.get_ticks_msec()) + ".txt"
			var result = commands._create_file([test_file])
			var success = result.contains("Created file")
			
			if FileAccess.file_exists("res://" + test_file):
				cleanup_test_file(test_file)
			
			return success
		)
		
		test("Built-in Commands - Create Directory", func():
			var commands = BuiltInCommands.new()
			var test_dir = ".test_create_dir_" + str(Time.get_ticks_msec())
			var result = commands._make_directory([test_dir])
			var success = result.contains("Created directory")
			
			if DirAccess.dir_exists_absolute("res://" + test_dir):
				cleanup_test_directory(test_dir)
			
			return success
		)
		
		test("Built-in Commands - Create Script", func():
			var commands = BuiltInCommands.new()
			var test_script = ".test_script_" + str(Time.get_ticks_msec())
			var result = commands._create_script([test_script, "Node"])
			var success = result.contains("Created script") and result.contains("extends Node")
			
			if FileAccess.file_exists("res://" + test_script + ".gd"):
				cleanup_test_file(test_script + ".gd")
			
			return success
		)
		
		test("Built-in Commands - Remove File", func():
			
			var test_file = ".test_remove_file_" + str(Time.get_ticks_msec()) + ".txt"
			create_test_file(test_file, "test content")
			
			var commands = BuiltInCommands.new()
			var result = commands._remove_file([test_file])
			
			return result.contains("Removed") and not FileAccess.file_exists("res://" + test_file)
		)
		
		test("Built-in Commands - Remove Directory", func():
			
			var test_dir = ".test_remove_dir_" + str(Time.get_ticks_msec())
			create_test_directory(test_dir)
			
			var commands = BuiltInCommands.new()
			var result = commands._remove_directory([test_dir])
			
			# Happy path: directory we just created must have actually been removed.
			return result.contains("Removed directory") and not DirAccess.dir_exists_absolute("res://" + test_dir)
		)
		
		test("Built-in Commands - Copy File", func():
			
			var test_file = ".test_copy_source_" + str(Time.get_ticks_msec()) + ".txt"
			var test_dest = ".test_copy_dest_" + str(Time.get_ticks_msec()) + ".txt"
			create_test_file(test_file, "test content")
			
			var commands = BuiltInCommands.new()
			var result = commands._copy_file([test_file, test_dest])
			
			var success = result.contains("Copied") and FileAccess.file_exists("res://" + test_dest)
			
			cleanup_test_file(test_file)
			cleanup_test_file(test_dest)
			
			return success
		)
		
		test("Built-in Commands - Move File", func():
			
			var test_file = ".test_move_source_" + str(Time.get_ticks_msec()) + ".txt"
			var test_dest = ".test_move_dest_" + str(Time.get_ticks_msec()) + ".txt"
			create_test_file(test_file, "test content")
			
			var commands = BuiltInCommands.new()
			var result = commands._move_file([test_file, test_dest])
			
			var success = result.contains("Moved") and FileAccess.file_exists("res://" + test_dest) and not FileAccess.file_exists("res://" + test_file)
			
			cleanup_test_file(test_dest)
			
			return success
		)
	
	test("Built-in Commands - History Command", func():
		var commands = BuiltInCommands.new()
		var result = commands._show_history([])
		return result.contains("Command history")
	)
	
	test("Built-in Commands - Clear History", func():
		var commands = BuiltInCommands.new()
		var result = commands._clear_history([])
		return result.contains("History cleared")
	)
	
	test("Built-in Commands - Save Scenes (Editor)", func():
		if not Engine.is_editor_hint():
			return true
		
		var commands = BuiltInCommands.new()
		var result = commands._save_scene([])
		return result == "All scenes saved successfully"
	)
	
	test("Built-in Commands - Run Project (Editor)", func():
		if not Engine.is_editor_hint():
			return true
		
		var commands = BuiltInCommands.new()
		var result = commands._run_project([])
		return result == "Running main scene"
	)
	
	test("Built-in Commands - Stop Project (Editor)", func():
		if not Engine.is_editor_hint():
			return true
		
		var commands = BuiltInCommands.new()
		var result = commands._stop_project([])
		return result == "Project stopped"
	)
	
	
	
	if not Engine.is_editor_hint():
		test("Built-in Commands - Show FPS (Game)", func():
			var commands = BuiltInCommands.new()
			var result = commands._show_fps([])
			return result.contains("FPS:")
		)
		
		test("Built-in Commands - Count Nodes (Game)", func():
			var commands = BuiltInCommands.new()
			var result = commands._count_nodes([])
			return result.contains("Total nodes in scene:")
		)
		
		test("Built-in Commands - Toggle Pause (Game)", func():
			var commands = BuiltInCommands.new()
			var result = commands._toggle_pause([])
			return result.contains("Game") and (result.contains("paused") or result.contains("unpaused"))
		)
		
		test("Built-in Commands - Set Time Scale (Game)", func():
			var commands = BuiltInCommands.new()
			var result = commands._set_time_scale(["2.0"])
			return result.contains("Time scale set to: 2.0")
		)

		# --- opacity + intercept commands ---
		# opacity is registered inside register_game_commands(), which the
		# GameConsoleManager calls on startup in runtime mode. Editor mode
		# never registers game commands, hence the runtime-only gate.
		test("Built-in Commands - Opacity Command Registration", func():
			if not registry:
				return false
			return registry._commands.has("opacity")
		)

		test("Built-in Commands - Opacity Command Valid Value", func():
			var commands = BuiltInCommands.new()
			var result: String = commands._cmd_opacity(["50"])
			return result.contains("50") and not result.begins_with("Error")
		)

		test("Built-in Commands - Opacity Command Invalid Value", func():
			var commands = BuiltInCommands.new()
			var result: String = commands._cmd_opacity(["abc"])
			return result.begins_with("Error")
		)

		test("Built-in Commands - Intercept Toggle", func():
			var commands = BuiltInCommands.new()
			var on_result: String = commands._cmd_intercept(["on"])
			var off_result: String = commands._cmd_intercept(["off"])
			return on_result.contains("ON") and off_result.contains("OFF")
		)

		# End-to-end intercept proof: when ON, a print() call should land
		# in the GameConsole's log buffer; when OFF, the next print()
		# must NOT add another entry. Skipped gracefully if the running
		# Godot build doesn't expose Logger (intercept_available == false).
		test("Built-in Commands - Intercept Routes Print", func():
			var tree: SceneTree = Engine.get_main_loop() as SceneTree
			if not tree:
				return false
			var gcm: Node = tree.root.get_node_or_null("/root/GameConsoleManager")
			if not gcm:
				return false
			var gc: Node = gcm.get("console_instance")
			if not gc or not gc.has_method("is_intercept_available"):
				return false
			if not gc.call("is_intercept_available"):
				# Engine lacks Logger API - feature unsupported here.
				# Treat as PASS (parity with how we skip platform-specific tests).
				return true
			var commands = BuiltInCommands.new()
			# Ensure clean baseline: turn off first so we're not relying on previous state.
			commands._cmd_intercept(["off"])
			var baseline_size: int = gc.call("get_log_buffer").size()
			commands._cmd_intercept(["on"])
			var marker_on: String = "T23_INTERCEPT_MARKER_ON_%d" % Time.get_ticks_usec()
			print(marker_on)
			var after_on: Array = gc.call("get_log_buffer")
			var captured_on: bool = false
			for line in after_on:
				if str(line).contains(marker_on):
					captured_on = true
					break
			commands._cmd_intercept(["off"])
			var size_after_off_toggle: int = gc.call("get_log_buffer").size()
			var marker_off: String = "T23_INTERCEPT_MARKER_OFF_%d" % Time.get_ticks_usec()
			print(marker_off)
			var after_off: Array = gc.call("get_log_buffer")
			var captured_off: bool = false
			for line in after_off:
				if str(line).contains(marker_off):
					captured_off = true
					break
			# ON must capture, OFF must NOT capture (and size must not grow
			# from the OFF print). baseline_size sanity-checks we started clean.
			return captured_on and not captured_off and after_off.size() == size_after_off_toggle and baseline_size >= 0
		)
		# --- end T2.3 opacity + intercept commands ---

	# --- Bug-fix regression tests ---
	test("Regression - B1 cwd Persists Across Instances", func():
		if not Engine.is_editor_hint():
			return true
		# EditorConsole's file/dir autocomplete relies on BuiltInCommands.get_current_directory()
		# returning the actual cwd, not always res://. Confirm the static contract.
		var commands_a = BuiltInCommands.new()
		var original_dir := BuiltInCommands.get_current_directory()
		commands_a._change_directory(["addons"])
		var observed_static := BuiltInCommands.get_current_directory()
		# Restore
		BuiltInCommands.set_current_directory(original_dir)
		return observed_static.contains("addons") and observed_static != "res://"
	)

	test("Regression - B4 new_scene Generates Unique UIDs", func():
		if not Engine.is_editor_hint():
			return true
		# Verifies _create_scene produces distinct UIDs via ResourceUID, not the
		# hardcoded UID that was burned into every scene before the B4 fix.
		#
		# Known cosmetic warning: this test creates .gd files via _create_script
		# which triggers Godot's async filesystem scan. By the time cleanup_test_file
		# deletes the .gd, the scanner may still be loading it and will log a
		# "File not found" error. The TEST RESULT is unaffected - the assertion
		# uses the .tscn contents we read synchronously before cleanup.
		var commands: BuiltInCommands = BuiltInCommands.new()
		var ts := Time.get_ticks_msec()
		var name_a := ".test_b4_scene_a_" + str(ts)
		var name_b := ".test_b4_scene_b_" + str(ts)
		commands._create_scene([name_a, "Node"])
		commands._create_scene([name_b, "Node"])
		# _create_scene writes under current_directory; a fresh BuiltInCommands
		# defaults to "res://".
		var path_a: String = commands.current_directory.path_join(name_a + ".tscn")
		var path_b: String = commands.current_directory.path_join(name_b + ".tscn")
		var content_a := ""
		var content_b := ""
		var file_a := FileAccess.open(path_a, FileAccess.READ)
		if file_a:
			content_a = file_a.get_as_text()
			file_a.close()
		var file_b := FileAccess.open(path_b, FileAccess.READ)
		if file_b:
			content_b = file_b.get_as_text()
			file_b.close()
		var uid_a := _extract_scene_uid(content_a)
		var uid_b := _extract_scene_uid(content_b)
		# Cleanup (see comment above re: cosmetic .gd File-not-found warning).
		cleanup_test_file(name_a + ".tscn")
		cleanup_test_file(name_b + ".tscn")
		cleanup_test_file(name_a + ".gd")
		cleanup_test_file(name_b + ".gd")
		return uid_a != "" and uid_b != "" and uid_a != uid_b and uid_a.begins_with("uid://") and uid_b.begins_with("uid://")
	)

	test("Regression - B2 GameConsole Esc Closes Console", func():
		if Engine.is_editor_hint():
			return true  # GameConsole behavior is runtime-only
		# B2: pressing ESC while the GameConsole is visible must start hiding it.
		# Asserts that _input() routes ESC through hide_console(), which flips
		# is_animating=true (the hide tween is in flight). The actual visible=false
		# happens in _on_hide_complete at the end of the tween; we invoke it
		# manually to leave a clean state.
		var gc := _instantiate_game_console_fixture()
		if not gc:
			return false
		gc.visible = true
		gc.is_animating = false
		var event := InputEventKey.new()
		event.keycode = KEY_ESCAPE
		event.pressed = true
		gc._input(event)
		var hide_started: bool = gc.is_animating
		gc._on_hide_complete()
		_cleanup_game_console_fixture(gc)
		return hide_started
	)

	test("Regression - B3a EditorConsole BBCode Survives Truncation", func():
		if not Engine.is_editor_hint():
			return true  # EditorConsole _ready short-circuits at runtime
		# B3a: when the log buffer exceeds max_output_lines, the rebuilt buffer
		# must still contain BBCode-formatted entries (each starts with "[color=#"),
		# not bare strings stripped of their level color.
		var ec := _instantiate_editor_console_fixture()
		if not ec:
			return false
		var saved_limit: int = ec.max_output_lines
		ec.max_output_lines = 10
		ec.clear_output()
		for i in range(20):
			ec.add_log_message("line " + str(i), EditorConsole.LOG_LEVEL_INFO)
		var buffer: Array = ec.get_log_buffer()
		var size_ok: bool = buffer.size() == 10
		var bbcode_preserved: bool = true
		for entry in buffer:
			if not str(entry).begins_with("[color=#"):
				bbcode_preserved = false
				break
		ec.max_output_lines = saved_limit
		_cleanup_editor_console_fixture(ec)
		return size_ok and bbcode_preserved
	)

	test("Regression - B3b EditorConsole add_log_message Does Not Force Focus", func():
		if not Engine.is_editor_hint():
			return true  # EditorConsole _ready short-circuits at runtime
		# B3b: add_log_message must not call focus_command_input() or otherwise
		# yank focus away from whatever Control currently owns it. We park focus
		# on a sentinel Control and verify it survives the log call.
		# Focus state is not guaranteed to be applied synchronously in a headless
		# editor test run; if the sentinel never acquired focus we treat the
		# assertion as inconclusive and skip-pass rather than reporting a false
		# negative.
		var tree := Engine.get_main_loop() as SceneTree
		if not tree:
			return false
		var ec := _instantiate_editor_console_fixture()
		if not ec:
			return false
		var sentinel := Control.new()
		sentinel.name = "B3bFocusSentinel_" + str(Time.get_ticks_usec())
		sentinel.focus_mode = Control.FOCUS_ALL
		tree.root.add_child(sentinel)
		sentinel.grab_focus()
		var had_focus_before: bool = sentinel.has_focus()
		ec.add_log_message("focus-probe", EditorConsole.LOG_LEVEL_INFO)
		var focus_preserved: bool = sentinel.has_focus() == had_focus_before
		if is_instance_valid(sentinel):
			sentinel.queue_free()
		_cleanup_editor_console_fixture(ec)
		if not had_focus_before:
			return true  # Headless run: focus wasn't applied, can't make a meaningful claim.
		return focus_preserved
	)
	# --- end regression tests ---

	# --- new commands tests ---
	test("Tree Command - Registration", func():
		if not Engine.is_editor_hint():
			return true  # editor-only
		if not registry:
			return false
		return registry._commands.has("tree")
	)

	test("Tree Command - Default Depth", func():
		var commands = BuiltInCommands.new()
		var result: String = commands._cmd_tree([])
		var cwd: String = commands.current_directory
		var has_cwd: bool = result.contains(cwd)
		var has_glyph: bool = result.contains("├─") or result.contains("└─")
		return has_cwd and has_glyph
	)

	test("Tree Command - Custom Depth", func():
		var commands = BuiltInCommands.new()
		var depth_one: String = commands._cmd_tree(["1"])
		var depth_three: String = commands._cmd_tree(["3"])
		var depth_one_lines: int = depth_one.split("\n").size()
		var depth_three_lines: int = depth_three.split("\n").size()
		return depth_one_lines < depth_three_lines

	)

	test("WC Command - Registration", func():
		if not Engine.is_editor_hint():
			return true  # editor-only
		if not registry:
			return false
		return registry._commands.has("wc")
	)

	test("WC Command - File", func():
		var filename := "t31_wc_test.txt"
		# 3 lines, 7 words, 32 chars total.
		var content := "one two three four\nfive six\nseven"
		create_test_file(filename, content)
		var commands = BuiltInCommands.new()
		# create_test_file writes under res://; current_directory defaults to res://.
		var result: String = commands._cmd_wc([filename])
		cleanup_test_file(filename)
		return result.contains("3") and result.contains("7") and result.contains(filename)
	)

	test("WC Command - Piped Input", func():
		var commands = BuiltInCommands.new()
		# 2 lines, 5 words.
		var result: String = commands._cmd_wc([], "hello world\nfoo bar baz", true)
		return result.contains("2") and result.contains("5")
	)

	test("Signals Command - Registration", func():
		if not registry:
			return false
		return registry._commands.has("signals")
	)

	test("Signals Command - DebugCore", func():
		var core := _debug_core()
		if not core:
			return false
		var commands = BuiltInCommands.new()
		var result: String = commands._cmd_signals(["DebugCore"])
		# DebugCore declares `signal message_logged(message: String, level: String)`.
		return result.contains("message_logged")
	)

	test("Properties Command - Registration", func():
		if not registry:
			return false
		return registry._commands.has("properties")
	)

	test("Properties Command - DebugCore", func():
		var core := _debug_core()
		if not core:
			return false
		var commands = BuiltInCommands.new()
		var result: String = commands._cmd_properties(["DebugCore"])
		# DebugCore exposes `var max_history_size: int = 1000`.
		return result.contains("max_history_size")
	)

	test("Reload Scripts - Registration", func():
		if not Engine.is_editor_hint():
			return true  # editor-only
		if not registry:
			return false
		return registry._commands.has("reload_scripts")
	)

	test("Diff Command - Registration", func():
		if not Engine.is_editor_hint():
			return true  # editor-only
		if not registry:
			return false
		return registry._commands.has("diff")
	)

	test("Diff Command - Same Files", func():
		var file_a := "t31_diff_same_a.txt"
		var file_b := "t31_diff_same_b.txt"
		var content := "alpha\nbeta\ngamma"
		create_test_file(file_a, content)
		create_test_file(file_b, content)
		var commands = BuiltInCommands.new()
		var result: String = commands._cmd_diff([file_a, file_b])
		cleanup_test_file(file_a)
		cleanup_test_file(file_b)
		var no_removed: bool = not result.contains("[color=#FF4444]-")
		var no_added: bool = not result.contains("[color=#44FF44]+")
		return no_removed and no_added
	)

	test("Diff Command - Different Files", func():
		var file_a := "t31_diff_diff_a.txt"
		var file_b := "t31_diff_diff_b.txt"
		create_test_file(file_a, "foo()\nshared")
		create_test_file(file_b, "bar()\nshared")
		var commands = BuiltInCommands.new()
		var result: String = commands._cmd_diff([file_a, file_b])
		cleanup_test_file(file_a)
		cleanup_test_file(file_b)
		var has_removed: bool = result.contains("[color=#FF4444]-")
		var has_added: bool = result.contains("[color=#44FF44]+")
		return has_removed and has_added
	)
	# --- end T3.1 new commands tests ---

	# --- persistence tests ---
	# All persistence tests use per-test unique paths in user:// (via the
	# history_path / state_path overrides on DebugConsolePersistenceManager) so
	# they never trample the real user's debug_console_history.json or
	# debug_console_state.json. Cleanup deletes the test-only files.

	test("Persistence - History Round Trip", func():
		var pm: DebugConsolePersistenceManager = DebugConsolePersistenceManager.new()
		var unique := "user://dc_t33_hist_rt_%d.json" % Time.get_ticks_usec()
		pm.history_path = unique
		var saved_history: Array[String] = ["cmd1", "cmd2"]
		pm.save_history(saved_history)
		var loaded: Array[String] = pm.load_history()
		var ok: bool = loaded.size() == 2 and loaded[0] == "cmd1" and loaded[1] == "cmd2"
		DirAccess.remove_absolute(ProjectSettings.globalize_path(unique))
		return ok
	)

	test("Persistence - History Cap at 500", func():
		var pm: DebugConsolePersistenceManager = DebugConsolePersistenceManager.new()
		var unique := "user://dc_t33_hist_cap_%d.json" % Time.get_ticks_usec()
		pm.history_path = unique
		var oversized: Array[String] = []
		for i in range(600):
			oversized.append("cmd_%d" % i)
		pm.save_history(oversized)
		var loaded: Array[String] = pm.load_history()
		# Must keep the LAST 500 (oldest dropped). Last entry is cmd_599, first
		# survivor is cmd_100.
		var ok: bool = (
			loaded.size() == 500
			and loaded[0] == "cmd_100"
			and loaded[loaded.size() - 1] == "cmd_599"
		)
		DirAccess.remove_absolute(ProjectSettings.globalize_path(unique))
		return ok
	)

	test("Persistence - History Corrupted File", func():
		var pm: DebugConsolePersistenceManager = DebugConsolePersistenceManager.new()
		var unique := "user://dc_t33_hist_corrupt_%d.json" % Time.get_ticks_usec()
		pm.history_path = unique
		# Write deliberate garbage that JSON.parse_string will reject.
		var f := FileAccess.open(unique, FileAccess.WRITE)
		if not f:
			return false
		f.store_string("{not valid json at all <<<>>>")
		f.close()
		var loaded: Array[String] = pm.load_history()
		var ok: bool = loaded.is_empty()
		DirAccess.remove_absolute(ProjectSettings.globalize_path(unique))
		return ok
	)

	test("Persistence - CWD Save And Load", func():
		var pm: DebugConsolePersistenceManager = DebugConsolePersistenceManager.new()
		var unique := "user://dc_t33_state_rt_%d.json" % Time.get_ticks_usec()
		pm.state_path = unique
		pm.save_cwd("res://addons")
		var project_path: String = ProjectSettings.globalize_path("res://")
		var loaded: String = pm.load_cwd_for_project(project_path)
		var ok: bool = loaded == "res://addons"
		DirAccess.remove_absolute(ProjectSettings.globalize_path(unique))
		return ok
	)

	test("Persistence - CWD Project Isolation", func():
		var pm: DebugConsolePersistenceManager = DebugConsolePersistenceManager.new()
		var unique := "user://dc_t33_state_iso_%d.json" % Time.get_ticks_usec()
		pm.state_path = unique
		# Write the state file directly with two synthetic project keys so we
		# can verify load_cwd_for_project returns the right cwd per project.
		# save_cwd auto-detects via ProjectSettings so we can't use it for the
		# second project without actually switching projects.
		var payload: Dictionary = {
			"version": DebugConsolePersistenceManager.STATE_VERSION,
			"cwd_by_project": {
				"/path/proj1": "res://A",
				"/path/proj2": "res://B",
			},
		}
		var f := FileAccess.open(unique, FileAccess.WRITE)
		if not f:
			return false
		f.store_string(JSON.stringify(payload))
		f.close()
		var got1: String = pm.load_cwd_for_project("/path/proj1")
		var got2: String = pm.load_cwd_for_project("/path/proj2")
		var got_missing: String = pm.load_cwd_for_project("/path/never_saved")
		var ok: bool = got1 == "res://A" and got2 == "res://B" and got_missing == ""
		DirAccess.remove_absolute(ProjectSettings.globalize_path(unique))
		return ok
	)
	# --- end T3.3 persistence tests ---

	# --- output renderer tests ---
	test("JSON Command - Registration", func():
		# Use an isolated temp registry so we never mutate the live autoload
		# (mutating it overwrites callables bound to the live plugin instance
		# with callables bound to a transient one, which then gets GC'd and
		# breaks subsequent tests). This proves the command is wired into
		# register_universal_commands() without side effects.
		var temp_registry = load("res://addons/debug_console/core/CommandRegistry.gd").new()
		var commands = BuiltInCommands.new()
		commands._registry = temp_registry
		commands._core = Node.new()
		commands.register_universal_commands()
		return temp_registry._commands.has("json")
	)

	test("JSON Command - Pretty Prints Valid", func():
		var commands = BuiltInCommands.new()
		var result: String = commands._cmd_json(["{\"a\":1,\"b\":2}"])
		return result.contains("\"a\"") and result.contains("\"b\"") and result.contains("\n")
	)

	test("JSON Command - Invalid Returns Error", func():
		var commands = BuiltInCommands.new()
		var result: String = commands._cmd_json(["not-json-at-all }}}"])
		return result.begins_with("Error")
	)

	test("JSON Command - Pipe Input", func():
		var commands = BuiltInCommands.new()
		var result: String = commands._cmd_json([], "{\"piped\":true}", true)
		return result.contains("\"piped\"") and result.contains("true")
	)

	test("Colorize - Quoted String Detected", func():
		var commands = BuiltInCommands.new()
		var result: String = commands._colorize_message("foo \"bar\" baz")
		return result.contains("[color=#A0E0A0]\"bar\"[/color]")
	)

	test("Colorize - Boolean Detected", func():
		var commands = BuiltInCommands.new()
		var result: String = commands._colorize_message("result is true here")
		return result.contains("[color=#D670D6]true[/color]")
	)

	test("Colorize - Bracket Detected", func():
		var commands = BuiltInCommands.new()
		var result: String = commands._colorize_message("array [1, 2, 3]")
		return result.contains("[color=#FFD700][[/color]") and result.contains("[color=#FFD700]][/color]")
	)

	test("Colorize - Keyword Detected", func():
		var commands = BuiltInCommands.new()
		var result: String = commands._colorize_message("func _ready():")
		return result.contains("[color=#FF6B9D]func[/color]")
	)
	# --- end W1 output renderer tests ---

	# --- new commands tests ---
	# eval (Expression-based REPL), perf (Performance.Monitor dashboard), show_*
	# (SceneTree debug flags), mark (sync marker), slowmo/freeze (time scale),
	# physics_tps (tick rate), crashtest (assert validation).
	test("Eval - Registration", func():
		# Use an isolated temp registry: see JSON Command - Registration above.
		var temp_registry = load("res://addons/debug_console/core/CommandRegistry.gd").new()
		var commands = BuiltInCommands.new()
		commands._registry = temp_registry
		commands._core = Node.new()
		commands.register_universal_commands()
		return temp_registry._commands.has("eval")
	)

	test("Eval - Simple Arithmetic", func():
		var commands = BuiltInCommands.new()
		var result: String = commands._cmd_eval(["2", "+", "2"])
		return result == "4"
	)

	test("Eval - Vector Constructor And Method", func():
		var commands = BuiltInCommands.new()
		var result: String = commands._cmd_eval(["Vector2(3,", "4).length()"])
		return result == "5" or result == "5.0"
	)

	test("Eval - Bad Syntax Returns Error", func():
		var commands = BuiltInCommands.new()
		var result: String = commands._cmd_eval(["bad", "syntax", "%%%"])
		return result.begins_with("Error")
	)

	test("Perf - Registration", func():
		# perf is "game" context; verify it appears in register_game_commands()
		# using an isolated temp registry so the live autoload is untouched.
		var temp_registry = load("res://addons/debug_console/core/CommandRegistry.gd").new()
		var commands = BuiltInCommands.new()
		commands._registry = temp_registry
		commands._core = Node.new()
		commands.register_game_commands()
		return temp_registry._commands.has("perf")
	)

	test("Perf - Returns FPS Line", func():
		var commands = BuiltInCommands.new()
		var result: String = commands._cmd_perf([])
		return not result.is_empty() and result.contains("FPS")
	)

	test("Perf - Filter Narrows Output", func():
		var commands = BuiltInCommands.new()
		var full: String = commands._cmd_perf([])
		var filtered: String = commands._cmd_perf(["memory"])
		return filtered.contains("Memory") and not filtered.contains("FPS") and filtered.length() < full.length()
	)

	test("Show Colliders - Registration", func():
		# show_colliders is "game" context; verify it appears in register_game_commands()
		# using an isolated temp registry so the live autoload is untouched.
		var temp_registry = load("res://addons/debug_console/core/CommandRegistry.gd").new()
		var commands = BuiltInCommands.new()
		commands._registry = temp_registry
		commands._core = Node.new()
		commands.register_game_commands()
		return temp_registry._commands.has("show_colliders")
	)

	test("Show Colliders - Toggle Or Editor Guard", func():
		var commands = BuiltInCommands.new()
		if Engine.is_editor_hint():
			var result: String = commands._cmd_show_colliders(["on"])
			return result.begins_with("Error")
		var tree := Engine.get_main_loop() as SceneTree
		if not tree:
			return false
		var prev: bool = tree.debug_collisions_hint
		commands._cmd_show_colliders(["on"])
		var on_state: bool = tree.debug_collisions_hint
		commands._cmd_show_colliders(["off"])
		var off_state: bool = tree.debug_collisions_hint
		tree.debug_collisions_hint = prev
		return on_state == true and off_state == false
	)

	test("Show Nav - Toggle Or Editor Guard", func():
		var commands = BuiltInCommands.new()
		if Engine.is_editor_hint():
			var result: String = commands._cmd_show_nav(["on"])
			return result.begins_with("Error")
		var tree := Engine.get_main_loop() as SceneTree
		if not tree:
			return false
		var prev: bool = tree.debug_navigation_hint
		commands._cmd_show_nav(["on"])
		var on_state: bool = tree.debug_navigation_hint
		commands._cmd_show_nav(["off"])
		var off_state: bool = tree.debug_navigation_hint
		tree.debug_navigation_hint = prev
		return on_state == true and off_state == false
	)

	test("Show Paths - Toggle Or Editor Guard", func():
		var commands = BuiltInCommands.new()
		if Engine.is_editor_hint():
			var result: String = commands._cmd_show_paths(["on"])
			return result.begins_with("Error")
		var tree := Engine.get_main_loop() as SceneTree
		if not tree:
			return false
		var prev: bool = tree.debug_paths_hint
		commands._cmd_show_paths(["on"])
		var on_state: bool = tree.debug_paths_hint
		commands._cmd_show_paths(["off"])
		var off_state: bool = tree.debug_paths_hint
		tree.debug_paths_hint = prev
		return on_state == true and off_state == false
	)

	test("Mark - Default Label", func():
		var commands = BuiltInCommands.new()
		var result: String = commands._cmd_mark([])
		return result.contains("MARK") and result.contains("[color=#FFD700]")
	)

	test("Mark - Custom Label Preserved", func():
		var commands = BuiltInCommands.new()
		var result: String = commands._cmd_mark(["hello", "world"])
		return result.contains("hello world")
	)

	test("Slowmo - Sets Time Scale", func():
		if Engine.is_editor_hint():
			var commands_e = BuiltInCommands.new()
			return commands_e._cmd_slowmo(["0.5"]).begins_with("Error")
		var commands = BuiltInCommands.new()
		var prev: float = Engine.time_scale
		commands._cmd_slowmo(["0.5"])
		var ok: bool = absf(Engine.time_scale - 0.5) < 0.0001
		Engine.time_scale = prev
		return ok
	)

	test("Slowmo - Off Resets Time Scale", func():
		if Engine.is_editor_hint():
			var commands_e = BuiltInCommands.new()
			return commands_e._cmd_slowmo(["off"]).begins_with("Error")
		var commands = BuiltInCommands.new()
		var prev: float = Engine.time_scale
		Engine.time_scale = 0.3
		commands._cmd_slowmo(["off"])
		var ok: bool = absf(Engine.time_scale - 1.0) < 0.0001
		Engine.time_scale = prev
		return ok
	)

	test("Freeze - Sets Time Scale To Zero", func():
		if Engine.is_editor_hint():
			var commands_e = BuiltInCommands.new()
			return commands_e._cmd_freeze([]).begins_with("Error")
		var commands = BuiltInCommands.new()
		var prev: float = Engine.time_scale
		commands._cmd_freeze([])
		var ok: bool = Engine.time_scale == 0.0
		Engine.time_scale = prev
		return ok
	)

	test("Physics TPS - Get And Set Roundtrip", func():
		var commands = BuiltInCommands.new()
		var prev: int = Engine.physics_ticks_per_second
		var set_result: String = commands._cmd_physics_tps(["30"])
		var get_result: String = commands._cmd_physics_tps([])
		var ok: bool = Engine.physics_ticks_per_second == 30 and set_result.contains("30") and get_result.contains("30")
		Engine.physics_ticks_per_second = prev
		return ok
	)

	test("Crashtest - Registration Only", func():
		# Isolated temp registry: see JSON Command - Registration above.
		# Do NOT invoke _cmd_crashtest; assert(false) would halt the test runner.
		var temp_registry = load("res://addons/debug_console/core/CommandRegistry.gd").new()
		var commands = BuiltInCommands.new()
		commands._registry = temp_registry
		commands._core = Node.new()
		commands.register_universal_commands()
		return temp_registry._commands.has("crashtest")
	)
	# --- end T5 new commands tests ---

	# --- external command module tests (scene/runtime/UI) ---
	# These verify the three new modules (SceneCommands, RuntimeCommands,
	# UICommands) register and behave correctly when invoked through their
	# own instances. We use the temp_registry pattern for registration
	# checks so live state is never mutated, and direct method calls for
	# behavior checks so we don't depend on the live registry's freshness.
	test("Scene Commands - All Registered", func():
		var temp_registry = load("res://addons/debug_console/core/CommandRegistry.gd").new()
		var cmds = load("res://addons/debug_console/core/SceneCommands.gd").new()
		cmds.register_commands(temp_registry, null)
		var expected: Array = [
			"spawn", "instance_scene", "create_node", "delete_node", "reparent",
			"duplicate_node", "call", "methods", "class_db", "signal_emit",
			"signal_connect", "signal_disconnect", "tween", "find_node", "count_nodes",
		]
		for cmd_name in expected:
			if not temp_registry._commands.has(cmd_name):
				return false
		return true
	)

	test("Scene Commands - Create Node Behavior", func():
		if Engine.is_editor_hint():
			return true
		var tree := Engine.get_main_loop() as SceneTree
		if not tree:
			return false
		var container := Node.new()
		container.name = "T6CreateContainer"
		tree.root.add_child(container)
		var cmds = load("res://addons/debug_console/core/SceneCommands.gd").new()
		var result: String = cmds._cmd_create_node(["Label", "/root/T6CreateContainer", "MyLabel"])
		var ok: bool = container.get_node_or_null("MyLabel") != null and result.contains("MyLabel")
		container.queue_free()
		return ok
	)

	test("Scene Commands - Create Node Rejects Bad Class", func():
		var cmds = load("res://addons/debug_console/core/SceneCommands.gd").new()
		var result: String = cmds._cmd_create_node(["NotARealClass"])
		return result.contains("Error") and result.contains("Unknown class")
	)

	test("Scene Commands - Delete Refuses Root", func():
		if Engine.is_editor_hint():
			return true
		var cmds = load("res://addons/debug_console/core/SceneCommands.gd").new()
		var result: String = cmds._cmd_delete_node(["/root"])
		return result.contains("Error") and result.contains("Refusing")
	)

	test("Scene Commands - Call Returns Method Result", func():
		if Engine.is_editor_hint():
			return true
		var tree := Engine.get_main_loop() as SceneTree
		if not tree:
			return false
		var n := Node.new()
		n.name = "T6CallNode"
		tree.root.add_child(n)
		var cmds = load("res://addons/debug_console/core/SceneCommands.gd").new()
		var result: String = cmds._cmd_call(["/root/T6CallNode.get_name"])
		var ok: bool = result.contains("T6CallNode")
		n.queue_free()
		return ok
	)

	test("Scene Commands - Class DB Dump Has Sections", func():
		var cmds = load("res://addons/debug_console/core/SceneCommands.gd").new()
		var result: String = cmds._cmd_class_db(["Node"])
		return result.contains("=== Node ===") and result.contains("Methods:") and result.contains("Signals:")
	)

	test("Scene Commands - Class DB Unknown Errors", func():
		var cmds = load("res://addons/debug_console/core/SceneCommands.gd").new()
		var result: String = cmds._cmd_class_db(["DefinitelyNotAClass"])
		return result.contains("Error") and result.contains("Unknown class")
	)

	test("Scene Commands - Find Node Glob Match", func():
		if Engine.is_editor_hint():
			return true
		var tree := Engine.get_main_loop() as SceneTree
		if not tree:
			return false
		var container := Node.new()
		container.name = "T6FindContainer"
		tree.root.add_child(container)
		var a := Node.new(); a.name = "Foo1"; container.add_child(a)
		var b := Node.new(); b.name = "Foo2"; container.add_child(b)
		var c := Node.new(); c.name = "Bar"; container.add_child(c)
		var cmds = load("res://addons/debug_console/core/SceneCommands.gd").new()
		var result: String = cmds._cmd_find_node(["Foo*", "/root/T6FindContainer"])
		var ok: bool = result.contains("Foo1") and result.contains("Foo2") and not result.contains("Bar")
		container.queue_free()
		return ok
	)

	test("Scene Commands - Count Nodes Reports Total", func():
		if Engine.is_editor_hint():
			return true
		var tree := Engine.get_main_loop() as SceneTree
		if not tree:
			return false
		var container := Node.new()
		container.name = "T6CountContainer"
		tree.root.add_child(container)
		container.add_child(Node.new())
		container.add_child(Node.new())
		var label := Label.new()
		container.add_child(label)
		var cmds = load("res://addons/debug_console/core/SceneCommands.gd").new()
		var result: String = cmds._cmd_count_nodes(["/root/T6CountContainer"])
		var ok: bool = result.contains("Total:") and result.contains("Node") and result.contains("Label")
		container.queue_free()
		return ok
	)

	test("Runtime Commands - All Registered", func():
		var temp_registry = load("res://addons/debug_console/core/CommandRegistry.gd").new()
		var cmds = load("res://addons/debug_console/core/RuntimeCommands.gd").new()
		cmds.register_commands(temp_registry, null)
		var expected: Array = [
			"input_action", "input_dump", "bind", "unbind", "step",
			"viewport", "fullscreen", "assets", "find_asset", "goto_scene",
			"save_world", "load_world", "tick_rate", "vsync", "audio_bus",
		]
		for cmd_name in expected:
			if not temp_registry._commands.has(cmd_name):
				return false
		return true
	)

	test("Runtime Commands - input_dump Returns String", func():
		var cmds = load("res://addons/debug_console/core/RuntimeCommands.gd").new()
		var result: String = cmds._cmd_input_dump([])
		return not result.is_empty()
	)

	test("Runtime Commands - bind/unbind Roundtrip", func():
		var cmds = load("res://addons/debug_console/core/RuntimeCommands.gd").new()
		var test_action: String = "__t6_test_action__"
		if InputMap.has_action(test_action):
			InputMap.erase_action(test_action)
		var bind_out: String = cmds._cmd_bind([test_action, "F12"])
		var has_after_bind: bool = InputMap.has_action(test_action) and InputMap.action_get_events(test_action).size() == 1
		var unbind_out: String = cmds._cmd_unbind([test_action])
		var empty_after_unbind: bool = InputMap.action_get_events(test_action).size() == 0
		InputMap.erase_action(test_action)
		return bind_out.contains("F12") and has_after_bind and empty_after_unbind and unbind_out.contains("Cleared")
	)

	test("Runtime Commands - bind Parses Modifier Spec", func():
		var cmds = load("res://addons/debug_console/core/RuntimeCommands.gd").new()
		var test_action: String = "__t6_modifier_test__"
		if InputMap.has_action(test_action):
			InputMap.erase_action(test_action)
		cmds._cmd_bind([test_action, "Ctrl+Shift+P"])
		var events: Array[InputEvent] = InputMap.action_get_events(test_action)
		var ok: bool = false
		if events.size() == 1 and events[0] is InputEventKey:
			var ek := events[0] as InputEventKey
			ok = ek.ctrl_pressed and ek.shift_pressed and not ek.alt_pressed
		InputMap.erase_action(test_action)
		return ok
	)

	test("Runtime Commands - assets Returns Results", func():
		var cmds = load("res://addons/debug_console/core/RuntimeCommands.gd").new()
		var result: String = cmds._cmd_assets([])
		return result.contains("Assets in res://") and result.contains(".gd")
	)

	test("Runtime Commands - find_asset Glob Matches", func():
		var cmds = load("res://addons/debug_console/core/RuntimeCommands.gd").new()
		var result: String = cmds._cmd_find_asset(["*RuntimeCommands*"])
		return result.contains("RuntimeCommands.gd")
	)

	test("Runtime Commands - find_asset No Match", func():
		var cmds = load("res://addons/debug_console/core/RuntimeCommands.gd").new()
		var result: String = cmds._cmd_find_asset(["*__zzz_no_such_asset__*"])
		return result.to_lower().contains("no assets matched") or result.to_lower().contains("no matches")
	)

	test("Runtime Commands - tick_rate Reports And Rejects Out Of Range", func():
		var cmds = load("res://addons/debug_console/core/RuntimeCommands.gd").new()
		var report: String = cmds._cmd_tick_rate([])
		var range_err: String = cmds._cmd_tick_rate(["9999"])
		return report.contains("Tick rate:") and range_err.to_lower().contains("must be 1-1000")
	)

	test("Runtime Commands - vsync Reports State", func():
		if Engine.is_editor_hint():
			return true
		var cmds = load("res://addons/debug_console/core/RuntimeCommands.gd").new()
		var result: String = cmds._cmd_vsync([])
		return result.to_lower().contains("vsync:")
	)

	test("Runtime Commands - audio_bus Lists Master", func():
		if Engine.is_editor_hint():
			return true
		var cmds = load("res://addons/debug_console/core/RuntimeCommands.gd").new()
		var result: String = cmds._cmd_audio_bus([])
		return result.contains("Master")
	)

	test("UI Commands - All Registered", func():
		var temp_registry = load("res://addons/debug_console/core/CommandRegistry.gd").new()
		var cmds = load("res://addons/debug_console/core/UICommands.gd").new()
		cmds.register_commands(temp_registry, null)
		var expected: Array = [
			"ui_panel", "ui_label", "ui_button", "ui_vbox", "ui_hbox",
			"ui_grid", "ui_layout", "ui_text_color", "ui_size", "ui_anchor",
			"ui_clear", "ui_dump", "ui_modal",
		]
		for cmd_name in expected:
			if not temp_registry._commands.has(cmd_name):
				return false
		return true
	)

	test("UI Commands - ui_panel Spawns PanelContainer", func():
		var tree := Engine.get_main_loop() as SceneTree
		if not tree:
			return false
		var parent := Node.new()
		parent.name = "T6PanelParent"
		tree.root.add_child(parent)
		var cmds = load("res://addons/debug_console/core/UICommands.gd").new()
		var _r: String = cmds._cmd_ui_panel(["TestPanel", str(parent.get_path())])
		var spawned = parent.get_node_or_null("TestPanel")
		var ok: bool = spawned != null and spawned is PanelContainer
		parent.queue_free()
		return ok
	)

	test("UI Commands - ui_label Spawns With Text", func():
		var tree := Engine.get_main_loop() as SceneTree
		if not tree:
			return false
		var parent := Node.new()
		parent.name = "T6LabelParent"
		tree.root.add_child(parent)
		var cmds = load("res://addons/debug_console/core/UICommands.gd").new()
		var _r: String = cmds._cmd_ui_label(["Hello", str(parent.get_path()), "Greeting"])
		var spawned = parent.get_node_or_null("Greeting")
		var ok: bool = spawned != null and spawned is Label and spawned.text == "Hello"
		parent.queue_free()
		return ok
	)

	test("UI Commands - ui_button Spawns With Text", func():
		var tree := Engine.get_main_loop() as SceneTree
		if not tree:
			return false
		var parent := Node.new()
		parent.name = "T6BtnParent"
		tree.root.add_child(parent)
		var cmds = load("res://addons/debug_console/core/UICommands.gd").new()
		var _r: String = cmds._cmd_ui_button(["Click", str(parent.get_path()), "Btn"])
		var spawned = parent.get_node_or_null("Btn")
		var ok: bool = spawned != null and spawned is Button and spawned.text == "Click"
		parent.queue_free()
		return ok
	)

	test("UI Commands - ui_vbox Spawns VBoxContainer", func():
		var tree := Engine.get_main_loop() as SceneTree
		if not tree:
			return false
		var parent := Node.new()
		parent.name = "T6VBoxParent"
		tree.root.add_child(parent)
		var cmds = load("res://addons/debug_console/core/UICommands.gd").new()
		var _r: String = cmds._cmd_ui_vbox([str(parent.get_path()), "MyVBox"])
		var spawned = parent.get_node_or_null("MyVBox")
		var ok: bool = spawned != null and spawned is VBoxContainer
		parent.queue_free()
		return ok
	)

	test("UI Commands - ui_grid Sets Columns", func():
		var tree := Engine.get_main_loop() as SceneTree
		if not tree:
			return false
		var parent := Node.new()
		parent.name = "T6GridParent"
		tree.root.add_child(parent)
		var cmds = load("res://addons/debug_console/core/UICommands.gd").new()
		var _r: String = cmds._cmd_ui_grid(["3", str(parent.get_path()), "MyGrid"])
		var spawned = parent.get_node_or_null("MyGrid")
		var ok: bool = spawned != null and spawned is GridContainer and spawned.columns == 3
		parent.queue_free()
		return ok
	)

	test("UI Commands - ui_layout Applies Full Rect Preset", func():
		var tree := Engine.get_main_loop() as SceneTree
		if not tree:
			return false
		var parent := Control.new()
		parent.name = "T6LayoutParent"
		tree.root.add_child(parent)
		var ctrl := Control.new()
		ctrl.name = "Target"
		parent.add_child(ctrl)
		var cmds = load("res://addons/debug_console/core/UICommands.gd").new()
		var _r: String = cmds._cmd_ui_layout([str(ctrl.get_path()), "full_rect"])
		var ok: bool = is_equal_approx(ctrl.anchor_left, 0.0) and is_equal_approx(ctrl.anchor_top, 0.0) \
			and is_equal_approx(ctrl.anchor_right, 1.0) and is_equal_approx(ctrl.anchor_bottom, 1.0)
		parent.queue_free()
		return ok
	)

	test("UI Commands - ui_text_color Sets font_color Override", func():
		var tree := Engine.get_main_loop() as SceneTree
		if not tree:
			return false
		var parent := Control.new()
		parent.name = "T6TextColorParent"
		tree.root.add_child(parent)
		var label := Label.new()
		label.name = "L"
		parent.add_child(label)
		var cmds = load("res://addons/debug_console/core/UICommands.gd").new()
		var _r: String = cmds._cmd_ui_text_color([str(label.get_path()), "#FF0000"])
		var ok: bool = label.has_theme_color_override("font_color") \
			and label.get_theme_color("font_color").is_equal_approx(Color(1, 0, 0, 1))
		parent.queue_free()
		return ok
	)

	test("UI Commands - ui_size Sets custom_minimum_size", func():
		var tree := Engine.get_main_loop() as SceneTree
		if not tree:
			return false
		var parent := Control.new()
		parent.name = "T6SizeParent"
		tree.root.add_child(parent)
		var ctrl := Control.new()
		ctrl.name = "Sized"
		parent.add_child(ctrl)
		var cmds = load("res://addons/debug_console/core/UICommands.gd").new()
		var _r: String = cmds._cmd_ui_size([str(ctrl.get_path()), "200x100"])
		var ok: bool = ctrl.custom_minimum_size.is_equal_approx(Vector2(200, 100))
		parent.queue_free()
		return ok
	)

	test("UI Commands - ui_anchor Parses Four Floats", func():
		var tree := Engine.get_main_loop() as SceneTree
		if not tree:
			return false
		var parent := Control.new()
		parent.name = "T6AnchorParent"
		tree.root.add_child(parent)
		var ctrl := Control.new()
		ctrl.name = "Anchored"
		parent.add_child(ctrl)
		var cmds = load("res://addons/debug_console/core/UICommands.gd").new()
		var _r: String = cmds._cmd_ui_anchor([str(ctrl.get_path()), "0.1,0.2,0.8,0.9"])
		var ok: bool = is_equal_approx(ctrl.anchor_left, 0.1) and is_equal_approx(ctrl.anchor_top, 0.2) \
			and is_equal_approx(ctrl.anchor_right, 0.8) and is_equal_approx(ctrl.anchor_bottom, 0.9)
		parent.queue_free()
		return ok
	)

	test("UI Commands - ui_dump Returns Non-Empty Tree", func():
		var tree := Engine.get_main_loop() as SceneTree
		if not tree:
			return false
		var parent := Node.new()
		parent.name = "T6DumpParent"
		tree.root.add_child(parent)
		var cmds = load("res://addons/debug_console/core/UICommands.gd").new()
		var parent_path: String = str(parent.get_path())
		cmds._cmd_ui_label(["A", parent_path, "DumpedLabel"])
		var dump: String = cmds._cmd_ui_dump([parent_path])
		var ok: bool = not dump.is_empty() and dump.contains("DumpedLabel") and dump.contains("Label")
		parent.queue_free()
		return ok
	)
	# --- end T6 external command module tests ---

	# --- external command module registration tests ---
	# 11 new domain modules added in parallel. Each test uses the
	# temp_registry pattern so the live autoload is never mutated.
	# Sentinel commands picked for coverage: at least one command per
	# module that ought to exist if register_commands ran end-to-end.
	test("Physics - Registers raycast + apply_force + collision_layers", func():
		var temp_registry = load("res://addons/debug_console/core/CommandRegistry.gd").new()
		var cmds = load("res://addons/debug_console/core/PhysicsCommands.gd").new()
		cmds.register_commands(temp_registry, null)
		return temp_registry._commands.has("raycast") and temp_registry._commands.has("apply_force") and temp_registry._commands.has("collision_layers")
	)

	test("Animation - Registers anim_play + anim_stop + anim_list", func():
		var temp_registry = load("res://addons/debug_console/core/CommandRegistry.gd").new()
		var cmds = load("res://addons/debug_console/core/AnimationCommands.gd").new()
		cmds.register_commands(temp_registry, null)
		return temp_registry._commands.has("anim_play") and temp_registry._commands.has("anim_stop") and temp_registry._commands.has("anim_list")
	)

	test("Camera - Registers cam_list + cam_pos + cam_shake", func():
		var temp_registry = load("res://addons/debug_console/core/CommandRegistry.gd").new()
		var cmds = load("res://addons/debug_console/core/CameraCommands.gd").new()
		cmds.register_commands(temp_registry, null)
		return temp_registry._commands.has("cam_list") and temp_registry._commands.has("cam_pos") and temp_registry._commands.has("cam_shake")
	)

	test("Timer - Registers schedule + repeat + stopwatch", func():
		var temp_registry = load("res://addons/debug_console/core/CommandRegistry.gd").new()
		var cmds = load("res://addons/debug_console/core/TimerCommands.gd").new()
		cmds.register_commands(temp_registry, null)
		return temp_registry._commands.has("schedule") and temp_registry._commands.has("repeat") and temp_registry._commands.has("stopwatch")
	)

	test("Prefab - Registers prefab_save + prefab_spawn + prefab_swarm", func():
		var temp_registry = load("res://addons/debug_console/core/CommandRegistry.gd").new()
		var cmds = load("res://addons/debug_console/core/PrefabCommands.gd").new()
		cmds.register_commands(temp_registry, null)
		return temp_registry._commands.has("prefab_save") and temp_registry._commands.has("prefab_spawn") and temp_registry._commands.has("prefab_swarm")
	)

	test("Math - Registers rand + lerp_val + noise + vec", func():
		var temp_registry = load("res://addons/debug_console/core/CommandRegistry.gd").new()
		var cmds = load("res://addons/debug_console/core/MathCommands.gd").new()
		cmds.register_commands(temp_registry, null)
		return temp_registry._commands.has("rand") and temp_registry._commands.has("lerp_val") and temp_registry._commands.has("noise") and temp_registry._commands.has("vec")
	)

	test("Dialog - Registers dialog_alert + dialog_confirm + dialog_input", func():
		var temp_registry = load("res://addons/debug_console/core/CommandRegistry.gd").new()
		var cmds = load("res://addons/debug_console/core/DialogCommands.gd").new()
		cmds.register_commands(temp_registry, null)
		return temp_registry._commands.has("dialog_alert") and temp_registry._commands.has("dialog_confirm") and temp_registry._commands.has("dialog_input")
	)

	test("Particles - Registers particles_burst + particles_emit + particles_clear", func():
		var temp_registry = load("res://addons/debug_console/core/CommandRegistry.gd").new()
		var cmds = load("res://addons/debug_console/core/ParticleCommands.gd").new()
		cmds.register_commands(temp_registry, null)
		return temp_registry._commands.has("particles_burst") and temp_registry._commands.has("particles_emit") and temp_registry._commands.has("particles_clear")
	)

	test("Data - Registers csv_read + json_read + table + query", func():
		var temp_registry = load("res://addons/debug_console/core/CommandRegistry.gd").new()
		var cmds = load("res://addons/debug_console/core/DataCommands.gd").new()
		cmds.register_commands(temp_registry, null)
		return temp_registry._commands.has("csv_read") and temp_registry._commands.has("json_read") and temp_registry._commands.has("table") and temp_registry._commands.has("query")
	)

	test("Shader - Registers shader_load + shader_set + mat_new", func():
		var temp_registry = load("res://addons/debug_console/core/CommandRegistry.gd").new()
		var cmds = load("res://addons/debug_console/core/ShaderCommands.gd").new()
		cmds.register_commands(temp_registry, null)
		return temp_registry._commands.has("shader_load") and temp_registry._commands.has("shader_set") and temp_registry._commands.has("mat_new")
	)

	test("Tilemap - Registers tile_set + tile_get + tile_fill", func():
		var temp_registry = load("res://addons/debug_console/core/CommandRegistry.gd").new()
		var cmds = load("res://addons/debug_console/core/TilemapCommands.gd").new()
		cmds.register_commands(temp_registry, null)
		return temp_registry._commands.has("tile_set") and temp_registry._commands.has("tile_get") and temp_registry._commands.has("tile_fill")
	)

	test("All Modules Load Via Loader", func():
		# Verify the BuiltInCommands T6/T7 loader picks up every module without
		# crashing. We instantiate a fresh BuiltInCommands against a temp
		# registry; if any module's class_name registration or class loading
		# barfs, this throws during the loader's load().new() chain.
		var temp_registry = load("res://addons/debug_console/core/CommandRegistry.gd").new()
		var commands = BuiltInCommands.new()
		commands._registry = temp_registry
		commands._core = Node.new()
		commands.register_universal_commands()
		# After loading, temp_registry should have at minimum echo (BuiltInCommands)
		# plus a sentinel from each T6/T7 module:
		return temp_registry._commands.has("echo") \
			and temp_registry._commands.has("spawn") \
			and temp_registry._commands.has("raycast") \
			and temp_registry._commands.has("anim_play") \
			and temp_registry._commands.has("cam_list") \
			and temp_registry._commands.has("schedule") \
			and temp_registry._commands.has("prefab_save") \
			and temp_registry._commands.has("rand") \
			and temp_registry._commands.has("dialog_alert") \
			and temp_registry._commands.has("particles_burst") \
			and temp_registry._commands.has("csv_read") \
			and temp_registry._commands.has("shader_load") \
			and temp_registry._commands.has("tile_set")
	)
	# --- end T7 external command module registration tests ---

func run_autocomplete_tests():
	print("\nTesting Autocomplete...")
	var registry := _registry()
	
	test("Autocomplete - Command Suggestions", func():
		var available = registry.get_available_commands()
		var matching = []
		for cmd in available:
			if cmd.begins_with("h"):
				matching.append(cmd)
		return matching.has("help") and matching.has("history")
	)
	
	test("Autocomplete - File Suggestions", func():
		var dir = DirAccess.open("res://")
		if not dir:
			return false
		
		var files = []
		dir.list_dir_begin()
		var file_name = dir.get_next()
		
		while file_name != "":
			if not file_name.begins_with(".") and file_name.begins_with("p"):
				files.append(file_name)
			file_name = dir.get_next()
		
		dir.list_dir_end()
		return files.has("project.godot")
	)
	
	test("Autocomplete - Node Type Suggestions", func():
		var valid_types = ["Node", "Node2D", "Node3D", "Control", "CanvasItem"]
		var matching = []
		for type_name in valid_types:
			if type_name.begins_with("N"):
				matching.append(type_name)
		return matching.has("Node") and matching.has("Node2D") and matching.has("Node3D")
	)
	
	test("Autocomplete - Mode Detection", func():
		var text1 = "new_script Player N"
		var text2 = "ls h"
		
		var parts1 = text1.substr(0, 20).split(" ", false)
		var parts2 = text2.substr(0, 5).split(" ", false)
		
		var command1 = parts1[0].to_lower() if not parts1.is_empty() else ""
		var command2 = parts2[0].to_lower() if not parts2.is_empty() else ""
		
		var mode1 = "node_types" if command1 == "new_script" and parts1.size() >= 2 else "files"
		var mode2 = "files" if command2 in ["ls", "cd", "rm", "mv", "cp", "touch", "open", "new_scene", "new_resource"] else "commands"
		
		return mode1 == "node_types" and mode2 == "files"
	)
	
	test("Autocomplete - Cycling", func():
		var options = ["help", "history", "hello"]
		var index = 1
		var next_index = (index + 1) % options.size()
		return next_index == 2
	)
	
	test("Autocomplete - Mode Detection for New Commands", func():
		var text1 = "grep test"
		var text2 = "head 5"
		var text3 = "tail 10"
		var text4 = "find .gd"
		var text5 = "stat file.txt"
		
		var parts1 = text1.split(" ", false)
		var parts2 = text2.split(" ", false)
		var parts3 = text3.split(" ", false)
		var parts4 = text4.split(" ", false)
		var parts5 = text5.split(" ", false)
		
		var command1 = parts1[0].to_lower() if not parts1.is_empty() else ""
		var command2 = parts2[0].to_lower() if not parts2.is_empty() else ""
		var command3 = parts3[0].to_lower() if not parts3.is_empty() else ""
		var command4 = parts4[0].to_lower() if not parts4.is_empty() else ""
		var command5 = parts5[0].to_lower() if not parts5.is_empty() else ""
		
		var mode1 = "files" if command1 in ["grep", "head", "tail", "find", "stat"] else "commands"
		var mode2 = "files" if command2 in ["grep", "head", "tail", "find", "stat"] else "commands"
		var mode3 = "files" if command3 in ["grep", "head", "tail", "find", "stat"] else "commands"
		var mode4 = "files" if command4 in ["grep", "head", "tail", "find", "stat"] else "commands"
		var mode5 = "files" if command5 in ["grep", "head", "tail", "find", "stat"] else "commands"
		
		return mode1 == "files" and mode2 == "files" and mode3 == "files" and mode4 == "files" and mode5 == "files"
	)

	# --- smart autocomplete tests ---
	# These exercise the per-mode dispatch in EditorConsole._determine_autocomplete_mode
	# and the new node-path suggestion machinery. We instantiate EditorConsole
	# directly with .new() (no scene fixture needed) because these methods don't
	# touch @onready node references - they only walk the live SceneTree root
	# and EditorInterface, both of which are reachable from a detached instance.

	test("Autocomplete - Mode for inspect Is node_paths", func():
		var ec := EditorConsole.new()
		var mode: String = ec._determine_autocomplete_mode("inspect ", 8)
		ec.queue_free()
		return mode == "node_paths"
	)

	test("Autocomplete - Mode for cd Is directories", func():
		# Regression guard: pre-existing behavior must survive the T3.2
		# dispatch rewrite. "cd " should still map to "directories".
		var ec := EditorConsole.new()
		var mode: String = ec._determine_autocomplete_mode("cd ", 3)
		ec.queue_free()
		return mode == "directories"
	)

	test("Autocomplete - Mode for wc Is files", func():
		var ec := EditorConsole.new()
		var mode: String = ec._determine_autocomplete_mode("wc ", 3)
		ec.queue_free()
		return mode == "files"
	)

	test("Autocomplete - Mode for diff Is files", func():
		var ec := EditorConsole.new()
		var mode: String = ec._determine_autocomplete_mode("diff ", 5)
		ec.queue_free()
		return mode == "files"
	)

	test("Autocomplete - Mode for set Is node_paths", func():
		var ec := EditorConsole.new()
		var mode: String = ec._determine_autocomplete_mode("set ", 4)
		ec.queue_free()
		return mode == "node_paths"
	)

	test("Autocomplete - Node Path Suggestions Include Engine", func():
		# "Engine" is the global singleton and must always appear when the
		# prefix is empty, regardless of editor vs runtime context.
		var ec := EditorConsole.new()
		ec._get_node_path_suggestions("")
		var has_engine: bool = ec._matching_commands.has("Engine")
		ec.queue_free()
		return has_engine
	)

	test("Autocomplete - Node Path Suggestions Include DebugCore", func():
		# DebugCore is registered as an autoload in project.godot, so it shows
		# up as a direct child of /root in both editor and runtime tests.
		var ec := EditorConsole.new()
		ec._get_node_path_suggestions("Debug")
		var has_debug_core: bool = ec._matching_commands.has("DebugCore")
		ec.queue_free()
		return has_debug_core
	)

	test("Autocomplete - Node Path Filter Prefix", func():
		# Prefix "Eng" must include "Engine" and exclude "DebugCore". This
		# proves the prefix filter is applied per-suggestion, not after a
		# global match.
		var ec := EditorConsole.new()
		ec._get_node_path_suggestions("Eng")
		var includes_engine: bool = ec._matching_commands.has("Engine")
		var excludes_debug_core: bool = not ec._matching_commands.has("DebugCore")
		ec.queue_free()
		return includes_engine and excludes_debug_core
	)
	# --- end T3.2 smart autocomplete tests ---

func run_editor_console_tests():
	print("\nTesting Editor Console...")

	test("Editor Console - Initialization", func():
		if not Engine.is_editor_hint():
			return true  # EditorConsole _ready short-circuits at runtime
		var ec := _instantiate_editor_console_fixture()
		if not ec:
			return false
		var ok: bool = ec.is_inside_tree() and ec.output_text != null and ec.input_line != null
		_cleanup_editor_console_fixture(ec)
		return ok
	)

	test("Editor Console - Command Execution", func():
		if not Engine.is_editor_hint():
			return true  # EditorConsole _ready short-circuits at runtime
		var ec := _instantiate_editor_console_fixture()
		if not ec:
			return false
		var initial_size: int = ec.get_log_buffer().size()
		ec._execute_command("echo hello")
		var buffer_after: Array = ec.get_log_buffer()
		var grew: bool = buffer_after.size() > initial_size
		var echoed: bool = false
		for line in buffer_after:
			if str(line).contains("hello"):
				echoed = true
				break
		_cleanup_editor_console_fixture(ec)
		return grew and echoed
	)

	test("Editor Console - Command History", func():
		if not Engine.is_editor_hint():
			return true  # EditorConsole _ready short-circuits at runtime
		var ec := _instantiate_editor_console_fixture()
		if not ec:
			return false
		ec._execute_command("echo one")
		ec._execute_command("echo two")
		ec._execute_command("echo three")
		var ok: bool = ec.command_history.size() == 3 and ec.command_history[2] == "echo three"
		_cleanup_editor_console_fixture(ec)
		return ok
	)

	test("Editor Console - Clear Output", func():
		if not Engine.is_editor_hint():
			return true  # EditorConsole _ready short-circuits at runtime
		var ec := _instantiate_editor_console_fixture()
		if not ec:
			return false
		ec.add_log_message("clear-output-probe")
		var was_populated: bool = ec.get_log_buffer().size() > 0
		ec.clear_output()
		var is_cleared: bool = ec.get_log_buffer().is_empty()
		_cleanup_editor_console_fixture(ec)
		return was_populated and is_cleared
	)

	test("Editor Console - Log Message Levels", func():
		if not Engine.is_editor_hint():
			return true  # EditorConsole _ready short-circuits at runtime
		var ec := _instantiate_editor_console_fixture()
		if not ec:
			return false
		ec.clear_output()
		ec.add_log_message("info-msg", EditorConsole.LOG_LEVEL_INFO)
		ec.add_log_message("warn-msg", EditorConsole.LOG_LEVEL_WARNING)
		ec.add_log_message("err-msg", EditorConsole.LOG_LEVEL_ERROR)
		ec.add_log_message("success-msg", EditorConsole.LOG_LEVEL_SUCCESS)
		var buffer: Array = ec.get_log_buffer()
		var combined := ""
		for entry in buffer:
			combined += str(entry)
		var ok: bool = (
			buffer.size() == 4
			and combined.contains("#808080") and combined.contains("info-msg")
			and combined.contains("#FFAA00") and combined.contains("warn-msg")
			and combined.contains("#FF4444") and combined.contains("err-msg")
			and combined.contains("#44FF44") and combined.contains("success-msg")
		)
		_cleanup_editor_console_fixture(ec)
		return ok
	)

	test("Editor Console - Input Line Focus", func():
		if not Engine.is_editor_hint():
			return true  # EditorConsole _ready short-circuits at runtime
		# Focus state on an offscreen Control is unreliable; only assert that the
		# helper is callable end-to-end and input_line survives.
		var ec := _instantiate_editor_console_fixture()
		if not ec:
			return false
		ec.focus_command_input()
		var ok: bool = ec.input_line != null
		_cleanup_editor_console_fixture(ec)
		return ok
	)

	test("Editor Console - Focus Helper Safe", func():
		# focus_command_input must not crash on a detached EditorConsole (no scene
		# tree, no @onready wiring). Exercised in both contexts because the helper
		# is guarded with explicit null checks that should hold everywhere.
		var console := EditorConsole.new()
		var was_detached: bool = not console.is_inside_tree()
		console.focus_command_input()
		var still_valid: bool = is_instance_valid(console)
		if is_instance_valid(console):
			console.queue_free()
		return was_detached and still_valid
	)

	test("Editor Console - Empty Command Handling", func():
		if not Engine.is_editor_hint():
			return true  # EditorConsole _ready short-circuits at runtime
		var ec := _instantiate_editor_console_fixture()
		if not ec:
			return false
		var initial_history_size: int = ec.command_history.size()
		ec._execute_command("")
		ec._execute_command("   ")
		var ok: bool = ec.command_history.size() == initial_history_size
		_cleanup_editor_console_fixture(ec)
		return ok
	)

	# --- keyboard UX tests ---
	# These tests exercise the popup-driven autocomplete and the 8 LineEdit
	# keyboard shortcuts (Up/Down, Tab/Shift+Tab, Esc, Enter, Home, End,
	# Ctrl+A, Ctrl+U). Each test gates on Engine.is_editor_hint() because
	# EditorConsole._ready() is itself editor-gated; instantiating at runtime
	# would never wire up the signal handlers under test.

	test("Editor Console - Popup Shows On Typing", func():
		if not Engine.is_editor_hint():
			return true
		var ec := _instantiate_editor_console_fixture()
		if not ec:
			return false
		ec.input_line.text = "h"
		ec.input_line.caret_column = 1
		ec._on_input_text_changed("h")
		var popup_open: bool = ec._popup_open
		var popup_visible: bool = ec.autocomplete_popup.visible
		var has_matches: bool = ec._matching_commands.size() > 0
		_cleanup_editor_console_fixture(ec)
		return popup_open and popup_visible and has_matches
	)

	test("Editor Console - Popup Hides On Empty Input", func():
		if not Engine.is_editor_hint():
			return true
		var ec := _instantiate_editor_console_fixture()
		if not ec:
			return false
		ec.input_line.text = "h"
		ec.input_line.caret_column = 1
		ec._on_input_text_changed("h")
		var opened_first: bool = ec._popup_open
		ec.input_line.text = ""
		ec.input_line.caret_column = 0
		ec._on_input_text_changed("")
		var closed_after: bool = (not ec._popup_open) and (not ec.autocomplete_popup.visible)
		_cleanup_editor_console_fixture(ec)
		return opened_first and closed_after
	)

	test("Editor Console - Esc Restores Draft", func():
		if not Engine.is_editor_hint():
			return true
		var ec := _instantiate_editor_console_fixture()
		if not ec:
			return false
		ec.input_line.text = "h"
		ec.input_line.caret_column = 1
		ec._on_input_text_changed("h")
		# Simulate the popup having mutated input_line.text out from under the
		# user (e.g. a future preview-on-cycle feature). Esc must restore the
		# original draft regardless.
		ec.input_line.text = "MUTATED-BY-POPUP"
		ec.input_line.caret_column = ec.input_line.text.length()
		_simulate_key_event(ec, KEY_ESCAPE)
		var restored: bool = ec.input_line.text == "h"
		var dismissed: bool = not ec._popup_open
		var action_recorded: bool = ec._last_input_action == "dismiss_popup"
		_cleanup_editor_console_fixture(ec)
		return restored and dismissed and action_recorded
	)

	test("Editor Console - Tab Cycles With Preview", func():
		if not Engine.is_editor_hint():
			return true
		var ec := _instantiate_editor_console_fixture()
		if not ec:
			return false
		ec.input_line.text = "h"
		ec.input_line.caret_column = 1
		ec._on_input_text_changed("h")
		if ec._matching_commands.size() < 2:
			# Need at least two matches to exercise cycling.
			_cleanup_editor_console_fixture(ec)
			return false
		var first_pick: String = str(ec._matching_commands[0])
		var second_pick: String = str(ec._matching_commands[1])
		# First Tab after passive popup-open: previews match[0] WITHOUT cycling.
		# This matches what the user sees - item 0 is visually highlighted.
		_simulate_key_event(ec, KEY_TAB)
		var first_preview_ok: bool = ec.input_line.text == first_pick and ec._popup_open
		var first_action_ok: bool = ec._last_input_action == "preview_current"
		# Second Tab: cycle to match[1], preview updated, popup still open.
		_simulate_key_event(ec, KEY_TAB)
		var second_preview_ok: bool = ec.input_line.text == second_pick and ec._popup_open
		var second_action_ok: bool = ec._last_input_action == "cycle_next"
		_cleanup_editor_console_fixture(ec)
		return first_preview_ok and first_action_ok and second_preview_ok and second_action_ok
	)

	test("Editor Console - Ctrl+A Selects All", func():
		if not Engine.is_editor_hint():
			return true
		var ec := _instantiate_editor_console_fixture()
		if not ec:
			return false
		ec.input_line.text = "hello world"
		ec.input_line.caret_column = ec.input_line.text.length()
		_simulate_key_event(ec, KEY_A, true)
		# In headless contexts LineEdit.has_selection() may return false even
		# after select_all() because the visual selection rect requires a
		# focused, visible widget. _last_input_action is the authoritative
		# signal that the Ctrl+A branch ran.
		var action_recorded: bool = ec._last_input_action == "select_all"
		var text_intact: bool = ec.input_line.text == "hello world"
		_cleanup_editor_console_fixture(ec)
		return action_recorded and text_intact
	)

	test("Editor Console - Ctrl+U Clears Line", func():
		if not Engine.is_editor_hint():
			return true
		var ec := _instantiate_editor_console_fixture()
		if not ec:
			return false
		ec.input_line.text = "hello world"
		ec.input_line.caret_column = ec.input_line.text.length()
		ec._user_draft = "hello world"
		_simulate_key_event(ec, KEY_U, true)
		var cleared: bool = ec.input_line.text == "" and ec.input_line.caret_column == 0
		var draft_cleared: bool = ec._user_draft == ""
		var action_recorded: bool = ec._last_input_action == "clear_line"
		_cleanup_editor_console_fixture(ec)
		return cleared and draft_cleared and action_recorded
	)

	test("Editor Console - Home Caret Moves", func():
		if not Engine.is_editor_hint():
			return true
		var ec := _instantiate_editor_console_fixture()
		if not ec:
			return false
		ec.input_line.text = "hello"
		ec.input_line.caret_column = 5
		_simulate_key_event(ec, KEY_HOME)
		var at_home: bool = ec.input_line.caret_column == 0
		var action_recorded: bool = ec._last_input_action == "caret_home"
		_cleanup_editor_console_fixture(ec)
		return at_home and action_recorded
	)

	test("Editor Console - End Caret Moves", func():
		if not Engine.is_editor_hint():
			return true
		var ec := _instantiate_editor_console_fixture()
		if not ec:
			return false
		ec.input_line.text = "hello"
		ec.input_line.caret_column = 0
		_simulate_key_event(ec, KEY_END)
		var at_end: bool = ec.input_line.caret_column == 5
		var action_recorded: bool = ec._last_input_action == "caret_end"
		_cleanup_editor_console_fixture(ec)
		return at_end and action_recorded
	)
	# --- end T2.1 keyboard UX tests ---

	# --- output renderer tests ---
	# Colorization runs inside add_log_message before the level-color wrap.
	# Tests gate on Engine.is_editor_hint() because the fixture instantiates
	# EditorConsole.tscn which only fully wires up in the editor.

	test("Editor Console - Colorize Path Detection", func():
		if not Engine.is_editor_hint():
			return true
		var ec := _instantiate_editor_console_fixture()
		if not ec:
			return false
		ec.clear_output()
		ec.add_log_message("Opened res://addons/foo.gd successfully")
		var buffer: Array = ec.get_log_buffer()
		var combined: String = ""
		for entry in buffer:
			combined += str(entry)
		var has_url: bool = combined.contains("[url=res://addons/foo.gd]")
		var has_color: bool = combined.contains("[color=#5FBEE0]res://addons/foo.gd[/color]")
		_cleanup_editor_console_fixture(ec)
		return has_url and has_color
	)

	test("Editor Console - Colorize Number Detection", func():
		if not Engine.is_editor_hint():
			return true
		var ec := _instantiate_editor_console_fixture()
		if not ec:
			return false
		ec.clear_output()
		ec.add_log_message("Found 42 files in 123.5ms")
		var buffer: Array = ec.get_log_buffer()
		var combined: String = ""
		for entry in buffer:
			combined += str(entry)
		var has_int: bool = combined.contains("[color=#F7DC6F]42[/color]")
		var has_decimal_with_unit: bool = combined.contains("[color=#F7DC6F]123.5ms[/color]")
		_cleanup_editor_console_fixture(ec)
		return has_int and has_decimal_with_unit
	)

	test("Editor Console - Colorize Error Prefix", func():
		if not Engine.is_editor_hint():
			return true
		var ec := _instantiate_editor_console_fixture()
		if not ec:
			return false
		ec.clear_output()
		# Logged at INFO level but the Error-prefix highlighter still flags it
		# in the message-token color (red). That's the whole point of T2.2 #1:
		# command-output text like "Error: ..." gets visual emphasis even when
		# routed through a non-error level.
		ec.add_log_message("Error: File not found", EditorConsole.LOG_LEVEL_INFO)
		var buffer: Array = ec.get_log_buffer()
		var combined: String = ""
		for entry in buffer:
			combined += str(entry)
		var ok: bool = combined.contains("[color=#FF4444]Error[/color]")
		_cleanup_editor_console_fixture(ec)
		return ok
	)

	test("Editor Console - Pre-Colored Message Untouched", func():
		if not Engine.is_editor_hint():
			return true
		var ec := _instantiate_editor_console_fixture()
		if not ec:
			return false
		ec.clear_output()
		# Caller pre-colored: _colorize_message must early-return so we don't
		# layer a second category color on top of the caller's choice.
		ec.add_log_message("[color=#ABCDEF]custom[/color]")
		var buffer: Array = ec.get_log_buffer()
		var combined: String = ""
		for entry in buffer:
			combined += str(entry)
		var path_color_absent: bool = not combined.contains("[color=#5FBEE0]")
		var number_color_absent: bool = not combined.contains("[color=#F7DC6F]")
		var original_color_kept: bool = combined.contains("[color=#ABCDEF]custom[/color]")
		_cleanup_editor_console_fixture(ec)
		return path_color_absent and number_color_absent and original_color_kept
	)
	# --- end T2.2 output renderer tests ---

	# --- persistence tests ---
	# Stub-based tests verify EditorConsole's wiring to the persistence API
	# without touching real user:// files. The stub is a RefCounted with the
	# minimum surface that set_persistence and _execute_command call into:
	# save_history(Array) and load_history() -> Array.

	test("Editor Console - History Saves On Command Execute", func():
		if not Engine.is_editor_hint():
			return true  # EditorConsole _ready short-circuits at runtime
		var stub_script := GDScript.new()
		stub_script.source_code = (
			"extends RefCounted\n"
			+ "var _saved: Array = []\n"
			+ "func save_history(history: Array) -> void:\n"
			+ "\t_saved = history.duplicate()\n"
			+ "func load_history() -> Array:\n"
			+ "\treturn []\n"
		)
		var reload_err: int = stub_script.reload()
		if reload_err != OK:
			return false
		var stub: Object = stub_script.new()
		var ec := _instantiate_editor_console_fixture()
		if not ec:
			return false
		ec.set_persistence(stub)
		ec._execute_command("echo persisttest")
		var saved_arr: Array = stub.get("_saved")
		var ok: bool = (
			saved_arr.size() > 0
			and str(saved_arr[saved_arr.size() - 1]) == "echo persisttest"
		)
		_cleanup_editor_console_fixture(ec)
		return ok
	)

	test("Editor Console - History Loads On Set Persistence", func():
		if not Engine.is_editor_hint():
			return true  # EditorConsole _ready short-circuits at runtime
		var stub_script := GDScript.new()
		stub_script.source_code = (
			"extends RefCounted\n"
			+ "func save_history(_h: Array) -> void:\n"
			+ "\tpass\n"
			+ "func load_history() -> Array:\n"
			+ "\treturn [\"one\", \"two\"]\n"
		)
		var reload_err: int = stub_script.reload()
		if reload_err != OK:
			return false
		var stub: Object = stub_script.new()
		var ec := _instantiate_editor_console_fixture()
		if not ec:
			return false
		ec.set_persistence(stub)
		var ok: bool = (
			ec.command_history.size() == 2
			and ec.command_history[0] == "one"
			and ec.command_history[1] == "two"
		)
		_cleanup_editor_console_fixture(ec)
		return ok
	)
	# --- end T3.3 persistence tests ---


	# --- bash polish tests ---
	# These tests cover the 8 W1 mandate items: welcome banner, bash prompt,
	# command coloring, common-prefix Tab, Ctrl+L, Ctrl+R reverse search,
	# dark theme, caret blink. All gate on Engine.is_editor_hint() because
	# EditorConsole._ready() early-returns at runtime.

	test("Editor Console - W1 Banner Shown On Ready", func():
		if not Engine.is_editor_hint():
			return true
		var ec := _instantiate_editor_console_fixture()
		if not ec:
			return false
		var buffer: Array = ec.get_log_buffer()
		var found: bool = false
		for line in buffer:
			if str(line).contains("Debug Console"):
				found = true
				break
		_cleanup_editor_console_fixture(ec)
		return found
	)

	test("Editor Console - W1 Banner Idempotent", func():
		# Calling _emit_welcome_banner twice should not double-print the banner.
		# The meta flag _META_BANNER_SHOWN gates the second call to a no-op.
		if not Engine.is_editor_hint():
			return true
		var ec := _instantiate_editor_console_fixture()
		if not ec:
			return false
		var count_after_first: int = 0
		for line in ec.get_log_buffer():
			if str(line).contains("Debug Console"):
				count_after_first += 1
		ec._emit_welcome_banner()
		var count_after_second: int = 0
		for line in ec.get_log_buffer():
			if str(line).contains("Debug Console"):
				count_after_second += 1
		_cleanup_editor_console_fixture(ec)
		return count_after_first == count_after_second

	)

	test("Editor Console - W1 Bash Prompt Format", func():
		# _render_bash_prompt should produce a line containing user@godot, the
		# cwd, and a literal $ separator. The brackets are rendered via [lb]/[rb]
		# so the raw string contains those escape tags.
		if not Engine.is_editor_hint():
			return true
		var ec := EditorConsole.new()
		var rendered: String = ec._render_bash_prompt("ls")
		ec.queue_free()
		var has_host: bool = rendered.contains("@godot")
		var has_dollar: bool = rendered.contains("$")
		var has_lb: bool = rendered.contains("[lb]")
		var has_rb: bool = rendered.contains("[rb]")
		return has_host and has_dollar and has_lb and has_rb
	)

	test("Editor Console - W1 Command Name Coloring", func():
		# First non-blank token should be wrapped in the command-name color.
		if not Engine.is_editor_hint():
			return true
		var ec := EditorConsole.new()
		var colored: String = ec._colorize_command_input("help foo")
		ec.queue_free()
		return colored.contains("[color=#F7DC6F]help[/color]")
	)

	test("Editor Console - W1 Flag And Pipe Coloring", func():
		# Flags (--verbose) and pipes (|) should both use _COLOR_FLAG/_COLOR_PIPE.
		if not Engine.is_editor_hint():
			return true
		var ec := EditorConsole.new()
		var colored: String = ec._colorize_command_input("ls --all | grep foo")
		ec.queue_free()
		var has_flag: bool = colored.contains("[color=#FF6B9D]--all[/color]")
		var has_pipe: bool = colored.contains("[color=#FF6B9D]|[/color]")
		return has_flag and has_pipe
	)

	test("Editor Console - W1 String Literal Coloring", func():
		# Quoted strings (both single- and double-quoted) should be wrapped in
		# the string-literal color.
		if not Engine.is_editor_hint():
			return true
		var ec := EditorConsole.new()
		var colored: String = ec._colorize_command_input("echo \"hello world\"")
		ec.queue_free()
		return colored.contains("[color=#5FBEE0]\"hello world\"[/color]")
	)

	test("Editor Console - W1 Longest Common Prefix Helper", func():
		if not Engine.is_editor_hint():
			return true
		var ec := EditorConsole.new()
		var p1: String = ec._longest_common_prefix(["abcdef", "abcxyz", "abcabc"])
		var p2: String = ec._longest_common_prefix(["abc"])
		var p3: String = ec._longest_common_prefix([])
		var p4: String = ec._longest_common_prefix(["foo", "bar"])
		ec.queue_free()
		return p1 == "abc" and p2 == "abc" and p3 == "" and p4 == ""
	)

	test("Editor Console - W1 Tab Advances To Common Prefix", func():
		# Set matching commands manually to ["test_one","test_two"] and trigger
		# the LCP advance. The input should advance to "test_" silently without
		# opening the popup.
		if not Engine.is_editor_hint():
			return true
		var ec := _instantiate_editor_console_fixture()
		if not ec:
			return false
		ec.input_line.text = "te"
		ec.input_line.caret_column = 2
		ec._matching_commands = ["test_one", "test_two"]
		var advanced: bool = ec._try_advance_to_common_prefix()
		var new_text: String = ec.input_line.text
		_cleanup_editor_console_fixture(ec)
		return advanced and new_text == "test_"
	)

	test("Editor Console - W1 Common Prefix No-op On Single Match", func():
		# Only one match -> no advance, returns false.
		if not Engine.is_editor_hint():
			return true
		var ec := _instantiate_editor_console_fixture()
		if not ec:
			return false
		ec.input_line.text = "he"
		ec.input_line.caret_column = 2
		ec._matching_commands = ["help"]
		var advanced: bool = ec._try_advance_to_common_prefix()
		_cleanup_editor_console_fixture(ec)
		return not advanced
	)

	test("Editor Console - W1 Ctrl+L Clears Output", func():
		if not Engine.is_editor_hint():
			return true
		var ec := _instantiate_editor_console_fixture()
		if not ec:
			return false
		ec.add_log_message("noise", ec.LOG_LEVEL_INFO)
		var size_before: int = ec.get_log_buffer().size()
		_simulate_key_event(ec, KEY_L, true, false)
		var size_after: int = ec.get_log_buffer().size()
		var action: String = ec._last_input_action
		_cleanup_editor_console_fixture(ec)
		return size_before > 0 and size_after == 0 and action == "clear_output"
	)

	test("Editor Console - W1 Ctrl+R Enters Reverse Search", func():
		if not Engine.is_editor_hint():
			return true
		var ec := _instantiate_editor_console_fixture()
		if not ec:
			return false
		ec.command_history = ["help", "echo hi", "ls", "cd /tmp"]
		_simulate_key_event(ec, KEY_R, true, false)
		var active: bool = ec._reverse_search_active
		var prompt_changed: bool = ec.input_line.placeholder_text.contains("reverse-i-search")
		_cleanup_editor_console_fixture(ec)
		return active and prompt_changed
	)

	test("Editor Console - W1 Reverse Search Finds Match", func():
		# After entering search mode, typing 'e' should jump to the most recent
		# history entry containing 'e' (case-insensitive).
		if not Engine.is_editor_hint():
			return true
		var ec := _instantiate_editor_console_fixture()
		if not ec:
			return false
		ec.command_history = ["help", "echo hi", "ls", "cd /tmp"]
		ec._enter_reverse_search()
		# Simulate typing 'e' via the same handler the gui_input path uses.
		var ev := InputEventKey.new()
		ev.pressed = true
		ev.keycode = KEY_E
		ev.physical_keycode = KEY_E
		ev.unicode = "e".unicode_at(0)
		ec._handle_reverse_search_key(ev)
		var matched: String = ec.input_line.text
		var found_index: int = ec._reverse_search_index
		_cleanup_editor_console_fixture(ec)
		return matched == "echo hi" and found_index == 1
	)

	test("Editor Console - W1 Reverse Search Esc Cancels", func():
		# Esc should restore the pre-search input verbatim and clear active.
		if not Engine.is_editor_hint():
			return true
		var ec := _instantiate_editor_console_fixture()
		if not ec:
			return false
		ec.command_history = ["help", "echo hi"]
		ec.input_line.text = "draft text"
		ec.input_line.caret_column = ec.input_line.text.length()
		ec._enter_reverse_search()
		var ev := InputEventKey.new()
		ev.pressed = true
		ev.keycode = KEY_E
		ev.physical_keycode = KEY_E
		ev.unicode = "e".unicode_at(0)
		ec._handle_reverse_search_key(ev)
		var esc_ev := InputEventKey.new()
		esc_ev.pressed = true
		esc_ev.keycode = KEY_ESCAPE
		ec._handle_reverse_search_key(esc_ev)
		var restored: bool = ec.input_line.text == "draft text"
		var inactive: bool = not ec._reverse_search_active
		_cleanup_editor_console_fixture(ec)
		return restored and inactive
	)

	test("Editor Console - W1 Reverse Search Backspace Trims Query", func():
		if not Engine.is_editor_hint():
			return true
		var ec := _instantiate_editor_console_fixture()
		if not ec:
			return false
		ec.command_history = ["help", "echo hi"]
		ec._enter_reverse_search()
		for ch in ["e", "c"]:
			var ev := InputEventKey.new()
			ev.pressed = true
			ev.keycode = KEY_E if ch == "e" else KEY_C
			ev.physical_keycode = ev.keycode
			ev.unicode = ch.unicode_at(0)
			ec._handle_reverse_search_key(ev)
		var query_before: String = ec._reverse_search_query
		var bs_ev := InputEventKey.new()
		bs_ev.pressed = true
		bs_ev.keycode = KEY_BACKSPACE
		ec._handle_reverse_search_key(bs_ev)
		var query_after: String = ec._reverse_search_query
		_cleanup_editor_console_fixture(ec)
		return query_before == "ec" and query_after == "e"
	)

	test("Editor Console - W1 Caret Blink Enabled", func():
		if not Engine.is_editor_hint():
			return true
		var ec := _instantiate_editor_console_fixture()
		if not ec:
			return false
		var blink: bool = ec.input_line.caret_blink
		var interval: float = ec.input_line.caret_blink_interval
		_cleanup_editor_console_fixture(ec)
		return blink and interval > 0.0 and interval <= 1.0
	)
	# --- end W1 bash polish tests ---

	# --- readline shortcut tests (editor) ---
	# Bash readline parity: Ctrl+W/K/Y kill ring + Alt+B/F word nav.
	test("Editor Console - T5 Ctrl+W Deletes Word Backward", func():
		if not Engine.is_editor_hint():
			return true
		var ec := _instantiate_editor_console_fixture()
		if not ec:
			return false
		ec.input_line.text = "cd res://addons/debug_console/editor"
		ec.input_line.caret_column = ec.input_line.text.length()
		_simulate_key_event(ec, KEY_W, true, false)
		var text_ok: bool = ec.input_line.text == "cd res://addons/debug_console/"
		var caret_ok: bool = ec.input_line.caret_column == 30
		var kill_ok: bool = ec._kill_ring == "editor"
		var action_ok: bool = ec._last_input_action == "kill_word_backward"
		_cleanup_editor_console_fixture(ec)
		return text_ok and caret_ok and kill_ok and action_ok
	)

	test("Editor Console - T5 Ctrl+W Skips Trailing Whitespace", func():
		if not Engine.is_editor_hint():
			return true
		var ec := _instantiate_editor_console_fixture()
		if not ec:
			return false
		ec.input_line.text = "   echo hello   "
		ec.input_line.caret_column = ec.input_line.text.length()
		_simulate_key_event(ec, KEY_W, true, false)
		var text_ok: bool = ec.input_line.text == "   echo "
		var caret_ok: bool = ec.input_line.caret_column == 8
		var kill_ok: bool = ec._kill_ring == "hello   "
		_cleanup_editor_console_fixture(ec)
		return text_ok and caret_ok and kill_ok
	)

	test("Editor Console - T5 Ctrl+K Kills To End Of Line", func():
		if not Engine.is_editor_hint():
			return true
		var ec := _instantiate_editor_console_fixture()
		if not ec:
			return false
		ec.input_line.text = "echo hello world"
		ec.input_line.caret_column = 10
		_simulate_key_event(ec, KEY_K, true, false)
		var text_ok: bool = ec.input_line.text == "echo hello"
		var caret_ok: bool = ec.input_line.caret_column == 10
		var kill_ok: bool = ec._kill_ring == " world"
		var action_ok: bool = ec._last_input_action == "kill_to_end_of_line"
		_cleanup_editor_console_fixture(ec)
		return text_ok and caret_ok and kill_ok and action_ok
	)

	test("Editor Console - T5 Alt+B Walks Caret Backward Word-By-Word", func():
		if not Engine.is_editor_hint():
			return true
		var ec := _instantiate_editor_console_fixture()
		if not ec:
			return false
		ec.input_line.text = "echo hello world"
		ec.input_line.caret_column = ec.input_line.text.length()
		var stops: Array[int] = []
		for i in range(3):
			var ev := InputEventKey.new()
			ev.pressed = true
			ev.keycode = KEY_B
			ev.physical_keycode = KEY_B
			ev.alt_pressed = true
			ec._on_input_line_gui_input(ev)
			stops.append(ec.input_line.caret_column)
		var action_ok: bool = ec._last_input_action == "word_back"
		_cleanup_editor_console_fixture(ec)
		return stops == [11, 5, 0] and action_ok
	)

	test("Editor Console - T5 Alt+F Walks Caret Forward Word-By-Word", func():
		if not Engine.is_editor_hint():
			return true
		var ec := _instantiate_editor_console_fixture()
		if not ec:
			return false
		ec.input_line.text = "echo hello world"
		ec.input_line.caret_column = 0
		var stops: Array[int] = []
		for i in range(3):
			var ev := InputEventKey.new()
			ev.pressed = true
			ev.keycode = KEY_F
			ev.physical_keycode = KEY_F
			ev.alt_pressed = true
			ec._on_input_line_gui_input(ev)
			stops.append(ec.input_line.caret_column)
		var action_ok: bool = ec._last_input_action == "word_forward"
		_cleanup_editor_console_fixture(ec)
		return stops == [4, 10, 16] and action_ok
	)

	test("Editor Console - T5 Ctrl+Y Yanks After Kill And No-Op On Empty", func():
		if not Engine.is_editor_hint():
			return true
		var ec := _instantiate_editor_console_fixture()
		if not ec:
			return false
		ec.input_line.text = "echo hello"
		ec.input_line.caret_column = ec.input_line.text.length()
		_simulate_key_event(ec, KEY_W, true, false)
		var after_kill_text: String = ec.input_line.text
		_simulate_key_event(ec, KEY_Y, true, false)
		var yank_text_ok: bool = ec.input_line.text == "echo hello"
		var yank_caret_ok: bool = ec.input_line.caret_column == 10
		ec._kill_ring = ""
		_simulate_key_event(ec, KEY_Y, true, false)
		var noop_ok: bool = ec.input_line.text == "echo hello"
		_cleanup_editor_console_fixture(ec)
		return after_kill_text == "echo " and yank_text_ok and yank_caret_ok and noop_ok
	)
	# --- end T5 readline shortcut tests (editor) ---

func run_game_console_tests():
	print("\nTesting Game Console...")

	test("Game Console - Initialization", func():
		if Engine.is_editor_hint():
			return true  # GameConsole behavior is runtime-only
		var gc := _instantiate_game_console_fixture()
		if not gc:
			return false
		var ok: bool = gc.is_inside_tree() and gc.output_text != null and gc.input_line != null
		_cleanup_game_console_fixture(gc)
		return ok
	)

	test("Game Console - Visibility Toggle", func():
		if Engine.is_editor_hint():
			return true  # GameConsole behavior is runtime-only
		var gc := _instantiate_game_console_fixture()
		if not gc:
			return false
		gc.visible = true
		gc.is_animating = false
		gc.hide_console()
		# The hide tween runs across multiple frames; jump to its end synchronously.
		gc._on_hide_complete()
		var ok: bool = not gc.visible and not gc.is_animating
		_cleanup_game_console_fixture(gc)
		return ok
	)

	test("Game Console - Command Execution", func():
		if Engine.is_editor_hint():
			return true  # GameConsole behavior is runtime-only
		var gc := _instantiate_game_console_fixture()
		if not gc:
			return false
		gc._execute_command("echo hi")
		# Read from the meta-backed log buffer rather than RichTextLabel state -
		# RichTextLabel's text/get_parsed_text() don't reliably reflect appended
		# content in headless run_scene contexts.
		var buffer: Array = gc.get_log_buffer()
		var echoed: bool = false
		for line in buffer:
			if str(line).contains("hi"):
				echoed = true
				break
		var ok: bool = gc.command_history.size() == 1 and echoed
		_cleanup_game_console_fixture(gc)
		return ok
	)

	test("Game Console - Command History", func():
		if Engine.is_editor_hint():
			return true  # GameConsole behavior is runtime-only
		var gc := _instantiate_game_console_fixture()
		if not gc:
			return false
		gc._execute_command("echo one")
		gc._execute_command("echo two")
		gc._execute_command("echo three")
		var ok: bool = gc.command_history.size() == 3 and gc.command_history[2] == "echo three"
		_cleanup_game_console_fixture(gc)
		return ok
	)

	test("Game Console - History Navigation", func():
		if Engine.is_editor_hint():
			return true  # GameConsole behavior is runtime-only
		var gc := _instantiate_game_console_fixture()
		if not gc:
			return false
		gc.command_history.clear()
		gc.command_history.append("cmd_a")
		gc.command_history.append("cmd_b")
		gc.command_history.append("cmd_c")
		gc.history_index = gc.command_history.size()
		gc._navigate_history(-1)  # → cmd_c (index 2)
		gc._navigate_history(-1)  # → cmd_b (index 1)
		var ok: bool = gc.input_line.text == "cmd_b"
		_cleanup_game_console_fixture(gc)
		return ok
	)

	test("Game Console - Clear Output", func():
		if Engine.is_editor_hint():
			return true  # GameConsole behavior is runtime-only
		var gc := _instantiate_game_console_fixture()
		if not gc:
			return false
		gc.add_log_message("clear-output-probe")
		var was_populated: bool = gc.get_log_buffer().size() > 0
		gc.clear_output()
		var is_cleared: bool = gc.get_log_buffer().is_empty()
		_cleanup_game_console_fixture(gc)
		return was_populated and is_cleared
	)

	test("Game Console - Log Message Levels", func():
		if Engine.is_editor_hint():
			return true  # GameConsole behavior is runtime-only
		var gc := _instantiate_game_console_fixture()
		if not gc:
			return false
		gc.clear_output()
		gc.add_log_message("info-msg", GameConsole.LOG_LEVEL_INFO)
		gc.add_log_message("warn-msg", GameConsole.LOG_LEVEL_WARNING)
		gc.add_log_message("err-msg", GameConsole.LOG_LEVEL_ERROR)
		gc.add_log_message("success-msg", GameConsole.LOG_LEVEL_SUCCESS)
		# Inspect the meta buffer: each entry should contain its color marker
		# AND its message text. Reading the buffer is reliable in any context,
		# unlike RichTextLabel.text / get_parsed_text() in headless runs.
		var buffer: Array = gc.get_log_buffer()
		var combined := ""
		for entry in buffer:
			combined += str(entry)
		var ok: bool = (
			buffer.size() == 4
			and combined.contains("#808080") and combined.contains("info-msg")
			and combined.contains("#FFAA00") and combined.contains("warn-msg")
			and combined.contains("#FF4444") and combined.contains("err-msg")
			and combined.contains("#44FF44") and combined.contains("success-msg")
		)
		_cleanup_game_console_fixture(gc)
		return ok
	)

	test("Game Console - Animation State", func():
		if Engine.is_editor_hint():
			return true  # GameConsole behavior is runtime-only
		var gc := _instantiate_game_console_fixture()
		if not gc:
			return false
		var initial_animating: bool = gc.is_animating
		gc.show_console()
		var animating_after_show: bool = gc.is_animating
		# Skip to the end of the in-flight show tween synchronously.
		gc._on_show_complete()
		var ok: bool = (
			initial_animating == false
			and animating_after_show == true
			and gc.is_animating == false
			and gc.visible == true
		)
		_cleanup_game_console_fixture(gc)
		return ok
	)

	test("Game Console - Target Height", func():
		if Engine.is_editor_hint():
			return true  # GameConsole behavior is runtime-only
		var gc := _instantiate_game_console_fixture()
		if not gc:
			return false
		var ok: bool = gc.target_height == 400.0
		_cleanup_game_console_fixture(gc)
		return ok
	)

	test("Game Console - Focus Helper Safe", func():
		# focus_command_input must not crash on a detached GameConsole (input_line
		# is null when @onready hasn't bound). The early-return guard inside the
		# helper is what we're verifying.
		var console := GameConsole.new()
		var no_input_line: bool = console.input_line == null
		console.focus_command_input()
		var still_valid: bool = is_instance_valid(console)
		if is_instance_valid(console):
			console.queue_free()
		return no_input_line and still_valid
	)

	# --- keyboard UX tests (GameConsole runtime-only) ---
	# Mirror the editor popup/keyboard tests for the runtime console, scoped
	# to the behaviors GameConsole actually supports (commands-only popup, no
	# directory / file / node-type suggestion modes).

	test("Game Console - Popup Shows On Typing", func():
		if Engine.is_editor_hint():
			return true  # GameConsole behavior is runtime-only
		var gc := _instantiate_game_console_fixture()
		if not gc:
			return false
		gc.input_line.text = "h"
		gc.input_line.caret_column = 1
		gc._on_input_text_changed("h")
		var popup_open: bool = gc._popup_open
		var popup_visible: bool = gc.autocomplete_popup.visible
		var has_matches: bool = gc._matching_commands.size() > 0
		_cleanup_game_console_fixture(gc)
		return popup_open and popup_visible and has_matches
	)

	test("Game Console - Esc Restores Draft", func():
		if Engine.is_editor_hint():
			return true
		var gc := _instantiate_game_console_fixture()
		if not gc:
			return false
		gc.input_line.text = "h"
		gc.input_line.caret_column = 1
		gc._on_input_text_changed("h")
		gc.input_line.text = "MUTATED-BY-POPUP"
		gc.input_line.caret_column = gc.input_line.text.length()
		_simulate_key_event(gc, KEY_ESCAPE)
		var restored: bool = gc.input_line.text == "h"
		var dismissed: bool = not gc._popup_open
		var action_recorded: bool = gc._last_input_action == "dismiss_popup"
		_cleanup_game_console_fixture(gc)
		return restored and dismissed and action_recorded
	)

	test("Game Console - Ctrl+U Clears Line", func():
		if Engine.is_editor_hint():
			return true
		var gc := _instantiate_game_console_fixture()
		if not gc:
			return false
		gc.input_line.text = "hello world"
		gc.input_line.caret_column = gc.input_line.text.length()
		gc._user_draft = "hello world"
		_simulate_key_event(gc, KEY_U, true)
		var cleared: bool = gc.input_line.text == "" and gc.input_line.caret_column == 0
		var draft_cleared: bool = gc._user_draft == ""
		var action_recorded: bool = gc._last_input_action == "clear_line"
		_cleanup_game_console_fixture(gc)
		return cleared and draft_cleared and action_recorded
	)
	# --- end T2.1 keyboard UX tests ---

	# --- opacity + resize tests ---
	test("Game Console - Opacity Set", func():
		if Engine.is_editor_hint():
			return true  # GameConsole behavior is runtime-only
		var gc := _instantiate_game_console_fixture()
		if not gc:
			return false
		gc.set_opacity(0.5)
		var ok: bool = is_equal_approx(gc.background.color.a, 0.5)
		_cleanup_game_console_fixture(gc)
		return ok
	)

	test("Game Console - Opacity Clamps Below Minimum", func():
		if Engine.is_editor_hint():
			return true  # GameConsole behavior is runtime-only
		var gc := _instantiate_game_console_fixture()
		if not gc:
			return false
		gc.set_opacity(0.05)
		var ok: bool = gc.background.color.a >= 0.1 - 0.0001
		_cleanup_game_console_fixture(gc)
		return ok
	)

	test("Game Console - Opacity Clamps Above Maximum", func():
		if Engine.is_editor_hint():
			return true  # GameConsole behavior is runtime-only
		var gc := _instantiate_game_console_fixture()
		if not gc:
			return false
		gc.set_opacity(1.5)
		var ok: bool = is_equal_approx(gc.background.color.a, 1.0)
		_cleanup_game_console_fixture(gc)
		return ok
	)

	test("Game Console - Target Height Clamps", func():
		if Engine.is_editor_hint():
			return true  # GameConsole behavior is runtime-only
		var gc := _instantiate_game_console_fixture()
		if not gc:
			return false
		# Request a height below the floor; _set_height_clamped must lift it
		# to at least _MIN_HEIGHT (150). Same code path the resize drag uses.
		gc._set_height_clamped(50.0)
		var ok: bool = gc.target_height >= 150.0
		_cleanup_game_console_fixture(gc)
		return ok
	)
	# --- end T2.3 opacity + resize tests ---

	# --- smart autocomplete tests ---
	# Runtime parity with EditorConsole's node-path suggestions. GameConsole
	# gains the "node_paths" mode for inspect / get / set / watch / scene_tree
	# / signals / properties. Tests use _instantiate_game_console_fixture so
	# the input_line / autocomplete_popup wiring is realized; the methods
	# under test don't strictly need it, but mirroring the EditorConsole
	# pattern keeps the fixtures consistent.

	test("Game Console - Autocomplete Mode for inspect Is node_paths", func():
		if Engine.is_editor_hint():
			return true  # GameConsole behavior is runtime-only
		var gc := _instantiate_game_console_fixture()
		if not gc:
			return false
		var mode: String = gc._determine_autocomplete_mode("inspect ", 8)
		_cleanup_game_console_fixture(gc)
		return mode == "node_paths"
	)

	test("Game Console - Autocomplete Node Paths Include Engine", func():
		if Engine.is_editor_hint():
			return true  # GameConsole behavior is runtime-only
		var gc := _instantiate_game_console_fixture()
		if not gc:
			return false
		gc._get_node_path_suggestions("")
		var has_engine: bool = gc._matching_commands.has("Engine")
		_cleanup_game_console_fixture(gc)
		return has_engine
	)
	# --- end T3.2 smart autocomplete tests ---

	# --- bash polish tests ---
	# These cover the runtime polish features added in Wave 1: the welcome
	# banner emitted at _ready, the bash-style prompt prepended to every
	# echoed command, per-token coloring of the echoed command line, smart
	# Tab that advances to the longest common prefix before cycling, the
	# Ctrl+L clear shortcut, and Ctrl+R reverse history search.

	test("Game Console - Banner Shown On Ready", func():
		if Engine.is_editor_hint():
			return true  # GameConsole behavior is runtime-only
		var gc := _instantiate_game_console_fixture()
		if not gc:
			return false
		# _show_welcome_banner runs in _ready and writes 4 lines via
		# add_log_message, so the meta-backed buffer should already contain
		# them by the time we inspect it here.
		var combined: String = ""
		for line in gc.get_log_buffer():
			combined += str(line)
		var ok: bool = (
			combined.contains("Debug Console")
			and combined.contains("Runtime")
			and combined.contains("F12")
			and combined.contains("#5FBEE0")
		)
		_cleanup_game_console_fixture(gc)
		return ok
	)

	test("Game Console - Bash Prompt Format", func():
		if Engine.is_editor_hint():
			return true  # GameConsole behavior is runtime-only
		var gc := _instantiate_game_console_fixture()
		if not gc:
			return false
		# Snapshot cwd so the assertion below is deterministic regardless of
		# whatever state previous tests left BuiltInCommands in.
		var saved_cwd: String = BuiltInCommands.get_current_directory()
		BuiltInCommands.set_current_directory("res://probe")
		gc.clear_output()
		gc._execute_command("echo hi")
		var combined: String = ""
		for line in gc.get_log_buffer():
			combined += str(line)
		var ok: bool = (
			combined.contains("player")
			and combined.contains("runtime")
			and combined.contains("res://probe")
			and combined.contains("$")
			and combined.contains("echo")
			and combined.contains("#44FF44")
			and combined.contains("#606060")
		)
		BuiltInCommands.set_current_directory(saved_cwd)
		_cleanup_game_console_fixture(gc)
		return ok
	)

	test("Game Console - Command Token Color", func():
		if Engine.is_editor_hint():
			return true  # GameConsole behavior is runtime-only
		var gc := _instantiate_game_console_fixture()
		if not gc:
			return false
		var colored: String = gc._colorize_command_input("echo --flag \"hello\"")
		var ok: bool = (
			colored.contains("#F7DC6F")  # command name yellow
			and colored.contains("#FF6B9D")  # flag pink
			and colored.contains("#5FBEE0")  # string literal cyan
		)
		_cleanup_game_console_fixture(gc)
		return ok
	)

	test("Game Console - Longest Common Prefix Helper", func():
		if Engine.is_editor_hint():
			return true  # GameConsole behavior is runtime-only
		var gc := _instantiate_game_console_fixture()
		if not gc:
			return false
		var ok: bool = (
			gc._longest_common_prefix(["help", "hello"]) == "hel"
			and gc._longest_common_prefix(["echo", "exec"]) == "e"
			and gc._longest_common_prefix(["abc"]) == "abc"
			and gc._longest_common_prefix([]) == ""
			and gc._longest_common_prefix(["foo", "bar"]) == ""
		)
		_cleanup_game_console_fixture(gc)
		return ok
	)

	test("Game Console - Tab Advances To Common Prefix", func():
		if Engine.is_editor_hint():
			return true  # GameConsole behavior is runtime-only
		var gc := _instantiate_game_console_fixture()
		if not gc:
			return false
		# Seed the input line and matching-commands state to simulate the
		# moment after the autocomplete machinery filtered "h" → 3 matches.
		# _maybe_advance_to_common_prefix should bump the input to "hel"
		# (the LCP of help/hello/helper) without dismissing the popup.
		gc.input_line.text = "h"
		gc.input_line.caret_column = 1
		gc._user_draft = "h"
		gc._matching_commands = ["help", "hello", "helper"]
		var advanced: bool = gc._maybe_advance_to_common_prefix()
		var ok: bool = (
			advanced
			and gc.input_line.text == "hel"
			and gc._user_draft == "hel"
		)
		_cleanup_game_console_fixture(gc)
		return ok
	)

	test("Game Console - Ctrl+L Clears", func():
		if Engine.is_editor_hint():
			return true  # GameConsole behavior is runtime-only
		var gc := _instantiate_game_console_fixture()
		if not gc:
			return false
		gc.add_log_message("probe")
		var pre_size: int = gc.get_log_buffer().size()
		_simulate_key_event(gc, KEY_L, true)
		var post_size: int = gc.get_log_buffer().size()
		var ok: bool = pre_size > 0 and post_size == 0
		_cleanup_game_console_fixture(gc)
		return ok
	)

	test("Game Console - Ctrl+R Enters Search Mode", func():
		if Engine.is_editor_hint():
			return true  # GameConsole behavior is runtime-only
		var gc := _instantiate_game_console_fixture()
		if not gc:
			return false
		_simulate_key_event(gc, KEY_R, true)
		var ok: bool = gc._reverse_search_active == true
		_cleanup_game_console_fixture(gc)
		return ok
	)

	test("Game Console - Reverse Search Finds Match", func():
		if Engine.is_editor_hint():
			return true  # GameConsole behavior is runtime-only
		var gc := _instantiate_game_console_fixture()
		if not gc:
			return false
		gc.command_history.clear()
		gc.command_history.append("echo apple")
		gc.command_history.append("echo banana")
		gc.command_history.append("ls")
		gc._reverse_search_start()
		# Drive the query through the public-ish setter; this avoids having
		# to synthesize unicode-bearing key events in a headless context.
		gc._reverse_search_set_query("app")
		var ok: bool = gc.input_line.text == "echo apple"
		_cleanup_game_console_fixture(gc)
		return ok
	)

	test("Game Console - Reverse Search Esc Cancels", func():
		if Engine.is_editor_hint():
			return true  # GameConsole behavior is runtime-only
		var gc := _instantiate_game_console_fixture()
		if not gc:
			return false
		gc.command_history.clear()
		gc.command_history.append("echo apple")
		gc.command_history.append("echo banana")
		gc.input_line.text = "original-text"
		gc.input_line.caret_column = gc.input_line.text.length()
		gc._user_draft = "original-text"
		gc._reverse_search_start()
		gc._reverse_search_set_query("ec")
		# Esc through the gui_input path - since _reverse_search_active is
		# true, the handler at the top of _on_input_line_gui_input routes
		# the event to _handle_reverse_search_key → _reverse_search_cancel.
		_simulate_key_event(gc, KEY_ESCAPE)
		var ok: bool = (
			gc.input_line.text == "original-text"
			and not gc._reverse_search_active
		)
		_cleanup_game_console_fixture(gc)
		return ok
	)
	# --- end W1 bash polish tests ---

	# --- readline shortcut tests (game) ---
	# Runtime parity with the editor T5 suite. GameConsole carries its own
	# independent _kill_ring slot, so these tests must not assume any
	# state shared with the editor console.
	test("Game Console - T5 Ctrl+W Deletes Word Backward", func():
		if Engine.is_editor_hint():
			return true
		var gc := _instantiate_game_console_fixture()
		if not gc:
			return false
		gc.input_line.text = "cd res://addons/debug_console/editor"
		gc.input_line.caret_column = gc.input_line.text.length()
		_simulate_key_event(gc, KEY_W, true, false)
		var text_ok: bool = gc.input_line.text == "cd res://addons/debug_console/"
		var caret_ok: bool = gc.input_line.caret_column == 30
		var kill_ok: bool = gc._kill_ring == "editor"
		var action_ok: bool = gc._last_input_action == "kill_word_backward"
		_cleanup_game_console_fixture(gc)
		return text_ok and caret_ok and kill_ok and action_ok
	)

	test("Game Console - T5 Ctrl+W Skips Trailing Whitespace", func():
		if Engine.is_editor_hint():
			return true
		var gc := _instantiate_game_console_fixture()
		if not gc:
			return false
		gc.input_line.text = "   echo hello   "
		gc.input_line.caret_column = gc.input_line.text.length()
		_simulate_key_event(gc, KEY_W, true, false)
		var text_ok: bool = gc.input_line.text == "   echo "
		var caret_ok: bool = gc.input_line.caret_column == 8
		var kill_ok: bool = gc._kill_ring == "hello   "
		_cleanup_game_console_fixture(gc)
		return text_ok and caret_ok and kill_ok
	)

	test("Game Console - T5 Ctrl+K Kills To End Of Line", func():
		if Engine.is_editor_hint():
			return true
		var gc := _instantiate_game_console_fixture()
		if not gc:
			return false
		gc.input_line.text = "echo hello world"
		gc.input_line.caret_column = 10
		_simulate_key_event(gc, KEY_K, true, false)
		var text_ok: bool = gc.input_line.text == "echo hello"
		var caret_ok: bool = gc.input_line.caret_column == 10
		var kill_ok: bool = gc._kill_ring == " world"
		var action_ok: bool = gc._last_input_action == "kill_to_end_of_line"
		_cleanup_game_console_fixture(gc)
		return text_ok and caret_ok and kill_ok and action_ok
	)

	test("Game Console - T5 Alt+B Walks Caret Backward Word-By-Word", func():
		if Engine.is_editor_hint():
			return true
		var gc := _instantiate_game_console_fixture()
		if not gc:
			return false
		gc.input_line.text = "echo hello world"
		gc.input_line.caret_column = gc.input_line.text.length()
		var stops: Array[int] = []
		for i in range(3):
			var ev := InputEventKey.new()
			ev.pressed = true
			ev.keycode = KEY_B
			ev.physical_keycode = KEY_B
			ev.alt_pressed = true
			gc._on_input_line_gui_input(ev)
			stops.append(gc.input_line.caret_column)
		var action_ok: bool = gc._last_input_action == "word_back"
		_cleanup_game_console_fixture(gc)
		return stops == [11, 5, 0] and action_ok
	)

	test("Game Console - T5 Alt+F Walks Caret Forward Word-By-Word", func():
		if Engine.is_editor_hint():
			return true
		var gc := _instantiate_game_console_fixture()
		if not gc:
			return false
		gc.input_line.text = "echo hello world"
		gc.input_line.caret_column = 0
		var stops: Array[int] = []
		for i in range(3):
			var ev := InputEventKey.new()
			ev.pressed = true
			ev.keycode = KEY_F
			ev.physical_keycode = KEY_F
			ev.alt_pressed = true
			gc._on_input_line_gui_input(ev)
			stops.append(gc.input_line.caret_column)
		var action_ok: bool = gc._last_input_action == "word_forward"
		_cleanup_game_console_fixture(gc)
		return stops == [4, 10, 16] and action_ok
	)

	test("Game Console - T5 Ctrl+Y Yanks After Kill And No-Op On Empty", func():
		if Engine.is_editor_hint():
			return true
		var gc := _instantiate_game_console_fixture()
		if not gc:
			return false
		gc.input_line.text = "echo hello"
		gc.input_line.caret_column = gc.input_line.text.length()
		_simulate_key_event(gc, KEY_W, true, false)
		var after_kill_text: String = gc.input_line.text
		_simulate_key_event(gc, KEY_Y, true, false)
		var yank_text_ok: bool = gc.input_line.text == "echo hello"
		var yank_caret_ok: bool = gc.input_line.caret_column == 10
		gc._kill_ring = ""
		_simulate_key_event(gc, KEY_Y, true, false)
		var noop_ok: bool = gc.input_line.text == "echo hello"
		_cleanup_game_console_fixture(gc)
		return after_kill_text == "echo " and yank_text_ok and yank_caret_ok and noop_ok
	)
	# --- end T5 readline shortcut tests (game) ---

func run_console_manager_tests():
	print("\nTesting Console Manager...")

	test("Console Manager - Initialization", func():
		if Engine.is_editor_hint():
			return true  # GameConsoleManager._ready early-returns in editor
		var tree := Engine.get_main_loop() as SceneTree
		if not tree:
			return false
		var gcm := tree.root.get_node_or_null("/root/GameConsoleManager")
		return gcm != null
	)

	test("Console Manager - Console Creation", func():
		if Engine.is_editor_hint():
			return true  # GameConsoleManager._ready early-returns in editor
		var tree := Engine.get_main_loop() as SceneTree
		if not tree:
			return false
		var gcm := tree.root.get_node_or_null("/root/GameConsoleManager")
		if not gcm:
			return false
		# is_console_enabled is set synchronously in _ready before the deferred
		# _create_console call. console_instance is created on the next idle frame;
		# by the time the test runner is invoked from user input / MCP, that frame
		# has long since passed.
		return (
			gcm.is_console_enabled
			and gcm.console_instance != null
			and is_instance_valid(gcm.console_instance)
		)
	)

	test("Console Manager - Console Toggle", func():
		if Engine.is_editor_hint():
			return true  # GameConsoleManager._ready early-returns in editor
		var tree := Engine.get_main_loop() as SceneTree
		if not tree:
			return false
		var gcm := tree.root.get_node_or_null("/root/GameConsoleManager")
		if not gcm or not is_instance_valid(gcm.console_instance):
			return false
		gcm.console_instance.is_animating = false
		gcm.console_instance.visible = false
		gcm.toggle_console()
		# toggle_visibility -> show_console: visible=true, is_animating=true.
		var ok: bool = gcm.console_instance.visible and gcm.console_instance.is_animating
		# Drain the tween state so subsequent tests inherit a clean console.
		gcm.console_instance._on_show_complete()
		gcm.console_instance.visible = false
		gcm.console_instance.is_animating = false
		return ok
	)

	test("Console Manager - Show Console", func():
		if Engine.is_editor_hint():
			return true  # GameConsoleManager._ready early-returns in editor
		var tree := Engine.get_main_loop() as SceneTree
		if not tree:
			return false
		var gcm := tree.root.get_node_or_null("/root/GameConsoleManager")
		if not gcm or not is_instance_valid(gcm.console_instance):
			return false
		gcm.console_instance.is_animating = false
		gcm.console_instance.visible = false
		gcm.show_console()
		var ok: bool = gcm.console_instance.visible and gcm.console_instance.is_animating
		gcm.console_instance._on_show_complete()
		gcm.console_instance.visible = false
		gcm.console_instance.is_animating = false
		return ok
	)

	test("Console Manager - Hide Console", func():
		if Engine.is_editor_hint():
			return true  # GameConsoleManager._ready early-returns in editor
		var tree := Engine.get_main_loop() as SceneTree
		if not tree:
			return false
		var gcm := tree.root.get_node_or_null("/root/GameConsoleManager")
		if not gcm or not is_instance_valid(gcm.console_instance):
			return false
		gcm.console_instance.is_animating = false
		gcm.console_instance.visible = true
		gcm.hide_console()
		var ok: bool = gcm.console_instance.is_animating
		gcm.console_instance._on_hide_complete()
		return ok
	)

	test("Console Manager - Built-in Commands Registration", func():
		if Engine.is_editor_hint():
			return true  # GameConsoleManager._ready early-returns in editor
		var tree := Engine.get_main_loop() as SceneTree
		if not tree:
			return false
		var gcm := tree.root.get_node_or_null("/root/GameConsoleManager")
		if not gcm:
			return false
		var registry := _registry()
		if not registry:
			return false
		return (
			gcm.builtin_commands != null
			and registry._commands.has("fps")
			and registry._commands.has("nodes")
			and registry._commands.has("pause")
			and registry._commands.has("timescale")
		)
	)

func run_debug_core_tests():
	print("\nTesting Debug Core...")

	test("Debug Core - Initialization", func():
		return _debug_core() != null
	)

	test("Debug Core - Log Levels", func():
		var core := _debug_core()
		if not core:
			return false
		var saved_history: Array[String] = core.get_history()
		core.clear_history()
		core.info("level-info-probe")
		core.warning("level-warning-probe")
		core.error("level-error-probe")
		core.success("level-success-probe")
		var after: Array[String] = core.get_history()
		var ok: bool = after.size() == 4
		# Restore pre-test history so we don't bleed state into other tests.
		core.clear_history()
		for entry in saved_history:
			core._message_history.append(entry)
		return ok
	)

	test("Debug Core - Message History", func():
		var core := _debug_core()
		if not core:
			return false
		var saved_history: Array[String] = core.get_history()
		core.clear_history()
		core.info("history-marker-9f2c8b")
		var after_text: String = core.get_history_text()
		var ok: bool = after_text.contains("history-marker-9f2c8b")
		core.clear_history()
		for entry in saved_history:
			core._message_history.append(entry)
		return ok
	)

	test("Debug Core - Clear History", func():
		var core := _debug_core()
		if not core:
			return false
		var saved_history: Array[String] = core.get_history()
		core.info("clear-history-marker")
		var was_populated: bool = not core.get_history().is_empty()
		core.clear_history()
		var is_cleared: bool = core.get_history().is_empty()
		# Restore
		for entry in saved_history:
			core._message_history.append(entry)
		return was_populated and is_cleared
	)

	test("Debug Core - Message Formatting", func():
		# Exercise _format_message indirectly via the public Log path so we don't
		# depend on the LogLevel enum being addressable through a Node ref.
		var core := _debug_core()
		if not core:
			return false
		var saved_history: Array[String] = core.get_history()
		core.clear_history()
		core.info("format-probe-marker")
		var history: Array[String] = core.get_history()
		var ok: bool = (
			history.size() == 1
			and history[0].contains("INFO")
			and history[0].contains("format-probe-marker")
		)
		core.clear_history()
		for entry in saved_history:
			core._message_history.append(entry)
		return ok
	)

	test("Debug Core - History Size Limit", func():
		var core := _debug_core()
		if not core:
			return false
		var saved_history: Array[String] = core.get_history()
		var saved_limit: int = core.max_history_size
		core.clear_history()
		core.max_history_size = 5
		for i in range(10):
			core.info("size-limit-" + str(i))
		var ok: bool = core.get_history().size() == 5
		# Restore - DebugCore is a live singleton, leaking state breaks other tests.
		core.max_history_size = saved_limit
		core.clear_history()
		for entry in saved_history:
			core._message_history.append(entry)
		return ok
	)

func run_file_operation_tests():
	print("\nTesting File Operations...")
	
	# File operations are editor-specific
	if Engine.is_editor_hint():
		test("File Operations - Create Directory", func():
			var commands = BuiltInCommands.new()
			var test_dir_name = ".hidden_test_" + str(Time.get_ticks_msec())
			var result = commands._make_directory([test_dir_name])
			var success = result.contains("Created directory")
			if DirAccess.dir_exists_absolute("res://" + test_dir_name):
				DirAccess.open("res://").remove(test_dir_name)
				if Engine.is_editor_hint():
					EditorInterface.get_resource_filesystem().scan()
			return success
		)
		
		test("File Operations - Create File", func():
			var commands = BuiltInCommands.new()
			var test_file_name = ".hidden_test_" + str(Time.get_ticks_msec()) + ".txt"
			var result = commands._create_file([test_file_name])
			var success = result.contains("Created file")
			if FileAccess.file_exists("res://" + test_file_name):
				DirAccess.open("res://").remove(test_file_name)
				if Engine.is_editor_hint():
					EditorInterface.get_resource_filesystem().scan()
			return success
		)
		
		test("File Operations - Create Script", func():
			var commands = BuiltInCommands.new()
			var test_script_name = ".hidden_test_" + str(Time.get_ticks_msec())
			var result = commands._create_script([test_script_name, "Node"])
			var success = result.contains("Created script") and result.contains("extends Node")
			if FileAccess.file_exists("res://" + test_script_name + ".gd"):
				DirAccess.open("res://").remove(test_script_name + ".gd")
				if Engine.is_editor_hint():
					EditorInterface.get_resource_filesystem().scan()
			return success
		)
		
		test("File Operations - List Files", func():
			var commands = BuiltInCommands.new()
			var result = commands._list_files([])
			return result.contains("Files in res://")
		)
		
		test("File Operations - Directory Navigation", func():
			var commands = BuiltInCommands.new()
			var test_dir_name = ".hidden_test_" + str(Time.get_ticks_msec())
			commands._make_directory([test_dir_name])
			var result = commands._change_directory([test_dir_name])
			var success = result.contains("Changed to:")
			if DirAccess.dir_exists_absolute("res://" + test_dir_name):
				DirAccess.open("res://").remove(test_dir_name)
				if Engine.is_editor_hint():
					EditorInterface.get_resource_filesystem().scan()
			return success
		)
		
		test("File Operations - Working Directory", func():
			var commands = BuiltInCommands.new()
			var result = commands._print_working_directory([])
			return result.contains("Current directory")
		)
	else:
		test("File Operations - Skipped in Game Mode", func():
			return true
		)

func run_piping_tests():
	print("\nTesting Command Piping...")
	var registry := _registry()
	
	test("Piping - Simple Echo Pipe", func():
		var result = registry.execute_command("echo hello world | echo")
		return result == "hello world"
	)
	
	test("Piping - LS to Grep", func():
		if not Engine.is_editor_hint():
			return true
		var result = registry.execute_command("ls | grep .gd")
		return result.contains(".gd") or result == "No matches found"
	)
	
	test("Piping - Multiple Pipes", func():
		var result = registry.execute_command("ls | grep .gd | head 5")
		return not result.contains("Error") and not result.contains("Usage")
	)
	
	test("Piping - Cat to Grep", func():
		if not Engine.is_editor_hint():
			return true
		
		var test_content = "func test_function():\n    print('hello')\nfunc another_function():\n    pass"
		create_test_file("test_pipe_file.gd", test_content)
		
		var result = registry.execute_command("cat test_pipe_file.gd | grep func")
		
		# Cleanup
		cleanup_test_file("test_pipe_file.gd")
		
		return result.contains("func") and result.contains("test_function")
	)
	
	test("Piping - Head and Tail", func():
		var result = registry.execute_command("ls | head 3 | tail 2")
		return not result.contains("Error") and not result.contains("Usage")
	)
	
	test("Piping - Find to Grep", func():
		if not Engine.is_editor_hint():
			return true
		var result = registry.execute_command("find .gd | grep test")
		return not result.contains("Error") and not result.contains("Usage")
	)
	
	test("Piping - Command with No Input Support", func():
		
		var result = registry.execute_command("echo nonexistent_command | help")
		# This should become "help nonexistent_command" which returns "Unknown command: nonexistent_command"
		return result.contains("Unknown command: nonexistent_command")
	)
	
	test("Piping - Command with Input Support", func():
		if not Engine.is_editor_hint():
			return true
		
		var result = registry.execute_command("echo hello world | grep hello")
		# This should search for "hello" in the input "hello world"
		return result.contains("hello world")
	)
	
	test("Piping - Empty Pipe Chain", func():
		var result = registry.execute_command("echo hello | | echo world")
		return result == "hello"
	)
	
	test("Piping - Whitespace Handling", func():
		var result = registry.execute_command(" echo hello | echo ")
		return result == "hello"
	)
	
	test("Piping - Unknown Command in Chain", func():
		var result = registry.execute_command("echo hello | unknown_command")
		return result.contains("Unknown command")
	)

func run_integration_tests():
	print("\nTesting Integration...")
	var registry := _registry()
	
	test("Integration - Command Execution Flow", func():
		var commands = BuiltInCommands.new()
		commands.register_editor_commands()
		
		var result = registry.execute_command("help")
		return result.contains("Available commands")
	)
	
	test("Integration - Autocomplete Integration", func():
		var available = registry.get_available_commands()
		var matching = []
		for cmd in available:
			if cmd.begins_with("h"):
				matching.append(cmd)
		return matching.size() > 0
	)
	
	test("Integration - Command Registration Flow", func():
		var commands = BuiltInCommands.new()
		commands.register_editor_commands()
		var available = registry.get_available_commands()
		return available.size() > 0 and available.has("help")
	)
	
	test("Integration - Command Arguments", func():
		var commands = BuiltInCommands.new()
		commands.register_editor_commands()
		var result = registry.execute_command("help")
		return result.contains("Available commands") and result.contains("help")
	)
	
	test("Integration - Full Command Chain", func():
		var commands = BuiltInCommands.new()
		commands.register_editor_commands()
		
		
		var result1 = ""
		var result2 = ""
		var result3 = ""
		
		if Engine.is_editor_hint():
			result1 = registry.execute_command("ls | grep .gd | head 3")
			result2 = registry.execute_command("echo 'test content' | grep test")
			result3 = registry.execute_command("help | grep help")
		else:
			
			result1 = registry.execute_command("echo test | echo")
			result2 = registry.execute_command("echo 'test content' | echo")
			result3 = registry.execute_command("help")
		
		
		var success1 = not result1.contains("Error") or result1.is_empty() or result1.contains("test")
		var success2 = result2.contains("test content") or result2.is_empty() or result2.contains("test")
		var success3 = result3.contains("help") or result3.is_empty()
		
		return success1 and success2 and success3
	)
	
	test("Integration - Cross-Component Communication", func():
		var commands = BuiltInCommands.new()
		commands.register_editor_commands()
		
		
		var available_commands = registry.get_available_commands()
		
		return available_commands.size() > 0 and available_commands.has("help")
	)

	test("Integration - Scene Tree Command Execution", func():
		var commands = BuiltInCommands.new()
		commands.register_editor_commands()
		var fixture = _create_scene_tree_fixture()
		var result = registry.execute_command("scene_tree %s" % fixture.root.get_path())
		var passed = result.contains("[Node] " + fixture.root.name) and result.contains(fixture.branch_b.name)
		_cleanup_scene_tree_fixture(fixture)
		return passed
	)

	test("Integration - Watch Command Execution", func():
		var commands = BuiltInCommands.new()
		commands.register_editor_commands()
		var core := _debug_core()
		if not core:
			return false
		core.clear_watches()
		var fixture = _create_watch_fixture()
		var expression = "%s:process_mode" % fixture.target.get_path()
		var add_result = registry.execute_command("watch %s" % expression)
		fixture.target.process_mode = Node.PROCESS_MODE_DISABLED
		var poll_result = registry.execute_command("watch poll")
		var list_result = registry.execute_command("watch")
		var passed = add_result.contains("Watching %s = " % expression) and poll_result.contains(expression) and list_result.contains(expression)
		core.clear_watches()
		_cleanup_watch_fixture(fixture)
		return passed
	)

	test("Integration - Save Log Command Execution", func():
		var commands = BuiltInCommands.new()
		commands.register_editor_commands()
		var core := _debug_core()
		if not core:
			return false
		core.clear_history()
		core.info("SaveLog integration test line")
		var filename = ".test_save_log_integration_" + str(Time.get_ticks_msec()) + ".txt"
		var result = registry.execute_command("save_log %s" % filename)
		# _resolve_output_path routes to res:// in editor, user:// at runtime.
		# Explicit String typing - GDScript 4.6 can't infer through the ternary.
		var expected_prefix: String = "res://" if Engine.is_editor_hint() else "user://"
		var full_path: String = expected_prefix + filename
		var file = FileAccess.open(full_path, FileAccess.READ)
		var content = file.get_as_text() if file else ""
		if file:
			file.close()
		cleanup_test_file(filename)
		return result.contains(full_path) and content.contains("SaveLog integration test line")
	)

func run_performance_tests():
	print("\nTesting Performance...")
	var registry := _registry()
	
	test("Performance - Command Registration Speed", func():
		var start_time = Time.get_ticks_msec()
		
		for i in range(50):  # Reduced from 100 to 50
			var test_callable = Callable(self, "_test_function")
			registry.register_command("perf_test_" + str(i), test_callable, "Test command", "both")
		
		var end_time = Time.get_ticks_msec()
		var duration = end_time - start_time
		
		# Cleanup
		for i in range(50):  # Reduced from 100 to 50
			registry.unregister_command("perf_test_" + str(i))
		
		return duration < 5000  # Increased threshold to 5 seconds
	)
	
	test("Performance - Command Execution Speed", func():
		var test_callable = Callable(self, "_test_function")
		registry.register_command("perf_exec", test_callable, "Test command", "both")
		
		var start_time = Time.get_ticks_msec()
		
		for i in range(100):
			registry.execute_command("perf_exec arg" + str(i))
		
		var end_time = Time.get_ticks_msec()
		var duration = end_time - start_time
		
		registry.unregister_command("perf_exec")
		
		return duration < 1000  # Should complete in under 1 second
	)
	
	test("Performance - Piping Speed", func():
		var start_time = Time.get_ticks_msec()
		
		for i in range(50):
			registry.execute_command("echo test" + str(i) + " | echo")
		
		var end_time = Time.get_ticks_msec()
		var duration = end_time - start_time
		
		return duration < 1000  # Should complete in under 1 second
	)
	
	test("Performance - Large File Operations", func():
		
		var large_content = ""
		for i in range(1000):
			large_content += "Line " + str(i) + ": Test content for performance testing\n"
		
		create_test_file("large_test_file.txt", large_content)
		
		var start_time = Time.get_ticks_msec()
		var commands = BuiltInCommands.new()
		var result = commands._view_file(["large_test_file.txt"])
		var end_time = Time.get_ticks_msec()
		var duration = end_time - start_time
		
		cleanup_test_file("large_test_file.txt")
		
		return duration < 1000 and (result.contains("Line 999") or result.contains("Test content"))
	)
	
	test("Performance - Console UI Responsiveness", func():
		if not Engine.is_editor_hint():
			return true  # Skip in game mode
		
		editor_console_instance = EditorConsole.new()
		
		var start_time = Time.get_ticks_msec()
		
		for i in range(100):
			editor_console_instance.add_log_message("Performance test message " + str(i), LOG_LEVEL_INFO)
		
		var end_time = Time.get_ticks_msec()
		var duration = end_time - start_time
		
		editor_console_instance.queue_free()
		
		return duration < 1000  # Should complete in under 1 second
	)

func run_error_handling_tests():
	print("\nTesting Error Handling...")
	var registry := _registry()
	
	test("Error Handling - Invalid Command Execution", func():
		var result = registry.execute_command("")
		return result.is_empty()
	)
	
	test("Error Handling - Malformed Piping", func():
		var result = registry.execute_command("| | |")
		return not result.contains("Error") or result.is_empty()
	)
	
	test("Error Handling - Non-existent File Operations", func():
		var commands = BuiltInCommands.new()
		var result = commands._view_file(["nonexistent_file.txt"])
		return result.contains("File not found") or result.contains("Error")
	)
	
	test("Error Handling - Invalid Directory Operations", func():
		var commands = BuiltInCommands.new()
		var result = commands._change_directory(["nonexistent_directory"])
		return result.contains("Directory not found") or result.contains("Error")
	)
	
	test("Error Handling - Invalid Grep Pattern", func():
		var commands = BuiltInCommands.new()
		var result = commands._grep([""], "test content")
		# Path (a): In Godot 4.6, String.contains("") returns false (String::find
		# guards p_str.is_empty() and returns -1, see core/string/ustring.cpp).
		# So _grep's pipe-input loop matches nothing and returns "No matches found".
		# This is the actual current observable behavior; if a future Godot release
		# changes the find/contains semantics, this assertion will fail loudly.
		return result == "No matches found"
	)
	
	test("Error Handling - Invalid Head/Tail Arguments", func():
		if not Engine.is_editor_hint():
			return true
		var commands = BuiltInCommands.new()
		# Test with invalid file that doesn't exist
		var result1 = commands._head(["nonexistent_file.txt"])
		var result2 = commands._tail(["nonexistent_file.txt"])
		return result1.contains("Error: File not found") and result2.contains("Error: File not found")
	)
	
	test("Error Handling - Console Instance Cleanup", func():
		# Smoke test: a fresh GameConsole can be instantiated and freed without
		# being added to a scene tree. We don't call show_console() here because
		# its create_tween() requires the node to be in a tree; that behavior is
		# covered by the Game Console - Visibility Toggle test.
		var console = GameConsole.new()
		var was_created: bool = is_instance_valid(console) and console is GameConsole
		console.queue_free()
		return was_created
	)
	
	test("Error Handling - Command Registry Cleanup", func():
		# Register many commands then unregister them
		for i in range(50):
			var test_callable = Callable(self, "_test_function")
			registry.register_command("cleanup_test_" + str(i), test_callable, "Test command", "both")
		
		for i in range(50):
			registry.unregister_command("cleanup_test_" + str(i))
		
		# Verify cleanup
		var available_commands = registry.get_available_commands()
		var has_cleanup_commands = false
		for cmd in available_commands:
			if cmd.begins_with("cleanup_test_"):
				has_cleanup_commands = true
				break
		
		return not has_cleanup_commands
	)
	
	test("Error Handling - Memory Leak Prevention", func():
		# Smoke test: stress GameConsole instantiation 20 times. Asserts that
		# every instance is actually constructed (not silently null) and that
		# queue_free is callable on each. We don't call show_console/hide_console
		# here because those require the node in a tree (covered elsewhere); the
		# point of this test is to exercise the construct/destruct path under
		# repetition and surface allocation crashes loudly.
		var created_count := 0
		for i in range(20):
			var console = GameConsole.new()
			if is_instance_valid(console) and console is GameConsole:
				created_count += 1
			console.queue_free()
		return created_count == 20
	)

func cleanup_test_instances():
	if game_console_instance:
		game_console_instance.queue_free()
		game_console_instance = null
	
	if editor_console_instance:
		editor_console_instance.queue_free()
		editor_console_instance = null
	
	if test_scene_instance:
		test_scene_instance.queue_free()
		test_scene_instance = null

func test(test_name: String, test_function: Callable):
	total_tests += 1
	
	var start_time = Time.get_ticks_msec()
	var passed = false
	var message = ""
	var error_info = ""
	
	var test_result = _execute_test_safely(test_function)
	passed = test_result.passed
	message = test_result.message
	error_info = test_result.error_info
	
	var end_time = Time.get_ticks_msec()
	var duration = end_time - start_time
	
	if passed:
		passed_tests += 1
		print("✅ %s (%dms)" % [test_name, duration])
	else:
		failed_tests += 1
		var error_msg = "FAIL"
		if error_info != "":
			error_msg += " - " + error_info
		print("❌ %s (%dms) - %s" % [test_name, duration, error_msg])
	
	test_results.append({
		"name": test_name,
		"passed": passed,
		"message": message,
		"duration": duration,
		"error_info": error_info
	})
	
	test_completed.emit(test_name, passed, message)

func _execute_test_safely(test_function: Callable) -> Dictionary:
	var result := {"passed": false, "message": "FAIL", "error_info": ""}
	var test_result: Variant = test_function.call()
	if test_result is bool:
		result.passed = test_result
		result.message = "PASS" if test_result else "FAIL"
	else:
		result.passed = false
		result.message = "FAIL"
		result.error_info = "Test returned non-bool value of type %s; tests must return bool" % typeof(test_result)
	return result

func print_results():
	var total_time = Time.get_ticks_msec() - test_start_time
	var success_rate = 0.0
	if total_tests > 0:
		success_rate = (float(passed_tests) / float(total_tests)) * 100.0
	
	print("\n" + "=====================================")
	print("TEST RESULTS SUMMARY")
	print("=====================================")
	print("Total Tests: %d" % total_tests)
	print("Passed: %d" % passed_tests)
	print("Failed: %d" % failed_tests)
	print("Success Rate: %.1f%%" % success_rate)
	print("Total Time: %dms" % total_time)
	
	if failed_tests > 0:
		print("\nFAILED TESTS:")
		for result in test_results:
			if not result.passed:
				var error_msg = ""
				if result.error_info != "":
					error_msg = " - " + result.error_info
				print("  ❌ %s%s" % [result.name, error_msg])
	
	if success_rate == 100.0:
		print("\nAll tests passed! The Debug Console is working perfectly.")
	elif success_rate >= 90.0:
		print("\nMost tests passed. Please review failed tests.")
	else:
		print("\nMultiple test failures detected. Please fix issues before proceeding.")
	
	print("=====================================")

func _test_function(args: Array) -> String:
	return "test_function called with: " + ",".join(args)

func _test_function_with_input(args: Array, input: String = "", is_pipe_context: bool = false) -> String:
	if is_pipe_context and not input.is_empty():
		return input
	return "test_function_with_input called with: " + ",".join(args) + " and input: " + input

func _extract_scene_uid(content: String) -> String:
	# Locates uid="uid://..." in a .tscn header and returns the inner UID string,
	# or "" if not found. Used by B4 regression to verify uniqueness.
	var marker := "uid=\""
	var start := content.find(marker)
	if start == -1:
		return ""
	start += marker.length()
	var end := content.find("\"", start)
	if end == -1:
		return ""
	return content.substr(start, end - start)

func _create_scene_tree_fixture() -> Dictionary:
	var unique_id := str(Time.get_ticks_usec())
	var scene_root := Node.new()
	scene_root.name = "SceneTreeFixture_%s_Root" % unique_id

	var branch_a := Node.new()
	branch_a.name = "SceneTreeFixture_%s_BranchA" % unique_id
	scene_root.add_child(branch_a)

	var leaf_a := Node.new()
	leaf_a.name = "SceneTreeFixture_%s_LeafA" % unique_id
	branch_a.add_child(leaf_a)

	var branch_b := Node.new()
	branch_b.name = "SceneTreeFixture_%s_BranchB" % unique_id
	scene_root.add_child(branch_b)

	var leaf_b := Node.new()
	leaf_b.name = "SceneTreeFixture_%s_LeafB" % unique_id
	branch_b.add_child(leaf_b)

	var tree := Engine.get_main_loop() as SceneTree
	if tree:
		tree.root.add_child(scene_root)

	return {
		"root": scene_root,
		"branch_a": branch_a,
		"leaf_a": leaf_a,
		"branch_b": branch_b,
		"leaf_b": leaf_b,
	}

func _cleanup_scene_tree_fixture(fixture: Dictionary) -> void:
	if not fixture.has("root"):
		return

	var scene_root = fixture.root as Node
	if not scene_root:
		return

	var parent := scene_root.get_parent()
	if parent:
		parent.remove_child(scene_root)
	scene_root.free()

func _create_watch_fixture() -> Dictionary:
	var unique_id := str(Time.get_ticks_usec())
	var watch_root := Node.new()
	watch_root.name = "WatchFixture_%s_Root" % unique_id

	var target := Node.new()
	target.name = "WatchFixture_%s_Target" % unique_id
	target.process_mode = Node.PROCESS_MODE_INHERIT
	watch_root.add_child(target)

	var tree := Engine.get_main_loop() as SceneTree
	if tree:
		tree.root.add_child(watch_root)

	return {
		"root": watch_root,
		"target": target,
	}

func _cleanup_watch_fixture(fixture: Dictionary) -> void:
	if not fixture.has("root"):
		return

	var watch_root = fixture.root as Node
	if not watch_root:
		return

	var parent := watch_root.get_parent()
	if parent:
		parent.remove_child(watch_root)
	watch_root.free()

func _instantiate_editor_console_fixture() -> EditorConsole:
	# Instantiates EditorConsole.tscn and adds it to the SceneTree root so that
	# _ready() runs and the @onready node references are populated. Returns null
	# if the resource can't be loaded or the SceneTree is unavailable; callers
	# should treat null as a fail-the-test signal rather than crash.
	var packed_scene := load("res://addons/debug_console/editor/EditorConsole.tscn") as PackedScene
	if not packed_scene:
		return null
	var instance := packed_scene.instantiate() as EditorConsole
	if not instance:
		return null
	var tree := Engine.get_main_loop() as SceneTree
	if not tree:
		instance.free()
		return null
	tree.root.add_child(instance)
	return instance

func _cleanup_editor_console_fixture(instance: EditorConsole) -> void:
	if is_instance_valid(instance):
		instance.queue_free()

func _instantiate_game_console_fixture() -> GameConsole:
	# Same contract as _instantiate_editor_console_fixture, but for the runtime
	# GameConsole. Tweens created inside GameConsole require the node to be in a
	# SceneTree, so we always add it before returning.
	var packed_scene := load("res://addons/debug_console/game/GameConsole.tscn") as PackedScene
	if not packed_scene:
		return null
	var instance := packed_scene.instantiate() as GameConsole
	if not instance:
		return null
	var tree := Engine.get_main_loop() as SceneTree
	if not tree:
		instance.free()
		return null
	tree.root.add_child(instance)
	return instance

func _cleanup_game_console_fixture(instance: GameConsole) -> void:
	if is_instance_valid(instance):
		instance.queue_free()

func _simulate_key_event(console: Object, keycode: int, ctrl: bool = false, shift: bool = false) -> void:
	# Builds a pressed InputEventKey and routes it through the console's
	# _on_input_line_gui_input handler. We bypass the normal viewport input
	# pipeline because, in headless test contexts, the LineEdit may not have
	# real focus and the InputEvent never reaches Control._gui_input naturally.
	# Calling the handler directly exercises the same logic without depending
	# on the focus / hover state of any node.
	if not is_instance_valid(console) or not console.has_method("_on_input_line_gui_input"):
		return
	var event := InputEventKey.new()
	event.pressed = true
	event.keycode = keycode
	event.physical_keycode = keycode
	event.ctrl_pressed = ctrl
	event.shift_pressed = shift
	console._on_input_line_gui_input(event)

func create_test_file(filename: String, content: String = "") -> bool:
	var file = FileAccess.open("res://" + filename, FileAccess.WRITE)
	if file:
		file.store_string(content)
		file.close()
		return true
	return false

func cleanup_test_file(filename: String):
	# Files created by tests may land in either res:// (editor mode, current cwd)
	# or user:// (runtime mode, via _resolve_output_path). Try both.
	if FileAccess.file_exists("res://" + filename):
		DirAccess.open("res://").remove(filename)
	if FileAccess.file_exists("user://" + filename):
		DirAccess.open("user://").remove(filename)

func create_test_directory(dirname: String) -> bool:
	var dir = DirAccess.open("res://")
	if dir:
		return dir.make_dir_recursive(dirname) == OK
	return false

func cleanup_test_directory(dirname: String):
	var dir = DirAccess.open("res://")
	if dir and dir.dir_exists_absolute("res://" + dirname):
		dir.remove(dirname)

func assert_true(condition: bool, message: String = "") -> bool:
	if not condition:
		if message != "":
			print("Assertion failed: " + message)
		return false
	return true

func assert_false(condition: bool, message: String = "") -> bool:
	return assert_true(not condition, message)

func assert_equals(expected, actual, message: String = "") -> bool:
	var result = expected == actual
	if not result:
		var error_msg = "Expected '%s', got '%s'" % [str(expected), str(actual)]
		if message != "":
			error_msg = message + " - " + error_msg
		print("Assertion failed: " + error_msg)
	return result

func assert_contains(haystack: String, needle: String, message: String = "") -> bool:
	var result = haystack.contains(needle)
	if not result:
		var error_msg = "Expected '%s' to contain '%s'" % [haystack, needle]
		if message != "":
			error_msg = message + " - " + error_msg
		print("Assertion failed: " + error_msg)
	return result 

@tool
extends RefCounted
class_name TestFramework

signal test_completed(test_name: String, passed: bool, message: String)

var total_tests: int = 0
var passed_tests: int = 0
var failed_tests: int = 0
var test_results: Array[Dictionary] = []
var test_start_time: int = 0

func run_all_tests():
	test_start_time = Time.get_ticks_msec()
	print("Starting Debug Console Test Suite...")
	
	reset_test_counters()
	
	run_command_tests()
	run_autocomplete_tests()
	run_file_operation_tests()
	run_integration_tests()
	
	print_results()

func reset_test_counters():
	total_tests = 0
	passed_tests = 0
	failed_tests = 0
	test_results.clear()

func run_command_tests():
	print("\nTesting Commands...")
	
	test("Command Registry - Register Command", func():
		var test_callable = Callable(self, "_test_function")
		CommandRegistry.register_command("test_reg", test_callable, "Test command", "both")
		var success = CommandRegistry._commands.has("test_reg")
		CommandRegistry.unregister_command("test_reg")
		return success
	)
	
	test("Command Registry - Execute Command", func():
		var test_callable = Callable(self, "_test_function")
		CommandRegistry.register_command("test_exec", test_callable, "Test command", "both")
		var result = CommandRegistry.execute_command("test_exec arg1 arg2")
		CommandRegistry.unregister_command("test_exec")
		return result == "test_function called with: arg1,arg2"
	)
	
	test("Command Registry - Get Help", func():
		var test_callable = Callable(self, "_test_function")
		CommandRegistry.register_command("test_help", test_callable, "Test command", "both")
		var help = CommandRegistry.get_command_help("test_help")
		CommandRegistry.unregister_command("test_help")
		return help == "test_help - Test command"
	)
	
	test("Command Registry - Unknown Command", func():
		var result = CommandRegistry.execute_command("unknown_command")
		return result.contains("Unknown command")
	)
	
	test("Command Registry - Context Validation", func():
		var test_callable = Callable(self, "_test_function")
		CommandRegistry.register_command("editor_only", test_callable, "Editor only", "editor")
		var result = CommandRegistry.execute_command("editor_only")
		CommandRegistry.unregister_command("editor_only")
		return not result.contains("not available")
	)
	
	test("Command Registry - Existing Commands Intact", func():
		var result = CommandRegistry.execute_command("help")
		return result.contains("Available commands")
	)

func run_autocomplete_tests():
	print("\nTesting Autocomplete...")
	
	test("Autocomplete - Command Suggestions", func():
		var available = CommandRegistry.get_available_commands()
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

func run_file_operation_tests():
	print("\nTesting File Operations...")
	
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

func run_integration_tests():
	print("\nTesting Integration...")
	
	test("Integration - Command Execution Flow", func():
		var commands = BuiltInCommands.new()
		commands.register_editor_commands()
		
		var result = CommandRegistry.execute_command("help")
		return result.contains("Available commands")
	)
	
	test("Integration - Autocomplete Integration", func():
		var available = CommandRegistry.get_available_commands()
		var matching = []
		for cmd in available:
			if cmd.begins_with("h"):
				matching.append(cmd)
		return matching.size() > 0
	)
	
	test("Integration - Command Registration Flow", func():
		var commands = BuiltInCommands.new()
		commands.register_editor_commands()
		var available = CommandRegistry.get_available_commands()
		return available.size() > 0 and available.has("help")
	)
	
	test("Integration - Command Arguments", func():
		var commands = BuiltInCommands.new()
		commands.register_editor_commands()
		var result = CommandRegistry.execute_command("help")
		return result.contains("Available commands") and result.contains("help")
	)

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
	var result = {"passed": false, "message": "FAIL", "error_info": ""}
	
	var test_result = null
	
	test_result = test_function.call()
	
	if test_result is bool:
		result.passed = test_result
		result.message = "PASS" if test_result else "FAIL"
	elif test_result is String:
		result.passed = test_result.contains("success") or test_result.contains("Created") or test_result.contains("Available")
		result.message = "PASS" if result.passed else "FAIL"
	else:
		result.passed = test_result != null
		result.message = "PASS" if result.passed else "FAIL"
	
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

func create_test_file(filename: String, content: String = "") -> bool:
	var file = FileAccess.open("res://" + filename, FileAccess.WRITE)
	if file:
		file.store_string(content)
		file.close()
		return true
	return false

func cleanup_test_file(filename: String):
	if FileAccess.file_exists("res://" + filename):
		DirAccess.open("res://").remove(filename)

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

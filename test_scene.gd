extends Node2D

func _ready():
	print("Test scene loaded. GameConsole should be available.")
	print("Press F12 or Ctrl+` to open the debug console")
	print("Try commands like: fps, nodes, pause, timescale 2.0")
	print("Or run: test to execute comprehensive test suite")

func _input(event):
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_F1:
			print("F1 pressed - this should not interfere with console")
		elif event.keycode == KEY_F2:
			print("F2 pressed - this should not interfere with console")
		elif event.keycode == KEY_T and event.ctrl_pressed:
			_run_comprehensive_tests()

func _run_comprehensive_tests():
	print("\n =========================")
	print("RUNNING COMPREHENSIVE DEBUG CONSOLE TEST SUITE")
	print("=========================")
	
	var test_framework = TestFramework.new()
	test_framework.run_all_tests()
	
	print("\n =========================")
	print("TEST SUITE COMPLETED")
	print("=========================")
	
	# Cleanup
	test_framework.queue_free()

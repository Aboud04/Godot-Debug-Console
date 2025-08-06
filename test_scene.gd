extends Node2D

func _ready():
	print("Test scene loaded. GameConsole should be available.")
	print("Press F12 or Ctrl+` to open the debug console")
	print("Try commands like: fps, nodes, pause, timescale 2.0")

func _input(event):
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_F1:
			print("F1 pressed - this should not interfere with console")
		elif event.keycode == KEY_F2:
			print("F2 pressed - this should not interfere with console") 
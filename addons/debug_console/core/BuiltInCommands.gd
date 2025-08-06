@tool
class_name BuiltInCommands extends RefCounted

func register_editor_commands():
	register_universal_commands()
	
	CommandRegistry.register_command("scene", _get_current_scene, "Get current scene info", "editor")
	CommandRegistry.register_command("reload", _reload_scene, "Reload current scene", "editor")
	
	CommandRegistry.register_command("ls", _list_files, "List files in current directory", "editor")
	CommandRegistry.register_command("cd", _change_directory, "Change directory", "editor")
	CommandRegistry.register_command("pwd", _print_working_directory, "Print current working directory", "editor")
	CommandRegistry.register_command("mkdir", _make_directory, "Create directory", "editor")
	CommandRegistry.register_command("touch", _create_file, "Create file", "editor")
	CommandRegistry.register_command("rm", _remove_file, "Remove file or directory", "editor")
	CommandRegistry.register_command("mv", _move_file, "Move/rename file", "editor")
	CommandRegistry.register_command("cp", _copy_file, "Copy file", "editor")
	
	CommandRegistry.register_command("new_script", _create_script, "Create new script file", "editor")
	CommandRegistry.register_command("new_scene", _create_scene, "Create new scene file", "editor")
	CommandRegistry.register_command("new_resource", _create_resource, "Create new resource file", "editor")
	CommandRegistry.register_command("open", _open_file, "Open file in editor", "editor")
	CommandRegistry.register_command("node_types", _list_node_types, "List available node types for extends", "editor")
	
	CommandRegistry.register_command("test", _run_tests, "Run all tests", "editor")
	CommandRegistry.register_command("test_commands", _test_commands, "Test command functionality", "editor")
	CommandRegistry.register_command("test_autocomplete", _test_autocomplete, "Test autocomplete functionality", "editor")
	CommandRegistry.register_command("test_files", _test_file_operations, "Test file operations", "editor")
	CommandRegistry.register_command("quick_test", _quick_test, "Run quick test", "editor")

func register_game_commands():
	register_universal_commands()
	
	CommandRegistry.register_command("fps", _show_fps, "Show FPS information", "game")
	CommandRegistry.register_command("nodes", _count_nodes, "Count nodes in scene tree", "game")
	CommandRegistry.register_command("pause", _toggle_pause, "Toggle game pause", "game")
	CommandRegistry.register_command("timescale", _set_time_scale, "Set engine time scale", "game")

func register_universal_commands():
	CommandRegistry.register_command("help", _help, "Show available commands", "both")
	CommandRegistry.register_command("clear", _clear, "Clear console output", "both")
	CommandRegistry.register_command("echo", _echo, "Echo text back", "both")
	CommandRegistry.register_command("history", _history, "Show command history", "both")

#region Universal commands
func _help(args: Array) -> String:
	var cmd_name = ""
	if args.size() > 0:
		cmd_name = str(args[0])
	return CommandRegistry.get_command_help(cmd_name)

func _clear(args: Array) -> String:
	DebugCore.clear_history()
	if Engine.is_editor_hint() and DebugCore.editor_output:
		DebugCore.editor_output.clear_output()
	elif DebugCore.game_output:
		DebugCore.game_output.clear_output()
	
	return ""

func _echo(args: Array) -> String:
	return " ".join(args) if args.size() > 0 else "Usage: echo <message>"

func _history(args: Array) -> String:
	var history = DebugCore.get_history()
	var count = min(10, history.size())
	if args.size() > 0:
		count = min(args[0].to_int(), history.size())
	
	var recent = history.slice(-count)
	return "Recent history:\n" + "\n".join(recent)
#endregion

#region Editor commands
func _get_current_scene(args: Array) -> String:
	if not Engine.is_editor_hint():
		return "Not in editor"
	
	var edited_scene = EditorInterface.get_edited_scene_root()
	if edited_scene:
		return "Current scene: %s (%s)" % [edited_scene.name, edited_scene.scene_file_path]
	else:
		return "No scene loaded"

func _reload_scene(args: Array) -> String:
	if not Engine.is_editor_hint():
		return "Not in editor"
	
	EditorInterface.reload_scene_from_path(EditorInterface.get_edited_scene_root().scene_file_path)
	return "Scene reloaded"

#endregion

#region File system commands
var current_directory: String = "res://"

static var global_current_directory: String = "res://"

static func get_current_directory() -> String:
	return global_current_directory

static func set_current_directory(path: String):
	global_current_directory = path

func _list_files(args: Array) -> String:
	var dir = DirAccess.open(current_directory)
	if not dir:
		return "Error: Cannot access directory"
	
	var files = []
	dir.list_dir_begin()
	var file_name = dir.get_next()
	
	while file_name != "":
		if not file_name.begins_with("."):
			var icon = "📁" if dir.current_is_dir() else "📄"
			files.append("%s %s" % [icon, file_name])
		file_name = dir.get_next()
	
	dir.list_dir_end()
	files.sort()
	return "Files in %s:\n%s" % [current_directory, "\n".join(files)]

func _change_directory(args: Array) -> String:
	if args.size() == 0:
		return "Usage: cd <directory>"
	
	var target_dir = args[0]
	var new_path = current_directory
	
	if target_dir == "..":
		if current_directory == "res://":
			return "Already at root directory"
		var parent = current_directory.get_base_dir()
		if parent == "res:":
			parent = "res://"
		new_path = parent
	elif target_dir == ".":
		return "Current directory: %s" % current_directory
	elif target_dir == "/":
		new_path = "res://"
	else:
		if target_dir.begins_with("/"):
			new_path = "res://" + target_dir.substr(1)
		else:
			new_path = current_directory.path_join(target_dir)
	
	if DirAccess.dir_exists_absolute(new_path):
		current_directory = new_path
		set_current_directory(new_path)
		return "Changed to: %s" % current_directory
	else:
		return "Error: Directory not found"

func _print_working_directory(args: Array) -> String:
	return "Current directory: %s" % current_directory

func _make_directory(args: Array) -> String:
	if args.size() == 0:
		return "Usage: mkdir <directory_name>"
	
	var dir_name = args[0]
	var dir = DirAccess.open(current_directory)
	if not dir:
		return "Error: Cannot access directory"
	
	var result = dir.make_dir_recursive(dir_name)
	if result == OK:
		EditorInterface.get_resource_filesystem().scan()
		return "Created directory: %s" % dir_name
	else:
		return "Error: Failed to create directory"

func _create_file(args: Array) -> String:
	if args.size() == 0:
		return "Usage: touch <filename>"
	
	var file_name = args[0]
	var full_path = current_directory.path_join(file_name)
	var file = FileAccess.open(full_path, FileAccess.WRITE)
	if file:
		file.close()
		EditorInterface.get_resource_filesystem().scan()
		return "Created file: %s" % file_name
	else:
		return "Error: Failed to create file"

func _remove_file(args: Array) -> String:
	if args.size() == 0:
		return "Usage: rm <filename>"
	
	var file_name = args[0]
	var dir = DirAccess.open(current_directory)
	if not dir:
		return "Error: Cannot access directory"
	
	var result = dir.remove(file_name)
	if result == OK:
		EditorInterface.get_resource_filesystem().scan()
		return "Removed: %s" % file_name
	else:
		return "Error: Failed to remove file"

func _move_file(args: Array) -> String:
	if args.size() < 2:
		return "Usage: mv <source> <destination>"
	
	var source = args[0]
	var dest = args[1]
	var dir = DirAccess.open(current_directory)
	if not dir:
		return "Error: Cannot access directory"
	
	var result = dir.rename(source, dest)
	if result == OK:
		EditorInterface.get_resource_filesystem().scan()
		return "Moved %s to %s" % [source, dest]
	else:
		return "Error: Failed to move file"

func _copy_file(args: Array) -> String:
	if args.size() < 2:
		return "Usage: cp <source> <destination>"
	
	var source = args[0]
	var dest = args[1]
	
	var source_path = current_directory.path_join(source)
	var dest_path = current_directory.path_join(dest)
	
	var source_file = FileAccess.open(source_path, FileAccess.READ)
	if not source_file:
		return "Error: Cannot read source file"
	
	var dest_file = FileAccess.open(dest_path, FileAccess.WRITE)
	if not dest_file:
		source_file.close()
		return "Error: Cannot write destination file"
	
	dest_file.store_buffer(source_file.get_buffer(source_file.get_length()))
	source_file.close()
	dest_file.close()
	
	EditorInterface.get_resource_filesystem().scan()
	return "Copied %s to %s" % [source, dest]

func _create_script(args: Array) -> String:
	if args.size() == 0:
		return "Usage: new_script <filename> [extends_type] [class_name]"
	
	var file_name = args[0]
	if not file_name.ends_with(".gd"):
		file_name += ".gd"
	
	var extends_type = args[1] if args.size() > 1 else "Node"
	var classname = args[2] if args.size() > 2 else file_name.get_basename().capitalize().replace(" ", "")
	
	var valid_types = ["Node", "Node2D", "Node3D", "Control", "CanvasItem", "CanvasLayer", "Viewport", "Window", "SubViewport", "Area2D", "Area3D", "CollisionShape2D", "CollisionShape3D", "Sprite2D", "Sprite3D", "Label", "Button", "LineEdit", "TextEdit", "RichTextLabel", "Panel", "VBoxContainer", "HBoxContainer", "GridContainer", "CenterContainer", "MarginContainer", "ScrollContainer", "TabContainer", "SplitContainer", "AspectRatioContainer", "TextureRect", "ColorRect", "NinePatchRect", "ProgressBar", "Slider", "SpinBox", "CheckBox", "CheckButton", "OptionButton", "ItemList", "Tree", "TreeItem", "FileDialog", "ColorPicker", "ColorPickerButton", "MenuButton", "PopupMenu", "MenuBar", "ToolButton", "LinkButton", "TextureButton", "TextureProgressBar", "AnimationPlayer", "AnimationTree", "Tween", "Timer", "Camera2D", "Camera3D", "Light2D", "Light3D", "AudioStreamPlayer", "AudioStreamPlayer2D", "AudioStreamPlayer3D", "AudioListener2D", "AudioListener3D", "RigidBody2D", "RigidBody3D", "CharacterBody2D", "CharacterBody3D", "StaticBody2D", "StaticBody3D", "KinematicBody2D", "KinematicBody3D", "Path2D", "Path3D", "NavigationAgent2D", "NavigationAgent3D", "NavigationRegion2D", "NavigationRegion3D", "NavigationPolygon", "NavigationMesh", "NavigationLink2D", "NavigationLink3D", "NavigationObstacle2D", "NavigationObstacle3D", "NavigationPathQueryParameters2D", "NavigationPathQueryParameters3D", "NavigationPathQueryResult2D", "NavigationPathQueryResult3D", "NavigationMeshSourceGeometry2D", "NavigationMeshSourceGeometry3D", "NavigationMeshSourceGeometryData2D", "NavigationMeshSourceGeometryData3D"]
	
	if not valid_types.has(extends_type):
		return "Error: Invalid extends type '%s'. Use: %s" % [extends_type, ", ".join(valid_types.slice(0, 10)) + "..."]
	
	var script_content = """extends %s

class_name %s

func _ready():
	pass

func _process(delta):
	pass
""" % [extends_type, classname]
	
	var full_path = current_directory.path_join(file_name)
	var file = FileAccess.open(full_path, FileAccess.WRITE)
	if file:
		file.store_string(script_content)
		file.close()
		EditorInterface.get_resource_filesystem().scan()
		return "Created script: %s (extends %s)" % [file_name, extends_type]
	else:
		return "Error: Failed to create script"

func _create_scene(args: Array) -> String:
	if args.size() == 0:
		return "Usage: new_scene <filename> [root_node_type]"
	
	var file_name = args[0]
	if not file_name.ends_with(".tscn"):
		file_name += ".tscn"
	
	var root_type = args[1] if args.size() > 1 else "Node"
	var script_name = file_name.replace(".tscn", ".gd")
	var classname = file_name.get_basename().capitalize().replace(" ", "")
	
	var script_result = _create_script([script_name.get_basename(), root_type, classname])
	if not script_result.contains("Created script"):
		return "Error: " + script_result
	
	var scene_content = """[gd_scene load_steps=2 format=3 uid="uid://bqxvj6y5n8q8p"]

[ext_resource type="Script" path="res://%s" id="1_0"]

[node name="%s" type="%s"]
script = ExtResource("1_0")
""" % [script_name, classname, root_type]
	
	var scene_file = FileAccess.open("res://" + file_name, FileAccess.WRITE)
	if scene_file:
		scene_file.store_string(scene_content)
		scene_file.close()
		EditorInterface.get_resource_filesystem().scan()
		return "Created scene: %s with script: %s" % [file_name, script_name]
	else:
		return "Error: Failed to create scene file"

func _create_resource(args: Array) -> String:
	if args.size() == 0:
		return "Usage: new_resource <filename> [resource_type]"
	
	var file_name = args[0]
	if not file_name.ends_with(".tres"):
		file_name += ".tres"
	
	var resource_type = args[1] if args.size() > 1 else "Resource"
	
	var resource_content = """[gd_resource type="%s" format=3]
""" % resource_type
	
	var file = FileAccess.open("res://" + file_name, FileAccess.WRITE)
	if file:
		file.store_string(resource_content)
		file.close()
		EditorInterface.get_resource_filesystem().scan()
		return "Created resource: %s" % file_name
	else:
		return "Error: Failed to create resource"

func _open_file(args: Array) -> String:
	if args.size() == 0:
		return "Usage: open <filename>"
	
	var file_name = args[0]
	var full_path = "res://" + file_name
	
	if FileAccess.file_exists(full_path):
		EditorInterface.open_scene_from_path(full_path)
		return "Opened: %s" % file_name
	else:
		return "Error: File not found"

func _list_node_types(args: Array) -> String:
	var valid_types = ["Node", "Node2D", "Node3D", "Control", "CanvasItem", "CanvasLayer", "Viewport", "Window", "SubViewport", "Area2D", "Area3D", "CollisionShape2D", "CollisionShape3D", "Sprite2D", "Sprite3D", "Label", "Button", "LineEdit", "TextEdit", "RichTextLabel", "Panel", "VBoxContainer", "HBoxContainer", "GridContainer", "CenterContainer", "MarginContainer", "ScrollContainer", "TabContainer", "SplitContainer", "AspectRatioContainer", "TextureRect", "ColorRect", "NinePatchRect", "ProgressBar", "Slider", "SpinBox", "CheckBox", "CheckButton", "OptionButton", "ItemList", "Tree", "TreeItem", "FileDialog", "ColorPicker", "ColorPickerButton", "MenuButton", "PopupMenu", "MenuBar", "ToolButton", "LinkButton", "TextureButton", "TextureProgressBar", "AnimationPlayer", "AnimationTree", "Tween", "Timer", "Camera2D", "Camera3D", "Light2D", "Light3D", "AudioStreamPlayer", "AudioStreamPlayer2D", "AudioStreamPlayer3D", "AudioListener2D", "AudioListener3D", "RigidBody2D", "RigidBody3D", "CharacterBody2D", "CharacterBody3D", "StaticBody2D", "StaticBody3D", "KinematicBody2D", "KinematicBody3D", "Path2D", "Path3D", "NavigationAgent2D", "NavigationAgent3D", "NavigationRegion2D", "NavigationRegion3D", "NavigationPolygon", "NavigationMesh", "NavigationLink2D", "NavigationLink3D", "NavigationObstacle2D", "NavigationObstacle3D", "NavigationPathQueryParameters2D", "NavigationPathQueryParameters3D", "NavigationPathQueryResult2D", "NavigationPathQueryResult3D", "NavigationMeshSourceGeometry2D", "NavigationMeshSourceGeometry3D", "NavigationMeshSourceGeometryData2D", "NavigationMeshSourceGeometryData3D"]
	
	return "Available node types:\n" + "\n".join(valid_types)
#endregion

#region Testing commands
func _run_tests(args: Array) -> String:
	var test_framework = TestFramework.new()
	test_framework.run_all_tests()
	
	register_editor_commands()
	
	return "Tests completed. Console reset. Check console for results."

func _test_commands(args: Array) -> String:
	var test_framework = TestFramework.new()
	test_framework.run_command_tests()
	
	register_editor_commands()
	
	return "Command tests completed. Console reset. Check console for results."

func _test_autocomplete(args: Array) -> String:
	var test_framework = TestFramework.new()
	test_framework.run_autocomplete_tests()
	
	register_editor_commands()
	
	return "Autocomplete tests completed. Console reset. Check console for results."

func _test_file_operations(args: Array) -> String:
	var test_framework = TestFramework.new()
	test_framework.run_file_operation_tests()
	
	register_editor_commands()
	
	return "File operation tests completed. Console reset. Check console for results."

func _quick_test(args: Array) -> String:
	var test_framework = TestFramework.new()
	test_framework.run_command_tests()
	return "Quick test completed"
#endregion

#region Game commands
func _show_fps(args: Array) -> String:
	var fps = Engine.get_frames_per_second()
	return "FPS: %d" % fps

func _count_nodes(args: Array) -> String:
	var count = _count_nodes_recursive(Engine.get_main_loop().current_scene)
	return "Total nodes in scene: %d" % count

func _count_nodes_recursive(node: Node) -> int:
	var count = 1
	for child in node.get_children():
		count += _count_nodes_recursive(child)
	return count

func _toggle_pause(args: Array) -> String:
	var tree = Engine.get_main_loop()
	tree.paused = not tree.paused
	return "Game %s" % ("paused" if tree.paused else "unpaused")

func _set_time_scale(args: Array) -> String:
	if args.size() == 0:
		return "Current time scale: %.2f" % Engine.time_scale
	
	var scale = args[0].to_float()
	if scale <= 0:
		return "Time scale must be positive"
	
	Engine.time_scale = scale
	return "Time scale set to: %.2f" % scale

#endregion

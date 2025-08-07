@tool
class_name BuiltInCommands extends RefCounted

#region BuiltInCommands
func register_editor_commands():
	register_universal_commands()
	
	CommandRegistry.register_command("scene", _get_current_scene, "Get current scene info", "editor")
	CommandRegistry.register_command("reload", _reload_scene, "Reload current scene", "editor")
	
	CommandRegistry.register_command("ls", _list_files, "List files in current directory", "editor", true)
	CommandRegistry.register_command("cd", _change_directory, "Change directory", "editor")
	CommandRegistry.register_command("pwd", _print_working_directory, "Print current working directory", "editor")
	CommandRegistry.register_command("mkdir", _make_directory, "Create directory", "editor")
	CommandRegistry.register_command("touch", _create_file, "Create file", "editor")
	CommandRegistry.register_command("rm", _remove_file, "Remove file or directory", "editor")
	CommandRegistry.register_command("rmdir", _remove_directory, "Remove directory", "editor")
	CommandRegistry.register_command("mv", _move_file, "Move/rename file", "editor")
	CommandRegistry.register_command("cp", _copy_file, "Copy file", "editor")
	CommandRegistry.register_command("cat", _view_file, "View file contents", "editor", true)
	CommandRegistry.register_command("refresh", _refresh_filesystem, "Refresh Godot filesystem", "editor")
	
	CommandRegistry.register_command("find", _find, "Find files by name in current or subdirectories", "editor")
	CommandRegistry.register_command("grep", _grep, "Search for text inside files", "editor", true)
	CommandRegistry.register_command("stat", _stat, "Display file information such as size, type, and modification time", "editor")
	CommandRegistry.register_command("head", _head, "Show first N lines of input or file", "editor", true)
	CommandRegistry.register_command("tail", _tail, "Show last N lines of input or file", "editor", true)

	
	CommandRegistry.register_command("new_script", _create_script, "Create new script file", "editor")
	CommandRegistry.register_command("new_scene", _create_scene, "Create new scene file", "editor")
	CommandRegistry.register_command("new_resource", _create_resource, "Create new resource file", "editor")
	CommandRegistry.register_command("open", _open_file, "Open file in editor", "editor")
	CommandRegistry.register_command("node_types", _list_node_types, "List available node types for extends", "editor")
	
	CommandRegistry.register_command("save_scenes", _save_scene, "Save all open scenes", "editor")
	CommandRegistry.register_command("run_project", _run_project, "Run the main scene or a specific scene of your choice", "editor")
	CommandRegistry.register_command("stop_project", _stop_project, "Stop the currently running scene or project", "editor")

	
	
	
	CommandRegistry.register_command("test_commands", _test_commands, "Test command functionality", "editor")
	CommandRegistry.register_command("test_autocomplete", _test_autocomplete, "Test autocomplete functionality", "editor")
	CommandRegistry.register_command("test_files", _test_file_operations, "Test file operations", "editor")
	CommandRegistry.register_command("test_pipes", _test_pipes, "Test command piping functionality", "editor")
	CommandRegistry.register_command("quick_test", _quick_test, "Run quick test", "editor")

func register_game_commands():
	register_universal_commands()
	
	CommandRegistry.register_command("fps", _show_fps, "Show FPS information", "game")
	CommandRegistry.register_command("nodes", _count_nodes, "Count nodes in scene tree", "game")
	CommandRegistry.register_command("pause", _toggle_pause, "Toggle game pause", "game")
	CommandRegistry.register_command("timescale", _set_time_scale, "Set engine time scale", "game")

func register_universal_commands():
	CommandRegistry.register_command("test", _run_tests, "Run all tests", "both")
	CommandRegistry.register_command("help", _help, "Show available commands", "both")
	CommandRegistry.register_command("clear", _clear, "Clear console output", "both")
	CommandRegistry.register_command("history", _show_history, "Show command history", "both")
	CommandRegistry.register_command("clear_history", _clear_history, "Clear command history", "both")
	CommandRegistry.register_command("echo", _echo, "Echo text back", "both", true)

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

func _echo(args: Array, input: String = "", is_pipe_context: bool = false) -> String:
	if not input.is_empty():
		return input
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

func _refresh_filesystem(args: Array) -> String:
	if not Engine.is_editor_hint():
		return "Not in editor"
	
	EditorInterface.get_resource_filesystem().scan()
	return "Filesystem refreshed"

#endregion

#region File system commands
var current_directory: String = "res://"

static var global_current_directory: String = "res://"

static func get_current_directory() -> String:
	return global_current_directory

static func set_current_directory(path: String):
	global_current_directory = path

func _list_files(args: Array, input: String = "", is_pipe_context: bool = false) -> String:
	var dir = DirAccess.open(current_directory)
	if not dir:
		return "Error: Cannot access directory"
	
	var files = []
	dir.list_dir_begin()
	var file_name = dir.get_next()
	
	while file_name != "":
		if not file_name.begins_with("."):
			files.append(file_name)
		file_name = dir.get_next()
	
	dir.list_dir_end()
	files.sort()
	
	var colored_files = []
	for fn in files:
		var colored_name = _get_colored_filename(fn, dir.current_is_dir())
		colored_files.append(colored_name)
	
	if is_pipe_context:
		return "\n".join(colored_files)
	
	return "Files in %s:\n%s" % [current_directory, "\t".join(colored_files)]

func _get_colored_filename(filename: String, is_dir: bool) -> String:
	if is_dir:
		return "[color=#4A90E2]📁 %s[/color]" % filename  
	var extension = filename.get_extension().to_lower()
	if extension in ["gd", "cs", "py", "sh", "bat", "exe"]:
		return "[color=#50C878]📄 %s[/color]" % filename 
	elif extension in ["zip", "tar", "gz", "rar", "7z", "bz2", "xz"]:
		return "[color=#FF6B6B]📦 %s[/color]" % filename
	elif extension in ["png", "jpg", "jpeg", "gif", "bmp", "svg", "webp", "ico", "tiff"]:
		return "[color=#FF69B4]🖼️ %s[/color]" % filename  
	elif extension in ["mp3", "wav", "ogg", "flac", "aac", "m4a", "wma"]:
		return "[color=#40E0D0]🎵 %s[/color]" % filename  
	elif extension in ["mp4", "avi", "mkv", "mov", "wmv", "flv", "webm", "ogv"]:
		return "[color=#FFD700]🎬 %s[/color]" % filename  
	elif extension in ["tscn", "tres", "godot", "import"]:
		return "[color=#87CEEB]🎮 %s[/color]" % filename  
	elif extension in ["json", "xml", "yaml", "yml", "toml", "ini", "cfg", "conf"]:
		return "[color=#FFA500]⚙️ %s[/color]" % filename  
	elif extension in ["txt", "md", "rst", "doc", "docx", "pdf", "rtf"]:
		return "[color=#F5F5F5]📝 %s[/color]" % filename  
	elif filename.ends_with("~") or filename.ends_with(".bak") or filename.ends_with(".backup"):
		return "[color=#696969]💾 %s[/color]" % filename 
	elif filename.begins_with("."):
		return "[color=#696969] %s[/color]" % filename  
	else:
		return "[color=#FFFFFF]📄 %s[/color]" % filename  

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
		_refresh_filesystem([])
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
		_refresh_filesystem([])
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
		_refresh_filesystem([])
		return "Removed: %s" % file_name
	else:
		return "Error: Failed to remove file"

func _remove_directory(args: Array) -> String:
	if args.size() == 0:
		return "Usage: rmdir <directory>"
	
	var dir_name = args[0]
	var dir = DirAccess.open(current_directory)
	if not dir:
		return "Error: Cannot access directory"
	
	var result = dir.remove(dir_name)
	if result == OK:
		_refresh_filesystem([])
		return "Removed directory: %s" % dir_name
	else:
		return "Error: Failed to remove directory"

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
		_refresh_filesystem([])
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
	
	_refresh_filesystem([])
	return "Copied %s to %s" % [source, dest]

func _view_file(args: Array, input: String = "", is_pipe_context: bool = false) -> String:
	if args.size() == 0:
		return "Usage: cat <filename>"
	
	var file_name = args[0]
	var full_path = current_directory.path_join(file_name)
	
	if not FileAccess.file_exists(full_path):
		return "Error: File not found - %s" % full_path
	
	var file = FileAccess.open(full_path, FileAccess.READ)
	if not file:
		return "Error: Cannot read file - %s" % file_name
	
	var content = file.get_as_text()
	file.close()
	

	if is_pipe_context or not input.is_empty():
		return content
	
	var extension = file_name.get_extension().to_lower()
	if extension == "gd":
		content = _colorize_gdscript(content)
	
	# Limit output to prevent console overflow
	var limit: int = 3000
	if content.length() > limit:  
		var preview = content.substr(0, limit)
		return "%s:\n%s\n... (truncated)" % [file_name, preview]
	else:
		return "%s:\n%s" % [file_name, content]

func _colorize_gdscript(content: String) -> String:
	var lines = content.split("\n")
	var colored_lines = []
	
	for line in lines:
		var colored_line = line
		

		if line.strip_edges().begins_with("#"):
			colored_line = "[color=#999999]%s[/color]" % line
		else:

			colored_line = _color_strings(colored_line)
			

			colored_line = _color_comments(colored_line)
			
			
			if not _is_line_comment(line):
				colored_line = _color_keywords(colored_line)
				colored_line = _color_types(colored_line)
				colored_line = _color_functions(colored_line)
				colored_line = _color_numbers(colored_line)
				colored_line = _color_function_definitions(colored_line)
		
		colored_lines.append(colored_line)
	
	return "\n".join(colored_lines)

func _is_line_comment(line: String) -> bool:
	return line.strip_edges().begins_with("#")

func _color_strings(text: String) -> String:
	var result = text
	

	var i = 0
	while i < result.length():
		if result[i] == '"':
			var start = i
			i += 1
			var escaped = false
			while i < result.length():
				if escaped:
					escaped = false
				elif result[i] == '\\':
					escaped = true
				elif result[i] == '"':
					break
				i += 1
			if i < result.length():
				var string_content = result.substr(start, i - start + 1)
				var colored_string = "[color=#98D8C8]%s[/color]" % string_content
				result = result.substr(0, start) + colored_string + result.substr(i + 1)
				i = start + colored_string.length()
		else:
			i += 1
	

	i = 0
	while i < result.length():
		if result[i] == "'" and not _is_inside_color_tag(result, i):
			var start = i
			i += 1
			var escaped = false
			while i < result.length():
				if escaped:
					escaped = false
				elif result[i] == '\\':
					escaped = true
				elif result[i] == "'":
					break
				i += 1
			if i < result.length():
				var string_content = result.substr(start, i - start + 1)
				var colored_string = "[color=#98D8C8]%s[/color]" % string_content
				result = result.substr(0, start) + colored_string + result.substr(i + 1)
				i = start + colored_string.length()
		else:
			i += 1
	
	return result

func _color_comments(text: String) -> String:
	var hash_pos = text.find("#")
	if hash_pos != -1 and not _is_inside_color_tag(text, hash_pos):
		var before_comment = text.substr(0, hash_pos)
		var comment = text.substr(hash_pos)
		return before_comment + "[color=#999999]%s[/color]" % comment
	return text

func _color_keywords(text: String) -> String:
	var keywords = ["extends", "class_name", "func", "var", "const", "signal", "enum", 
					"if", "elif", "else", "for", "while", "match", "continue", "break", 
					"return", "pass", "and", "or", "not", "in", "is", "as", "self", 
					"true", "false", "null", "PI", "TAU", "INF", "NAN"]
	
	var result = text
	for keyword in keywords:
		result = _replace_whole_word(result, keyword, "[color=#FF6B9D]%s[/color]" % keyword)
	return result

func _color_types(text: String) -> String:
	var types = ["bool", "int", "float", "String", "Vector2", "Vector3", "Color", 
				 "Array", "Dictionary", "Node2D", "Node3D", "Node", "Control", "Resource"]
	
	var result = text
	for type in types:
		result = _replace_whole_word(result, type, "[color=#4ECDC4]%s[/color]" % type)
	return result

func _color_functions(text: String) -> String:
	var builtins = ["print", "printerr", "printt", "prints", "push_error", "push_warning",
					"len", "range", "abs", "min", "max", "clamp", "lerp", "sin", "cos", "tan"]
	
	var result = text
	for builtin in builtins:
		var pattern = builtin + "("
		var pos = result.find(pattern)
		while pos != -1:
			if _is_word_boundary_before(result, pos) and not _is_inside_color_tag(result, pos):
				var colored_func = "[color=#45B7D1]%s[/color](" % builtin
				result = result.substr(0, pos) + colored_func + result.substr(pos + pattern.length())
				pos = result.find(pattern, pos + colored_func.length())
			else:
				pos = result.find(pattern, pos + 1)
	return result

func _color_numbers(text: String) -> String:
	var result = text
	var i = 0
	while i < result.length():
		if result[i].is_valid_int() and not _is_inside_color_tag(result, i):
			if i == 0 or not result[i-1].is_valid_identifier():
				var start = i
				while i < result.length() and (result[i].is_valid_int() or result[i] == '.'):
					i += 1
				if i >= result.length() or not result[i].is_valid_identifier():
					var number = result.substr(start, i - start)
					var colored_number = "[color=#F7DC6F]%s[/color]" % number
					result = result.substr(0, start) + colored_number + result.substr(i)
					i = start + colored_number.length()
					continue
		i += 1
	return result

func _color_function_definitions(text: String) -> String:
	var func_pos = text.find("func ")
	if func_pos != -1 and not _is_inside_color_tag(text, func_pos):
		var after_func = func_pos + 5
		while after_func < text.length() and text[after_func] == ' ':
			after_func += 1
		
		var name_start = after_func
		var name_end = name_start
		while name_end < text.length() and (text[name_end].is_valid_identifier() or text[name_end] == '_'):
			name_end += 1
		
		if name_end > name_start:
			var func_name = text.substr(name_start, name_end - name_start)
			var colored_name = "[color=#FFB347]%s[/color]" % func_name
			return text.substr(0, name_start) + colored_name + text.substr(name_end)
	return text

func _replace_whole_word(text: String, word: String, replacement: String) -> String:
	var result = text
	var pos = 0
	while pos < result.length():
		pos = result.find(word, pos)
		if pos == -1:
			break
		
		if _is_word_boundary_before(result, pos) and _is_word_boundary_after(result, pos + word.length()) and not _is_inside_color_tag(result, pos):
			result = result.substr(0, pos) + replacement + result.substr(pos + word.length())
			pos += replacement.length()
		else:
			pos += 1
	return result

func _is_word_boundary_before(text: String, pos: int) -> bool:
	if pos == 0:
		return true
	var prev_char = text[pos - 1]
	return not (prev_char.is_valid_identifier() or prev_char == '_')

func _is_word_boundary_after(text: String, pos: int) -> bool:
	if pos >= text.length():
		return true
	var next_char = text[pos]
	return not (next_char.is_valid_identifier() or next_char == '_')

func _is_inside_color_tag(text: String, pos: int) -> bool:
	var check_pos = pos - 1
	while check_pos >= 0:
		if text.substr(check_pos, 8) == "[/color]":
			return false
		if text.substr(check_pos, 7) == "[color=":
			return true
		check_pos -= 1
	return false

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
		_refresh_filesystem([])
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
		_refresh_filesystem([])
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
		_refresh_filesystem([])
		return "Created resource: %s" % file_name
	else:
		return "Error: Failed to create resource"

func _open_file(args: Array) -> String:
	if args.size() == 0:
		return "Usage: open <filename>"
	
	var file_name = args[0]
	var full_path = current_directory.path_join(file_name)
	
	if not FileAccess.file_exists(full_path):
		return "Error: File not found - %s" % full_path
	
	var extension = file_name.get_extension().to_lower()
	
	if extension == "tscn":
		EditorInterface.open_scene_from_path(full_path)
		return "Opened scene: %s" % file_name
	elif extension == "gd" or extension == "cs":
		var script = load(full_path)
		if script:
			EditorInterface.edit_script(script)
			return "Opened script: %s" % file_name
		else:
			return "Error: Could not load script - %s" % file_name
	elif extension == "tres":
		var resource = load(full_path)
		if resource:
			EditorInterface.edit_resource(resource)
			return "Opened resource: %s" % file_name
		else:
			return "Error: Could not load resource - %s" % file_name
	elif extension in ["txt", "md", "json", "xml", "yaml", "yml", "cfg", "ini", "log"]:
		var file = FileAccess.open(full_path, FileAccess.READ)
		if file:
			var content = file.get_as_text()
			file.close()
			var preview = content.substr(0, min(500, content.length()))
			if content.length() > 500:
				preview += "\n... (truncated, %d total characters)" % content.length()
			return "Content of %s:\n%s" % [file_name, preview]
		else:
			return "Error: Could not read file - %s" % file_name
	else:
		var file = FileAccess.open(full_path, FileAccess.READ)
		if file:
			var size = file.get_length()
			file.close()
			return "File info: %s (%d bytes)\nUse 'cat %s' to view content or open externally" % [file_name, size, file_name]
		else:
			return "Error: Cannot access file - %s" % file_name

func _list_node_types(args: Array) -> String:
	var valid_types = ["Node", "Node2D", "Node3D", "Control", "CanvasItem", "CanvasLayer", "Viewport", "Window", "SubViewport", "Area2D", "Area3D", "CollisionShape2D", "CollisionShape3D", "Sprite2D", "Sprite3D", "Label", "Button", "LineEdit", "TextEdit", "RichTextLabel", "Panel", "VBoxContainer", "HBoxContainer", "GridContainer", "CenterContainer", "MarginContainer", "ScrollContainer", "TabContainer", "SplitContainer", "AspectRatioContainer", "TextureRect", "ColorRect", "NinePatchRect", "ProgressBar", "Slider", "SpinBox", "CheckBox", "CheckButton", "OptionButton", "ItemList", "Tree", "TreeItem", "FileDialog", "ColorPicker", "ColorPickerButton", "MenuButton", "PopupMenu", "MenuBar", "ToolButton", "LinkButton", "TextureButton", "TextureProgressBar", "AnimationPlayer", "AnimationTree", "Tween", "Timer", "Camera2D", "Camera3D", "Light2D", "Light3D", "AudioStreamPlayer", "AudioStreamPlayer2D", "AudioStreamPlayer3D", "AudioListener2D", "AudioListener3D", "RigidBody2D", "RigidBody3D", "CharacterBody2D", "CharacterBody3D", "StaticBody2D", "StaticBody3D", "KinematicBody2D", "KinematicBody3D", "Path2D", "Path3D", "NavigationAgent2D", "NavigationAgent3D", "NavigationRegion2D", "NavigationRegion3D", "NavigationPolygon", "NavigationMesh", "NavigationLink2D", "NavigationLink3D", "NavigationObstacle2D", "NavigationObstacle3D", "NavigationPathQueryParameters2D", "NavigationPathQueryParameters3D", "NavigationPathQueryResult2D", "NavigationPathQueryResult3D", "NavigationMeshSourceGeometry2D", "NavigationMeshSourceGeometry3D", "NavigationMeshSourceGeometryData2D", "NavigationMeshSourceGeometryData3D"]
	
	return "Available node types:\n" + "\n".join(valid_types)
#endregion

#region Search and filter commands
func _find(args: Array) -> String:
	var dir = DirAccess.open(current_directory)
	if not dir:
		return "Error: Cannot access directory"
	
	var search_name = args[0] if args.size() > 0 else ""
	if search_name.is_empty():
		return "Usage: find <filename_pattern>"
	
	var results = []
	_find_recursive(dir, search_name, results)
	
	if results.is_empty():
		return "No files found matching: %s" % search_name
	else:
		return "Found %d files:\n%s" % [results.size(), "\n".join(results)]

func _find_recursive(dir: DirAccess, pattern: String, results: Array):
	dir.list_dir_begin()
	var file_name = dir.get_next()
	
	while file_name != "":
		if not file_name.begins_with("."):
			var full_path = dir.get_current_dir().path_join(file_name)
			if dir.current_is_dir():
				var subdir = DirAccess.open(full_path)
				if subdir:
					_find_recursive(subdir, pattern, results)
			elif file_name.contains(pattern):
				results.append(full_path)
		file_name = dir.get_next()
	
	dir.list_dir_end()

func _grep(args: Array, input: String = "", is_pipe_context: bool = false) -> String:
	var search_pattern = ""
	var search_path = current_directory
	
	if args.size() > 0:
		search_pattern = args[0]
	else:
		return "Usage: grep <pattern> [path] or use with pipe"
	
	if not input.is_empty():
		var lines = input.split("\n")
		var results = []
		for i in range(lines.size()):
			if lines[i].contains(search_pattern):
				results.append(lines[i])  
		return "\n".join(results) if not results.is_empty() else "No matches found"
	

	if args.size() > 1:
		search_path = current_directory.path_join(args[1])
	
	var results = []
	_grep_recursive(search_path, search_pattern, results)
	
	if results.is_empty():
		return "No matches found for: %s" % search_pattern
	else:
		return "Found %d matches:\n%s" % [results.size(), "\n".join(results)]

func _grep_recursive(path: String, pattern: String, results: Array):
	if FileAccess.file_exists(path):
		var file = FileAccess.open(path, FileAccess.READ)
		if file:
			var content = file.get_as_text()
			file.close()
			var lines = content.split("\n")
			for i in range(lines.size()):
				if lines[i].contains(pattern):
					results.append("%s:%d: %s" % [path, i + 1, lines[i]])
	elif DirAccess.dir_exists_absolute(path):
		var dir = DirAccess.open(path)
		if dir:
			dir.list_dir_begin()
			var file_name = dir.get_next()
			while file_name != "":
				if not file_name.begins_with("."):
					var full_path = path.path_join(file_name)
					_grep_recursive(full_path, pattern, results)
				file_name = dir.get_next()
			dir.list_dir_end()

func _stat(args: Array) -> String:
	if args.size() == 0:
		return "Usage: stat <filename>"
	
	var file_name = args[0]
	var full_path = current_directory.path_join(file_name)
	
	if not FileAccess.file_exists(full_path) and not DirAccess.dir_exists_absolute(full_path):
		return "Error: File or directory not found - %s" % full_path
	
	var info = []
	info.append("File: %s" % full_path)
	
	if FileAccess.file_exists(full_path):
		var file = FileAccess.open(full_path, FileAccess.READ)
		if file:
			var size = file.get_length()
			file.close()
			info.append("Type: File")
			info.append("Size: %d bytes" % size)
			info.append("Extension: %s" % file_name.get_extension())
	elif DirAccess.dir_exists_absolute(full_path):
		info.append("Type: Directory")
		var dir = DirAccess.open(full_path)
		if dir:
			var count = 0
			dir.list_dir_begin()
			var file_name_in_dir = dir.get_next()
			while file_name_in_dir != "":
				if not file_name_in_dir.begins_with("."):
					count += 1
				file_name_in_dir = dir.get_next()
			dir.list_dir_end()
			info.append("Items: %d" % count)
	
	return "\n".join(info)

func _head(args: Array, input: String = "", is_pipe_context: bool = false) -> String:
	var lines_to_show = 10
	var content = ""
	

	if not input.is_empty():
		content = input
		if args.size() > 0:
			lines_to_show = args[0].to_int()
	elif args.size() > 0:
		if args[0].is_valid_int():
			lines_to_show = args[0].to_int()
			if args.size() > 1:
				var file_name = args[1]
				var full_path = current_directory.path_join(file_name)
				if FileAccess.file_exists(full_path):
					var file = FileAccess.open(full_path, FileAccess.READ)
					if file:
						content = file.get_as_text()
						file.close()
				else:
					return "Error: File not found - %s" % full_path
			else:
				return "Usage: head [lines] [filename] or use with pipe"
		else:
			var file_name = args[0]
			var full_path = current_directory.path_join(file_name)
			if FileAccess.file_exists(full_path):
				var file = FileAccess.open(full_path, FileAccess.READ)
				if file:
					content = file.get_as_text()
					file.close()
			else:
				return "Error: File not found - %s" % full_path
	else:
		return "Usage: head [lines] [filename] or use with pipe"
	
	if content.is_empty():
		return "No content to process"
	
	var lines = content.split("\n")
	var result_lines = lines.slice(0, min(lines_to_show, lines.size()))
	return "\n".join(result_lines)

func _tail(args: Array, input: String = "", is_pipe_context: bool = false) -> String:
	var lines_to_show = 10
	var content = ""
	
	if not input.is_empty():
		content = input
		if args.size() > 0:
			lines_to_show = args[0].to_int()
	elif args.size() > 0:
		if args[0].is_valid_int():
			lines_to_show = args[0].to_int()
			if args.size() > 1:
				var file_name = args[1]
				var full_path = current_directory.path_join(file_name)
				if FileAccess.file_exists(full_path):
					var file = FileAccess.open(full_path, FileAccess.READ)
					if file:
						content = file.get_as_text()
						file.close()
				else:
					return "Error: File not found - %s" % full_path
			else:
				return "Usage: tail [lines] [filename] or use with pipe"
		else:
			# First argument is filename
			var file_name = args[0]
			var full_path = current_directory.path_join(file_name)
			if FileAccess.file_exists(full_path):
				var file = FileAccess.open(full_path, FileAccess.READ)
				if file:
					content = file.get_as_text()
					file.close()
			else:
				return "Error: File not found - %s" % full_path
	else:
		return "Usage: tail [lines] [filename] or use with pipe"
	
	if content.is_empty():
		return "No content to process"
	
	var lines = content.split("\n")
	var start_index = max(0, lines.size() - lines_to_show)
	var result_lines = lines.slice(start_index)
	return "\n".join(result_lines)

#endregion

#region Editor project commands
func _save_scene(args: Array) -> String:
	if not Engine.is_editor_hint():
		return "Not in editor"
	
	EditorInterface.save_all_scenes()
	return "All scenes saved successfully"


func _run_project(args: Array) -> String:
	if not Engine.is_editor_hint():
		return "Not in editor"
	
	var scene_path = ""
	if args.size() > 0:
		scene_path = args[0]
		if not scene_path.ends_with(".tscn"):
			scene_path += ".tscn"
		if not scene_path.begins_with("res://"):
			scene_path = "res://" + scene_path
	
	if scene_path.is_empty():
		EditorInterface.play_main_scene()
		return "Running main scene"
	else:
		EditorInterface.play_custom_scene(scene_path)
		return "Running scene: %s" % scene_path

func _stop_project(args: Array) -> String:
	if not Engine.is_editor_hint():
		return "Not in editor"
	
	EditorInterface.stop_playing_scene()
	return "Project stopped"

#endregion

#region History commands
func _show_history(args: Array) -> String:
	var history = CommandRegistry.get_command_history()
	if history.is_empty():
		return "Command history is empty"
	
	var result = "Command history:\n"
	for i in range(history.size()):
		result += "%d: %s\n" % [i + 1, history[i]]
	
	return result

func _clear_history(args: Array) -> String:
	CommandRegistry.clear_command_history()
	return "History cleared"
#endregion

#region Testing commands
func _run_tests(args: Array) -> String:
	var test_framework = TestFramework.new()
	test_framework.run_all_tests()
	
	register_editor_commands()
	
	return "Comprehensive test suite completed! Check console for detailed results."

func _test_commands(args: Array) -> String:
	var test_framework = TestFramework.new()
	test_framework.run_command_registry_tests()
	
	register_editor_commands()
	
	return "Command registry tests completed! Check console for results."

func _test_autocomplete(args: Array) -> String:
	var test_framework = TestFramework.new()
	test_framework.run_autocomplete_tests()
	
	register_editor_commands()
	
	return "Autocomplete tests completed. Console reset. Check console for results."

func _test_file_operations(args: Array) -> String:
	var test_framework = TestFramework.new()
	test_framework.run_file_operation_tests()
	
	register_editor_commands()
	
	return "File operation tests completed! Check console for results."

func _test_pipes(args: Array) -> String:
	var test_framework = TestFramework.new()
	test_framework.run_piping_tests()
	
	# Re-register commands after test
	register_editor_commands()
	
	return "Piping tests completed. Check console for results."

func _quick_test(args: Array) -> String:
	var test_framework = TestFramework.new()
	test_framework.run_command_registry_tests()
	test_framework.run_builtin_commands_tests()
	return "Quick test completed - Command registry and built-in commands tested"
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


#endregion

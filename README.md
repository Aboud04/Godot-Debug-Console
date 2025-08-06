# Debug Console for Godot

A powerful, feature-rich debug console addon for Godot 4.x that provides an integrated terminal-like experience within the Godot editor.

## Features

### **Core Functionality**
- **Integrated Console** - Bottom panel integration like Output/Debugger
- **Command System** - Extensible command registry with help system
- **Autocomplete** - Smart autocomplete for commands, files, and node types
- **File Operations** - Create, edit, and manage files directly from console

### **User Experience**
- **Bottom Panel** - Native Godot panel integration

### **File Management**
- **File Creation** - `touch`, `new_script`, `new_scene`, `new_resource`
- **Directory Operations** - `mkdir`, `cd`, `pwd`, `ls`
- **File Manipulation** - `cp`, `mv`, `rm`
- **Auto Refresh** - FileSystem dock updates automatically

## Installation

1. **Download** the addon files
2. **Copy** the `addons/debug_console` folder to your Godot project's `addons/` directory
3. **Enable** the addon in Project Settings → Plugins
4. **Restart** the Godot editor

## Usage

### Basic Commands

```bash
# File operations
ls                    # List files in current directory
cd <directory>        # Change directory
pwd                   # Show current directory
mkdir <name>          # Create directory
touch <filename>      # Create file

# Script and scene creation
new_script <name> [extends_type] [class_name]
new_scene <name> [root_type]
new_resource <name> [resource_type]

# File manipulation
cp <source> <dest>    # Copy file
mv <source> <dest>    # Move/rename file
rm <filename>         # Delete file

# Console management
clear                 # Clear console output
help                  # Show available commands
history               # Show command history

# Testing
test                  # Run all tests
test_commands         # Test command system
test_autocomplete     # Test autocomplete
test_files            # Test file operations
```


### Keyboard Shortcuts

- **``Ctrl + ` ``** - Toggle console visibility
- **`Enter`** - Execute command
- **`Tab`** - Autocomplete
- **`Up/Down`** - Navigate command history

## Architecture

### Core Components

```
addons/debug_console/
├── core/
│   ├── CommandRegistry.gd    # Command registration and execution
│   ├── BuiltInCommands.gd    # Built-in command implementations
│   └── DebugCore.gd          # Core logging and initialization
├── editor/
│   ├── EditorConsole.gd      # Editor console UI and logic
│   └── EditorConsole.tscn    
├── game/
│   ├── GameConsole.gd        # Runtime console UI
│   ├── GameConsole.tscn     
│   └── GameConsoleManager.gd # Runtime console management
├── tests/
│   └── TestFramework.gd      # test cases
└── plugin.gd                 
```


## Development

### Adding New Commands

```gdscript
# Register a new command
CommandRegistry.register_command(
    "my_command",           # Command name
    _my_command_function,    # Function to call
    "Description",          # Help text
    "editor"               # Context (editor/game/both)
)

# Implement the command function
func _my_command_function(args: Array) -> String:
    return "Command executed successfully"
```

### Running Tests

```bash
# Run all tests
test

# Run specific test cases
test_commands
test_autocomplete
test_files
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for detailed contribution guidelines.

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Support

- **Issues** - Report bugs and feature requests on GitHub
- **Discussions** - Ask questions and share ideas
- **Documentation** - Check the code comments for implementation details

## Changelog

### v1.0.0

- Initial release



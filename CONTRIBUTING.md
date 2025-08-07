# Contributing to Debug Console

Thank you for your interest in contributing to the Debug Console addon! This document provides guidelines for contributing code, reporting bugs, and suggesting features.

## Table of Contents

- [Getting Started](#getting-started)
- [Development Setup](#development-setup)
- [Code Style Guidelines](#code-style-guidelines)
- [Testing Requirements](#testing-requirements)
- [Pull Request Guidelines](#pull-request-guidelines)
- [Bug Reports](#bug-reports)
- [Feature Requests](#feature-requests)
- [Code Review Process](#code-review-process)
- [Getting Help](#getting-help)

## Getting Started

### Prerequisites
- **Godot 4.x** - Latest stable version (4.2+ recommended)
- **Git** - For version control
- **Basic GDScript knowledge** - Understanding of Godot's scripting language
- **Familiarity with Godot plugins** - Understanding of addon development

### Quick Start
1. **Fork** the repository on GitHub
2. **Clone** your fork locally: `git clone https://github.com/your-username/debug-console.git`
3. **Create** a feature branch: `git checkout -b feature/your-feature-name`
4. **Make changes** and test thoroughly
5. **Commit** with descriptive messages
6. **Push** to your fork
7. **Create** a pull request

## Development Setup

### Local Development Environment
1. **Open** the project in Godot 4.x
2. **Enable** the Debug Console plugin in Project Settings → Plugins
3. **Test** the existing functionality: Open console and run `test`
4. **Verify** all tests pass (100% success rate expected)

### Project Structure
```
addons/debug_console/
├── core/           # Core functionality (commands, registry)
│   ├── CommandRegistry.gd    # Command registration and execution
│   ├── BuiltInCommands.gd    # Built-in command implementations
│   └── DebugCore.gd          # Core logging and initialization
├── editor/         # Editor-specific components
│   ├── EditorConsole.gd      # Editor console UI and logic
│   └── EditorConsole.tscn    # Editor console scene
├── game/           # Runtime components
│   ├── GameConsole.gd        # Runtime console UI
│   ├── GameConsole.tscn      # Game console scene
│   └── GameConsoleManager.gd # Runtime console management
├── tests/          # Test framework and test cases
│   └── TestFramework.gd      # Comprehensive test suite
├── icons/          # Plugin icons
│   └── console_icon.svg      # Console icon
└── plugin.gd       # Main plugin entry point
```

## Code Style Guidelines

### GDScript Conventions
- **Indentation** - Use tabs, not spaces
- **Naming** - Use snake_case for variables and functions
- **Comments** - Add comments for complex logic and public APIs
- **Documentation** - Update README.md for new features
- **Line length** - Keep lines under 100 characters when possible

### Code Organization
- **Single responsibility** - Each function should do one thing well
- **Error handling** - Always handle potential errors gracefully
- **Context awareness** - Use `Engine.is_editor_hint()` for editor/game context
- **Memory management** - Properly free resources and avoid memory leaks

### Example Code Style
```gdscript
# Good example
func _process_file_content(content: String) -> String:
	if content.is_empty():
		return "Error: Empty content"
	
	var processed_lines = []
	for line in content.split("\n"):
		if not line.strip_edges().is_empty():
			processed_lines.append(line.strip_edges())
	
	return "\n".join(processed_lines)

# Bad example
func processFile(content):
	var lines=[]
	for line in content.split("\n"):
		if line.strip_edges()!="":
			lines.append(line.strip_edges())
	return "\n".join(lines)
```

## Testing Requirements

### Mandatory Testing
**All contributions must include comprehensive test cases.** The testing framework is located in `addons/debug_console/tests/TestFramework.gd`.

### Test Categories

#### 1. Command Testing
When adding new commands, include tests for:
- **Registration** - Command is properly registered
- **Execution** - Command executes with correct arguments
- **Error handling** - Invalid arguments are handled gracefully
- **Help system** - Help text is accurate
- **Context awareness** - Works in correct context (editor/game/both)

```gdscript
# Example test for a new command
test("New Command - Registration", func():
	CommandRegistry.register_command("test_cmd", _test_func, "Test", "both")
	return CommandRegistry._commands.has("test_cmd")
)

test("New Command - Execution", func():
	CommandRegistry.register_command("test_cmd", _test_func, "Test", "both")
	var result = CommandRegistry.execute_command("test_cmd arg1 arg2")
	return result == "expected_result"
)

test("New Command - Error Handling", func():
	CommandRegistry.register_command("test_cmd", _test_func, "Test", "both")
	var result = CommandRegistry.execute_command("test_cmd invalid_arg")
	return result.contains("Error") or result.contains("Usage")
)
```

#### 2. Autocomplete Testing
For autocomplete features, test:
- **Command suggestions** - Correct commands are suggested
- **File suggestions** - File system integration works
- **Node type suggestions** - Node types are properly filtered
- **Mode detection** - Context is correctly determined

```gdscript
# Example autocomplete test
test("Autocomplete - New Feature", func():
	var console = EditorConsole.new()
	var suggestions = console._get_command_suggestions("t")
	return suggestions.has("test_cmd")
)
```

#### 3. File Operation Testing
For file operations, test:
- **Creation** - Files/directories are created successfully
- **Cleanup** - Test artifacts are properly removed
- **Error handling** - Invalid operations are handled
- **File system integration** - Godot's file system is updated

```gdscript
# Example file operation test
test("File Operations - New Feature", func():
	var commands = BuiltInCommands.new()
	var result = commands._new_feature(["test_file"])
	var success = result.contains("Created")
	
	# Cleanup
	if FileAccess.file_exists("res://test_file"):
		DirAccess.open("res://").remove("test_file")
	
	return success
)
```

#### 4. Integration Testing
Test complete workflows:
- **End-to-end** - Full command execution flow
- **Component interaction** - Different parts work together
- **Error recovery** - System handles failures gracefully

```gdscript
# Example integration test
test("Integration - New Feature", func():
	var commands = BuiltInCommands.new()
	commands.register_editor_commands()
	
	var result = CommandRegistry.execute_command("new_feature")
	return result.contains("success")
)
```

### Running Tests

#### Before Submitting
1. **Run all tests**: `test` (must achieve 100% pass rate)
2. **Run specific tests**: `test_commands`, `test_autocomplete`, `test_files`
3. **Verify no regressions** - Existing functionality still works
4. **Test in both contexts** - Editor and game mode

#### Test Framework Usage
```gdscript
# Add tests to TestFramework.gd
func run_new_feature_tests():
	print("\nTesting New Feature...")
	
	test("New Feature - Basic Functionality", func():
		# Your test logic here
		return true
	)
	
	test("New Feature - Error Handling", func():
		# Test error cases
		return true
	)
```

### Test Quality Standards

#### Coverage Requirements
- **100% function coverage** - Every new function must be tested
- **Edge case testing** - Test boundary conditions and error cases
- **Integration testing** - Test how new features work with existing code
- **Context testing** - Test in both editor and game contexts

#### Test Naming
- **Descriptive names** - Clearly indicate what is being tested
- **Category prefixes** - Use prefixes like "Command", "Autocomplete", "File"
- **Specific scenarios** - Include the specific scenario being tested

#### Test Structure
```gdscript
test("Category - Specific Test Name", func():
	# Setup
	var test_object = create_test_object()
	
	# Execute
	var result = test_object.test_function()
	
	# Cleanup
	cleanup_test_artifacts()
	
	# Assert
	return result == expected_value
)
```

## Pull Request Guidelines

### Before Submitting
1. **Test thoroughly** - Run all tests and ensure 100% pass rate
2. **Update documentation** - Modify README.md for new features
3. **Check code style** - Follow GDScript conventions
4. **Self-review** - Review your own code before submitting

### Pull Request Template
```markdown
## Description
Brief description of the changes and why they are needed.

## Type of Change
- [ ] Bug fix (non-breaking change which fixes an issue)
- [ ] New feature (non-breaking change which adds functionality)
- [ ] Breaking change (fix or feature that would cause existing functionality to not work as expected)
- [ ] Documentation update

## Testing
- [ ] All tests pass (100% success rate)
- [ ] New tests added for new functionality
- [ ] Existing functionality still works
- [ ] Manual testing completed in both editor and game contexts

## Checklist
- [ ] Code follows style guidelines
- [ ] Self-review completed
- [ ] Documentation updated
- [ ] Tests added and passing
- [ ] No breaking changes (or breaking changes are documented)
```

### Commit Message Guidelines
Follow conventional commit format:
```
type(scope): description

[optional body]

[optional footer]
```

Examples:
```
feat(commands): add new file search command
fix(autocomplete): resolve file suggestion bug
docs(readme): update installation instructions
test(framework): add comprehensive test coverage
```

## Bug Reports

### Before Reporting
1. **Check existing issues** - Search for similar problems
2. **Test in isolation** - Reproduce in a minimal project
3. **Check Godot version** - Ensure you're using a supported version
4. **Run tests** - Verify if the issue affects the test suite

### Bug Report Template
```markdown
## Bug Description
Clear description of the issue and expected behavior.

## Steps to Reproduce
1. Step one
2. Step two
3. Step three

## Expected Behavior
What should happen

## Actual Behavior
What actually happens

## Environment
- Godot Version: [e.g., 4.2.1]
- OS: [e.g., Windows 11, macOS 13, Ubuntu 22.04]
- Debug Console Version: [e.g., 1.0.0]
- Plugin Status: [Enabled/Disabled]

## Additional Information
- Screenshots (if applicable)
- Console output/error messages
- Minimal reproduction project (if needed)
```

## Feature Requests

### Before Requesting
1. **Check existing features** - Ensure it's not already implemented
2. **Consider scope** - Is it within the addon's purpose?
3. **Think about testing** - How would it be tested?
4. **Check roadmap** - Is it planned for future releases?

### Feature Request Template
```markdown
## Feature Description
Clear description of the requested feature

## Use Case
Why this feature would be useful and how it would improve the workflow

## Proposed Implementation
How you think it could be implemented (optional)

## Testing Considerations
How this feature could be tested

## Impact
- [ ] Low impact (nice to have)
- [ ] Medium impact (improves workflow)
- [ ] High impact (essential functionality)
```

## Code Review Process

### Review Criteria
- **Functionality** - Does the code work as intended?
- **Testing** - Are there comprehensive tests?
- **Style** - Does it follow coding conventions?
- **Documentation** - Is it properly documented?
- **Performance** - Is it efficient and scalable?
- **Security** - Are there any security concerns?

### Review Process
1. **Automated checks** - Tests must pass
2. **Code review** - At least one maintainer reviews
3. **Testing verification** - Manual testing may be required
4. **Documentation review** - Ensure docs are updated

### Review Checklist
- [ ] Code follows style guidelines
- [ ] Tests are comprehensive and pass
- [ ] Documentation is updated
- [ ] No breaking changes (or properly documented)
- [ ] Performance impact is acceptable
- [ ] Error handling is appropriate

## Getting Help

### Questions and Support
- **GitHub Issues** - For bug reports and feature requests
- **GitHub Discussions** - For questions and general discussion
- **Code comments** - Check existing code for examples

### Development Resources
- **Godot Documentation** - [docs.godotengine.org](https://docs.godotengine.org)
- **GDScript Reference** - [docs.godotengine.org/en/stable/tutorials/scripting/gdscript](https://docs.godotengine.org/en/stable/tutorials/scripting/gdscript)
- **Plugin Development** - [docs.godotengine.org/en/stable/tutorials/plugins/editor](https://docs.godotengine.org/en/stable/tutorials/plugins/editor)
- **Testing Guide** - [addons/debug_console/tests/README.md](addons/debug_console/tests/README.md)

### Community Channels
- **Godot Discord** - #plugins channel
- **Godot Forums** - Plugin development section
- **Reddit** - r/godot for general discussions

## Recognition

Contributors will be recognized in:
- **README.md** - Contributors section
- **Release notes** - For significant contributions
- **GitHub contributors** - Automatic recognition

## Code of Conduct

This project follows the [Godot Code of Conduct](https://godotengine.org/code-of-conduct). Please be respectful and inclusive in all interactions.

---

Thank you for contributing to the Debug Console addon! Your contributions help make Godot development better for everyone.

—The Debug Console development team 

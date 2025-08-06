# Contributing to Debug Console

Thank you for your interest in contributing to the Debug Console addon! This document provides guidelines for contributing code, reporting bugs, and suggesting features.

## Development Setup

### Prerequisites
- **Godot 4.x** - Latest stable version
- **Git** - For version control
- **Basic GDScript knowledge** - Understanding of Godot's scripting language

### Local Development
1. **Fork** the repository
2. **Clone** your fork locally
3. **Create** a feature branch: `git checkout -b feature/your-feature-name`
4. **Make changes** and test thoroughly
5. **Commit** with descriptive messages
6. **Push** to your fork
7. **Create** a pull request

## Code Style Guidelines

### GDScript Conventions
- **Indentation** - Use tabs, not spaces
- **Naming** - Use snake_case for variables and functions
- **Comments** - Add comments for complex logic
- **Documentation** - Update README.md for new features

### File Organization
```
addons/debug_console/
├── core/           # Core functionality (commands, registry)
├── editor/         # Editor-specific components
├── game/           # Runtime components
├── tests/          # Test framework and test cases
└── plugin.gd       # Main plugin entry point
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
    console._get_command_suggestions("t")
    return console._matching_commands.has("test_cmd")
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
1. **Run all tests**: `test`
2. **Run specific tests**: `test_commands`, `test_autocomplete`, `test_files`
3. **Verify 100% pass rate** - All tests must pass
4. **Check for regressions** - Existing functionality still works

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


### Pull Request Template
```markdown
## Description
Brief description of the changes

## Type of Change
- [ ] Bug fix
- [ ] New feature
- [ ] Breaking change
- [ ] Documentation update

## Testing
- [ ] All tests pass (100% success rate)
- [ ] New tests added for new functionality
- [ ] Existing functionality still works
- [ ] Manual testing completed

## Checklist
- [ ] Code follows style guidelines
- [ ] Self-review completed
- [ ] Documentation updated
- [ ] Tests added and passing
```

## Bug Reports

### Before Reporting
1. **Check existing issues** - Search for similar problems
2. **Test in isolation** - Reproduce in a minimal project
3. **Check Godot version** - Ensure you're using a supported version

### Bug Report Template
```markdown
## Bug Description
Clear description of the issue

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
- OS: [e.g., Windows 11]
- Debug Console Version: [e.g., 1.0.0]

## Additional Information
Screenshots, logs, or other relevant information
```

## Feature Requests

### Before Requesting
1. **Check existing features** - Ensure it's not already implemented
2. **Consider scope** - Is it within the addon's purpose?
3. **Think about testing** - How would it be tested?

### Feature Request Template
```markdown
## Feature Description
Clear description of the requested feature

## Use Case
Why this feature would be useful

## Proposed Implementation
How you think it could be implemented

## Testing Considerations
How this feature could be tested
```

## Code Review Process

### Review Criteria
- **Functionality** - Does the code work as intended?
- **Testing** - Are there comprehensive tests?
- **Style** - Does it follow coding conventions?
- **Documentation** - Is it properly documented?
- **Performance** - Is it efficient and scalable?

### Review Process
1. **Automated checks** - Tests must pass
2. **Code review** - At least one maintainer reviews
3. **Testing verification** - Manual testing may be required
4. **Documentation review** - Ensure docs are updated

## Getting Help

### Questions and Support
- **GitHub Issues** - For bug reports and feature requests
- **GitHub Discussions** - For questions and general discussion
- **Code comments** - Check existing code for examples

### Development Resources
- **Godot Documentation** - [docs.godotengine.org](https://docs.godotengine.org)
- **GDScript Reference** - [docs.godotengine.org/en/stable/tutorials/scripting/gdscript](https://docs.godotengine.org/en/stable/tutorials/scripting/gdscript)
- **Plugin Development** - [docs.godotengine.org/en/stable/tutorials/plugins/editor](https://docs.godotengine.org/en/stable/tutorials/plugins/editor)

## Recognition

Contributors will be recognized in:
- **README.md** - Contributors section
- **Release notes** - For significant contributions
- **GitHub contributors** - automatic

Thank you for contributing to the Debug Console addon! 

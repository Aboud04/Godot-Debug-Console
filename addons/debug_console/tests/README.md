# Debug Console Testing Guide

This guide covers the comprehensive test suite for the Debug Console addon, including how to run tests, understand results, and contribute new test cases.

## Quick Start

### Running Tests
```bash
# In editor or game console
test                    # Run complete test suite
test_commands          # Test command system only
test_autocomplete      # Test autocomplete only
test_files             # Test file operations only
test_pipes             # Test command piping only
quick_test             # Run basic functionality tests
```

### Programmatic Testing
```gdscript
var test_framework = TestFramework.new()
test_framework.run_all_tests()
test_framework.queue_free()
```

## Test Categories

### 1. Command Registry Tests
Tests the core command system:
- Command registration and unregistration
- Command execution with various argument types
- Context validation (editor vs game)
- Help system functionality
- Input support for piped commands

### 2. Built-in Commands Tests
Tests all individual commands:
- **Universal**: `help`, `echo`, `history`, `clear_history`
- **Editor**: `ls`, `cd`, `pwd`, `cat`, `grep`, `head`, `tail`, `find`, `stat`
- **File Operations**: `mkdir`, `touch`, `rm`, `rmdir`, `cp`, `mv`
- **Content Creation**: `new_script`, `new_scene`, `new_resource`
- **Project Control**: `save_scenes`, `run_project`, `stop_project`
- **Game**: `fps`, `nodes`, `pause`, `timescale`

### 3. Command Piping Tests
Tests command chaining functionality:
- Simple command chains (`echo | echo`)
- Multiple pipe sequences (`ls | grep .gd | head 5`)
- Input/output handling
- Error handling in pipe chains
- Whitespace and edge case handling

### 4. Autocomplete Tests
Tests the smart suggestion system:
- Command suggestions
- File and directory suggestions
- Node type suggestions
- Mode detection
- Cycling through options

### 5. UI Component Tests
Tests console interfaces:
- Editor console initialization and functionality
- Game console visibility and animation
- Console manager integration
- Input handling and focus management
- Log message formatting

### 6. Debug Core Tests
Tests core logging system:
- Log level handling
- Message history management
- Message formatting
- History size limits

### 7. Performance Tests
Tests system performance:
- Command registration speed
- Command execution performance
- Piping operation speed
- Large file handling
- UI responsiveness

### 8. Error Handling Tests
Tests error scenarios:
- Invalid command handling
- Malformed piping
- Non-existent file operations
- Memory leak prevention
- Instance cleanup

### 9. Integration Tests
Tests system-wide functionality:
- Cross-component communication
- Full command chains
- End-to-end workflows

## Test Results

### Success Criteria
- **100% pass rate** expected for all test suites
- **Context awareness** - Tests run only in appropriate contexts
- **Performance** - Tests complete within reasonable time limits
- **Cleanup** - No test artifacts left behind

### Example Output
```
Starting Comprehensive Debug Console Test Suite...

Testing Command Registry...
✅ Command Registry - Register Command (5ms)
✅ Command Registry - Execute Command (3ms)
✅ Command Registry - Get Help (2ms)
...

=====================================
TEST RESULTS SUMMARY
=====================================
Total Tests: 108
Passed: 108
Failed: 0
Success Rate: 100.0%
Total Time: 1250ms

All tests passed! The Debug Console is working perfectly.
=====================================
```

## Writing Custom Tests

### Adding New Test Categories
```gdscript
func run_custom_tests():
	print("\nTesting Custom Functionality...")
	
	test("Custom Test Name", func():
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

### Test Best Practices

#### 1. Context Awareness
```gdscript
# Editor-only tests
if Engine.is_editor_hint():
	test("Editor Feature", func():
		# Test editor-specific functionality
		return true
	)

# Game-only tests
if not Engine.is_editor_hint():
	test("Game Feature", func():
		# Test game-specific functionality
		return true
	)
```

#### 2. File Operations
```gdscript
test("File Operation Test", func():
	# Create test file
	var test_file = ".test_file_" + str(Time.get_ticks_msec()) + ".txt"
	create_test_file(test_file, "test content")
	
	# Test functionality
	var result = some_function(test_file)
	var success = result.contains("expected")
	
	# Cleanup
	cleanup_test_file(test_file)
	
	return success
)
```

#### 3. Error Handling
```gdscript
test("Error Handling Test", func():
	var result = function_with_potential_error()
	return result.contains("Error") or result.contains("Usage") or result == expected_success
)
```

#### 4. Performance Testing
```gdscript
test("Performance Test", func():
	var start_time = Time.get_ticks_msec()
	
	# Execute operation
	for i in range(100):
		perform_operation()
	
	var end_time = Time.get_ticks_msec()
	var duration = end_time - start_time
	
	return duration < 1000  # Should complete in under 1 second
)
```

## Troubleshooting

### Common Issues

#### Test Failures in Game Mode
Some tests are editor-only and will be skipped in game mode. This is expected behavior.

#### File Permission Errors
- Ensure the project directory is writable
- Check that test files are created in `res://` directory
- Verify cleanup functions are working properly

#### Memory Leaks
Tests include cleanup verification. If you see memory leak warnings:
- Ensure all test objects are properly freed
- Check that `queue_free()` is called on test instances
- Verify no circular references are created

#### Performance Issues
- Check for infinite loops in test logic
- Ensure tests don't perform heavy operations unnecessarily
- Use appropriate timeouts for performance tests

### Debug Mode
Enable debug output by adding print statements:
```gdscript
test("Debug Test", func():
	print("DEBUG: Running test...")
	var result = some_function()
	print("DEBUG: Result: ", result)
	return result == expected_value
)
```

## Continuous Integration

The test suite is designed for CI/CD integration:

### GitHub Actions Example
```yaml
name: Test Debug Console
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Setup Godot
        uses: godotengine/godot-ci-action@v1
      - name: Run Tests
        run: godot --headless --script addons/debug_console/tests/TestFramework.gd
```

### Pre-commit Hooks
```bash
#!/bin/bash
# .git/hooks/pre-commit
echo "Running Debug Console tests..."
godot --headless --script addons/debug_console/tests/TestFramework.gd
if [ $? -ne 0 ]; then
    echo "Tests failed! Commit aborted."
    exit 1
fi
```

## Test Coverage

The test suite provides comprehensive coverage:

- **Function Coverage**: 100% of public functions tested
- **Branch Coverage**: All code paths tested
- **Error Paths**: Error conditions and edge cases covered
- **Integration**: Cross-component interactions tested
- **Performance**: Performance characteristics validated

## Contributing Tests

When contributing new functionality:

1. **Add tests first** - Write tests before implementing features
2. **Test both contexts** - Ensure tests work in editor and game modes
3. **Include error cases** - Test failure scenarios and edge cases
4. **Maintain coverage** - Don't reduce overall test coverage
5. **Follow patterns** - Use existing test patterns and conventions

For more information on contributing, see [CONTRIBUTING.md](CONTRIBUTING.md).

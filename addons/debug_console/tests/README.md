# Debug Console Testing Guide

This guide covers the comprehensive test suite for the Debug Console addon, including how to run tests, understand results, and contribute new test cases.

## Quick Start

### Running Tests
```bash
# In editor or game console
test                    # Run complete test suite (247 tests as of v1.2.0)
test_commands          # Test command system only
test_autocomplete      # Test autocomplete only
test_files             # Test file operations only
test_pipes             # Test command piping only
quick_test             # Run basic functionality tests
```

### File-Based Runner (canonical for CI / headless verification)

The repo ships a non-interactive test pipeline at the project root:

| File | Purpose |
|---|---|
| `res://.dc_test_runner.tscn` | Headless scene - load it as the main scene (or `godot --headless res://.dc_test_runner.tscn`) and it auto-runs `TestFramework.gd` |
| `res://.dc_test_runner.gd` | Runner script that drives the suite and writes results to disk |
| `res://.dc_test_results.json` | JSON output of the most recent run: `{"passed": N, "total": M, "ok": bool, ...}` |

This is the **canonical pipeline** for verifying the suite - the MCP `get_console_log` route is unreliable across multiple runs, so prefer reading `.dc_test_results.json` in any automation. **Do not modify `.dc_test_runner.tscn` or `.dc_test_runner.gd` unless your task is specifically about the test pipeline.**

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
- **Universal**: `help`, `echo`, `history`, `clear_history`, `clear`, `alias`/`unalias`, `test`, `inspect`, `get`/`set`, `watch`, `signals`, `properties`, `scene_tree`, `save_log`, `benchmark`, `config`, `json`
- **Editor file ops**: `ls`, `cd`, `pwd`, `cat`, `grep`, `head`, `tail`, `find`, `stat`, `tree`, `wc`, `diff`
- **File mutations**: `mkdir`, `touch`, `rm`, `rmdir`, `cp`, `mv`
- **Content creation**: `new_script`, `new_scene`, `new_resource`, `open`, `node_types`
- **Project control**: `save_scenes`, `run_project`, `stop_project`, `refresh`, `reload`, `reload_scripts`, `scene`
- **Game**: `fps`, `nodes`, `pause`, `timescale`, `opacity`, `intercept`
- **Regression coverage**: dedicated `Regression - B1`/`B2`/`B3`/`B4` cases (cwd-clamp, Esc close, BBCode + autoload focus, new_scene UID collision)

### 3. Persistence Tests (Tier 3 + Wave 1)
Tests history and cwd persistence to `user://`:
- History cap at 500, consecutive-duplicate dedup
- Per-project cwd isolation (different projects keep independent state)
- Graceful recovery on corrupted JSON (PersistenceManager logs `Parse JSON failed` as a SUCCESS signal - see Troubleshooting)
- Survives editor restarts and plugin enable/disable cycles

### 4. Plugin Author API Tests (Tier 4)
Tests the public `/root/DebugConsole` surface:
- `register_command()`, `register_console_command()`, `unregister_command()` round-trips
- `ConsoleCommand` resource declarative path (note: `callable_target` is NOT `@export`ed because Godot refuses to serialize Object/Node refs on Resource - it must be assigned in code after the resource is loaded)
- Signal emission: `command_registered`, `command_unregistered`, `command_executed`, `console_opened`, `console_closed`
- Backward-compatibility surface - methods may grow params (with defaults) but never reduce or reshape (REQ-6.2)

### 5. Command Piping Tests
Tests command chaining functionality:
- Simple command chains (`echo | echo`)
- Multiple pipe sequences (`ls | grep .gd | head 5`)
- Input/output handling
- Error handling in pipe chains
- Whitespace and edge case handling

### 6. Autocomplete Tests
Tests the smart suggestion system:
- Command suggestions
- File and directory suggestions
- Node type suggestions
- Mode detection
- Cycling through options

### 7. UI Component Tests
Tests console interfaces:
- Editor console initialization and functionality
- Game console visibility and animation
- Console manager integration
- Input handling and focus management
- Log message formatting

### 8. Debug Core Tests
Tests core logging system:
- Log level handling
- Message history management
- Message formatting
- History size limits

### 9. Performance Tests
Tests system performance:
- Command registration speed
- Command execution performance
- Piping operation speed
- Large file handling
- UI responsiveness

### 10. Error Handling Tests
Tests error scenarios:
- Invalid command handling
- Malformed piping
- Non-existent file operations
- Memory leak prevention
- Instance cleanup

### 11. Integration Tests
Tests system-wide functionality:
- Cross-component communication
- Full command chains
- End-to-end workflows

## Test Results

### Success Criteria
- **100% pass rate** expected for all test suites (currently **247/247** as of v1.2.0)
- **Context awareness** - tests run only in appropriate contexts
- **Performance** - tests complete within reasonable time limits
- **Cleanup** - no test artifacts left behind
- **No auto-PASS heuristics** - the test framework's `_execute_test_safely` no longer accepts non-bool returns as success; tests must explicitly return `bool` (REQ-6.5)

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
Total Tests: 247
Passed: 247
Failed: 0
Success Rate: 100.0%
Total Time: 1850ms

All 247 tests passed! The Debug Console is working perfectly.
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

#### Harmless Warnings During a Successful Run
Two warnings appear in the editor Output panel during a green run. **Both are intentional and indicate tests are working correctly:**

| Warning | Source | Why it's harmless |
|---|---|---|
| `PersistenceManager.gd:37 Parse JSON failed` | Persistence Tests - corrupted-file recovery case | The test deliberately writes garbage to `user://debug_console_history.json` to verify graceful recovery. The warning IS the success signal - if it disappears, the recovery test isn't actually exercising the bad path |
| `GameConsole.gd:183 Nodes with non-equal opposite anchors` | UI Component Tests - resize-clamp case | Benign Godot 4.x warning that fires while the console panel is being resized below its natural minimum size during clamp testing. Cosmetic only |

If you see OTHER warnings or errors in the Output during a `test` run, treat them as real and investigate.

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

The test suite is designed for CI/CD integration via the file-based runner.

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
      - name: Run Tests (file-based runner)
        run: |
          godot --headless --path . res://.dc_test_runner.tscn
          # Runner writes results to res://.dc_test_results.json
      - name: Check results
        run: |
          jq -e '.ok == true and .passed == .total' .dc_test_results.json
```

### Pre-commit Hooks
```bash
#!/bin/bash
# .git/hooks/pre-commit
echo "Running Debug Console tests..."
godot --headless --path . res://.dc_test_runner.tscn
if ! jq -e '.ok == true' .dc_test_results.json > /dev/null; then
    echo "Tests failed! Commit aborted."
    cat .dc_test_results.json
    exit 1
fi
```

> **Note:** The MCP `get_console_log` route is unreliable across multiple runs. Always read `.dc_test_results.json` in CI/automation; treat the console transcript as informational only.

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

@tool
class_name ConsoleCommand extends Resource
## Declarative command definition for the Debug Console plugin API.
##
## Use this Resource when you want to define console commands declaratively
## (for example, inside an exported `Array[ConsoleCommand]` on your plugin's
## main script) instead of imperatively calling
## `DebugConsole.register_command(...)` for each command.
##
## Typical usage from a plugin author:
## [codeblock]
## # In your_plugin.gd (an EditorPlugin)
## var ConsoleCommandScript := load("res://addons/debug_console/core/ConsoleCommand.gd")
##
## func _enter_tree() -> void:
##     var debug_console: Node = get_node_or_null("/root/DebugConsole")
##     if not debug_console:
##         return
##     var cmd: Resource = ConsoleCommandScript.new()
##     cmd.command_name = "my_cmd"
##     cmd.description = "Does my custom thing."
##     cmd.context = "both"
##     cmd.callable_target = self
##     cmd.callable_method = "_run_my_cmd"
##     debug_console.register_resource_command(cmd)
## [/codeblock]
##
## Note: `callable_target` is an [Object] reference and is therefore NOT
## persisted when this resource is saved to a `.tres` file (Godot only
## serializes [Resource] references for [Object]-typed fields). For that
## reason, ConsoleCommand instances are intended to be constructed and
## registered at runtime (in `_enter_tree` / `_ready`), not loaded from disk.

## The command word as typed in the console (lowercase, no spaces, no leading
## or trailing whitespace). This is also the key under which the command is
## stored in the registry - registering a name that already exists will fail.
@export var command_name: String = ""

## Human-readable description shown in the `help` command output. Keep it to
## a single line if possible; long descriptions may be truncated by some
## autocomplete UIs.
@export_multiline var description: String = ""

## Context in which the command should be available. Must be one of:
## "editor" (only in the Godot editor), "game" (only at runtime in the
## running project), or "both". Any other value causes [method is_valid] to
## return [code]false[/code].
@export var context: String = "both"

## The object whose method will be called when this command is executed.
## Must remain valid for the lifetime of the registration - if this object
## is freed, the command will silently fail with an "object was destroyed"
## error message. Plugin authors should unregister the command in their
## `_exit_tree` / cleanup paths to avoid this.
## [br]Note: this field is NOT [code]@export[/code]ed. Godot does not allow
## [Resource]s to declare exported [Object] (or [Node]) properties, because
## those references cannot be serialized when the resource is saved to disk.
## Always assign this field in code, e.g. [code]cmd.callable_target = self[/code].
var callable_target: Object = null

## The name of the method on [member callable_target] to invoke. The method
## must accept a single [Array] of [String] arguments and return a value
## that is convertible to [String] (typically [String] itself).
@export var callable_method: String = ""

## Returns [code]true[/code] if every field required for registration is set
## to a usable value, otherwise [code]false[/code]. Specifically:
## [br]- [member command_name] is non-empty after trimming whitespace
## [br]- [member callable_target] is non-null and is a valid instance
## [br]- [member callable_method] is non-empty and exists as a method on
## [member callable_target]
## [br]- [member context] is one of "editor", "game", or "both"
func is_valid() -> bool:
	if command_name.strip_edges().is_empty():
		return false
	if context != "editor" and context != "game" and context != "both":
		return false
	if callable_target == null:
		return false
	if not is_instance_valid(callable_target):
		return false
	if callable_method.strip_edges().is_empty():
		return false
	if not callable_target.has_method(callable_method):
		return false
	return true

## Returns a [Callable] bound to [member callable_target] and
## [member callable_method], suitable for passing to
## [method DebugConsole.register_command]. Returns an invalid [Callable]
## (one for which `is_valid()` is `false`) when [method is_valid] is
## [code]false[/code], so callers can guard with
## [code]to_callable().is_valid()[/code].
func to_callable() -> Callable:
	if not is_valid():
		return Callable()
	return Callable(callable_target, callable_method)

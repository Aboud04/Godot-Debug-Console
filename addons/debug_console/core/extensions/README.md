# Extensions

Auto-loaded command modules. Drop any `*Commands.gd` file here and
`BuiltInCommands.register_universal_commands` will instantiate it via the
extensions loader on next plugin enable. The module must follow the standard
shape:

```gdscript
@tool
class_name DebugConsoleXyzCommands extends RefCounted

var _registry: Node
var _core: Node

func register_commands(registry: Node, core: Node) -> void:
    _registry = registry
    _core = core
    if not _registry:
        return
    _registry.register_command("xyz", _cmd_xyz, "description", "both")
    # ...
```

Modules are kept alive in the shared `_t6_keepalive` static array on
`BuiltInCommands`. No edits to `BuiltInCommands.gd` are required when adding
a new extension module.

# PROJECT.md - The Constitution
> **GSD Framework | Godot Debug Console**
> Last updated: 2026-05-27 | Version: 1.2.0

---

## 1. Project Purpose

**Godot Debug Console** is a first-class Godot 4.x editor and runtime addon that provides a native terminal-like interface inside the Godot editor and in-game overlay. It accelerates development workflows through integrated file management, extensible command execution, piped command chaining, and smart autocomplete - all without leaving the Godot environment.

**Target users:** Godot 4.x developers (indie, small studio) who want an IDE-grade debug/shell experience inside the engine.

---

## 2. Architecture Overview

```
addons/debug_console/
├── plugin.gd                   # EditorPlugin entry point (@tool) - registers all 4 autoloads
├── plugin.cfg                  # version, author, icon
├── core/
│   ├── DebugCore.gd            # Autoload singleton - logging, output dispatch, history
│   ├── CommandRegistry.gd      # Autoload singleton - command registration, execution, piping
│   ├── DebugConsoleAPI.gd      # Autoload singleton (DebugConsole) - PUBLIC plugin author API (Tier 4)
│   ├── ConsoleCommand.gd       # Resource - declarative command definition (Tier 4)
│   ├── PersistenceManager.gd   # RefCounted - history + cwd persistence to user:// (Tier 3)
│   └── BuiltInCommands.gd      # RefCounted - registers ~50 built-in commands on demand
├── editor/
│   ├── EditorConsole.tscn      # Bottom-panel UI for editor context
│   └── EditorConsole.gd        # Editor console controller (autocomplete popup, table renderer, clickable paths)
├── game/
│   ├── GameConsole.tscn        # In-game overlay UI (CanvasLayer)
│   ├── GameConsole.gd          # Game console controller (opacity, resize handle, intercept)
│   ├── GameConsoleManager.gd   # Autoload - spawns GameConsole at runtime
│   ├── GameConsoleManager.tscn
│   └── GameConsoleLogger.gd    # Logger subclass - print/warning/error interceptor (Godot 4.5+, conditionally load()-ed)
├── icons/
│   └── console_icon.svg
└── tests/
    ├── TestFramework.gd        # RefCounted - 247-test suite (v1.2.0)
    └── README.md
```

### Autoload Roster (registered by `plugin.gd`)

| Order | Autoload | Script | Purpose |
|---|---|---|---|
| 1 | `DebugCore` | `core/DebugCore.gd` | Logging, history, message routing |
| 2 | `CommandRegistry` | `core/CommandRegistry.gd` | Command registry + piping engine |
| 3 | `DebugConsole` | `core/DebugConsoleAPI.gd` | Public API surface for third-party plugins |
| 4 | `GameConsoleManager` | `game/GameConsoleManager.gd` | Spawns GameConsole when the project runs |

### Data Flow
```
[User Input] → EditorConsole / GameConsole
    → CommandRegistry.execute_command()
        → Piping engine (if | present)
        → Command callable (BuiltInCommands or third-party via DebugConsole API)
    → DebugCore.Log()  →  Output panel / game overlay
                       →  DebugConsole.command_executed signal (Tier 4)
```

### Context Duality
Every command is tagged with its valid context: `"editor"`, `"game"`, or `"both"`. CommandRegistry enforces this at execution time via `Engine.is_editor_hint()`.

### Persistence

| File | Purpose | Cap / Behavior |
|---|---|---|
| `user://debug_console_history.json` | Command history across editor restarts | Cap 500 entries; consecutive duplicates dedup'd; graceful recovery on corruption |
| `user://debug_console_state.json` | Per-project working directory | Keyed by project path; different projects keep independent cwd |
| `user://debug_console_aliases.cfg` (ConfigFile) | Persistent `alias`/`unalias` definitions | Shipped in v1.1.0 (Phase 3b.3) |
| `user://debug_console_config.cfg` (ConfigFile) | Persistent console appearance preferences | Shipped in v1.1.0 (Phase 3b.5); Tier 2.3 adds opacity/height keys |

---

## 3. Tech Stack

| Layer | Technology |
|---|---|
| Engine | Godot **4.x** (primary target: **4.5 / 4.6**); print interception requires **4.5+** |
| Language | **GDScript 2.0** (strict mode compatible) |
| Addon system | Godot **EditorPlugin** API |
| UI | Godot Control nodes, native bottom panel integration, RichTextLabel with BBCode |
| Persistence | JSON (`user://debug_console_history.json`, `user://debug_console_state.json`) + ConfigFile (aliases, settings) |
| Testing | Custom `TestFramework.gd` (247 tests) + file-based runner (`res://.dc_test_runner.tscn` → `res://.dc_test_results.json`) |
| C# compat | Must function in MonoProject / .NET-enabled builds |
| VCS | Git - `.godot/` cache MUST be gitignored |

---

## 4. Strict Rules for Plugin Development

These rules are **invariants**. No agent task may violate them.

### 4.1 - Autoload Lifecycle (CRITICAL)

> **Root cause of Issues #10, #12, #13.**

- `plugin.gd#_enter_tree()` **MUST** register all required autoloads programmatically using `add_autoload_singleton(name, path)` before any code that references those singletons executes.
- `plugin.gd#_exit_tree()` **MUST** remove all autoloads registered by the plugin using `remove_autoload_singleton(name)`.
- The autoload registration block in `project.godot` is the **developer's convenience copy only** - it must not be the sole source of singleton registration for end-users installing the addon.
- A fresh user's project will have **zero pre-existing autoloads**. The plugin must be entirely self-provisioning.

### 4.2 - No Static Singleton References in @tool Scripts

- **FORBIDDEN:** Bare global identifiers like `DebugCore.Log()` or `CommandRegistry.register_command()` inside any `@tool`-annotated script that could be parsed before the plugin's `_enter_tree()` completes.
- **REQUIRED:** All `@tool` scripts that need singleton access must use deferred or safe lookup patterns:
  - `Engine.get_singleton("DebugCore")` - for engine-registered singletons
  - `Engine.get_main_loop().root.get_node_or_null("/root/DebugCore")` - for autoload nodes
  - Or pass references explicitly via method parameters (preferred for testability).
- `BuiltInCommands.gd` must **never** call `DebugCore` or `CommandRegistry` as bare globals. It must receive them as injected dependencies or retrieve them via the node tree.

### 4.3 - Initialization Order

```
_enter_tree() execution order (mandatory):
  1. add_autoload_singleton("DebugCore", ...)
  2. add_autoload_singleton("CommandRegistry", ...)
  3. add_autoload_singleton("DebugConsole", ...)     # Public plugin author API (Tier 4)
  4. add_autoload_singleton("GameConsoleManager", ...)
  5. await get_tree().process_frame   # allow autoloads to _ready()
  6. Instantiate EditorConsole panel
  7. DebugCore reference (via node path) → initialize_for_editor()
  8. Register built-in commands
  9. Add panel to bottom dock
```

### 4.4 - Editor vs Runtime Isolation

- All editor-only code paths must be guarded by `Engine.is_editor_hint()`.
- `GameConsoleManager.gd` must guard its entire `_ready()` body with `if Engine.is_editor_hint(): return`.
- Never add game-runtime UI nodes to the editor scene tree; never add editor UI into the game scene tree.

### 4.5 - C# / Mono Compatibility

- Do not use GDScript features that crash C# projects: `class_name` global registration conflicts must be tested against MonoProject.
- All file paths must use `res://` scheme, never OS-level absolute paths.
- The plugin must not depend on any C#-only or Mono-only assembly.

### 4.6 - No Cache in Version Control

- `.godot/` directory **MUST** be listed in `.gitignore`.
- Never commit `.uid` files generated by cache. Source UID files (`*.gd.uid`) may be retained only if they are hand-authored; auto-generated ones must be gitignored.
- `*.import` files are build artifacts and must be gitignored unless they define import settings that cannot be auto-regenerated.

### 4.7 - Test Integrity

- `TestFramework.gd` is the source of truth for correctness.
- **All tests must pass** before any PR, refactor, or phase is marked complete (current count: **247 tests** as of v1.2.0).
- Tests must not be skipped, mocked away, or have their assertions weakened to make them pass.
- The test-runner auto-PASS heuristic (which used to treat any string return as success) has been removed; tests must explicitly return `bool`.
- If a refactor changes an API, the test must be updated to match the new API - not deleted.
- The file-based runner (`res://.dc_test_runner.tscn` → `res://.dc_test_results.json`) is the canonical pipeline for CI and headless verification.

### 4.8 - Minimal Surface, Maximum Clarity

- `plugin.gd` must remain the sole EditorPlugin entry point. Do not create additional plugin entry points.
- Keep `core/`, `editor/`, `game/` separation strict - no cross-folder direct instantiation except through the registry or explicit injection.
- Every registered command must have a non-empty `description` string.

---

## 5. Glossary

| Term | Definition |
|---|---|
| **Autoload singleton** | A Node registered in Project Settings → Autoload, available globally by name |
| **Parse Error #10/#12/#13** | The "Identifier not declared" error caused by bare singleton refs in `@tool` scripts parsed before autoloads are active |
| **GSD** | Get Stuff Done - the spec-driven agent workflow used in this repo |
| **Context** | `"editor"` (inside Godot IDE) vs `"game"` (running project) - determined by `Engine.is_editor_hint()` |
| **Piping** | Chaining commands with `\|` - output of left command is appended as args to right command |
| **Plugin Author API** | Public surface at `/root/DebugConsole` (script `core/DebugConsoleAPI.gd`) - the only entry point third-party plugins should use; backward-compatible from v1.2.0 onward (REQ-6.2) |
| **ConsoleCommand** | Resource (`core/ConsoleCommand.gd`) that bundles command name + callable + metadata for declarative registration. `callable_target` is NOT `@export`ed because Godot refuses to serialize Object/Node refs on Resource |
| **PersistenceManager** | RefCounted (`core/PersistenceManager.gd`) responsible for reading/writing `user://debug_console_history.json` and `user://debug_console_state.json` |
| **File-based runner** | `res://.dc_test_runner.tscn` - a headless scene that runs `TestFramework.gd` and writes `res://.dc_test_results.json`. The canonical pipeline for CI; MCP `get_console_log` is unreliable across multiple runs |

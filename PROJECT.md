# PROJECT.md — The Constitution
> **GSD Framework | Godot Debug Console**
> Last updated: 2026-03-12 | Version: 1.0.0

---

## 1. Project Purpose

**Godot Debug Console** is a first-class Godot 4.x editor and runtime addon that provides a native terminal-like interface inside the Godot editor and in-game overlay. It accelerates development workflows through integrated file management, extensible command execution, piped command chaining, and smart autocomplete — all without leaving the Godot environment.

**Target users:** Godot 4.x developers (indie, small studio) who want an IDE-grade debug/shell experience inside the engine.

---

## 2. Architecture Overview

```
addons/debug_console/
├── plugin.gd                   # EditorPlugin entry point (@tool)
├── plugin.cfg
├── core/
│   ├── DebugCore.gd            # Autoload singleton — logging, output dispatch
│   ├── CommandRegistry.gd      # Autoload singleton — command registration & execution
│   └── BuiltInCommands.gd      # RefCounted — registers built-in commands on demand
├── editor/
│   ├── EditorConsole.tscn      # Bottom-panel UI for editor context
│   └── EditorConsole.gd        # Editor console controller
├── game/
│   ├── GameConsole.tscn        # In-game overlay UI (CanvasLayer)
│   ├── GameConsole.gd          # Game console controller
│   ├── GameConsoleManager.gd   # Autoload — spawns GameConsole at runtime
│   └── GameConsoleManager.tscn
├── icons/
│   └── console_icon.svg
└── tests/
    ├── TestFramework.gd        # RefCounted — comprehensive 100+ test suite
    └── README.md
```

### Data Flow
```
[User Input] → EditorConsole / GameConsole
    → CommandRegistry.execute_command()
        → Piping engine (if | present)
        → Command callable (BuiltInCommands or user-registered)
    → DebugCore.Log()  →  Output panel / game overlay
```

### Context Duality
Every command is tagged with its valid context: `"editor"`, `"game"`, or `"both"`. CommandRegistry enforces this at execution time via `Engine.is_editor_hint()`.

---

## 3. Tech Stack

| Layer | Technology |
|---|---|
| Engine | Godot **4.x** (primary target: **4.5 / 4.6**) |
| Language | **GDScript 2.0** (strict mode compatible) |
| Addon system | Godot **EditorPlugin** API |
| UI | Godot Control nodes, native bottom panel integration |
| Testing | Custom `TestFramework.gd` (in-engine, no third-party libs) |
| C# compat | Must function in MonoProject / .NET-enabled builds |
| VCS | Git — `.godot/` cache MUST be gitignored |

---

## 4. Strict Rules for Plugin Development

These rules are **invariants**. No agent task may violate them.

### 4.1 — Autoload Lifecycle (CRITICAL)

> **Root cause of Issues #10, #12, #13.**

- `plugin.gd#_enter_tree()` **MUST** register all required autoloads programmatically using `add_autoload_singleton(name, path)` before any code that references those singletons executes.
- `plugin.gd#_exit_tree()` **MUST** remove all autoloads registered by the plugin using `remove_autoload_singleton(name)`.
- The autoload registration block in `project.godot` is the **developer's convenience copy only** — it must not be the sole source of singleton registration for end-users installing the addon.
- A fresh user's project will have **zero pre-existing autoloads**. The plugin must be entirely self-provisioning.

### 4.2 — No Static Singleton References in @tool Scripts

- **FORBIDDEN:** Bare global identifiers like `DebugCore.Log()` or `CommandRegistry.register_command()` inside any `@tool`-annotated script that could be parsed before the plugin's `_enter_tree()` completes.
- **REQUIRED:** All `@tool` scripts that need singleton access must use deferred or safe lookup patterns:
  - `Engine.get_singleton("DebugCore")` — for engine-registered singletons
  - `Engine.get_main_loop().root.get_node_or_null("/root/DebugCore")` — for autoload nodes
  - Or pass references explicitly via method parameters (preferred for testability).
- `BuiltInCommands.gd` must **never** call `DebugCore` or `CommandRegistry` as bare globals. It must receive them as injected dependencies or retrieve them via the node tree.

### 4.3 — Initialization Order

```
_enter_tree() execution order (mandatory):
  1. add_autoload_singleton("DebugCore", ...)
  2. add_autoload_singleton("CommandRegistry", ...)
  3. add_autoload_singleton("GameConsoleManager", ...)
  4. await get_tree().process_frame   # allow autoloads to _ready()
  5. Instantiate EditorConsole panel
  6. DebugCore reference (via node path) → initialize_for_editor()
  7. Register built-in commands
  8. Add panel to bottom dock
```

### 4.4 — Editor vs Runtime Isolation

- All editor-only code paths must be guarded by `Engine.is_editor_hint()`.
- `GameConsoleManager.gd` must guard its entire `_ready()` body with `if Engine.is_editor_hint(): return`.
- Never add game-runtime UI nodes to the editor scene tree; never add editor UI into the game scene tree.

### 4.5 — C# / Mono Compatibility

- Do not use GDScript features that crash C# projects: `class_name` global registration conflicts must be tested against MonoProject.
- All file paths must use `res://` scheme, never OS-level absolute paths.
- The plugin must not depend on any C#-only or Mono-only assembly.

### 4.6 — No Cache in Version Control

- `.godot/` directory **MUST** be listed in `.gitignore`.
- Never commit `.uid` files generated by cache. Source UID files (`*.gd.uid`) may be retained only if they are hand-authored; auto-generated ones must be gitignored.
- `*.import` files are build artifacts and must be gitignored unless they define import settings that cannot be auto-regenerated.

### 4.7 — Test Integrity

- `TestFramework.gd` is the source of truth for correctness.
- **All 100+ tests must pass** before any PR, refactor, or phase is marked complete.
- Tests must not be skipped, mocked away, or have their assertions weakened to make them pass.
- If a refactor changes an API, the test must be updated to match the new API — not deleted.

### 4.8 — Minimal Surface, Maximum Clarity

- `plugin.gd` must remain the sole EditorPlugin entry point. Do not create additional plugin entry points.
- Keep `core/`, `editor/`, `game/` separation strict — no cross-folder direct instantiation except through the registry or explicit injection.
- Every registered command must have a non-empty `description` string.

---

## 5. Glossary

| Term | Definition |
|---|---|
| **Autoload singleton** | A Node registered in Project Settings → Autoload, available globally by name |
| **Parse Error #10/#12/#13** | The "Identifier not declared" error caused by bare singleton refs in `@tool` scripts parsed before autoloads are active |
| **GSD** | Get Stuff Done — the spec-driven agent workflow used in this repo |
| **Context** | `"editor"` (inside Godot IDE) vs `"game"` (running project) — determined by `Engine.is_editor_hint()` |
| **Piping** | Chaining commands with `\|` — output of left command is appended as args to right command |

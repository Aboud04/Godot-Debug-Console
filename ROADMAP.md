# ROADMAP.md — The Master Plan
> **GSD Framework | Godot Debug Console**
> Last updated: 2026-03-12

---

## How to Read This File

- Each phase is a self-contained unit of work.
- Tasks within a phase must be completed **in order** unless explicitly marked as parallelizable.
- Status icons: `[ ]` = not started · `[~]` = in progress · `[x]` = done · `[!]` = blocked
- Linked requirement IDs (e.g., `→ REQ-1.1`) reference `REQUIREMENTS.md` acceptance criteria.
- Update `STATE.md` whenever a task's status changes.

---

## Phase 1 — Installation Architecture Fix

**Goal:** Any developer can install the addon on a brand-new Godot 4.5 or 4.6 project (GDScript or C#) and enable it from the Plugin menu without a parse error, crash, or restart requirement.

**Root cause (Issues #10, #12, #13):** `plugin.gd` and `BuiltInCommands.gd` reference `DebugCore` and `CommandRegistry` as bare global identifiers. In a fresh project, these autoloads do not exist when the GDScript parser processes `@tool` scripts, causing `Parse Error: Identifier not declared`.

---

### Task 1.1 — Add `.godot/` to `.gitignore`
**Status:** `[ ]`
**Priority:** P0 — do first (unblocks clean testing)

- [ ] Check if `.gitignore` exists in the repo root; create it if absent.
- [ ] Add `.godot/` entry.
- [ ] Add `*.import` entry (auto-generated import metadata).
- [ ] Verify `.godot/` is no longer tracked by git (`git ls-files --others --exclude-standard`).
- [ ] Commit: `chore: add .godot/ and *.import to .gitignore`

**Verifies:** REQ-3.5

---

### Task 1.2 — Refactor `plugin.gd`: Dynamic Autoload Registration
**Status:** `[ ]`
**Priority:** P0 — core fix

**What to change in `plugin.gd`:**

1. Remove all bare `DebugCore.*` and `CommandRegistry.*` calls from the top-level scope.
2. In `_enter_tree()`:
   - Call `add_autoload_singleton("DebugCore", "res://addons/debug_console/core/DebugCore.gd")`.
   - Call `add_autoload_singleton("CommandRegistry", "res://addons/debug_console/core/CommandRegistry.gd")`.
   - Call `add_autoload_singleton("GameConsoleManager", "res://addons/debug_console/game/GameConsoleManager.gd")`.
   - `await get_tree().process_frame` to allow autoloads to call `_ready()`.
   - Fetch references via `get_node("/root/DebugCore")` and `get_node("/root/CommandRegistry")`.
   - Pass references as parameters to dependent code (no bare globals).
3. In `_exit_tree()`:
   - Call `remove_autoload_singleton("GameConsoleManager")`.
   - Call `remove_autoload_singleton("CommandRegistry")`.
   - Call `remove_autoload_singleton("DebugCore")`.

**Subtasks:**
- [ ] Backup original `plugin.gd` as `plugin.gd.bak` for reference during refactor.
- [ ] Implement `_enter_tree()` with ordered `add_autoload_singleton()` calls + `await`.
- [ ] Implement `_exit_tree()` with `remove_autoload_singleton()` in reverse order.
- [ ] Remove static `DebugCore`/`CommandRegistry` references from `plugin.gd` body.
- [ ] Verify no parse errors when the file is loaded cold (no autoloads pre-existing).

**Verifies:** REQ-1.1 through REQ-1.9, REQ-3.2, REQ-3.3

---

### Task 1.3 — Refactor `BuiltInCommands.gd`: Eliminate Bare Singleton Refs
**Status:** `[ ]`
**Priority:** P0 — same root cause

**Problem:** `BuiltInCommands.gd` calls `CommandRegistry.register_command(...)` and `DebugCore.Log(...)` / `DebugCore.clear_history()` / `DebugCore.editor_output` as bare globals throughout. Since the file is `@tool`, GDScript parses it at editor startup — before autoloads are ready.

**Approach — Dependency Injection:**
1. Add `var _registry: Node` and `var _core: Node` properties to `BuiltInCommands`.
2. Add an `initialize(registry: Node, core: Node)` method that sets these properties.
3. Replace every bare `CommandRegistry.*` call with `_registry.*`.
4. Replace every bare `DebugCore.*` call with `_core.*`.
5. In `plugin.gd`, after fetching node refs: `builtin_commands.initialize(registry_node, core_node)`.

**Subtasks:**
- [ ] Audit `BuiltInCommands.gd` for every occurrence of `CommandRegistry` and `DebugCore`.
- [ ] Add `_registry` and `_core` instance variables.
- [ ] Implement `initialize(registry, core)` method.
- [ ] Replace all bare global refs with instance variable refs.
- [ ] Update `plugin.gd` call site to call `.initialize()` before `.register_editor_commands()`.
- [ ] Update `GameConsoleManager.gd` to call `.initialize()` before `.register_game_commands()`.

**Verifies:** REQ-3.1, REQ-4.1, REQ-4.2

---

### Task 1.4 — Refactor `CommandRegistry.gd`: Remove Internal `DebugCore` Dependency
**Status:** `[ ]`
**Priority:** P1

**Problem:** `CommandRegistry.register_command()` and `unregister_command()` call `DebugCore.Log()` directly. This creates a circular dependency (both are autoloads that could load in any order) and a bare-global parse risk.

**Approach:**
- Remove `DebugCore.Log()` calls from `CommandRegistry.gd`.
- Use `print()` as the fallback (sufficient for registry-level logging).
- Or accept an optional logger callable: `var _logger: Callable`.

**Subtasks:**
- [ ] Replace `DebugCore.Log(...)` calls in `CommandRegistry.gd` with `print(...)`.
- [ ] Verify `CommandRegistry.gd` has zero references to `DebugCore`.

**Verifies:** REQ-3.1

---

### Task 1.5 — Fix `GameConsoleManager.gd` Editor Guard
**Status:** `[ ]`
**Priority:** P1

**Problem:** `GameConsoleManager.gd` currently has `if Engine.is_editor_hint(): return` in `_ready()`, but it preloads `GameConsole.tscn` as a `const` at class level. This preload executes during parse phase and could trigger issues.

**Approach:**
- Move the `const GAME_CONSOLE_SCENE = preload(...)` line inside `_create_console()` (runtime-only path) or convert to a lazy load.

**Subtasks:**
- [ ] Move `preload("res://addons/debug_console/game/GameConsole.tscn")` out of class-level const.
- [ ] Load it dynamically inside `_create_console()` via `load(...)` or `ResourceLoader.load(...)`.
- [ ] Confirm editor guard `if Engine.is_editor_hint(): return` is the first statement in `_ready()`.

**Verifies:** REQ-3.6

---

### Task 1.6 — Verify `project.godot` Stays Clean (Dev Project)
**Status:** `[ ]`
**Priority:** P1

The developer's own `project.godot` has the autoloads hard-coded. After Phase 1, the plugin manages its own autoloads, so the developer copy should either:
- Remove the hard-coded autoload entries from `project.godot` (and let the plugin add them), or
- Document clearly that the dev project's `project.godot` is a convenience setup that end-users won't have.

**Subtasks:**
- [ ] Decide which approach: remove from `project.godot` or document the dual-state.
- [ ] Update `project.godot` accordingly.
- [ ] Ensure the test scene (`test_scene.tscn`) still runs correctly.

---

### Task 1.7 — Full Test Pass: Phase 1 Validation
**Status:** `[ ]`
**Priority:** P0 — gate task; Phase 1 cannot be closed without this

**Subtasks:**
- [ ] Enable plugin on a clean GDScript-only Godot 4.5 project → zero errors → REQ-1.1 ✓
- [ ] Enable plugin on a clean GDScript-only Godot 4.6 project → zero errors → REQ-1.2 ✓
- [ ] Enable plugin on a clean C# Godot 4.5 project → zero errors → REQ-1.3 ✓
- [ ] Enable plugin on a clean C# Godot 4.6 project → zero errors → REQ-1.4 ✓
- [ ] Disable plugin → autoloads removed → no orphan nodes → REQ-1.6 ✓
- [ ] Run `test` command in EditorConsole → all 100+ tests pass → REQ-2.1 ✓
- [ ] Run functional smoke tests: `ls`, `cd`, `grep`, `help`, `ls | grep` → REQ-4.1–4.3 ✓
- [ ] Update `STATE.md`: set Phase = 2, Task = "Phase 1 complete".

---

## Phase 2 — Modernization & Godot 4.6 Compatibility

**Goal:** Zero deprecation warnings on Godot 4.6, full compatibility with both GDScript and .NET project types, no reliance on any 4.x API that was removed or renamed in 4.5+.

**Status:** `[ ]` — not started (begins after Phase 1 gate task passes)

---

### Task 2.1 — Godot 4.6 API Audit
- [ ] Cross-reference all API calls in addon scripts against Godot 4.6 changelog and class reference.
- [ ] Identify any deprecated methods (e.g., signal parameter changes, renamed nodes).
- [ ] Document findings as a checklist here before implementing fixes.

### Task 2.2 — Fix Deprecated API Usage
- [ ] Replace all deprecated calls found in Task 2.1.
- [ ] Re-run test suite after each replacement to catch regressions.

### Task 2.3 — C# Project Compatibility Hardening
- [ ] Validate that `class_name` declarations in GDScript don't conflict with C# type names.
- [ ] Test addon enable/disable cycle in a .NET-enabled Godot 4.6 project.
- [ ] Confirm `res://` paths resolve correctly in C# project layout.

### Task 2.4 — Phase 2 Test Pass
- [ ] All REQ-1.x, REQ-2.x, REQ-5.x criteria pass.
- [ ] Update `STATE.md`.

---

## Phase 3 — Feature Expansion

**Goal:** Extend the console command set and improve developer experience.

---

### Phase 3a — Core Feature Sprint ✅ COMPLETE

| Task | Feature | Status |
|---|---|---|
| 3a.1 | `scene_tree` — ASCII tree dump of the running scene | `[x]` Done |
| 3a.2 | `watch <expr>` — Live property monitor with auto-poll | `[x]` Done |
| 3a.3 | `save_log <path>` — Export session log to disk | `[x]` Done |
| —    | Deferred `focus_command_input()` on all console open paths | `[x]` Done |

---

### Phase 3b — Developer Power Tools ✅ SHIPPED (v1.1.0)

Released as v1.1.0 (commit `f292c33`). All five tasks shipped.

| Task | Feature | Status |
|---|---|---|
| 3b.1 | `inspect` — Dump all properties of a node, autoload, or Engine | `[x]` Done |
| 3b.2 | `set` / `get` — Read/write live node properties by selector | `[x]` Done |
| 3b.3 | `alias` / `unalias` — Persistent command shorthands (ConfigFile) | `[x]` Done |
| 3b.4 | `benchmark` — Time command execution over N iterations | `[x]` Done |
| 3b.5 | `config` — Persist console appearance preferences | `[x]` Done |

---

## Phase 4 — Audit & Hardening (Active, started 2026-05-27)

Started with a fresh codebase ingestion. Audit surfaced 4 surgical bugs and a test-integrity violation (REQ-2.2). Work is organized into 4 tiers; tiers ship sequentially with a user boundary review between each.

### Tier 1 — Correctness & Test Integrity

**Goal:** Fix 4 confirmed bugs and replace fraudulent / over-permissive test assertions. Block all later tiers on this passing.

#### T1-A — Surgical Bug Fixes ✅
**Status:** `[x]` Done. Diff integrated 2026-05-27.

| ID | File | Bug | Fix Strategy |
|---|---|---|---|
| B1 | `editor/EditorConsole.gd` (`_get_file_suggestions`, `_get_directory_suggestions`) | File/dir autocomplete clamped cwd back to `res://` after `cd subfolder`, breaking the suggestion system. Also: `if BuiltInCommands.get_current_directory:` (no parens) was a no-op truthiness check. | Use real `BuiltInCommands.get_current_directory()`; remove clamping branch. |
| B2 | `game/GameConsole.gd` (`_input`) | `Escape` matched outer `match` arm but inner `if` only handled F12 / Ctrl+`. Esc was a silent no-op. | Replace nested match/if with a flat boolean predicate; Esc, F12, Ctrl+\` all close. |
| B3a | `editor/EditorConsole.gd` (`add_log_message`) | Truncation used `get_parsed_text()` which strips BBCode; colors lost permanently after first truncation. | Maintain `_output_buffer: Array[String]` of raw BBCode lines; clear and rebuild from buffer when capacity exceeded. |
| B3b | `editor/EditorConsole.gd` (`add_log_message`) | Auto-refocus on every log message stole focus from script editor when `watch` polled. | Delete the auto-refocus call; focus is still grabbed on console show and after command execution. |
| B4 | `core/BuiltInCommands.gd` (`_create_scene`) | Hardcoded `uid="uid://bqxvj6y5n8q8p"` in scene template caused UID collisions across every generated scene. | Use `ResourceUID.create_id()` + `ResourceUID.id_to_text()` per call. |

#### T1-B — Test Honesty Pass ✅
**Status:** `[x]` Done. Diff integrated 2026-05-27.

- Removed the auto-PASS String/null heuristic in `_execute_test_safely`. Tests must now return `bool`; non-bool returns produce a loud failure with a clear `error_info` message.
- Tightened 8 OR-chain assertions in `run_builtin_commands_tests` (View File piped, List Files piped, Find, Stat, Remove Directory, Save Scenes, Run Project, Stop Project) that previously accepted failure as success.
- Tightened the empty-grep test to assert the exact current Godot 4.6 observable behavior (verified against `core/string/ustring.cpp` `String::find` empty-needle guard).
- Added 2 regression tests: `Regression - B1 cwd Persists Across Instances` and `Regression - B4 new_scene Generates Unique UIDs`.
- **Deliberately preserved** the ~35 `return true` UI test stubs in `EditorConsole`/`GameConsole`/`ConsoleManager`/`DebugCore` test blocks. Those are deferred to T1-D (see below).

#### T1-C — Doc Sync ✅
**Status:** `[x]` Done. STATE.md and ROADMAP.md updated to match git reality.

#### T1-V — Manual Verification (gate task)
**Status:** `[ ]` Awaiting user.

- [ ] Run `test` in EditorConsole on Godot 4.6. All 169 tests must pass.
- [ ] Smoke-test B1: `cd addons` then `cat B<Tab>` should suggest `BuiltInCommands.gd` (or similar files in the actual cwd).
- [ ] Smoke-test B2: open game console with F12, press Esc — must close.
- [ ] Smoke-test B3a: emit > 1000 log messages, verify colors are still rendered on the most recent 1000.
- [ ] Smoke-test B3b: open the console, focus a script in the editor, let a `watch` fire — focus must stay on the script.
- [ ] Smoke-test B4: run `new_scene foo` then `new_scene bar`; verify the two `.tscn` files have different `uid="..."` headers.

#### T1-D — UI-Test Fixture Pass (deferred)
**Status:** `[ ]` Deferred — runs after Tier 2 ships.

Rewrite the ~35 `return true` UI stubs in `run_editor_console_tests`, `run_game_console_tests`, `run_console_manager_tests`, and `run_debug_core_tests` using real `SceneTree` fixtures. Each test must:
1. Instantiate the Control / Node under test.
2. Add it to a transient parent under `get_tree().root`.
3. Assert real behavior (signal emission, property mutation, focus state).
4. Cleanly `queue_free()` afterwards.

Includes regression tests for B2 (GameConsole Esc closes) and B3a/B3b (BBCode persists, focus doesn't theft) since those need fixtures too.

### Tier 2 — UX & Keyboard Polish

**Status:** `[ ]` Not started. Begins after Tier 1 boundary review.

#### T2.1 — Full keyboard autocomplete UX
- Floating ItemList popup for autocomplete suggestions (no current visible UI).
- Arrow keys cycle through suggestions with visual selection.
- Esc dismisses popup, restores typed text.
- Tab still completes; Shift+Tab cycles backwards.
- Home / End move caret to ends of line.
- Ctrl+A select-all in input. Ctrl+U clear-line.

#### T2.2 — Output renderer polish
- Color categories beyond level: file paths (cyan), numbers (yellow), error keywords (red), warning keywords (amber).
- Clickable file paths in output — clicking opens in editor (use `meta_clicked` signal on RichTextLabel).
- Optional `ls -l` table renderer with columns (name, type, size, modified).
- **Cut from original mandate:** "collapsible sections" — RichTextLabel doesn't support native collapse; faking it is a yak-shave.

#### T2.3 — Game console polish
- `opacity <0-100>` command + Ctrl+Scroll on console body to adjust live.
- Real bottom-edge resize handle (drag to resize).
- Print interception: route `print()`, `push_warning()`, `push_error()` to console (`print_rich` + custom logger script attached via `OS.add_logger` if API allows; otherwise hook via `Engine.print_error_messages` channel).
- **Cut from original mandate:** Mini overlay F11 mode — fights with other F-keys, separate feature not polish.

### Tier 3 — New Commands & Capabilities

**Status:** `[ ]` Not started. Begins after Tier 2 boundary review.

#### T3.1 — Genuinely useful new built-ins
- `tree [depth]` — `tree` as cwd visualization with optional depth limit. Distinct from `scene_tree` (scene graph) — this is filesystem.
- `wc <file>` — word / line / char count. Pipe-aware.
- `signals <node_path>` — list signals on a node and current connections.
- `properties <node_path>` — filtered view from `inspect` (just names + types, no values).
- `reload_scripts` — soft-reload all GDScript files in project. Uses `ResourceLoader.load(..., "Script", ResourceLoader.CACHE_MODE_REPLACE)`.
- `diff <a> <b>` — line-level diff between two files, BBCode-colored.

#### T3.2 — Smarter context-aware autocomplete
- After commands that take a node-path argument (`inspect`, `get`, `set`, `watch`, `scene_tree`, `signals`, `properties`), suggest live node paths from the scene tree.
- After `cd`, only suggest directories. After `cat`/`grep`/`head`/`tail`/`stat`/`wc`, only suggest files.
- After `new_script`/`new_scene`, suggest common `extends` types from `ClassDB.get_class_list()`.
- **Cut from original mandate:** fuzzy matching (complexity vs. value); MRU ranking (requires persistence layer — defer until that exists).

#### T3.3 — Light persistence layer
- Command history persists across editor restarts. `user://debug_console_history.json`, cap 500 entries.
- Working directory persists per project. `user://debug_console_state.json`.
- **Cut from original mandate:** Aliases (already persisted via ConfigFile in 3b.3). Config (already persisted via ConfigFile in 3b.5). Don't duplicate.

### Tier 4 — Plugin Author API

**Status:** `[ ]` Not started. Begins after Tier 3 boundary review.

- Stable public `DebugConsole` autoload interface: `register_command(name, callable, description, context)`, `unregister_command(name)`, `print_to_console(text, level)`, `set_context(context)`.
- `ConsoleCommand` Resource type for declarative command definitions.
- Signals: `command_executed(command_name, args, result)`, `console_opened()`, `console_closed()`.
- `##` docstrings on every public method/signal.
- Document in `addons/debug_console/README.md`.

---

## Dependency Map

```
Phase 1 ──► Phase 2 ──► Phase 3 (a + b) ──► Phase 4
                                              │
                                              ├── Tier 1 (correctness + test honesty)
                                              │     │
                                              │     ├── T1-A (bugs)  ──► T1-B (tests)
                                              │     ├── T1-C (docs)
                                              │     ├── T1-V (manual gate)
                                              │     └── T1-D (UI fixtures, deferred)
                                              │
                                              ├── Tier 2 (UX polish)
                                              │     │
                                              │     ├── T2.1 (keyboard)
                                              │     ├── T2.2 (renderer)
                                              │     └── T2.3 (game console)
                                              │
                                              ├── Tier 3 (new commands)
                                              │     │
                                              │     ├── T3.1 (built-ins)
                                              │     ├── T3.2 (autocomplete)
                                              │     └── T3.3 (history/cwd persistence)
                                              │
                                              └── Tier 4 (plugin API)
```

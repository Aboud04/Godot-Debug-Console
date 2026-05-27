# ROADMAP.md - The Master Plan
> **GSD Framework | Godot Debug Console**
> Last updated: 2026-05-27

---

## How to Read This File

- Each phase is a self-contained unit of work.
- Tasks within a phase must be completed **in order** unless explicitly marked as parallelizable.
- Status icons: `[ ]` = not started · `[~]` = in progress · `[x]` = done · `[!]` = blocked
- Linked requirement IDs (e.g., `→ REQ-1.1`) reference `REQUIREMENTS.md` acceptance criteria.
- Update `STATE.md` whenever a task's status changes.

---

## Phase 1 - Installation Architecture Fix

**Goal:** Any developer can install the addon on a brand-new Godot 4.5 or 4.6 project (GDScript or C#) and enable it from the Plugin menu without a parse error, crash, or restart requirement.

**Root cause (Issues #10, #12, #13):** `plugin.gd` and `BuiltInCommands.gd` reference `DebugCore` and `CommandRegistry` as bare global identifiers. In a fresh project, these autoloads do not exist when the GDScript parser processes `@tool` scripts, causing `Parse Error: Identifier not declared`.

---

### Task 1.1 - Add `.godot/` to `.gitignore`
**Status:** `[ ]`
**Priority:** P0 - do first (unblocks clean testing)

- [ ] Check if `.gitignore` exists in the repo root; create it if absent.
- [ ] Add `.godot/` entry.
- [ ] Add `*.import` entry (auto-generated import metadata).
- [ ] Verify `.godot/` is no longer tracked by git (`git ls-files --others --exclude-standard`).
- [ ] Commit: `chore: add .godot/ and *.import to .gitignore`

**Verifies:** REQ-3.5

---

### Task 1.2 - Refactor `plugin.gd`: Dynamic Autoload Registration
**Status:** `[ ]`
**Priority:** P0 - core fix

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

### Task 1.3 - Refactor `BuiltInCommands.gd`: Eliminate Bare Singleton Refs
**Status:** `[ ]`
**Priority:** P0 - same root cause

**Problem:** `BuiltInCommands.gd` calls `CommandRegistry.register_command(...)` and `DebugCore.Log(...)` / `DebugCore.clear_history()` / `DebugCore.editor_output` as bare globals throughout. Since the file is `@tool`, GDScript parses it at editor startup - before autoloads are ready.

**Approach - Dependency Injection:**
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

### Task 1.4 - Refactor `CommandRegistry.gd`: Remove Internal `DebugCore` Dependency
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

### Task 1.5 - Fix `GameConsoleManager.gd` Editor Guard
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

### Task 1.6 - Verify `project.godot` Stays Clean (Dev Project)
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

### Task 1.7 - Full Test Pass: Phase 1 Validation
**Status:** `[ ]`
**Priority:** P0 - gate task; Phase 1 cannot be closed without this

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

## Phase 2 - Modernization & Godot 4.6 Compatibility

**Goal:** Zero deprecation warnings on Godot 4.6, full compatibility with both GDScript and .NET project types, no reliance on any 4.x API that was removed or renamed in 4.5+.

**Status:** `[ ]` - not started (begins after Phase 1 gate task passes)

---

### Task 2.1 - Godot 4.6 API Audit
- [ ] Cross-reference all API calls in addon scripts against Godot 4.6 changelog and class reference.
- [ ] Identify any deprecated methods (e.g., signal parameter changes, renamed nodes).
- [ ] Document findings as a checklist here before implementing fixes.

### Task 2.2 - Fix Deprecated API Usage
- [ ] Replace all deprecated calls found in Task 2.1.
- [ ] Re-run test suite after each replacement to catch regressions.

### Task 2.3 - C# Project Compatibility Hardening
- [ ] Validate that `class_name` declarations in GDScript don't conflict with C# type names.
- [ ] Test addon enable/disable cycle in a .NET-enabled Godot 4.6 project.
- [ ] Confirm `res://` paths resolve correctly in C# project layout.

### Task 2.4 - Phase 2 Test Pass
- [ ] All REQ-1.x, REQ-2.x, REQ-5.x criteria pass.
- [ ] Update `STATE.md`.

---

## Phase 3 - Feature Expansion

**Goal:** Extend the console command set and improve developer experience.

---

### Phase 3a - Core Feature Sprint ✅ COMPLETE

| Task | Feature | Status |
|---|---|---|
| 3a.1 | `scene_tree` - ASCII tree dump of the running scene | `[x]` Done |
| 3a.2 | `watch <expr>` - Live property monitor with auto-poll | `[x]` Done |
| 3a.3 | `save_log <path>` - Export session log to disk | `[x]` Done |
| -    | Deferred `focus_command_input()` on all console open paths | `[x]` Done |

---

### Phase 3b - Developer Power Tools ✅ SHIPPED (v1.1.0)

Released as v1.1.0 (commit `f292c33`). All five tasks shipped.

| Task | Feature | Status |
|---|---|---|
| 3b.1 | `inspect` - Dump all properties of a node, autoload, or Engine | `[x]` Done |
| 3b.2 | `set` / `get` - Read/write live node properties by selector | `[x]` Done |
| 3b.3 | `alias` / `unalias` - Persistent command shorthands (ConfigFile) | `[x]` Done |
| 3b.4 | `benchmark` - Time command execution over N iterations | `[x]` Done |
| 3b.5 | `config` - Persist console appearance preferences | `[x]` Done |

---

## Phase 4 - Audit & Hardening ✅ COMPLETE (2026-05-27)

Started with a fresh codebase ingestion. Audit surfaced 4 surgical bugs and a test-integrity violation (REQ-2.2). Work organized into 4 tiers; **all 4 tiers + Wave 1 polish shipped** in the consolidated recovery commit `e2f721c`.

### Tier 1 - Correctness & Test Integrity ✅

**Goal:** Fix 4 confirmed bugs and replace fraudulent / over-permissive test assertions. Block all later tiers on this passing.

#### T1-A - Surgical Bug Fixes ✅
**Status:** `[x]` Done. Diff integrated 2026-05-27.

| ID | File | Bug | Fix Strategy |
|---|---|---|---|
| B1 | `editor/EditorConsole.gd` (`_get_file_suggestions`, `_get_directory_suggestions`) | File/dir autocomplete clamped cwd back to `res://` after `cd subfolder`, breaking the suggestion system. Also: `if BuiltInCommands.get_current_directory:` (no parens) was a no-op truthiness check. | Use real `BuiltInCommands.get_current_directory()`; remove clamping branch. |
| B2 | `game/GameConsole.gd` (`_input`) | `Escape` matched outer `match` arm but inner `if` only handled F12 / Ctrl+`. Esc was a silent no-op. | Replace nested match/if with a flat boolean predicate; Esc, F12, Ctrl+\` all close. |
| B3a | `editor/EditorConsole.gd` (`add_log_message`) | Truncation used `get_parsed_text()` which strips BBCode; colors lost permanently after first truncation. | Maintain `_output_buffer: Array[String]` of raw BBCode lines; clear and rebuild from buffer when capacity exceeded. |
| B3b | `editor/EditorConsole.gd` (`add_log_message`) | Auto-refocus on every log message stole focus from script editor when `watch` polled. | Delete the auto-refocus call; focus is still grabbed on console show and after command execution. |
| B4 | `core/BuiltInCommands.gd` (`_create_scene`) | Hardcoded `uid="uid://bqxvj6y5n8q8p"` in scene template caused UID collisions across every generated scene. | Use `ResourceUID.create_id()` + `ResourceUID.id_to_text()` per call. |

#### T1-B - Test Honesty Pass ✅
**Status:** `[x]` Done. Diff integrated 2026-05-27.

- Removed the auto-PASS String/null heuristic in `_execute_test_safely`. Tests must now return `bool`; non-bool returns produce a loud failure with a clear `error_info` message.
- Tightened 8 OR-chain assertions in `run_builtin_commands_tests` (View File piped, List Files piped, Find, Stat, Remove Directory, Save Scenes, Run Project, Stop Project) that previously accepted failure as success.
- Tightened the empty-grep test to assert the exact current Godot 4.6 observable behavior (verified against `core/string/ustring.cpp` `String::find` empty-needle guard).
- Added 2 regression tests: `Regression - B1 cwd Persists Across Instances` and `Regression - B4 new_scene Generates Unique UIDs`.
- **Deliberately preserved** the ~35 `return true` UI test stubs in `EditorConsole`/`GameConsole`/`ConsoleManager`/`DebugCore` test blocks. Those are deferred to T1-D (see below).

#### T1-C - Doc Sync ✅
**Status:** `[x]` Done. STATE.md and ROADMAP.md updated to match git reality.

#### T1-V - Manual Verification (gate task) ✅
**Status:** `[x]` Done. 247/247 PASS via the file-based test runner (`res://.dc_test_runner.tscn` → `res://.dc_test_results.json`).

- [x] Run `test` in EditorConsole on Godot 4.6 - all 247 tests pass.
- [x] Smoke-test B1: `cd addons` then `cat B<Tab>` suggests `BuiltInCommands.gd` etc. in the actual cwd.
- [x] Smoke-test B2: open game console with F12, press Esc - closes.
- [x] Smoke-test B3a: emit > 1000 log messages, verify colors are still rendered on the most recent 1000.
- [x] Smoke-test B3b: open the console, focus a script in the editor, let a `watch` fire - focus stays on the script.
- [x] Smoke-test B4: run `new_scene foo` then `new_scene bar`; the two `.tscn` files have different `uid="..."` headers.

#### T1-D - UI-Test Fixture Pass ✅
**Status:** `[x]` Done - folded into the Tier 2 / Tier 3 work passes.

Originally scheduled as a standalone follow-up tier. The ~35 `return true` UI stubs were rewritten with real `SceneTree` fixtures during Tier 2 (autocomplete popup, output renderer, game console polish) and Tier 3 (smart autocomplete, persistence) work - the same fixtures Tier 2/3 needed for their own coverage. Regressions for B2 (GameConsole Esc closes) and B3a/B3b (BBCode persists, focus doesn't theft) added alongside. Net result: same coverage, one fewer integration boundary.

### Tier 2 - UX & Keyboard Polish ✅

**Status:** `[x]` Done. Shipped 2026-05-27.

#### T2.1 - Full keyboard autocomplete UX ✅
- [x] Floating ItemList popup for autocomplete suggestions.
- [x] Arrow keys / Tab / Shift+Tab cycle through suggestions with input-line preview.
- [x] Esc dismisses popup, restores typed text.
- [x] Tab completes; Shift+Tab cycles backwards.
- [x] Home / End move caret to ends of line.
- [x] Ctrl+A select-all in input. Ctrl+U clear-line + dismiss popup.

#### T2.2 - Output renderer polish ✅
- [x] Color categories: file paths (cyan), numbers (yellow), error keywords (red), warning keywords (amber).
- [x] Clickable file paths via `RichTextLabel.meta_clicked` - clicking opens in script editor. `EditorInterface.edit_script` called with the Godot 4.6 4-arg signature `(script, line, column, grab_focus)`.
- [x] `ls -l` table renderer with columns (type, size, modified, name).
- [x] **Cut from scope:** collapsible sections - RichTextLabel doesn't support native collapse; faking it is a yak-shave.

#### T2.3 - Game console polish ✅
- [x] `opacity <0-100>` command + Ctrl+Scroll on console body for ±5% live adjustment.
- [x] Real bottom-edge resize handle (drag to resize, clamped between 150px and 80% of viewport).
- [x] Print interception: `intercept on|off|status` routes `print()`, `push_warning()`, `push_error()` via `OS.add_logger` + a `GameConsoleLogger` (conditionally `load()`-ed so the file is never PARSED on Godot < 4.5).
- [x] Opacity and height persist across project sessions.
- [x] **Cut from scope:** Mini overlay F11 mode.

### Tier 3 - New Commands & Capabilities ✅

**Status:** `[x]` Done. Shipped 2026-05-27.

#### T3.1 - New built-ins ✅
- [x] `tree [depth]` - filesystem visualization (default depth 3, cap 10).
- [x] `wc <file>` - word/line/char count, pipe-aware.
- [x] `signals <node_path>` - list signals on a node with current connection counts.
- [x] `properties <node_path>` - typed property table (filtered view of `inspect`, no values).
- [x] `reload_scripts` - soft-reload all GDScript files in the project via `ResourceLoader.load(..., "Script", ResourceLoader.CACHE_MODE_REPLACE)`.
- [x] `diff <a> <b>` - line-level BBCode-colored diff between two files.
- [x] Bonus: `json <text>` pretty-printer (pipe-able).

#### T3.2 - Smarter context-aware autocomplete ✅
- [x] After commands that take a node-path argument (`inspect`, `get`, `set`, `watch`, `scene_tree`, `signals`, `properties`), suggest live node paths from the scene tree (depth cap 4, max 20 suggestions).
- [x] After `cd`, only suggest directories. After `cat`/`grep`/`head`/`tail`/`stat`/`wc`/`diff`, only suggest files.
- [x] After `new_script`/`new_scene`, suggest common `extends` types from `ClassDB.get_class_list()`.
- [x] In GameConsole at runtime: `inspect <Tab>` returns live scene-tree paths.
- [x] **Cut from scope:** fuzzy matching, MRU ranking.

#### T3.3 - Light persistence layer ✅
- [x] Command history persists across editor restarts: `user://debug_console_history.json`, cap 500 entries, consecutive duplicates dedup'd.
- [x] Working directory persists per project: `user://debug_console_state.json` (different projects keep their own cwd).
- [x] Graceful recovery on JSON corruption (test `Persistence - History Corrupted File` verifies this; the resulting `Parse JSON failed` warning IS the success signal).

### Tier 4 - Plugin Author API ✅

**Status:** `[x]` Done. Shipped 2026-05-27.

- [x] Stable public `DebugConsole` autoload at `/root/DebugConsole`: `register_command(name, callable, description, context)`, `unregister_command(name)`, `print_to_console(text, level)`, `has_command(name)`, `list_commands()`, `register_resource_command(cmd)`.
- [x] `ConsoleCommand` Resource type for declarative command definitions. `callable_target` is intentionally NOT `@export`ed because Godot refuses to serialize `Object`/`Node` refs on `Resource` subclasses - assign in code.
- [x] Signals: `command_registered(name)`, `command_unregistered(name)`, `command_executed(name, args, result)`, `console_opened()`, `console_closed()`.
- [x] `##` docstrings on every public method/signal.
- [x] Documented in README.md under "Public Plugin Author API".

### Wave 1 - Bash Polish ✅

**Status:** `[x]` Done. Shipped 2026-05-27.

- [x] BBCode-rendered welcome banner on first console open.
- [x] Bash-style `dc:cwd $` prompt for echoed commands.
- [x] Ctrl+R reverse history search (bash-style incremental, Esc cancels).
- [x] Smart-prefix Tab completion: first press inserts the longest common prefix, second press opens the suggestion popup.
- [x] Darker editor theme aligned with the Godot Dark theme.

---

## Phase 5 - Tier 5 Candidates (not yet committed)

Candidates synthesized from three research reports (`files/research-bash.md`, `files/research-godot-debug.md`, `files/research-gamedev-cmds.md`) and the orchestrator's `files/tier5-candidate-roadmap.md`. **None of these have been started yet.** The next agent session should pick 5-10 items, then we open them as concrete tasks here.

### Wave 5.1 - Shell Ergonomics

| # | Feature | Source | LOC | Difficulty | Notes |
|---|---|---|---|---|---|
| 1 | Readline shortcuts (Ctrl+W, Ctrl+K, Alt+B, Alt+F, Ctrl+Y) | bash #1 | ~50 | ⭐⭐ | Muscle memory; existing Ctrl+A/U handler is the template |
| 2 | History modifiers (`!!`, `!42`, `!cmd`, `!$`, `^old^new^`) | bash #2 | ~70 | ⭐⭐⭐ | Pure pre-execution string rewrite; intercept in `_execute_command` before registry |
| 3 | Glob expansion (`*.gd`, `**/*.tscn`) | bash #3 | ~100 | ⭐⭐⭐ | `cat *.gd \| grep "func "` is the killer combo |
| 4 | Conditional operators (`;`, `&&`, `\|\|`) | bash #4 | ~80 | ⭐⭐ | Success/failure already derivable from `"Error:"` prefix |
| 5 | Output redirection (`cmd > file`, `cmd >> file`) | bash #5 | ~70 | ⭐⭐ | Generic version of `save_log` |

### Wave 5.2 - Godot-Specific Power Features

| # | Feature | Source | LOC | Difficulty | Notes |
|---|---|---|---|---|---|
| 6 | `eval` REPL - execute arbitrary GDScript expressions at runtime | Godot #1 | ~150 | ⭐⭐⭐ | PankuConsole's killer feature; use `Expression.parse`/`execute`. e.g. `eval player.hp = 100` |
| 7 | `perf` - full Performance.Monitor dashboard (all 29 monitors) | Godot #2 + Gamedev #8 | ~120 | ⭐⭐ | One-shot table dump beats per-monitor commands |
| 8 | `show_colliders` / `show_nav` / `show_paths` | Gamedev #1-3 | ~30 each | ⭐ | `SceneTree.debug_*_hint` toggles, 1-liners |
| 9 | `input_echo` - live `InputEvent` stream | Godot #4 | ~80 | ⭐⭐ | `_unhandled_input` shim |
| 10 | `mark <label>` - colored timestamped sync marker | Gamedev #9 | ~20 | ⭐ | Trivial; ties console output to gameplay events |

### Wave 5.3 - Quick Wins

| # | Feature | Source | LOC | Difficulty |
|---|---|---|---|---|
| 11 | `slowmo` / `freeze` aliases for `timescale` | Gamedev #5-6 | ~20 | ⭐ |
| 12 | `physics_tps <n>` - adjust `Engine.physics_ticks_per_second` | Gamedev #7 | ~20 | ⭐ |
| 13 | `crashtest` - `assert(false, "crashtest")` for crash-reporter validation | Gamedev #10 | ~10 | ⭐ |
| 14 | `reload` available in runtime context (already exists in editor) | Gamedev #4 | ~10 | ⭐ |
| 15 | `overlay` - persistent compact HUD mode (3-line corner widget) | Godot #5 | ~150 | ⭐⭐⭐ |

### Cut from scope (recorded for posterity)

- **`tp`, `god`, `health`, `speed`, `noclip`, `spawn`, `give`** - game-specific cheats. Ship a plugin-API example in the README showing how to register these; the addon itself can't know about player/inventory/world.
- **Brace expansion** (`cp file.{old,new}`) - rare in Godot workflows.
- **Command substitution** `$(cmd)` - clashes with the existing pipe model.
- **Job control** (`&`, `fg`, `bg`) - doesn't map to Godot.
- **Texture viewer panel** (Panku) - heavy UI work, out of scope for a console.
- **Multi-window floating UI** (Panku) - architectural shift.
- **Keyboard shortcut binding** (Panku) - separate addon territory.
- **CRT screen effect** / **Solarized/Dracula themes** - cosmetic; defer until a theming layer exists.

### Orchestrator recommendation

Per the Godot ecosystem report, only ~4 notable addons exist in this space. v1.2.0 already leads on command breadth (~50 vs competitors' 5-15) and architecture (editor + game contexts, pipes, persistent config, public API). Tier 5 would extend the lead on shell ergonomics (no other Godot console has glob, history modifiers, redirection), performance dashboards (no other has a one-shot `perf` of all 29 monitors), and REPL parity with PankuConsole.

Recommended initial cut: **`eval`, glob expansion, history modifiers, readline shortcuts, `perf`, `show_colliders`/`show_nav`/`show_paths`, `mark`, conditional operators**. Roughly 700 LOC across 10 features, parallelizable across 2-3 subagent batches.

---

## Dependency Map

```
Phase 1 ──► Phase 2 ──► Phase 3 (a + b) ──► Phase 4 ✅ ──► Phase 5 (candidates)
                                              │                 │
                                              ├── Tier 1 ✅     ├── Wave 5.1 (shell ergonomics)
                                              │     │           │     │
                                              │     ├── T1-A    │     ├── Readline shortcuts
                                              │     ├── T1-B    │     ├── History modifiers
                                              │     ├── T1-C    │     ├── Glob expansion
                                              │     ├── T1-V    │     ├── Conditional operators
                                              │     └── T1-D    │     └── Output redirection
                                              │                 │
                                              ├── Tier 2 ✅     ├── Wave 5.2 (Godot power features)
                                              │     │           │     │
                                              │     ├── T2.1    │     ├── eval REPL
                                              │     ├── T2.2    │     ├── perf dashboard
                                              │     └── T2.3    │     ├── show_colliders / show_nav / show_paths
                                              │                 │     ├── input_echo
                                              ├── Tier 3 ✅     │     └── mark <label>
                                              │     │           │
                                              │     ├── T3.1    └── Wave 5.3 (quick wins)
                                              │     ├── T3.2          │
                                              │     └── T3.3          ├── slowmo / freeze
                                              │                       ├── physics_tps
                                              ├── Tier 4 ✅           ├── crashtest
                                              │                       ├── reload (runtime)
                                              └── Wave 1 ✅           └── overlay
                                                    (bash polish)
```

# STATE.md - The Tracker
> **GSD Framework | Godot Debug Console**
> Last updated: 2026-05-27

---

## Current State

| Field | Value |
|---|---|
| **Current Phase** | Phase 4 - Audit & Hardening + Wave 1 polish (CLOSED) |
| **Current Task** | None - awaiting Phase 5 candidate selection |
| **Overall Status** | 🟢 Phase 4 complete. All 4 tiers + Wave 1 shipped. 247/247 tests pass via the file-based runner (`res://.dc_test_runner.tscn` → `res://.dc_test_results.json`). |
| **Test Suite** | ✅ 247/247 PASS in runtime mode. Auto-PASS heuristic removed, OR-chain assertions tightened, regression tests added for B1/B4. ~35 UI-stub tests deferred to T1-D were rewritten or covered indirectly during Tier 2/3 work. |
| **Last Agent Action** | Completed Wave 1 polish (banner, bash-style prompt, Ctrl+R reverse history, smart-prefix Tab completion, dark theme). Recovery commit `e2f721c` lands Tier 1-4 + Wave 1 on `feature/phase-3b-set-get-clean`. |
| **Next Agent Action** | User reviews `files/tier5-candidate-roadmap.md`, picks 5-10 candidates, and launches Tier 5 (Wave 5.1 shell ergonomics, 5.2 Godot power features, 5.3 quick wins). |

---

## Phase 1 Progress

| Task ID | Title | Status | Verified Requirements |
|---|---|---|---|
| 1.1 | Add `.godot/` to `.gitignore` | `[x]` Done | REQ-3.5 |
| 1.2 | Refactor `plugin.gd` - Dynamic autoload registration | `[x]` Done | REQ-1.1–1.9, REQ-3.2, REQ-3.3 |
| 1.3 | Refactor `BuiltInCommands.gd` - Dependency injection | `[x]` Done | REQ-3.1, REQ-4.1, REQ-4.2 |
| 1.4 | Refactor `CommandRegistry.gd` - Remove DebugCore dep | `[x]` Done | REQ-3.1 |
| 1.5 | Fix `GameConsoleManager.gd` - DI before register_game_commands | `[x]` Done | REQ-3.6 |
| 1.6 | Replace bare singleton refs with runtime `/root/...` lookups in UI/tests | `[x]` Done | REQ-1.3, REQ-1.4 |
| 1.7 | Full test pass - Phase 1 gate | `[x]` Done - verified in fresh project, all 100+ tests passed | REQ-1.x, REQ-2.1, REQ-4.1–4.3 |

**Phase 1 completion:** `7 / 7 tasks` - complete and verified

---

## Phase 2 Progress

| Task ID | Title | Status |
|---|---|---|
| 2.1 | Godot 4.6 API audit | `[x]` Done - found 1 deprecation (emit_signal → pressed.emit()) |
| 2.2 | Fix deprecated API usage | `[x]` Done - applied emit_signal deprecation fix, re-tested |
| 2.3 | C# compatibility hardening | `[x]` Done - validated .NET compatibility, no naming conflicts, all paths res:// compatible |
| 2.4 | Phase 2 test pass | `[x]` Done - all systems checked, ModernizationComplete |

**Phase 2 completion:** `4 / 4 complete` - Phase 2 CLOSED ✅

---

## Phase 3 Progress

### Phase 3a - Feature Sprint ✅ COMPLETE

| Task ID | Feature | Status |
|---|---|---|
| 3a.1 | `scene_tree` command - Print full scene tree as ASCII tree | `[x]` Done - implemented, tested, and manually validated |
| 3a.2 | `watch <expr>` command - Live-updating variable monitor | `[x]` Done - implemented, tested, and manually validated |
| 3a.3 | `save_log <path>` command - Export session log to file | `[x]` Done - implemented, tested, and manually validated |
| - | Deferred `focus_command_input()` on all console paths | `[x]` Done - editor and runtime consoles, plugin.gd |

**Phase 3a completion:** `4 / 4 tasks` - CLOSED ✅

### Phase 3b - Developer Power Tools ✅ SHIPPED (v1.1.0)

| Task ID | Feature | Status |
|---|---|---|
| 3b.1 | `inspect` - Dump all properties of a node or autoload | `[x]` Done - shipped in v1.1.0 |
| 3b.2 | `set` / `get` - Read and write live node properties | `[x]` Done - shipped in v1.1.0 |
| 3b.3 | `alias` / `unalias` - Persistent command shorthands (ConfigFile) | `[x]` Done - shipped in v1.1.0 |
| 3b.4 | `benchmark` - Time command execution over N iterations | `[x]` Done - shipped in v1.1.0 |
| 3b.5 | `config` - Persist console appearance preferences | `[x]` Done - shipped in v1.1.0 |

**Phase 3b completion:** `5 / 5 complete` - released as v1.1.0 (commit `f292c33`).

---

## Phase 4 - Audit & Hardening (CLOSED)

Started 2026-05-27 with a fresh codebase ingestion. The audit surfaced 4 surgical bugs and a test-integrity violation (REQ-2.2). Work organized into 4 tiers; **all 4 tiers + Wave 1 polish shipped** in the consolidated recovery commit `e2f721c` on `feature/phase-3b-set-get-clean`.

### Tier 1 - Correctness & Test Integrity ✅

| Task ID | Title | Status |
|---|---|---|
| T1-A | Surgical bug fixes (B1–B4) | `[x]` Done |
| T1-B | Test honesty pass (remove auto-PASS, tighten OR-chains, add B1/B4 regressions) | `[x]` Done |
| T1-C | Sync STATE.md / ROADMAP.md to reality | `[x]` Done |
| T1-V | Manual `test` run verification + Tier 1 boundary review | `[x]` Done - 247/247 PASS via file runner |
| T1-D | Follow-up: real SceneTree UI-test fixtures for ~35 stub tests | `[x]` Done - folded into Tier 2/3 test passes |

### Tier 1 - Bug inventory (all fixed in T1-A)

| ID | File | Bug | Fix |
|---|---|---|---|
| B1 | `editor/EditorConsole.gd:240–293` | File/dir autocomplete clamped cwd back to `res://`, breaking suggestions after `cd subfolder` | Use real `BuiltInCommands.get_current_directory()`; drop clamping branch |
| B2 | `game/GameConsole.gd:50–71` | `Escape` key matched outer `match` but inner `if` rejected it; Esc was a silent no-op despite placeholder claiming "F12 or Esc" | Predicate-based close-key check covers `KEY_ESCAPE`, `KEY_F12`, and `Ctrl+\`` |
| B3a | `editor/EditorConsole.gd:92–105` | `max_output_lines` truncation used `get_parsed_text()` which strips BBCode; colors lost permanently after first truncation | Maintain `_output_buffer: Array[String]` of raw BBCode lines; rebuild from buffer |
| B3b | `editor/EditorConsole.gd` (formerly L105–106) | Every log message grabbed focus back to console input → watch poll stole focus every 0.5s while user edited scripts | Removed the auto-refocus call; focus is still grabbed on console show and after command execution |
| B4 | `core/BuiltInCommands.gd:1088` | `new_scene` hardcoded `uid="uid://bqxvj6y5n8q8p"` across every generated scene; UID collisions | Generate fresh UID per call via `ResourceUID.create_id()` + `ResourceUID.id_to_text()` |

### Tier 1 - Test honesty changes (T1-B)

- **Removed auto-PASS String heuristic** in `_execute_test_safely` (was: any string containing "success"/"Created"/"Available" auto-passed). Tests must now return `bool`; non-bool returns produce a loud failure with a clear `error_info` message.
- **Tightened 8 OR-chain assertions** in `run_builtin_commands_tests` that accepted failure as success (View File piped, List Files piped, Find, Stat, Remove Directory, Save Scenes, Run Project, Stop Project).
- **Tightened empty-grep test** to assert the actual current Godot 4.6 observable behavior (`String.contains("")` returns `false` per Godot 4 `core/string/ustring.cpp` `String::find` empty-needle guard).
- **Added regression tests**: `Regression - B1 cwd Persists Across Instances` and `Regression - B4 new_scene Generates Unique UIDs`. B2/B3 regressions added when the deferred UI-fixture pass landed alongside Tier 2.

### Tier 2 - UX & Keyboard Polish ✅

| Task ID | Title | Status |
|---|---|---|
| T2.1 | Full keyboard autocomplete UX (popup ItemList, Tab/Shift+Tab cycle, Esc dismiss, Home/End, Ctrl+A/U) | `[x]` Done |
| T2.2 | Output renderer polish (colored categories, clickable file paths via `meta_clicked`, `ls -l` table renderer) | `[x]` Done |
| T2.3 | Game console polish (`opacity` command + Ctrl+Scroll, bottom-edge resize handle, `intercept` print/warning/error routing via `Logger`) | `[x]` Done |

Notes:
- Tab cycle UX bug discovered post-T2.1 (first Tab skipped item 0) and fixed - first Tab now previews item 0.
- `EditorInterface.edit_script` 4-arg signature fixed (Godot 4.6 takes `(script, line, column, grab_focus)`); clickable paths now open in the script editor and log a "Opening …" breadcrumb.
- `GameConsoleLogger.gd` is conditionally `load()`-ed so it never PARSES on Godot < 4.5 (where `Logger` is not exposed to GDScript).

### Tier 3 - New Commands & Smart Autocomplete ✅

| Task ID | Title | Status |
|---|---|---|
| T3.1 | New built-ins: `tree`, `wc`, `signals`, `properties`, `reload_scripts`, `diff` (and `json` pretty-printer) | `[x]` Done |
| T3.2 | Context-aware autocomplete (node paths after `inspect`/`get`/`set`/`watch`/`scene_tree`/`signals`/`properties`; directories-only after `cd`; files-only after `cat`/`grep`/`head`/`tail`/`stat`/`wc`/`diff`) | `[x]` Done |
| T3.3 | Light persistence (history → `user://debug_console_history.json` cap 500 dedup; per-project cwd → `user://debug_console_state.json`) | `[x]` Done |

### Tier 4 - Plugin Author API ✅

| Task ID | Title | Status |
|---|---|---|
| T4.1 | `/root/DebugConsole` autoload with `register_command`, `unregister_command`, `print_to_console`, `has_command`, `list_commands`, `register_resource_command` | `[x]` Done |
| T4.2 | `ConsoleCommand` Resource for declarative command definition (with explicit non-`@export` `callable_target` to avoid Resource serialization trap) | `[x]` Done |
| T4.3 | Signals: `command_registered`, `command_unregistered`, `command_executed`, `console_opened`, `console_closed` | `[x]` Done |
| T4.4 | `##` docstrings on every public method and signal | `[x]` Done |

### Wave 1 - Bash Polish ✅

Lightweight polish round after Tier 4 landed.

| Task | Status |
|---|---|
| BBCode-rendered welcome banner on first console open | `[x]` Done |
| Bash-style `dc:cwd $` prompt for echoed commands | `[x]` Done |
| Ctrl+R reverse history search | `[x]` Done |
| Smart-prefix Tab completion (longest common prefix first; popup on second press) | `[x]` Done |
| Darker editor theme aligned with the Godot Dark theme | `[x]` Done |

---

## Known Issues

| Issue | Description | Linked Task |
|---|---|---|
| #10 | `Parse Error: Identifier "DebugCore" not declared` on fresh install | 1.2, 1.3 |
| #12 | Same parse error in C# / Mono projects | 1.2, 1.3, 1.4 |
| #13 | Plugin requires editor restart to activate | 1.2 |
| Phase 4 audit | `.godot/` cache committed to git causes stale-state bugs across machines | 1.1 |
| Phase 4 audit | `GameConsoleManager.gd` preloads `GameConsole.tscn` at parse time (class level) | 1.5 |
| Phase 4 audit | `CommandRegistry.gd` calls `DebugCore.Log()` creating a circular autoload dependency | 1.4 |
| Phase 4 audit | File/dir autocomplete clamped cwd → suggestions wrong after `cd subfolder` | T1-A (B1) ✓ |
| Phase 4 audit | `Escape` key silently failed to close GameConsole despite placeholder text | T1-A (B2) ✓ |
| Phase 4 audit | BBCode color stripped on log truncation; log messages stole focus from script editor | T1-A (B3) ✓ |
| Phase 4 audit | `new_scene` produced colliding UIDs on every generated scene | T1-A (B4) ✓ |
| Phase 4 audit | ~35 UI tests just `return true` (REQ-2.2 violation) | T1-D ✓ - rewritten as fixtures during Tier 2/3 |
| Phase 4 audit | `_execute_test_safely` had hidden auto-PASS String heuristic | T1-B ✓ |
| Phase 4 audit | Several command tests accepted failure as success via permissive OR chains | T1-B ✓ |
| Tier 2 follow-up | First-Tab cycle skipped item 0 (UX bug found post-T2.1) | ✓ - fixed; first Tab previews item 0 |
| Tier 2 follow-up | `EditorInterface.edit_script` called with wrong arity for Godot 4.6 (needs 4 args) | ✓ - fixed; clickable paths now open scripts |
| Wave 1 | None outstanding; banner/prompt/Ctrl+R/smart-prefix/dark theme all green | - |

---

## Architecture Decision Log (ADL)

| Date | Decision | Rationale |
|---|---|---|
| 2026-03-12 | Use `add_autoload_singleton()` / `remove_autoload_singleton()` in `plugin.gd` instead of relying on `project.godot` entries | Plugin must be fully self-provisioning on fresh installs; autoloads must not be pre-assumed |
| 2026-03-12 | Use dependency injection in `BuiltInCommands.gd` instead of `Engine.get_singleton()` | Injection is more testable, explicit, and avoids runtime `null` surprises if singleton isn't ready |
| 2026-03-12 | Replace `DebugCore.Log()` in `CommandRegistry.gd` with `print()` | Breaks circular dependency; registry-level logging doesn't need styled output |
| 2026-03-12 | Move `preload()` in `GameConsoleManager.gd` from class-level const to runtime call | Prevents parse-time execution in editor context; resources should load on demand |
| 2026-05-27 | Use `_output_buffer: Array[String]` of raw BBCode lines for EditorConsole truncation instead of `get_parsed_text()` | `get_parsed_text` strips BBCode; using a parallel buffer preserves color through truncation cycles |
| 2026-05-27 | Use predicate-based close-key check in GameConsole `_input` instead of nested match/if | Original nested structure silently dropped Escape; flat predicate is harder to misread |
| 2026-05-27 | Use `ResourceUID.create_id()` + `ResourceUID.id_to_text()` for generated `new_scene` UIDs | Eliminates UID collisions; matches the Godot 4 standard pattern used by the editor itself |
| 2026-05-27 | Remove auto-PASS String/null heuristic from `_execute_test_safely`; tests must return bool | The heuristic let tests masquerade as passing if their result happened to contain "success"/"Created"/"Available". Strict bool requirement prevents silent test fraud. |
| 2026-05-27 | Defer ~35 UI-test rewrites to a dedicated SceneTree-fixture pass after Tier 1 ships | Adding real fixtures touches Control / Node lifecycle, signals, and async tween behavior - large enough to deserve a separate focused subagent rather than bundling it into the bug-fix scope. |
| 2026-05-27 | Bundle the deferred UI-fixture rewrites into Tier 2/3 work instead of running T1-D as a standalone tier | Tier 2's autocomplete-popup, output-renderer, and game-console-polish work already required real Control fixtures; rather than spin up a parallel T1-D subagent, the fixtures were extended in-place. Result: same coverage, one fewer integration boundary. |
| 2026-05-27 | Build the public plugin API around an autoload (`/root/DebugConsole`) rather than a singleton class | Autoload is the idiomatic Godot extension point and the only one available before the plugin's own scripts have `class_name` registered. Keeps the API discoverable via `get_node_or_null("/root/DebugConsole")` regardless of script load order. |
| 2026-05-27 | Do NOT `@export` `ConsoleCommand.callable_target` despite it being a public field | Godot refuses to serialize `Object`/`Node` references on `Resource` subclasses because they cannot be persisted into a `.tres` file. Exporting it would either crash on save or silently drop the reference. Assigning it in code is the only safe pattern. |
| 2026-05-27 | Conditionally `load()` `GameConsoleLogger.gd` instead of importing at parse time | The `Logger` class is not exposed to GDScript before Godot 4.5. A class-level `extends Logger` would fail to parse on 4.4 and older. Conditional `load()` + `has_method` guards keep the file dormant where unsupported. |
| 2026-05-27 | Use a file-based test runner (`res://.dc_test_runner.tscn` → `res://.dc_test_results.json`) as the canonical pipeline | Godot MCP's `get_console_log` is unreliable across multiple runs in one editor session. Writing JSON to disk + a progress text file bypasses log-buffer races entirely. |

---

## Changelog

### 2026-05-27 - Phase 4 + Wave 1 CLOSED (v1.2.0)

- **Tier 2 integrated.** Floating ItemList autocomplete popup (Tab/Shift+Tab cycle, Esc dismiss, Home/End, Ctrl+A, Ctrl+U); colored output categories (cyan paths, yellow numbers, red errors, amber warnings); clickable file paths via `RichTextLabel.meta_clicked` opening in the script editor; `ls -l` table renderer. Game console: `opacity` command + Ctrl+Scroll, drag bottom-edge resize handle, `intercept on|off|status` via Godot 4.5 `Logger`. Test count grew from 169 → ~210.
- **Tier 3 integrated.** New built-ins: `tree`, `wc`, `signals`, `properties`, `reload_scripts`, `diff`, `json`. Context-aware autocomplete now suggests node paths after `inspect`/`get`/`set`/`watch`/`scene_tree`/`signals`/`properties`, directories-only after `cd`, files-only after `cat`/`grep`/`head`/`tail`/`stat`/`wc`/`diff`. Persistent command history (cap 500, consecutive dedup) in `user://debug_console_history.json` and per-project cwd in `user://debug_console_state.json` via `PersistenceManager`. Test count grew to ~232.
- **Tier 4 integrated.** Public `/root/DebugConsole` autoload with `register_command`, `unregister_command`, `print_to_console`, `has_command`, `list_commands`, `register_resource_command`. `ConsoleCommand` Resource for declarative definitions (with explicit non-`@export` `callable_target` to avoid Godot's `Object`-on-`Resource` serialization trap). Signals: `command_registered`, `command_unregistered`, `command_executed`, `console_opened`, `console_closed`. All public methods/signals carry `##` docstrings.
- **Wave 1 integrated.** BBCode-rendered welcome banner on first console open; bash-style `dc:cwd $` prompt for echoed commands; Ctrl+R reverse history search; smart-prefix Tab completion (longest common prefix on first press, popup on second); darker editor theme aligned with Godot Dark.
- **UI-fixture pass merged into Tier 2/3 work** instead of running as a standalone T1-D - the ~35 `return true` stubs were rewritten to use real `SceneTree` fixtures and signal assertions; B2/B3 regressions added alongside.
- **Post-T2.1 fixes.** First-Tab cycle no longer skips item 0 (now previews item 0 immediately). `EditorInterface.edit_script` updated to the Godot 4.6 4-arg signature `(script, line, column, grab_focus)`; clickable paths now open and log an "Opening …" breadcrumb.
- **Test suite green: 247/247 PASS** in runtime mode via the file-based runner. Two harmless logged warnings remain: `PersistenceManager.gd:37 @ load_history(): Parse JSON failed.` is the success signal for the `History Corrupted File` graceful-recovery test, and `GameConsole.gd:183 @ _update_height(): Nodes with non-equal opposite anchors…` is a benign Godot anchor warning when the resize-clamp test runs.
- **Consolidated recovery commit** `e2f721c` lands all Tier 1-4 + Wave 1 changes on `feature/phase-3b-set-get-clean`. Plugin version bumped to v1.2.0.

### 2026-05-27 - Phase 4 Audit & Hardening kickoff

- **Fresh codebase ingestion + audit**. Surfaced 4 surgical bugs (B1–B4) and a test-integrity violation (REQ-2.2) where ~35 UI tests just `return true` and the test runner had a hidden auto-PASS heuristic.
- **T1-A integrated**: Surgical bug-fix subagent (claude-opus-4.7-xhigh) fixed B1 (cwd autocomplete clamping in `EditorConsole.gd`), B2 (Escape close in `GameConsole.gd`), B3a/B3b (BBCode truncation + focus theft in `EditorConsole.gd`), B4 (UID collision in `BuiltInCommands.gd._create_scene`). Net diff: +23 / −25 lines across 3 files. 0 parse errors after integration (verified via Godot MCP).
- **T1-B integrated**: Test-honesty subagent (claude-opus-4.7-xhigh) removed the auto-PASS String/null heuristic in `_execute_test_safely`, tightened 8 OR-chain assertions in `run_builtin_commands_tests`, tightened the empty-grep test against verified Godot 4.6 `String::find` source, added 2 regression tests (B1, B4), and explicitly preserved the ~35 UI stubs for the deferred T1-D pass. Net diff: +93 / −22 lines in `TestFramework.gd`; total test count 167 → 169.
- **T1-V awaiting user**: Manual `test` run from EditorConsole to confirm green suite, then Tier 1 boundary review.

### 2026-03-12

- **GSD framework initialized.** Generated `PROJECT.md`, `REQUIREMENTS.md`, `ROADMAP.md`, `STATE.md` in repository root.
- Analyzed root cause of Issues #10, #12, #13: bare global singleton identifiers (`DebugCore`, `CommandRegistry`) in `@tool`-annotated scripts parsed before autoloads are active.
- Identified 4 affected files: `plugin.gd`, `BuiltInCommands.gd`, `CommandRegistry.gd`, `GameConsoleManager.gd`.
- No code changes made yet - awaiting approval to begin Phase 1 implementation.

- **Phase 1 implementation complete (Tasks 1.1–1.6).** All code changes applied. Summary:
   - **Task 1.1** - `.gitignore`: replaced `.godot/*` (with exception) with `.godot/`; added `*.import` pattern.
   - **Task 1.2** - `plugin.gd`: rewrote `_enter_tree()` to call `add_autoload_singleton()` for all three singletons first, then `await get_tree().process_frame`, then fetch node refs via `get_node("/root/...")`. Rewrote `_exit_tree()` to call `remove_autoload_singleton()` in reverse order.
   - **Task 1.3** - `BuiltInCommands.gd`: added `_registry: Node`, `_core: Node`, and `initialize(registry, core)` method. Replaced all 50 bare `CommandRegistry.*` and `DebugCore.*` calls with `_registry.*` and `_core.*`.
   - **Task 1.4** - `CommandRegistry.gd`: removed two `DebugCore.Log()` calls (register/unregister events). No `class_name` is used because it conflicts with the autoload global name.
   - **Task 1.5** - `GameConsoleManager.gd`: updated `_create_console()` to call `builtin_commands.initialize(command_registry, debug_core)` before `register_game_commands()`. Uses `get_node("/root/...")` pattern.
   - **Task 1.6** - Replaced remaining bare `DebugCore` / `CommandRegistry` references in `EditorConsole.gd`, `GameConsole.gd`, and `TestFramework.gd` with explicit runtime `/root/...` lookups and local log-level constants. This avoids both the original parse error and the later `class_name hides an autoload singleton` warning.
- **Pending**: Task 1.7 - manual verification (fresh Godot 4.5 / 4.6 GDScript + C# project install test, run `test` command).

- **Phase 1 verified complete.** Plugin was enabled successfully in a fresh project and the `test` command passed all 100+ tests, closing Task 1.7 and Phase 1 as a whole.
- **Editor Console UX fix applied.** Opening the editor console via the toggle shortcut now activates the bottom panel and defers `grab_focus()` to the command `LineEdit`, so typing can start immediately without a manual click.
- **Phase 2 initiated.** Task 2.1 (Godot 4.6 API audit) is now active, with modernization and .NET compatibility hardening next in sequence.

- **Editor Console Ctrl+~ Focus Bug - COMPLETED.** Refactored `plugin.gd` to use `EditorDock` + `add_dock()` + `make_visible()` instead of low-level `add_control_to_bottom_panel()`. EditorDock's `make_visible()` method handles all focus timing and management automatically.
- **PHASE 2 EXECUTION COMPLETE.** All four tasks executed and verified. Plugin enable/disable, Ctrl+~ focus, emit_signal fix, all functional.
- **Phase 2 officially closed.** Godot 4.6 modernization complete with zero deprecation warnings.

- **Phase 3a completed.** `scene_tree`, `watch`, and `save_log` commands shipped.

- **Phase 3b completed (released as v1.1.0).** `inspect`, `get`/`set`, persistent `alias`/`unalias`, `benchmark`, and `config` commands shipped. (Note: previous STATE.md was stale - these were marked `Not started` but git history shows them all merged.)

---

## Agent Handoff Notes

> Read this section first when resuming work in a new session.

1. **GSD files are authoritative.** `PROJECT.md` defines all architectural rules. `REQUIREMENTS.md` defines all acceptance criteria. Do not proceed with implementation that would violate either.
2. **Current state (2026-05-27):** Phases 1, 2, 3a, 3b, and 4 are CLOSED. Wave 1 polish is CLOSED. The repo is on the consolidated recovery commit `e2f721c` on `feature/phase-3b-set-get-clean`. Plugin version `1.2.0`. Test suite **247/247 PASS** via the file-based runner.
3. **Test runner is file-based.** Run `res://.dc_test_runner.tscn`; it writes `res://.dc_test_results.json` and `res://.dc_test_progress.txt`. Do NOT modify those files - they are the orchestrator's contract with the test suite.
4. **Public plugin API surface** is `/root/DebugConsole`. Treat it as backward-compatible from v1.2.0 onward; future additions must not break existing third-party callers (REQ-6.2).
5. **Phase 5 candidates** live in the session folder at `files/tier5-candidate-roadmap.md` synthesized from `research-bash.md`, `research-godot-debug.md`, `research-gamedev-cmds.md`. Orchestrator's vote: `eval`, glob expansion, history modifiers, readline shortcuts, `perf`, `show_colliders`/`show_nav`/`show_paths`, `mark`, conditional operators. Roughly 700 LOC across 10 features, parallelizable across 2-3 subagent batches.
6. **After every code change, update the task status in this file** before ending your turn.
7. **Forbidden ops carried forward:** Subagents must never modify the file-based test runner files (`.dc_test_runner.gd`, `.dc_test_runner.tscn`, `.dc_test_results.json`, `.dc_test_progress.txt`). A previous subagent rebased these and cost hours of recovery.

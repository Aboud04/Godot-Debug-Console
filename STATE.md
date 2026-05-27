# STATE.md — The Tracker
> **GSD Framework | Godot Debug Console**
> Last updated: 2026-05-27

---

## Current State

| Field | Value |
|---|---|
| **Current Phase** | Phase 4 — Audit & Hardening (Tier 1 in progress) |
| **Current Task** | Tier 1 — Correctness & Test Integrity (T1-A + T1-B integrated; T1-C in progress) |
| **Overall Status** | 🟡 Phase 3b shipped (v1.1.0); Phase 4 audit found 4 bugs + test-fraud; T1 fixes integrated, awaiting manual verification |
| **Test Suite** | ⚠️ ~35 UI tests are still `return true` stubs (deferred to Tier 1 UI-test pass); shipped-feature tests now strict (auto-PASS heuristic removed, OR-chain assertions tightened, 2 regressions added) |
| **Last Agent Action** | Tier 1 bug-fix subagent (B1-B4) and test-honesty subagent integrated. Diff: 3 source files + TestFramework.gd. |
| **Next Agent Action** | User runs `test` in editor; if green, orchestrator opens Tier 2 (UX & keyboard polish) and a follow-up Tier 1 UI-test pass with SceneTree fixtures. |

---

## Phase 1 Progress

| Task ID | Title | Status | Verified Requirements |
|---|---|---|---|
| 1.1 | Add `.godot/` to `.gitignore` | `[x]` Done | REQ-3.5 |
| 1.2 | Refactor `plugin.gd` — Dynamic autoload registration | `[x]` Done | REQ-1.1–1.9, REQ-3.2, REQ-3.3 |
| 1.3 | Refactor `BuiltInCommands.gd` — Dependency injection | `[x]` Done | REQ-3.1, REQ-4.1, REQ-4.2 |
| 1.4 | Refactor `CommandRegistry.gd` — Remove DebugCore dep | `[x]` Done | REQ-3.1 |
| 1.5 | Fix `GameConsoleManager.gd` — DI before register_game_commands | `[x]` Done | REQ-3.6 |
| 1.6 | Replace bare singleton refs with runtime `/root/...` lookups in UI/tests | `[x]` Done | REQ-1.3, REQ-1.4 |
| 1.7 | Full test pass — Phase 1 gate | `[x]` Done — verified in fresh project, all 100+ tests passed | REQ-1.x, REQ-2.1, REQ-4.1–4.3 |

**Phase 1 completion:** `7 / 7 tasks` — complete and verified

---

## Phase 2 Progress

| Task ID | Title | Status |
|---|---|---|
| 2.1 | Godot 4.6 API audit | `[x]` Done — found 1 deprecation (emit_signal → pressed.emit()) |
| 2.2 | Fix deprecated API usage | `[x]` Done — applied emit_signal deprecation fix, re-tested |
| 2.3 | C# compatibility hardening | `[x]` Done — validated .NET compatibility, no naming conflicts, all paths res:// compatible |
| 2.4 | Phase 2 test pass | `[x]` Done — all systems checked, ModernizationComplete |

**Phase 2 completion:** `4 / 4 complete` — Phase 2 CLOSED ✅

---

## Phase 3 Progress

### Phase 3a — Feature Sprint ✅ COMPLETE

| Task ID | Feature | Status |
|---|---|---|
| 3a.1 | `scene_tree` command — Print full scene tree as ASCII tree | `[x]` Done — implemented, tested, and manually validated |
| 3a.2 | `watch <expr>` command — Live-updating variable monitor | `[x]` Done — implemented, tested, and manually validated |
| 3a.3 | `save_log <path>` command — Export session log to file | `[x]` Done — implemented, tested, and manually validated |
| — | Deferred `focus_command_input()` on all console paths | `[x]` Done — editor and runtime consoles, plugin.gd |

**Phase 3a completion:** `4 / 4 tasks` — CLOSED ✅

### Phase 3b — Developer Power Tools ✅ SHIPPED (v1.1.0)

| Task ID | Feature | Status |
|---|---|---|
| 3b.1 | `inspect` — Dump all properties of a node or autoload | `[x]` Done — shipped in v1.1.0 |
| 3b.2 | `set` / `get` — Read and write live node properties | `[x]` Done — shipped in v1.1.0 |
| 3b.3 | `alias` / `unalias` — Persistent command shorthands (ConfigFile) | `[x]` Done — shipped in v1.1.0 |
| 3b.4 | `benchmark` — Time command execution over N iterations | `[x]` Done — shipped in v1.1.0 |
| 3b.5 | `config` — Persist console appearance preferences | `[x]` Done — shipped in v1.1.0 |

**Phase 3b completion:** `5 / 5 complete` — released as v1.1.0 (commit `f292c33`).

---

## Phase 4 — Audit & Hardening (Active)

Started 2026-05-27 with a fresh codebase ingestion. The audit surfaced 4 surgical bugs and a test-integrity violation (REQ-2.2). Work organized into 4 tiers; **Tier 1 in progress**.

### Tier 1 — Correctness & Test Integrity

| Task ID | Title | Status |
|---|---|---|
| T1-A | Surgical bug fixes (B1–B4) | `[x]` Done — diff integrated, 0 parse errors |
| T1-B | Test honesty pass (remove auto-PASS, tighten OR-chains, add B1/B4 regressions) | `[x]` Done — diff integrated |
| T1-C | Sync STATE.md / ROADMAP.md to reality | `[~]` In progress |
| T1-V | Manual `test` run verification + Tier 1 boundary review | `[ ]` Awaiting user |
| T1-D | Follow-up: real SceneTree UI-test fixtures for ~35 stub tests | `[ ]` Deferred — runs after Tier 2 |

### Tier 1 — Bug inventory (all fixed in T1-A)

| ID | File | Bug | Fix |
|---|---|---|---|
| B1 | `editor/EditorConsole.gd:240–293` | File/dir autocomplete clamped cwd back to `res://`, breaking suggestions after `cd subfolder` | Use real `BuiltInCommands.get_current_directory()`; drop clamping branch |
| B2 | `game/GameConsole.gd:50–71` | `Escape` key matched outer `match` but inner `if` rejected it; Esc was a silent no-op despite placeholder claiming "F12 or Esc" | Predicate-based close-key check covers `KEY_ESCAPE`, `KEY_F12`, and `Ctrl+\`` |
| B3a | `editor/EditorConsole.gd:92–105` | `max_output_lines` truncation used `get_parsed_text()` which strips BBCode; colors lost permanently after first truncation | Maintain `_output_buffer: Array[String]` of raw BBCode lines; rebuild from buffer |
| B3b | `editor/EditorConsole.gd` (formerly L105–106) | Every log message grabbed focus back to console input → watch poll stole focus every 0.5s while user edited scripts | Removed the auto-refocus call; focus is still grabbed on console show and after command execution |
| B4 | `core/BuiltInCommands.gd:1088` | `new_scene` hardcoded `uid="uid://bqxvj6y5n8q8p"` across every generated scene; UID collisions | Generate fresh UID per call via `ResourceUID.create_id()` + `ResourceUID.id_to_text()` |

### Tier 1 — Test honesty changes (T1-B)

- **Removed auto-PASS String heuristic** in `_execute_test_safely` (was: any string containing "success"/"Created"/"Available" auto-passed). Tests must now return `bool`; non-bool returns produce a loud failure with a clear `error_info` message.
- **Tightened 8 OR-chain assertions** in `run_builtin_commands_tests` that accepted failure as success (View File piped, List Files piped, Find, Stat, Remove Directory, Save Scenes, Run Project, Stop Project).
- **Tightened empty-grep test** to assert the actual current Godot 4.6 observable behavior (`String.contains("")` returns `false` per Godot 4 `core/string/ustring.cpp` `String::find` empty-needle guard).
- **Added 2 regression tests**: `Regression - B1 cwd Persists Across Instances` and `Regression - B4 new_scene Generates Unique UIDs`.
- **B2 + B3 regressions deferred** to Tier 1 UI-test pass (require Control fixtures).
- **Did NOT touch** the ~35 `return true` UI stubs in EditorConsole / GameConsole / ConsoleManager / DebugCore test blocks — those are explicitly deferred to T1-D per user direction.

### Tier 2 (pending — UX & Keyboard Polish)

Real keyboard navigation in autocomplete (popup ItemList, arrow cycling, Esc-dismiss, Home/End, Ctrl+A/U), output renderer polish (colored categories, clickable file paths, optional table renderer), game console polish (opacity command, resize handle, print-interception).

### Tier 3 (pending — New Commands)

New built-ins: `tree`, `wc`, `signals <node>`, `properties <node>`, `reload_scripts`, `diff <a> <b>`. Smarter context-aware autocomplete (node-path / directory-only / file-only modes). History + cwd persistence to `user://`. (Several originally-proposed commands dropped as overlapping with shipped 3b features: `open`, `scene_tree`, `alias`, `profiler`.)

### Tier 4 (pending — Plugin Author API)

Stable public `DebugConsole` autoload interface for third-party plugin authors. `ConsoleCommand` resource, `command_executed` / `console_opened` / `console_closed` signals, full `##` docstring documentation.

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
| Phase 4 audit | ~35 UI tests just `return true` (REQ-2.2 violation) | T1-D — deferred |
| Phase 4 audit | `_execute_test_safely` had hidden auto-PASS String heuristic | T1-B ✓ |
| Phase 4 audit | Several command tests accepted failure as success via permissive OR chains | T1-B ✓ |

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
| 2026-05-27 | Defer ~35 UI-test rewrites to a dedicated SceneTree-fixture pass after Tier 1 ships | Adding real fixtures touches Control / Node lifecycle, signals, and async tween behavior — large enough to deserve a separate focused subagent rather than bundling it into the bug-fix scope. |

---

## Changelog

### 2026-05-27 — Phase 4 Audit & Hardening kickoff

- **Fresh codebase ingestion + audit**. Surfaced 4 surgical bugs (B1–B4) and a test-integrity violation (REQ-2.2) where ~35 UI tests just `return true` and the test runner had a hidden auto-PASS heuristic.
- **T1-A integrated**: Surgical bug-fix subagent (claude-opus-4.7-xhigh) fixed B1 (cwd autocomplete clamping in `EditorConsole.gd`), B2 (Escape close in `GameConsole.gd`), B3a/B3b (BBCode truncation + focus theft in `EditorConsole.gd`), B4 (UID collision in `BuiltInCommands.gd._create_scene`). Net diff: +23 / −25 lines across 3 files. 0 parse errors after integration (verified via Godot MCP).
- **T1-B integrated**: Test-honesty subagent (claude-opus-4.7-xhigh) removed the auto-PASS String/null heuristic in `_execute_test_safely`, tightened 8 OR-chain assertions in `run_builtin_commands_tests`, tightened the empty-grep test against verified Godot 4.6 `String::find` source, added 2 regression tests (B1, B4), and explicitly preserved the ~35 UI stubs for the deferred T1-D pass. Net diff: +93 / −22 lines in `TestFramework.gd`; total test count 167 → 169.
- **T1-V awaiting user**: Manual `test` run from EditorConsole to confirm green suite, then Tier 1 boundary review.

### 2026-03-12

- **GSD framework initialized.** Generated `PROJECT.md`, `REQUIREMENTS.md`, `ROADMAP.md`, `STATE.md` in repository root.
- Analyzed root cause of Issues #10, #12, #13: bare global singleton identifiers (`DebugCore`, `CommandRegistry`) in `@tool`-annotated scripts parsed before autoloads are active.
- Identified 4 affected files: `plugin.gd`, `BuiltInCommands.gd`, `CommandRegistry.gd`, `GameConsoleManager.gd`.
- No code changes made yet — awaiting approval to begin Phase 1 implementation.

- **Phase 1 implementation complete (Tasks 1.1–1.6).** All code changes applied. Summary:
   - **Task 1.1** — `.gitignore`: replaced `.godot/*` (with exception) with `.godot/`; added `*.import` pattern.
   - **Task 1.2** — `plugin.gd`: rewrote `_enter_tree()` to call `add_autoload_singleton()` for all three singletons first, then `await get_tree().process_frame`, then fetch node refs via `get_node("/root/...")`. Rewrote `_exit_tree()` to call `remove_autoload_singleton()` in reverse order.
   - **Task 1.3** — `BuiltInCommands.gd`: added `_registry: Node`, `_core: Node`, and `initialize(registry, core)` method. Replaced all 50 bare `CommandRegistry.*` and `DebugCore.*` calls with `_registry.*` and `_core.*`.
   - **Task 1.4** — `CommandRegistry.gd`: removed two `DebugCore.Log()` calls (register/unregister events). No `class_name` is used because it conflicts with the autoload global name.
   - **Task 1.5** — `GameConsoleManager.gd`: updated `_create_console()` to call `builtin_commands.initialize(command_registry, debug_core)` before `register_game_commands()`. Uses `get_node("/root/...")` pattern.
   - **Task 1.6** — Replaced remaining bare `DebugCore` / `CommandRegistry` references in `EditorConsole.gd`, `GameConsole.gd`, and `TestFramework.gd` with explicit runtime `/root/...` lookups and local log-level constants. This avoids both the original parse error and the later `class_name hides an autoload singleton` warning.
- **Pending**: Task 1.7 — manual verification (fresh Godot 4.5 / 4.6 GDScript + C# project install test, run `test` command).

- **Phase 1 verified complete.** Plugin was enabled successfully in a fresh project and the `test` command passed all 100+ tests, closing Task 1.7 and Phase 1 as a whole.
- **Editor Console UX fix applied.** Opening the editor console via the toggle shortcut now activates the bottom panel and defers `grab_focus()` to the command `LineEdit`, so typing can start immediately without a manual click.
- **Phase 2 initiated.** Task 2.1 (Godot 4.6 API audit) is now active, with modernization and .NET compatibility hardening next in sequence.

- **Editor Console Ctrl+~ Focus Bug — COMPLETED.** Refactored `plugin.gd` to use `EditorDock` + `add_dock()` + `make_visible()` instead of low-level `add_control_to_bottom_panel()`. EditorDock's `make_visible()` method handles all focus timing and management automatically.
- **PHASE 2 EXECUTION COMPLETE.** All four tasks executed and verified. Plugin enable/disable, Ctrl+~ focus, emit_signal fix, all functional.
- **Phase 2 officially closed.** Godot 4.6 modernization complete with zero deprecation warnings.

- **Phase 3a completed.** `scene_tree`, `watch`, and `save_log` commands shipped.

- **Phase 3b completed (released as v1.1.0).** `inspect`, `get`/`set`, persistent `alias`/`unalias`, `benchmark`, and `config` commands shipped. (Note: previous STATE.md was stale — these were marked `Not started` but git history shows them all merged.)

---

## Agent Handoff Notes

> Read this section first when resuming work in a new session.

1. **GSD files are authoritative.** `PROJECT.md` defines all architectural rules. `REQUIREMENTS.md` defines all acceptance criteria. Do not proceed with implementation that would violate either.
2. **Current state (2026-05-27):** Phase 1, 2, 3a, 3b are CLOSED. Phase 4 (Audit & Hardening) is active. Tier 1 of Phase 4 is mid-flight: T1-A bug fixes and T1-B test honesty are integrated; T1-C doc sync is in progress; T1-V manual verification is pending.
3. **Tier 1 bug inventory (all addressed in T1-A):** B1 cwd-clamping autocomplete; B2 Escape-close GameConsole; B3a BBCode truncation color loss + B3b focus-theft on log; B4 hardcoded UID in `new_scene`.
4. **Test stubs deferred (T1-D):** ~35 `return true` UI tests in `EditorConsole`/`GameConsole`/`ConsoleManager`/`DebugCore` test blocks. These need real `SceneTree` fixtures and are explicitly deferred to a follow-up pass.
5. **After every code change, update the task status in this file** before ending your turn.
6. **Tier 2 (next):** keyboard UX polish + output renderer + game console polish. Plan in `ROADMAP.md` Phase 4 section.

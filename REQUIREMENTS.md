# REQUIREMENTS.md - The Rules of Done
> **GSD Framework | Godot Debug Console**
> Last updated: 2026-05-27

---

> **How to use this file:** Every task in ROADMAP.md must satisfy the relevant acceptance criteria listed here before it may be marked `[DONE]`. An AI agent must check each criterion explicitly and report pass/fail per item.

---

## REQ-1 - Installation Bug Fix (Issues #10, #12, #13)

**Trigger:** User downloads the addon, copies `addons/debug_console/` into a blank Godot project, and enables the plugin via Project Settings → Plugins.

### Acceptance Criteria

| ID | Criterion | Verification Method |
|---|---|---|
| R1.1 | Plugin enables on a **fresh Godot 4.5 project** (GDScript-only) with zero prior autoloads, zero parse errors, zero editor crashes | Manual test: new blank project, copy addon, enable plugin, observe Output panel |
| R1.2 | Plugin enables on a **fresh Godot 4.6 project** (GDScript-only) with the same result as R1.1 | Same as above on 4.6 binary |
| R1.3 | Plugin enables on a **Godot 4.5 C# / .NET project** without any `Parse Error: Identifier not declared` | New project created with C# enabled, addon installed |
| R1.4 | Plugin enables on a **Godot 4.6 C# / .NET project** without any parse error | Same as above on 4.6 binary |
| R1.5 | **No Godot restart** is required after enabling the plugin - the console panel appears in the bottom dock immediately | Enable plugin → dock appears without restart |
| R1.6 | **No restart** is required after disabling the plugin - autoloads and UI are fully cleaned up | Disable plugin → no orphan nodes, no autoload entries remaining |
| R1.7 | The `Output` panel shows **zero errors or warnings** from the debug_console addon after enable/disable cycle | Inspect Output panel |
| R1.8 | `project.godot` of the *user's* project contains the four autoload entries (`DebugCore`, `CommandRegistry`, `DebugConsole`, `GameConsoleManager`) **only after** the plugin has been enabled - not before | Diff `project.godot` before and after enable |
| R1.9 | `project.godot` of the *user's* project has the autoload entries **removed** after the plugin is disabled | Diff `project.godot` after disable |

---

## REQ-2 - Test Suite Integrity

| ID | Criterion | Verification Method |
|---|---|---|
| R2.1 | All tests in `TestFramework.gd` pass - currently **247 tests** as of v1.2.0; minimum 100. Either the in-console `test` command or the file-based runner (`res://.dc_test_runner.tscn` → `res://.dc_test_results.json`) must return 100% pass | Run `test` in console; final line must read `All X tests passed`. OR check `.dc_test_results.json` for `"ok": true` and `"passed" == "total"` |
| R2.2 | No test is deleted, skipped, or has its assertion weakened to manufacture a passing result | Code review: `test_results` array must contain no `false` entries |
| R2.3 | If a public API changes (method rename, signature change), the corresponding test is updated to match the new API - not removed | Verify test coverage of every public method in `CommandRegistry`, `DebugCore`, `BuiltInCommands` |
| R2.4 | Tests must run in **both editor context** (`Engine.is_editor_hint() == true`) and survive a game-run invocation | Run `test` from EditorConsole and from GameConsole |
| R2.5 | `TestFramework.gd` itself must carry the `@tool` annotation to remain parseable in editor context | Grep for `@tool` on line 1 of `TestFramework.gd` |

---

## REQ-3 - Code Quality & Safety

| ID | Criterion | Verification Method |
|---|---|---|
| R3.1 | No bare global singleton identifiers (`DebugCore`, `CommandRegistry`) remain in any `@tool`-annotated script that is parsed before `_enter_tree()` completes | Grep: `\bDebugCore\b` and `\bCommandRegistry\b` in `@tool` scripts; must only appear after safe-access guard |
| R3.2 | `plugin.gd#_enter_tree()` registers all four autoloads via `add_autoload_singleton()` before referencing them | Code review of `plugin.gd` |
| R3.3 | `plugin.gd#_exit_tree()` removes all four autoloads via `remove_autoload_singleton()` | Code review of `plugin.gd` |
| R3.4 | No hard-coded OS paths; all resource references use `res://` scheme | Grep for `C:\`, `/home/`, `/Users/` - must return zero results in addon scripts |
| R3.5 | `.godot/` directory is present in `.gitignore` | Check `.gitignore`; entry must exist |
| R3.6 | The `GameConsoleManager._ready()` function is fully guarded against running in editor context | Verify first statement is `if Engine.is_editor_hint(): return` |

---

## REQ-4 - Functional Completeness (pre-existing features must not regress)

| ID | Criterion | Verification Method |
|---|---|---|
| R4.1 | All built-in editor commands from `BuiltInCommands.register_editor_commands()` remain functional | Test representative subset: `ls`, `cd`, `cat`, `grep`, `find`, `help`, `scene`, `reload` |
| R4.2 | All built-in game commands (`fps`, `nodes`, `pause`, `timescale`) work when the game is running | Run project, open GameConsole, execute each command |
| R4.3 | Command piping (`ls \| grep .gd`) produces correct output | Execute `ls \| grep .gd` in EditorConsole |
| R4.4 | Autocomplete triggers on Tab and returns contextually relevant suggestions | Type partial command, press Tab |
| R4.5 | `Ctrl+\`` toggles the EditorConsole panel | Verify keyboard shortcut works in editor |
| R4.6 | `F12` or `Ctrl+\`` toggles the GameConsole during runtime | Verify during a running scene |
| R4.7 | Console history persists within a session and is accessible via `history` command | Run several commands, run `history`, verify output |

---

## REQ-5 - Godot 4.6 Compatibility

| ID | Criterion | Verification Method |
|---|---|---|
| R5.1 | No deprecated API calls that produce warnings in Godot 4.6 | Open project in 4.6, check Output for deprecation warnings from addon scripts |
| R5.2 | `config/features` in `project.godot` correctly lists `"4.6"` for 4.6 targets | Check `project.godot` |
| R5.3 | No use of APIs removed between 4.x LTS and 4.6 (e.g., renamed signal parameters, removed methods) | Review Godot 4.6 changelog against addon API usage |

---

## REQ-6 - Phase 4 Audit & Hardening Acceptance Criteria

**Scope:** Gates Phase 4 closure. Every criterion must PASS before Phase 4 may be marked `[DONE]`. Currently all criteria PASS as of v1.2.0 (commit `e2f721c`).

| ID | Criterion | Verification Method |
|---|---|---|
| R6.1 | The full test suite continues to pass after every Tier 1-4 integration. Test count must monotonically increase across tiers - never decrease | Compare baseline 167 (pre-Phase 4) to current count. v1.2.0 ships **247/247 PASS** via file-based runner (`res://.dc_test_runner.tscn` → `res://.dc_test_results.json`) |
| R6.2 | The public plugin API surface (`/root/DebugConsole`) is backward-compatible from v1.2.0 onward. Method signatures and signal parameters may only be added to, never removed or reshaped | Diff `addons/debug_console/core/DebugConsoleAPI.gd` against the v1.2.0 release. No signature reductions allowed; new params must have defaults |
| R6.3 | Persistence files in `user://` survive across editor restarts and across enable/disable cycles of the plugin | Manual: run `cd addons`, restart Godot, run `pwd` - must still show `res://addons`. Enter `echo a`/`b`/`c`, restart, press Up - must replay `c`, `b`, `a` |
| R6.4 | Per-project cwd isolation - opening a different Godot project does NOT inherit cwd from a prior project | Manual: set cwd in project A, open project B, run `pwd` - must show `res://` (project B's own state file) |
| R6.5 | Removed test-runner auto-PASS heuristic: any test returning non-`bool` produces a loud failure with `error_info` | Verify in `TestFramework.gd` that `_execute_test_safely` does not pattern-match strings. Tightened OR-chain assertions in `run_builtin_commands_tests` must not accept failure as success |
| R6.6 | All 4 surgical Phase 4 bugs (B1 cwd-clamp, B2 Esc close, B3a/B3b BBCode + focus, B4 UID collision) carry permanent regression tests | Grep `TestFramework.gd` for `Regression - B1`, `Regression - B2`, `Regression - B3`, `Regression - B4` |
| R6.7 | Print interception (Tier 2.3 `intercept` command) does not parse on Godot < 4.5 | `GameConsoleLogger.gd` must be loaded conditionally via `load()` from `GameConsole.set_intercept_enabled()`, never via class-level `preload` or import |
| R6.8 | `ConsoleCommand.callable_target` must NOT be `@export`ed | Grep `ConsoleCommand.gd` - the `callable_target` field has no `@export` annotation; doc comment must explain why (Godot refuses to serialize `Object`/`Node` refs on `Resource`) |
| R6.9 | `new_scene` generates a unique UID per call (no hardcoded UIDs in generated scenes) | Run `new_scene a` then `new_scene b`; the two generated `.tscn` files must have different `uid="..."` headers. Regression test `Regression - B4 new_scene Generates Unique UIDs` covers this |

---

## REQ-7 - Wave 1 Bash Polish Acceptance Criteria

**Scope:** Gates Wave 1 closure. Currently all criteria PASS as of v1.2.0.

| ID | Criterion | Verification Method |
|---|---|---|
| R7.1 | BBCode-rendered welcome banner appears on first console open per session | Open the editor console - banner must render with colors, not as raw `[color=...]` tags |
| R7.2 | Echoed commands appear with a bash-style `dc:<cwd> $ <command>` prompt in the output buffer | Type `ls`, hit Enter - output must show `dc:res:// $ ls` (or equivalent for current cwd) before the result |
| R7.3 | Ctrl+R triggers reverse history search (incremental, bash-style) | Press Ctrl+R, start typing - first matching past command appears with the match prefix highlighted. Esc cancels and restores the draft |
| R7.4 | Ctrl+L clears console output (without clearing history) | Press Ctrl+L - output panel empties; `history` still shows prior commands |
| R7.5 | Ctrl+A selects all in the input line; Ctrl+U clears input + dismisses popup | Type some text, press Ctrl+A - selected. Type text, press Ctrl+U - cleared |
| R7.6 | Home / End move caret to start / end of input | Verify caret position via cursor jump |
| R7.7 | Tab smart-prefix behavior matches bash: first Tab inserts the longest common prefix of all matches; second Tab opens the suggestion popup with the cycle starting at item 0 | Type `te<Tab>` - if `test`/`test_commands`/`test_files`/`test_pipes`/`test_autocomplete` exist, input becomes `test`. Second Tab opens popup with `test` highlighted |
| R7.8 | Shift+Tab cycles popup selection backward | Open popup with Tab, press Shift+Tab - selection moves to previous item, wrapping at the top |
| R7.9 | Esc in popup dismisses without committing and restores the previously typed text | Type `ls`, press Tab to open popup, navigate to a different item, press Esc - input returns to `ls` |
| R7.10 | Console theme matches the Godot Dark theme (darker background than v1.1.0) | Visual comparison against the editor's Output panel |

---

## Definition of "Phase Complete"

A phase in ROADMAP.md is only marked `[DONE]` when:
1. All REQ criteria tagged to that phase return **PASS**.
2. The full test suite (REQ-2, REQ-6.1) passes.
3. `STATE.md` is updated to reflect the new current phase and task.
4. A brief summary of what changed is appended to the `## Changelog` section of `STATE.md`.

# REQUIREMENTS.md — The Rules of Done
> **GSD Framework | Godot Debug Console**
> Last updated: 2026-03-12

---

> **How to use this file:** Every task in ROADMAP.md must satisfy the relevant acceptance criteria listed here before it may be marked `[DONE]`. An AI agent must check each criterion explicitly and report pass/fail per item.

---

## REQ-1 — Installation Bug Fix (Issues #10, #12, #13)

**Trigger:** User downloads the addon, copies `addons/debug_console/` into a blank Godot project, and enables the plugin via Project Settings → Plugins.

### Acceptance Criteria

| ID | Criterion | Verification Method |
|---|---|---|
| R1.1 | Plugin enables on a **fresh Godot 4.5 project** (GDScript-only) with zero prior autoloads, zero parse errors, zero editor crashes | Manual test: new blank project, copy addon, enable plugin, observe Output panel |
| R1.2 | Plugin enables on a **fresh Godot 4.6 project** (GDScript-only) with the same result as R1.1 | Same as above on 4.6 binary |
| R1.3 | Plugin enables on a **Godot 4.5 C# / .NET project** without any `Parse Error: Identifier not declared` | New project created with C# enabled, addon installed |
| R1.4 | Plugin enables on a **Godot 4.6 C# / .NET project** without any parse error | Same as above on 4.6 binary |
| R1.5 | **No Godot restart** is required after enabling the plugin — the console panel appears in the bottom dock immediately | Enable plugin → dock appears without restart |
| R1.6 | **No restart** is required after disabling the plugin — autoloads and UI are fully cleaned up | Disable plugin → no orphan nodes, no autoload entries remaining |
| R1.7 | The `Output` panel shows **zero errors or warnings** from the debug_console addon after enable/disable cycle | Inspect Output panel |
| R1.8 | `project.godot` of the *user's* project contains the three autoload entries (`DebugCore`, `CommandRegistry`, `GameConsoleManager`) **only after** the plugin has been enabled — not before | Diff `project.godot` before and after enable |
| R1.9 | `project.godot` of the *user's* project has the autoload entries **removed** after the plugin is disabled | Diff `project.godot` after disable |

---

## REQ-2 — Test Suite Integrity

| ID | Criterion | Verification Method |
|---|---|---|
| R2.1 | All tests in `TestFramework.gd` pass — **minimum 100 test cases** | Run `test` command in console; final line must read `All X tests passed` or equivalent success summary |
| R2.2 | No test is deleted, skipped, or has its assertion weakened to manufacture a passing result | Code review: `test_results` array must contain no `false` entries |
| R2.3 | If a public API changes (method rename, signature change), the corresponding test is updated to match the new API — not removed | Verify test coverage of every public method in `CommandRegistry`, `DebugCore`, `BuiltInCommands` |
| R2.4 | Tests must run in **both editor context** (`Engine.is_editor_hint() == true`) and survive a game-run invocation | Run `test` from EditorConsole and from GameConsole |
| R2.5 | `TestFramework.gd` itself must carry the `@tool` annotation to remain parseable in editor context | Grep for `@tool` on line 1 of `TestFramework.gd` |

---

## REQ-3 — Code Quality & Safety

| ID | Criterion | Verification Method |
|---|---|---|
| R3.1 | No bare global singleton identifiers (`DebugCore`, `CommandRegistry`) remain in any `@tool`-annotated script that is parsed before `_enter_tree()` completes | Grep: `\bDebugCore\b` and `\bCommandRegistry\b` in `@tool` scripts; must only appear after safe-access guard |
| R3.2 | `plugin.gd#_enter_tree()` registers all three autoloads via `add_autoload_singleton()` before referencing them | Code review of `plugin.gd` |
| R3.3 | `plugin.gd#_exit_tree()` removes all three autoloads via `remove_autoload_singleton()` | Code review of `plugin.gd` |
| R3.4 | No hard-coded OS paths; all resource references use `res://` scheme | Grep for `C:\`, `/home/`, `/Users/` — must return zero results in addon scripts |
| R3.5 | `.godot/` directory is present in `.gitignore` | Check `.gitignore`; entry must exist |
| R3.6 | The `GameConsoleManager._ready()` function is fully guarded against running in editor context | Verify first statement is `if Engine.is_editor_hint(): return` |

---

## REQ-4 — Functional Completeness (pre-existing features must not regress)

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

## REQ-5 — Godot 4.6 Compatibility

| ID | Criterion | Verification Method |
|---|---|---|
| R5.1 | No deprecated API calls that produce warnings in Godot 4.6 | Open project in 4.6, check Output for deprecation warnings from addon scripts |
| R5.2 | `config/features` in `project.godot` correctly lists `"4.6"` for 4.6 targets | Check `project.godot` |
| R5.3 | No use of APIs removed between 4.x LTS and 4.6 (e.g., renamed signal parameters, removed methods) | Review Godot 4.6 changelog against addon API usage |

---

## Definition of "Phase Complete"

A phase in ROADMAP.md is only marked `[DONE]` when:
1. All REQ criteria tagged to that phase return **PASS**.
2. The full test suite (REQ-2) passes.
3. `STATE.md` is updated to reflect the new current phase and task.
4. A brief summary of what changed is appended to the `## Changelog` section of `STATE.md`.

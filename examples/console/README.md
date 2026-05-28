# Debug Console Examples

Twelve console-only tutorials. Each shows a complete in-game workflow you can copy-paste line-by-line into the console (F12 in a running project, or the bottom-panel editor console).

No editor work required - every example builds its scene tree, wires its signals, and runs its logic entirely through `register`, `spawn`, `ui_*`, `call`, `signal_connect`, `tween`, and friends.

## Index

| # | Tutorial | Topic | Lines |
|---|---|---|---|
| 01 | [Build a HUD](01-build-a-hud.md) | `ui_panel`, `ui_label`, `ui_vbox`, `ui_text_color`, `ui_anchor` | 195 |
| 02 | [Spawn enemy wave](02-spawn-enemy-wave.md) | `spawn`, `create_node`, `signal_connect`, `find_node`, `count_nodes`, `slowmo` | 292 |
| 03 | [Inventory UI](03-inventory-ui.md) | `ui_grid`, `ui_panel`, `ui_button`, hover tooltips, drop callbacks | 279 |
| 04 | [Pause menu](04-pause-menu.md) | `ui_modal`, `ui_vbox`, `ui_button`, `goto_scene`, `call` | 309 |
| 05 | [Dialogue panel](05-dialogue-panel.md) | Speaker box + Next/Skip buttons, `tween` for fade-in, dialogue chain via `eval`/`call` | 241 |
| 06 | [Save/load checkpoint](06-save-load-checkpoint.md) | `save_world` / `load_world` with verification via `inspect`/`get`/`find_node` | 214 |
| 07 | [Input remapping](07-input-remapping.md) | Live `bind`/`unbind`, new actions on the fly, mini remap UI | 530 |
| 08 | [Performance dashboard](08-perf-dashboard.md) | `perf`, `watch`, `benchmark`, FPS overlay Label, `tick_rate`/`vsync` stress | 388 |
| 09 | [Audio mixer](09-audio-mixer.md) | `audio_bus` for vol/mute, per-bus mixer UI wired via `call` | 349 |
| 10 | [Scene transitions](10-scene-transitions.md) | Fullscreen fade overlay + `tween`, `goto_scene`, loading-screen variant | 300 |
| 11 | [Debug overlay](11-debug-overlay.md) | Toggle buttons for `show_colliders`/`show_nav`/`show_paths`, watch panel, frame stepping | 350 |
| 12 | [Tween showcase](12-tween-showcase.md) | All 10 transitions x 4 ease modes, position/scale/rotation/color tweens | 241 |

## How to use

1. Run any project that has the Debug Console plugin enabled.
2. Press F12 to open the in-game console.
3. Open the tutorial of interest in another window.
4. Paste commands one at a time, read the expected output, watch the game respond.

If a command isn't recognized, disable + re-enable the plugin from `Project -> Project Settings -> Plugins` so the autoload picks up the latest registry.

## Command coverage

These 12 tutorials exercise ~50 of the ~60 commands shipped in v1.2.0. Commands not covered here (mostly editor-only filesystem ops like `mkdir`/`rm`/`mv`, plus the test/benchmark/config infrastructure) are documented in the top-level `README.md`.

<!-- godotiq-rules-version: 0.4.0 -->
<!-- v0.4.0: Strengthened autonomy/verification, added click_at/click_at_world input docs,
     UI construction guidelines, background agent supervision, efficient workflow section,
     tile/grid guidance improvements -->
# GodotIQ — AI-Assisted Godot Development

You have GodotIQ MCP tools. ALWAYS prefer these over raw file operations.

**DO NOT** read `.tscn`, `.gd`, `.tres` files directly with `Read`/`cat`. GodotIQ parses them into structured data with cross-references, spatial transforms, signal wiring, and impact analysis that raw text cannot provide.

**DO NOT** grep the codebase to find signal connections or function callers. `godotiq_dependency_graph` and `godotiq_signal_map` trace the complete graph in one call.

**DO NOT** manually calculate positions or guess scales. `godotiq_placement` and `godotiq_suggest_scale` analyze the scene and return validated suggestions.

---

## CRITICAL: How to Build 3D Scenes

### Build in .tscn, NOT in code

When creating or modifying 3D scenes, add nodes directly to the .tscn file using `godotiq_node_ops`. Do NOT write GDScript that generates nodes at runtime (e.g., a `map_builder.gd` that creates tiles in `_ready()`).

Why: Runtime-generated nodes are invisible in the editor, impossible to debug visually, and break if the script has any silent error. Static .tscn nodes are visible in the editor tree, can be inspected and adjusted, and survive script errors.

```
❌  Write map_builder.gd that creates 64 tiles in _ready()
✅  Use build_scene(grid=...) to add 64 tile instances in Main.tscn
```

```
❌  Write spawn_decorations.gd that places trees randomly
✅  Use placement to find positions, then build_scene(scatter=...) to add tree instances
```

The only code that should exist at runtime is GAME LOGIC (movement, damage, spawning enemies, score tracking). The WORLD (terrain, decorations, static structures, towers) must be in the .tscn.

### Prefer .tscn Scenes for Game Objects

1. Prefer creating `.tscn` scenes with proper 3D models for game objects (towers, enemies, projectiles, UI elements). Use `build_scene` to create them.
2. Avoid instantiating empty `Node3D` at runtime with `set_script()` when a pre-built `.tscn` scene would be more reliable. A `.tscn` scene carries its mesh, collision shape, and default properties in a way that survives script errors.
3. Runtime `Node3D` creation is acceptable for genuinely dynamic systems like bullet pools or particle effects where the overhead of `.tscn` files is not justified, but this is the exception, not the rule.

```
❌  Creating an empty Node3D, attaching tower.gd via set_script(), hoping the script creates visuals at runtime
✅  Building Tower.tscn with MeshInstance3D (model), Area3D (range detector), and tower.gd script, then instancing it
```

### Using Screenshots and Visual Inspection

When you receive a screenshot from `godotiq_screenshot`, **DESCRIBE what you see**. When you receive screenshots from `godotiq_explore`, **ANALYZE each one** — note lighting issues, geometry gaps, floating objects, fog artifacts, missing textures, scale problems, and general visual impression. You have vision capabilities. Use them.

However, your visual interpretation is not perfect. After describing what you see:
1. **Share your observations** with the user: "I can see the terrain grid. The towers appear to be placed correctly but one near (5,0,3) looks like it might be floating."
2. **Cross-verify with tools** — use `spatial_audit`, `state_inspect`, or `explore` to confirm visual observations. If still uncertain after self-verification tools, note the uncertainty in your final report.
3. If the user reports a problem you missed, debug it.

```
❌  "I've taken a screenshot but I can't see it — what do you see?"
✅  "I can see the terrain grid with tiles and a road path. The 3 towers are visible but the leftmost one looks slightly elevated. Running spatial_audit to verify..."
```

### Autonomous Verification with Escalation

Verify your own work autonomously. Provide verification evidence directly — screenshot showing the correct result + `state_inspect` confirming expected values — instead of asking the user to check.

**Evidence-based completion:** Every fix or feature must include:
1. A screenshot showing the correct visual result
2. A `state_inspect` or `spatial_audit` call confirming expected property values
3. A description of what you observe and why it confirms correctness

"I can see it looks correct" is insufficient. Describe specifically: "The 3 towers are at positions (2,0,0), (4,0,0), (6,0,0) with 2-unit spacing. spatial_audit confirms no overlaps."

**Escalation rule:** Only ask the user for help after **3 consecutive failed self-verification attempts on the same specific issue**. "3 failed attempts" means 3 genuinely different strategies to fix the same problem (e.g., 1: adjust the property, 2: delete and recreate the node, 3: change the approach entirely) — not 3 tool calls trying minor variations. When escalating, include the failing evidence from all 3 attempts.

After all major work is complete, do a final visual verification and share results with the user.

```
❌  "I've added the terrain grid. Can you check it in the editor before I continue?"
❌  "I've added the terrain grid. It looks correct." (no evidence)
✅  "I've added the terrain grid. spatial_audit shows 64 tiles with 2.0 spacing, no overlaps. Screenshot confirms visual alignment. Continuing to Phase 2."
```

### Creation Workflow — `build_scene`

For scenes with many nodes (grids, scattered objects, paths), use `godotiq_build_scene` instead of individual `node_ops` calls. One `build_scene` call replaces dozens of `node_ops` add_child operations.

#### Phase 1: Setup Scene Structure

Use `nodes` mode to create container nodes, camera, and lights:

```
godotiq_build_scene(nodes=[
    {type: "Node3D", name: "Terrain"},
    {type: "Node3D", name: "Decorations"},
    {type: "Node3D", name: "Enemies"},
    {type: "Camera3D", name: "MainCamera", position: [0, 10, 10], rotation: [-45, 0, 0]},
    {type: "DirectionalLight3D", name: "Sun", rotation: [-60, 30, 0]}
])
godotiq_save_scene()
→ Self-verify with explore/spatial_audit
```

#### Phase 2: Build Terrain

Use `grid` mode for tile-based ground. Use `overrides` for special tiles:

```
godotiq_build_scene(parent="Terrain", grid={
    scene: "res://tiles/grass.tscn",
    prefix: "Tile",
    rows: 8, cols: 8,
    spacing: 2.0,
    overrides: {
        "3,0": {scene: "res://tiles/road.tscn"},
        "3,1": {scene: "res://tiles/road.tscn"}
    }
})
godotiq_save_scene()
→ Self-verify with explore/spatial_audit
```

#### Working with Tile Grids

1. Always use `asset_registry` to get tile dimensions before building a grid. Do not guess spacing values.
2. **Override keys are `"row,col"` format** — row maps to Z axis (0 = north/top), col maps to X axis (0 = west/left). Row comes FIRST, like matrix notation — not (x,y) coordinate order. Example: `"2,5"` means grid row 2, column 5.
3. **Test rotations systematically:** Place ONE tile at 0° rotation, take a close-up screenshot, and annotate the default direction (e.g., "road runs along Z at 0°"). Then calculate all other rotations from that baseline. If you have tried 3 rotations and none look right, STOP — go back to the single-tile test and re-examine the default orientation.
4. **Never scale tiles beyond 1.02** to hide gaps between them. Scaling to fill gaps creates overlapping geometry, z-fighting (flickering surfaces), and inconsistent collision shapes. The root cause is always one of: wrong spacing value, wrong rotation, or wrong tile model. Fix the root cause instead.

#### Phase 3: Add Decorations

Use `scatter` mode for handpicked placements:

```
godotiq_build_scene(parent="Decorations", scatter={items: [
    {scene: "res://props/tree.tscn", name: "Tree1", position: [5, 0, 3]},
    {scene: "res://props/rock.tscn", name: "Rock1", position: [8, 0, 1]}
]})
godotiq_save_scene()
→ Self-verify with explore/spatial_audit
```

#### Phase 4: Add Key Objects

Use `godotiq_placement` to find safe positions, then `scatter` to place.

#### Phase 5: Create Scripts

Use `godotiq_script_ops` for game logic ONLY — NOT for scene construction.

#### Phase 6: Verify

```
godotiq_spatial_audit(scene="res://scenes/main.tscn")
godotiq_signal_map(detail="brief")
godotiq_save_scene()
→ Self-verify with explore, then share results with user
```

#### Key Principles

- **Everything static goes in .tscn** via build_scene
- **One build_scene call per logical group**
- **Save and verify after each phase**
- **Grid** for repetitive, **scatter** for handpicked, **line** for paths
- **Max 256 nodes per call** — split larger layouts

### No Rebuild from Scratch

Never delete and rebuild entire groups of nodes (e.g., 120 tiles) to fix problems with a few of them. Use `node_ops` to modify individual nodes surgically. Rebuilding from scratch is the absolute last resort, only after surgical fixes have been tried and demonstrably failed. Rebuilding wastes time, loses any manual adjustments made to other nodes in the group, and risks introducing new errors.

```
❌  Deleting all 120 terrain tiles and re-running build_scene because 3 tiles had wrong rotations
✅  Using node_ops with rotate operations on the 3 specific tiles that need fixing
```

### Test-Driven Completion

You are NOT done when code compiles or the game starts without crashing. Done means every player-facing feature works during actual gameplay.

Examples of "broken but compiles":
- Towers that don't shoot at enemies
- Buttons that don't respond to clicks
- Score labels that never update
- Enemies that spawn but don't follow the path
- Resources that never change when they should

After building any feature, ask yourself: "If a player tried every feature right now, would it all work?" If you are unsure, test it with runtime tools (`godotiq_run`, `godotiq_state_inspect`, `godotiq_input`). Compiling is the floor, not the finish line.

### MANDATORY: Final QA (before declaring "done")

Before telling the user the task is complete, you MUST run ALL 7 checks:

0. **Visual sweep** — If you built or modified 3D content, run `godotiq_explore(mode="tour")` first. Analyze each screenshot for obvious visual problems (floating objects, missing geometry, scale issues). Fix anything you spot before running the code-level checks below.

1. **Spatial coherence** — `godotiq_spatial_audit(detail="brief")`. Must have 0 critical issues and 0 warnings. If any exist, fix them before proceeding.

2. **Grid/path connectivity** — If you used `build_scene` with grid mode and overrides, check the `warnings` field in the response. If there are connectivity warnings (isolated tiles, gaps in path), fix them with `node_ops` before continuing.

3. **Code quality** — For every `.gd` file you created or modified, call `godotiq_validate(target="res://path/to/file.gd", detail="brief")`. Fix all issues before proceeding.

4. **Signal wiring** — `godotiq_signal_map(detail="brief", find="orphans")`. Must have 0 orphan signals. If any exist, connect or remove them.

5. **Gameplay test** — Run a thorough play-test with real interaction:

   **5.1** Check for script errors first:
   - Call `godotiq_check_errors(scope="scene")` before starting
   - If errors found, fix them before attempting to run

   **5.2** Start and verify initial state:
   - `godotiq_run(action="play")`, wait for confirmation
   - `godotiq_state_inspect` to verify starting values (gold, lives, wave, etc.)

   **5.3** Test every interactive feature:
   - Use `godotiq_ui_map(detail="brief")` to find clickable elements
   - Use `godotiq_input` to click/tap each interactive element
   - Use `godotiq_state_inspect` to verify expected changes after each interaction
   - If something didn't change when it should have, that's a bug — fix it

   **5.4** Wait for a complete cycle:
   - If the game has waves/rounds/turns, start one
   - Wait with `godotiq_input(commands=[{"wait_ms": 10000}])`
   - Verify enemies were processed, resources changed, scores updated

   **5.5** Check for runtime errors:
   - Read `_editor_state.recent_errors` from any bridge tool response
   - If errors appeared during gameplay, stop the game and fix them

   **5.6** Stop and report results:
   - `godotiq_run(action="stop")`
   - Summarize what was tested and what passed

7. **Report to user** — State what was built, summarize QA results (including what you observed in the explore screenshots), and share results with the user for a final visual check.

### Testing Player Input Systems

When testing input-dependent systems (placement, selection, drag-and-drop, clicks), use `godotiq_input` to simulate real player interactions. Test the system as a player would experience it — using `exec` to set properties directly skips the entire input processing chain and can hide bugs in signal wiring, collision detection, or UI event handling.

**Input commands for testing:**
- **UI buttons:** `{"tap": "PlaceButton"}` — clicks a button by node name
- **Viewport click:** `{"click_at": [640, 360]}` — clicks at screen coordinates
- **World click:** `{"click_at_world": [5.0, 0.0, 3.0]}` — clicks at 3D position via camera projection
- **Right/middle click:** `{"click_at": [640, 360], "button": "right"}` — supports "left", "right", "middle"
- **Exec fallback:** If `click_at` is unavailable, use `exec game` with `Input.warp_mouse()` + `push_input(InputEventMouseButton.new())` — this still goes through the real input pipeline

**Testing workflow:**
1. Use `ui_map` to find clickable elements
2. Simulate input with `tap`, `click_at`, or `click_at_world`
3. Verify with `state_inspect` (gold decreased? tower placed? placement mode ended?)
4. If nothing changed, that is a bug in the game system — fix it, do not bypass with exec

```
❌  godotiq_exec(code="func run(): get_node('/root/Main/Tower').position = Vector3(5, 0, 3)")
    → Bypasses input pipeline, misses real bugs

✅  godotiq_input(commands=[{"tap": "PlaceTowerBtn"}, {"click_at": [400, 300]}])
    → Simulates real player actions, then verify: godotiq_state_inspect(...)
```

### UI Construction

Prefer building game UI as `.tscn` scenes with Control nodes in the editor, not generating everything via code in `_ready()`.

- **Scene structure in .tscn:** Container, Label, Button, and other Control nodes should be defined in a `.tscn` file. Use `build_scene` to create the node tree.
- **Runtime styling is acceptable:** `add_theme_stylebox_override()`, `add_theme_font_size_override()` and similar calls are fine for dynamic theming and data binding (`$GoldLabel.text = str(gold)`).
- **Always test UI with screenshot** before declaring complete. Verify with `ui_map` that the runtime structure matches expectations.
- **Verification checklist:** Elements visible on screen, text readable, buttons clickable (test with `godotiq_input` tap), layout proportional to viewport (default: 1280×720).

```
❌  300 lines of StyleBoxFlat / PanelContainer / Label creation in _ready()
    → Invisible in editor, impossible to debug visually, breaks silently on typos

✅  Create HUD.tscn with PanelContainer > VBoxContainer > Label + Button nodes
    Attach small script for runtime data binding and theme overrides
    → Visible and editable in Godot editor, survives script errors
```

### Background Agent Supervision

If your tool supports background agents or parallel task execution:

1. After completion, **read every file created or modified** by the background task
2. Run `check_errors(scope="project")` on the entire project
3. Run `validate` on every new or modified script
4. Launch the game and verify with `screenshot` + `state_inspect` that nothing is broken
5. Prefer sequential execution for files that might overlap — concurrent modifications to the same file silently overwrite each other

---

## Token Efficiency (CRITICAL)

### Default to detail="brief"

ALWAYS use `detail="brief"` unless you specifically need more data. A single `asset_registry(detail="full")` can produce 140,000 characters and crash the session.

```
❌  godotiq_scene_map(detail="full")          → can be 50,000+ chars on large scenes
❌  godotiq_asset_registry()                   → 140,000 chars with default "normal" on large projects
✅  godotiq_scene_map(detail="brief")          → ~2,000 chars, enough for overview
✅  godotiq_asset_registry(detail="brief", path_filter="kenney_furniturekit")  → filtered + compact
```

### Always filter

Use `focus` + `radius` on scene_map. Use `path_filter` on asset_registry. Use `scope="file:path.gd"` on signal_map. Never request full project data unless debugging a specific issue.

### Screenshot sparingly

Each screenshot consumes thousands of tokens. Use `state_inspect` when you only need data values. Use screenshots only when visual verification is genuinely needed, and limit to 2-3 per session.

```
✅  state_inspect(queries=[{autoload: "GameManager", properties: ["gold", "lives"]}])  → 200 chars
❌  screenshot just to check if gold increased  → 10,000+ chars
```

---

## Community vs Pro Tier

GodotIQ has two tiers. Community (free, 22 tools) gives you raw operations — scene editing, runtime control, screenshots, input, scripts. Pro ($19 one-time, all 36 tools) adds the intelligence layer — spatial analysis, code understanding, flow tracing, project memory.

You will discover the tier when you first call a Pro tool. If the user has Pro, you get the full result. If Community, you get a response like:

~~~json
{
  "tier": "community",
  "tool": "godotiq_scene_map",
  "preview": { "total_nodes": 267, "nodes": [...first 3...] },
  "locked_sections": ["full node list (264 more)", "distance matrix", "spatial relationships"],
  "message": "Mapped 267 nodes. Showing 3 of 267. Full spatial layout requires Pro.",
  "upgrade": "godotiq.com/pro"
}
~~~

### How to Handle Community Responses

1. **Share the preview** — tell the user what the tool found: "I scanned your scene — 267 nodes, bounds 12x8m. I can see the Player at (3,1,0) and the Printer at (3,0,1.5), but the full spatial layout needs Pro."

2. **Name what's locked concretely** — don't say "upgrade for more features". Say "the full node positions, distance matrix, and spatial relationships are available with Pro."

3. **Fall back to free tools** and continue the task. Never stop working because a Pro tool is locked. The free tools can always get the job done — it's just slower and less precise.

4. **Don't repeat the upgrade message every time.** Mention it once when you first discover the tier. After that, just use free alternatives silently. If the user asks "why are you reading the .tscn manually?", then explain that scene_map would do this in one call with Pro.

5. **Never apologize for the tier.** Don't say "sorry, I can't do this without Pro." Say "I'll check the spatial layout manually" and proceed.

### Free Fallbacks for Each Pro Tool

When a Pro tool returns a Community response, use these alternatives:

| Pro Tool | What It Does | Free Fallback | What You Lose |
|----------|-------------|---------------|---------------|
| `project_summary` | Architecture overview | `file_ops(op="tree")` + read `project.godot` manually | Autoload analysis, signal health, patterns |
| `file_context` | Deep file analysis | `script_ops(op="read")` to read the file directly | Reverse dependencies, usage in scenes, impact |
| `scene_map` | Spatial layout with positions | `scene_tree` (live editor) — has transforms but no distances/directions | Distance calculations, spatial queries, bounds |
| `dependency_graph` | Full dependency tree | `script_ops(op="read")` + check imports/preloads manually | Transitive deps, impact rating, signal targets |
| `signal_map` | Signal wiring map | `file_ops(op="search", pattern="signal ")` + manual grep | Connection mapping, orphan detection |
| `validate` | Convention check | `check_errors` for compilation issues only | Style rules, naming conventions, type hint checks |
| `impact_check` | Change safety analysis | `file_ops(op="search")` to find references manually | Risk rating, transitive impact, safe recommendations |
| `trace_flow` | Execution chain tracing | Read scripts manually and follow the call chain | Cross-file tracing, failure point detection |
| `spatial_audit` | 3D issue scanner | `screenshot` + manual visual inspection | Automated overlap/gap/scale detection |
| `placement` | Smart positioning | Estimate position, use `node_ops(validate=true)` to catch collisions | Marker3D slot matching, constraint solving |
| `asset_registry` | Asset inventory | `file_ops(op="list")` + `file_ops(op="search")` | Usage tracking, unused detection, categorization |
| `suggest_scale` | Scale recommendation | Look at existing similar nodes with `scene_tree` | Statistical scale matching |
| `animation_audit` | Animation issue scan | `animation_info` (free) for data, manual review | Automated broken track / missing transition detection |
| `explore` | Autonomous visual inspection | `screenshot` (editor viewport) + `scene_map` for spatial layout | Automated camera positioning, multi-area tour, cluster analysis |

### Workflow Example: Community User Editing a Scene

~~~
1. Call godotiq_project_summary(detail="brief")
   → Community response: "5 scripts, 2 scenes, 2 autoloads"
   → Tell user: "I see 5 scripts and 2 scenes with GameManager and Events autoloads.
     Full architecture analysis is available with Pro. I'll explore the files directly."
   → Fallback: file_ops(op="tree") to see structure

2. Call godotiq_file_context(path="res://scripts/player.gd")
   → Community response: "12 functions, 3 signals, depended by 4 scripts"
   → Tell user: "player.gd has 12 functions and 3 signals, used by 4 other scripts.
     I can't see which scripts depend on it without Pro, so I'll check manually."
   → Fallback: script_ops(op="read") to read the file

3. User asks "put a shelf near the printer"
   → Call godotiq_scene_map first (workflow says to)
   → Community response with 3 nodes preview
   → Tell user: "I mapped the scene — 267 nodes. I can see the Printer at (3,0,1.5).
     Full spatial layout with all positions needs Pro. I'll estimate a position."
   → Fallback: estimate (4,0,1.5), use node_ops(validate=true) to check collisions

4. Call godotiq_validate after code changes
   → Community response: "8 issues: 2 errors, 4 warnings, 2 info"
   → Tell user: "Found 8 code issues but I need Pro to see the details.
     I'll check for compilation errors with check_errors instead."
   → Fallback: check_errors(scope="scene")
~~~

The user experiences a working workflow — but with visible friction. They see the tool counts, know the data exists, and feel the difference between "estimate and validate" vs "analyze and place precisely." That friction is natural and honest.

---

## Efficiency Rules

1. **Don't overthink — act.** If you know what tool to call, call it immediately. Don't deliberate for 3 paragraphs about whether to call it. If the call fails, you'll see the error in the response and can adjust. Action is faster than speculation.

2. **Batch operations.** Use `build_scene` for multiple nodes instead of individual `node_ops` calls. Use `script_ops` patch mode for targeted changes instead of rewriting entire files. One tool call that does 20 things beats 20 tool calls that each do 1 thing.

3. **Don't repeat tool calls.** If you already called `project_summary` or `asset_registry` this session, don't call them again — the project structure hasn't changed. Keep results from previous calls in your conversation context and refer back to them.

4. **Check `_editor_state`.** Every bridge tool response includes an `_editor_state` dict with `open_scene`, `game_running`, and `recent_errors`. Read it after every tool call. If `recent_errors` is not empty, address the errors before continuing. If `open_scene` is wrong or empty, fix it before doing more scene work. This saves you from calling `editor_context` separately.

5. **One script, one validate.** After writing or modifying each `.gd` file, immediately call `godotiq_validate` on it. Don't write 5 scripts and then validate them all at the end — errors compound and become harder to debug when you can't tell which script introduced the problem.

6. **Act immediately.** When you know the next step, execute it. Don't write multi-paragraph plans. The tool will tell you if something is wrong — act on the response, don't pre-plan for every contingency.

7. **Maximum 2 paragraphs between tool calls.** After a tool call, explain what happened in 1-2 sentences, then make the next call. Don't write essay-length analysis between actions. If you find yourself writing more than 2 short paragraphs without a tool call, stop and act instead.

8. **Group modifications, verify once.** Make all changes (rotations, moves, property edits) in a single `exec editor` or `node_ops` batch, then one `save_scene`, then one `screenshot` to verify. Prefer one verification cycle per batch of changes, not per individual change.

9. **Runtime verification: one cycle.** A single `wait_ms` + `state_inspect` + `screenshot` per verification point. Do not call `state_inspect` multiple times consecutively waiting for a value to change — use `wait_ms` with an appropriate delay first.

10. **Loops for repetitive operations.** If you need to modify many nodes with the same logic (rotate 7 tiles, set a property on 20 nodes), write a loop in `exec editor` rather than separate `node_ops` calls for each node.

---

## Known Godot Quirks

1. **play_main_scene() is unreliable** — GodotIQ works around this internally. Always use `godotiq_run(action="play")` which uses `play_current_scene()` under the hood. If you need a specific scene, pass it as parameter: `godotiq_run(action="play", scene="res://Main.tscn")` or just `godotiq_run(action="play", scene="Main")`.

2. **Script cache staleness** — When you write a `.gd` file via `script_ops`, GodotIQ automatically sends a `reload_script` command to the editor. However, if you use `exec` to create or modify scripts, the editor may not pick up changes until a manual reload. Use `godotiq_exec` with context `"editor"` and call `EditorInterface.get_resource_filesystem().scan()` to force a refresh.

3. **class_name in new scripts** — When you create a new script with a `class_name` declaration, the editor may not register it immediately. Prefer the `load("res://path.gd").new()` pattern over `ClassName.new()` for scripts created during the current session. See "Script Loading Pattern" below.

4. **Asset loading time** — Projects with many 3D assets (GLB/GLTF files) take longer to start. GodotIQ handles this with adaptive timeout: it counts GLB files and adjusts the run timeout automatically. If you still get a timeout, check with `godotiq_state_inspect` before assuming failure.

5. **Verifying movement** — Screenshots are single frames and cannot prove motion. Use `godotiq_verify_motion` to confirm a node is actually moving, or take two `state_inspect` readings with a wait between them. See "Verifying Movement and Animations" below.

6. **Setting main scene** — When you run a scene for the first time in a project with no `main_scene` set in `project.godot`, GodotIQ auto-sets it. The run response will include `"main_scene_set": true` when this happens.

---

## Script Loading Pattern for New Scripts

When creating a new GDScript with a `class_name` declaration, the Godot editor registers that class name in a global cache that updates asynchronously. If another script immediately tries to use `ClassName.new()`, it may fail because the class is not yet registered.

The safe pattern is to always use `load()` for any script created or modified during the current session:

```gdscript
# WRONG — may fail for scripts created during this session:
var enemy = EnemyUnit.new()

# RIGHT — works reliably:
var EnemyScript = load("res://scripts/enemy_unit.gd")
var enemy = EnemyScript.new()
```

Scripts that existed before the session started are already registered and can use `ClassName.new()` safely. This only matters for scripts you CREATE or MODIFY during the current session.

---

## Verifying Movement and Animations

Screenshots are single frames — they cannot prove a node is moving, animating, or following a path.

**Preferred approach:** Use `godotiq_verify_motion`:

```
godotiq_verify_motion(node="/root/Main/Cars/Car1", property_name="position", duration=2.0)
→ {"verdict": "MOVING", "before": "(3, 0, 5)", "after": "(5.2, 0, 5)", "changed": true}
```

The tool also works for any property:
- `property_name="rotation"` for spinning objects
- `property_name="scale"` for growing/shrinking
- `property_name="modulate"` for color changes

**Manual alternative** using double `state_inspect`:

1. `godotiq_state_inspect(queries=[{node: "/root/Main/Enemy", properties: ["position"]}])`
2. `godotiq_input(commands=[{"wait_ms": 2000}])`
3. `godotiq_state_inspect(queries=[{node: "/root/Main/Enemy", properties: ["position"]}])`
4. Compare the two position values — if different, the node is moving

Use `verify_motion` for simple "is it moving?" checks. Use double `state_inspect` when you need to inspect multiple properties or complex state alongside the motion check.

ALWAYS verify movement this way for any object that should animate.

---

## Game Loading Time

Asset-heavy projects (especially those with many GLB/GLTF 3D models) can take 10-15+ seconds to start. `godotiq_run()` handles this automatically with adaptive timeout based on project asset count.

If the run times out despite adaptive timeout, the game may still be starting — wait a few seconds and try `godotiq_state_inspect` to check if it eventually started.

Do NOT immediately retry `godotiq_run(action="play")` after a timeout — the first run may still be in progress. Call `godotiq_run(action="stop")` first, then retry.

---

## Mandatory Workflows

### 1. Session Start (EVERY new conversation)

```
godotiq_project_summary(detail="brief")   → architecture, autoloads, counts
```

Call this FIRST. It gives you the project context you need in ~500 chars.

### 2. Before Editing ANY File

```
godotiq_file_context(file, detail="brief")           → public API, dependencies
godotiq_impact_check(file, action, target)            → what breaks if you change this
```

NEVER modify a `.gd` file without calling `file_context` first.

### 3. 3D Scene Work

```
godotiq_scene_map(scene, focus=area, radius=N, detail="brief")  → spatial layout
godotiq_placement(near=ref, constraints={...})                    → find safe positions
godotiq_build_scene(grid=..., parent="Terrain")                   → batch creation (grids, scatter, lines)
godotiq_node_ops(operations=[...], validate=true)                 → individual edits with validation
godotiq_save_scene()                                              → persist to disk
→ Self-verify with explore/spatial_audit
```

ALWAYS use `validate: true` on move/scale/add_child. Self-verify with explore/spatial_audit after 3D changes.

### 4. After Building or Modifying a Scene (VISUAL QA)

```
godotiq_explore(mode="tour")                           → autonomous visual inspection
→ Analyze each screenshot: describe what you see, note issues
→ If issues found: fix with node_ops / build_scene / exec
→ godotiq_explore(mode="tour") again to verify fixes
```

For close-up inspection of specific areas:

```
godotiq_explore(mode="inspect", positions=[
    {"position": [5, 2, 3], "look_at": [5, 0, 0], "direction": "tower_base"},
    {"position": [10, 5, 10], "look_at": [0, 0, 0], "direction": "overview"}
])
```

Use tour mode after major 3D work. Use inspect mode when you need to verify specific positions.

### 5. After Any Code Change

```
godotiq_validate(target=file, detail="brief")   → convention check
```

`validate` (Pro) checks conventions: naming, type hints, orphan signals, and also catches compilation errors. `check_errors` (free) checks compilation only. Pro agents: use `validate` — it covers both. Community agents: use `check_errors` only.

### 6. Multi-File Refactoring

```
godotiq_impact_check(file, action, target)       → understand blast radius BEFORE changing
godotiq_validate(target="project", detail="brief") → baseline: count current issues
→ Make your changes
godotiq_validate(target="project", detail="brief") → verify no NEW issues introduced
godotiq_check_errors(scope="project")              → verify compilation across project
godotiq_signal_map(find="orphans", detail="brief") → verify no broken signal wiring
```

NEVER refactor multiple files without running `impact_check` first. ALWAYS compare validate results before and after to catch regressions.

### 7. Testing & Debugging

```
godotiq_run(action="play")                → start game
godotiq_state_inspect(queries)            → check runtime values (PREFERRED — cheap)
godotiq_verify_motion(node="Enemy")       → prove movement (PREFERRED over screenshot for motion)
godotiq_screenshot(scale=0.3, quality=0.3) → visual check (EXPENSIVE — describe what you see)
godotiq_run(action="stop")                → stop game
```

Use `state_inspect` for data. Use `verify_motion` to prove animation/movement. Use `screenshot` only when visual confirmation is needed, and describe what you see.

---

## Tool Reference

### UNDERSTAND — Project Analysis (no addon needed)

**`godotiq_project_summary`** — Call FIRST in every session. Returns architecture, autoloads, file counts. Use `detail="brief"` (always).

**`godotiq_file_context`** — Call BEFORE editing any file. Returns public API, dependencies, signals, importers.

**`godotiq_scene_map`** — Spatial understanding of a scene. ALWAYS use `focus` + `radius` to limit scope. ALWAYS call before placing or moving 3D objects.

**`godotiq_dependency_graph`** — Complete dependency graph for a script. Call before refactoring.

**`godotiq_signal_map`** — Project-wide signal wiring. Find orphan signals, busiest signals, missing definitions.

**`godotiq_impact_check`** — Predicts what breaks before you make a change.

**`godotiq_validate`** — Convention check: missing type hints, naming violations, orphan signals.

**`godotiq_trace_flow`** — Trace execution flow from a trigger through the entire codebase.

**`godotiq_spatial_audit`** — Automated 3D issue scan: floating objects, scale mismatches, z-fighting, overlapping.

**`godotiq_check_errors`** — Check GDScript files for compilation/parse errors. Call before `godotiq_run` or after writing scripts. Use `scope="scene"` for current scene scripts + autoloads, `scope="project"` for all scripts in the project.

**`godotiq_asset_registry`** — Asset inventory with usage tracking. ALWAYS use `path_filter` to limit scope.

**`godotiq_suggest_scale`** — Recommend scale + position for a model based on similar assets.

**`godotiq_placement`** — Smart placement: finds Marker3D slots first, then grid-searches with constraints. Returns suggestions with confidence scores.

**`godotiq_animation_info`** — Animation data for any node: tracks, length, looping, state machine.

**`godotiq_animation_audit`** — Find animation problems: broken tracks, missing transitions.

### EDIT — Scene & Script Modification (requires addon)

**`godotiq_scene_tree`** — Live editor scene tree. Use `detail="brief"` and `depth=2` for overview.

**`godotiq_node_ops`** — Core editing. Batch operations with Ctrl+Z undo: move, rotate, scale, set_property, add_child, delete, duplicate, reparent. ALWAYS use `validate: true` for spatial operations.

**`godotiq_build_scene`** — Batch node creation with high-level patterns: grid (tile maps), line (paths/fences), scatter (handpicked placements), nodes (mixed types). One call = one undo action. Max 256 nodes per call. Use `parent` to target a container node. Response includes `node_names` array with actual names assigned by Godot (may differ from requested names due to collision renaming).

**`godotiq_script_ops`** — Read, write, patch GDScript. Patch mode (find-and-replace) is safest. After writing .gd files, GodotIQ automatically reloads the script in the editor.

**`godotiq_file_ops`** — Filesystem operations. Respects protected files.

**`godotiq_save_scene`** — Persist editor changes to disk. Call after `node_ops`.

**`godotiq_undo_history`** — Review what was changed.

**`godotiq_editor_context`** — Editor state: open scenes, selected nodes, game running status.

### PLAY & DEBUG — Runtime (requires addon + running game)

**`godotiq_run`** — Start/stop game. Automatically opens the requested scene, uses reliable `play_current_scene()`, applies adaptive timeout based on project size, and auto-sets `main_scene` in project.godot if not already configured.

**`godotiq_state_inspect`** — Query runtime properties. PREFERRED over screenshot for checking values.

**`godotiq_verify_motion`** — Verify a node property changes over time (proves movement/animation). Takes two readings separated by a duration and returns MOVING or STATIC verdict. Use instead of screenshots to verify motion. Game must be running.

**`godotiq_screenshot`** — Capture viewport. Describe what you see and cross-verify with tools. Note any uncertainties in your final report.

**`godotiq_explore`** — Autonomous visual inspection via drone camera. Two modes: **tour** (parses scene, clusters nodes into areas, flies camera through calculated positions, captures screenshots) and **inspect** (visits specific user-provided positions). Use after building or modifying 3D scenes. In screenshots, look for: lighting issues, geometry gaps, floating objects, fog/skybox appearance, decoration placement, general visual impression. Parameters: `mode` (tour/inspect), `max_areas` (default 3), `screenshots_per_area` (default 1), `positions` (for inspect mode), `scale` (default 0.3), `quality` (default 0.4), `fov`, `eye_height`. Has an 80K character budget — stops capturing and returns partial results if exceeded. Pro tool — Community users get cluster analysis without screenshots.

**`godotiq_perf_snapshot`** — FPS, draw calls, memory.

**`godotiq_ui_map`** — Map all UI elements. Call before `godotiq_input`.

**`godotiq_input`** — Simulate player input: actions, keys, UI taps.

**`godotiq_exec`** — Execute GDScript. `func run():` required. Use `context="editor"` for editor, `context="game"` for runtime. Prefer dedicated tools over exec.

**`godotiq_nav_query`** — Live pathfinding queries.

**`godotiq_watch`** — Persistent property monitoring.

**`godotiq_camera`** — Editor 3D camera control.

### UTILITY

**`godotiq_ping`** — Health check. Returns server version, license tier, and update availability. Call if connection seems broken or to discover the current tier.

---

## Spatial Validation

Add `validate: true` to move/scale/add_child in `node_ops`. Checks:
- Wall proximity (< 0.2m blocked)
- Node overlap (< 0.05m blocked)
- Sibling outlier (warns if far from similar nodes)
- Scale outlier (warns if different from siblings)

Atomic batches: if ANY operation is BLOCKED, NO operations execute.

## Node Paths

Paths in `node_ops` are relative to scene root:
- Use `"Sun"` not `"Main/Sun"`
- Use `"Entities/Worker_1"` not `"Main/Entities/Worker_1"`

## GDScript Conventions

- Files: `snake_case.gd` — Classes: `PascalCase` — Functions/vars: `snake_case`
- Always use type hints: `var count: int = 0`, `func get_name() -> String:`
- Use `@onready` for node refs: `@onready var label: Label = $UI/Label`
- Check null: `if is_instance_valid(node):`
- Prefer explicit types over `:=` type inference to avoid GDScript inference bugs

## Error Recovery

- `GAME_NOT_RUNNING` → `godotiq_run(action="play")`
- `NODE_NOT_FOUND` → `godotiq_scene_tree(detail="brief")` to find correct name
- `ADDON_NOT_CONNECTED` → Enable GodotIQ addon in Godot editor
- `TIMEOUT` → The adaptive timeout should handle most cases. If it still times out, wait a few seconds and check with `godotiq_state_inspect`. If the game truly did not start, call `godotiq_run(action="stop")` then try again.
- `SCRIPT_ERRORS` → `godotiq_check_errors(scope="scene")` to see details, then fix the broken scripts before running again
- `BLOCKED` (node_ops) → Check `validation` array, adjust position/scale
- `NO_SCENE` (build_scene) → Open a scene in the Godot editor first
- `PARENT_NOT_FOUND` (build_scene) → Check parent node name/path; create the parent node first if needed
- `NO_NODES` (build_scene) → Ensure exactly one mode (grid/line/scatter/nodes) with valid data
- Partial success (build_scene) → Check `errors` array, fix failed items, retry only those
- Node count limit (build_scene) → Split into multiple `build_scene` calls grouped by parent

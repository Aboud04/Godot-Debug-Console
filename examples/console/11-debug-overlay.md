# Tutorial 11: Building a Developer Debug Overlay

**Level:** Intermediate  
**Commands:** ui_panel, ui_vbox, ui_label, ui_button, ui_anchor, ui_size, ui_text_color, ui_modal, signal_connect, show_colliders, show_nav, show_paths, watch, count_nodes, step, slowmo, freeze, find_node, input_action  
**Goal:** Build an interactive debug HUD with visualization toggles, live property monitoring, frame controls, and node search.

## Overview

This tutorial demonstrates how to wire together console commands to create a professional developer overlay. The HUD includes:

- Visualization toggles (colliders, navigation, paths)
- Live watch panel showing player position
- Node count ticker
- Frame-by-frame controls (step/slowmo/freeze)
- Node search bar
- All connected via signal callbacks

The overlay is togglable and positioned at the top-right corner using anchors.

## Setup

Start with a game scene that has a Player node (or any movable object) and collision shapes.

## Session: Building the Overlay

### Step 1: Create the Main Panel

Create a top-right anchored panel to hold the debug HUD.

```
ui_panel DebugOverlay "" 320x240 #222222
ui_anchor /root/DebugOverlay 1,0,1,0.3
```

Response:
```
[CONSOLE] Spawned PanelContainer: /root/DebugOverlay
[CONSOLE] Anchors set: /root/DebugOverlay (left: 1.0, top: 0.0, right: 1.0, bottom: 0.3)
```

The panel is now positioned at top-right with size 320x240 pixels.

### Step 2: Add the Main Vertical Container

Create a VBox to organize all controls vertically.

```
ui_vbox /root/DebugOverlay DebugVBox
ui_size /root/DebugOverlay/DebugVBox 300x230
```

Response:
```
[CONSOLE] Spawned VBoxContainer: /root/DebugOverlay/DebugVBox
[CONSOLE] Size set: /root/DebugOverlay/DebugVBox custom_minimum_size=Vector2(300, 230)
```

### Step 3: Add Section Title

```
ui_label "DEBUG OVERLAY" /root/DebugOverlay/DebugVBox DebugTitle
ui_text_color /root/DebugOverlay/DebugVBox/DebugTitle #ffff00
```

Response:
```
[CONSOLE] Spawned Label: /root/DebugOverlay/DebugVBox/DebugTitle
[CONSOLE] Text color set: /root/DebugOverlay/DebugVBox/DebugTitle to #ffff00
```

### Step 4: Create Visualization Toggles Section

Add a container for visualization buttons.

```
ui_label "Visualization" /root/DebugOverlay/DebugVBox VisLabel
ui_vbox /root/DebugOverlay/DebugVBox VisButtonsBox
```

Now add the three toggle buttons.

```
ui_button "Show Colliders" /root/DebugOverlay/DebugVBox/VisButtonsBox CollidersBtn
ui_button "Show NavMesh" /root/DebugOverlay/DebugVBox/VisButtonsBox NavBtn
ui_button "Show Paths" /root/DebugOverlay/DebugVBox/VisButtonsBox PathsBtn
```

Response:
```
[CONSOLE] Spawned Button: /root/DebugOverlay/DebugVBox/VisButtonsBox/CollidersBtn
[CONSOLE] Spawned Button: /root/DebugOverlay/DebugVBox/VisButtonsBox/NavBtn
[CONSOLE] Spawned Button: /root/DebugOverlay/DebugVBox/VisButtonsBox/PathsBtn
```

### Step 5: Wire Visualization Buttons

Connect each button's pressed signal to the corresponding console command.

```
signal_connect /root/DebugOverlay/DebugVBox/VisButtonsBox/CollidersBtn.pressed DebugConsole._exec show_colliders
signal_connect /root/DebugOverlay/DebugVBox/VisButtonsBox/NavBtn.pressed DebugConsole._exec show_nav
signal_connect /root/DebugOverlay/DebugVBox/VisButtonsBox/PathsBtn.pressed DebugConsole._exec show_paths
```

Response:
```
[CONSOLE] Connected /root/DebugOverlay/DebugVBox/VisButtonsBox/CollidersBtn.pressed to DebugConsole._exec(show_colliders)
[CONSOLE] Connected /root/DebugOverlay/DebugVBox/VisButtonsBox/NavBtn.pressed to DebugConsole._exec(show_nav)
[CONSOLE] Connected /root/DebugOverlay/DebugVBox/VisButtonsBox/PathsBtn.pressed to DebugConsole._exec(show_paths)
```

Each button now toggles the corresponding debug visualization when clicked.

### Step 6: Add Frame Controls Section

```
ui_label "Frame Controls" /root/DebugOverlay/DebugVBox FrameLabel
ui_hbox /root/DebugOverlay/DebugVBox FrameButtonsBox
```

Add control buttons.

```
ui_button "Step" /root/DebugOverlay/DebugVBox/FrameButtonsBox StepBtn
ui_button "Slow-Mo" /root/DebugOverlay/DebugVBox/FrameButtonsBox SlowmoBtn
ui_button "Freeze" /root/DebugOverlay/DebugVBox/FrameButtonsBox FreezeBtn
```

Response:
```
[CONSOLE] Spawned Button: /root/DebugOverlay/DebugVBox/FrameButtonsBox/StepBtn
[CONSOLE] Spawned Button: /root/DebugOverlay/DebugVBox/FrameButtonsBox/SlowmoBtn
[CONSOLE] Spawned Button: /root/DebugOverlay/DebugVBox/FrameButtonsBox/FreezeBtn
```

### Step 7: Wire Frame Control Buttons

```
signal_connect /root/DebugOverlay/DebugVBox/FrameButtonsBox/StepBtn.pressed DebugConsole._exec step
signal_connect /root/DebugOverlay/DebugVBox/FrameButtonsBox/SlowmoBtn.pressed DebugConsole._exec "slowmo 0.25"
signal_connect /root/DebugOverlay/DebugVBox/FrameButtonsBox/FreezeBtn.pressed DebugConsole._exec freeze
```

Response:
```
[CONSOLE] Connected /root/DebugOverlay/DebugVBox/FrameButtonsBox/StepBtn.pressed to DebugConsole._exec(step)
[CONSOLE] Connected /root/DebugOverlay/DebugVBox/FrameButtonsBox/SlowmoBtn.pressed to DebugConsole._exec(slowmo 0.25)
[CONSOLE] Connected /root/DebugOverlay/DebugVBox/FrameButtonsBox/FreezeBtn.pressed to DebugConsole._exec(freeze)
```

Now you can pause and step through frames one at a time using the overlay buttons.

### Step 8: Add Watch Panel

Create a section to monitor live player position.

```
ui_label "Watch: Player" /root/DebugOverlay/DebugVBox WatchLabel
ui_label "" /root/DebugOverlay/DebugVBox PlayerPosLabel
```

Response:
```
[CONSOLE] Spawned Label: /root/DebugOverlay/DebugVBox/WatchLabel
[CONSOLE] Spawned Label: /root/DebugOverlay/DebugVBox/PlayerPosLabel
```

Start watching the player's position property.

```
watch /root/Player/Player.position 1000 /root/DebugOverlay/DebugVBox/PlayerPosLabel
```

Response:
```
[CONSOLE] Watching /root/Player/Player.position, updating /root/DebugOverlay/DebugVBox/PlayerPosLabel every 1000ms
```

The label now updates every second with the player's current position.

### Step 9: Add Node Count Ticker

Add another label to show live node count.

```
ui_label "Nodes: --" /root/DebugOverlay/DebugVBox NodeCountLabel
ui_button "Refresh Count" /root/DebugOverlay/DebugVBox CountBtn
```

Response:
```
[CONSOLE] Spawned Label: /root/DebugOverlay/DebugVBox/NodeCountLabel
[CONSOLE] Spawned Button: /root/DebugOverlay/DebugVBox/CountBtn
```

Wire the button to update the count when clicked.

```
signal_connect /root/DebugOverlay/DebugVBox/CountBtn.pressed DebugConsole._exec count_nodes
```

You can enhance this by creating a custom script to auto-update, but manual refresh works well for occasional monitoring.

### Step 10: Add Node Search Bar

Create a search input for finding nodes.

```
ui_label "Find Node" /root/DebugOverlay/DebugVBox FindLabel
ui_button "find_node Player" /root/DebugOverlay/DebugVBox FindBtn
```

Response:
```
[CONSOLE] Spawned Label: /root/DebugOverlay/DebugVBox/FindLabel
[CONSOLE] Spawned Button: /root/DebugOverlay/DebugVBox/FindBtn
```

Wire the find button.

```
signal_connect /root/DebugOverlay/DebugVBox/FindBtn.pressed DebugConsole._exec "find_node Player"
```

When clicked, it will search the tree for nodes matching the pattern.

### Step 11: Adjust Panel Size and Colors

Make the panel larger to accommodate all controls and style it.

```
ui_size /root/DebugOverlay 340x500
ui_anchor /root/DebugOverlay 0.7,0,1,0.65
```

Response:
```
[CONSOLE] Size set: /root/DebugOverlay custom_minimum_size=Vector2(340, 500)
[CONSOLE] Anchors set: /root/DebugOverlay (left: 0.7, top: 0.0, right: 1.0, bottom: 0.65)
```

The overlay now spans from 70% to 100% horizontally and 0% to 65% vertically.

### Step 12: Make the Overlay Togglable

Create a toggle button that shows/hides the overlay.

```
ui_button "Toggle HUD (F12)" "" ToggleHUDBtn
ui_layout /root/ToggleHUDBtn top_left
ui_size /root/ToggleHUDBtn 100x30
```

Add a hotkey binding to trigger the toggle.

```
bind toggle_debug_hud F12
input_action toggle_debug_hud tap
```

Then in your game script, you would listen for this action and call:
```gdscript
if Input.is_action_just_pressed("toggle_debug_hud"):
    if get_node_or_null("/root/DebugOverlay"):
        get_node("/root/DebugOverlay").visible = !get_node("/root/DebugOverlay").visible
```

Alternatively, use a console command to toggle visibility directly.

## Complete Overlay Layout

After following all steps, your overlay structure is:

```
/root/DebugOverlay (PanelContainer)
├── DebugVBox (VBoxContainer)
│   ├── DebugTitle (Label) "DEBUG OVERLAY"
│   ├── VisLabel (Label) "Visualization"
│   ├── VisButtonsBox (VBoxContainer)
│   │   ├── CollidersBtn (Button)
│   │   ├── NavBtn (Button)
│   │   └── PathsBtn (Button)
│   ├── FrameLabel (Label) "Frame Controls"
│   ├── FrameButtonsBox (HBoxContainer)
│   │   ├── StepBtn (Button)
│   │   ├── SlowmoBtn (Button)
│   │   └── FreezeBtn (Button)
│   ├── WatchLabel (Label) "Watch: Player"
│   ├── PlayerPosLabel (Label) [updates via watch]
│   ├── NodeCountLabel (Label) "Nodes: --"
│   ├── CountBtn (Button)
│   ├── FindLabel (Label) "Find Node"
│   └── FindBtn (Button)
```

## Advanced: Scripting the Overlay

For production overlays, create a custom GDScript that manages state:

```gdscript
extends Control

var colliders_shown = false
var nav_shown = false
var paths_shown = false

func _ready():
    $DebugVBox/VisButtonsBox/CollidersBtn.pressed.connect(_on_colliders_toggle)
    # ... wire other signals

func _on_colliders_toggle():
    colliders_shown = !colliders_shown
    DebugConsole._exec("show_colliders")
    $DebugVBox/VisButtonsBox/CollidersBtn.text = "Colliders: ON" if colliders_shown else "Colliders: OFF"
```

This lets you track state and update button text to reflect current mode.

## Keyboard Shortcuts

For faster access, bind all debug functions to hotkeys:

```
bind show_colliders C
bind show_nav N
bind show_paths P
bind step Space
bind slowmo S
bind freeze F
```

Then you can toggle visuals and controls directly from your keyboard without clicking buttons.

## Performance Notes

- Watch commands update at specified intervals; use longer intervals (5000ms) for expensive properties.
- The overlay itself consumes minimal resources when visible; the debug visualizations (colliders, nav) are where CPU impact occurs.
- For production, remove the overlay or toggle it off by default.

## Summary

You now have a fully functional developer debug overlay that integrates console commands into a reactive UI. The overlay demonstrates:

1. Dynamic UI construction via console
2. Signal-command wiring for responsive debugging
3. Live property monitoring with watch
4. Frame-level game control
5. Efficient node searching

This pattern scales to arbitrarily complex debugging tools: add more buttons, panels, watches, or input fields as needed, all without writing custom GDScript code for the overlay itself.

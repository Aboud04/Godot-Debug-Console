# Tutorial 10 - Smooth Scene Transitions

## Goal

Learn how to create smooth fade-based scene transitions entirely from the Debug Console. You will build a fullscreen overlay panel, tween its transparency to create fade-out and fade-in effects, and use goto_scene to switch between scenes with a polished transition. You will also explore loading screens and dynamic entity spawning without scene changes.

## Prerequisites

- Debug Console addon enabled and running in-game (press the hotkey to open it)
- A running game scene (the transition overlay will appear on top)
- Multiple scenes in your project (res://scenes/ folder or similar)
- Familiarity with console commands from previous tutorials

## Part 1: Find Available Scenes

Before transitioning, find which scenes exist in your project.

### Step 1: List all scenes in your project

Type:

```
> find_asset *.tscn
```

Expected output:

```
[color=#5FBEE0]Found 8 matches:[/color]
res://scenes/level_01.tscn
res://scenes/level_02.tscn
res://scenes/menu.tscn
res://scenes/game.tscn
res://scenes/ui/hud.tscn
res://scenes/pause_menu.tscn
...
```

This returns all .tscn files in your project. Note the full paths of scenes you want to transition to.

### Step 2: List only top-level scenes

Type:

```
> find_asset scenes/*.tscn
```

Expected output:

```
[color=#5FBEE0]Found 4 matches:[/color]
res://scenes/level_01.tscn
res://scenes/level_02.tscn
res://scenes/game.tscn
res://scenes/menu.tscn
```

The glob pattern narrows results to the scenes/ directory only.

## Part 2: Create a Fullscreen Fade Overlay

### Step 3: Spawn the black overlay panel

Type:

```
> ui_panel FadeOverlay 1280x720 #000000
```

Expected output:

```
[color=#5FBEE0]Spawned PanelContainer at /root/DebugConsoleUI/FadeOverlay[/color]
```

This creates a black panel 1280x720 (standard viewport size). It will layer on top of all game content.

### Step 4: Anchor the overlay to fill the entire viewport

Type:

```
> ui_anchor DebugConsoleUI/FadeOverlay 0,0,1,1
```

Expected output:

```
[color=#5FBEE0]Set anchors on [color=#5FBEE0]/root/DebugConsoleUI/FadeOverlay[/color] to left=0.0, top=0.0, right=1.0, bottom=1.0[/color]
```

This sets the panel anchors to full_rect mode. The panel now stretches to fill the entire viewport regardless of resolution. It will scale with any window resize.

### Step 5: Make the overlay transparent initially

Type:

```
> set DebugConsoleUI/FadeOverlay modulate #ffffff00
```

Expected output:

```
[color=#5FBEE0]Set modulate on /root/DebugConsoleUI/FadeOverlay to Color(1, 1, 1, 0)[/color]
```

The overlay is now invisible (alpha channel = 0). The color code #ffffff00 is white with zero alpha. We will tween this alpha to create the fade effect.

## Part 3: Tween Fade-Out and Transition

### Step 6: Tween the overlay to opaque (fade-out)

Type:

```
> tween DebugConsoleUI/FadeOverlay.modulate 0,0,0,0 0,0,0,1 0.5 Linear InOut
```

Expected output:

```
[color=#5FBEE0]Tweening /root/DebugConsoleUI/FadeOverlay.modulate from Color(0, 0, 0, 0) to Color(0, 0, 0, 1) over 0.5 secs[/color]
```

The overlay fades from transparent black (0,0,0,0) to opaque black (0,0,0,1) over 0.5 seconds. The screen is now completely black and the player cannot see the game.

### Step 7: Wait for the fade to complete

Wait about 0.5 seconds manually, or type:

```
> wait 0.5
```

(The wait command is for manual pauses in testing. In production code, you would chain tweens or use signals.)

### Step 8: Change the scene while the screen is black

Type:

```
> goto_scene res://scenes/level_02.tscn
```

Expected output:

```
[color=#5FBEE0]Changing scene to res://scenes/level_02.tscn[/color]
[Scene changed. Current scene: level_02]
```

The scene has changed, but the screen remains black because the overlay is still opaque. The new scene renders underneath, invisible.

### Step 9: Tween fade-in to reveal the new scene

Type:

```
> tween DebugConsoleUI/FadeOverlay.modulate 0,0,0,1 0,0,0,0 0.5 Linear InOut
```

Expected output:

```
[color=#5FBEE0]Tweening /root/DebugConsoleUI/FadeOverlay.modulate from Color(0, 0, 0, 1) to Color(0, 0, 0, 0) over 0.5 secs[/color]
```

The overlay fades from opaque black (0,0,0,1) to transparent black (0,0,0,0) over 0.5 seconds. The new scene gradually appears on screen. The transition is complete and polished.

## Part 4: Loading Screen Variant

The same technique can display a "Loading" message or logo while the screen is black.

### Step 10: Add a loading label

Before step 6 above, you can add text to the overlay:

Type:

```
> ui_label "Loading..." DebugConsoleUI/FadeOverlay LoadingText
```

Expected output:

```
[color=#5FBEE0]Spawned Label at /root/DebugConsoleUI/FadeOverlay/LoadingText[/color]
```

### Step 11: Center and style the loading text

Type:

```
> ui_text_color DebugConsoleUI/FadeOverlay/LoadingText #FFFFFF
```

Expected output:

```
[color=#5FBEE0]Set font_color on [color=#5FBEE0]/root/DebugConsoleUI/FadeOverlay/LoadingText[/color] to #ffffff[/color]
```

The "Loading..." text is now white and centered on the black screen. You could extend this with animations or a spinner.

## Part 5: Spawn Entities Without Scene Change

You can spawn new nodes (enemies, items, etc.) while remaining in the current scene using instance_scene.

### Step 12: Find a reusable scene template

Type:

```
> find_asset enemies/*.tscn
```

Expected output:

```
[color=#5FBEE0]Found 3 matches:[/color]
res://scenes/enemies/goblin.tscn
res://scenes/enemies/orc.tscn
res://scenes/enemies/skeleton.tscn
```

### Step 13: Spawn an enemy without changing scenes

Type:

```
> instance_scene res://scenes/enemies/goblin.tscn /root/Main/EnemySpawner
```

Expected output:

```
[color=#5FBEE0]Instanced scene at /root/Main/EnemySpawner/goblin[/color]
```

A new goblin enemy appears in the game world under the EnemySpawner node. The current scene remains active. You can instance multiple times to spawn waves of enemies.

### Step 14: Spawn another enemy

Type:

```
> instance_scene res://scenes/enemies/orc.tscn /root/Main/EnemySpawner Orc01
```

Expected output:

```
[color=#5FBEE0]Instanced scene at /root/Main/EnemySpawner/Orc01[/color]
```

This time, we specified a custom name "Orc01" for the spawned node. If you omit the name, the console uses the source scene's root node name.

## Advanced: Chained Transitions

You can create more complex transitions by combining multiple commands. For example:

### Colored Fade

Instead of black, fade with a different color:

```
> ui_panel TransitionOverlay 1280x720 #FF0000
> ui_anchor DebugConsoleUI/TransitionOverlay 0,0,1,1
> set DebugConsoleUI/TransitionOverlay modulate #ff000000
> tween DebugConsoleUI/TransitionOverlay.modulate 1,0,0,0 1,0,0,1 0.5
```

This creates a red fade-out instead of black.

### Directional Wipe (Simulated)

Use position tweens to slide the overlay in from one direction:

```
> tween DebugConsoleUI/FadeOverlay.position -1280,0,0 0,0,0 0.5
```

This slides the panel from off-screen (left) to the center over 0.5 seconds, creating a wipe effect.

## Summary

You have learned to:

1. Find available scenes using find_asset with glob patterns
2. Create a fullscreen overlay with ui_panel and ui_anchor
3. Tween the modulate.a property for fade effects
4. Combine fade-out, goto_scene, and fade-in for smooth transitions
5. Enhance transitions with loading messages
6. Spawn entities dynamically with instance_scene without changing scenes
7. Explore colored fades and directional wipes

Next steps: Experiment with different tween durations, easing functions (Quad, Cubic, Bounce), and overlay colors. Layer multiple panels for more complex wipe patterns.

# Tutorial 01 - Build a HUD from the Console

## Goal

Learn how to construct a complete in-game HUD with panels, labels, containers, and styling entirely from the Debug Console. No editor scene editing required. You will build a functional score/lives/timer display and see it render live as you type commands.

## Prerequisites

- Debug Console addon enabled and running in-game (press the hotkey to open it)
- A running game scene (any scene; the HUD will overlay on top)
- Basic familiarity with hex color codes (e.g., #FF0000 for red)

## Step 1: Create the main HUD panel

Type:

```
> ui_panel HUD 400x150 #1a1a2e
```

Expected output:

```
[color=#5FBEE0]Spawned PanelContainer at /root/DebugConsoleUI/HUD[/color]
```

This creates the outer panel 400 pixels wide by 150 tall, dark blue background. The addon automatically creates a DebugConsoleUI CanvasLayer as parent if none exists, keeping the HUD overlay-safe above the 3D viewport.

## Step 2: Add a vertical box container inside the panel

Type:

```
> ui_vbox HUD VBoxMain
```

Expected output:

```
[color=#5FBEE0]Spawned VBoxContainer at /root/DebugConsoleUI/HUD/VBoxMain[/color]
```

The VBoxContainer will automatically resize to fill the panel and stack children vertically. This is the layout backbone for the HUD.

## Step 3: Create the score label

Type:

```
> ui_label "Score: 0" HUD/VBoxMain ScoreLabel
```

Expected output:

```
[color=#5FBEE0]Spawned Label at /root/DebugConsoleUI/HUD/VBoxMain/ScoreLabel[/color]
```

The label shows "Score: 0" and is a child of the vertical box. Whitespace in text requires double quotes (quoting), which the addon parses and rejoins.

## Step 4: Set the score label color to gold

Type:

```
> ui_text_color HUD/VBoxMain/ScoreLabel #FFD700
```

Expected output:

```
Set font_color on [color=#5FBEE0]/root/DebugConsoleUI/HUD/VBoxMain/ScoreLabel[/color] to #ffd700
```

The score text is now gold. Text color is applied via theme overrides, visible immediately in-game.

## Step 5: Create the lives label

Type:

```
> ui_label "Lives: 3" HUD/VBoxMain LivesLabel
```

Expected output:

```
[color=#5FBEE0]Spawned Label at /root/DebugConsoleUI/HUD/VBoxMain/LivesLabel[/color]
```

Lives label stacks below the score in the VBox.

## Step 6: Color the lives label green

Type:

```
> ui_text_color HUD/VBoxMain/LivesLabel #00FF00
```

Expected output:

```
Set font_color on [color=#5FBEE0]/root/DebugConsoleUI/HUD/VBoxMain/LivesLabel[/color] to #00ff00
```

Lives are now bright green.

## Step 7: Create the timer label

Type:

```
> ui_label "Time: 0s" HUD/VBoxMain TimerLabel
```

Expected output:

```
[color=#5FBEE0]Spawned Label at /root/DebugConsoleUI/HUD/VBoxMain/TimerLabel[/color]
```

Timer label stacks below lives.

## Step 8: Color the timer label cyan

Type:

```
> ui_text_color HUD/VBoxMain/TimerLabel #00FFFF
```

Expected output:

```
Set font_color on [color=#5FBEE0]/root/DebugConsoleUI/HUD/VBoxMain/TimerLabel[/color] to #00ffff
```

Timer is now cyan.

## Step 9: Position the HUD in the top-left corner

Type:

```
> ui_layout HUD top_left
```

Expected output:

```
Applied preset 'top_left' to [color=#5FBEE0]/root/DebugConsoleUI/HUD[/color]
```

The HUD panel snaps to the top-left corner of the screen. Presets like `top_left`, `top_right`, `center`, `bottom_right` are built-in Godot anchor presets applied instantly.

## Step 10: Inspect your layout

Type:

```
> ui_dump HUD
```

Expected output:

```
HUD (PanelContainer)
  VBoxMain (VBoxContainer)
    ScoreLabel (Label)
    LivesLabel (Label)
    TimerLabel (Label)
```

The ASCII tree confirms the hierarchy. All three labels are children of VBoxMain, which is a child of HUD, all of which are children of the DebugConsoleUI CanvasLayer (implicit parent not shown here).

## What you built

A functional 3-row HUD stacked in a VBox inside a dark panel, anchored to the top-left, with gold score, green lives, and cyan timer labels. All done in 10 console commands. The HUD is live on-screen: if you run a game loop, a script can update `$HUD/VBoxMain/ScoreLabel.text = "Score: 100"` at runtime and the HUD reflects it instantly.

## Variations

- **Horizontal layout instead of vertical:** Replace Step 2 with `> ui_hbox HUD HBoxMain` to place labels side-by-side.
- **Center the HUD:** Replace Step 9 with `> ui_layout HUD center` for a centered overlay.
- **Change the panel color:** Re-run Step 1 with a different hex (e.g., `#2a2a4e` for lighter blue).
- **Make the panel larger:** Re-run Step 1 with bigger dimensions, e.g., `ui_panel HUD 600x200 #1a1a2e`.
- **Add a custom-sized score label:** After Step 3, add `> ui_size HUD/VBoxMain/ScoreLabel 300x50` to give it a fixed height.

## Troubleshooting

**"Control not found":** The path syntax is case-sensitive and must match the exact node names you gave. If you named the label `scoreLabel` but reference `ScoreLabel`, it will fail. Double-check spelling.

**Label text is tiny or invisible:** Use `ui_size` to set a custom_minimum_size on the label, e.g., `ui_size HUD/VBoxMain/ScoreLabel 200x40`. The VBox will then respect that minimum and allocate space.

**HUD doesn't appear on-screen:** Check that the DebugConsoleUI CanvasLayer is a child of the scene root. If the scene root is a 3D viewport, the CanvasLayer must sit above it in the tree. Confirm with `ui_dump` (no args) to see the full tree starting from /root.

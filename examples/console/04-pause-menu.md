# Tutorial 04: Building a Pause Menu with Debug Console

Learn to construct a full-featured pause menu using the Debug Console UI system. This tutorial demonstrates modals, layouts, button wiring, and scene navigation through pure console commands.

## Overview

You'll build a pause menu containing:
- Semi-transparent modal background overlay
- Vertical button layout (Resume, Restart Scene, Quit to Menu)
- Settings sub-panel with toggle options
- Signal connections that pause/resume the game
- Scene navigation handlers

All construction happens in a live console session without touching the editor.

## Prerequisites

- Godot 4.x with Debug Console addon installed
- A playable scene with at least one non-UI node
- Console access via F1 or your configured hotkey

## Step 1: Create the Modal Container

Start by opening the Debug Console and creating a modal overlay with semi-transparent background:

```
ui_modal PauseMenuModal 0.5 333333 200
```

This creates:
- Control node named "PauseMenuModal"
- 50% opacity (0.5)
- Dark gray background (333333 hex)
- 200ms animation duration

Verify the modal appeared and dimmed the scene. You should see a semi-transparent overlay covering the full viewport.

## Step 2: Create the Main Panel Container

Inside the modal, create a centered panel to hold all pause menu content:

```
ui_panel PausePanel PauseMenuModal Color(0.1,0.1,0.1,0.9) 400 300 true true
```

This creates:
- Panel styled with dark background (0.9 alpha)
- 400x300 pixel size
- Centered on screen (true, true)
- Child of PauseMenuModal

The panel now serves as the main container. All menu elements will be children of this panel.

## Step 3: Build the Main Button Layout

Create a vertical box layout to arrange buttons:

```
ui_vbox MainVBox PausePanel 10 10 380 100 true
```

This creates:
- VBoxContainer named "MainVBox"
- Position (10, 10) inside the panel
- Size 380x100
- Separation enabled (true) for spacing

Add the three main action buttons to this layout:

```
ui_button ResumeBtn MainVBox "Resume Game" 30
```

```
ui_button RestartBtn MainVBox "Restart Scene" 30
```

```
ui_button QuitBtn MainVBox "Quit to Menu" 30
```

Each button:
- Has 30px height
- Inherits the container's width
- Displays the action text

Verify the buttons stack vertically and are centered in the panel.

## Step 4: Create the Settings Sub-Panel

Below the buttons, add a collapsible settings area:

```
ui_panel SettingsPanel PausePanel Color(0.15,0.15,0.15,0.8) 380 120 true true
```

Adjust position to sit below buttons:

```
ui_layout SettingsPanel 10 130 380 120
```

This creates a sub-panel for settings with darker background (0.8 alpha).

## Step 5: Add Settings Controls

Create a horizontal layout for settings:

```
ui_vbox SettingsVBox SettingsPanel 5 5 370 110 true
```

Add toggle buttons for common pause menu settings:

```
ui_button MusicToggle SettingsVBox "Music: ON" 25
```

```
ui_button EffectsToggle SettingsVBox "SFX: ON" 25
```

```
ui_button GraphicsToggle SettingsVBox "High Quality" 25
```

## Step 6: Wire Resume Button

Connect the Resume button to un-pause the game:

```
signal_connect ResumeBtn pressed "pause_handler" "resume"
```

Then call the pause toggle to allow resuming:

```
call /root get_tree().paused false
```

This prepares the resume behavior. When pressed, the button will unpause the scene.

## Step 7: Wire Restart Button

Connect the Restart button to reload the current scene:

```
signal_connect RestartBtn pressed "scene_handler" "restart"
```

Implement the restart behavior:

```
call /root SceneManager reload_scene
```

Or directly via the tree:

```
call /root get_tree().reload_current_scene()
```

## Step 8: Wire Quit Button

Connect the Quit button to return to the main menu:

```
signal_connect QuitBtn pressed "scene_handler" "quit"
```

Implement the quit behavior. First, check what scene is your main menu (typically "res://scenes/menu.tscn"):

```
call /root get_tree().change_scene_to_file("res://scenes/menu.tscn")
```

## Step 9: Add Toggle Behavior to Settings

Wire the Music toggle:

```
signal_connect MusicToggle pressed "audio_handler" "toggle_music"
```

Add the toggle logic:

```
call /root AudioManager.toggle_music()
```

Wire Effects toggle:

```
signal_connect EffectsToggle pressed "audio_handler" "toggle_effects"
```

```
call /root AudioManager.toggle_effects()
```

## Step 10: Test the Full Menu

Pause the game using the pause toggle command:

```
pause
```

Verify:
- Modal overlay is visible and semi-transparent
- Main panel is centered
- All three buttons are clickable
- Settings panel is visible below buttons
- Settings toggles respond to clicks

Click Resume to verify the game un-pauses. Use Ctrl+Z to undo and re-pause if needed.

## Customization Tips

### Change Button Colors

Apply theme overrides to individual buttons:

```
call ResumeBtn add_theme_color_override("font_color", Color.GREEN)
```

### Adjust Transparency

Modify modal opacity after creation:

```
call PauseMenuModal set_modulate(Color(1,1,1,0.6))
```

### Add Keyboard Navigation

Bind Escape to close the menu:

```
call /root Input.action_release("pause")
```

### Center the Panel Dynamically

After adjusting size, re-center:

```
call PausePanel set_anchors_preset(14)
```

Preset 14 is "Center" in Godot's preset system.

### Disable Menu Buttons While Transitioning

Temporarily disable Quit during scene load:

```
call QuitBtn set_disabled(true)
```

Re-enable after verification:

```
call QuitBtn set_disabled(false)
```

## Common Issues

**Modal doesn't appear semi-transparent:**
Check that the opacity value is between 0.0 and 1.0. Values outside this range cause visibility issues.

**Buttons are invisible:**
Verify the panel background color has sufficient contrast. Use Color(0.1, 0.1, 0.1, 0.9) for dark backgrounds.

**Settings panel overlaps buttons:**
Adjust the y-position in ui_layout. Increase the second parameter (currently 130) to move it lower.

**Button clicks don't trigger:**
Ensure signal_connect receives the full pressed signal. Check the signal name is exactly "pressed" (lowercase).

**Scene change doesn't work:**
Verify the target scene path exists. Use absolute paths like "res://scenes/menu.tscn" rather than relative paths.

## Summary

You've built a fully functional pause menu using:
- ui_modal for the overlay effect
- ui_panel for containers
- ui_vbox for layout
- ui_button for controls
- signal_connect to wire interactivity
- call to invoke game logic

The pause menu demonstrates the power of Debug Console for rapid UI prototyping and testing game behaviors in real-time.

## Next Steps

- Add animations to menu appearance/disappearance
- Create save/load options in the settings panel
- Add difficulty selection buttons
- Implement slider controls for volume and brightness
- Create a confirmation dialog for Quit action

---

**Estimated time:** 10-15 minutes
**Difficulty:** Intermediate
**Commands used:** ui_modal, ui_panel, ui_vbox, ui_button, ui_layout, signal_connect, call, pause

# Tutorial 09 - Audio Mixer UI from Console

## Goal

Learn to build a functional audio mixer UI entirely from the Debug Console, controlling all audio buses dynamically. You will inspect bus volumes, create a visual mixer panel with labels and mute buttons per bus, and wire button clicks to AudioServer methods using the eval command for real-time dB value binding.

## Prerequisites

- Debug Console addon enabled and running in-game
- A game scene with audio buses configured (or use Godot default Master bus)
- Understanding of basic console commands (ui_panel, ui_label, ui_button from Tutorial 01)
- Familiarity with GDScript expressions and AudioServer API

## Step 1: List all audio buses

Type:

```
> audio_bus
```

Expected output:

```
== Audio Buses (2) ==
  Master      [color=#5FBEE0]+0.0 dB[/color]
  Music       [color=#5FBEE0]-5.3 dB[/color]
```

This command lists all audio buses on your project with their current volumes in dB. The Master bus is always present by default. Any user-created buses appear below it.

## Step 2: Check a specific bus volume

Type:

```
> audio_bus Master
```

Expected output:

```
[color=#5FBEE0]Master[/color]: +0.00 dB (audible)
```

This queries the Master bus specifically and shows its volume and mute state. The dB value is the actual AudioServer.get_bus_volume_db() reading.

## Step 3: Create the mixer panel

Type:

```
> ui_panel Mixer 500x300 #0a0a1a
```

Expected output:

```
[color=#5FBEE0]Spawned PanelContainer at /root/DebugConsoleUI/Mixer[/color]
```

This dark panel is the container for the mixer UI. Size is 500 wide by 300 tall, giving room for multiple bus controls.

## Step 4: Add a vertical box inside the panel

Type:

```
> ui_vbox Mixer MixerVBox
```

Expected output:

```
[color=#5FBEE0]Spawned VBoxContainer at /root/DebugConsoleUI/Mixer/MixerVBox[/color]
```

The VBox will stack bus rows vertically, one row per audio bus.

## Step 5: Create the Master bus row (horizontal layout)

Type:

```
> ui_hbox Mixer/MixerVBox MasterRow
```

Expected output:

```
[color=#5FBEE0]Spawned HBoxContainer at /root/DebugConsoleUI/Mixer/MixerVBox/MasterRow[/color]
```

This horizontal box will hold the bus name label, volume display, and mute button on one line.

## Step 6: Add a label showing the bus name

Type:

```
> ui_label "Master" Mixer/MixerVBox/MasterRow BusName
```

Expected output:

```
[color=#5FBEE0]Spawned Label at /root/DebugConsoleUI/Mixer/MixerVBox/MasterRow/BusName[/color]
```

The label displays the bus name for clarity in the mixer.

## Step 7: Add a label for the current volume display

Type:

```
> ui_label "(+0.0 dB)" Mixer/MixerVBox/MasterRow VolLabel
```

Expected output:

```
[color=#5FBEE0]Spawned Label at /root/DebugConsoleUI/Mixer/MixerVBox/MasterRow/VolLabel[/color]
```

This label will show the current dB value. You can update it via eval later if needed.

## Step 8: Add a mute toggle button for Master

Type:

```
> ui_button "Mute" Mixer/MixerVBox/MasterRow MuteBtn
```

Expected output:

```
[color=#5FBEE0]Spawned Button at /root/DebugConsoleUI/Mixer/MixerVBox/MasterRow/MuteBtn[/color]
```

This button will toggle the Master bus mute state when clicked.

## Step 9: Wire the mute button to AudioServer.set_bus_mute()

Type:

```
> signal_connect Mixer/MixerVBox/MasterRow/MuteBtn.pressed /root.set_bus_mute_master
```

Expected output:

```
Connected [color=#5FBEE0]Mixer/MixerVBox/MasterRow/MuteBtn[/color].pressed to /root.set_bus_mute_master
```

This connects the button's pressed signal to a method that will toggle the mute state. You'll define this method next, or use eval directly.

## Step 10: Alternatively, use eval to query current bus state

Type:

```
> eval AudioServer.is_bus_mute(AudioServer.get_bus_index("Master"))
```

Expected output:

```
false
```

The eval command evaluates GDScript expressions in a sandboxed environment. This expression queries whether the Master bus is currently muted (false means not muted, audible).

## Step 11: Get the Master bus volume

Type:

```
> eval AudioServer.get_bus_volume_db(AudioServer.get_bus_index("Master"))
```

Expected output:

```
0.0
```

This retrieves the current volume in dB. You can bind this to the label text dynamically.

## Step 12: Create a Music bus row

Type:

```
> ui_hbox Mixer/MixerVBox MusicRow
```

Expected output:

```
[color=#5FBEE0]Spawned HBoxContainer at /root/DebugConsoleUI/Mixer/MixerVBox/MusicRow[/color]
```

If your project has a Music bus (or you create one), add a second row for it.

## Step 13: Add Music bus name label

Type:

```
> ui_label "Music" Mixer/MixerVBox/MusicRow MusicBusName
```

Expected output:

```
[color=#5FBEE0]Spawned Label at /root/DebugConsoleUI/Mixer/MixerVBox/MusicRow/MusicBusName[/color]
```

Displays the Music bus name.

## Step 14: Add Music bus volume label

Type:

```
> ui_label "(-5.3 dB)" Mixer/MixerVBox/MusicRow MusicVolLabel
```

Expected output:

```
[color=#5FBEE0]Spawned Label at /root/DebugConsoleUI/Mixer/MixerVBox/MusicRow/MusicVolLabel[/color]
```

Shows the current volume of the Music bus.

## Step 15: Add a mute button for Music

Type:

```
> ui_button "Mute" Mixer/MixerVBox/MusicRow MusicMuteBtn
```

Expected output:

```
[color=#5FBEE0]Spawned Button at /root/DebugConsoleUI/Mixer/MixerVBox/MusicRow/MusicMuteBtn[/color]
```

Mute toggle for the Music bus.

## Step 16: Test muting the Master bus via console

Type:

```
> audio_bus Master mute
```

Expected output:

```
[color=#5FBEE0]Master[/color]: muted
```

The Master bus is now muted. All audio is silenced. The mixer UI is passive here; it reflects state but the button wiring in Step 9 would allow clicking to toggle this from the UI.

## Step 17: Unmute via console

Type:

```
> audio_bus Master unmute
```

Expected output:

```
[color=#5FBEE0]Master[/color]: unmuted
```

Master bus is audible again.

## Step 18: Change Master volume via console

Type:

```
> audio_bus Master -10
```

Expected output:

```
[color=#5FBEE0]Master[/color]: -10.00 dB
```

Master bus volume is now -10 dB (quieter). Valid range is -80 to +24 dB.

## Step 19: Inspect the complete mixer structure

Type:

```
> ui_dump Mixer
```

Expected output:

```
Mixer (PanelContainer)
  MixerVBox (VBoxContainer)
    MasterRow (HBoxContainer)
      BusName (Label)
      VolLabel (Label)
      MuteBtn (Button)
    MusicRow (HBoxContainer)
      MusicBusName (Label)
      MusicVolLabel (Label)
      MusicMuteBtn (Button)
```

The tree shows the complete hierarchy: two rows stacked in a VBox inside the mixer panel.

## What you built

A mixer panel with two audio bus rows (Master and Music), each showing the bus name, current volume in dB, and a mute button. You can toggle mute states via the console using audio_bus commands, and query volume values using eval expressions. The UI is live on-screen and can be extended with more buses or volume sliders using additional ui_* commands.

## Variations

- **Add a volume decrease button:** Create a button "Vol -" and wire it with eval: `AudioServer.set_bus_volume_db(0, AudioServer.get_bus_volume_db(0) - 1)` to reduce Master volume by 1 dB per click.
- **Add a volume increase button:** Similarly wire a "Vol +" button with `AudioServer.set_bus_volume_db(0, AudioServer.get_bus_volume_db(0) + 1)`.
- **Dynamic volume display:** Use a script to periodically read `AudioServer.get_bus_volume_db()` and update the volume labels to reflect real-time state.
- **Add more buses:** If your project has SFX, Dialogue, or Ambiance buses, add rows for each following the pattern of Step 12-15.
- **Color-code muted buses:** Use `ui_text_color` to highlight a bus label red when muted, adding visual feedback.

## Troubleshooting

**"unknown audio bus" error:** The bus name you passed to audio_bus does not exist. Run `audio_bus` with no args to list all available buses and check spelling.

**Button does not mute when clicked:** The signal_connect wiring requires the target method to exist. For simple cases, use eval directly in a script method or bind the button to a callable that executes the eval command.

**Volume value is out of range:** audio_bus clamps values to -80 to +24 dB. If you try to set outside this range, you will get an error. Use valid values within the range.

**UI does not appear on-screen:** Ensure the Mixer panel is a child of DebugConsoleUI. Confirm with `ui_dump` from the root (/root) to verify the panel tree.

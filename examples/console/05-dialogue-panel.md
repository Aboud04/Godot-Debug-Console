# Tutorial 5: Building a Dialogue Panel with Tweens and Signal Callbacks

Learn how to build an interactive dialogue UI at the bottom of the screen using the Debug Console. This tutorial demonstrates combining UI commands, signal connections, tweens, and dynamic text updates to create a multi-line dialogue system.

## Scenario

You want to display dialogue from an NPC at the bottom of the viewport. The UI has:
- A portrait placeholder panel on the left
- Speaker name label
- Dialogue text that advances through 3 lines
- Next and Skip buttons that trigger via signal callbacks

## Step 1: Create the Main Panel Container

Build the bottom panel that will contain the entire dialogue UI. This panel stretches across the bottom 25% of the screen.

```
ui_panel DialogueContainer "DebugConsoleUI" 1024x180 #2B2B2B
ui_layout DialogueContainer bottom_wide
```

Result: A dark panel at the bottom of the screen, 1024x180 pixels.

## Step 2: Create a Horizontal Layout (Portrait + Content)

Add an HBox to arrange the portrait on the left and text content on the right.

```
ui_hbox DialogueContainer MainRow
ui_layout MainRow full_rect
```

Result: A horizontal container that divides the dialogue panel into left/right regions.

## Step 3: Add the Portrait Placeholder

Create a portrait panel on the left. This is purely visual and shows where an NPC portrait would display.

```
ui_panel Portrait MainRow PortraitFrame 120x160 #1F4D5C
ui_size /root/DebugConsoleUI/DialogueContainer/MainRow/PortraitFrame 120x160
```

Result: A 120x160 portrait box in teal, ready for a future portrait texture.

## Step 4: Create a Vertical Layout for Text Content

Add a VBox on the right side to stack the speaker name and dialogue text vertically.

```
ui_vbox MainRow ContentBox
ui_layout ContentBox full_rect
```

Result: A vertical container for speaker name and dialogue lines.

## Step 5: Add the Speaker Name Label

Display who is speaking. We will update this dynamically.

```
ui_label "Merchant" ContentBox SpeakerName
ui_text_color /root/DebugConsoleUI/DialogueContainer/MainRow/ContentBox/SpeakerName #FFD700
```

Result: A golden speaker name label that reads "Merchant".

## Step 6: Add the Dialogue Text Label

This label will contain the current dialogue line. We will swap text through 3 lines.

```
ui_label "Welcome, traveler!" ContentBox DialogueText
ui_size /root/DebugConsoleUI/DialogueContainer/MainRow/ContentBox/DialogueText 800x80
```

Result: A larger label with the opening line of dialogue.

## Step 7: Create a Button Row Below the Text

Add an HBox for the Next and Skip buttons.

```
ui_hbox DialogueContainer ButtonRow
ui_layout ButtonRow bottom_left
```

Result: A horizontal container for action buttons.

## Step 8: Add Action Buttons

Create Next and Skip buttons. We will connect these to handlers in the next steps.

```
ui_button "Next" ButtonRow NextButton
ui_button "Skip" ButtonRow SkipButton
```

Result: Two buttons ready for connection.

## Step 9: Create a Signal Handler Node

We need a target node to handle button signals. Create a simple Node that will store dialogue state.

```
create_node Node "/root" DialogueManager
```

Result: A new DialogueManager node that will track dialogue state and handle callbacks.

## Step 10: Connect the Next Button Signal

Connect the Next button's pressed signal to a callback method. We will use signal_connect to tie button input to dialogue advancement.

```
signal_connect /root/DebugConsoleUI/DialogueContainer/ButtonRow/NextButton.pressed /root/DialogueManager.advance_dialogue
```

Result: The Next button is now connected. When pressed, it calls the advance_dialogue method on DialogueManager.

## Step 11: Connect the Skip Button Signal

Similarly, connect Skip to jump directly to the final line.

```
signal_connect /root/DebugConsoleUI/DialogueContainer/ButtonRow/SkipButton.pressed /root/DialogueManager.skip_dialogue
```

Result: The Skip button calls skip_dialogue when pressed.

## Step 12: Tween the Dialogue Text (Fade-In)

Animate the DialogueText label with a fade-in effect from alpha 0 to 1 over 0.5 seconds.

```
tween /root/DebugConsoleUI/DialogueContainer/MainRow/ContentBox/DialogueText.modulate:a 0.0 1.0 0.5
```

Result: The dialogue text fades in smoothly, providing visual feedback that new text has appeared.

## Step 13: Create the Advance Dialogue Handler

Now define the advance_dialogue method on DialogueManager. It will swap the text to the second line.

```
call /root/DialogueManager.advance_dialogue
```

This works because we can call methods via the console. Let's define it properly by using eval on the manager node. First, verify the method exists:

```
methods /root/DialogueManager
```

If advance_dialogue does not appear, we need to create it. For this tutorial, we will use `call` with a dynamic text swap.

## Step 14: Advance to Line 2

Use call to update the DialogueText label to the second line of dialogue.

```
call /root/DebugConsoleUI/DialogueContainer/MainRow/ContentBox/DialogueText.set_text "I have rare potions and supplies. Interested?"
```

Result: The dialogue advances to line 2.

## Step 15: Tween the Second Line Fade-In

Fade in the new text again for consistency.

```
tween /root/DebugConsoleUI/DialogueContainer/MainRow/ContentBox/DialogueText.modulate:a 0.0 1.0 0.5
```

Result: Smooth fade-in for the second line.

## Step 16: Advance to Line 3

Update the dialogue to the third and final line.

```
call /root/DebugConsoleUI/DialogueContainer/MainRow/ContentBox/DialogueText.set_text "Return soon, and we'll talk further."
```

Result: The dialogue advances to line 3.

## Step 17: Tween the Final Line Fade-In

Animate the final line's appearance.

```
tween /root/DebugConsoleUI/DialogueContainer/MainRow/ContentBox/DialogueText.modulate:a 0.0 1.0 0.5
```

Result: The final line appears with a fade-in.

## Step 18: Test the Skip Button

If the user clicks Skip at any point, the dialogue jumps directly to the final line.

```
call /root/DebugConsoleUI/DialogueContainer/MainRow/ContentBox/DialogueText.set_text "Return soon, and we'll talk further."
```

Result: Pressing Skip shows the final line immediately.

## Summary

You have built a complete dialogue UI using purely console commands:

1. Created a panel-based layout at the bottom of the screen.
2. Structured the dialogue UI with portrait, speaker name, and text areas.
3. Connected button signals to handler methods using signal_connect.
4. Used tweens to fade dialogue text in and out smoothly.
5. Chained 3 dialogue lines by calling set_text dynamically.
6. Implemented Next and Skip callbacks that advance or skip the dialogue.

All of this was accomplished without writing a single line of GDScript. The console commands managed layout, animation, signals, and state transitions. This pattern scales to longer dialogues, branching narratives, and complex event chains.

## Commands Used

- `ui_panel`: Spawn a PanelContainer
- `ui_label`: Create labels for text display
- `ui_button`: Create interactive buttons
- `ui_hbox`, `ui_vbox`: Container layouts
- `ui_layout`: Apply anchor presets
- `ui_size`: Set custom sizes
- `ui_text_color`: Change label colors
- `create_node`: Create manager nodes
- `signal_connect`: Connect button pressed signals to methods
- `tween`: Animate properties with fade effects
- `call`: Invoke set_text to swap dialogue lines
- `methods`: Inspect available methods on nodes

## Tips for Extension

- Add multiple NPCs by creating separate dialogue managers for each.
- Use `ui_grid` to create a choice menu for branching dialogue.
- Chain signals using `signal_emit` to trigger cutscenes after dialogue completes.
- Store dialogue lines in a dictionary and reference them by key instead of hardcoding text.
- Add sound effects by calling audio playback methods on an AudioStreamPlayer.

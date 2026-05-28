# Tutorial 07: Live Input Remapping

Master the input remapping commands to inspect, bind, and test controls without restarting the game. Build a live rebinding UI directly in the console.

## Core Concept

Input remapping lets you dynamically add key bindings to actions at runtime. The four essential commands are:

- **input_dump** - List all configured actions and their current key bindings
- **bind** - Add a key binding to an action (or create a new action on the fly)
- **unbind** - Remove a binding from an action
- **input_action** - Simulate an input event to test the binding

All changes persist only during the current game session. Reload or exit, and bindings revert to what is in project.godot. This is perfect for testing, player customization UIs, and rapid iteration without file I/O.

## Part 1: Inspecting the Input Map

### Step 1a: Dump All Actions and Bindings

The game has a default set of actions (ui_accept, ui_cancel, move_left, move_right, etc.).

```
input_dump
```

Output shows all actions with their current bindings. Example:

```
ui_accept     (UI Accept) -> Space, Enter
ui_cancel     (UI Cancel) -> Escape
move_left     -> A, Left
move_right    -> D, Right
```

Each line shows the action name, optional description in parentheses, and comma-separated key specs (e.g. "Space", "Ctrl+S", "MouseButton1").

### Step 1b: Filter by Substring

List only actions containing "move":

```
input_dump move
```

Output:

```
move_left     -> A, Left
move_right    -> D, Right
move_up       -> W, Up
move_down     -> S, Down
```

Filtered output shows only matching actions, making it easy to find a group of related bindings.

### Step 1c: Empty Action

Some actions may have no bindings yet:

```
input_dump custom
```

Output:

```
custom_skill  (no bindings)
```

This is normal. An action without bindings will not trigger when you press a key, but it can still be assigned bindings at runtime.

## Part 2: Adding Key Bindings

### Step 2a: Bind to an Existing Action

Add a new key to an existing action:

```
bind move_left Q
```

Response:

```
Bound move_left -> Q (1 binding)
```

The "move_left" action now responds to both A/Left (from project.godot) and Q (just added). Test it:

```
input_dump move_left
```

Output:

```
move_left     -> A, Left, Q
```

### Step 2b: Compound Keys

Use modifiers like Ctrl, Shift, Alt:

```
bind screenshot Ctrl+S
```

Response:

```
Bound screenshot -> Ctrl+S (1 binding)
```

Valid key specs: "Space", "Enter", "Escape", "Tab", "Backspace", "Delete", "Home", "End", "PageUp", "PageDown", arrow keys ("Up", "Down", "Left", "Right"), function keys ("F1" through "F12"), number keys, letter keys, and modifiers ("Ctrl+", "Shift+", "Alt+", "Cmd+" on Mac).

### Step 2c: Create an Action and Bind in One Command

Add a binding to an action that doesn't exist yet:

```
bind quick_save F5
```

Response:

```
Bound quick_save -> F5 (1 binding)
```

The "quick_save" action is created on the fly and immediately bound to F5. Verify:

```
input_dump quick_save
```

Output:

```
quick_save    -> F5
```

### Step 2d: Multiple Bindings for One Action

An action can respond to multiple keys:

```
bind move_left E
bind move_left Page_Up
```

Each command adds a binding. Verify:

```
input_dump move_left
```

Output:

```
move_left     -> A, Left, Q, E, Page_Up
```

Now the player can move left with any of those five keys.

## Part 3: Removing Bindings

### Step 3a: Remove a Specific Binding

Remove one key from an action:

```
unbind move_left Q
```

Response:

```
Removed 1 binding from move_left (spec: Q)
```

Verify:

```
input_dump move_left
```

Output:

```
move_left     -> A, Left, E, Page_Up
```

Q is gone, but A, Left, E, and Page_Up remain.

### Step 3b: Remove All Bindings

Unbind an action with no key argument:

```
unbind move_left
```

Response:

```
Cleared all bindings for move_left
```

Verify:

```
input_dump move_left
```

Output:

```
move_left     (no bindings)
```

Now the action has no keys and will not trigger from keyboard input.

### Step 3c: Unbind a Non-Existent Binding

Try to remove a binding that does not exist:

```
unbind move_left Z
```

Response:

```
No matching binding removed from move_left (spec: Z)
```

No error, but no binding is removed because Z was never bound to move_left.

## Part 4: Testing Input Events

### Step 4a: Simulate a Press

Use input_action to trigger an action as if the player pressed a key:

```
input_action move_left press
```

If your game's player controller listens for the "move_left" action, the player will move left for one frame. No visual output from the command itself, but the action fires in the engine.

### Step 4b: Simulate a Release

Trigger the release event:

```
input_action move_left release
```

Most game code only cares about press and release separately. "Press" means the key went down, "release" means it went up. For a movement action, the controller probably checks input_is_action_pressed() continuously, so a single press/release pair will move the player for exactly one frame.

### Step 4c: Simulate a Tap (Press + Release)

Combine press and release in one command:

```
input_action move_left tap
```

Equivalent to:

```
input_action move_left press
input_action move_left release
```

Use "tap" for actions that trigger once, like "jump" or "attack". Use "press"/"release" if you need to hold a key or test the state transition.

### Step 4d: Verify Binding Works

Example workflow to test a new binding:

```
bind jump Space
input_dump jump
input_action jump tap
```

If the game logs "Player jumped!" when the jump action fires, you'll see that feedback. If nothing happens, check that your game's script is listening to the "jump" action, or check the debug console's game log.

## Part 5: Building a Live Rebinding UI

Create a minimal "press a key to bind" UI using the console's built-in UI commands. This demonstrates how a player could rebind keys interactively.

### Step 5a: Create a Control Panel

```
ui_panel BindPanel 500x300 #1a1a2e
```

Response:

```
Created PanelContainer node 'BindPanel' at /root/CanvasLayer/DebugConsole/BindPanel
```

A semi-transparent dark panel appears on screen, 500 pixels wide and 300 pixels tall.

### Step 5b: Add Labels

Add a title label:

```
ui_label "Key Binding Setup" BindPanel BindTitle
```

Response:

```
Created Label node 'BindTitle' at /root/CanvasLayer/DebugConsole/BindPanel/BindTitle
```

Add a status label:

```
ui_label "Press a key to bind to jump" BindPanel BindStatus
```

Response:

```
Created Label node 'BindStatus' at /root/CanvasLayer/DebugConsole/BindPanel/BindStatus
```

### Step 5c: Add Buttons

Add a button to confirm the binding:

```
ui_button "Bind to Jump" BindPanel ConfirmBtn
```

Response:

```
Created Button node 'ConfirmBtn' at /root/CanvasLayer/DebugConsole/BindPanel/ConfirmBtn
```

Add a button to reset bindings:

```
ui_button "Reset Jump" BindPanel ResetBtn
```

Response:

```
Created Button node 'ResetBtn' at /root/CanvasLayer/DebugConsole/BindPanel/ResetBtn
```

### Step 5d: Use the UI to Bind Keys

In a real game, you would connect the button's pressed() signal to a script that waits for the next key press. For this tutorial, we simulate the workflow:

1. Display the prompt:

```
ui_label "Waiting for key..." BindPanel WaitMsg
```

2. Manually bind the key:

```
bind jump X
```

3. Verify the binding:

```
input_dump jump
```

4. Test the binding:

```
input_action jump tap
```

5. Update the status:

```
ui_label "Jump bound to X" BindPanel BindStatus
```

### Step 5e: Cleanup

Remove the entire panel when done:

```
execute /root/CanvasLayer/DebugConsole/BindPanel queue_free
```

The panel will disappear from the screen. (Or you can ignore it and continue using the console.)

## Part 6: Realistic Workflow

Here's a complete workflow for testing a custom action:

```
// Create and bind a new action
bind dash Shift

// Verify the binding exists
input_dump dash

// Show UI feedback
ui_label "Dash bound to Shift" /root/UIRoot DashLabel

// Simulate the player pressing the dash key
input_action dash press

// Simulate the player releasing it
input_action dash release

// Unbind and rebind to test another key
unbind dash
bind dash E

// Verify the new binding
input_dump dash

// Test it
input_action dash tap
```

No file I/O, no restart. You can test 10 different key assignments in 30 seconds.

## Part 7: Key Takeaways

1. **input_dump** shows all actions and their bindings. Use it to verify what is currently bound.

2. **bind** adds a key to an action. It creates the action if it doesn't exist. Multiple bindings per action are allowed.

3. **unbind** removes a binding. Unbind with no key removes all bindings from that action.

4. **input_action** simulates a key press/release. Use it to test that your binding works without touching the keyboard.

5. **UI commands** (ui_panel, ui_label, ui_button) let you build a visual rebinding interface using the console. Connect button signals to your game logic for a full rebinding system.

6. **Bindings are temporary**. They do not persist to project.godot. When the game restarts, bindings revert to project.godot defaults. For persistent bindings, save them to a JSON or INI file and restore on startup (out of scope for this tutorial).

## Common Patterns

**Inspect and Modify**

```
input_dump          // See what is bound
bind action Key     // Add a binding
input_dump action   // Confirm the binding
```

**Test a Binding**

```
bind action Key
input_action action tap
// Watch your game respond
```

**Create a Rebinding UI**

```
ui_panel RebindUI 400x200 #000000
ui_label "Press a key" RebindUI Prompt
ui_button "Confirm" RebindUI ConfirmBtn
bind action Space   // Manually bind for now
input_action action tap  // Test it
```

**Reset to Defaults**

```
unbind move_left
unbind move_right
unbind move_up
unbind move_down
// Now they fall back to project.godot defaults
input_dump move
```

## Troubleshooting

**Binding does not work**

- Verify the binding with `input_dump action`. If it is not there, the bind command failed (check syntax).
- Test with `input_action action tap`. If nothing happens, your game's script is not listening to that action. Check your game code.

**Action name typo**

Bind always succeeds, even if the action name is made up:

```
bind junp Space   // Typo: should be "jump"
input_dump       // Shows "junp" as a valid action now
```

If you misspell the action, unbind it and bind the correct name:

```
unbind junp
bind jump Space
```

**Key spec not recognized**

Valid key specs include modifier prefixes (Ctrl+, Shift+, Alt+, Cmd+) plus key names. Some examples:

- "A" through "Z", "0" through "9"
- "Space", "Enter", "Escape", "Tab"
- "Up", "Down", "Left", "Right"
- "F1" through "F12"
- "Ctrl+S", "Shift+F5", "Alt+Tab", "Cmd+Q"
- "MouseButton1" (left click), "MouseButton2" (right click)

If the key spec is invalid, the bind command will return an error message. Re-read the key name and try again.

## Conclusion

Live input remapping is one of the most powerful tools in the debug console. It lets you iterate on controls, test edge cases, and validate your input handling all without leaving the game. Combine it with the UI commands to build a player-facing rebinding menu, or use it solo for rapid QA.

Next tutorial: Custom commands and command chaining.

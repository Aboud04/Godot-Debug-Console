# Tutorial 12: Tween Showcase - Animate Any Property at Runtime

**Goal:** Animate node properties at runtime without animation tracks. Demonstrate all 10 transition types (linear, sine, quad, cubic, quart, quint, expo, elastic, back, bounce) and all 4 ease modes (in, out, in_out, out_in) via console commands.

## What Are Tweens?

A Tween is a lightweight animation that runs in the SceneTree, animating a property from one value to another over a duration. Unlike AnimationPlayer (which requires animation tracks), tweens are created and controlled entirely at runtime using a single command.

## The Tween Command

```
tween <path>.<property> <from> <to> <duration> [trans] [ease]
```

- `<path>`: Node path (absolute or relative)
- `<property>`: The property to animate (position, scale, rotation, modulate, etc.)
- `<from>`: Starting value
- `<to>`: Ending value
- `<duration>`: Animation duration in seconds
- `[trans]`: Transition type (optional: linear, sine, quad, cubic, quart, quint, expo, elastic, back, bounce)
- `[ease]`: Ease mode (optional: in, out, in_out, out_in)

## Step 1: Build a Tween Playground UI

First, create a simple scene with buttons for each tween type. In the scene tree or console:

```
create_node Control "." "TweenPlayground"
create_node VBoxContainer "TweenPlayground" "Container"
create_node Label "Container" "Title"
call "Container/Title".text = "Tween Playground"
```

Then create a target node to animate:

```
create_node Control "TweenPlayground" "AnimatedBox"
call "TweenPlayground/AnimatedBox".size_flags_horizontal = 1
call "TweenPlayground/AnimatedBox".size_flags_vertical = 1
call "TweenPlayground/AnimatedBox".custom_minimum_size = "200,200"
call "TweenPlayground/AnimatedBox".modulate = "1,1,1,1"
```

## Step 2: Position Tweens

Animate position using different transitions:

Linear transition (constant speed):
```
tween "TweenPlayground/AnimatedBox".position "0,100" "400,100" 2 linear
```

Sine transition (smooth easing):
```
tween "TweenPlayground/AnimatedBox".position "0,150" "400,150" 2 sine in
```

Bounce transition (bouncy arrival):
```
tween "TweenPlayground/AnimatedBox".position "0,200" "400,200" 2 bounce out
```

Elastic transition (elastic overshoot):
```
tween "TweenPlayground/AnimatedBox".position "0,250" "400,250" 2 elastic out
```

Back transition (slight backward motion before forward):
```
tween "TweenPlayground/AnimatedBox".position "0,300" "400,300" 2 back in_out
```

## Step 3: Scale Tweens

Animate the size of a node:

Grow effect (quad transition):
```
tween "TweenPlayground/AnimatedBox".scale "1,1" "2,2" 1.5 quad in
```

Shrink effect (cubic transition):
```
tween "TweenPlayground/AnimatedBox".scale "2,2" "0.5,0.5" 1.5 cubic out
```

Bounce scale (quart transition):
```
tween "TweenPlayground/AnimatedBox".scale "0.5,0.5" "1.5,1.5" 2 quart out_in
```

## Step 4: Rotation Tweens

Spin the node around:

Smooth rotation (quint transition):
```
tween "TweenPlayground/AnimatedBox".rotation "0" "6.28" 3 quint in
```

Fast spin (expo transition):
```
tween "TweenPlayground/AnimatedBox".rotation "0" "3.14" 1 expo out
```

## Step 5: Modulate Alpha (Fade) Tweens

Fade in and out by animating modulate.a (alpha channel):

Fade in (linear):
```
tween "TweenPlayground/AnimatedBox".modulate "1,1,1,0" "1,1,1,1" 2 linear
```

Fade out (sine):
```
tween "TweenPlayground/AnimatedBox".modulate "1,1,1,1" "1,1,1,0" 2 sine out
```

Pulse effect (quad):
```
tween "TweenPlayground/AnimatedBox".modulate "1,1,1,0.3" "1,1,1,1" 1 quad in_out
```

## Step 6: Modulate Color Tweens

Animate the full color by tweening modulate:

Red flash:
```
tween "TweenPlayground/AnimatedBox".modulate "1,1,1,1" "1,0,0,1" 1 linear
```

Cycle through colors (cubic):
```
tween "TweenPlayground/AnimatedBox".modulate "1,0,0,1" "0,1,0,1" 2 cubic in_out
```

Green to blue (quart):
```
tween "TweenPlayground/AnimatedBox".modulate "0,1,0,1" "0,0,1,1" 1.5 quart out
```

## Step 7: Custom Property Tweens

If your node has custom properties (e.g., a custom health or energy value):

```
create_node Node2D "TweenPlayground" "CustomNode"
call "TweenPlayground/CustomNode".set("custom_property", 0)
tween "TweenPlayground/CustomNode".custom_property "0" "100" 3 expo in
```

Check the value:
```
call "TweenPlayground/CustomNode".get("custom_property")
```

## Step 8: Combining Transitions and Eases

Advanced examples combining transitions with all 4 ease modes:

Linear IN (slow start, constant end):
```
tween "TweenPlayground/AnimatedBox".position "0,0" "500,0" 2 linear in
```

Linear OUT (constant start, slow end):
```
tween "TweenPlayground/AnimatedBox".position "0,0" "500,0" 2 linear out
```

Linear IN_OUT (slow on both ends):
```
tween "TweenPlayground/AnimatedBox".position "0,0" "500,0" 2 linear in_out
```

Linear OUT_IN (fast on both ends, slow middle):
```
tween "TweenPlayground/AnimatedBox".position "0,0" "500,0" 2 linear out_in
```

Elastic with IN (builds energy):
```
tween "TweenPlayground/AnimatedBox".position "0,50" "400,50" 2 elastic in
```

Elastic with IN_OUT (bounces both ways):
```
tween "TweenPlayground/AnimatedBox".position "0,100" "400,100" 2 elastic in_out
```

Back with OUT (overshoots on arrival):
```
tween "TweenPlayground/AnimatedBox".position "0,150" "400,150" 2 back out
```

Bounce with IN_OUT (springs and settles):
```
tween "TweenPlayground/AnimatedBox".position "0,200" "400,200" 2 bounce in_out
```

## Step 9: Quick Reference of All Transitions

| Transition | Effect | Best For |
|-----------|--------|----------|
| linear | Constant speed | UI, predictable motion |
| sine | Smooth, natural curve | Camera moves, fade effects |
| quad | Accelerating then decelerating | Gentle animations |
| cubic | More pronounced curve | Emphasized easing |
| quart | Sharper acceleration | Snappy UI feedback |
| quint | Even sharper curve | Impact effects |
| expo | Exponential (extreme) | Dramatic entrances/exits |
| elastic | Spring-like oscillation | Bouncy, playful feel |
| back | Slight backward overshoot | Anticipation, surprises |
| bounce | Ball-like bouncing | Playful, game-like feel |

## Step 10: Chain Multiple Tweens

Tweens execute independently. To sequence animations, run them in a script or use separate console commands with staggered timing:

```
tween "TweenPlayground/AnimatedBox".position "0,0" "300,0" 1 sine in
```

Wait a moment, then:
```
tween "TweenPlayground/AnimatedBox".position "300,0" "300,300" 1 sine in
```

## Tips and Tricks

1. Tween any property with set_indexed syntax: position, scale, rotation, modulate, custom_properties, etc.
2. Tweens do not block console commands; they run in the background.
3. Each new tween command creates a new Tween instance. Previous tweens continue running unless killed.
4. Use ease modes to customize feel: in for slow start, out for slow end, in_out for both.
5. Combine transitions and eases to find the perfect animation for your interaction.

## Summary

The tween command provides a powerful way to animate any property at runtime without animation tracks. With 10 transitions and 4 ease modes, you can create 40 unique animation styles. Use position for movement, scale for growth/shrinkage, rotation for spinning, modulate for color and fade effects, and custom properties for game values. Experiment with different combinations to find the feel that matches your game's style.

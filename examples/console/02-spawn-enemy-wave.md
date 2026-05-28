# Tutorial 02: Spawn Enemy Wave with Death Signals

## Goal

Spawn 5 enemies at scattered positions, wire their death signals to a kill counter, then test combat tuning with slowmo and freeze.

## Prerequisites

- Godot 4.6+ with Debug Console addon active
- A scene with an EnemyUnit scene or script ready to spawn
- Access to a running game instance or test scene

## Step-by-Step

### Step 1: Create a Counter Node

Start the console and create a simple Node to hold kill count:

```
> create_node Node Counter
Green: Node "Counter" created at /root/Counter

> set /root/Counter.kill_count 0
Green: set /root/Counter.kill_count = 0
```

### Step 2: Spawn 5 Enemies at Scattered Positions

Spawn enemies in a wave pattern. If your scene is `res://scenes/EnemyUnit.tscn`:

```
> spawn res://scenes/EnemyUnit.tscn "" 0,0,0
Green: Spawned Cyan: /root/EnemyUnit

> spawn res://scenes/EnemyUnit.tscn "" 5,0,0
Green: Spawned Cyan: /root/EnemyUnit1

> spawn res://scenes/EnemyUnit.tscn "" 10,0,0
Green: Spawned Cyan: /root/EnemyUnit2

> spawn res://scenes/EnemyUnit.tscn "" 3,0,5
Green: Spawned Cyan: /root/EnemyUnit3

> spawn res://scenes/EnemyUnit.tscn "" 7,0,5
Green: Spawned Cyan: /root/EnemyUnit4
```

### Step 3: Find All Enemies to Verify Spawn

Use find_node to search for all enemy nodes:

```
> find_node Enemy*
Cyan: /root/EnemyUnit
Cyan: /root/EnemyUnit1
Cyan: /root/EnemyUnit2
Cyan: /root/EnemyUnit3
Cyan: /root/EnemyUnit4
Green: 5 nodes found
```

### Step 4: Count Nodes by Type

Verify scene structure:

```
> count_nodes
Yellow: 6 nodes
  Node2D: 1
  EnemyUnit: 5
  Counter: 1
```

### Step 5: Wire Death Signals to Counter

If EnemyUnit emits a `died` signal, connect each one to a method on Counter:

```
> signal_connect /root/EnemyUnit.died /root/Counter._on_enemy_died
Green: Connected /root/EnemyUnit.died to /root/Counter._on_enemy_died

> signal_connect /root/EnemyUnit1.died /root/Counter._on_enemy_died
Green: Connected /root/EnemyUnit1.died to /root/Counter._on_enemy_died

> signal_connect /root/EnemyUnit2.died /root/Counter._on_enemy_died
Green: Connected /root/EnemyUnit2.died to /root/Counter._on_enemy_died

> signal_connect /root/EnemyUnit3.died /root/Counter._on_enemy_died
Green: Connected /root/EnemyUnit3.died to /root/Counter._on_enemy_died

> signal_connect /root/EnemyUnit4.died /root/Counter._on_enemy_died
Green: Connected /root/EnemyUnit4.died to /root/Counter._on_enemy_died
```

Shorthand: create a script method on Counter that increments kill_count:

```gdscript
func _on_enemy_died():
    kill_count += 1
    print("Enemy killed! Total: %d" % kill_count)
```

### Step 6: Emit Kill Signals (Test)

Manually trigger deaths to verify wiring. First check current kill count:

```
> get /root/Counter.kill_count
Yellow: 0
```

Emit the death signal from one enemy:

```
> signal_emit /root/EnemyUnit.died
Green: Signal died emitted from /root/EnemyUnit
```

Check updated kill count:

```
> get /root/Counter.kill_count
Yellow: 1
```

Emit more:

```
> signal_emit /root/EnemyUnit1.died
Green: Signal died emitted from /root/EnemyUnit1

> signal_emit /root/EnemyUnit2.died
Green: Signal died emitted from /root/EnemyUnit2

> get /root/Counter.kill_count
Yellow: 3
```

### Step 7: Enable Slow Motion (0.5x Speed)

Test combat mechanics at half speed:

```
> slowmo 0.5
Green: Time scale set to Yellow: 0.5

> get Engine.time_scale
Yellow: 0.5
```

Enemies now move and act at 50% speed. All animations, physics, and movement slow down.

### Step 8: Restore Normal Speed

```
> slowmo off
Green: Time scale restored to Yellow: 1.0
```

### Step 9: Freeze Time Completely

Stop all motion for detailed inspection:

```
> freeze
Green: Engine frozen (time_scale = Yellow: 0.0)
```

Nothing animates or moves. Freeze is useful for:
- Screenshotting final positions
- Inspecting enemy final states
- Pausing before a critical event

### Step 10: Unfreeze with Slowmo Off

```
> slowmo off
Green: Time scale restored to Yellow: 1.0
```

### Step 11: Evaluate Kill Ratio

Check how many of 5 enemies died:

```
> eval "get_node('/root/Counter').kill_count / 5.0 * 100"
Yellow: 60.0
```

This tells us 3 out of 5 enemies (60%) were killed during the test wave.

### Step 12: Duplicate an Enemy for Another Wave

If you want to add more enemies without re-spawning:

```
> duplicate_node /root/EnemyUnit EnemyUnit5
Green: Duplicated /root/EnemyUnit as Cyan: /root/EnemyUnit5

> signal_connect /root/EnemyUnit5.died /root/Counter._on_enemy_died
Green: Connected /root/EnemyUnit5.died to /root/Counter._on_enemy_died
```

Now you have 6 enemies total. Signal is already wired.

### Step 13: Test at Quarter Speed

Slow down further for pixel-perfect timing:

```
> slowmo 0.25
Green: Time scale set to Yellow: 0.25
```

At 0.25x, you can watch exact frame-by-frame attack patterns, projectile paths, and enemy AI behavior.

## What You Built

A complete combat testing setup:
- 5 enemies spawned at known positions
- A kill counter wired to each enemy's death signal
- Signal wiring verified by manually emitting deaths
- Slow-motion controls for combat tuning (0.5x, 0.25x)
- Complete time freeze for inspection
- Ability to duplicate enemies on demand
- Kill ratio calculation via eval

All without touching the editor. Everything driven by console commands.

## Variations

**Add damage numbers:** Bind Enemy.take_damage() to input and call via console:
```
> call /root/EnemyUnit.take_damage 10
```

**Log enemy positions before freeze:** 
```
> eval "get_tree().get_nodes_in_group('enemy').map(func(e): return str(e.global_position))"
```

**Wave spawner loop:** Create many waves with find_node to count live enemies after each:
```
> find_node EnemyUnit*
> count_nodes
```

**Slowmo progression:** Test at multiple speeds in sequence:
```
> slowmo 0.1
[watch at 10% speed]
> slowmo 0.25
[watch at 25% speed]
> slowmo off
[back to normal]
```

**Batch signal wiring:** If you have many enemies, write a loop in eval:
```
> eval "for e in get_tree().get_nodes_in_group('enemy'): get_node('/root/Counter').connect_to(e)"
```

## Troubleshooting

**"Parent not found"** when spawning:
- Ensure the parent path is correct (empty "" = tree root)
- If spawning under a specific container, pass full path: `spawn res://... "/root/Entities"`

**Signal not emitting:**
- Verify signal exists: `signals /root/EnemyUnit`
- Check connection with `signals /root/Counter` (shows listeners)
- Ensure method signature matches: `func _on_enemy_died():` (no parameters if signal emits with none)

**Slowmo not working:**
- Verify game is actually running (not paused in editor)
- Check current scale: `get Engine.time_scale`
- Enemies must respect Engine.time_scale in their movement code

**Freeze hangs the UI:**
- Freeze stops game time, not console time. Console still responsive.
- Use `slowmo off` to resume
- If console seems frozen, it may be waiting for user input in the game

**Kill count not incrementing:**
- Verify Counter has the `_on_enemy_died()` method attached as a script
- Check signal is wired: `signals /root/Counter`
- Manually emit signal and watch count: `signal_emit /root/EnemyUnit.died`

**Too many nodes named EnemyUnit:**
- Use count_nodes to see exact count
- Use find_node with wildcards: `find_node EnemyUnit*`
- Duplicate uses auto-increment (_0, _1, _2...) to avoid collisions

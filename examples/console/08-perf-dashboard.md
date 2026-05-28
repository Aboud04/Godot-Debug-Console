# Tutorial 08 - Build a Live Performance Dashboard

## Goal

Learn how to monitor game performance in real-time using the Debug Console. You will build a persistent FPS counter overlay, use the performance monitor to inspect the full Performance.Monitor dump, watch specific values over time, benchmark two commands to compare their impact, and use runtime config to stress-test rendering. Finally, you will bookmark interesting moments with mark for later analysis.

## Prerequisites

- Debug Console addon enabled and running in-game (press the hotkey to open it)
- A running game scene with some activity or animation
- Basic understanding of performance metrics: FPS, frame time, draw calls

## Step 1: Take a baseline performance snapshot

Type:

```
> perf
```

Expected output:

```
[color=#5FBEE0]Performance Monitor (Physical Devices)[/color]
CPU Frames:     60.00 FPS | Time: 16.67 ms
...
[Multiple categories of metrics]
```

This dumps all available Performance.Monitor values across categories like CPU, GPU, rendering, memory, and audio. You now have a baseline to compare against.

## Step 2: Watch specific values continuously

Open the console and type:

```
> watch add fps
```

Expected output:

```
[color=#5FBEE0]Watching: fps[/color]
```

Now every frame, the watch system tracks fps in the background. Start a second observation:

```
> watch add frame_time
```

Expected output:

```
[color=#5FBEE0]Watching: frame_time[/color]
```

List what you are watching:

```
> watch list
```

Expected output:

```
[color=#5FBEE0]Currently watching:[/color]
fps: 60.0
frame_time: 16.67
```

The watch command continuously samples these two properties each frame. You can add more:

```
> watch add draw_calls
> watch add texture_mem
```

## Step 3: Create an on-screen FPS label

Type:

```
> ui_label "FPS: 60.0" root FPSLabel
```

Expected output:

```
[color=#5FBEE0]Spawned Label at /root/DebugConsoleUI/FPSLabel[/color]
```

This creates a label in the DebugConsoleUI canvas layer at the root level. The text "FPS: 60.0" is the default display string.

## Step 4: Position the FPS label in the top-right corner

Type:

```
> ui_layout /root/DebugConsoleUI/FPSLabel top_right
```

Expected output:

```
[color=#5FBEE0]Applied preset 'top_right' to /root/DebugConsoleUI/FPSLabel[/color]
```

The label snaps to the top-right corner of the screen, anchored so it follows the viewport.

## Step 5: Set the FPS label text color to green

Type:

```
> ui_text_color /root/DebugConsoleUI/FPSLabel #00FF00
```

Expected output:

```
Set font_color on [color=#5FBEE0]/root/DebugConsoleUI/FPSLabel[/color] to #00ff00
```

The FPS counter is now bright green, making it easy to spot.

## Step 6: Create a frame time label below

Type:

```
> ui_label "Frame: 16.67 ms" root FrameTimeLabel
```

Expected output:

```
[color=#5FBEE0]Spawned Label at /root/DebugConsoleUI/FrameTimeLabel[/color]
```

This tracks frame time (the inverse of FPS in milliseconds). Position it top-right as well:

```
> ui_layout /root/DebugConsoleUI/FrameTimeLabel top_right
> ui_text_color /root/DebugConsoleUI/FrameTimeLabel #FFFF00
```

Expected output (two commands):

```
[color=#5FBEE0]Applied preset 'top_right' to /root/DebugConsoleUI/FrameTimeLabel[/color]
Set font_color on [color=#5FBEE0]/root/DebugConsoleUI/FrameTimeLabel[/color] to #ffff00
```

Your frame time label is now yellow and pinned to the top-right.

## Step 7: Create a draw calls label

Type:

```
> ui_label "Draw Calls: 0" root DrawCallsLabel
```

Expected output:

```
[color=#5FBEE0]Spawned Label at /root/DebugConsoleUI/DrawCallsLabel[/color]
```

Position and color it:

```
> ui_layout /root/DebugConsoleUI/DrawCallsLabel top_right
> ui_text_color /root/DebugConsoleUI/DrawCallsLabel #FF00FF
```

Expected output:

```
[color=#5FBEE0]Applied preset 'top_right' to /root/DebugConsoleUI/DrawCallsLabel[/color]
Set font_color on [color=#5FBEE0]/root/DebugConsoleUI/DrawCallsLabel[/color] to #ff00ff
```

Your draw calls label is now magenta.

## Step 8: Inspect memory usage

Type:

```
> perf memory
```

Expected output:

```
Memory (Mbytes):
Static Memory: 12.34 MB
Dynamic Memory: 45.67 MB
Total: 58.01 MB
```

This shows a focused view of memory categories only. You can run this periodically to check if memory grows during gameplay (potential leak) or stays stable.

## Step 9: Benchmark two commands

The benchmark command measures how long a command takes to execute. Start by benchmarking a simple operation:

```
> benchmark ui_label "Test" root BenchLabel1
```

Expected output:

```
[color=#5FBEE0]Benchmark: ui_label "Test" root BenchLabel1[/color]
Execution time: 0.23 ms
```

Now benchmark a different command:

```
> benchmark watch add test_property
```

Expected output:

```
[color=#5FBEE0]Benchmark: watch add test_property[/color]
Execution time: 0.05 ms
```

The first command (creating UI) took longer (0.23 ms) than the second (adding a watch), showing that UI creation has more overhead. Use benchmark to compare performance-critical operations.

## Step 10: Stress-test rendering by increasing tick rate

Type:

```
> tick_rate 120
```

Expected output:

```
[color=#5FBEE0]Physics tick rate set to 120 Hz[/color]
```

This increases the physics simulation frequency from 60 to 120 ticks per second, doubling the simulation load. Your FPS counter and frame time label will update to reflect the extra work.

## Step 11: Check the impact on performance

Look at your on-screen labels (FPS and frame time) and the watch output. With tick_rate 120, you should see:
- FPS drops (e.g., from 60 to 30-40)
- Frame time increases (e.g., from 16.67 ms to 25-33 ms)

This demonstrates how the tick rate directly stresses the physics engine. Return to normal:

```
> tick_rate 60
```

Expected output:

```
[color=#5FBEE0]Physics tick rate set to 60 Hz[/color]
```

FPS returns to normal.

## Step 12: Stress-test rendering with vsync control

Type:

```
> vsync off
```

Expected output:

```
[color=#5FBEE0]VSync disabled[/color]
```

With vsync off, your game renders as fast as possible, uncapped by the monitor refresh rate. You will see FPS spike (potentially 500-1000 on a modern GPU) and frame time drop to 1-2 ms. This shows the GPU's raw capacity.

Re-enable vsync:

```
> vsync on
```

Expected output:

```
[color=#5FBEE0]VSync enabled[/color]
```

FPS caps at the monitor's refresh rate (typically 60 Hz).

## Step 13: Bookmark an interesting moment

While your game is running and some event happens (e.g., a spike in activity, a slow frame), type:

```
> mark interesting_spike
```

Expected output:

```
[color=#5FBEE0]Marked: interesting_spike at frame 1234[/color]
```

This bookmarks the current frame number and labels it "interesting_spike". Later, you can reference this mark when analyzing the console log to see what happened at frame 1234.

## Step 14: Mark multiple moments

Create more bookmarks as events occur:

```
> mark enemy_wave_start
```

Expected output:

```
[color=#5FBEE0]Marked: enemy_wave_start at frame 1567[/color]
```

Then later:

```
> mark boss_fight_end
```

Expected output:

```
[color=#5FBEE0]Marked: boss_fight_end at frame 2890[/color]
```

Your marks create a timeline in the console log. When reviewing performance, you can correlate marked events with spikes in the watch data.

## Step 15: Inspect watch summary

Type:

```
> watch list
```

Expected output:

```
[color=#5FBEE0]Currently watching:[/color]
fps: 45.2 (current) | avg: 58.3 | min: 30.1 | max: 60.0
frame_time: 22.1 (current) | avg: 17.2 | min: 16.67 | max: 33.2
draw_calls: 87 (current) | avg: 72 | min: 45 | max: 120
texture_mem: 234.5 MB (current) | avg: 230.2 | max: 245.0
```

Watch has accumulated min, max, and average values for each property since you started watching. These statistics help identify performance trends: average FPS vs. current FPS (is it stable?), min FPS (how bad did it get?), and max (best case).

## What you built

A complete real-time performance dashboard with on-screen FPS/frame time/draw calls labels, continuous property watching with statistics, benchmarking capability for operation cost analysis, and marked events for later correlation. You also stress-tested rendering by manipulating tick rate and vsync to see how the engine responds to load.

## Variations

- **Add more watched properties:** `watch add audio_time`, `watch add physics_time` to track subsystem timings.
- **Create a memory label:** `ui_label "Memory: 0 MB" root MemoryLabel` and set its color to cyan for a memory tracker overlay.
- **Benchmark complex chains:** Create a series of commands (e.g., multiple ui_label calls) and benchmark the whole sequence to measure batched overhead.
- **Stress test with multiple parameters:** Increase both tick_rate and disable vsync, then watch frame time spike dramatically.
- **Export watch data:** After running for a while, your watch statistics summarize performance over a full gameplay session, helping identify bottlenecks.

## Troubleshooting

**FPS label not visible:** Use `ui_dump` (no args) to verify the label exists at /root/DebugConsoleUI/FPSLabel. If missing, recreate it with ui_label.

**Watch not accumulating data:** Ensure the game is running and the watch properties are valid (use `perf` to see available property names).

**Benchmark times seem very low:** The Debug Console has minimal overhead (microseconds to milliseconds). If a command reports 0.00 ms, it completed faster than the timer can measure. This is normal.

**Marks not appearing:** Check the console log by scrolling. Marks are printed at the time they occur. If you do not see them, the game may not be running, or the log has scrolled past.

**VSync change has no effect:** Some systems have VSync forced in the graphics driver settings, overriding the engine setting. Check your GPU control panel if toggling within Godot does not work.

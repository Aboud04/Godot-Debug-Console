# Tutorial 06: Save and Load Checkpoints

Persist game state during development by saving and restoring node properties. Learn how to use `save_world` and `load_world` to create checkpoints that preserve @export variables across gameplay changes.

## Overview

The `save_world` and `load_world` commands let you snapshot the exported properties of all scene nodes to a JSON file, then restore that state at any time. This is useful for:

- Preserving level state while iterating on gameplay
- Testing different scenarios by reverting to a known checkpoint
- Recording mid-gameplay state for debugging

Limitations: Only @export variables on existing nodes are saved. Dynamically spawned nodes are not persisted (nodes created at runtime via `spawn` or `instance_scene`), and properties that are not marked @export are skipped.

## Setup

Ensure you have a game scene running with at least one node that has @export properties. For this tutorial, we'll spawn some test nodes and modify them before saving.

## Step 1: Spawn Test Nodes

Create a few simple nodes with @export properties to work with:

```
> create_node Node3D Ball_1
Ball_1 (Node3D) created

> create_node Node3D Ball_2
Ball_2 (Node3D) created

> create_node Node3D Ball_3
Ball_3 (Node3D) created

> count_nodes
Total nodes: 4 (root + 3 created)
  Node3D: 4
```

You now have three simple nodes. While they don't have @export properties yet (they're plain Node3D), we'll use `set` to simulate property changes for this demonstration. In a real game, you'd have nodes with @export color, position, health, or other game parameters.

## Step 2: Modify Properties with set

Modify properties on your nodes to represent game state:

```
> set Ball_1.position Vector3(5, 0, 0)
Ball_1.position = (5, 0, 0)

> set Ball_2.position Vector3(10, 0, 0)
Ball_2.position = (10, 0, 0)

> set Ball_3.position Vector3(15, 0, 0)
Ball_3.position = (15, 0, 0)
```

Verify the state with `get`:

```
> get Ball_1.position
Ball_1.position = Vector3(5, 0, 0)

> get Ball_2.position
Ball_2.position = Vector3(10, 0, 0)

> get Ball_3.position
Ball_3.position = Vector3(15, 0, 0)
```

## Step 3: Create Your First Checkpoint

Save the current state to a checkpoint:

```
> save_world checkpoint_01
Saved 3 nodes to user://saves/world_checkpoint_01.json
```

The console writes a JSON snapshot to the user:// directory. The file contains all @export properties from every node in the scene tree. The filename follows the pattern `world_<name>.json`.

Verify the save succeeded by inspecting one node:

```
> inspect Ball_1
Ball_1: Node3D
  position: Vector3(5, 0, 0)
  rotation: Vector3(0, 0, 0)
  scale: Vector3(1, 1, 1)
```

Record this initial state: Ball_1 at (5, 0, 0), Ball_2 at (10, 0, 0), Ball_3 at (15, 0, 0).

## Step 4: Modify Everything to Chaos

Now change all the properties dramatically to simulate gameplay:

```
> set Ball_1.position Vector3(100, 50, 100)
Ball_1.position = (100, 50, 100)

> set Ball_2.position Vector3(-50, 75, 50)
Ball_2.position = (-50, 75, 50)

> set Ball_3.position Vector3(0, -100, 0)
Ball_3.position = (0, -100, 0)
```

Verify the chaos:

```
> get Ball_1.position
Ball_1.position = Vector3(100, 50, 100)

> get Ball_2.position
Ball_2.position = (-50, 75, 50)

> get Ball_3.position
Ball_3.position = Vector3(0, -100, 0)
```

The nodes are now in completely different positions. This simulates what happens after gameplay changes the world state.

## Step 5: Restore from Checkpoint

Load the checkpoint to restore the original state:

```
> load_world checkpoint_01
Loaded 3 nodes from user://saves/world_checkpoint_01.json
```

The console reads the checkpoint file and restores all @export properties to the values from when you saved.

## Step 6: Verify Restoration

Confirm that the state matches the checkpoint exactly:

```
> get Ball_1.position
Ball_1.position = Vector3(5, 0, 0)

> get Ball_2.position
Ball_2.position = Vector3(10, 0, 0)

> get Ball_3.position
Ball_3.position = Vector3(15, 0, 0)
```

Perfect! All nodes are back at their original positions. You can also use `inspect` for detailed verification:

```
> inspect Ball_1
Ball_1: Node3D
  position: Vector3(5, 0, 0)
  rotation: Vector3(0, 0, 0)
  scale: Vector3(1, 1, 1)

> inspect Ball_2
Ball_2: Node3D
  position: Vector3(10, 0, 0)
  rotation: Vector3(0, 0, 0)
  scale: Vector3(1, 1, 1)

> inspect Ball_3
Ball_3: Node3D
  position: Vector3(15, 0, 0)
  rotation: Vector3(0, 0, 0)
  scale: Vector3(1, 1, 1)
```

All properties match the pre-save state.

## Step 7: Find and Count Verification

Use `find_node` and `count_nodes` to verify the scene structure is intact:

```
> find_node Ball*
Found 3 nodes:
  Ball_1
  Ball_2
  Ball_3

> count_nodes
Total nodes: 4 (root + 3 created)
  Node3D: 4
```

The node structure is unchanged. Save and load only restore property values, not the tree structure.

## Key Observations

1. **State is restored exactly**: All @export properties return to their checkpoint values.
2. **Only @export vars are saved**: Properties not marked @export are not included in the checkpoint. If you modify a non-exported property after saving, it will not be restored.
3. **Node structure is preserved**: Nodes are not deleted or recreated. Only their properties change.
4. **Checkpoint files are stored in user://**: The JSON files live in the user data directory, not the project. This is platform-safe.
5. **Existing nodes only**: Nodes you spawned during this session are saved if they exist in the tree when you call `save_world`. But if you delete a node and then load a checkpoint that includes it, that node remains deleted. Load restores properties on existing nodes only.

## Limitations and Gotchas

- **Dynamic spawns are lost**: If you `spawn` a node after saving a checkpoint, then load the checkpoint, the spawned node stays in the tree. The checkpoint does not undo spawns, it only restores properties.
- **Non-exported properties ignored**: If a node has properties that are not marked @export, they are not saved and will not be restored.
- **No undo for tree changes**: Loading a checkpoint does not reverse node creation or deletion. It only resets property values on nodes that still exist.
- **Name collisions**: If two checkpoints have the same name, the second save overwrites the first. Be explicit with checkpoint names.

## Summary

You have successfully:

1. Created a multi-node scene
2. Saved the current state with `save_world checkpoint_01`
3. Modified all properties drastically
4. Restored the original state with `load_world checkpoint_01`
5. Verified restoration with `inspect`, `get`, `find_node`, and `count_nodes`

This workflow is useful for regression testing, reverting unintended changes, and comparing two different game states. In production, checkpoint saves are typically triggered by game events (level completion, death, save points), not manually from the console.

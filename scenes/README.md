# Two-triangle test scene

This scene tests two overlapping triangles at different depths.

- Triangle 1: green, closer to the viewer
- Triangle 2: blue, farther from the viewer
- Draw order: green first, then blue
- Expected result: green remains visible in the overlapping area

Coordinates use signed 16.16 fixed-point values in the range -1 to 1.

## Vertices

Each row is one point: (X, Y, Z).

| Vertex | Triangle | X | Y | Z |
|---|---|---:|---:|---:|
| A | Green | -0.75 | 0.50 | -0.50 |
| B | Green | 0.25 | 0.50 | -0.50 |
| C | Green | -0.25 | -0.75 | -0.50 |
| D | Blue | -0.25 | 0.75 | 0.50 |
| E | Blue | 0.75 | 0.75 | 0.50 |
| F | Blue | 0.25 | -0.50 | 0.50 |

## Signed 16.16 values in hexadecimal

| Vertex | X | Y | Z |
|---|---|---|---|
| A | FFFF4000 | 00008000 | FFFF8000 |
| B | 00004000 | 00008000 | FFFF8000 |
| C | FFFFC000 | FFFF4000 | FFFF8000 |
| D | FFFFC000 | 0000C000 | 00008000 |
| E | 0000C000 | 0000C000 | 00008000 |
| F | 00004000 | FFFF8000 | 00008000 |

## Current memory-file limitation

The memory file uses the existing 1,024-word binary asset layout.
The first six vertex records and first two face records contain this scene.
Unused words are zero. Face colors and the two-face count are not yet
encoded because their interface has not been established.

## Generate and check the fixture

Run these commands from the repository root:

```powershell
python scenes/generate_two_triangles.py
gnatmake -gnat2012 -Isw/ada/ref/src sw/ada/tools/check_scenes.adb -o check_scenes.exe
.\check_scenes.exe scenes/scene_two_triangles.mem
```

The checker verifies the fixture's 1,024 words, including its vertex data and face indices. It reports expected screen coordinates and depths; it does not test hardware rendering.

Face colors and vertex/face counts are not encoded in this file. The unused vertex attributes, including TextureID, are zero. The final scene-input, color, and count interfaces still need to be confirmed before integration.

## Test with asset memory

From the repository root, run:

```powershell
xvhdl --2008 rtl/asset_memory.vhd tb/asset_memory_scene_tb.vhd
xelab asset_memory_scene_tb -s asset_memory_scene_sim
xsim asset_memory_scene_sim -runall
```

The testbench checks all 1,024 words read by `asset_memory` against the expected fixture values. It does not test Block A's scene input, Block B, color handling, or rendered output.
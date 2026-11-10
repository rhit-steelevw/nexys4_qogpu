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
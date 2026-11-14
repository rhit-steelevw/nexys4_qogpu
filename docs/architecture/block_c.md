# Block C Vertex Transform

Team 05 — QOGPU Graphics Pipeline

Connor Bodie

11/14/2026

Block C rotates a model-space vertex and converts it to screen coordinates and depth. The current interface is defined by [`vertex_transform` in block_c.vhd](../../rtl/block_c.vhd). One instance processes one vertex at a time; three instances can process the A, B, and C vertex slots of a triangle simultaneously.

## Vertex data and rotation coefficients

[Block B](block_b.md) supplies XYZ coordinates as signed 32-bit 16.16 values, together with an unsigned vertex ID and a last-triangle marker. [Block A](block_a.md) supplies six signed 16.16 coefficients: the sine and cosine of each rotation angle. C does not calculate trigonometric functions.

C captures the coordinates, coefficients, ID, and marker together when its input valid/ready handshake succeeds. Later changes on the input buses do not affect the operation in progress. The ID and marker pass through unchanged; they do not participate in the arithmetic.

The [asset generator](../../scripts/generate_cube_bram.py) normalizes the model about the origin using the maximum vertex radius before fixed-point encoding. For the cube, each original coordinate of ±1 becomes approximately ±1/sqrt(3), encoded as ±37837. C expects normalized geometry and coefficients representing a valid rotation. It does not normalize vertices or verify that each sine/cosine pair represents the same angle.

## Rotation arithmetic

C applies rotations in X, then Y, then Z order:

| Step | Calculations |
| --- | --- |
| Rotate X | `X1 = X`; `Y1 = Y*Cx - Z*Sx`; `Z1 = Y*Sx + Z*Cx` |
| Rotate Y | `X2 = X1*Cy + Z1*Sy`; `Y2 = Y1`; `Z2 = Z1*Cy - X1*Sy` |
| Rotate Z | `X3 = X2*Cz - Y2*Sz`; `Y3 = X2*Sz + Y2*Cz`; `Z3 = Z2` |

Each lane reuses one [fx_mul](../../rtl/fx_mul.vhd) instance for all twelve products, with `FRAC = 16` and `ROUND = 1`. For each axis, four products are issued on consecutive clock edges and their valid results are captured into four temporary registers. Once all four have arrived, C combines them using widened 33-bit addition or subtraction and checks that the result fits signed 32-bit 16.16 before storing it.

Each product is rounded separately according to the [numeric contract](../spec/qogpu_numeric_contract.md):

```text
product_q16 = (a_raw * b_raw + 32768) >> 16
```

The shift is arithmetic and ties round toward positive infinity. Results can differ from floating-point software or from rounding only after summing two full-precision products. A reference implementation must preserve this operation order.

## Screen coordinates and depth

C uses [qogpu_fx_pkg](../../rtl/qogpu_fx_pkg.vhd) for viewport and depth conversion. The viewport is fixed at 320 × 240; it uses different X and Y scales and flips Y so that screen Y increases downward.

| Output | Mapping |
| --- | --- |
| Screen X | `(X3 + 1.0) * 160`, retained as signed 16.16 |
| Screen Y | `(1.0 - Y3) * 120`, retained as signed 16.16 |
| Depth | `((z_raw + 65536) * (2**DEPTH_W - 1) + 65536) >> 17`, returned as an unsigned integer |

Depth maps -1.0 to zero and +1.0 to the maximum representable depth, with half-up rounding. The default depth width is 8 bits, giving a range of 0–255. Screen-coordinate endpoints include 320 and 240; later rasterization stages handle pixel bounds.

The helper functions assert that rotated coordinates lie in -1.0 through +1.0. There is no clamping or saturation. Quantized normalization, coefficients, and intermediate products can move a vertex slightly outside the ideal unit sphere for some rotations; resolving that boundary policy remains integration work. Simulation assertions detect illegal ranges and rotation-sum overflow; there is no runtime error output.

## Signals

All directions are relative to one C instance. Transfers occur on rising edges of `clk_i`. The `DEPTH_W` generic selects a depth width from 1 to 16 bits and defaults to 8.

| Signal | Direction | Bit width | Description |
| --- | --- | ---: | --- |
| `clk_i` | Input | 1 | Common pipeline clock. |
| `rstn_i` | Input | 1 | Active-low reset. Datapath and state reset synchronously; ready and output valid are suppressed whenever reset is low. |
| `in_valid_i` | Input | 1 | Input coordinates, coefficients, and metadata are available. Captured when input valid and ready are both high. |
| `in_ready_o` | Output | 1 | C is idle and can accept one vertex. Low while flushing, computing, or holding an output. |
| `in_x_i` | Input | 32 | Model-space X coordinate, signed 16.16. |
| `in_y_i` | Input | 32 | Model-space Y coordinate, signed 16.16. |
| `in_z_i` | Input | 32 | Model-space Z coordinate, signed 16.16. |
| `in_id_i` | Input | 32 | Unsigned vertex ID, preserved without modification. |
| `in_last_i` | Input | 1 | Marker that the vertex belongs to the last triangle of the frame. |
| `cos_x_i` | Input | 32 | Cosine for rotation about X, signed 16.16. |
| `sin_x_i` | Input | 32 | Sine for rotation about X, signed 16.16. |
| `cos_y_i` | Input | 32 | Cosine for rotation about Y, signed 16.16. |
| `sin_y_i` | Input | 32 | Sine for rotation about Y, signed 16.16. |
| `cos_z_i` | Input | 32 | Cosine for rotation about Z, signed 16.16. |
| `sin_z_i` | Input | 32 | Sine for rotation about Z, signed 16.16. |
| `out_valid_o` | Output | 1 | Transformed vertex is available. Asserted independently of downstream ready and held until accepted. |
| `out_ready_i` | Input | 1 | Downstream can capture the result. Acceptance requires output valid and ready both high. |
| `out_x_o` | Output | 32 | Screen X coordinate, signed 16.16. |
| `out_y_o` | Output | 32 | Screen Y coordinate, signed 16.16 with positive Y downward. |
| `out_z_o` | Output | `DEPTH_W` | Unsigned integer depth. |
| `out_id_o` | Output | 32 | Original unsigned vertex ID. |
| `out_last_o` | Output | 1 | Original last-triangle marker. Meaningful only with output valid. |

## Transform sequence and synchronization

1. On reset, clear the registers and enter `FLUSH`. After reset is released, drain the multiplier for three clock cycles before accepting input. The multiplier has no reset port.
2. In `IDLE`, accept a vertex and capture all inputs.
3. In `MULTIPLY`, issue and collect four products for the current axis.
4. In `COMBINE`, add or subtract the rounded products. Repeat for each remaining axis.
5. In `MAP_SCREEN`, compute screen XY and depth.
6. In `PRESENT`, hold the output coordinates, ID, and marker stable until downstream accepts them, then return to idle.

Each lane has one operation in flight. Its internal multiplier is pipelined, but the vertex interface is multicycle and does not accept one vertex per clock. Reset cancels outstanding work, including a stalled output.

Three-lane triangle synchronization is not implemented in this entity. The surrounding logic must ensure each B triangle is accepted once by all three lanes and must assemble their outputs into one downstream triangle. Directly broadcasting B's valid without coordinating lane readiness can duplicate transfers if the lanes become unsynchronized. The last marker must remain associated with the complete triangle and eventually reach frame-completion logic.

## Verification

The [vertex transform testbench](../../tb/vertex_transform_tb.vhd) compiled, elaborated, and passed in Vivado 2024.2. It checked 28 vertices at both 8-bit and 16-bit depth using an independent fixed-point reference. Tests covered identity, viewport and depth endpoints, positive and negative 90-degree axis rotations, combined rotations of normalized cube corners, input capture, output backpressure, and reset during computation or a stalled output.

From a Vivado-configured terminal at the repository root:

```powershell
vivado -mode batch -source scripts/sim.tcl -tclargs vertex_transform_tb rtl/qogpu_fx_pkg.vhd rtl/fx_mul.vhd rtl/block_c.vhd tb/vertex_transform_tb.vhd
```

This verifies the vertex lanes, not an integrated three-lane triangle wrapper or a synthesized timing target.

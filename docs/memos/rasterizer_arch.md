# Block D: triangle setup (RQ-92)

Files: `rtl/tri_setup.vhd`, `rtl/raster_pkg.vhd`, `tb/tri_setup_tb.vhd`.
Run: `make sim-tri-setup` (regression), `make synth-tri-setup` (resources).

## What it computes

Bit-exact with `Qogpu_Raster.Setup` (numeric contract rules 7, 8, 9, 11, 12), no
rounding anywhere:

- `A_i = y_i - y_(i+1)` (25 bit), `B_i = x_(i+1) - x_i` (26 bit)
- `area2 = A_0 (x_2 - x_0) + B_0 (y_2 - y_0)` (51 bit, exact)
- `area2 < 0`: negate every A, B and area2, so E1-E3 see one winding
- `TL_i = A_i > 0 or (A_i = 0 and B_i > 0)`, on the normalized A/B
- bounding box: floor of the min and max, clamped to 0..319 and 0..239.
  Vertices are never clamped.
- `area2 = 0`: rejected. Dropped, unless it is the last triangle; then it is
  sent with `empty = '1'` so the frame still finishes.

There is no C term. E1/E2 evaluate `E_i = A_i (x - x_i) + B_i (y - y_i)`, so D
passes the three vertices through.

## Microarchitecture

Serial FSM, about 7 clocks per triangle (latency does not matter at two
triangles per frame):

    IDLE -> EDGE -> MUL -> SUM -> NORM -> FLAGS -> OUTPUT -> IDLE
                                           \-> IDLE   (rejected, not last)

| State | Work |
|---|---|
| IDLE | `in_ready_o` high. On `in_valid_i`: latch vertices, z, color, last |
| EDGE | A, B, `x2-x0`, `y2-y0`, bounding box |
| MUL | the two 25x26 products |
| SUM | add them in 52 bits |
| NORM | assert the sum fits 51 bits; negate A, B, area2 if negative |
| FLAGS | TL, `empty`, drop decision |
| OUTPUT | `out_valid_o` high, payload held until `out_ready_i` |

Output is one `tri_t` register, so it cannot change while `valid` is high and
`ready` is low. `fx_mul` is not used: it rounds and shifts by 16.

Input range (x 0..320, y 0..240, raw 16.16) and the 51-bit fit are checked with
`assert ... severity failure`, the same style as `qogpu_fx_pkg`.

## Verification

`tri_setup_tb` reads `tb/vectors/setup.csv` (8 directed and 200 random rows,
from `make vectors`) and checks A, B, area2, TL, bbox, `empty` and the
pass-through fields on every row. Every third row is held with `out_ready_i`
low for 5 clocks. A separate process checks the payload is stable while
`valid` and not `ready`. Then:

- a collinear triangle that is not last is dropped (no `out_valid_o` for 20 clocks)
- reset in the middle of a triangle, then triangle 1 comes out correctly

Not covered: a vertex with a fraction that crosses 320 or 240 exactly. Block C
cannot produce it (rule 2).

## Synthesis (out of context, xc7a100t, 100 MHz, Vivado 2024.2)

4 DSP48E1, 556 registers, 1093 LUTs, setup slack +0.83 ns.
Run `make synth-tri-setup` to reproduce.

# E1-E3: scan, coverage, depth (RQ-93)

## What it computes

`raster_scan` (E1+E2) scans the bounding box row-major and emits every pixel
with its three edge values and a `kill` flag. `depth_interp` (E3) drops the
killed pixels and gives each covered pixel its depth. `rasterizer` wraps both
behind E4's port list. All three rules are bit-exact with the Ada reference
(`Edge`, `Covered`, `Interp_Z`):

    x_s = px * 2^16 + 2^15,   y_s = py * 2^16 + 2^15          (rule 2)
    E_i = A_i (x_s - x_i) + B_i (y_s - y_i)                   (rule 9)
    covered: every E_i > 0, or E_i = 0 and TL_i = 1           (rule 11)
    num = E_0 z_2 + E_1 z_0 + E_2 z_1
    z   = floor((2 num + area2) / (2 area2))                  (rule 10)

Edge i is opposite vertex i+2, so E_0 weights z_2.

## Microarchitecture

E1+E2 evaluates E_i once at (xmin, ymin): six products. After that every move is
an add: `A_i * 2^16` along a row, `B_i * 2^16` on the row-start copy at the end
of a row. E only steps on a transfer (`out_valid` and `out_ready`), so a stall
cannot skip a pixel.

    raster_scan:    IDLE -> DIFF -> MUL -> SUM -> RUN -> IDLE
                      \-> MARK -> IDLE   (empty triangle)
    depth_interp:   IDLE -> MUL0 -> MUL1 -> MUL2 -> ACC -> SETUP -> DIV -> OUTPUT -> IDLE
                      \-> OUTPUT (marker, or INTERP = false)
                      \-> IDLE   (killed, no marker: dropped)

`DIV` is a restoring divider, `DEPTH_W` steps, exact floor with no DSP. The
product is registered in `MUL*` and added one clock later (`ACC`) to meet
100 MHz. About 14 clocks per covered pixel at `DEPTH_W` = 8.

Each fragment carries z, area2 and color, so E1 can take the next triangle
while earlier pixels are still downstream. An `empty` triangle (area2 = 0,
only sent when it is the last one) gives one killed marker with `eot` and
`eof`, so the frame still ends.

Overflow checks (E fits 51 bits after each step, z fits `DEPTH_W` bits,
negative E on a covered pixel) are `assert ... severity failure`.

## Verification

All benches print `<tb>: ALL TESTS PASSED`. `edge.csv` and `interp.csv` come
from `make vectors` and are not committed, so `make` stops with a message if
they are missing.

| Bench | Checks |
|---|---|
| `raster_scan_tb` | Every bounding-box pixel of tris 1-6 and 8: px, py, E0..E2, `kill`, `eot`, `eof`, color, bit-exact with `edge.csv`. Margin rows have `covered = 0`. Tri 7 gives one marker. `out_ready` low 3 of every 7 clocks, payload stable while stalled. Reset in the middle of tri 1, then tri 1 again |
| `depth_interp_tb` | Depth of every covered row of `edge.csv` against `interp.csv`, with the same stall pattern and stable-output check. Killed pixel dropped, marker passed, reset in the middle of a division |
| `depth_interp_bypass_tb` | `INTERP = false`: z = z_0 even when z_1, z_2 differ; drop and marker |
| `rasterizer_tb` | `tri_setup` -> `rasterizer`. Tris 4 and 5 (shared edge): no pixel hit twice, per-triangle pixel counts equal `interp.csv`. MVP scene in screen space: green in front of blue in the overlap. Both frames dumped with `frame_dump_pkg` |

`rasterizer_tb` has a small E4/E6 model in the bench (depth buffer, framebuffer
write). It is not the real E4 or E6.

Not covered: `DEPTH_W` = 16 (the Ada `Interp_Z` only defines D = 8). With
`INTERP = false` the MVP frame is not a check of E3, because equal depths make
any E_i-to-z pairing correct.

## Synthesis (out of context, xc7a100t, 100 MHz, Vivado 2024.2)

`rasterizer`: 15 DSP48E1, 1293 registers, 1307 LUTs, setup slack +1.94 ns.
Run `make synth-rasterizer` to reproduce. Before the product register in E3,
the multiply and accumulate in one clock failed by 1.8 ns.

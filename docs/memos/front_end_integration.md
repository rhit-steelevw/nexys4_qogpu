# Front end integration: face mask, three-lane Block C, depth shading (RQ-100, RQ-108, RQ-91)

Vance Steele, 11/14/2026.

Files: `rtl/block_b.vhd` (`FACE_MASK`), `rtl/triangle_transform.vhd` (new),
`rtl/shade_pkg.vhd` (new), `rtl/draw_pipeline.vhd` (`SHADE`),
`rtl/gpu_top.vhd` (`g_cube`).
Run: `make sim-triangle-fetch`, `make sim-triangle-fetch-mask`,
`make sim-triangle-transform`, `make sim-shade-pkg`, `make sim-gpu-top-cube`.

Integration 3 replaced `scene_stub` with the real front end, A -> asset ROM
-> B -> C, and added shading so the MVP's two overlapping triangles can be
told apart in one colour. The only logic change inside Blocks A, B and C is
Block B's face mask. Block A and `vertex_transform` are used exactly as
written.

## Decisions

| Item | Decision | Reason |
|---|---|---|
| Scene | Cube faces 1 and 12, identity rotation | The only pair that partly overlaps at different depths with no rotation (below) |
| Selecting two faces | `FACE_MASK` generic on Block B | Keeps `cube_init.txt` the single source of scene data |
| Block C at triangle level | Three `vertex_transform` lanes with a join on both sides | No sequencer, no lane drift; costs two more `fx_mul` |
| Colour | One base red, `0xE0`, from the wrapper | Nothing to fetch; downstream unchanged when per-face colour comes |
| Telling the faces apart | Depth-cue shading per fragment, between E4 and E6 | Depth is already on every fragment; no normals exist for lighting |
| Rotation | Not in the MVP: Block A's write port stays tied off | Identity also makes every product exact (below) |

## The scene

With identity rotation the projection is straight down the Z axis.

- Sides 2-5 (x = +/-0.577 or y = +/-0.577) are edge-on. Their triangles have
  zero area, and Block D drops them.
- Side 1 (z = +0.577, faces 1-2) and side 6 (z = -0.577, faces 11-12) both
  project onto the same square, (67.6, 50.7) to (252.4, 189.3).
- The two triangles of one side share an edge and never overlap. One triangle
  from each side does overlap, at different depths.
- Face 1 (vertices 1, 2, 4) is the half of the square above the
  top-right-to-bottom-left diagonal. Face 12 (vertices 23, 24, 22) is the half
  above the top-left-to-bottom-right diagonal. They share the top quarter.

Depths from Block C, `((z_raw + 65536) * 255 + 65536) >> 17`: face 12 at
z = -0.577 is 54, face 1 at z = +0.577 is 201. Smaller depth passes, so face 12
is in front. Face 12 is also the cube's last face, so Block B's last-triangle
marker lands on the last triangle drawn.

## Block B: FACE_MASK

New generic on `triangle_fetch`:

    FACE_MASK : std_logic_vector(1 to 12) := (others => '1');   -- bit f = face f

B fetches and presents only the selected faces, in ascending order, and puts
`triangle_last_o` on the highest selected one. `gpu_top` sets
`"100000000001"` (faces 1 and 12).

**Change.** Three constants, computed from the mask at elaboration, and four
edited lines:

| Constant | Value |
|---|---|
| `FIRST_FACE` | Lowest selected face |
| `LAST_FACE` | Highest selected face |
| `NEXT_FACE(f)` | Lowest selected face above `f` (a 12-entry table; entries for unselected faces are unused) |

| Where | Before | After |
|---|---|---|
| `IDLE`, on frame start | `face_id <= 1` | `face_id <= FIRST_FACE` |
| `PRESENT_TRIANGLE`, end test | `face_id = FACE_COUNT` | `face_id = LAST_FACE` |
| `PRESENT_TRIANGLE`, step | `face_id <= face_id + 1` | `face_id <= NEXT_FACE(face_id)` |
| `triangle_last_o` | `face_id = FACE_COUNT` | `face_id = LAST_FACE` |

An assertion fails elaboration if the mask selects no faces. Fetch states,
address arithmetic, ID validation and fault handling are untouched.

**Why it is safe.** With the default mask (all ones) the constants reduce to
the original values: `FIRST_FACE = 1`, `LAST_FACE = 12`,
`NEXT_FACE(f) = f + 1`. So the default build is the original behaviour, and
`triangle_fetch_tb` passes unchanged against it. Only non-default masks are new
behaviour, and `triangle_fetch_mask_tb` covers them. Synthesis sees constants
and a small table, not a search.

**Why in B.** Only B knows the face index. Filtering after B would waste ten
fetches and need its own way to move the last marker; skipping in B costs no
cycles for unselected faces and keeps the marker correct by construction. H4
still holds: the unselected faces never reach D, and the selected ones have
area.

**Alternative considered and rejected.** A second ROM image with faces 2-11
rewritten as degenerate (1, 1, 1) triangles, selected through `INIT_FILE`, with
A, B and C unchanged. Run end to end, it gives a byte-identical frame, because D
drops the ten zero-area triangles. It was rejected to keep `cube_init.txt` as
the single source of scene data: a second image hides the scene choice in data
bits, needs its own generator, and drifts from the source.

## triangle_transform: Block C at triangle level

Block B hands over one triangle; `vertex_transform` handles one vertex; Block D
needs one triangle again. `triangle_transform` takes one triangle from B,
transforms its three vertices in three lanes at once, and presents one
screen-space triangle to D. Its output port list is `scene_stub`'s.

| Side | Ports |
|---|---|
| From B | `tri_valid_i`, `tri_ready_o`, `tri_last_i`, `vertex_{a,b,c}_{id,x,y,z}_i` |
| From A | `cos_{x,y,z}_i`, `sin_{x,y,z}_i`, broadcast to all lanes |
| To D | `out_valid_o`, `out_ready_i`, `out_v{0,1,2}_{x,y}_o` (16.16), `out_v{0,1,2}_z_o`, `out_color_o`, `out_last_o` |
| Generics | `DEPTH_W` (8), `BASE_COLOR` (`x"E0"`) |

**The join.**

    all_in_ready   <= lane_in_ready(0) and lane_in_ready(1) and lane_in_ready(2);
    lane_in_valid  <= (others => tri_valid_i and all_in_ready);
    tri_ready_o    <= all_in_ready;
    all_out_valid  <= lane_out_valid(0) and lane_out_valid(1) and lane_out_valid(2);
    out_valid_o    <= all_out_valid;
    lane_out_ready <= (others => out_ready_i and all_out_valid);

Lane 0 carries vertex A, lane 1 B, lane 2 C. `out_last_o` comes from lane 0;
`out_color_o` is `BASE_COLOR`; vertex IDs are dropped (D does not use them).

**Reasoning.**

- *A join, not a broadcast.* The lanes have identical latency and would
  normally stay in step, but `docs/architecture/block_c.md` warns that
  broadcasting B's valid without checking all lanes can duplicate a transfer if
  they drift. With the join all three accept on the same edge and release on the
  same edge. A simulation assertion checks every clock that the three
  `in_ready` and the three `out_valid` agree.
- *No combinational loop.* Each lane's `in_valid` depends on the lanes'
  `in_ready`, and `out_ready` on the lanes' `out_valid`. This is safe only
  because `vertex_transform` drives `in_ready_o` and `out_valid_o` purely from
  its state (`state = IDLE` / `PRESENT`, plus reset), never from its inputs. The
  file says so; a change to that in Block C would turn the join into a loop.
- *Three lanes, not one lane three times.* RQ-91 first said "C single, serial
  over 3 vertices". Three lanes need no sequencer and no payload buffer, for two
  more `fx_mul` instances.
- *Identity rotation is exact.* Block A resets both rotation banks to
  cos = 1.0, sin = 0, and nothing writes them. Every rounded product is then
  exact (`(X * 65536 + 32768) >> 16 = X`, `(Y * 0 + 32768) >> 16 = 0`), so the
  coordinates stay exactly +/-37837 (+/-0.577). That is why the open question
  about rotated vertices just past +/-1.0 does not affect the MVP.

## Depth-cue shading (E5 slot)

Every fragment starts as `0xE0` and is darkened by its own depth just before
E6, from 100 % at depth 0 to about 50 % at depth 255. Numeric contract rule 17;
`depth_cue` in `rtl/shade_pkg.vhd`:

    z8 = top 8 bits of z            (z when DEPTH_W = 8; zero-extended below 8)
    k  = 256 - (z8 >> 1)            (256 at z8 = 0, 129 at z8 = 255)
    R' = (R * k) >> 8,  G' = (G * k) >> 8,  B' = (B * k) >> 8   (RGB332 fields)

| Depth | k | Red field | RGB332 | Where |
|---|---|---|---|---|
| 0 | 256 | 7 | `0xE0` | |
| 54 | 229 | 6 | `0xC0` | Face 12 |
| 201 | 156 | 4 | `0x80` | Face 1 |
| 255 | 129 | 3 | `0x60` | Never drawn (clear value) |

In `draw_pipeline`, behind `SHADE` (default `false`):

    e6_color <= depth_cue(p_color, p_z) when SHADE else p_color;

`gpu_top` sets `SHADE => (SCENE = "CUBE")`.

**Reasoning.**

- *Depth cue, not lighting.* Lighting needs normals, which nothing computes.
- *50 % floor.* A full-range ramp makes face 1 nearly black (red 1 of 7)
  against the black background. On the board's 4-bit DAC, `0xC0` and `0x80`
  become 13/15 and 9/15 red.
- *Per fragment.* The input is the fragment's own z, so when rotation returns
  the shading follows depth across each triangle with no change.
- *In the E5 slot.* The architecture puts per-fragment colour work (texturing)
  between E4 and E6. Texturing replaces this later; E6 and its testbench are
  untouched.
- *Off by default.* `draw_pipeline_tb` keeps comparing the stub scene against
  the rasterizer's reference dump.
- *Timing.* E4's colour register -> three small multiplies (3 x 9, 3 x 9,
  2 x 9 bits) -> E6's `fb_wdata` register: one short stage.
- *In the numeric contract.* The Ada reference must apply the same rule bit for
  bit when it renders this scene.

## Verification

| Bench | What it checks |
|---|---|
| `triangle_fetch_tb` | The original 12-face fetch, unchanged, against the masked B (default mask) |
| `triangle_fetch_mask_tb` | One checker per mask: `"100000000001"` gives faces 1 then 12; `"010000000100"` gives 2 then 10 (last moves to face 10); `"000001000000"` gives face 6 alone with last set. Each checks vertex IDs, vertex A coordinates, the last marker on the right triangle, no fault, and no extra triangle |
| `triangle_transform_tb` | Faces 1 and 12 at identity: six screen vertices and depths 201 / 54 against an independent reference in the bench; `out_ready_i` low for 50 clocks (no duplicate or lost triangle, `tri_ready_o` stays low); two triangles back to back (order kept, last only on the second); reset while computing and while stalled at the output |
| `shade_pkg_tb` | The four rows above, plus green and blue fields at depth 128, white and black |
| `gpu_top_cube_tb` | The full chain at the VGA pins; see `mvp_integration.md` |

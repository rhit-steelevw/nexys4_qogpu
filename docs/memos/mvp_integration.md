# MVP integration: A -> VGA (RQ-78, RQ-96, RQ-99, RQ-100)

Vance Steele, 11/14/2026. Board-verified at commit `8a4a166`.

Files: `rtl/gpu_top.vhd`, `rtl/draw_pipeline.vhd`, `rtl/clear_engine.vhd`,
`rtl/mem_mux.vhd`, `rtl/scene_stub.vhd`, `rtl/triangle_transform.vhd`,
`rtl/shade_pkg.vhd`, `rtl/board/nexys_a7_top.vhd`.
Run: `make sim-gpu-top-cube` (full chain), `make sim-gpu-top` (stub scene),
`make sim` (everything), `make bit` then `make program` (board).

This memo is the overview. Details are in three companion memos:

| Memo | Covers |
|---|---|
| [depth_hazards_markers.md](depth_hazards_markers.md) | E4/E6 marker side-band, the H1-H4 hazard rules, removal of `wr_pending` |
| [front_end_integration.md](front_end_integration.md) | Block B `FACE_MASK`, `triangle_transform` (three-lane Block C), depth-cue shading |
| [board_build.md](board_build.md) | Board wrapper, XDC, bitstream and programming scripts |

## Result

The Nexys A7 shows the MVP scene on a VGA monitor: two overlapping red
triangles at different depths, drawn by the full pipeline
A -> B -> C -> D -> E1-E3 -> E4 -> (E5 slot) -> E6 -> memory controller -> VGA.

The scene is cube faces 1 and 12 from `rtl/data/cube_init.txt` with rotation
held at identity. Face 12 (depth 54) is in front of face 1 (depth 201), so it
covers the top quarter of face 1. Depth shading makes the two faces different
reds, so the occlusion edge is visible.

| Region (framebuffer pixels) | Colour | Pixels |
|---|---|---|
| Face 12: the upper-right half of the square | `0xC0` | 12,696 |
| Face 1, visible part: the left wedge | `0x80` | 6,348 |
| Everything else (bottom wedge and outside the square) | `0x00` | 57,756 |

Lit pixels span x 68-251 and y 51-188, the projected square (67.6-252.4,
50.7-189.3) after the pixel-centre rule (numeric contract rule 2). These
counts are from the frame `gpu_top_cube_tb` captures at the VGA pins.

As RQ-78 states, the MVP is unverified: nothing is compared bit for bit
against the Ada reference yet.

## Block diagram

    start_i (button / auto-start)
       |
    Block A  command_controller --clear--> clear_engine --colour--> framebuffer
       |  frame start          ^                 \--depth fill--> mem_mux
       v                       | frame_done                            |
    asset_memory <-> Block B triangle_fetch (FACE_MASK)                |
                         |                                             |
                    triangle_transform (3 x vertex_transform)          |
                         |  Block C output = the seam                  |
    =====================|=======================================      |
    draw_pipeline        v                                             |
       D tri_setup -> E1-E3 rasterizer -> E4 depth_test --read------> mem_mux -> mem_ctrl_bram
                           ^  (H1 gate)        |  <--rsp---------------/
                           |                   v
                           |               E5 slot: depth_cue (SHADE)
                           |                   v
                           +--- tri_done -- E6 writeback --depth write--> mem_mux
                                               |  \--colour--> framebuffer
                                               +-- frame_done --> Block A
    framebuffer --> vga_scanout (2x2 doubling) --> board top (RGB332 -> 4-4-4) --> VGA pins

## gpu_top

### Generics

| Generic | Default | Meaning |
|---|---|---|
| `DEPTH_W` | 8 | Depth width, 1 to 16 bits. To come from RQ-113's board config package |
| `INTERP` | `true` | `false`: E3 passes z0 (flat-depth scenes only, a timing fallback) |
| `PIX_DIV` | 4 | 100 MHz clock / 4 = 25 MHz pixel enable |
| `SCENE` | `"CUBE"` | `"CUBE"`: A -> asset ROM -> B -> C. `"STUB"`: A -> `scene_stub` |
| `FACE_MASK` | `"100000000001"` | Faces Block B fetches (bit f = face f). MVP: faces 1 and 12 |
| `INIT_FILE` | `"data/cube_init.txt"` | Asset ROM image. The bitstream build passes an absolute path |

### Ports

| Port | Dir | Meaning |
|---|---|---|
| `clk`, `rst_n` | in | 100 MHz; asynchronous active-low reset, synchronized inside (two flops) |
| `start_i` | in | One-cycle pulse: clear and draw one frame |
| `vga_r`, `vga_g` (3), `vga_b` (2), `vga_hs_n`, `vga_vs_n` | out | RGB332 and active-low syncs, all from registers |
| `busy_o` | out | Block A busy |
| `frame_done_o` | out | Sticky: the last frame finished. Cleared by `start_i` or reset |
| `error_o` | out | Block A's sticky error (Block B fault in the CUBE scene) |

The port list has not changed since Integration 2, so the board wrapper never
had to change while the insides did.

### Scene switch

`SCENE` selects one of two `if ... generate` blocks. Both drive the same seam
signals (`s_valid`, `s_v0x` ... `s_last`) and read `s_ready`; only one exists
after elaboration, so there is no multiple-driver conflict. An assertion fails
elaboration for any other value.

| | `g_stub` (`"STUB"`) | `g_cube` (`"CUBE"`) |
|---|---|---|
| Source | `scene_stub`: green and blue screen-space triangles (Integration 2 scene) | `asset_memory` -> `triangle_fetch` -> `triangle_transform` |
| Block A `err_i` | `'0'` | Block B `err_o` |
| Block A rotation outputs | Unused | To `triangle_transform` (identity: nothing writes them) |
| `draw_pipeline` `SHADE` | `false` | `true` |

The stub stays in the build as a fallback. If the board ever shows nothing,
building with `SCENE => "STUB"` separates a front-end problem from a D -> VGA
problem, because the stub path has its own byte-exact reference. The unused
block costs nothing in hardware.

### The seam

`draw_pipeline`'s input is Block C's output interface: one triangle as three
16.16 screen-space vertices, three `DEPTH_W` depths, an RGB332 colour and a
last flag. `scene_stub` and `triangle_transform` have exactly this output port
list, so swapping them touches nothing downstream. The seam was fixed in
Integration 2, before Block C existed, so D -> VGA could be built and tested
against the stub first.

## Frame sequence

Block A (`command_controller`) is the frame sequencer, unchanged from its own
design (see `docs/architecture/block_a.md`):

1. `start_i` while idle: capture the rotation (identity), raise `busy_o`.
2. Pulse `clr_start_o`. The clear engine fills the framebuffer with `0x00` and
   the depth buffer with all ones (255), then pulses `clr_done_i`.
3. Raise `frame_start_valid_o` until the scene source accepts it.
4. Wait for `frame_done_i` from E6, then pulse `done_o` (unless an error was
   seen) and return to idle. `gpu_top` turns `done_o` into the sticky
   `frame_done_o`.

The clear must finish before any fragment: the BRAM depth buffer powers up as
zeros, and with the pass rule `z < stored` every fragment would fail.

## Memory and framebuffer sharing

**Depth buffer:** `mem_ctrl_bram`, 76,800 words of `DEPTH_W` bits, address
`y * 320 + x`, read latency 1, never stalls (memory interface spec, RQ-106).
Three clients share it through `mem_mux`, fixed priority:

| Priority | Client | Access |
|---|---|---|
| 0 (highest) | Clear engine | Write |
| 1 | E6 | Write |
| 2 | E4 | Read; the only reader, so responses go straight to E4 |

`mem_mux` is the Integration 1 inline mux moved into its own entity, with no
behaviour change, so `gpu_top` and `draw_pipeline_tb` use the same one and
RQ-109's arbiter can replace a single file. A client's `ready` depends on the
other clients' `valid`, never on its own.

**Framebuffer:** dual-port BRAM, 320 x 240 RGB332. The write port is a
two-way mux, clear engine first, then E6. They never overlap, because Block A
starts the frame only after `clr_done`; an assertion checks it in simulation.
VGA scan-out owns the read port.

**Clear engine:** `clear_engine` gained the depth port in Integration 2
(`gpu_top` already instantiated it, but the committed file had only the
framebuffer port). It writes one framebuffer word and one depth word per
accepted memory request, stepping only on `mem_req_ready`, so the two buffers
fill in lock-step and a stalling back-end (DDR2) is handled. With BRAM a clear
takes 76,800 clocks (0.77 ms). It waits for `mem_ready` before its first
request, and `done_o` pulses after the last depth write is accepted.

## Clocking and reset

One clock domain at 100 MHz from `CLK100MHZ`. VGA timing runs on a 1-in-4
pixel enable (25 MHz), not a second clock. `CPU_RESETN` goes to `gpu_top`'s
`rst_n`, which is synchronized with two flops; every block uses the
synchronized reset. The memory controller shares it with E4, as `depth_test`
requires (a late response to a read accepted before reset must never be taken
as the answer for the next fragment).

## Verification chain

Each level's frame dump is the reference for the next, so a mismatch points
at the stage that was added.

| Level | Test | Reference |
|---|---|---|
| E1-E3 | `rasterizer_tb` (E4/E6 modelled in the bench) | Ada vectors; dumps `two_triangles.hex` |
| D -> E6 with the real E4/E6 | `draw_pipeline_tb`, `draw_pipeline_blue_first_tb` | Byte-identical to `two_triangles.hex` |
| Whole top, captured at the VGA pins | `gpu_top_tb` (`SCENE => "STUB"`) | Byte-identical to the `draw_pipeline_tb` dump |
| Whole chain with the front end | `gpu_top_cube_tb` (`SCENE => "CUBE"`) | Pixel checks P1-P5 (below) |

`gpu_top_cube_tb` checks:

| Point | Pixel | Expected |
|---|---|---|
| P1 | (160, 70) | `0xC0`: overlap, face 12 in front |
| P2 | (90, 120) | `0x80`: face 1 only |
| P3 | (230, 120) | `0xC0`: face 12 only |
| P4 | (160, 170) | `0x00`: empty bottom wedge |
| P5 | (20, 20) | `0x00`: outside the square |

The VGA capture waits for `frame_done_o`, then samples `vga_r/g/b` on every
second pixel of every second line of one active frame (undoing the 2x2
doubling). Pixel (x, y) leaves the output registers
`4 * ((V_TOTAL - V_SYNC_START + 2y) * H_TOTAL + 2x)` clocks after `vga_vs_n`
falls. One frame is 800 x 525 x 4 = 1.68 M clocks.

Block-level benches also in `make sim`: `clear_engine_tb`, `depth_test_tb`,
`tb_writeback`, `command_controller_tb`, `triangle_fetch_tb`,
`triangle_fetch_mask_tb`, `vertex_transform_tb`, `shade_pkg_tb`,
`triangle_transform_tb`.

## History

| Step | Commit | What changed |
|---|---|---|
| Integration 1 (RQ-96) | `1fe1eba` | `gpu_top` with clear engine, framebuffer, BRAM back-end, VGA; bring-up sequencer |
| E1-E3 merged | `c9e7d28` | Rasterizer from the `e123-pipeline` branch |
| Block C lanes | `aed5063` | `vertex_transform` and normalized cube assets |
| Integration 2 (RQ-99) | `e318ee5` | E4/E6 markers, H1-H4 hazards, `draw_pipeline`, `scene_stub`, `mem_mux`, clear engine depth port, Block A as sequencer, board wrapper, XDC, build scripts |
| Integration 3 (RQ-100) | `8a4a166` | `FACE_MASK`, `triangle_transform`, depth-cue shading, `SCENE` switch, `INIT_FILE` plumbing; MVP scene on the monitor |

## Known follow-ups

- `clockInfo.txt` at the repo root is Vivado debug output; remove it and add it
  to `.gitignore`.
- Record the routed timing (WNS) and utilization of the MVP bitstream in
  `docs/reports/`, with the monitor photo (RQ-103, RQ-105).
- Deferred from the MVP by decision: rotation (Block A's write port is tied
  off), the policy for rotated vertices just past +/-1.0, per-face colour,
  double buffering (needed once frames change while VGA scans out), DDR2
  back-end (RQ-110, RQ-112, RQ-113).
- `scripts/generate_cube_bram.py` breaks the client's two-language rule
  (VHDL + Ada only); port it to Ada before the cube data changes again.

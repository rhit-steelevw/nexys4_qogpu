# E4/E6 markers and depth hazards (RQ-94, RQ-95, RQ-93, RQ-99)

Vance Steele, 11/14/2026.

Files: `rtl/depth_test.vhd` (E4), `rtl/writeback.vhd` (E6),
`rtl/rasterizer.vhd` (H1 gate), `rtl/draw_pipeline.vhd`.
Spec: `docs/architecture/spec/memory_interface.md`, rules 11 and H1-H4.
Run: `make sim-depth-test`, `make sim-writeback`, `make sim-rasterizer`,
`make sim-draw-pipeline`, `make sim-draw-pipeline-blue-first`.

Two changes, made together in Integration 2 so `draw_pipeline` could be
wired: E4 and E6 carry the rasterizer's marker side-band and colour, and depth
hazards are now handled only by the spec's rules H1-H4. E4's `HOLD` state and
`wr_pending` port are gone.

## The problem

The rasterizer (E1-E3) already emitted `px, py, z, kill, eot, eof, color`.
E4 and E6 were written before it and had none of the side-band:

- E4 took `px, py, pz, pu, pv` only. The end-of-triangle and end-of-frame
  markers and the colour could not reach E6.
- E6 had no `tri_done` or `frame_done`, so nothing could tell Block A the frame
  had finished.
- E1 puts `eot` on the bounding-box corner (xmax, ymax), which is usually
  outside the triangle, so it reaches E4 as a `kill = 1` marker. With no `kill`
  input, E4 would depth-test that corner: on a pass E6 paints a stray pixel; on
  a fail the marker is lost, `frame_done` never fires and Block A hangs in
  `WAIT_FRAME`.

## The marker contract

Every rule below follows from one invariant:
**a fragment that carries `eot` or `eof` is never dropped before E6.**

| Fragment at E4 input | E4 | E6 |
|---|---|---|
| `kill = 0`, on screen, depth passes | Read depth, forward with `kill = 0` | Write colour and depth |
| `kill = 0`, depth fails, no marker | Drop | Never sees it |
| `kill = 0`, depth fails, `eot` or `eof` set | Forward with `kill = 1` | No writes; done pulse(s) |
| `kill = 1` with `eot` or `eof` | No memory read; forward with `kill = 1` | No writes; done pulse(s) |
| `kill = 1`, no marker | Drop (E3 already drops these; defensive) | Never sees it |
| Off screen | No memory read; forward as `kill = 1` only if it carries a marker | As above |

## E4: depth_test

FSM, one fragment in flight:

    IDLE --kill or off screen, marker--> PASS (kill = 1)
    IDLE --kill or off screen, no marker--> DROP
    IDLE --otherwise--> REQ --accepted--> WAIT_RSP --rsp.valid--> COMPARE
    COMPARE --z < stored--> PASS (kill = 0)
    COMPARE --fail, marker--> PASS (kill = 1)
    COMPARE --fail, no marker--> DROP
    PASS --pass_ready--> IDLE;  DROP --> IDLE

- `IDLE` latches position, depth, UV, `eot`, `eof` and colour together.
- `REQ` holds `mem_req_valid` and the address until accepted; `WAIT_RSP` makes
  no latency assumption (BRAM answers in 1 clock, DDR2 will take tens).
- Pass rule: `pz < stored_z`; equal depth is dropped.
- New ports: inputs `frag_kill`, `frag_eot`, `frag_eof`, `frag_color`
  (defaults `'0'` / `x"00"`), outputs `pass_kill`, `pass_eot`, `pass_eof`,
  `pass_color`.
- The UV ports stay. E5 (texturing) comes back next quarter; `draw_pipeline`
  ties `pu`/`pv` to zero and leaves `pass_u`/`pass_v` open.
- Port names keep E4's original style (`clk`, `rst_n`, `frag_*`, `pass_*`);
  `draw_pipeline` adapts them.

## E6: writeback

| Fragment | Behaviour |
|---|---|
| `kill = 0` | One framebuffer write (`fb_we` pulse); depth write held until `mem_req_ready`; `eot`/`eof` latched. `tri_done`/`frame_done` pulse on the cycle after the depth write is accepted |
| `kill = 1` | No framebuffer write, no memory request. Stays ready, so the transfer takes one clock. `tri_done`/`frame_done` pulse on the next cycle |
| `eot` and `eof` together | Both outputs pulse on the same cycle |

- E6 accepts a fragment only while idle, so a killed `eot` behind a stalled
  write waits until that write is accepted.
- "Done" means accepted, not issued: the controller keeps requests in order
  (rule 11), so the next triangle's reads and the next frame's clear cannot
  overtake the last write. With BRAM accepted means written; with DDR2 the
  ordering still holds.
- Both done outputs are registered pulses.
- New ports go last in the port list, because `tb_writeback` binds by
  position; trailing defaulted inputs and unconnected outputs keep it
  compiling.

## Depth hazards: H1-H4

The read-modify-write hazard: E4 reads a pixel's depth, and E6 later writes
it. If another fragment for the same pixel reads before that write lands, it
compares against stale depth. The spec handles this with four rules, and they
are now the only mechanism:

| Rule | Statement (spec) | Where it lives |
|---|---|---|
| H1 | E1 does not start the next triangle until it sees `tri_done` from E6 for the current one | Gate in `rasterizer.vhd`, in front of `raster_scan` |
| H2 | E6 pulses `tri_done` only after the `eot` pixel's depth write is accepted, or right away on a killed `eot` once earlier writes are accepted | `writeback.vhd` |
| H3 | `frame_done` follows the same rule for the `eof` pixel | `writeback.vhd` |
| H4 | Every triangle that enters E1 produces an `eot` pixel, even if every pixel is killed, so H1 cannot deadlock | `raster_scan` always emits `eot`; D drops zero-area triangles before E1 unless last, and then E1 sends one `eot`/`eof` marker. E4's invariant carries it to E6 |

**Why this is sufficient.** Inside one triangle E1 visits each pixel once, so
a depth read never targets a word with a write still pending from the same
triangle. Across triangles, H1 drains the pipeline before the next triangle
starts. Everything accepted takes effect in acceptance order (rule 11), and
`mem_mux` serves E6 before E4, so the order of accesses to different addresses
does not matter.

### The H1 gate

In the `rasterizer` wrapper, around `raster_scan`:

- `tri_in_flight` is set on the edge a triangle is accepted from D and cleared
  by `tri_done_i`.
- While it is set, D's `valid` into `raster_scan` and `raster_scan`'s `ready`
  back to D are both masked. The mask is combinational, but `tri_in_flight` is
  a flop, so there is no loop.
- Simulation assertions: a triangle is never accepted in the same cycle as
  `tri_done_i`, and `tri_done_i` never arrives with nothing in flight.
- `tri_done_i` has no default. Left unconnected the build fails; a default of
  `'1'` would turn H1 off without anyone noticing.

The gate is in the wrapper, not in `raster_scan`, because E1/E2 are bit-exact
against the Ada reference with their own testbench. The gate only touches the
handshake.

Cost: one drain per triangle (the last fragment's trip from E1 through E6,
including E3's divider), a few tens of clocks. D sets up the next triangle
during the drain and holds it at its output. Negligible for the MVP; the spec
flags it to revisit for the cube.

### Why `wr_pending` was removed

E4 originally had its own hazard check: a `HOLD` state that waited for a
`wr_pending` input (E6 busy) before every read. The first Integration 2 plan
kept it, driven from an E6 `busy` output, and that design was correct. It was
removed before Integration 2 was committed, so that hazards follow the design
files and nothing else:

- One mechanism to verify instead of two that could disagree.
- `HOLD` made every read wait for the previous pixel's write, even though
  within a triangle the two are always different addresses. Without it the
  next read goes out while the previous write is still pending; `depth_test_tb`
  finishes about 8 us sooner.
- The spec already said E1 waits for `tri_done`; the code did not implement it,
  so code and spec disagreed.

`depth_test_tb` needed one change for this: its `wr_pending => '0'` line.

## Verification

| Bench | What it checks |
|---|---|
| `depth_test_tb` | Original cases (six configurations of random latency 10-40 and stalls), plus: colour carried on a pass; killed `eot` marker forwarded with no read; failed fragment with `eof` forwarded as `kill = 1`; failed fragment without a marker dropped; killed non-marker dropped with no read; killed `eot` + `eof`; off-screen marker forwarded with no read |
| `tb_writeback` | Original 41 fragments and reset while stalled, plus: killed `eot` taken in one clock with no writes and `tri_done` next cycle; passing `eot` with the depth write stalled, `tri_done` only after the accept and exactly once; killed `eot` behind a stalled write not taken until the write is; `eot` + `eof` together on written and killed fragments |
| `rasterizer_tb` | Its E4/E6 stand-in pulses `tri_done` on each consumed `eot`. Passes with the gate in; both frame dumps (`shared_edge.hex`, `two_triangles.hex`) unchanged from before the gate |
| `draw_pipeline_tb`, `draw_pipeline_blue_first_tb` | Real D -> E6 in both draw orders. Green first exercises the depth-fail drop path, blue first the overwrite path. The bench's monitor fails on `frame_done` more than once, on any framebuffer write or memory request after `frame_done`, and on the clear engine and pipeline writing the framebuffer together. H1 is checked by the rasterizer's own assertions, which run inside this bench. Both dumps byte-identical to `two_triangles.hex` |

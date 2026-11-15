# Board wrapper, constraints and bitstream flow (RQ-103, RQ-41)

Vance Steele, 11/14/2026. Board-verified at commit `8a4a166`.

Files: `rtl/board/nexys_a7_top.vhd`, `constraints/nexys_a7_100t.xdc`,
`scripts/build_bit.tcl`, `scripts/program.tcl`, `Makefile` (`bit`, `program`).
Run, from a Vivado-configured shell at the repo root:

    make bit        # synthesize, place, route, write build/bit/nexys_a7_top.bit
    make program    # load it over JTAG

Part: `xc7a100tcsg324-1` (Nexys A7-100T). Vivado 2024.2, non-project batch
mode. Tcl and XDC are the tool configuration the client's language rule allows.

## nexys_a7_top

The board top owns everything specific to the Nexys A7: pin names, button
handling, LEDs and the 4-4-4 VGA DAC. `gpu_top` stays board-independent, keeps
RGB332 ports for its testbenches, and never sees the button.

| Port | Dir | Use |
|---|---|---|
| `CLK100MHZ` | in | 100 MHz board clock, straight to `gpu_top` |
| `CPU_RESETN` | in | Active-low reset button, to `gpu_top`'s `rst_n` (synchronized inside) |
| `BTNC` | in | Centre button: redraw |
| `VGA_R`, `VGA_G`, `VGA_B` (4 each), `VGA_HS`, `VGA_VS` | out | VGA connector |
| `LED(3:0)` | out | Status |

Port names match Digilent's master XDC, so constraint lines can be copied
unchanged.

Generics, passed through to `gpu_top`:

| Generic | Default | Use |
|---|---|---|
| `SCENE` | `"CUBE"` | `"STUB"` builds the Integration 2 green/blue scene for debugging |
| `INIT_FILE` | `"data/cube_init.txt"` | Asset ROM image; `build_bit.tcl` overrides it with an absolute path |

**Start pulses.** `gpu_top` draws one frame per `start_i` pulse. Two sources:

- *Auto-start:* one pulse about 1 ms (100,000 clocks) after reset is released,
  so the scene appears with no button press. The counter runs on a two-flop
  synchronized copy of `CPU_RESETN` and fires once per reset.
- *BTNC:* two-flop synchronizer, then a 10 ms (1,000,000-clock) debounce: the
  stable value follows the synchronized input only after it has differed for
  the whole window. A rising edge of the stable value gives one start pulse.

Block A ignores a start while it is busy, so a press during a frame does
nothing.

**RGB332 to 4-4-4.** The board has a 4-bit resistor DAC per colour. Each field
is widened by replicating its top bit, so full scale maps to full scale and
black stays black:

    VGA_R <= r3 & r3(2);   VGA_G <= g3 & g3(2);   VGA_B <= b2 & b2;

| RGB332 field | 4-bit output |
|---|---|
| R or G = 7 | 15 |
| R = 6 (`0xC0`, face 12) | 13 |
| R = 4 (`0x80`, face 1) | 9 |
| B = 3 | 15 |

Zero-padding instead would cap white at 14/15 and blue at 12/15. This is
wiring only: `gpu_top`'s colour and sync outputs already leave from registers.

**LEDs.**

| LED | Meaning | What it tells you |
|---|---|---|
| LED0 | Heartbeat, bit 26 of a free-running counter (about 0.75 Hz) | Bitstream loaded and clock running |
| LED1 | `busy_o` | Stuck on: a frame never finished (for example `frame_done` lost) |
| LED2 | `frame_done_o` (sticky) | On: the last frame completed |
| LED3 | `error_o` | On: Block B faulted (bad vertex ID, for example an empty ROM) |

Without an ILA these separate "pipeline hung" from "VGA wrong" at a glance.

## Constraints: constraints/nexys_a7_100t.xdc

Only the pins in use, all `LVCMOS33`, copied from Digilent's
`Nexys-A7-100T-Master.xdc`. The clock, reset and VGA pins are confirmed by the
working image on the monitor (`8a4a166`); confirm BTNC and the LEDs during the
bring-up checklist below.

| Signal | Pin(s) |
|---|---|
| `CLK100MHZ` | E3 |
| `CPU_RESETN` | C12 |
| `BTNC` | N17 |
| `LED[0..3]` | H17, K15, J13, N14 |
| `VGA_R[0..3]` | A3, B4, C5, A4 |
| `VGA_G[0..3]` | C6, A5, B6, A6 |
| `VGA_B[0..3]` | B7, C7, D7, D8 |
| `VGA_HS`, `VGA_VS` | B11, B12 |

Timing and configuration:

- `create_clock -period 10.000` on `CLK100MHZ`: the whole design is one 100 MHz
  domain; VGA uses a 1-in-4 enable, not a second clock.
- `set_false_path -from` `CPU_RESETN` and `BTNC`: both are asynchronous and go
  through two-flop synchronizers.
- `set_false_path -to` the VGA and LED outputs: they leave from registers, and
  a monitor samples them with no timing relation to our clock, so an output
  delay would mean nothing.
- `CFGBVS VCCO`, `CONFIG_VOLTAGE 3.3`: the configuration bank setting for this
  board (silences the DRC warning).

## scripts/build_bit.tcl

Non-project flow, the same style as `synth_ooc.tcl`:

    vivado -mode batch -nojournal -nolog -notrace -source scripts/build_bit.tcl \
        -tclargs <top> <part> <xdc> <src_1.vhd> [<src_2.vhd> ...]

1. Read every source as VHDL-2008 in the order given (the Makefile's
   `BOARD_SRCS`), then the XDC.
2. Resolve the asset ROM image to an absolute path,
   `<repo>/rtl/data/cube_init.txt`, and stop with an error if it is missing.
3. `synth_design -top <top> -part <part> -generic "INIT_FILE=<absolute path>"`.
4. `opt_design`, `place_design`, `route_design`.
5. Write `build/bit/<top>_util_synth.rpt`, `_timing.rpt`, `_util.rpt` and
   `_drc.rpt`.
6. Read the worst setup slack; if WNS < 0, print `TIMING FAILED` and exit 1, so
   `make bit` fails loudly instead of producing a bitstream that may not work.
7. `write_bitstream` to `build/bit/<top>.bit`.

**Why the ROM path is absolute.** `asset_memory` loads its image during
elaboration with `textio`. A relative path is resolved from Vivado's working
directory, not from `rtl/`. In simulation `sim.tcl` copies `cube_init.txt` into
the run directory, so the default `"data/cube_init.txt"` works there; synthesis
needs the absolute path. Keep the checkout path free of spaces: the path rides
inside a `-generic` string.

## scripts/program.tcl

Opens the hardware manager, connects to the local hardware server, opens the
first target, picks the first `xc7a100t*` device, sets `PROGRAM.FILE` and
programs it. `make program` passes `build/bit/nexys_a7_top.bit`. The board must
be on USB with the JTAG drivers installed.

## Bring-up checklist

1. `make sim` passes (in particular `gpu_top_cube_tb` and `gpu_top_tb`).
2. `make bit`: no `TIMING FAILED`; check `build/bit/nexys_a7_top_timing.rpt`
   for WNS and `_util.rpt` for resources.
3. `make program`; LED0 blinks.
4. About 1 ms later LED2 lights and the monitor shows the scene (two red
   triangles, the brighter one covering the top of the dimmer one).
5. BTNC redraws the same image. A frame takes about 1-2 ms, so the LED changes
   during a redraw are too short to see.

If nothing appears: LED0 off means the bitstream or clock; LED1 stuck on means
the frame never finished; LED3 on means Block B faulted (check the ROM path).
Rebuilding with `SCENE => "STUB"` on `nexys_a7_top` shows whether the problem
is in the front end or in D -> VGA, because the stub path has its own
byte-exact reference.

## To record

- WNS and utilization (LUTs, registers, BRAM, DSP) of the MVP bitstream, from
  the reports above, in `docs/reports/` with the monitor photo.
- `clockInfo.txt` at the repo root is Vivado debug output from a GUI project
  build (design `design_1`), not from this flow. Remove it and add it to
  `.gitignore`.

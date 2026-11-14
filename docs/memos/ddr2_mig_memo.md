# DDR2 / MIG Memo (Nexys A7-100T)
#created with aid from AI 

RQ-110 · Sprint 3

- **[doc]** taken from a document (source named in the row)
- **[derived]** calculated from other rows, not read from the tool
- **[confirm]** expected value, must be checked in the MIG GUI, generated port list, or UG586
- **[measure]** comes from the xsim example-design run or the board

## Memory and clocks

| Item | Value | Tag | Source / how to check |
|---|---|---|---|
| Memory part | MT47H64M16HR-25E, x16, 1 Gib = 128 MiB, single rank | [doc] | Digilent manual table 3.1. Prose in section 3.1 says `-25:H`, and a third-party guide says `-26E`. Use the part name the Digilent `.prj` selects |
| Memory clock period | 3077 ps (about 325 MHz, 650 MT/s) | [doc] | Digilent table 3.1. 3000 ps is the limit, 3077 ps is the one the 100 MHz board clock can generate |
| PHY to controller ratio | 4:1 | [confirm] | MIG GUI, "Controller Options" page |
| `ui_clk` frequency | 325 / 4 = 81.25 MHz (12.31 ns) | [derived] | Check the `ui_clk` period in the example-design sim |
| UI data width | 2 x nCK_PER_CLK x 16 = 2 x 4 x 16 = 128 bits | [derived] | Port list of the generated core |
| UI mask width | 128 / 8 = 16 bits | [derived] | Port list |
| Burst | BL8 on a x16 bus = 8 x 16 = 128 bits per UI word | [derived] | UG586 |
| `app_addr` width | 27 = 13 row + 10 column + 3 bank + 1 rank | [confirm] | Port list. Row and column counts come from the part in the MIG GUI |
| `app_addr` unit | One address = one 16-bit column location. One UI word = 8 addresses, so the address steps by 8. Byte address = `app_addr` x 2 | [confirm] | UG586 addressing section, and the address step in the example design's traffic generator |
| `app_cmd` | `000` write, `001` read | [doc] | UG586 and the Xilinx example design |
| Address order | Pick one in the GUI (BANK_ROW_COLUMN or ROW_BANK_COLUMN) and record it here | [confirm] | Digilent `.prj` |
| Ordering | `ORDERING = "STRICT"` unless UG586 shows normal ordering still keeps a read behind a write to the same address (memory_interface.md rule 11) | [confirm] | `.prj` and UG586 |
| Write mask polarity | Expected: 1 = byte not written. Check it in the sim waveform | [confirm] | UG586, then a masked write in xsim |

## Input clock and reset

| Item | Value | Tag | Source / how to check |
|---|---|---|---|
| Board clock | 100 MHz on pin E3, bank 35, 3.3 V | [doc] | Digilent manual section 5 |
| MIG `sys_clk_i` and `clk_ref_i` | 200 MHz, both from our own MMCM on the 100 MHz clock | [confirm] | Ticket. In the GUI set the input clock period to 5000 ps and the reference clock to the system clock, buffer type "No Buffer" |
| Why our own MMCM | Digilent forum report: letting the MIG make its clocks from a 100 MHz input gave an IDELAYCTRL REFCLK of 189.583 MHz and a timing error. A third-party tutorial also hit a bank-35 3.3 V conflict when `sys_clk_i` came straight from a pin | [doc] | forum.digilent.com topic 24653 and the MicroBlaze-DDR3 tutorial. Not our own result |
| `sys_rst` polarity | Set in the GUI ("System Reset Polarity"). Record it here | [confirm] | Generated port list and `.prj` |
| `ui_clk_sync_rst` | Active high, synchronous to `ui_clk` | [confirm] | UG586 |
| `init_calib_complete` | Active high, in the `ui_clk` domain. Treat it as asynchronous when it goes to any other clock | [confirm] | UG586 |
| CPU_RESETN | Active low, pin C12 | [doc] | Digilent manual section 9 and XDC |

## Measured values

| Item | Value | Tag |
|---|---|---|
| Read latency, accept to `app_rd_data_valid` (`ui_clk` cycles) | min ___ / typical ___ / max ___ | [measure] |
| Longest `app_rdy` low period seen (cycles) | ___ | [measure] |
| Longest `app_wdf_rdy` low period seen (cycles) | ___ | [measure] |
| Cycles from `app_en` with a write command to `app_wdf_wren` accepted | ___ | [measure] |
| Calibration done in simulation (with and without calibration bypass) | ___ | [measure] |
| Latency range chosen for `mig_ui_model` (`RD_LAT_MIN`, `RD_LAT_MAX`) | ___ , ___ | [measure] |

Screenshot of the UI handshake from the example design: `docs/memos/images/mig_ui_handshake.png` (to add).

Note: memory_interface.md counts latency in `clk_i` cycles. The values above are in `ui_clk` cycles. The FIFO crossing in the back-end (RQ-112) adds to them.

## Settings from Digilent (manual table 3.1)

Data width 16, data mask enabled, chip select enabled, Rtt nominal 50 ohm, internal Vref enabled, internal termination impedance 50 ohm. The pinout comes from the Digilent MIG `.prj` or UCF. The Nexys A7 XDC has no DDR2 pins, and the MIG constraints supply them.

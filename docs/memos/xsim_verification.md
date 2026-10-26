Counter simulation verification
Current shared-runner status - PASSED

Verified on Windows on 2026-10-26 using Vivado 2024.2 and GNU Make 4.4.1.

A fresh clone of local branch alex/rq85-clean, commit 6e46c76, was created in C:\\Users\\freelal\\rq85-check using git clone --no-local. No previous build outputs were copied.

Command: make sim-counter

Result: PASS: counter\_tb

Exit code: 0

After the run, git status --short produced no output.

This verifies the shared-runner success path. The intentional failure test below was performed with the old standalone runner, not the shared script.

Historical standalone tests — 2026-10-25
Environment: Windows, C:\\Xilinx\\Vivado\\2024.2; Vivado v2024.2, SW Build 5239630; Simulator v2024.2.0. These tests used the former xsim-starter workspace and scripts/sim\_counter.tcl wrapper.

1. Initial simulation: exit 0; PASS at 201 ns.
2. Intentional mismatch (expected + 1): assertion failed at cycle 1, 7 ns. xsim returned 0; the old failure guard made outer Vivado return 1. Original testbench restored immediately afterward.
3. Restored source: exit 0; PASS at 201 ns.
4. Copy under space path check\\xsim starter: exit 0; PASS at 201 ns.
5. xvhdl -help: exit 0; documented --2008 and single-dash equivalents. Builds used --2008.
Historical success text: Note: PASS: all 20 cycles checked (reset, hold, increment).

Coverage: initial asynchronous reset, reset on cycles 1–2 and 15, increments, hold on cycles 8–9, and all 20 rising-edge values. Rollover, unknown inputs, and physical-board timing were not covered. The Makefile target was not executed during the October 25 tests; it passed on October 26 as recorded above.


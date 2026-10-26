Counter simulation verification
Current shared-runner status — PENDING
No new shared scripts/sim.tcl, fresh-clone, or make sim-counter run has been verified. GNU Make was previously missing from PATH. Historical standalone results below do not validate the current integration.

Next: configure GNU Make and Vivado, run make sim-counter from a fresh checkout, and immediately record its exit code. Confirm PASS: counter_tb, exit 0, and counter_tb: ALL TESTS PASSED in build/sim/counter_tb/xsim.log. Record the revision, tool versions, and fresh logs.

The shared runner checks the success substring without independently scanning error markers; it has no Windows wrapper. Historical failure-guard/path tests do not apply to it. Hardening is deferred to a follow-up PR.
Historical standalone tests — 2026-10-25
Environment: Windows, C:\Xilinx\Vivado\2024.2; Vivado v2024.2, SW Build 5239630; Simulator v2024.2.0. These tests used the former xsim-starter workspace and scripts/sim_counter.tcl wrapper.
1. Initial simulation: exit 0; PASS at 201 ns.
2. Intentional mismatch (expected + 1): assertion failed at cycle 1, 7 ns. xsim returned 0; the old failure guard made outer Vivado return 1. Original testbench restored immediately afterward.
3. Restored source: exit 0; PASS at 201 ns.
4. Copy under space path check\xsim starter: exit 0; PASS at 201 ns.
5. xvhdl -help: exit 0; documented --2008 and single-dash equivalents. Builds used --2008.
Historical success text: Note: PASS: all 20 cycles checked (reset, hold, increment).

Coverage: initial asynchronous reset, reset on cycles 1–2 and 15, increments, hold on cycles 8–9, and all 20 rising-edge values. Rollover, unknown inputs, and physical-board timing were not covered. The required Makefile target was not executed.
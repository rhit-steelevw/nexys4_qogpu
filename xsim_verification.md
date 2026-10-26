Verified on 2026-10-25 on this Windows computer.
Installation: C:\Xilinx\Vivado\2024.2
Vivado v2024.2 (64-bit), SW Build 5239630 (Nov 08 2024).
Vivado Simulator v2024.2.0.

Observed process results:
1. Initial working simulation: exit 0; PASS at 201 ns.
2. Intentional assertion mismatch: replaced the cycle assertion's
   to_unsigned(expected, 8) with to_unsigned(expected + 1, 8).
   Assertion failed at cycle 1, time 7 ns. xsim itself exited 0.
   Final Tcl failure guard rejected the log and outer Vivado exited 1.
   Original testbench was restored immediately after the run.
3. Restored final source with failure guard: exit 0; PASS at 201 ns.
4. Same source in "space path check\xsim starter": exit 0;
   PASS at 201 ns. Confirms project paths containing spaces.
5. xvhdl -help: exit 0. It lists --2008 and states that double-dash
   switches may also be used with a single dash. Actual builds used --2008.

The command used for the restored final source (from project root):
"C:\Xilinx\Vivado\2024.2\bin\vivado.bat" -mode batch -source scripts/sim_counter.tcl -log build/final-pass.log -journal build/final-pass.jou

PASS text:
Note: PASS: all 20 cycles checked (reset, hold, increment)

Coverage: initial asynchronous reset, reset on cycles 1-2 and 15,
increments, enable hold on cycles 8-9, all 20 rising-edge values.
Not covered: 255-to-0 rollover, unknown inputs, timing on a physical board.
GNU Make not found on PATH; optional Makefile target not executed.
No GUI, board programming, installations, persistent PATH edits,
existing repository changes, commits, pushes, or PRs.

Full test logs are retained locally in the project's build folder;
generated build outputs are intentionally excluded from the ZIP.

Runner troubleshooting during development:
- Restricted sandbox could not enter Vivado's installation directory;
  approved elevated execution successfully ran the installed tools.
- First nested cmd quoting attempt exited 1; corrected by generating a
  small run_tool.cmd file inside build. All simulations above used the fix.
- vivado -version printed the version but returned 1; actual batch
  simulations, not the version command, establish successful operation.

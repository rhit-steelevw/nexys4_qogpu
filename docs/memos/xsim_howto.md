Counter simulation
Run the 8-bit counter testbench with Vivado Simulator (xsim); no FPGA board is required. The testbench checks asynchronous active-low reset, enabled increments, and disabled hold behavior over 20 cycles.
Prerequisites
Install Vivado with xsim and GNU Make. Both VHDL sources require VHDL-2008. GNU Make was unavailable during the historical tests and must be available on PATH for the required target.

Use the existing repository Makefile and shared scripts/sim.tcl, with rtl/counter.vhd and tb/counter\_tb.vhd.
Run
In Windows Command Prompt, enter these lines separately. Replace the repository path; adjust the Vivado path if necessary.
cd /d "C:\\path\\to\\nexys4\_qogpu"
call "C:\\Xilinx\\Vivado\\2024.2\\settings64.bat"
where make
where vivado
where xvhdl
where xelab
where xsim
make sim-counter
echo %ERRORLEVEL%
Resolve missing tools before running make. Run the final echo immediately after make to capture its exit code. The setup changes this terminal's environment, not the permanent PATH.

The existing target's recipe is:
$(VBATCH) -source scripts/sim.tcl -tclargs counter\_tb rtl/counter.vhd tb/counter\_tb.vhd
Expected result
Success should print PASS: counter\_tb, return 0, and leave counter\_tb: ALL TESTS PASSED in build/sim/counter\_tb/xsim.log. Investigate nonzero results and tool errors; an echoed command is not a test result.

The shared runner resolves paths from its own location, recreates build/sim/counter\_tb, compiles with xvhdl --2008, elaborates, and runs xsim in batch mode. Preserve logs before rerunning; avoid concurrent runs in one checkout.

It checks the final-report substring, not separate error markers, and has no Windows wrapper. The shared-runner success path passed a fresh-clone test on 2026-10-26.


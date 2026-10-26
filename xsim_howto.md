# Counter simulation

This project tests an 8-bit VHDL counter in Vivado Simulator (xsim). No FPGA board is required.

## What the code does

`rtl/counter.vhd` stores an unsigned 8-bit count using `numeric_std`. When `rst_n` is 0, it resets immediately to 0 (active-low, asynchronous reset). Otherwise, each rising clock edge increments the count when `en` is 1 or holds it when `en` is 0. `q` shows the count.

`tb/counter_tb.vhd` automatically tests whether the counter works. It resets and checks for 0, creates clock pulses and checks increments when enabled, disables counting and checks that the value holds, then resets again and checks for 0. It compares the actual output with the expected value over 20 clock cycles: **FAIL** if a check is wrong, otherwise **PASS**. A short wait after each rising edge lets signal updates settle before checking.

## Requirements and commands

Install AMD Vivado with its simulator if it is not already available. This project was tested with Vivado 2024.2 on Windows. Both VHDL files use **VHDL-2008**. GNU Make is needed for the ticket's `sim-counter` build target; direct Vivado is sufficient for a local simulation.

Open **Windows Command Prompt**. Change to the project root: the folder containing `rtl`, `tb`, `scripts`, and `Makefile`. Replace the example project path below with your own. If Vivado is installed elsewhere, adjust the setup path too.

```bat
cd /d "C:\path\to\xsim-starter"
call "C:\Xilinx\Vivado\2024.2\settings64.bat"
if not exist build mkdir build
vivado -mode batch -source scripts/sim_counter.tcl -log build/vivado.log -journal build/vivado.jou
echo %ERRORLEVEL%
```

Enter the lines separately. The setup changes only this terminal and its child processes; it does not permanently edit PATH. Create `build` before starting Vivado with those log paths.

Success means exit code **0** and this actual result in `build/counter_result.log`:

```text
Note: PASS: all 20 cycles checked (reset, hold, increment)
```

An echoed Tcl line mentioning PASS is not the test result. If the command returns **1**, check the first error in the logs. Run one simulation at a time per project folder.

With GNU Make available in the configured terminal, use the required build target:

```bat
make sim-counter
echo %ERRORLEVEL%
```

The target creates `build` and runs the same simulation. The minimal direct entry is also supported:

```bat
vivado -mode batch -source scripts/sim_counter.tcl
```

That minimal command leaves Vivado's own log and journal in the project root.

## Tool flow and submission files

`scripts/sim_counter.tcl` runs `xvhdl --2008` on both VHDL files, then `xelab counter_tb -s counter_sim`, then xsim in batch mode. Tcl only configures and runs the tools. On Windows it calls Vivado's `.bat` tools through a generated command file. It checks tool exit status and requires a fresh final PASS with no failure/error markers, because xsim can return 0 after an assertion failure.

Keep `rtl/`, `tb/`, `scripts/`, `Makefile`, `.gitignore`, and this memo together. `.gitignore` excludes generated build outputs and logs; a source package can omit those outputs while the local testing records remain. `xsim-starter/xsim_verification.md` is an assistant-written record of observed tests, not a simulator-generated report.

The standalone `sim-counter` target is provided. GNU Make was unavailable, so that target has not been executed. 
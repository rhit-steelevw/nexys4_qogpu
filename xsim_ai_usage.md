Used AI to help with the simulation runner, how-to documentation, and verification notes.

Simulation Runner:
scripts/sim_counter.tcl
It automatically:
1. Compiles VHDL files.
2. Builds the simulation.
3. Runs the testbench.
4. Checks for PASS or failure and returns 0 or 1.

Used AI to understand how port map connects the testbench signals to the counter’s inputs and output. 
Used AI to understand why the testbench needs its own signals and how := differs from <=.

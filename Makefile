# Wrapper around Vivado batch TCL  scripts
# Need Vivado on $PATH

VIVADO ?= vivado
VBATCH = $(VIVADO) -mode batch -nojournal -nolog -notrace

FB_SRCS = rtl/qogpu_pkg.vhd rtl/framebuffer.vhd

.PHONY: sim sim-framebuffer sim-counter synth-framebuffer synth-framebuffer-35t build clean

# all tb, add each new sim-* targ here
sim: sim-framebuffer sim-counter

sim-framebuffer:
	$(VBATCH) -source scripts/sim.tcl -tclargs framebuffer_tb $(FB_SRCS) tb/framebuffer_tb.vhd

sim-counter:
	$(VBATCH) -source scripts/sim.tcl -tclargs counter_tb rtl/counter.vhd tb/counter_tb.vhd

# NEXYS A7-100T (MVP demo)
synth-framebuffer:
	$(VBATCH) -source scripts/synth_ooc.tcl -tclargs framebuffer xc7a100tcsg324-1 clk_i 10.0 $(FB_SRCS)

# Mercury 2 - part string needs confirming
synth-framebuffer-35t:
	$(VBATCH) -source scripts/synth_ooc.tcl -tclargs framebuffer xc7a35tftg256-1 clk_i 10.0 $(FB_SRCS)

build:

clean:
	rm -rf build .Xil

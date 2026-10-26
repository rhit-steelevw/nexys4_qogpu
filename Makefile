.PHONY: sim build clean sim-counter

sim:

build:

clean:

ifeq ($(OS),Windows_NT)
sim-counter: SHELL := cmd.exe
sim-counter: .SHELLFLAGS := /d /c
endif

sim-counter:
ifeq ($(OS),Windows_NT)
	if not exist build mkdir build
else
	mkdir -p build
endif
	vivado -mode batch -source scripts/sim_counter.tcl -log build/vivado.log -journal build/vivado.jou
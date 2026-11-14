# Build the Nexys A7 bitstream, non-project mode (RQ-103)
# To use:
#   vivado -mode batch -nojournal -nolog -notrace -source scripts/build_bit.tcl \
#       -tclargs <top> <part> <xdc> <src_1.vhd> [<src_2.vhd> ...]
# Sources are read as VHDL-2008 in the order given.
# Outputs go to build/bit/: <top>.bit, timing and utilization reports.
# Exits 1 if routed timing fails (WNS < 0), so `make bit` fails loudly.

if {[llength $argv] < 4} {
    puts "usage: -tclargs <top> <part> <xdc> <src.vhd> ..."
    exit 2
}
lassign $argv top part xdc
set repo [file normalize [file join [file dirname [info script]] ..]]
set out  [file join $repo build bit]
file mkdir $out

foreach f [lrange $argv 3 end] {
    read_vhdl -vhdl2008 [file join $repo $f]
}
read_xdc [file join $repo $xdc]

synth_design -top $top -part $part
report_utilization -file [file join $out ${top}_util_synth.rpt]

opt_design
place_design
route_design

report_timing_summary -file [file join $out ${top}_timing.rpt]
report_utilization    -file [file join $out ${top}_util.rpt]
report_drc            -file [file join $out ${top}_drc.rpt]

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
if {$wns < 0} {
    puts "TIMING FAILED: WNS = $wns"
    exit 1
}

write_bitstream -force [file join $out ${top}.bit]
puts "build_bit: wrote [file join $out ${top}.bit]"
exit 0

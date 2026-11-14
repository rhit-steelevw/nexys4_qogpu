# Program the Nexys A7 over JTAG
# To use:
#   vivado -mode batch -nojournal -nolog -notrace -source scripts/program.tcl \
#       -tclargs <file.bit>

if {[llength $argv] < 1} {
    puts "usage: -tclargs <file.bit>"
    exit 2
}
set bit [file normalize [lindex $argv 0]]

open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices xc7a100t*] 0]
current_hw_device $dev
set_property PROGRAM.FILE $bit $dev
program_hw_devices $dev
puts "program: loaded $bit"
close_hw_manager
exit 0

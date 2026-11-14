# use (from the repo root):
#   vivado -mode batch -nojournal -nolog -notrace -source scripts/gen_mig.tcl

set part xc7a100tcsg324-1
set name mig_ddr2

set repo [file normalize [file join [file dirname [info script]] ..]]
set prj  [file join $repo ip mig_ddr2 mig_a.prj]
set out  [file join $repo build mig_gen]

if {![file exists $prj]} {
    puts "ERROR: $prj not found. Generate the core once in the MIG wizard and commit the .prj."
    exit 1
}

file delete -force $out
file mkdir $out

create_project -in_memory -part $part
# the VHDL top level needs a VHDL instantiation template, not Verilog
set_property target_language VHDL [current_project]

create_ip -name mig_7series -vendor xilinx.com -library ip -module_name $name -dir $out
set ip     [get_ips $name]
set ip_dir [file dirname [get_property IP_FILE $ip]]

# The core looks for the .prj next to the .xci, so give it a copy and a relative name
file copy -force $prj [file join $ip_dir mig_a.prj]

# These four are the only parameters Digilent's own mig_7series .xci marks as user-set
set_property -dict [list \
    CONFIG.XML_INPUT_FILE {mig_a.prj} \
    CONFIG.RESET_BOARD_INTERFACE {Custom} \
    CONFIG.MIG_DONT_TOUCH_PARAM {Custom} \
    CONFIG.BOARD_MIG_PARAM {Custom}] $ip

generate_target all $ip

puts "Generated $name for $part"
puts "IP files:  $ip_dir"
puts "Port list: look for $name.vho (or .veo) in that folder and compare it with the memo"
exit 0
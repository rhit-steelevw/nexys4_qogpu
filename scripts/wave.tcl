# Compile, elaborate with debug and open one VHDL tb in the xsim GUI
# To use:
#   vivado -mode batch -nojournal -nolog -notrace -source scripts/wave.tcl \
#       -tclargs <tb> <src_1.vhd> [<src_2.vhd> ...]
# Same arguments as sim.tcl. Nothing is run: add signals, then run in the GUI
# (run 20 us). Do not run -all on the big benches, the wave database gets huge
# Outputs go to build/wave/<tb>/ (xsim.dir, wdb). Test files from tb/vectors/
# are copied there so the tb can open them by bare file name

if {[llength $argv] < 2} {
    puts "usage: -tclargs <tb> <src.vhd ..."
    exit 2
}
set top [lindex $argv 0]
set repo [file normalize [file join [file dirname [info script]] ..]]
set srcs {}
foreach f [lrange $argv 1 end] {
    lappend srcs [file normalize [file join $repo $f]]
}
set run_dir [file join $repo build wave $top]
file delete -force $run_dir
file mkdir $run_dir
file mkdir [file join $run_dir data]
file copy -force \
    [file join $repo rtl data cube_init.txt] \
    [file join $run_dir data cube_init.txt]
foreach v [glob -nocomplain -directory [file join $repo tb vectors] *.txt *.csv] {
    file copy -force $v $run_dir
}
cd $run_dir

set ext [expr {$::tcl_platform(platform) eq "windows" ? ".bat" : ""}]

proc step {name args} {
    puts "== $name"
    if {[catch {exec -ignorestderr {*}$args} out]} {
        puts $out
        puts "FAIL: $name failed (see logs in [pwd])"
        exit 1
    }
}

# top-level signals of the tb are added so the wave window is not empty
set fh [open init.tcl w]
puts $fh "add_wave /*"
close $fh

step xvhdl xvhdl$ext --2008 {*}$srcs
step xelab xelab$ext -debug typical -s ${top}_dbg work.$top
puts "== xsim GUI (close the window to return)"
catch {exec -ignorestderr xsim$ext ${top}_dbg -gui -tclbatch init.tcl -log xsim.log} out
exit 0

# Run from Vivado batch mode. This script only configures/runs the tools.
set root [file normalize [file join [file dirname [info script]] ..]]
set build [file join $root build]
file mkdir $build
cd $build

# Use the tools belonging to the Vivado installation running this script.
set bin [file join $::env(XILINX_VIVADO) bin]
proc run_tool {name args} {
    global bin
    if {$::tcl_platform(platform) eq "windows"} {
        # A small generated .cmd avoids nested cmd/Tcl quoting problems.
        # CALL returns here after the vendor's .bat launcher finishes.
        set words [list call "\"[file nativename [file join $bin $name.bat]]\""]
        foreach arg $args { lappend words "\"$arg\"" }
        set wrapper [open run_tool.cmd w]
        puts $wrapper "@echo off\n[join $words { }]\nexit /b %errorlevel%"
        close $wrapper
        exec $::env(COMSPEC) /d /c run_tool.cmd >@stdout 2>@stderr
    } else {
        exec [file join $bin $name] {*}$args >@stdout 2>@stderr
    }
}

if {[catch {
    run_tool xvhdl --2008 [file join $root rtl counter.vhd] [file join $root tb counter_tb.vhd]
    run_tool xelab counter_tb -s counter_sim
    # Erase the old result first: yesterday's PASS must never count today.
    close [open counter_result.log w]
    run_tool xsim counter_sim -R -onerror quit -onfinish quit -log counter_result.log
    set result_file [open counter_result.log r]
    set result [read $result_file]
    close $result_file
    # Some simulator errors can still return zero. Require completion too.
    if {![string match {*Note: PASS: all 20 cycles checked (reset, hold, increment)*} $result]
        || [regexp -nocase {FAIL:|Failure:|Fatal:|Error:} $result]} {
        error "testbench failed or did not reach its final PASS"
    }
} message]} {
    puts stderr "FAIL: $message"
    exit 1
}
puts "Simulation command completed successfully."
exit 0

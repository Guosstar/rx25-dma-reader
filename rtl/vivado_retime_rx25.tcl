# ---------------------------------------------------------------------------
# vivado_retime_rx25.tcl -- last attempt at the 59 ps before touching RTL.
#
# The failing path is unchanged across two optimisation rounds: the host command
# FIFO's BRAM output drives five LUT levels of decode before landing in
# asmcehnk_fifo's rw register, all at 402.8 MHz.  Backward retiming can move the
# capturing flop into that LUT cone, which is exactly the shape of this path.
#
# Runs on an existing routed checkpoint; writes the bitstream only if setup and
# hold are both clean afterwards.
#
# usage: vivado -mode batch -source vivado_retime_rx25.tcl
# ---------------------------------------------------------------------------

set script_dir [file normalize [file dirname [info script]]]
set project_dir [file join $script_dir build_rx25]
if {[info exists ::env(AS02_PROJECT_DIR)] && $::env(AS02_PROJECT_DIR) ne ""} {
    set project_dir [file normalize $::env(AS02_PROJECT_DIR)]
}
set xpr [file join $project_dir fpga.xpr]
if {![file exists $xpr]} { error "no project at $xpr" }

proc as02_wns {} {
    return [get_property SLACK [lindex [get_timing_paths -delay_type max -max_paths 1] 0]]
}
proc as02_whs {} {
    return [get_property SLACK [lindex [get_timing_paths -delay_type min -max_paths 1] 0]]
}

open_project $xpr
open_run impl_1
puts "AS02_RX25 retime: start WNS=[as02_wns] WHS=[as02_whs]"

phys_opt_design -critical_cell_opt -retime -placement_opt -routing_opt
report_timing_summary -delay_type min_max -max_paths 20 \
    -file [file join $project_dir fpga_rx25_timing_retime.rpt]
puts "AS02_RX25 retime: after phys_opt WNS=[as02_wns] WHS=[as02_whs]"

if {[as02_wns] < 0} {
    # Retiming moved the flop but the router is now looking at different cells.
    route_design -directive AggressiveExplore
    report_timing_summary -delay_type min_max -max_paths 20 \
        -file [file join $project_dir fpga_rx25_timing_retime2.rpt]
    puts "AS02_RX25 retime: after re-route WNS=[as02_wns] WHS=[as02_whs]"
}

set setup_fail [get_timing_paths -quiet -delay_type max -max_paths 1 -slack_lesser_than 0]
set hold_fail  [get_timing_paths -quiet -delay_type min -max_paths 1 -slack_lesser_than 0]
if {[llength $setup_fail] || [llength $hold_fail]} {
    report_timing -delay_type max -max_paths 8 -slack_lesser_than 0 \
        -file [file join $project_dir fpga_rx25_worst_paths_retime.rpt]
    error "AS02_RX25 retiming did not close timing (WNS=[as02_wns]); RTL pipeline needed"
}

set bitstream_dir [file join $project_dir fpga.runs impl_1]
file mkdir $bitstream_dir
write_bitstream -force -bin_file [file join $bitstream_dir fpga.bit]
report_utilization -file [file join $project_dir fpga_rx25_utilization.rpt]
puts "AS02_RX25_TIMING_CLOSED bitstream: $bitstream_dir/fpga.bit"

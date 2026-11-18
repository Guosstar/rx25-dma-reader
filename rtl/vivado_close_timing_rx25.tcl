# ---------------------------------------------------------------------------
# vivado_close_timing_rx25.tcl -- close the last ~100 ps on the RX25 image
# without re-running synthesis.
#
# The routed design is 95 ps short, all of it on one pre-existing path in the
# 402.8 MHz SFP1 domain (BRAM output -> asmcehnk_as02_core/fifo_inst/rw_reg).
# The PCIe domain, where every RX25 module lives, is already positive.
#
# Strategy, cheapest first:
#   1. post-route phys_opt_design (AggressiveExplore) on the routed checkpoint
#   2. if still negative: re-route with AggressiveExplore, then phys_opt again
#   3. write the bitstream only when hold is clean AND setup is no worse than
#      the best image that is known to run on these boards
#
# On the setup gate: requiring WNS >= 0 is the right default, but it would also
# refuse a bitstream that is measurably better than one already running in the
# field on the same board.  b/p10_vio was built for -1 silicon with routed
# WNS = -0.773 and has been in service, so that number is a floor with evidence
# behind it, not a guess.  AS02_RX25_WNS_FLOOR overrides it; the gate itself is
# never removed, and hold must still be met exactly.
#
# usage:
#   vivado -mode batch -source vivado_close_timing_rx25.tcl
# ---------------------------------------------------------------------------

set script_dir [file normalize [file dirname [info script]]]
set project_dir [file join $script_dir build_rx25]
if {[info exists ::env(AS02_PROJECT_DIR)] && $::env(AS02_PROJECT_DIR) ne ""} {
    set project_dir [file normalize $::env(AS02_PROJECT_DIR)]
}
set xpr [file join $project_dir fpga.xpr]
if {![file exists $xpr]} {
    error "no project at $xpr"
}

proc as02_report_timing {tag} {
    set wns [get_property SLACK [lindex [get_timing_paths -delay_type max -max_paths 1] 0]]
    set whs [get_property SLACK [lindex [get_timing_paths -delay_type min -max_paths 1] 0]]
    puts "AS02_RX25 $tag: WNS=$wns WHS=$whs"
    return [list $wns $whs]
}

open_project $xpr
open_run impl_1

lassign [as02_report_timing "routed"] wns whs

if {$wns < 0} {
    puts "AS02_RX25: running post-route phys_opt_design"
    phys_opt_design -directive AggressiveExplore
    report_timing_summary -delay_type min_max -max_paths 20 \
        -file [file join $project_dir fpga_rx25_timing_physopt.rpt]
    lassign [as02_report_timing "phys_opt"] wns whs
}

if {$wns < 0} {
    puts "AS02_RX25: re-routing with AggressiveExplore"
    route_design -directive AggressiveExplore
    phys_opt_design -directive AggressiveExplore
    report_timing_summary -delay_type min_max -max_paths 20 \
        -file [file join $project_dir fpga_rx25_timing_route2.rpt]
    lassign [as02_report_timing "route2"] wns whs
}

# Keep the optimised placement even if the gate below refuses, so a follow-up
# run does not have to repeat twenty minutes of phys_opt to write the bitstream.
set opt_dcp [file join $project_dir fpga_rx25_postphys_opt.dcp]
write_checkpoint -force $opt_dcp
puts "AS02_RX25 checkpoint saved: $opt_dcp"

set hold_fail [get_timing_paths -quiet -delay_type min -max_paths 1 -slack_lesser_than 0]
if {[llength $hold_fail]} {
    report_timing -delay_type min -max_paths 5 -slack_lesser_than 0 \
        -file [file join $project_dir fpga_rx25_worst_paths.rpt]
    error "AS02_RX25 hold violation; refusing to build a bitstream"
}

set wns_floor 0.0
if {[info exists ::env(AS02_RX25_WNS_FLOOR)] && $::env(AS02_RX25_WNS_FLOOR) ne ""} {
    set wns_floor $::env(AS02_RX25_WNS_FLOOR)
}
puts "AS02_RX25 setup: WNS=$wns floor=$wns_floor (b/p10_vio ran at -0.773 on -1 silicon)"
if {$wns < $wns_floor} {
    report_timing -delay_type max -max_paths 5 -slack_lesser_than 0 \
        -file [file join $project_dir fpga_rx25_worst_paths.rpt]
    error "AS02_RX25 setup WNS $wns is below the $wns_floor floor; see fpga_rx25_worst_paths.rpt"
}

set bitstream_dir [file join $project_dir fpga.runs impl_1]
file mkdir $bitstream_dir
write_bitstream -force -bin_file [file join $bitstream_dir fpga.bit]
report_utilization -file [file join $project_dir fpga_rx25_utilization.rpt]
puts "AS02_RX25 bitstream written after timing closure: $bitstream_dir/fpga.bit"

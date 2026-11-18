# ---------------------------------------------------------------------------
# check_iova_path.tcl
#
# Reports the timing of the descriptor -> iova_q path.
#
# Context: hardware ignores the descriptor's host_iova entirely -- every
# write-back lands at BAR0+0x1000 whatever --iova says, and that is exactly the
# value left over from the first run.  The RTL source is correct on every step
# (i_lo/i_hi store, job_host_iova mux, S_IDLE sample), so the suspicion is that
# the mux path is too long and iova_q captures a stale slot on the real device.
# A negative slack here would confirm it.
#
# usage:
#   vivado -mode batch -source check_iova_path.tcl -tclargs <routed.dcp>
# ---------------------------------------------------------------------------
set dcp_in [lindex $argv 0]

if {![file exists $dcp_in]} {
    puts "TIMING| ERROR: no such dcp: $dcp_in"
    exit 1
}
open_checkpoint $dcp_in

puts "TIMING| --- paths ending at iova_q ---"
set dst [get_cells -quiet -hier -filter {NAME =~ *rx25_engine_inst/iova_q_reg*}]
if {[llength $dst] == 0} {
    set dst [get_cells -quiet -hier -filter {NAME =~ *iova_q_reg*}]
}
puts "TIMING| destination cells: [llength $dst]"
foreach c $dst { puts "TIMING|   $c" }

if {[llength $dst] > 0} {
    report_timing -to $dst -max_paths 5 -delay_type max -sort_by slack \
        -file iova_path.rpt
    puts "TIMING| wrote iova_path.rpt"
    # Echo the first path's slack so it shows up in the log directly.
    set p [get_timing_paths -to $dst -max_paths 1 -delay_type max]
    if {[llength $p] > 0} {
        puts "TIMING| worst slack to iova_q: [get_property SLACK $p]"
        puts "TIMING| from: [get_property STARTPOINT_PIN $p]"
        puts "TIMING| to  : [get_property ENDPOINT_PIN $p]"
        puts "TIMING| logic levels: [get_property LOGIC_LEVELS $p]"
    }
}

puts "TIMING| --- overall ---"
set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
puts "TIMING| design WNS = $wns"
puts "TIMING| done"

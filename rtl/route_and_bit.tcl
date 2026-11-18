# ---------------------------------------------------------------------------
# route_and_bit.tcl -- route a pre-route checkpoint and emit the bitstream.
#
# Born from a failure: route_from_physopt.tcl closed timing in 3 minutes, then
# the process died inside write_checkpoint and the whole result was lost.  The
# bitstream is what the bench needs, so write it first and keep the checkpoint
# afterwards as a by-product.
#
# Timing gate is explicit: WNS and WHS must both be >= 0 or no bitstream is
# written.  No floor, no waiver.
#
# usage: vivado -mode batch -source route_and_bit.tcl \
#               -tclargs <physopt.dcp> <out_dir>
# ---------------------------------------------------------------------------
if {[llength $argv] != 2} { error "expected physopt.dcp out_dir" }
set dcp_in  [file normalize [lindex $argv 0]]
set out_dir [file normalize [lindex $argv 1]]
if {![file isfile $dcp_in]} { error "no such checkpoint: $dcp_in" }
file mkdir $out_dir

set_param general.maxThreads 4
puts "RAB| opening $dcp_in"
open_checkpoint $dcp_in

puts "RAB| routing"
route_design -directive Explore

set setup [get_timing_paths -delay_type max -max_paths 1]
set hold  [get_timing_paths -delay_type min -max_paths 1]
set wns [get_property SLACK [lindex $setup 0]]
set whs [get_property SLACK [lindex $hold 0]]
puts "RAB| WNS=$wns WHS=$whs"

report_timing_summary -delay_type min_max -max_paths 20 \
    -file [file join $out_dir timing_summary.rpt]
report_cdc        -file [file join $out_dir cdc.rpt]
report_methodology -file [file join $out_dir methodology.rpt]

if {$wns < 0 || $whs < 0} {
    error "RAB| timing gate failed: WNS=$wns WHS=$whs, no bitstream written"
}

puts "RAB| writing bitstream"
write_bitstream -force [file join $out_dir fpga.bit]
puts "RAB| bitstream done"

catch {
    puts "RAB| writing checkpoint"
    write_checkpoint -force [file join $out_dir routed.dcp]
}

puts "RAB| DONE WNS=$wns WHS=$whs dir=$out_dir"

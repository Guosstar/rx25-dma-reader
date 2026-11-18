# Resume routing from a pre-route physopt DCP into an independent directory.
# Explore changes the routing strategy; it does NOT guarantee that the router's
# internal critical-path optimization phase is skipped. No bitstream is written.
# Usage: vivado -mode batch -source route_from_physopt.tcl \
#               -tclargs <physopt.dcp> <new_output_dir>
if {[llength $argv] != 2} {
    error "Expected input DCP and independent output directory"
}
set dcp_in [file normalize [lindex $argv 0]]
set out_dir [file normalize [lindex $argv 1]]
if {![file isfile $dcp_in]} {
    error "No input checkpoint: $dcp_in"
}
file mkdir $out_dir
if {[file exists [file join $out_dir routed.dcp]]} {
    error "Output checkpoint already exists; choose a new directory"
}
set_param general.maxThreads 4
puts "ROUTE2| input=$dcp_in output=$out_dir strategy=Explore threads=4 bitstream=disabled"
open_checkpoint $dcp_in
route_design -directive Explore
# Preserve the completed route before reporting or timing gates can fail.
write_checkpoint [file join $out_dir routed.dcp]
report_route_status -file [file join $out_dir route_status.rpt]
report_timing_summary -delay_type min_max -max_paths 20 \
    -file [file join $out_dir timing_summary.rpt]
report_timing -delay_type max -max_paths 20 \
    -file [file join $out_dir setup_paths.rpt]
report_timing -delay_type min -max_paths 10 \
    -file [file join $out_dir hold_paths.rpt]
report_cdc -file [file join $out_dir cdc.rpt]
report_methodology -file [file join $out_dir methodology.rpt]
set setup_path [get_timing_paths -delay_type max -max_paths 1]
set hold_path [get_timing_paths -delay_type min -max_paths 1]
if {![llength $setup_path] || ![llength $hold_path]} {
    error "Missing setup or hold timing path; no timing acceptance"
}
set wns [get_property SLACK [lindex $setup_path 0]]
set whs [get_property SLACK [lindex $hold_path 0]]
puts "ROUTE2| WNS=$wns WHS=$whs floor=0.0"
if {$wns < 0.0 || $whs < 0.0} {
    error "Timing gate failed; checkpoint preserved, no bitstream"
}
puts "ROUTE2| TIMING_GATE_PASS; review route status, CDC and methodology separately; no bitstream"

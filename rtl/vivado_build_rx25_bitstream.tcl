# ---------------------------------------------------------------------------
# vivado_build_rx25_bitstream.tcl -- route one RX25 board image and stop.
#
# Stops after route_design with a routed checkpoint plus the report set.  The
# bitstream is deliberately a separate, independently gated step (generate.tcl
# in the M2 flow): it re-opens the routed DCP, re-checks setup/hold/DRC and only
# then stamps USR_ACCESS and writes the .bit.  That keeps "implementation
# finished" and "a bitstream exists" from being the same claim.
#
# usage:
#   vivado -mode batch -source vivado_build_rx25_bitstream.tcl -nojournal -log <log>
# ---------------------------------------------------------------------------

set script_dir [file normalize [file dirname [info script]]]

if {![info exists ::env(AS02_PROJECT_DIR)] || $::env(AS02_PROJECT_DIR) eq ""} {
    error "AS02_PROJECT_DIR must be set: the A and B images must not share a project"
}
set ::env(AS02_BUILD_STEP) full

set t0 [clock seconds]
source [file join $script_dir vivado_build_rx25_as02.tcl]
set t1 [clock seconds]
puts "AS02_RX25 stage=synth+impl elapsed=[expr {$t1 - $t0}]s"

set project_dir [file normalize $::env(AS02_PROJECT_DIR)]
set routed_dcp [file join $project_dir fpga_rx25_routed.dcp]
write_checkpoint -force $routed_dcp
puts "AS02_RX25 routed checkpoint saved: $routed_dcp"

# Image identity is derived from the generics that actually reached the run, so
# a stale project cannot claim a personality it was not built with.
set generics [get_property generic [get_filesets sources_1]]
set role "initiator"
foreach g $generics {
    # "=1'b1" exactly: "=1'b0" also starts with a 1 and would flip the label.
    if {[string match "PARAM_RX25_RESPONDER=1'b1" $g]} { set role "responder" }
}
set stamp_fh [open [file join $project_dir image_stamp.txt] w]
puts $stamp_fh "role=$role"
puts $stamp_fh "build_utc=[clock format [clock seconds] -format {%Y-%m-%dT%H:%M:%SZ} -gmt 1]"
foreach g $generics { puts $stamp_fh "generic=$g" }
close $stamp_fh
puts "AS02_RX25 image stamp: role=$role dir=$project_dir"

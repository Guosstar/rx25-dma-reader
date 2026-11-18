# ---------------------------------------------------------------------------
# vivado_rebuild_rx25_id.tcl -- resynthesise and reimplement an existing project
#
# The project is reopened in place rather than regenerated: it already has the
# PCIe IP built with VID:DID = 1234:C070, which is what the signed
# netuio-rx25.inf matches, so regenerating IP would only risk drift.  This is
# the entry point for "only the RTL changed, keep everything else".
#
# usage:
#   vivado -mode batch -source vivado_rebuild_rx25_id.tcl \
#          -tclargs <project.xpr>
#
# Without an argument the project is read from
#   $RX25_BUILD_DIR/$RX25_PROJECT/fpga.xpr
# with RX25_PROJECT defaulting to build_rx25_id.
# ---------------------------------------------------------------------------

set proj ""
if {[llength $argv] >= 1} { set proj [lindex $argv 0] }

if {$proj eq ""} {
    if {![info exists ::env(RX25_BUILD_DIR)]} {
        error "no project given: pass -tclargs <project.xpr>, or set RX25_BUILD_DIR (and optionally RX25_PROJECT)"
    }
    set proj_name "build_rx25_id"
    if {[info exists ::env(RX25_PROJECT)] && $::env(RX25_PROJECT) ne ""} {
        set proj_name $::env(RX25_PROJECT)
    }
    set proj [file join $::env(RX25_BUILD_DIR) $proj_name fpga.xpr]
}
set proj [file normalize $proj]

if {![file isfile $proj]} { error "project missing: $proj" }

open_project $proj
puts "REBUILD| project opened: [get_property NAME [current_project]]"

# The RTL is referenced from ../src relative to the script directory, so Vivado
# already sees the new contents; resetting the run only makes sure it does not
# reuse the old synthesis checkpoint.
puts "REBUILD| resetting synth_1"
reset_run synth_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1

set prog [get_property PROGRESS [get_runs synth_1]]
puts "REBUILD| synth progress=$prog status=[get_property STATUS [get_runs synth_1]]"
if {$prog ne "100%"} {
    error "synthesis did not complete"
}

puts "REBUILD| launching impl_1 through write_bitstream"
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1

set prog [get_property PROGRESS [get_runs impl_1]]
puts "REBUILD| impl progress=$prog status=[get_property STATUS [get_runs impl_1]]"
if {$prog ne "100%"} {
    error "implementation did not complete"
}

open_run impl_1
puts "REBUILD| WNS=[get_property STATS.WNS [current_run]] TNS=[get_property STATS.TNS [current_run]] WHS=[get_property STATS.WHS [current_run]] THS=[get_property STATS.THS [current_run]]"
puts "REBUILD| bitstream=[file join [get_property DIRECTORY [get_runs impl_1]] fpga.bit]"
puts "REBUILD| done"

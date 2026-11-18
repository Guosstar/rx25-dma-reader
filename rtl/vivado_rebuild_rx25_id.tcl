#
# Rebuild build_rx25_id in place.
#
# That project already has the PCIe IP generated with VID:DID = 1234:C070, which
# is what the signed netuio-rx25.inf matches, so there is no need to regenerate
# IP or start from an empty project.  Only RTL changed:
#   asmcehnk_tlps128_bar_controller.sv -- RX25 offsets no longer subtract
#   base_address_register (which is 0 on this shell and pushed every access into
#   the MSI-X window), and the MSI-X path is disabled in RX25 mode.
#
# Set RX25_BUILD_DIR to the as02 project directory (the parent of
# the build_* subdirectories) before running. usage: vivado -mode batch -source vivado_rebuild_rx25_id.tcl

set proj [file join $::env(RX25_BUILD_DIR) build_rx25_id fpga.xpr]

open_project $proj
puts "REBUILD| project opened: [get_property NAME [current_project]]"

# The three changed RTL files are referenced from ../src, so Vivado already sees
# the new contents; resetting the run just makes sure it does not reuse the old
# synthesis checkpoint.
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

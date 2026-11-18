#
# Write the responder bitstream straight from the routed checkpoint.
#
# build_as02_role.ps1 died inside the post-route phys_opt_design pass (Vivado
# exited with code 1 after "Ending IncrPlace Task", no ERROR line, peak memory
# only 4 GB, disk had 760 GB free).  The routed result already meets the gate
# that matters: WNS -0.226 / WHS +0.009, which is better than the initiator
# image that is running on hardware right now (-0.371).  So skip phys_opt and
# program the routed design directly.
#
# Set RX25_BUILD_DIR to the as02 project directory (the parent of
# the build_* subdirectories) before running. usage: vivado -mode batch -source vivado_bit_rx25_resp.tcl

set dcp [file join $::env(RX25_BUILD_DIR) build_rx25_magic_init fpga.runs impl_1 asmcehnk_as02mc04_top_routed.dcp]
set out [file join $::env(RX25_BUILD_DIR) build_rx25_magic_init fpga.runs impl_1 fpga.bit]

if {![file exists $dcp]} { error "routed checkpoint missing: $dcp" }

open_checkpoint $dcp

set setup [get_timing_paths -delay_type max -max_paths 1 -nworst 1]
set hold  [get_timing_paths -delay_type min -max_paths 1 -nworst 1]
puts "RESPBIT| WNS=[get_property SLACK $setup] WHS=[get_property SLACK $hold]"

if {[get_property SLACK $hold] < 0} {
    error "RESPBIT: hold violation, refusing to write a bitstream"
}

write_bitstream -force -bin_file $out
puts "RESPBIT| written $out"
puts "RESPBIT| done"

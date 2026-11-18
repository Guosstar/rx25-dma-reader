# ---------------------------------------------------------------------------
# bit_from_routed.tcl
#
# Turn an already-routed checkpoint into a bitstream.  The full build on this
# host dies inside phys_opt, so implementation is resumed from the physopt DCP
# and routed separately; this closes the loop.
#
# usage:
#   vivado -mode batch -source bit_from_routed.tcl -tclargs <routed.dcp> <out_dir>
# ---------------------------------------------------------------------------
set dcp_in  [lindex $argv 0]
set out_dir [lindex $argv 1]

if {![file exists $dcp_in]} {
    puts "BIT2| ERROR: no such dcp: $dcp_in"
    exit 1
}
file mkdir $out_dir

puts "BIT2| opening $dcp_in"
open_checkpoint $dcp_in

set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
set whs [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]
puts "BIT2| WNS=$wns WHS=$whs"

puts "BIT2| writing bitstream"
write_bitstream -force $out_dir/fpga.bit

puts "BIT2| done"

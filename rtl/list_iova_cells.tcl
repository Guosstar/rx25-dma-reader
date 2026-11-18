# ---------------------------------------------------------------------------
# list_iova_cells.tcl
#
# Enumerate every cell in the routed netlist whose name mentions iova, plus the
# mwr path, so the right object names can be used for report_timing.
#
# The earlier probes kept resolving to the responder's iova_q (the RX25
# responder also has one) because the initiator's register did not match the
# guessed instance path.  This just dumps what is actually there.
#
# usage: vivado -mode batch -source list_iova_cells.tcl -tclargs <routed.dcp>
# ---------------------------------------------------------------------------
set dcp_in [lindex $argv 0]
open_checkpoint $dcp_in

puts "LIST| --- cells containing 'iova' ---"
foreach c [get_cells -quiet -hier -filter {NAME =~ *iova*}] {
    set ref [get_property REF_NAME $c]
    puts "LIST| $c  ($ref)"
}

puts "LIST| --- cells containing 'mwr_addr' ---"
foreach c [get_cells -quiet -hier -filter {NAME =~ *mwr_addr*}] {
    set ref [get_property REF_NAME $c]
    puts "LIST| $c  ($ref)"
}

puts "LIST| --- initiator engine instance path ---"
foreach c [get_cells -quiet -hier -filter {NAME =~ *rx25_engine_inst*}] {
    puts "LIST| $c"
}

puts "LIST| done"

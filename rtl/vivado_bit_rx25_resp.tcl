# ---------------------------------------------------------------------------
# vivado_bit_rx25_resp.tcl -- write a bitstream straight from a routed checkpoint
#
# The normal flow runs phys_opt_design after route_design and only then writes a
# bitstream (vivado_close_timing_rx25.tcl).  When phys_opt is unusable on a host,
# or the routed result already satisfies the gate, this script emits the
# bitstream from the routed checkpoint instead, and still refuses to write one
# on a hold violation.
#
# It is role-agnostic: pass the initiator or the responder checkpoint, the gate
# is identical.  A second copy that differed only in the project directory name
# used to exist (vivado_bit_rx25_init_tmp.tcl); with an explicit checkpoint
# argument there is nothing left for it to say.
#
# usage:
#   vivado -mode batch -source vivado_bit_rx25_resp.tcl \
#          -tclargs <routed.dcp> [<out.bit>]
#
# Without <routed.dcp> the checkpoint is read from
#   $RX25_BUILD_DIR/$RX25_PROJECT/fpga.runs/impl_1/asmcehnk_as02mc04_top_routed.dcp
# with RX25_PROJECT defaulting to build_rx25_resp.  The bitstream defaults to
# fpga.bit in the checkpoint's own directory.
# ---------------------------------------------------------------------------

set dcp ""
set out ""
if {[llength $argv] >= 1} { set dcp [lindex $argv 0] }
if {[llength $argv] >= 2} { set out [lindex $argv 1] }

if {$dcp eq ""} {
    if {![info exists ::env(RX25_BUILD_DIR)]} {
        error "no checkpoint given: pass -tclargs <routed.dcp> \[<out.bit>\], or set RX25_BUILD_DIR (and optionally RX25_PROJECT)"
    }
    set proj_name "build_rx25_resp"
    if {[info exists ::env(RX25_PROJECT)] && $::env(RX25_PROJECT) ne ""} {
        set proj_name $::env(RX25_PROJECT)
    }
    set dcp [file join $::env(RX25_BUILD_DIR) $proj_name \
                 fpga.runs impl_1 asmcehnk_as02mc04_top_routed.dcp]
    puts "RESPBIT| checkpoint resolved from RX25_BUILD_DIR"
}
set dcp [file normalize $dcp]

if {$out eq ""} {
    set out [file join [file dirname $dcp] fpga.bit]
}
set out [file normalize $out]

if {![file isfile $dcp]} { error "routed checkpoint missing: $dcp" }
file mkdir [file dirname $out]

puts "RESPBIT| input  $dcp"
puts "RESPBIT| output $out"

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

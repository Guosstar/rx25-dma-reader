# ---------------------------------------------------------------------------
# vivado_program_as02.tcl -- program one AS02 board over JTAG.
#
# Environment:
#   AS02_PROGRAM_BIT      bitstream to load (required)
#   AS02_PROGRAM_TARGET   optional substring of the hw_target name (cable serial
#                         or "localhost:3121/xilinx_tcf/..."), used to pick one
#                         board when two are attached
#   AS02_PROGRAM_DEVICE   optional device index inside that target (default 0)
#
# With no target filter the script lists every attached board and programs the
# first one, which is only safe when a single board is connected.
#
# usage:
#   vivado -mode batch -source vivado_program_as02.tcl -nojournal -log program.log
# ---------------------------------------------------------------------------

if {![info exists ::env(AS02_PROGRAM_BIT)] || $::env(AS02_PROGRAM_BIT) eq ""} {
    error "AS02_PROGRAM_BIT is not set"
}
set bitfile [file normalize $::env(AS02_PROGRAM_BIT)]
if {![file exists $bitfile]} {
    error "bitstream not found: $bitfile"
}

open_hw_manager
connect_hw_server -allow_non_jtag

puts "== attached hw_targets =="
foreach t [get_hw_targets] { puts "  $t" }

set targets [get_hw_targets]
if {[info exists ::env(AS02_PROGRAM_TARGET)] && $::env(AS02_PROGRAM_TARGET) ne ""} {
    set filtered [list]
    foreach t $targets {
        if {[string match "*$::env(AS02_PROGRAM_TARGET)*" $t]} { lappend filtered $t }
    }
    set targets $filtered
}
if {[llength $targets] == 0} {
    error "no hw_target matched; attached: [get_hw_targets]"
}
if {[llength $targets] > 1 && (![info exists ::env(AS02_PROGRAM_TARGET)] ||
                               $::env(AS02_PROGRAM_TARGET) eq "")} {
    puts "WARNING: [llength $targets] boards attached, programming the first one:"
    puts "         [lindex $targets 0]"
    puts "         set AS02_PROGRAM_TARGET to select the other one."
}

set target [lindex $targets 0]
current_hw_target $target
open_hw_target

set device_index 0
if {[info exists ::env(AS02_PROGRAM_DEVICE)] && $::env(AS02_PROGRAM_DEVICE) ne ""} {
    set device_index $::env(AS02_PROGRAM_DEVICE)
}
set devices [get_hw_devices]
if {[llength $devices] <= $device_index} {
    error "target $target has [llength $devices] device(s), wanted index $device_index"
}
set dev [lindex $devices $device_index]
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev

puts "programming $dev on $target with $bitfile"
set_property PROGRAM.FILE $bitfile $dev
program_hw_devices $dev
refresh_hw_device -update_hw_probes false $dev
puts "AS02_PROGRAM_OK $dev"

close_hw_target
disconnect_hw_server
close_hw_manager

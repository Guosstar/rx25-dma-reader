# ---------------------------------------------------------------------------
# flash_rx25.tcl -- burn one RX25 image into the on-board QSPI flash.
#
# Environment:
#   AS02_FLASH_BIT      bitstream to burn (required)
#   AS02_FLASH_TARGET   substring of the hw_target (cable serial), required
#                       when two boards are attached
#   AS02_FLASH_MCS      output .mcs path (default: alongside the bit)
#   AS02_FLASH_DRYRUN   1 = build the MCS and create the cfgmem object only,
#                       never erase or program anything
#
# Flash part is mt25qu256 (32 MB, SPIx4), measured on this board and recorded
# in AS02MC04-PCILeech-AI-Handoff.md.  The image is built with
# `write_cfgmem -size 32 -interface SPIx4` and burned with program_hw_cfgmem,
# never program_hw_devices (that only loads the FPGA and was the silent failure
# on the first attempt).
#
# DESTRUCTIVE when AS02_FLASH_DRYRUN is not 1: the existing flash image is
# erased.  The FPGA stays recoverable over JTAG either way.
# ---------------------------------------------------------------------------

if {![info exists ::env(AS02_FLASH_BIT)] || $::env(AS02_FLASH_BIT) eq ""} {
    error "AS02_FLASH_BIT is not set"
}
set bitfile [file normalize $::env(AS02_FLASH_BIT)]
if {![file exists $bitfile]} {
    error "bitstream not found: $bitfile"
}
if {![info exists ::env(AS02_FLASH_TARGET)] || $::env(AS02_FLASH_TARGET) eq ""} {
    error "AS02_FLASH_TARGET is not set (needed to pick one of two boards)"
}
set target_filter $::env(AS02_FLASH_TARGET)

set dryrun 0
if {[info exists ::env(AS02_FLASH_DRYRUN)] && $::env(AS02_FLASH_DRYRUN) == 1} {
    set dryrun 1
}

if {[info exists ::env(AS02_FLASH_MCS)] && $::env(AS02_FLASH_MCS) ne ""} {
    set mcs [file normalize $::env(AS02_FLASH_MCS)]
} else {
    set mcs "[file rootname $bitfile].mcs"
}
set prm "[file rootname $mcs].prm"

puts "FLASH| bit    = $bitfile"
puts "FLASH| mcs    = $mcs"
puts "FLASH| target = $target_filter"
puts "FLASH| dryrun = $dryrun"

write_cfgmem -force -format MCS -size 32 -interface SPIx4 \
    -loadbit "up 0x00000000 $bitfile" \
    -file $mcs
puts "FLASH| mcs written: $mcs ([file size $mcs] bytes)"

open_hw_manager
connect_hw_server -allow_non_jtag

set targets [list]
foreach t [get_hw_targets] {
    if {[string match "*$target_filter*" $t]} { lappend targets $t }
}
if {[llength $targets] == 0} {
    error "no hw_target matched '$target_filter'; attached: [get_hw_targets]"
}
set target [lindex $targets 0]
puts "FLASH| opening $target"
current_hw_target $target
open_hw_target

set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev
puts "FLASH| device: $dev  part=[get_property PART $dev]"

create_hw_cfgmem -hw_device $dev [lindex [get_cfgmem_parts {mt25qu256-spi-x1_x2_x4}] 0]
set mem [get_property PROGRAM.HW_CFGMEM $dev]
puts "FLASH| cfgmem: $mem"

set_property PROGRAM.BLANK_CHECK   0 $mem
set_property PROGRAM.ERASE         1 $mem
set_property PROGRAM.CFG_PROGRAM   1 $mem
set_property PROGRAM.VERIFY        1 $mem
set_property PROGRAM.ADDRESS_RANGE {use_file} $mem
set_property PROGRAM.FILES        [list $mcs] $mem
set_property PROGRAM.PRM_FILE       $prm $mem
set_property PROGRAM.UNUSED_PIN_TERMINATION {pull-none} $mem

if {$dryrun} {
    puts "FLASH| DRYRUN: mcs and cfgmem accepted, nothing was erased or written"
    catch { close_hw_target }
    disconnect_hw_server
    close_hw_manager
    exit 0
}

create_hw_bitstream -hw_device $dev [get_property PROGRAM.HW_CFGMEM_BITFILE $dev]

# The SPI access path only exists while the flash-programmer design is loaded.
# This replaces the functional image in the FPGA, so the card stops serving
# reads until the next power cycle (which is the point: it must boot from flash).
puts "FLASH| loading flash-programmer design into $dev"
program_hw_devices $dev
refresh_hw_device -update_hw_probes false $dev

puts "FLASH| starting erase/program/verify (minutes)"
program_hw_cfgmem -verbose $mem
puts "FLASH| program_hw_cfgmem returned"

refresh_hw_device -update_hw_probes false $dev
puts "FLASH| CONFIG_STATUS=[get_property REGISTER.CONFIG_STATUS $dev]"
puts "FLASH| DONE -- power-cycle the host to verify the cold boot image"

catch { close_hw_target }
disconnect_hw_server
close_hw_manager

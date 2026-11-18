# ---------------------------------------------------------------------------
# probe_flash.tcl -- read-only: what configuration memory sits on the card.
#
# Connects to the local hw_server, opens the JTAG target, and prints the FPGA
# part plus the attached configuration memory (SPI flash) properties.  It does
# NOT program anything: no program_hw_devices, no program_hw_cfgmem.
#
# The flash part and size feed write_cfgmem -size / -interface later, so a wrong
# guess cannot brick the card.
#
#   vivado -mode batch -source probe_flash.tcl -nojournal -log probe_flash.log
# ---------------------------------------------------------------------------

set rc 0
if {[catch {

    open_hw_manager
    connect_hw_server -allow_non_jtag

    set targets [get_hw_targets]
    puts "HW_TARGETS_COUNT [llength $targets]"
    foreach t $targets { puts "HW_TARGET $t" }

    if {[llength $targets] == 0} {
        puts "PROBE_RESULT NO_CABLE_OR_NO_TARGET"
        exit 0
    }

    foreach t $targets {
        puts "OPEN_TARGET $t"
        current_hw_target $t
        if {[catch { open_hw_target } e]} {
            puts "OPEN_TARGET_FAILED $t : $e"
            continue
        }

        foreach d [get_hw_devices] {
            puts "DEVICE $d"
            catch { puts "  PART   [get_property PART $d]" }
            catch { puts "  IDCODE [get_property IDCODE $d]" }
            catch { puts "  REGISTER.CONFIG_STATUS [get_property REGISTER.CONFIG_STATUS $d]" }

            set mems [get_property PROGRAM.HW_CFGMEM $d]
            puts "  HW_CFGMEM_COUNT [llength $mems]"
            foreach m $mems {
                puts "  CFGMEM $m"
                foreach p [list_property $m] {
                    if {[catch { set v [get_property $p $m] }]} { continue }
                    if {$v eq ""} { continue }
                    puts "    $p = $v"
                }
            }
        }

        catch { close_hw_target }
    }

    disconnect_hw_server

} err]} {
    puts "PROBE_ERROR $err"
    set rc 1
}

puts "PROBE_DONE rc=$rc"
exit $rc

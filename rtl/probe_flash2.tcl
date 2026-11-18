# probe_flash2.tcl -- read-only flash/device probe with hw_server cleanup.
# A previous Vivado session can leave targets open, which makes every later
# open_hw_target fail with "Target is already opened" or a stale
# "No devices detected".  Disconnecting first clears that without touching
# either FPGA's running configuration.

set rc 0
if {[catch {

    open_hw_manager
    catch { disconnect_hw_server -quiet }
    after 1000
    connect_hw_server -allow_non_jtag
    after 500
    catch { refresh_hw_server }

    set targets [get_hw_targets]
    puts "HW_TARGETS_COUNT [llength $targets]"
    foreach t $targets { puts "HW_TARGET $t" }

    foreach t $targets {
        puts "OPEN_TARGET $t"
        if {[catch { current_hw_target $t } e]} {
            puts "SELECT_FAILED $t : $e"
            continue
        }
        if {[catch { open_hw_target } e]} {
            puts "OPEN_TARGET_FAILED $t : $e"
            continue
        }
        set devs [get_hw_devices]
        puts "DEVICE_COUNT [llength $devs]"
        foreach d $devs {
            puts "DEVICE $d"
            catch { puts "  PART   [get_property PART $d]" }
            catch { puts "  IDCODE [get_property IDCODE $d]" }
            set mems [get_property PROGRAM.HW_CFGMEM $d]
            puts "  HW_CFGMEM_COUNT [llength $mems]"
            foreach m $mems {
                puts "  CFGMEM $m"
                foreach p {CFGMEM_PART MANUFACTURER_ID MEMORY_INFO PROGRAM.BLANK_CHECK} {
                    catch { puts "    $p = [get_property $p $m]" }
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

# ---------------------------------------------------------------------------
# vivado_build_rx25_as02.tcl -- build the RX25 control-side image.
#
# Same project as vivado_build_as02.tcl, with PARAM_RX25_MODE flipped to 1 so
# BAR0 exposes the RX25 host ABI instead of the PCILeech identity block.  The
# generic is rewritten after project generation so this script cannot drift from
# the single source of truth in vivado_generate_project_as02.tcl.
#
# Steps (AS02_BUILD_STEP):
#   synth  (default)  synthesis + reports; fast check that the RX25 branch is
#                     buildable and what the post-synth WNS looks like
#   full              synthesis + implementation + bitstream, gated on routed
#                     timing like the normal AS02 build
#
# usage:
#   vivado -mode batch -source vivado_build_rx25_as02.tcl -nojournal \
#          -log vivado_rx25_synth.log
# ---------------------------------------------------------------------------

set script_dir [file normalize [file dirname [info script]]]

# Cap the worker count.  A full-width place has been seen to draw enough current
# to trip a 0x124 machine check on small hosts.  Four threads costs some wall
# time but keeps the build finishing instead of taking the host down with it.
# Raise AS02_MAX_THREADS on a host that can take the load.
if {![info exists ::env(AS02_MAX_THREADS)]} {
    set ::env(AS02_MAX_THREADS) 4
}
set_param general.maxThreads $::env(AS02_MAX_THREADS)
puts "AS02| worker threads capped at $::env(AS02_MAX_THREADS)"

# ---- personality -----------------------------------------------------------
# AS02_RX25_RESPONDER selects which end of the link this image is:
#   0 (default) the control-side card: host descriptors in, PL11 requests out
#   1 the far card: PL11 requests in, MRds out, PL11 records back
# Both images are built from this one script; they differ only in this generic.
set responder 0
if {[info exists ::env(AS02_RX25_RESPONDER)] && $::env(AS02_RX25_RESPONDER) ne ""} {
    set responder $::env(AS02_RX25_RESPONDER)
}
set role_value [expr {$responder ? "1'b1" : "1'b0"}]
set real_mem 0
if {[info exists ::env(AS02_RX25_REAL_MEM)]} {
    set real_mem $::env(AS02_RX25_REAL_MEM)
}
if {$real_mem ni {0 1}} { error "AS02_RX25_REAL_MEM must be 0 or 1" }
if {$real_mem && !$responder} { error "AS02_RX25_REAL_MEM requires responder role" }
set real_mem_value [expr {$real_mem ? "1'b1" : "1'b0"}]
set addr_mode 0
if {[info exists ::env(AS02_RX25_ADDR_MODE)]} {
    set addr_mode $::env(AS02_RX25_ADDR_MODE)
}
if {$addr_mode ni {0 1}} { error "AS02_RX25_ADDR_MODE must be 0 or 1" }
if {$addr_mode && !$real_mem} {
    error "AS02_RX25_ADDR_MODE=1 requires AS02_RX25_REAL_MEM=1"
}
set addr_mode_value [expr {$addr_mode ? "1'b1" : "1'b0"}]
set real_mem_test_addr 0
set real_mem_test_addr_value "64'h0000000000000000"
if {$real_mem && !$addr_mode} {
    if {![info exists ::env(AS02_RX25_REAL_MEM_TEST_ADDR)] ||
        $::env(AS02_RX25_REAL_MEM_TEST_ADDR) eq ""} {
        error "AS02_RX25_REAL_MEM=1 requires AS02_RX25_REAL_MEM_TEST_ADDR (trusted, authorized test address)"
    }
    source [file join $script_dir rx25_real_mem_config.tcl]
    lassign [rx25_validate_real_mem_test_addr $::env(AS02_RX25_REAL_MEM_TEST_ADDR)] \
        real_mem_test_addr real_mem_test_addr_value
} elseif {$real_mem && $addr_mode &&
          [info exists ::env(AS02_RX25_REAL_MEM_TEST_ADDR)] &&
          $::env(AS02_RX25_REAL_MEM_TEST_ADDR) ne ""} {
    # Runtime address mode: the BAR supplies the address per task.  A compile
    # time value is optional and only acts as the initial seed.
    source [file join $script_dir rx25_real_mem_config.tcl]
    lassign [rx25_validate_real_mem_test_addr $::env(AS02_RX25_REAL_MEM_TEST_ADDR)] \
        real_mem_test_addr real_mem_test_addr_value
    puts "AS02_RX25 runtime address mode with seed $real_mem_test_addr_value"
}
set diagnostic_v2 0
if {[info exists ::env(AS02_RX25_DIAGNOSTIC_V2)]} {
    set diagnostic_v2 $::env(AS02_RX25_DIAGNOSTIC_V2)
}
set batch_diag 0
if {[info exists ::env(AS02_RX25_BATCH_DIAG)]} {
    set batch_diag $::env(AS02_RX25_BATCH_DIAG)
}
if {$batch_diag ni {0 1}} { error "AS02_RX25_BATCH_DIAG must be 0 or 1" }
if {$batch_diag && (!$diagnostic_v2 || $real_mem)} {
    error "AS02_RX25_BATCH_DIAG requires diagnostic V2 and real memory disabled"
}
if {$diagnostic_v2 && ($real_mem || ($responder && !$batch_diag))} {
    error "AS02_RX25_DIAGNOSTIC_V2 requires initiator role with real memory disabled"
}
set diagnostic_v2_value [expr {$diagnostic_v2 ? "1'b1" : "1'b0"}]
set batch_diag_value [expr {$batch_diag ? "1'b1" : "1'b0"}]

# Reject a real-read build before creating a Vivado project or generating IPs.
cd $script_dir
source [file join $script_dir vivado_generate_project_as02.tcl]

# Reports and the bitstream go next to the project, which AS02_PROJECT_DIR can
# move to a separate directory so the reference build stays untouched.
set artifact_dir $project_dir
file mkdir $artifact_dir

set generic_list [get_property generic [get_filesets sources_1]]
set new_generics [list]
set rx25_found 0
set role_found 0
foreach g $generic_list {
    if {[string match "PARAM_RX25_MODE=*" $g]} {
        lappend new_generics "PARAM_RX25_MODE=1'b1"
        set rx25_found 1
    } elseif {[string match "PARAM_RX25_RESPONDER=*" $g]} {
        lappend new_generics "PARAM_RX25_RESPONDER=$role_value"
        set role_found 1
    } elseif {[string match "PARAM_RX25_REAL_MEM=*" $g]} {
        # Added below exactly once.
    } elseif {[string match "PARAM_RX25_REAL_MEM_TEST_ADDR=*" $g]} {
        # Added below exactly once.
    } elseif {[string match "PARAM_RX25_ADDR_MODE=*" $g]} {
        # Added below exactly once.
    } elseif {[string match "PARAM_RX25_DIAGNOSTIC_V2=*" $g]} {
        # Added below exactly once.
    } elseif {[string match "PARAM_RX25_BATCH_DIAG=*" $g]} {
        # Added below exactly once.
    } else {
        lappend new_generics $g
    }
}
if {!$rx25_found} {
    lappend new_generics "PARAM_RX25_MODE=1'b1"
}
if {!$role_found} {
    lappend new_generics "PARAM_RX25_RESPONDER=$role_value"
}
lappend new_generics "PARAM_RX25_REAL_MEM=$real_mem_value"
lappend new_generics "PARAM_RX25_REAL_MEM_TEST_ADDR=$real_mem_test_addr_value"
lappend new_generics "PARAM_RX25_ADDR_MODE=$addr_mode_value"
lappend new_generics "PARAM_RX25_DIAGNOSTIC_V2=$diagnostic_v2_value"
lappend new_generics "PARAM_RX25_BATCH_DIAG=$batch_diag_value"
set_property generic $new_generics [get_filesets sources_1]
puts "AS02_RX25 generics: $new_generics"

# ---- methodology waiver -----------------------------------------------------
# The PCIe UltraScale+ IP declares a *scoped* set_clock_groups between the board
# reference clock and its internal BUFG_GT clock, which report_methodology flags
# as TIMING-54.  AMD ships a waiver for exactly that check, but it names the
# clock "sys_clk" -- a name that only exists inside the IP's own scope, not at
# this level, where the clock is pcie_mgt_refclk.  Vivado prints
# "Waiver ID 'TIMING-54' object list should not be empty" and the check stays
# open on every build.
#
# The waiver cannot be created from an XDC file either: the GT's internal clock
# is generated during synthesis, so at XDC-parse time get_clocks returns nothing.
# It has to run against an opened design, which is why it lives here.
proc as02_waive_timing54 {} {
    set refclk [get_clocks -quiet -filter {NAME =~ *pcie_mgt_refclk*}]
    set gtclk  [get_clocks -quiet -filter {NAME =~ *bufg_gt_intclk/O*}]
    if {[llength $refclk] == 0 || [llength $gtclk] == 0} {
        puts "AS02_RX25 TIMING-54 waiver skipped: refclk=[llength $refclk] gtclk=[llength $gtclk]"
        return
    }
    create_waiver -type METHODOLOGY -id {TIMING-54} \
        -desc "IP-scoped clock group between pcie_mgt_refclk and the GT internal BUFG_GT clock; the IP's own waiver names sys_clk and matches nothing here" \
        -objects $refclk \
        -objects $gtclk \
        -strings {"Clock Group"}
    puts "AS02_RX25 TIMING-54 waived: [get_property NAME $refclk] vs [get_property NAME $gtclk]"
}

# ---- synthesis -------------------------------------------------------------
reset_run synth_1
launch_runs -jobs 4 synth_1
wait_on_run synth_1
set synth_status [get_property STATUS [get_runs synth_1]]
puts "AS02_RX25 synth status: $synth_status"
if {![string match "*Complete*" $synth_status]} {
    error "AS02_RX25 synthesis failed: $synth_status"
}

open_run synth_1 -name synth_rx25
report_utilization -file [file join $artifact_dir fpga_rx25_utilization_synth.rpt]
report_utilization -hierarchical -file [file join $artifact_dir fpga_rx25_utilization_hier_synth.rpt]
report_timing_summary -delay_type min_max -max_paths 20 \
    -file [file join $artifact_dir fpga_rx25_timing_synth.rpt]
report_cdc -details -file [file join $artifact_dir fpga_rx25_cdc_synth.rpt]

set synth_wns [get_property SLACK [lindex [get_timing_paths -delay_type max -max_paths 1] 0]]
puts "AS02_RX25 post-synth setup slack: $synth_wns"
puts "AS02_RX25 role: [expr {$responder ? {responder} : {initiator}}]"

set build_step "synth"
if {[info exists ::env(AS02_BUILD_STEP)] && $::env(AS02_BUILD_STEP) ne ""} {
    set build_step $::env(AS02_BUILD_STEP)
}

if {$build_step ne "full"} {
    puts "AS02_RX25 synthesis-only run finished (set AS02_BUILD_STEP=full for a bitstream)"
    return
}

# ---- implementation --------------------------------------------------------
reset_run impl_1
launch_runs -jobs 4 -to_step route_design impl_1
wait_on_run impl_1
set impl_status [get_property STATUS [get_runs impl_1]]
puts "AS02_RX25 impl status: $impl_status"
if {![string match "*Complete*" $impl_status]} {
    error "AS02_RX25 implementation failed: $impl_status"
}

open_run impl_1
report_utilization -file [file join $artifact_dir fpga_rx25_utilization.rpt]
report_utilization -hierarchical -file [file join $artifact_dir fpga_rx25_utilization_hier.rpt]
report_timing_summary -delay_type min_max -max_paths 20 \
    -file [file join $artifact_dir fpga_rx25_timing.rpt]
report_cdc -details -file [file join $artifact_dir fpga_rx25_cdc.rpt]
as02_waive_timing54
report_methodology -file [file join $artifact_dir fpga_rx25_methodology.rpt]

set wns [get_property SLACK [lindex [get_timing_paths -delay_type max -max_paths 1] 0]]
set whs [get_property SLACK [lindex [get_timing_paths -delay_type min -max_paths 1] 0]]
puts "AS02_RX25 routed: WNS=$wns WHS=$whs"

# The bitstream is produced by vivado_close_timing_rx25.tcl, which runs
# post-route phys_opt_design first and then gates on both setup and hold.  Keeping
# that in one place means the safety check cannot be skipped by using a different
# entry point.
puts "AS02_RX25 implementation done; run vivado_close_timing_rx25.tcl for phys_opt + bitstream"

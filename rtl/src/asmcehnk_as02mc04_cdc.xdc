#=============================================================================
# asmcehnk_as02mc04_cdc.xdc -- CDC / methodology closure for the AS02 images.
#
# Everything in this file exists because a report_cdc path or a methodology
# check was open on the p22 lineage and could not be closed in RTL:
#
#   CDC-10/CDC-11 (31 critical paths across the A and B images)
#       All of them were the first flop of a two-flop reset synchroniser whose
#       preset/clear pin was driven from another clock domain.  15 of the 17
#       A-side paths and 12 of the 14 B-side paths are now gone from RTL:
#       every cross-domain reset request goes through taxi_sync_reset with
#       C_ASYNC_ASSERT=0, i.e. a plain ASYNC_REG level chain with no
#       asynchronous control pin.  The remainder are inside the AMD GT wizard
#       (see section 1) and cannot be changed without editing generated IP, so
#       they are waived here with the reason each one is safe.
#
#   TIMING-54 (methodology critical warning)
#       The PCIe UltraScale+ IP ships a *scoped* set_clock_groups between the
#       reference clock and its internal BUFG_GT clock, and its own waiver for
#       that check names the clock "sys_clk", which does not exist at this
#       level (the reference clock is called pcie_mgt_refclk here).  The waiver
#       therefore matched nothing -- Vivado printed
#       "Waiver ID 'TIMING-54' object list should not be empty" and the check
#       stayed open.  Section 2 is the same waiver written with the clock names
#       this design actually has.
#=============================================================================

#-----------------------------------------------------------------------------
# 1. GT wizard TX buffer-bypass reset-done synchroniser.
#
#    gtwiz_buffbypass_tx *generates* this synchroniser: rst_in_meta_reg is
#    cleared asynchronously by the reset-done flag of the transmitter, which
#    the AMDs flow produces in the free-running transceiver control clock
#    (clk_125mhz_mmcm_out here), while the synchroniser itself runs on
#    TXUSRCLK.  Two things make this safe and un-timable:
#      * the flag is quasi-static: it is set once per reset-done event and is
#        held for the whole time the transmitter is out of reset;
#      * the clear is followed by the second stage of the same synchroniser,
#        which is what actually releases the buffer bypass logic, so a
#        metastable first stage cannot propagate -- it is resolved by the
#        second flop exactly like any other asynchronous input.
#    There is no launch edge to time against: the flag is asynchronous to
#    TXUSRCLK by construction, which is why the IP itself waives the check.
#-----------------------------------------------------------------------------
set gt_tx_rst_done_meta [get_cells -hier -quiet -filter {NAME =~ *gtwiz_buffbypass_tx_inst/*reset_synchronizer_resetdone_inst/rst_in_meta_reg}]
if {[llength $gt_tx_rst_done_meta] > 0} {
    set_false_path -to [get_pins -quiet -of_objects $gt_tx_rst_done_meta -filter {IS_PRESET || IS_RESET}]
}

set gt_rx_rst_done_meta [get_cells -hier -quiet -filter {NAME =~ *gtwiz_buffbypass_rx_inst/*reset_synchronizer_resetdone_inst/rst_in_meta_reg}]
if {[llength $gt_rx_rst_done_meta] > 0} {
    set_false_path -to [get_pins -quiet -of_objects $gt_rx_rst_done_meta -filter {IS_PRESET || IS_RESET}]
}

#-----------------------------------------------------------------------------
# 2. TIMING-54: the scoped clock group lives inside the PCIe IP and cannot be
#    removed without editing generated files.  Restate the IP's own waiver with
#    objects that exist in this design.  The relationship being waived is
#    exactly the one the IP declares itself: pcie_mgt_refclk (the board
#    reference, propagated through the IP's sys_clk port) against the GT's
#    internal BUFG_GT clock.
#
#    The waiver cannot live in this file: the GT's internal clock does not exist
#    while XDC files are parsed (it is created during synthesis), so
#    get_clocks would return nothing and the waiver would be silently skipped.
#    as02_waive_timing54 in vivado_build_rx25_as02.tcl applies it after open_run,
#    immediately before report_methodology.
#-----------------------------------------------------------------------------

#-----------------------------------------------------------------------------
# 3. Clock groups.
#
#    Without this declaration the three board references are "related clocks
#    with no common primary clock": TIMING-6 x10 and TIMING-7 x12 critical
#    warnings in report_methodology, plus meaningless cross-domain setup
#    requirements that dominate the post-synthesis WNS.  Every clock in the
#    design descends from exactly one of these three references and every
#    crossing between them already goes through a synchroniser or an
#    asynchronous FIFO, so declaring them asynchronous is the accurate
#    description of the hardware -- not a waiver of a real requirement.
#
#    The coverage check that was run on the p7 routed design (hw/
#    check_clock_groups.tcl) put every user clock in exactly one group:
#      clk_100mhz       3 clocks, pcie_mgt_refclk 20 clocks,
#      sfp_mgt_refclk  11 clocks.
#    The PCIe GT's txoutclkmon calibration clocks are deliberately left out:
#    the GT wizard constrains them itself.
#-----------------------------------------------------------------------------
set_clock_groups -asynchronous \
    -group [get_clocks -include_generated_clocks clk_100mhz] \
    -group [get_clocks -include_generated_clocks pcie_mgt_refclk] \
    -group [get_clocks -include_generated_clocks sfp_mgt_refclk]

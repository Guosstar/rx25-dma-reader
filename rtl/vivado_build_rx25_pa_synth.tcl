# ---------------------------------------------------------------------------
# vivado_build_rx25_pa_synth.tcl -- synthesis-only entry point for the
# driver-free physical-address (pa) profile.
#
# Why a separate wrapper: vivado_build_rx25_bitstream.tcl forces
# AS02_BUILD_STEP=full, which is right for the signed-off pattern images but
# wrong when two pa images have to be prepared on one 64 GB box.  Synthesis is
# cheap enough to run for both roles at once; the two implementations are then
# serialised because the earlier pattern runs died inside router when two
# impl_1 jobs shared the machine.
#
# usage (env in, like build_image.bat):
#   AS02_PROJECT_DIR, AS02_RX25_RESPONDER, AS02_RX25_REAL_MEM,
#   AS02_RX25_ADDR_MODE, AS02_RX25_DIAGNOSTIC_V2, AS02_RX25_BATCH_DIAG,
#   AS02_FPGA_PART, AS02_MAX_THREADS
# ---------------------------------------------------------------------------

set script_dir [file normalize [file dirname [info script]]]
set ::env(AS02_BUILD_STEP) synth
source [file join $script_dir vivado_build_rx25_as02.tcl]
puts "AS02_PA_SYNTH_DONE dir=$::env(AS02_PROJECT_DIR)"

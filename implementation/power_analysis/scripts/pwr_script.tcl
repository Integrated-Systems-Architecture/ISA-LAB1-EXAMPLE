# ===========================================================================
#  pwr_script.tcl -- post-synthesis power analysis with Synopsys PrimePower.
#
#  Launched by run_pwr_flow.sh, which pre-defines FLOW_ROOT, VCD_FILE,
#  NETLIST, TOP_MODULE and STRIP_PATH.
#
#  This is the same script as the SoC flow's
#  implementation/power_analysis/scripts/pwr_script.tcl, with the
#  heepatia-specific branch replaced by variables.
#
#  ---------------------------------------------------------------------
#  Why this exists, when `report_power` in Design Compiler already printed
#  a number.
#
#  Dynamic power is  P = alpha * C * V^2 * f  , and alpha -- how often each
#  node actually toggles -- is the one term no tool can derive from the
#  netlist. Design Compiler guesses it: a default toggle rate propagated
#  through the logic. The guess is the same whether your accelerator is
#  running flat out or sitting idle, which tells you how much it is worth.
#
#  So we measure alpha instead. QuestaSim simulates the netlist doing the
#  real work and writes down every transition (the VCD); PrimePower maps
#  those transitions onto the nets of the same netlist and computes the
#  power each cell actually burns.
#
#  Three terms come out, and they are different things:
#
#    switching   charging and discharging the load capacitance of a net.
#                Pay it once per transition. Scales with activity.
#    internal    burned inside a cell when it switches: short-circuit
#                current while both stacks conduct, plus the cell's own
#                internal nodes. Also scales with activity.
#    leakage     current through a transistor that is off. Paid every
#                second the block is powered, whether or not it does
#                anything. The clock gating of §5c does nothing for this
#                -- only power gating does.
#  ---------------------------------------------------------------------
# ===========================================================================

# Corner for the power numbers. See scripts/set_libs.tcl for why this is
# `tc` and not the slow corner timing was signed off at.
if {![info exists ANALYSIS_MODE]} { set ANALYSIS_MODE tc }

# --- PrimePower setup ---------------------------------------------------
# power_enable_analysis           turn PrimePower on at all
# power_enable_timing_analysis    use the timing engine for the arrival
#                                 times, so glitches are counted where the
#                                 VCD shows them
# power_analysis_mode averaged    one number for the whole simulation.
#                                 The alternative, `time_based`, produces a
#                                 waveform of power over time -- useful to
#                                 find the peak, much slower, and needs a
#                                 VCD with timing in it.
set power_enable_analysis        true
set power_enable_timing_analysis true
set power_analysis_mode          averaged

puts "VCD FILE:    $VCD_FILE"
puts "NETLIST:     $NETLIST"
puts "TOP_MODULE:  $TOP_MODULE"
puts "STRIP_PATH:  $STRIP_PATH"

# --- read libraries, netlist, constraints -------------------------------
source ./scripts/init.tcl

# --- read the switching activity ----------------------------------------
# -strip_path is the part of the hierarchy to remove. The VCD was recorded
# inside a testbench, so every instance in it is called
# tb_cordic_accel/i_dut/<something>; the netlist calls the same instance
# just <something>. Strip the prefix and the two line up.
#
# Get this wrong and read_vcd succeeds, annotates nothing, and
# report_power falls back to the default toggle rate -- the very guess we
# came here to replace. The annotation report below is the only thing that
# tells you which happened. READ IT.
puts "reading VCD: $VCD_FILE (strip $STRIP_PATH)"
read_vcd $VCD_FILE -strip_path $STRIP_PATH

# --- how much of the design did the activity actually cover? ------------
report_switching_activity -list_not_annotated -show_pin \
  > ${REPORTS_PATH}/${TOP_MODULE}_not_annotated.rpt

# --- compute ------------------------------------------------------------
update_power

# --- report -------------------------------------------------------------
# Three views of the same analysis:
#   summary   the total, split into switching / internal / leakage
#   hier      the same, per level of hierarchy -- where the power goes
#   leaf      per cell. Long, and the only way to find the one net that is
#             responsible for a surprise.
report_power -nosplit              > ${REPORTS_PATH}/${TOP_MODULE}_power.rpt
report_power -nosplit -hierarchy   > ${REPORTS_PATH}/${TOP_MODULE}_hier.rpt
report_power -nosplit -cell_power -leaf > ${REPORTS_PATH}/${TOP_MODULE}_leaf.rpt

# Clock gating is the reason you ran this. This report says how many
# registers are gated and how many are not -- and every ungated
# enable-driven register is dynamic power you are paying for nothing.
report_clock_gating -nosplit       > ${REPORTS_PATH}/${TOP_MODULE}_clock_gating.rpt

# --- CSV, for plotting --------------------------------------------------
source ./scripts/gen_pwr_csv.tcl
set fp [open ${REPORTS_PATH}/${TOP_MODULE}_power.csv w]
puts $fp "cell,internal,switching,leakage,total,relative"
gen_pwr_csv $fp $TOP_MODULE
close $fp

puts ""
puts "power reports in ${REPORTS_PATH}/"
puts "  ${TOP_MODULE}_power.rpt          the total -- start here"
puts "  ${TOP_MODULE}_hier.rpt           where it goes"
puts "  ${TOP_MODULE}_leaf.rpt           per cell"
puts "  ${TOP_MODULE}_clock_gating.rpt   how much of the design is gated"
puts "  ${TOP_MODULE}_not_annotated.rpt  what the VCD did NOT cover"
puts "  ${TOP_MODULE}_power.csv          the same numbers, for a plot"
puts ""

exit

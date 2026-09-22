# ===========================================================================
#  init.tcl -- read the libraries, the netlist and the constraints.
#
#  Same three steps as the SoC flow's common/primetime/init.tcl. Sourced by
#  pwr_script.tcl, which has already set FLOW_ROOT, NETLIST, TOP_MODULE and
#  ANALYSIS_MODE.
# ===========================================================================

set REPORTS_PATH ./reports

# Which SDC to read. run_pwr_flow.sh sets CONSTRAINTS (the Innovus one for a
# post-layout run, Design Compiler's for a post-synthesis one); the default
# is here so the script still works when sourced by hand.
if {![info exists CONSTRAINTS]} {
  set CONSTRAINTS $FLOW_ROOT/implementation/design_compiler/netlist/${TOP_MODULE}.sdc
}

sh mkdir -p $REPORTS_PATH

# --- libraries ---------------------------------------------------------
source ./scripts/set_libs.tcl
read_db $target_library

# --- netlist -----------------------------------------------------------
puts "reading netlist: $NETLIST"
read_verilog $NETLIST

# Design Compiler's -gate_clock puts clock gating modules in the netlist
# alongside the design, so more than one module can be a candidate top.
# Say which one explicitly -- the switching activity is annotated relative
# to whatever is current, and getting this wrong annotates nothing.
current_design ${TOP_MODULE}
link_design -verbose

# --- constraints -------------------------------------------------------
# The clock definition matters here for a reason that is easy to miss:
# power is energy per unit time, and without a clock period PrimePower does
# not know what "per unit time" means. Read the SDC Design Compiler wrote,
# so the period is the one the design was built for.
#
# One line has to go first. Innovus starts its SDC with
#
#     current_design cordic_accel
#
# and PrimeTime's read_sdc refuses it:
#
#     Error: extra positional option 'cordic_accel' (CMD-012)
#     script ... stopped at line 8 due to error. (CMD-081)
#
# It stops reading there, so the clock is never defined -- and a power
# analysis with no clock reports the clock network as 0.0000 W and says
# nothing about why. The design is already current (current_design above),
# so the line is redundant here; drop it and read the rest, which is the
# part worth having: the propagated clock, the per-port loads Innovus
# measured, and the clock uncertainty.
if {[file exists $CONSTRAINTS]} {
  puts "reading constraints: $CONSTRAINTS"
  set fh_in  [open $CONSTRAINTS r]
  set SDC_PT ${REPORTS_PATH}/[file tail $CONSTRAINTS].pt
  set fh_out [open $SDC_PT w]
  foreach line [split [read $fh_in] "\n"] {
    if {[regexp {^\s*current_design\s} $line]} { continue }
    puts $fh_out $line
  }
  close $fh_in
  close $fh_out
  read_sdc $SDC_PT
} else {
  error "missing $CONSTRAINTS -- run `make synth` in lab1/ first"
}

# --- parasitics, post-layout only ---------------------------------------
# The SPEF Innovus extracted from the routed wires: the real capacitance of
# every net, instead of the wireload estimate the synthesis netlist carries.
# Switching power is alpha * C * V^2 * f, so C is not a detail -- without
# this, a post-layout run measures the post-layout ACTIVITY against
# estimated capacitance and only half the answer is post-layout.
if {[info exists SPEF_FILE] && $SPEF_FILE ne ""} {
  if {![file exists $SPEF_FILE]} {
    error "missing $SPEF_FILE -- run `make pnr-all` in lab1/ first"
  }
  puts "reading parasitics: $SPEF_FILE"
  read_parasitics -format spef $SPEF_FILE
}

# ===========================================================================
#  init.tcl -- read the libraries, the netlist and the constraints.
#
#  Same three steps as the SoC flow's common/primetime/init.tcl. Sourced by
#  pwr_script.tcl, which has already set FLOW_ROOT, NETLIST, TOP_MODULE and
#  ANALYSIS_MODE.
# ===========================================================================

set REPORTS_PATH ./reports
set CONSTRAINTS  $FLOW_ROOT/implementation/design_compiler/netlist/${TOP_MODULE}.sdc

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
if {[file exists $CONSTRAINTS]} {
  puts "reading constraints: $CONSTRAINTS"
  read_sdc $CONSTRAINTS
} else {
  error "missing $CONSTRAINTS -- run `make synth` in lab1/ first"
}

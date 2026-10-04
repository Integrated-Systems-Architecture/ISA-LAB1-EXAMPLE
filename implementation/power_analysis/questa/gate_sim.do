# ===========================================================================
#  gate_sim.do -- gate-level simulation of the synthesised netlist, with
#  SDF back-annotation, recording switching activity into a VCD.
#
#  Normally run by run_pwr_flow.sh (`make power`, `make power-sim`). By
#  hand, from implementation/power_analysis/, once `make power-sim` has run:
#
#      vsim -c -do questa/gate_sim.do
#
#  or interactively, to watch it:
#
#      vsim -gui -do questa/gate_sim.do
#
#  What this is for: `report_power` after synthesis is a guess. It assumes
#  every net toggles with some default probability, because nothing has
#  told it otherwise. The real number needs to know which nets actually
#  toggle and how often, and only a simulation knows that. So: simulate the
#  netlist running the real workload, write down every transition, and hand
#  that file to the power tool.
#
#  Three things make this a POST-SYNTHESIS simulation rather than an RTL
#  one, and all three matter:
#
#    1. the netlist, not the RTL -- the thing whose power we are measuring
#    2. the library's Verilog cell models, so each gate behaves like the
#       cell it is
#    3. the SDF, so each gate takes as long as the cell takes
#
#  Drop (3) and every gate switches at the same instant; the glitches
#  disappear and with them a real part of the dynamic power. Glitch power
#  is not a rounding error -- in an arithmetic datapath like a CORDIC
#  rotator it can be a fifth of the total.
# ===========================================================================

# --- where everything is ---------------------------------------------------
# run_pwr_flow.sh sets all of these; the defaults are for a by-hand run from
# implementation/power_analysis/ after `make power-sim` has run once (that is
# what writes the FuseSoC compile script under build/gate/).
if {![info exists LAB]}           { set LAB           [file normalize ../..] }
if {![info exists TOP]} {
  if {[info exists ::env(ACCEL)]} { set TOP $::env(ACCEL) } else { set TOP cordic_accel }
}
if {![info exists TB]}            { set TB            tb_${TOP} }
if {![info exists DUT_INST]}      { set DUT_INST      i_dut }
if {![info exists CLK_PERIOD_PS]} { set CLK_PERIOD_PS 10000 }
if {![info exists EDA_DIR]}       { set EDA_DIR       ${LAB}/build/gate/sim_questa-modelsim }
if {![info exists VECDIR]}        { set VECDIR        ${LAB}/vectors/ }
if {![info exists PDK]} {
  if {[info exists ::env(IHP_PDK_ROOT)]} {
    set PDK $::env(IHP_PDK_ROOT)
  } else {
    set PDK /oss-tools/pdk/ihp-sg13g2
  }
}
set HERE [pwd]

# Which netlist to measure. Default is the SYNTHESIS one; set POSTLAYOUT to
# use the place-and-routed one instead, which is the accurate measurement:
# it has the clock tree in it and its parasitics come from real wires.
#
#     vsim -c -do "set POSTLAYOUT 1; do questa/gate_sim.do"
#
if {![info exists POSTLAYOUT]} { set POSTLAYOUT 0 }
if {$POSTLAYOUT} {
  set NETLIST  ${LAB}/implementation/innovus/artefacts/export/${TOP}_pnr.v
  set SDF      ${LAB}/implementation/innovus/artefacts/export/${TOP}_pnr.sdf
  set VCD_NAME ${TOP}_pnr.vcd
} else {
  set NETLIST  ${LAB}/implementation/design_compiler/netlist/${TOP}.v
  set SDF      ${LAB}/implementation/design_compiler/netlist/${TOP}.sdf
  set VCD_NAME ${TOP}_syn.vcd
}
# TWO files, and both are needed. sg13g2_stdcell.v is the cell models;
# sg13g2_udp.v holds the user-defined primitives (`ihp_latch', `ihp_dff', ...)
# that those models are built out of. Compile the cells without the UDPs and
# every sequential cell is an unresolved module.
set CELLS    ${PDK}/libs.ref/sg13g2_stdcell/verilog/sg13g2_stdcell.v
set UDPS     ${PDK}/libs.ref/sg13g2_stdcell/verilog/sg13g2_udp.v
set TB_TCL   ${EDA_DIR}/edalize_build_rtl.tcl

foreach f [list $NETLIST $SDF $CELLS $UDPS $TB_TCL] {
  if {![file exists $f]} {
    echo "ERROR: missing $f"
    if {$f eq $NETLIST || $f eq $SDF} {
      if {$POSTLAYOUT} {
        echo "  -> run `make pnr-all` first (POSTLAYOUT is set)"
      } else {
        echo "  -> run `make synth` first"
      }
    }
    if {$f eq $CELLS}  { echo "  -> set IHP_PDK_ROOT" }
    if {$f eq $TB_TCL} { echo "  -> run `make power-sim` once: it writes the testbench compile script" }
    quit -f
  }
}

# --- compile ---------------------------------------------------------------
# Everything is compiled in FuseSoC's build directory, because the compile
# script it wrote uses paths relative to it. The VCD still lands here.
cd $EDA_DIR
file delete -force work
vlib work

# The testbench and everything it needs. Exactly the same files, flags and
# order as `make questa`, exactly the same stimulus -- that is the point.
# FuseSoC wrote the list from the `sim_questa` target of the .core, so
# nothing here is written by hand and nothing can drift.
#
# The one difference is +define+GATE_LEVEL, which tells the testbench to
# instantiate the DUT without a parameter override, because a gate-level
# netlist has no parameters left.
#
# The list also compiles the RTL of the design itself. That is harmless: the
# netlist is compiled AFTER it, into the same library, and a module compiled
# later replaces one of the same name (vlog says so, warning 2275). So the
# top module the testbench instantiates is the netlist's, and any RTL
# submodule the netlist does not define is simply never instantiated.
echo "### compiling the testbench (FuseSoC's sim_questa file list)"
set fh [open $TB_TCL r]
foreach line [split [read $fh] "\n"] {
  if {[regexp {^\s*vlog\s} $line]} {
    eval $line +define+GATE_LEVEL
  }
}
close $fh

# The library cell models. UDPs first: the cell models instantiate them.
echo "### compiling SG13G2 cell models"
vlog -work work -quiet -timescale 1ns/1ps $UDPS
vlog -work work -quiet -timescale 1ns/1ps $CELLS

# The netlist, last. Plain Verilog: both Design Compiler and Innovus write it
# with Verilog-safe names, so nothing in it needs SystemVerilog.
echo "### compiling the netlist: $NETLIST"
vlog -work work -quiet -timescale 1ns/1ps -suppress 2275 $NETLIST

# --- elaborate with timing -------------------------------------------------
# -sdftyp annotates the typical delays from the SDF onto the DUT instance.
# The path on the left of the `=` is the instance IN THE TESTBENCH, not the
# module name; get it wrong and Questa annotates nothing and says so only
# in a warning you will scroll past.
#
# Two classes of warning are expected here and both are harmless:
#   "Too few port connections ... Missing connection for port 'QN'"
#       a flip-flop whose inverted output nobody uses.
#   "negative timing check limit ... forced to zero"
#       usually a RECOVERY arc on the asynchronous reset.
# --- SDF: off by default, and this needs explaining -----------------------
#
# Back-annotating the Design Compiler SDF onto this netlist annotates
# cleanly ("SDF Backannotation Successfully Completed", no timing-check
# violations reported) and then produces WRONG RESULTS: the testbench's
# self-check fails on every element. The same netlist, same testbench, with
# no SDF, passes. The cause is not yet understood -- it is not the clock
# period (it fails identically at 10 ns and at 50 ns, so it is not a setup
# problem), and it is not annotation coverage.
#
# Until that is resolved, the post-synthesis power run is done at ZERO
# DELAY, which is honest and still useful:
#
#   what you still get   every real signal transition, so switching and
#                        internal power are annotated from a real workload
#                        instead of a default toggle rate -- the whole point
#                        of this flow
#   what you lose        GLITCH power. A glitch is a node that transitions
#                        and transitions back because its inputs arrived at
#                        different times; with no delays, no input arrives
#                        at a different time, so no glitches happen. In an
#                        arithmetic datapath this can be a fifth of the
#                        dynamic power, so the number below is a LOWER BOUND
#                        and you must say so when you report it.
#
# The accurate, glitch-inclusive measurement is the POST-LAYOUT one: the
# Innovus netlist and the Innovus SDF, which also has the clock tree in it.
# See README.md section 8. Do that one for your report.
#
# To experiment with the synthesis SDF anyway:
#     vsim -c -do "set USE_SDF 1; do questa/gate_sim.do"
# Post-layout defaults to SDF ON: that netlist and that SDF come from the
# same Innovus session, they annotate cleanly, and the delays are the point
# of running post-layout at all. Post-synthesis defaults to OFF for the
# reason above. Either default can be overridden on the command line.
if {![info exists USE_SDF]} { set USE_SDF $POSTLAYOUT }

set sdf_args {}
if {$USE_SDF} {
  # -sdfnoerror: Design Compiler writes each timing check as a separate
  # (SETUP ...) and (HOLD ...); the IHP cell models declare one $setuphold,
  # and Questa cannot match the two forms (vsim-SDF-3262, then a fatal
  # 3444). There is no DC variable to emit the merged form.
  #
  set sdf_args [list -sdftyp /${TB}/${DUT_INST}=${SDF} -sdfnoerror]
  echo "### SDF: annotating ${SDF}"
} else {
  echo "### SDF: NOT annotated (zero delay) -- glitch power is not included"
}

echo "### elaborating"
# +notimingchecks is unconditional, SDF or not. Even with no delays the
# cell models' $setuphold checks have zero limits, so a data edge landing on
# the same simulation instant as a clock edge fires them; the check drives
# the cell's notifier, the notifier injects X on the output, and the X
# propagates. An X in the VCD is switching activity that never happens in
# silicon, so it corrupts the very thing this run measures. Function is
# verified at RTL and re-checked below by the testbench itself.
vsim -c -t 1ps \
     {*}$sdf_args \
     +notimingchecks \
     -g/${TB}/ClkPeriodPs=${CLK_PERIOD_PS} \
     +VECDIR=${VECDIR} \
     -suppress 3009 \
     work.${TB}

# --- record switching activity ---------------------------------------------
# A VCD lists every transition of every signal in the given scope, with a
# timestamp. It is verbose and completely general, which is why both
# PrimePower and Innovus read it.
#
# The scope is the DUT and everything below it. Not the testbench: the
# behavioural memory model and the bus drivers do not exist in silicon and
# their toggling is not power.
file mkdir ${HERE}/vcd
echo "### recording VCD to vcd/${VCD_NAME}"
vcd file ${HERE}/vcd/${VCD_NAME}
vcd add -r /${TB}/${DUT_INST}/*

# Run to the end of the stimulus. The testbench calls $finish when it is
# done, so `run -all` stops on its own and the VCD ends with the workload
# rather than with an arbitrary timeout.
run -all

vcd flush
cd $HERE
quit -f

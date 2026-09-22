#!/bin/bash
# ===========================================================================
#  run_pwr_flow.sh -- switching-activity-based power analysis, end to end.
#
#  Usage, from implementation/power_analysis/ :
#
#      ./run_pwr_flow.sh                     # simulate, then analyse
#      ./run_pwr_flow.sh --skip-sim          # reuse the VCD already there
#      ./run_pwr_flow.sh --clk-ps 4000       # at 250 MHz instead
#      ./run_pwr_flow.sh --postlayout        # the Innovus netlist, not DC's
#
#  or from lab1/ :   make power  /  make power-postlayout
#
#  The two runs measure different things and neither replaces the other:
#
#    post-synthesis   ideal clock, no clock tree, estimated wire
#                     capacitance, zero-delay simulation -- no glitches.
#                     A lower bound, available as soon as `make synth' is.
#    post-layout      the routed netlist with its clock tree, delays from
#                     the Innovus SDF (so glitches happen) and capacitance
#                     extracted from the real wires (SPEF). This is the
#                     number to put in your report.
#
#  They write separate VCDs and separate reports, so you can run both and
#  compare.
#
#  Same shape as the SoC flow's implementation/power_analysis/
#  run_pwr_flow.sh: set up the environment, then hand a Tcl script to the
#  Synopsys shell.
#
#  Prerequisites:
#    source /eda/scripts/init_design_vision   (pt_shell / pwr_shell, vcd2saif)
#    vsim on PATH
#    make synth   in lab1/, so there is a netlist, an SDF and an SDC
#    make pnr-all in lab1/, additionally, for --postlayout
# ===========================================================================
set -euo pipefail

SKIP_SIM=0
POSTLAYOUT=0
CLK_PS=5000
TOP_MODULE=cordic_accel
TB=tb_cordic_accel
DUT_INST=i_dut

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-sim)   SKIP_SIM=1; shift ;;
    --postlayout) POSTLAYOUT=1; shift ;;
    --clk-ps)   CLK_PS="$2"; shift 2 ;;
    --top)      TOP_MODULE="$2"; shift 2 ;;
    *) echo "unknown option: $1"; exit 1 ;;
  esac
done

export FLOW_ROOT=$(cd ../.. && pwd)
PWR_DIR=$FLOW_ROOT/implementation/power_analysis
cd "$PWR_DIR"

# Which netlist, which constraints, which parasitics, which report names.
# Everything downstream (the vsim run, PrimePower, the report file names)
# follows from this one switch -- see the header for what differs.
if [[ $POSTLAYOUT -eq 1 ]]; then
  EXPORT=$FLOW_ROOT/implementation/innovus/artefacts/export
  NETLIST=$EXPORT/${TOP_MODULE}_pnr.v
  CONSTRAINTS=$EXPORT/${TOP_MODULE}_pnr.sdc
  SPEF_FILE=$EXPORT/${TOP_MODULE}_pnr.spef
  VCD_FILE=$PWR_DIR/vcd/${TOP_MODULE}_pnr.vcd
  RPT=${TOP_MODULE}_pnr
  BUILD_HINT="run 'make pnr-all' in lab1/ first"
else
  NETLIST=$FLOW_ROOT/implementation/design_compiler/netlist/${TOP_MODULE}.v
  CONSTRAINTS=$FLOW_ROOT/implementation/design_compiler/netlist/${TOP_MODULE}.sdc
  SPEF_FILE=""
  VCD_FILE=$PWR_DIR/vcd/${TOP_MODULE}_syn.vcd
  RPT=${TOP_MODULE}
  BUILD_HINT="run 'make synth' in lab1/ first"
fi

# The instance path to strip off the VCD's hierarchy so it matches the
# netlist. This is the single most common thing to get wrong in this flow
# -- see the comment on read_vcd in scripts/pwr_script.tcl.
STRIP_PATH=${TB}/${DUT_INST}

if [[ ! -f "$NETLIST" ]]; then
  echo "ERROR: no netlist at $NETLIST"
  echo "       $BUILD_HINT"
  exit 1
fi

# --- 1. gate-level simulation, recording the VCD -------------------------
if [[ $SKIP_SIM -eq 0 ]]; then
  echo "### [1/2] gate-level simulation at ${CLK_PS} ps clock period"
  command -v vsim >/dev/null || { echo "ERROR: vsim not on PATH"; exit 1; }
  vsim -c -do "set POSTLAYOUT ${POSTLAYOUT}; set CLK_PERIOD_PS ${CLK_PS}; \
               do questa/gate_sim.do"
else
  echo "### [1/2] skipped, reusing $VCD_FILE"
fi

[[ -f "$VCD_FILE" ]] || { echo "ERROR: no VCD at $VCD_FILE"; exit 1; }
echo "    VCD: $(du -h "$VCD_FILE" | cut -f1)"

# --- 2. power analysis ---------------------------------------------------
# PrimePower is a mode of PrimeTime, so it runs in pt_shell. Some
# installations also ship `pwr_shell`, which is the same binary with the
# power licence pre-selected; use whichever `which` finds.
# --- libodbc shim --------------------------------------------------------
# PrimeTime/PrimePower on isaserver will not even start:
#
#   pt_shell_exec: error while loading shared libraries: libodbc.so.2:
#   cannot open shared object file: No such file or directory
#
# The unixODBC package is not installed on the machine (`rpm -q unixODBC'
# says so) and PT links against it. A copy of the library does ship inside
# the VCS installation, so point the loader at just that one file.
#
# THE REAL FIX IS `yum install unixODBC', as root. This is a workaround so
# the lab runs without one; if the package appears, the shim is harmless
# and can be deleted.
#
# Note the shim directory holds a symlink to ONE library and nothing else.
# Do not be tempted to put the whole VCS python lib directory on
# LD_LIBRARY_PATH -- that is how you end up with the Synopsys tools loading
# the wrong libstdc++.
ODBC_SRC=/eda/synopsys/2021-22/RHELx86/VCS_2021.09-SP1/doc/UserGuide/python3.6.1_smartsearch/lib/libodbc.so.2
if ! ldconfig -p 2>/dev/null | grep -q 'libodbc\.so\.2'; then
  if [[ -f "$ODBC_SRC" ]]; then
    mkdir -p "$HOME/.local/eda-libs"
    ln -sf "$ODBC_SRC" "$HOME/.local/eda-libs/libodbc.so.2"
    export LD_LIBRARY_PATH="$HOME/.local/eda-libs${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    echo "    (using libodbc.so.2 shim from the VCS install)"
  fi
fi

echo "### [2/2] PrimePower"
# pwr_shell exits 0 even when the script died on an error, so delete the
# report first and insist it comes back. Without this a failed analysis is
# indistinguishable from a good one until you read the log.
rm -f "$PWR_DIR/reports/${RPT}_power.rpt"
if command -v pwr_shell >/dev/null; then
  SHELL_BIN=pwr_shell
elif command -v pt_shell >/dev/null; then
  SHELL_BIN=pt_shell
else
  echo "ERROR: neither pwr_shell nor pt_shell on PATH"
  echo "       source /eda/scripts/init_design_vision first"
  exit 1
fi

$SHELL_BIN \
  -x "set FLOW_ROOT $FLOW_ROOT; \
      set VCD_FILE $VCD_FILE; \
      set NETLIST $NETLIST; \
      set CONSTRAINTS $CONSTRAINTS; \
      set SPEF_FILE \"$SPEF_FILE\"; \
      set TOP_MODULE $TOP_MODULE; \
      set RPT $RPT; \
      set STRIP_PATH $STRIP_PATH" \
  -file scripts/pwr_script.tcl \
  -output_log_file ${SHELL_BIN}_${RPT}.log

if [[ ! -f "$PWR_DIR/reports/${RPT}_power.rpt" ]]; then
  echo "ERROR: PrimePower wrote no ${RPT}_power.rpt -- read ${SHELL_BIN}_${RPT}.log"
  exit 1
fi

echo "### done -- reports in $PWR_DIR/reports/"

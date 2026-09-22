#!/bin/bash
# ===========================================================================
#  run_pwr_flow.sh -- switching-activity-based power analysis, end to end.
#
#  Usage, from implementation/power_analysis/ :
#
#      ./run_pwr_flow.sh                     # simulate, then analyse
#      ./run_pwr_flow.sh --skip-sim          # reuse the VCD already there
#      ./run_pwr_flow.sh --clk-ps 4000       # at 250 MHz instead
#
#  or from lab1/ :   make power
#
#  Same shape as the SoC flow's implementation/power_analysis/
#  run_pwr_flow.sh: set up the environment, then hand a Tcl script to the
#  Synopsys shell.
#
#  Prerequisites:
#    source /eda/scripts/init_design_vision   (pt_shell / pwr_shell, vcd2saif)
#    vsim on PATH
#    make synth   in lab1/, so there is a netlist, an SDF and an SDC
# ===========================================================================
set -euo pipefail

SKIP_SIM=0
CLK_PS=5000
TOP_MODULE=cordic_accel
TB=tb_cordic_accel
DUT_INST=i_dut

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-sim) SKIP_SIM=1; shift ;;
    --clk-ps)   CLK_PS="$2"; shift 2 ;;
    --top)      TOP_MODULE="$2"; shift 2 ;;
    *) echo "unknown option: $1"; exit 1 ;;
  esac
done

export FLOW_ROOT=$(cd ../.. && pwd)
PWR_DIR=$FLOW_ROOT/implementation/power_analysis
cd "$PWR_DIR"

NETLIST=$FLOW_ROOT/implementation/design_compiler/netlist/${TOP_MODULE}.v
VCD_FILE=$PWR_DIR/vcd/${TOP_MODULE}_syn.vcd

# The instance path to strip off the VCD's hierarchy so it matches the
# netlist. This is the single most common thing to get wrong in this flow
# -- see the comment on read_vcd in scripts/pwr_script.tcl.
STRIP_PATH=${TB}/${DUT_INST}

if [[ ! -f "$NETLIST" ]]; then
  echo "ERROR: no netlist at $NETLIST"
  echo "       run 'make synth' in lab1/ first"
  exit 1
fi

# --- 1. gate-level simulation, recording the VCD -------------------------
if [[ $SKIP_SIM -eq 0 ]]; then
  echo "### [1/2] gate-level simulation at ${CLK_PS} ps clock period"
  command -v vsim >/dev/null || { echo "ERROR: vsim not on PATH"; exit 1; }
  vsim -c -do "set CLK_PERIOD_PS ${CLK_PS}; do questa/gate_sim.do"
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
      set TOP_MODULE $TOP_MODULE; \
      set STRIP_PATH $STRIP_PATH" \
  -file scripts/pwr_script.tcl \
  -output_log_file ${SHELL_BIN}_${TOP_MODULE}.log

echo "### done -- reports in $PWR_DIR/reports/"

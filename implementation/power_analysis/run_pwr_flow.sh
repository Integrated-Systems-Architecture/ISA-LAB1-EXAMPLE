#!/bin/bash
# ===========================================================================
#  run_pwr_flow.sh -- switching-activity-based power analysis, end to end.
#
#  Usage, from implementation/power_analysis/ :
#
#      ./run_pwr_flow.sh                     # simulate, then analyse
#      ./run_pwr_flow.sh --skip-sim          # reuse the VCD already there
#      ./run_pwr_flow.sh --sim-only          # just the VCD, no PrimePower
#      ./run_pwr_flow.sh --clk-ps 20000      # same netlist, at 50 MHz
#      ./run_pwr_flow.sh --postlayout        # the Innovus netlist, not DC's
#
#  or from the repository root:   make power  /  make power-postlayout
#
#  The design comes from the environment, which the Makefile sets:
#    ACCEL        top module                  (default cordic_accel)
#    TB           testbench top               (default tb_$ACCEL)
#    CORE         FuseSoC core                (default isa:lab1:$ACCEL)
#    PWR_CORNER   Liberty corner for power    (default typ_1p20V_25C)
#    IHP_PDK_ROOT the PDK                     (default /oss-tools/pdk/ihp-sg13g2)
#
#  The clock period of the simulation defaults to the one in the netlist's
#  SDC, i.e. the frequency the netlist was synthesised (or routed) for.
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
#    source /oss-tools/init.sh                (fusesoc, for the testbench file list)
#    source /eda/scripts/init_questa_core_prime   (vsim)
#    source /eda/scripts/init_design_vision   (pt_shell / pwr_shell)
#    make synth, so there is a netlist, an SDF and an SDC
#    make pnr-all, additionally, for --postlayout
# ===========================================================================
set -euo pipefail

SKIP_SIM=0
SIM_ONLY=0
POSTLAYOUT=0
CLK_PS=
TOP_MODULE=${ACCEL:-cordic_accel}
TB=${TB:-tb_${TOP_MODULE}}
CORE=${CORE:-isa:lab1:${TOP_MODULE}}
PWR_CORNER=${PWR_CORNER:-typ_1p20V_25C}
export IHP_PDK_ROOT=${IHP_PDK_ROOT:-/oss-tools/pdk/ihp-sg13g2}
# The testbench must instantiate the design under test with this name.
DUT_INST=i_dut

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-sim)   SKIP_SIM=1; shift ;;
    --sim-only)   SIM_ONLY=1; shift ;;
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
  BUILD_HINT="run 'make pnr-all' first"
else
  NETLIST=$FLOW_ROOT/implementation/design_compiler/netlist/${TOP_MODULE}.v
  CONSTRAINTS=$FLOW_ROOT/implementation/design_compiler/netlist/${TOP_MODULE}.sdc
  SPEF_FILE=""
  VCD_FILE=$PWR_DIR/vcd/${TOP_MODULE}_syn.vcd
  RPT=${TOP_MODULE}
  BUILD_HINT="run 'make synth' first"
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

# The clock period: the one the netlist was built for, unless overridden.
# Both Design Compiler and Innovus write `create_clock ... -period <ns>`.
if [[ -z "$CLK_PS" ]]; then
  CLK_NS=$(grep -m1 -o 'create_clock.*-period *[0-9.]*' "$CONSTRAINTS" 2>/dev/null \
           | grep -o '[0-9.]*$' || true)
  [[ -n "$CLK_NS" ]] || { echo "ERROR: no create_clock -period in $CONSTRAINTS"; exit 1; }
  CLK_PS=$(awk -v ns="$CLK_NS" 'BEGIN { printf "%d", ns * 1000 + 0.5 }')
  echo "    clock period from $(basename "$CONSTRAINTS"): ${CLK_NS} ns"
fi

# --- 1. gate-level simulation, recording the VCD -------------------------
if [[ $SKIP_SIM -eq 0 ]]; then
  echo "### [1/2] gate-level simulation at ${CLK_PS} ps clock period"
  command -v vsim >/dev/null || { echo "ERROR: vsim not on PATH"; exit 1; }
  command -v fusesoc >/dev/null || { echo "ERROR: fusesoc not on PATH -- source /oss-tools/init.sh"; exit 1; }
  # The testbench and everything it needs, exactly as `make questa` compiles
  # it: let FuseSoC resolve the sim_questa target and write the compile
  # script, without running it. gate_sim.do replays that script, then
  # compiles the netlist on top so it replaces the RTL top module.
  EDA_DIR=$FLOW_ROOT/build/gate/sim_questa-modelsim
  (cd "$FLOW_ROOT" && fusesoc --cores-root . run --setup --build-root build/gate \
     --target sim_questa "$CORE") > "$PWR_DIR/fusesoc_setup.log" 2>&1 \
    || { echo "ERROR: fusesoc setup failed -- read $PWR_DIR/fusesoc_setup.log"; exit 1; }
  rm -f "$VCD_FILE"
  vsim -c -do "set LAB $FLOW_ROOT; set EDA_DIR $EDA_DIR; set TOP $TOP_MODULE; \
               set TB $TB; set DUT_INST $DUT_INST; set VECDIR ${VECDIR:-$FLOW_ROOT/vectors}/; \
               set POSTLAYOUT ${POSTLAYOUT}; set CLK_PERIOD_PS ${CLK_PS}; \
               do questa/gate_sim.do"
else
  echo "### [1/2] skipped, reusing $VCD_FILE"
fi

[[ -f "$VCD_FILE" ]] || { echo "ERROR: no VCD at $VCD_FILE"; exit 1; }
echo "    VCD: $(du -h "$VCD_FILE" | cut -f1)"
[[ $SIM_ONLY -eq 0 ]] || { echo "### done (--sim-only)"; exit 0; }

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

# --- the typical-corner library, compiled once ---------------------------
# PrimePower needs the Liberty compiled to a .db: it can read the .lib
# directly, but then it drops the cells' internal power and leakage (the PDK
# Liberty lacks the char_config attribute PrimeTime wants, LBDB-366) and
# reports switching power only -- about half the real number, silently.
# Library Compiler fills in the defaults when it compiles. The .db lands in
# the same cache synthesis uses for its own (slow) corner. Nothing is
# re-synthesised: the netlist is the slow-corner one, linked at typical.
LIB_DIR=$IHP_PDK_ROOT/libs.ref/sg13g2_stdcell/lib
PWR_DB=$FLOW_ROOT/implementation/design_compiler/db/sg13g2_stdcell_${PWR_CORNER}.db
if [[ ! -f "$PWR_DB" ]]; then
  echo "### compiling the ${PWR_CORNER} Liberty to a .db (once, cached)"
  command -v lc_shell >/dev/null || { echo "ERROR: lc_shell not on PATH -- source /eda/scripts/init_design_vision"; exit 1; }
  mkdir -p "$(dirname "$PWR_DB")"
  lc_shell -x "read_lib $LIB_DIR/sg13g2_stdcell_${PWR_CORNER}.lib; \
               write_lib sg13g2_stdcell_${PWR_CORNER} -format db -output $PWR_DB; quit" \
    > "$PWR_DIR/lc_shell.log" 2>&1
  [[ -f "$PWR_DB" ]] || { echo "ERROR: lc_shell wrote no $PWR_DB -- read $PWR_DIR/lc_shell.log"; exit 1; }
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
      set PWR_CORNER $PWR_CORNER; \
      set PWR_DB $PWR_DB; \
      set RPT $RPT; \
      set STRIP_PATH $STRIP_PATH" \
  -file scripts/pwr_script.tcl \
  -output_log_file ${SHELL_BIN}_${RPT}.log

if [[ ! -f "$PWR_DIR/reports/${RPT}_power.rpt" ]]; then
  echo "ERROR: PrimePower wrote no ${RPT}_power.rpt -- read ${SHELL_BIN}_${RPT}.log"
  exit 1
fi

echo "### done -- reports in $PWR_DIR/reports/"

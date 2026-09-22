# Read every source of cordic_accel, in dependency order.
#
# This is the by-hand equivalent of what FuseSoC generates: when Design
# Compiler is driven through FuseSoC, edalize writes a
# <core>-read-sources.tcl with exactly these `analyze` commands, derived from
# the .core dependency tree. This file exists so the same synthesis script
# also runs standalone, and so you can see what the generated one contains.
#
# Paths are relative to implementation/design_compiler/.

set LAB    ../..
set VENDOR ${LAB}/vendor/pulp_platform

# Header files are found through search_path, not through analyze.
set search_path [concat [list ${VENDOR}/common_cells/include \
                              ${VENDOR}/register_interface/include \
                              ${VENDOR}/obi/include ] $search_path]

# --- vendored IPs -------------------------------------------------------
# Packages first: everything below imports from them.
analyze -f sverilog -lib WORK ${VENDOR}/common_cells/src/cf_math_pkg.sv
analyze -f sverilog -lib WORK ${VENDOR}/common_cells/src/fifo_v3.sv
analyze -f sverilog -lib WORK ${VENDOR}/common_cells/src/credit_counter.sv

# The technology cells. NOT the behavioural ones from tech_cells_generic:
# for synthesis, tc_clk_gating is the wrapper around sg13g2_lgcp_1, the
# library's integrated clock gating cell. Same module name, same ports, real
# cell inside. Synthesising the behavioural model instead would build a latch
# out of standard cells and AND it with the clock -- see the README.
analyze -f sverilog -lib WORK ${LAB}/implementation/tech/sg13g2/tc_clk_gating_sg13g2.sv

# The register interface protocol and the OpenTitan register primitives the
# generated CSR block instantiates.
analyze -f sverilog -lib WORK ${VENDOR}/register_interface/src/reg_intf.sv
analyze -f sverilog -lib WORK ${VENDOR}/register_interface/vendor/lowrisc_opentitan/src/prim_subreg_arb.sv
analyze -f sverilog -lib WORK ${VENDOR}/register_interface/vendor/lowrisc_opentitan/src/prim_subreg.sv
analyze -f sverilog -lib WORK ${VENDOR}/register_interface/vendor/lowrisc_opentitan/src/prim_subreg_ext.sv

# The OBI protocol package (types only; the interfaces are simulation-side).
analyze -f sverilog -lib WORK ${VENDOR}/obi/src/obi_pkg.sv

# --- the accelerator ----------------------------------------------------
analyze -f sverilog -lib WORK ${LAB}/rtl/cordic_pkg.sv
analyze -f sverilog -lib WORK ${LAB}/rtl/cordic_accel_types_pkg.sv
analyze -f sverilog -lib WORK ${LAB}/rtl/cordic_accel_reg_pkg.sv
analyze -f sverilog -lib WORK ${LAB}/rtl/cordic_accel_reg_top.sv
analyze -f sverilog -lib WORK ${LAB}/rtl/cordic_rot.sv
analyze -f sverilog -lib WORK ${LAB}/rtl/cordic_accel.sv

# Logic synthesis of cordic_accel with Synopsys Design Compiler,
# IHP SG13G2 (130 nm BiCMOS, open PDK).
#
# The same script runs two ways:
#
#   through FuseSoC   make synth      (from lab1/)
#       edalize starts dc_shell in its own build directory and pre-defines
#       TOP_MODULE, SCRIPT_DIR, REPORT_DIR and READ_SOURCES (the generated
#       file list) before sourcing this script.
#
#   by hand           dc_shell-xg-t -f scripts/dc_script.tcl > synth.log
#       (from implementation/design_compiler/) -- none of those variables
#       exist, so the defaults below fill them in and the sources come from
#       scripts/analyze_sources.tcl instead of the generated list.
#
# Run it by hand first, one command at a time, following the README. Only
# then use the script: a script you cannot read is a script you cannot debug.

# A fatal error has to take dc_shell down with it. `error' alone does not:
# the script is pulled in with Tcl's `source', so dc_shell prints the message
# and carries on to the next command. A missing PDK then leaves
# target_library empty, synthesis falls back to the built-in `gtech' library,
# and you get a complete set of reports describing a netlist of generic
# gates -- zero area, meaningless slack. (`sh_script_stop_severity' does not
# help here either: it governs `include', not `source'.)
proc die {msg} {
  puts "ERROR: $msg"
  exit 1
}

# --- defaults for the standalone run ------------------------------------
if {![info exists TOP_MODULE]}  { set TOP_MODULE  cordic_accel }
if {![info exists SCRIPT_DIR]}  { set SCRIPT_DIR  scripts }
if {![info exists REPORT_DIR]}  { set REPORT_DIR  reports }
if {![info exists NETLIST_DIR]} { set NETLIST_DIR ${REPORT_DIR}/../netlist }

sh mkdir -p ${REPORT_DIR} ${NETLIST_DIR} work

# Start from a clean slate. Design Compiler happily reuses the results of a
# previous run in the same session, which makes a sweep non-reproducible.
remove_design -all

# ========================================================================
#  Technology: IHP SG13G2
# ========================================================================
# This is the whole library setup: there is no .synopsys_dc.setup anywhere.
# Design Compiler reads that file automatically, but ONLY from the directory
# dc_shell was started in -- and FuseSoC starts it in its own build
# directory, where the file is not. A setup that applies to one of the two
# ways you run the flow and silently does not apply to the other is worse
# than no setup file, so the libraries are set here, once, for both.

# Where the PDK is installed. Override from the shell if yours is elsewhere:
#   export IHP_PDK_ROOT=/path/to/ihp-sg13g2
if {[info exists ::env(IHP_PDK_ROOT)]} {
  set PDK [string trim $::env(IHP_PDK_ROOT)]
} else {
  set PDK /oss-tools/pdk/ihp-sg13g2
}
set PDK_LIB ${PDK}/libs.ref

# The PVT corner to synthesise at. The slow corner is the one that decides
# whether the design meets its clock: worst-case process, lowest voltage,
# highest temperature. Synthesise at typ while you explore, sign off at slow.
#   typ   sg13g2_stdcell_typ_1p20V_25C     1.20 V,  25 C
#   slow  sg13g2_stdcell_slow_1p08V_125C   1.08 V, 125 C   <- setup sign-off
#   fast  sg13g2_stdcell_fast_1p32V_m40C   1.32 V, -40 C   <- hold sign-off
if {[info exists ::env(SG13G2_CORNER)]} {
  set CORNER [string trim $::env(SG13G2_CORNER)]
} else {
  set CORNER slow_1p08V_125C
}
set STDCELL_LIB sg13g2_stdcell_${CORNER}

# The PDK ships Liberty (.lib), not the compiled .db that Design Compiler
# needs -- open PDKs generally do. Library Compiler turns one into the other,
# and the result only has to be built once, so build it on demand and cache
# it next to the scripts.
set DB_DIR ${SCRIPT_DIR}/../db
sh mkdir -p ${DB_DIR}

# Compile a Liberty file into the .db Design Compiler needs, once, and cache
# it. Three things here are not obvious and all three were found the hard
# way on the lab server:
#
#   * `write_lib' is refused inside dc_shell unless you ask first:
#         Error: write_lib in dc_shell is not enabled. Please start new
#         session and do enable_write_lib_mode to enable it, or use
#         lc_shell instead. (UIL-91)
#     `enable_write_lib_mode' turns it on. It must be called before
#     `read_lib', and it is harmless if the mode is already on.
#
#   * there is no `remove_lib' command in dc_shell (CMD-005). The library
#     stays in memory; that costs nothing and nothing later depends on it
#     being gone.
#
#   * if this proc fails, STDCELL_DB is never set, `target_library' stays
#     empty, and dc_shell quietly falls back to its built-in `gtech'
#     library. The synthesis then "works" and produces a netlist of generic
#     gates that mean nothing. So: check, and stop -- `die', not `error'.
proc ensure_db {lib_name lib_path db_dir} {
  set db ${db_dir}/${lib_name}.db
  if {[file exists $db]} {
    puts "libraries: using cached $db"
    return $db
  }
  if {![file exists $lib_path]} {
    die "cannot find $lib_path -- is IHP_PDK_ROOT set correctly?"
  }
  puts "libraries: compiling $lib_path -> $db (needs a Library Compiler licence)"
  if {[catch {enable_write_lib_mode} msg]} {
    puts "libraries: enable_write_lib_mode said: $msg"
  }
  read_lib $lib_path
  write_lib $lib_name -format db -output $db
  if {![file exists $db]} {
    die "failed to write $db.\n\
           Compile it outside dc_shell instead:\n\
           lc_shell -x \"read_lib $lib_path; write_lib $lib_name -format db -output $db; quit\""
  }
  return $db
}

set STDCELL_DB [ensure_db ${STDCELL_LIB} \
                          ${PDK_LIB}/sg13g2_stdcell/lib/${STDCELL_LIB}.lib \
                          ${DB_DIR}]

# Add a memory or an IO macro here when the design grows one: same call,
# ${PDK_LIB}/sg13g2_sram/lib/... or ${PDK_LIB}/sg13g2_io/lib/..., and append
# the resulting .db to link_library below. Macros are read for their timing
# only -- Design Compiler treats them as black boxes and reports them on the
# "macro" line of report_area.
set MACRO_DBS [list]

# target_library     the cells the synthesizer may put in the netlist
# link_library       everything needed to resolve a reference ("*" = designs
#                    already in memory), plus DesignWare and any macros
# synthetic_library  DesignWare: lets the tool recognise adders, multipliers
#                    and friends and choose an implementation that meets the
#                    constraints instead of building what the RTL literally
#                    said. It comes from the Synopsys installation, not from
#                    the PDK.
set search_path [concat [list . ${DB_DIR} \
                              /eda/synopsys/2021-22/RHELx86/SYN_2021.06-SP4/libraries/syn ] \
                        $search_path]

set target_library    [list ${STDCELL_DB}]
set link_library      [concat [list "*" ${STDCELL_DB} "dw_foundation.sldb"] ${MACRO_DBS}]
set synthetic_library [list "dw_foundation.sldb"]

if {[llength $target_library] == 0} {
  die "target_library is empty -- dc_shell would silently synthesise to gtech"
}

puts "technology: IHP SG13G2, corner ${CORNER}"

# Keep the RTL hierarchy names in the netlist. Without this the names change,
# and the switching activity recorded in simulation can no longer be
# annotated onto the gate-level design for power estimation.
set power_preserve_rtl_hier_names true

# WORK is where Design Compiler keeps its intermediate files; the logical
# name has to be bound to a real directory, created above.
define_design_lib WORK -path ./work

# ========================================================================
#  Read the design
# ========================================================================
if {[info exists READ_SOURCES]} {
  # FuseSoC path: the file list edalize generated from the .core dependencies
  source ${READ_SOURCES}.tcl
} else {
  # Standalone path: the hand-written list
  source ${SCRIPT_DIR}/analyze_sources.tcl
}

elaborate ${TOP_MODULE}
uniquify
link

# ========================================================================
#  Constraints
# ========================================================================
source ${SCRIPT_DIR}/set_constraints.tcl

report_clocks > ${REPORT_DIR}/clocks.rpt

# ========================================================================
#  Synthesis
# ========================================================================
# compile_ultra is the high-effort flow; the course notes use plain `compile`.
# Run both at the same constraint and compare -- that difference is what
# effort buys, and it is worth knowing before you trust either number.
# compile -gate_clock
#
# -gate_clock lets the tool insert clock gates on enable-driven registers. In
# this technology it uses sg13g2_lgcp_1, the library's integrated clock
# gating cell (a posedge latch plus an AND, as one characterised cell).
compile_ultra -gate_clock

# ========================================================================
#  Reports
# ========================================================================
# Timing first: if the slack is negative nothing else matters yet.
report_timing -nosplit                  > ${REPORT_DIR}/timing.rpt
report_timing -nosplit -max_paths 10    > ${REPORT_DIR}/timing_top10.rpt
report_area   -hierarchy -nosplit       > ${REPORT_DIR}/area.rpt
report_power  -nosplit                  > ${REPORT_DIR}/power_estimate.rpt
report_qor                              > ${REPORT_DIR}/qor.rpt
report_resources -hierarchy             > ${REPORT_DIR}/resources.rpt
report_reference -hierarchy             > ${REPORT_DIR}/reference.rpt

# ========================================================================
#  Outputs for the rest of the flow
# ========================================================================
# Flatten the hierarchy before writing out: place and route, and the
# switching-activity power estimation, both work on the flat netlist.
ungroup -all -flatten

# Verilog naming rules: the netlist has to be readable by tools that do not
# speak SystemVerilog escaping.
change_names -hierarchy -rules verilog

write -f verilog -hierarchy -output ${NETLIST_DIR}/${TOP_MODULE}.v
write_sdf                           ${NETLIST_DIR}/${TOP_MODULE}.sdf
write_sdc                           ${NETLIST_DIR}/${TOP_MODULE}.sdc
write -f ddc -hierarchy -output     ${NETLIST_DIR}/${TOP_MODULE}.ddc

puts "synthesis done: netlist in ${NETLIST_DIR}, reports in ${REPORT_DIR}"

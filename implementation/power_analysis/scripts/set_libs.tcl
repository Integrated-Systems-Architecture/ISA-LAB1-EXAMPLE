# ===========================================================================
#  set_libs.tcl -- which Liberty the power analysis uses.
#
#  Same role as implementation/common/primetime/set_libs.tcl in the SoC
#  flow, at one twentieth the size: one standard cell library, no pads, no
#  register files, no memories -- until you add one.
#
#  ANALYSIS_MODE picks the corner, and it is set by pwr_script.tcl.
#
#  Which corner for power? Not the one you signed timing off at.
#
#    timing sign-off   slow, 1.08 V, 125 C -- the worst case for SPEED
#    power analysis    typ,  1.20 V,  25 C -- what the chip actually does
#
#  Dynamic power goes as C*V^2*f, so the slow corner's 1.08 V would
#  UNDER-report it by about 20 %. Leakage goes the other way and roughly
#  doubles every 10 C, so the slow corner's 125 C over-reports leakage by a
#  large factor. Neither number is the chip on a desk. Report typical, and
#  say that is what you did.
#
#  PrimePower wants the compiled .db, exactly as Design Compiler does, and
#  the synthesis flow already built and cached them under
#  implementation/design_compiler/db/. Reusing them is not just convenient:
#  the same .db in synthesis and in power analysis is one fewer thing that
#  can silently differ.
# ===========================================================================

set DB_DIR $FLOW_ROOT/implementation/design_compiler/db

set lib_std(tc) $DB_DIR/sg13g2_stdcell_typ_1p20V_25C.db
set lib_std(wc) $DB_DIR/sg13g2_stdcell_slow_1p08V_125C.db
set lib_std(bc) $DB_DIR/sg13g2_stdcell_fast_1p32V_m40C.db

# If you added an SRAM, its .db goes here too -- the macro burns power like
# everything else, and a report that leaves it out is missing the biggest
# single consumer in most accelerators.
#
#   set lib_mem(tc) $DB_DIR/RM_IHPSG13_1P_1024x32_c2_bm_bist_typ_1p20V_25C.db
#   set target_library "$lib_std($ANALYSIS_MODE) $lib_mem($ANALYSIS_MODE)"

set target_library "$lib_std($ANALYSIS_MODE)"
set link_library   "* $target_library"

puts "------------------------------------------------------------------"
puts "USED LIBRARIES ($ANALYSIS_MODE)"
puts $link_library
puts "------------------------------------------------------------------"

foreach db $target_library {
  if {![file exists $db]} {
    error "missing $db -- run `make synth` in lab1/ so the .db cache is built,\n\
           or `make synth SG13G2_CORNER=typ_1p20V_25C` for the typical corner"
  }
}

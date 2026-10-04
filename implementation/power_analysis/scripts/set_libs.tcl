# ===========================================================================
#  set_libs.tcl -- which Liberty the power analysis uses.
#
#  Same role as implementation/common/primetime/set_libs.tcl in the SoC
#  flow, at one twentieth the size: one standard cell library, no pads, no
#  register files, no memories -- until you add one.
#
#  PWR_CORNER picks the corner (run_pwr_flow.sh sets it; the Makefile knob
#  of the same name defaults to typ_1p20V_25C).
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
#  The netlist is the one synthesised at the slow corner; nothing is
#  re-synthesised. PrimePower simply links the same cells against the
#  typical-corner characterisation. It needs that Liberty compiled to a .db
#  (read straight from the .lib it loses internal power and leakage), which
#  run_pwr_flow.sh does once with lc_shell, into the same cache under
#  implementation/design_compiler/db/ that synthesis uses.
# ===========================================================================

if {![info exists PWR_CORNER]} { set PWR_CORNER typ_1p20V_25C }
if {![info exists PWR_DB]} {
  set PWR_DB $FLOW_ROOT/implementation/design_compiler/db/sg13g2_stdcell_${PWR_CORNER}.db
}

# If you added an SRAM, its .db goes here too -- the macro burns power like
# everything else, and a report that leaves it out is missing the biggest
# single consumer in most accelerators. Compile its Liberty the same way.
#
#   set target_library "$PWR_DB $FLOW_ROOT/implementation/design_compiler/db/RM_IHPSG13_1P_1024x32_c2_bm_bist_typ_1p20V_25C.db"

set target_library "$PWR_DB"

foreach db $target_library {
  if {![file exists $db]} {
    error "missing $db -- run_pwr_flow.sh (make power) compiles it"
  }
}

set link_path "* $target_library"

puts "------------------------------------------------------------------"
puts "USED LIBRARIES ($PWR_CORNER)"
puts $link_path
puts "------------------------------------------------------------------"

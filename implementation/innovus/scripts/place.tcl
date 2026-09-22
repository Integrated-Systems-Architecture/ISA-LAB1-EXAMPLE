# ===========================================================================
#  04 -- Placement (and pre-CTS optimisation).
#
#  GUI equivalent:  Place -> Place Standard Cell...
#                   ECO   -> Optimize Design... (Design Stage: Pre-CTS)
#  Legacy commands: placeDesign / optDesign -preCTS
#
#  Every cell gets a row and a position. `place_opt_design` does not only
#  place: it places, then optimises the logic for the placement it just
#  made -- resizing gates, adding buffers, restructuring -- and then
#  re-places what it changed. Placement and pre-CTS optimisation are one
#  step because separating them means optimising for positions that are
#  about to change.
#
#  The clock is still ideal here. Every timing number this step produces
#  assumes the clock edge arrives everywhere at once, which it will not
#  after CTS. Believe the setup slack; do not believe the hold slack.
# ===========================================================================

redirect -tee $REPORT_DIR/04_place.log {

  log_stage "Placement"

  # Is the problem even well posed? check_timing finds constraint mistakes
  # -- unconstrained endpoints, clocks that reach nothing, inputs with no
  # arrival time. A path with no constraint on it is never reported as
  # violating, so this report is the one that catches the timing you are
  # not checking.
  check_timing -verbose > $REPORT_DIR/04_place.check_timing.rpt
  check_design -type all -out_file $REPORT_DIR/04_place.check_design.rpt

  # Let the placer know about clock gates: it keeps the registers behind one
  # ICG together, so the gated clock net stays short. Those ICGs are the
  # ones Design Compiler inserted with -gate_clock, plus the explicit
  # tc_clk_gating around the rotator.
  set_db place_global_clock_gate_aware true

  log PLACE "Running place_opt_design"
  place_opt_design -report_dir $REPORT_DIR/04_place.place_opt

  # Tie cells: constants in the netlist have to become real cells driving a
  # real net. Do it after placement so each one lands near its load.
  # $design(tie_cells) is a list of cell:pin, not bare cell names -- see the
  # comment where it is set in globals.tcl.
  add_tieoffs -cell $design(tie_cells) -prefix TIE

  log PLACE "Reporting post-placement"

  time_design -pre_cts -expanded_views       -report_dir $REPORT_DIR/04_place.timing
  time_design -pre_cts -expanded_views -hold -report_dir $REPORT_DIR/04_place.timing

  report_timing -nworst 10 > $REPORT_DIR/04_place.timing_top10.rpt
  report_area -detail      > $REPORT_DIR/04_place.area.rpt

  # Congestion: the fraction of the routing tracks in each region that the
  # global router would need. Over 100 % anywhere and the detailed router
  # will not be able to finish. The fix is never in this file -- it is
  # lower utilisation or a different shape, back in floorplan.tcl.
  report_congestion -hotspot > $REPORT_DIR/04_place.congestion.rpt

  write_db $design(DB_DIR)/post_place.db
}

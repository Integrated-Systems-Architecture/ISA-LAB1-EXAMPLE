# ===========================================================================
#  05 -- Clock tree synthesis (and post-CTS optimisation).
#
#  GUI equivalent:  Clock -> CCOpt Clock Tree Debugger / Clock -> Synthesize
#                   ECO   -> Optimize Design... (Design Stage: Post-CTS)
#  Legacy commands: set_ccopt_property / create_ccopt_clock_tree /
#                   ccopt_design / optDesign -postCTS -hold
#
#  Up to now the clock was ideal: one net reaching every flip-flop with no
#  delay and no skew. It is not a net, it is a tree of buffers, and this is
#  where it gets built.
#
#  Two numbers to aim at, both in globals.tcl:
#
#    target skew        how much the arrival times at different flops may
#                       differ. Skew eats directly into the setup budget
#                       and can create hold violations out of nothing.
#    target max trans   the slowest edge allowed anywhere in the tree. A
#                       lazy clock edge is jitter, and jitter is margin you
#                       have to give back.
#
#  Then hold. Before CTS, hold checking is meaningless -- there is no clock
#  delay to race against. After CTS there is, and fixing hold is what the
#  second half of this script does. It fixes it by ADDING delay: buffers
#  whose only job is to slow a fast path down. They cost area and power and
#  they are not optional.
# ===========================================================================

redirect -tee $REPORT_DIR/05_cts.log {

  log_stage "Clock tree synthesis"

  # Which cells the tree may be built from. SG13G2 has no dedicated clock
  # buffer family, so these are the ordinary buffers and inverters -- the
  # strong ones only, see globals.tcl.
  # Every CTS setting is a `set_db cts_*' attribute. The legacy Common UI
  # spelled these as `set_ccopt_property target_skew 0.10'; Stylus does not
  # have that command at all --
  #     **ERROR: (IMPSE-110): invalid command name "set_ccopt_property"
  # -- and the property names change too (target_max_trans becomes
  # cts_target_max_transition_time). `get_db cts_*' lists the real ones.
  set_db cts_buffer_cells        $design(cts_buffers)
  set_db cts_inverter_cells      $design(cts_inverters)
  set_db cts_clock_gating_cells  {sg13g2_lgcp_1 sg13g2_slgcp_1}
  set_db cts_use_inverters       true

  set_db cts_target_skew                 $design(cts_target_skew)
  set_db cts_target_max_transition_time  $design(cts_target_max_trans)

  # CTS picks preferred routing layers for the clock and warns if they fall
  # outside the router's range (IMPCCOPT-1361, "likely to cause routing
  # correlation issues"). The range was set in floorplan.tcl; set it again
  # here so a restart from post_place.db does not lose it.
  set_db design_bottom_routing_layer $design(route_bottom_layer)
  set_db design_top_routing_layer    $design(route_top_layer)

  log CTS "target skew $design(cts_target_skew) ns, max transition $design(cts_target_max_trans) ns"

  # Build the tree. ccopt_design derives the tree structure from the SDC's
  # clocks itself, so there is no separate spec step to run first.
  ccopt_design -report_dir $REPORT_DIR/05_cts.ccopt

  log CTS "Reporting the tree"
  report_clock_trees -out_file $REPORT_DIR/05_cts.clock_trees.rpt
  report_skew_groups -out_file $REPORT_DIR/05_cts.skew_groups.rpt

  # The clock is real now, so the guess we made in init.tcl is no longer
  # needed for setup: the tool measures the skew instead of budgeting for
  # it. Keeping both is double-counting, and you pay for it in area.
  # Hold uncertainty stays -- that is jitter, and jitter does not go away
  # because the tree exists.
  set_interactive_constraint_modes [all_constraint_modes -active]
  set_clock_uncertainty -setup 0.03 [all_clocks]
  set_clock_uncertainty -hold  0.05 [all_clocks]
  set_interactive_constraint_modes {}

  set_analysis_view -update_timing

  time_design -post_cts -expanded_views       -report_dir $REPORT_DIR/05_cts.timing
  time_design -post_cts -expanded_views -hold -report_dir $REPORT_DIR/05_cts.timing

  log CTS "Optimizing post-CTS, setup and hold"
  opt_design -post_cts -setup -hold -report_dir $REPORT_DIR/05_cts.opt

  report_timing -nworst 10             > $REPORT_DIR/05_cts.timing_setup.rpt
  report_timing -nworst 10 -early      > $REPORT_DIR/05_cts.timing_hold.rpt
  report_area -detail                  > $REPORT_DIR/05_cts.area.rpt

  write_db $design(DB_DIR)/post_cts.db
}

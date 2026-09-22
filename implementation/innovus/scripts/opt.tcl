# ===========================================================================
#  07 -- Post-route optimisation.
#
#  GUI equivalent:  ECO -> Optimize Design... (Design Stage: Post-Route)
#  Legacy commands: optDesign -postRoute -setup / -hold / -drv
#
#  The last chance to fix timing. Everything this step does is an ECO: it
#  changes a few cells and re-routes only the nets it touched, so the rest
#  of the routing survives.
#
#  Three passes, and the order is not arbitrary:
#
#    setup   make the slow paths faster -- bigger drivers, better buffering
#    hold    make the fast paths slower -- delay buffers. Doing this before
#            setup would mean adding delay to paths setup is about to
#            restructure.
#    drv     design rule violations: max transition, max capacitance, max
#            fanout. Not timing, but a library is only characterised inside
#            these limits, so a violated one makes every delay downstream
#            of it a guess.
#
#  If setup slack is still negative after this, the answer is not another
#  opt_design. It is a lower clock frequency, a different floorplan, or a
#  different microarchitecture -- and that is a result too, as long as you
#  report it.
# ===========================================================================

# ---------------------------------------------------------------------------
#  OFF BY DEFAULT ON THIS TOOL VERSION. Enable with:  PNR_POST_ROUTE_OPT=1
#
#  On Innovus 20.11 with this design, all three post-route passes fail:
#
#      -- [OPT] WARNING: opt_design -post_route -setup returned: 0
#      -- [OPT] WARNING: opt_design -post_route -hold returned: 0
#      -- [OPT] WARNING: opt_design -post_route -drv returned: 0
#
#  preceded by an internal assert (goTimingPreserveUserMode). They do not
#  fail cleanly: they leave ECO cells in the database that were never
#  routed. Measured, on the design that is DRC-clean at the end of routing:
#
#                        end of route      after post-route opt
#      DRC violations               2                      1754
#      unconnected terminals        0                       322
#      net pieces unconnected       0                       313
#
#  An earlier version of this script wrapped each pass in `catch' so the
#  flow could reach export. That was a mistake worth naming: it turned a
#  loud failure into a silent one, and the flow went on to write a netlist,
#  an SDF, a SPEF and a GDS from a corrupt database. A stage that fails
#  should stop the flow, not be stepped over.
#
#  So the default flow is route -> export, which is consistent and clean:
#
#      setup slack  +0.081 ns  (MET)
#      hold slack   -0.265 ns  (NOT met -- see below)
#      DRC                  2  violations
#
#  The cost is real and you must report it: HOLD IS NOT FIXED. Post-route
#  hold repair is exactly what this stage exists to do. Hold was attempted
#  after CTS (opt_design -post_cts -hold, in cts.tcl, which does work), and
#  what is left is -0.265 ns. A chip cannot ship like that; a lab result
#  can, provided you say so.
#
#  If you want to work on this: run the flow to post_route.db, then try the
#  passes by hand --
#      read_db artefacts/db/post_route.db
#      opt_design -post_route -hold
#      check_connectivity -type all
#  -- and watch whether the terminal count goes non-zero. Resuming from
#  post_route.db in a fresh session has been observed to succeed where the
#  same commands fail in the full flow, which points at leftover session
#  state rather than at the design.
# ---------------------------------------------------------------------------

if {![info exists ::env(PNR_POST_ROUTE_OPT)] || $::env(PNR_POST_ROUTE_OPT) == 0} {
  log_stage "Post-route optimisation SKIPPED (set PNR_POST_ROUTE_OPT=1 to enable)"
  log OPT "hold slack is left unfixed -- see the header of scripts/opt.tcl"
} else {

redirect -tee $REPORT_DIR/07_opt.log {

  log_stage "Post-route optimisation"

  # No `catch' here on purpose. If a pass fails, the flow stops and you
  # find out, rather than exporting a corrupt database.
  foreach {what args} {
    setup {-setup}
    hold  {-hold}
    drv   {-drv}
  } {
    log OPT "post-route optimisation: $what"
    opt_design -post_route {*}$args -expanded_views \
               -report_dir $REPORT_DIR/07_opt.timing
  }

  extract_rc

  log OPT "Reporting post-optimisation"
  report_timing -nworst 10        > $REPORT_DIR/07_opt.timing_setup.rpt
  report_timing -nworst 10 -early > $REPORT_DIR/07_opt.timing_hold.rpt
  report_area -detail             > $REPORT_DIR/07_opt.area.rpt
  report_power                    > $REPORT_DIR/07_opt.power_estimate.rpt

  # Optimisation changes the netlist, so the routed database must be
  # re-verified before anything is written out.
  check_connectivity -type all -out_file $REPORT_DIR/07_opt.connectivity.rpt

  write_db $design(DB_DIR)/post_opt.db
}

}

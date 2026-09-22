# ===========================================================================
#  08 -- Fillers, verification, and everything the next tool needs.
#
#  GUI equivalent:  Place -> Physical Cell -> Add Filler...
#                   Verify -> Verify Connectivity / Verify DRC
#                   File -> Save -> Netlist / Timing -> Write SDF
#  Legacy commands: addFiller / verifyConnectivity / verifyGeometry /
#                   saveNetlist / write_sdf / rcOut
#
#  Fillers first, because they change the layout; verification second,
#  because it has to run on the layout you are actually shipping; exports
#  last.
#
#  Four files leave this step and each one has exactly one consumer:
#
#    netlist.v     the gate-level netlist WITH the clock tree in it. This
#                  is the one to simulate and the one PrimePower reads --
#                  not Design Compiler's, which has an ideal clock and none
#                  of these buffers.
#    netlist.sdf   cell and net delays. Back-annotated onto the netlist in
#                  QuestaSim, it is what makes the gate-level simulation
#                  timing-accurate.
#    netlist.spef  the extracted parasitics, for a static timing sign-off
#                  in PrimeTime.
#    <top>.gds     the layout itself.
# ===========================================================================

redirect -tee $REPORT_DIR/08_export.log {

  log_stage "Fillers, verification and export"

  # --- fillers ----------------------------------------------------------
  # The gaps between placed cells are not empty silicon -- the n-well and
  # the implant layers have to be continuous along a row, and a gap breaks
  # them. Filler cells carry no logic and exist to restore that continuity.
  #
  # Decap cells do the same job and add supply decoupling while they are
  # there, which is why they go in first: they are worth more than plain
  # filler, and plain filler mops up whatever is left.
  # FILL CELLS ONLY -- deliberately no decaps here, and this is the one
  # place in the flow where that choice has a measured consequence.
  #
  # Adding `sg13g2_decap_4/_8' at this point produced 3298 DRC shorts:
  #     SHORT: ( Metal Short ) Regular Wire of Net n1408 & Pin of Cell
  #     DECAP_incr__1_857  ( Metal1 )
  # The decap cells carry wide Metal1 power geometry, and by now the router
  # has already run signal wires through the empty row space on Metal1.
  # Dropping a decap into that gap shorts the two. The plain fill cells are
  # much leaner and produced 2.
  #
  # So: if you want decoupling capacitance -- and a real chip does, for IR
  # drop and supply noise -- insert it BEFORE routing, at the end of
  # cts.tcl, so the router sees the cells and goes around them. Adding it
  # afterwards cannot work, whatever the prefix.
  #
  # This block is 275 um square and has no decaps. That is a defensible
  # simplification for a lab and an indefensible one for silicon; say which
  # you did.
  # add_fillers_with_drc defaults to TRUE, and the tool says so in the log:
  #
  #     *INFO: Filler mode add_fillers_with_drc is default true to avoid
  #     gaps, which may add fillers with violations. Please check the
  #     violations for FILLER_incr* fillers and fix them before
  #     routeDesign. Set it to false can avoid the violation but may leave
  #     gaps.
  #
  # Read that again: the default knowingly places fillers that violate DRC,
  # on the assumption you will route afterwards and fix them. We are past
  # routing, so nothing fixes them -- and the result was 1756 violations
  # (1303 of them shorts against the pins of the ECO cells opt_design had
  # inserted) on a design that was clean with 2 violations at the end of
  # routing.
  #
  # Turning it off leaves small gaps in the rows instead. For this block
  # that is the right trade: a gap costs continuity in the wells, which
  # matters at tape-out and not in a lab, whereas 1756 shorts make the
  # layout meaningless. A real flow inserts fillers BEFORE the final route
  # so neither compromise is needed.
  set_db add_fillers_with_drc false

  log EXPORT "Adding fillers"
  add_fillers -base_cells $design(fillers) -prefix FILLER

  # Antenna fixing is NOT done here. It is configured before routing, in
  # route.tcl, because the router has to know about it while it routes --
  # there is no post-hoc `route_design -antenna_diode_fix' on Innovus 20.11:
  #     **ERROR: (IMPTCM-48): "-antenna_diode_fix" is not a legal option
  #     for command "route_design".

  # --- verification -----------------------------------------------------
  # Two questions, and both have to be answered before anyone believes the
  # layout:
  #
  #   connectivity -- is every net actually connected, end to end, with no
  #                   floating fragment and no accidental short?
  #   DRC          -- is the geometry manufacturable? Spacings, widths,
  #                   enclosures, density.
  #
  # A clean timing report on a layout that fails either of these means
  # nothing.
  log EXPORT "Verifying"
  check_filler       -out_file $REPORT_DIR/08_export.filler.rpt
  check_place        $REPORT_DIR/08_export.place.rpt
  check_route
  # Filler insertion can leave a handful of violations behind. Fix them
  # before the final check rather than reporting them.
  # --- repair, then verify ----------------------------------------------
  # ORDER MATTERS, and this is the subtle one. `route_eco -fix_drc' repairs
  # violations that have been MARKED -- it works from the marker database
  # that check_drc creates. Call it before any check_drc has run and it
  # simply does nothing, returning an empty error:
  #     -- [EXPORT] WARNING: route_eco -fix_drc did not run:
  # and the violations sail through to the final report. That is how 1754
  # violations survived a flow that looked like it was repairing them.
  #
  # So: check first to mark them, repair, then check again for the report.
  log EXPORT "Marking DRC violations"
  check_drc -limit 100000 -out_file $REPORT_DIR/08_export.drc_before_eco.rpt

  log EXPORT "Repairing them"
  if {[catch {route_eco -fix_drc} msg]} {
    log EXPORT "WARNING: route_eco -fix_drc did not run: $msg"
  }

  log EXPORT "Re-checking"
  check_connectivity -type all -out_file $REPORT_DIR/08_export.connectivity.rpt
  check_drc -limit 100000      -out_file $REPORT_DIR/08_export.drc.rpt

  # --- final numbers ----------------------------------------------------
  extract_rc

  report_area  -detail > $REPORT_DIR/08_export.area.rpt
  report_gate_count    > $REPORT_DIR/08_export.gate_count.rpt
  report_power         > $REPORT_DIR/08_export.power_estimate.rpt
  report_timing -nworst 10        > $REPORT_DIR/08_export.timing_setup.rpt
  report_timing -nworst 10 -early > $REPORT_DIR/08_export.timing_hold.rpt

  # --- exports ----------------------------------------------------------
  set OUT $design(EXPORT_DIR)
  log EXPORT "Writing outputs to $OUT"

  # The netlist. -include_pg_ports gives it explicit VDD/VSS ports, which
  # a power analysis wants and an ordinary gate-level simulation does not
  # -- so write both.
  write_netlist                    $OUT/$design(TOPLEVEL)_pnr.v
  write_netlist -include_pg_ports  $OUT/$design(TOPLEVEL)_pnr_pg.v

  write_sdc $OUT/$design(TOPLEVEL)_pnr.sdc

  # SDF. -recompute_delay_calc is not optional: without it you get the
  # delays as they stood at the last timing update, which may predate the
  # last ECO. Innovus itself tells you to pass it.
  # Option spellings are 20.11's; `help write_sdf' prints them. Note in
  # particular -recompute_delaycal, NOT -recompute_delay_calc:
  #     **ERROR: (IMPTCM-48): "-recompute_delay_calc" is not a legal option
  #     for command "write_sdf".
  # Without it you get the delays as they stood at the last timing update,
  # which may predate the last ECO.
  #
  # -map_setuphold merge_always is the one that matters downstream. The IHP
  # cell models declare a single $setuphold; a tool that writes separate
  # (SETUP ...) and (HOLD ...) entries cannot be matched against them and
  # QuestaSim refuses the file (vsim-SDF-3262, then a fatal 3444). That is
  # exactly the problem the Design Compiler SDF has and cannot be told to
  # avoid. Innovus can, so this SDF annotates where the synthesis one does
  # not -- which is the other reason the accurate power run is the
  # post-layout one.
  # NAME THE VIEWS. This is not optional under MMMC and the failure is
  # silent: leave them out and write_sdf emits the file, Questa annotates
  # it happily, and every delay in it is zero --
  #     ** Warning: (vsim-SDF-3924) Out of 19133 SDF statements, 19133 had
  #     null values.
  # A gate-level simulation then behaves exactly as if there were no SDF at
  # all, which is the bug you were trying to avoid by writing one.
  #
  # min/typical/max map onto the three columns of the SDF triplet. The
  # active analysis views are setup_slow and hold_fast (see lab1.view), so
  # the "typical" column here is the slow corner rather than a true typ:
  # conservative for a power run, not wrong, and worth one line in your
  # report. If you want a genuine typ column, add view_typ to
  # set_analysis_view in lab1.view and name it here.
  write_sdf $OUT/$design(TOPLEVEL)_pnr.sdf \
    -recompute_delaycal \
    -precision 4 \
    -min_view hold_fast \
    -typical_view setup_slow \
    -max_view setup_slow \
    -map_setuphold merge_always \
    -map_negative_checks \
    -map_negative_delays \
    -min_period_edges posedge

  # Parasitics, for PrimeTime.
  write_parasitics -spef_file $OUT/$design(TOPLEVEL)_pnr.spef -rc_corner rc_slow

  # The layout. -merge pulls in the GDS of every library cell, so the
  # result is a standalone file and not a hierarchy of references.
  write_stream -merge $design(ALL_GDS) \
               -die_area_as_boundary -unit 1000 -uniquify_cell_names \
               $OUT/$design(TOPLEVEL).gds

  write_db $design(DB_DIR)/final.db

  log EXPORT "Done. Reports in $REPORT_DIR, outputs in $OUT"
}

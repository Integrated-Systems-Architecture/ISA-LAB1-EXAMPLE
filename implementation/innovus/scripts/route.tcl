# ===========================================================================
#  06 -- Signal routing.
#
#  GUI equivalent:  Route -> NanoRoute -> Route...
#  Legacy commands: routeDesign / setNanoRouteMode
#
#  Every signal net becomes real metal on Metal1..Metal5, with real vias
#  and real parasitics. Two phases inside one command: a global route that
#  plans which region each net crosses, and a detailed route that draws the
#  wires and obeys the design rules.
#
#  This is also where the timing stops being an estimate. Up to now the
#  wire delays came from a statistical model of "a net with this many pins
#  in a block this size". Now there are wires, so there is extraction --
#  and the numbers move, sometimes a lot.
# ===========================================================================

redirect -tee $REPORT_DIR/06_route.log {

  log_stage "Signal routing"

  set_db design_bottom_routing_layer $design(route_bottom_layer)
  set_db design_top_routing_layer    $design(route_top_layer)

  # Prefer multi-cut vias where there is room. One via cut is a
  # reliability and resistance liability; two in parallel cost nothing but
  # space you usually have.
  # Attribute names drift between Innovus releases, and the SoC flow this
  # lab is modelled on targets a newer one. On 20.11:
  #   route_reserve_space_for_multi_cut   does not exist at all
  #   route_detail_post_route_swap_via    is
  #                                       route_design_detail_post_route_swap_via
  # Getting it wrong stops the flow:
  #   **ERROR: (IMPDBTCL-247): 'route_reserve_space_for_multi_cut' is not a
  #   recognized object or root attribute.
  # `get_db <name>' tells you whether a name exists before you rely on it.
  set_db route_design_detail_post_route_swap_via multicut

  # Antenna fixing, set BEFORE routing because the router applies it as it
  # goes. During manufacturing a long piece of metal connected to a gate
  # acts as a charge collector and can punch through the oxide before the
  # rest of the path exists; a diode gives the charge somewhere to go, and
  # splitting a net across layers ("jumpering") shortens the collector.
  #
  # Jumpering only. detail_fix_antenna is on by default: where a net
  # collects too much charge on one layer, the router splits it across
  # layers so no single piece is long enough to matter. That is free and it
  # is enough for a block this size.
  #
  # DIODE INSERTION IS DELIBERATELY OFF. Turning it on --
  #     set_db route_design_antenna_diode_insertion true
  #     set_db route_design_antenna_cell_name $design(antenna_cell)
  # -- made Innovus place sg13g2_antennanp diodes (instance prefix FE_PHC)
  # and produced 1756 DRC violations, 550 of them shorts on the diodes'
  # own pins, against a run that is otherwise DRC-clean. The diodes are
  # being dropped into space the router has already used, the same failure
  # as inserting decaps after routing (see export.tcl).
  #
  # Getting diodes in properly means reserving their space before routing,
  # which this lab does not do. If your design reports real antenna
  # violations, that is the work to do -- not flipping this flag.
  set_db route_design_detail_fix_antenna true

  # Nothing can be routed if something is placed illegally -- overlapping,
  # off-row, outside the core. Find that out now, not after an hour of
  # routing.
  check_place $REPORT_DIR/06_route.check_place.rpt

  log ROUTE "Running route_design"
  route_design

  # On-chip variation: within one corner, allow the tool to assume that
  # different parts of the die are not identical. It is pessimistic, and it
  # is what sign-off does, so turn it on before believing any post-route
  # number.
  set_db timing_analysis_type ocv

  # Extract the parasitics from the geometry that now exists. Without a QRC
  # deck this is Innovus's own rule-based extraction from the technology
  # LEF -- accurate enough to close a lab, not a foundry sign-off.
  extract_rc

  log ROUTE "Reporting post-route"
  time_design -post_route -expanded_views       -report_dir $REPORT_DIR/06_route.timing
  time_design -post_route -expanded_views -hold -report_dir $REPORT_DIR/06_route.timing

  report_timing -nworst 10        > $REPORT_DIR/06_route.timing_setup.rpt
  report_timing -nworst 10 -early > $REPORT_DIR/06_route.timing_hold.rpt

  check_drc -limit 100000 -out_file $REPORT_DIR/06_route.drc.rpt

  write_db $design(DB_DIR)/post_route.db
}

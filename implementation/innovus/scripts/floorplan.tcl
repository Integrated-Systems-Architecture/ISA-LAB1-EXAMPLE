# ===========================================================================
#  02 -- Floorplan.
#
#  GUI equivalent:  Floorplan -> Specify Floorplan...
#  Legacy commands: floorPlan -r <aspect> <util> <l> <b> <r> <t>
#
#  This is the step with the most leverage and the least tool support. You
#  are choosing how big the block is and what shape. Everything downstream
#  -- congestion, wire length, timing, power -- is decided here, and no
#  amount of optimisation later recovers a bad floorplan.
#
#  THIS IS THE FILE TO EDIT. Utilisation, aspect ratio and the margin are
#  the three knobs; they come from globals.tcl so you can also set them
#  from the shell:
#
#      make pnr PNR_UTIL=0.75 PNR_ASPECT=2.0
# ===========================================================================

redirect -tee $REPORT_DIR/02_floorplan.log {

  log_stage "Floorplan"

  # Which layers the signal router may use. Metal1..Metal5; the two thick
  # top layers are reserved for the power grid (see globals.tcl).
  set_db design_bottom_routing_layer $design(route_bottom_layer)
  set_db design_top_routing_layer    $design(route_top_layer)

  # Start from nothing, so that re-sourcing this file gives the same answer
  # as sourcing it the first time. Floorplanning commands are cumulative;
  # a flow you cannot re-run is a flow you cannot sweep.
  delete_relative_floorplan -all
  unplace_obj -all

  # --- the die --------------------------------------------------------
  # -core_density_size lets the tool size the die from the cell area it
  # already knows:
  #
  #     {aspect_ratio  utilisation  left  bottom  right  top}
  #
  # aspect_ratio 1.0 = square core. utilisation 0.60 = standard cells will
  # occupy 60 % of the core; the other 40 % is what the router needs to get
  # wires through, plus the filler that comes at the end.
  #
  # The four margins are core-to-die on each side. They have to hold the
  # power ring: two rings, each pg_ring_width wide, plus the spacings.
  # globals.tcl computes core_to_die from exactly those numbers, so if you
  # widen the ring the margin follows.
  set m $design(core_to_die)
  log FPLAN "aspect $design(aspect), utilisation $design(util), margin ${m} um"

  create_floorplan -site $design(site) \
    -core_density_size [list $design(aspect) $design(util) $m $m $m $m]

  # --- macros, if you have any -----------------------------------------
  # An SRAM is not placed by the placer: it is a block of silicon a hundred
  # times the size of a standard cell, and where it goes is your decision.
  # Place it by hand, then keep the placer a few microns away from its edge
  # with a halo -- cells jammed against a macro wall have nowhere to route.
  #
  #   place_inst i_scratchpad/i_sram 40 40 R0
  #   create_place_halo -insts i_scratchpad/i_sram \
  #                     -halo_deltas {10 10 10 10}
  #   create_route_halo -bottom_layer Metal1 -top_layer Metal4 \
  #                     -space 5 -inst i_scratchpad/i_sram
  #
  # Get the macro's size out of its LEF before you pick coordinates:
  #   get_db [get_db insts i_scratchpad/i_sram] .base_cell.bbox
  #
  # The SoC flow does this for ten memories at once in fplan_memories.tcl,
  # with create_relative_floorplan so the positions follow the die size
  # instead of being absolute. Same idea, more bookkeeping.
  if {$design(HAS_MACROS)} {
    log FPLAN "WARNING: design(SRAM_MACRO) is set but no macro placement is scripted"
    log FPLAN "         -> add place_inst / create_place_halo above"
  }

  # --- IO pins ----------------------------------------------------------
  # No pads: this is a block inside a chip, not a chip. Its "pins" are
  # points on the die edge where the level above will connect. Spread them
  # around the boundary on the two lowest layers the router can reach them
  # on.
  #
  # A full chip instead reads a pad-placement file and builds a pad ring --
  # that is fplan_io.tcl in the SoC flow, and it is the step this lab does
  # not have.
  # Inputs down the left edge, outputs down the right. A pin on a vertical
  # edge is reached by a wire running horizontally, so it goes on a
  # horizontal layer -- Metal3 here, leaving Metal1 for the cell rails.
  #
  # `edit_pin' is the whole command: there is no mode to switch on first.
  # (The legacy flow had setPinAssignMode; Stylus dropped it, and calling it
  # gives `invalid command name "set_pin_assign_mode"'.)
  # Note the nesting: `-if' filters the OBJECTS, and `.name' is applied to
  # what survives. Writing `get_db ports .name -if {...}' instead reduces the
  # ports to plain strings first and then tries to filter those, which fails
  # with
  #   **ERROR: (IMPDBTCL-248): 'direction' is not a recognized object or
  #   attribute for object type 'string'.
  # The attribute value is `in' / `out', not `input' / `output'.
  edit_pin -fix_overlap true -unit micron -spread_direction clockwise \
           -side Left -layer Metal3 -spread_type center -spacing 2 \
           -pin [get_db [get_db ports -if {.direction == in}] .name]
  edit_pin -fix_overlap true -unit micron -spread_direction clockwise \
           -side Right -layer Metal3 -spread_type center -spacing 2 \
           -pin [get_db [get_db ports -if {.direction == out}] .name]

  # Snap everything to the manufacturing grid (0.005 um here). Off-grid
  # geometry is a DRC error you will only find at the very end.
  snap_floorplan -all

  # --- look at it -------------------------------------------------------
  report_area > $REPORT_DIR/02_floorplan.area.rpt
  set die [get_db current_design .bbox]
  log FPLAN "die bbox: $die"

  write_db $design(DB_DIR)/post_floorplan.db
}

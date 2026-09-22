# ===========================================================================
#  03 -- Power plan.
#
#  GUI equivalent:  Power -> Connect Global Nets...
#                   Power -> Power Planning -> Add Ring...
#                   Power -> Power Planning -> Add Stripe...
#                   Route -> Special Route...
#  Legacy commands: globalNetConnect / addRing / addStripe / sroute
#
#  Every standard cell needs VDD and VSS before it can be placed, and the
#  supply is built before the signals because it is the one network whose
#  geometry you choose rather than let a router discover. Three pieces:
#
#     ring        around the core, the trunk
#     stripes     down through the core, the branches
#     followpins  the Metal1 rails inside each row, the leaves
#
#  They are built in that order and connected with vias as they go.
# ===========================================================================

redirect -tee $REPORT_DIR/03_powergrid.log {

  log_stage "Power plan"

  # --- 1. tell the tool what is a supply pin ---------------------------
  # Every cell's LEF declares pins named VDD and VSS with USE POWER /
  # USE GROUND. This connects all of them to the two global nets. Without
  # it the cells are placed with floating supplies and the followpin route
  # has nothing to attach to.
  log POWER "Connecting global nets"
  connect_global_net VDD -type pg_pin -pin_base_name VDD -all -verbose
  connect_global_net VSS -type pg_pin -pin_base_name VSS -all -verbose

  # Declare them as the design's own PG pins, so the exported netlist and
  # the LEF abstract of this block have supplies to offer the level above.
  create_pg_pin -name VDD -net VDD
  create_pg_pin -name VSS -net VSS

  # --- 2. the core ring -------------------------------------------------
  # One ring per net, in the channel the floorplan left between core and
  # die. Horizontal segments on a horizontal layer, vertical on a vertical
  # one -- going against a layer's preferred direction is legal and wasteful.
  #
  # Both are thick top metal: the ring carries the whole block's current, so
  # it wants the lowest sheet resistance in the stack.
  log POWER "Adding core ring on $design(pg_ring_h_layer) / $design(pg_ring_v_layer)"
  add_ring -nets {VDD VSS} \
    -type core_rings \
    -follow core \
    -layer [list top    $design(pg_ring_h_layer) \
                 bottom $design(pg_ring_h_layer) \
                 left   $design(pg_ring_v_layer) \
                 right  $design(pg_ring_v_layer)] \
    -width  $design(pg_ring_width) \
    -spacing $design(pg_ring_spacing) \
    -offset  $design(pg_ring_spacing) \
    -center 0

  # --- 3. stripes -------------------------------------------------------
  # The ring alone would leave the middle of the core starved: current
  # would have to travel from the edge along the thin Metal1 rails, and the
  # IR drop in the centre would be the worst in the block. Stripes bring
  # the supply down into the core every pg_stripe_pitch microns.
  #
  # Pitch is the trade-off in one number. Closer stripes mean a stiffer
  # supply and less routing space for signals. On a block this small you
  # could almost skip them; on anything real you cannot.
  set_db add_stripes_stacked_via_top_layer    $design(pg_stripe_layer)
  set_db add_stripes_stacked_via_bottom_layer $design(pg_followpin_layer)
  set_db add_stripes_orthogonal_only true
  set_db add_stripes_skip_via_on_pin {standardcell}
  set_db add_stripes_skip_via_on_wire_shape {noshape}

  log POWER "Adding stripes on $design(pg_stripe_layer), pitch $design(pg_stripe_pitch) um"
  add_stripes -nets {VDD VSS} \
    -layer $design(pg_stripe_layer) \
    -direction vertical \
    -width   $design(pg_stripe_width) \
    -spacing $design(pg_stripe_spacing) \
    -set_to_set_distance $design(pg_stripe_pitch) \
    -start_from left \
    -switch_layer_over_obs false \
    -max_same_layer_jog_length 2 \
    -use_wire_group 0

  # --- 4. followpins ----------------------------------------------------
  # The Metal1 rails that run the length of every standard-cell row, and
  # the vias that tie them up to the stripes and the ring. route_special
  # builds all of it. This is what actually feeds the cells.
  log POWER "Routing followpins and connecting to the grid"
  # -connect takes values from a fixed enum:
  #     {block_pin core_pin pad_pin pad_ring floating_stripe secondary_power_pin}
  # `stripe' is NOT one of them -- that is -core_pin_target's vocabulary, and
  # passing it here gives
  #     **ERROR: (IMPTCM-23): "corePin stripe" is not a valid enum for
  #     "-connect"
  # `help route_special' inside the tool lists both enums; when a power plan
  # command is rejected, read that before guessing.
  #
  # -allow_jogging and -allow_layer_change are documented as <0|1>, not as
  # booleans. Give them 1.
  route_special -connect core_pin \
    -nets {VDD VSS} \
    -core_pin_target first_after_row_end \
    -allow_jogging 1 \
    -allow_layer_change 1 \
    -layer_change_range [list $design(pg_followpin_layer) $design(pg_stripe_layer)]

  # --- 5. did it work? --------------------------------------------------
  # Two different questions, and you want both answered before placement:
  #
  #   check_drc          is the geometry manufacturable?
  #   check_connectivity is every piece of it actually joined up?
  #
  # A power grid can be perfectly legal and still have an island that
  # connects to nothing. That island will feed a row of cells with no
  # supply, and you will find out at signoff.
  deselect_obj -all
  select_routes -shapes {blockring blockwire corewire followpin stripe}
  edit_trim_routes -selected
  deselect_obj -all

  check_drc -check_only special -limit 100000 \
            -out_file $REPORT_DIR/03_powergrid.drc.rpt
  check_connectivity -type special -nets {VDD VSS} \
            -out_file $REPORT_DIR/03_powergrid.connectivity.rpt

  log POWER "Power plan done -- read both reports before continuing"

  write_db $design(DB_DIR)/post_powergrid.db
}

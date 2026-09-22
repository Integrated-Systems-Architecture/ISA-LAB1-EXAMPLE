# ===========================================================================
#  01 -- Import the design.
#
#  GUI equivalent:  File -> Import Design...
#  Legacy commands: loadConfig / setDesignMode / init_design
#
#  Nothing is placed and nothing is routed after this step. What you get is
#  the netlist, the physical abstracts of every cell in it, and the timing
#  setup -- Innovus knowing enough about the design to start making
#  decisions.
# ===========================================================================

set REPORT_DIR $design(REPORT_DIR)

redirect -tee $REPORT_DIR/01_init.log {

  log_stage "Setup libraries and read design"

  check_inputs

  # Name the power and ground nets BEFORE init_design. The tool uses them to
  # work out which pins of each cell are supplies; say it afterwards and
  # every standard cell comes in with unconnected VDD/VSS.
  set_db init_power_nets  $design(all_power_nets)
  set_db init_ground_nets $design(all_ground_nets)

  # 130 nm. Innovus defaults to a much smaller node, and the default decides
  # how it estimates wire resistance and capacitance before there are any
  # wires. Get this wrong and every pre-route timing number is wrong with
  # it. This matters more here than on a modern PDK, because SG13G2 ships
  # no QRC deck -- see the comment in lab1.view.
  set_db design_process_node 130

  # As many cores as you are allowed. Harmless on a block this small;
  # habit-forming for when it is not.
  set_multi_cpu_usage -local_cpu 8

  # --- the three inputs -------------------------------------------------
  # Timing: the MMMC setup of lab1.view.
  log INIT "Reading MMMC views"
  read_mmmc $design(mmmc_view_file)

  # Physical: the technology LEF and the cell abstracts.
  log INIT "Reading physical LEFs"
  read_physical -lefs $design(ALL_LEFS)

  # Logical: the gate-level netlist Design Compiler wrote.
  log INIT "Reading netlist $design(netlist)"
  read_netlist $design(netlist)

  # A chip with power domains reads its UPF here:
  #     read_power_intent -1801 $design(upf_file)
  #     ... then commit_power_intent -verbose after init_design.
  # This block has one always-on domain, so there is nothing to describe.
  # See §5c of the Design Compiler README for what the real thing buys you.

  set_db design_flow_effort standard
  set_db init_design_uniquify true

  init_design

  # --- tidy up the netlist ---------------------------------------------
  # Empty hierarchies and `assign` statements are legal Verilog and a
  # nuisance in a physical database: an assign is a net with no gate driving
  # it, which the router cannot build. Turn each into a buffer.
  delete_empty_hinsts
  delete_assigns -add_buffer

  # --- what the SDC did not say ----------------------------------------
  # Design Compiler worked with an ideal clock. From here on the clock is
  # a real tree with real skew, and the uncertainty has to cover the part
  # of it the tool cannot see yet -- plus jitter.
  #
  # After CTS, cts.tcl drops the setup uncertainty: once the tree exists,
  # its skew is measured instead of guessed, and keeping the guess on top
  # of the measurement is pessimism you pay for in area.
  set_interactive_constraint_modes [all_constraint_modes -active]
  set_clock_uncertainty -setup 0.10 [all_clocks]
  set_clock_uncertainty -hold  0.05 [all_clocks]
  set_interactive_constraint_modes {}

  # --- did it come in clean? -------------------------------------------
  log INIT "Checking the imported design"
  check_design -type all -out_file $REPORT_DIR/01_init.check_design.rpt
  check_timing -verbose            > $REPORT_DIR/01_init.check_timing.rpt

  report_timing -nworst 5 > $REPORT_DIR/01_init.timing_preplace.rpt

  log INIT "Import complete: [llength [get_db insts]] instances"
}

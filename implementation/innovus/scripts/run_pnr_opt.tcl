# ===========================================================================
#  Post-route optimisation and export, in a FRESH Innovus session.
#
#      make pnr-opt            (from lab1/, after `make pnr')
#
#  or by hand, from implementation/innovus/ :
#
#      PNR_POST_ROUTE_OPT=1 innovus -stylus -batch \
#          -files scripts/run_pnr_opt.tcl -log artefacts/pnr_opt
#
#  ---------------------------------------------------------------------
#  WHY THIS IS A SEPARATE RUN
#
#  On Innovus 20.11, both ECO commands -- `opt_design -post_route' and
#  `route_eco -fix_drc' -- fail in the session that has just done the
#  floorplan, power plan, placement, CTS and routing. They fail with an
#  empty error message, after an internal assert
#  (goTimingPreserveUserMode), and `opt_design' does not fail cleanly: it
#  leaves ECO cells in the database that were never routed.
#
#  The same commands, on the same database, in a fresh session, work.
#  Measured on this design at a 10 ns constraint:
#
#                           in the full session   in a fresh session
#      opt_design                      all 3 fail       all 3 succeed
#      route_eco -fix_drc                    fails             runs
#      DRC violations                            7                 0
#      hold slack                       -0.220 ns         -0.002 ns
#
#  So it is leftover session state, not the design and not the commands.
#  Rather than fight it, the flow is split: run_pnr_flow.tcl takes the
#  design to post_route.db and stops; this script picks it up and finishes.
#  Two commands instead of one, and a result you can defend.
#
#  If you ever find what in the first session breaks it, this file should
#  disappear and opt.tcl should go back into run_pnr_flow.tcl.
# ===========================================================================

source scripts/globals.tcl
source scripts/helpers.tcl

make_dirs
set REPORT_DIR $design(REPORT_DIR)

set db $design(DB_DIR)/post_route.db
if {![file isdirectory $db] && ![file exists $db]} {
  error "no $db -- run `make pnr' first"
}

log_stage "Resuming from post_route.db for optimisation and export"
read_db $db

# opt.tcl skips itself unless this is set; here it is the whole point.
set ::env(PNR_POST_ROUTE_OPT) 1

source scripts/opt.tcl
source scripts/export.tcl

log_stage "Post-route optimisation and export complete"

if {[info exists ::env(PNR_KEEP_GUI)]} {
  if {[catch {gui_show; gui_fit} e]} {
    puts "note: could not open the GUI ($e) -- did you log in with `ssh -X'?"
  }
} else {
  exit
}

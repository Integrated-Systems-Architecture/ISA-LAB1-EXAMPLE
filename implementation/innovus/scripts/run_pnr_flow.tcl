# ===========================================================================
#  Place and route of cordic_accel, IHP SG13G2, Cadence Innovus.
#
#  Run from implementation/innovus/ :
#
#      innovus -stylus -files scripts/run_pnr_flow.tcl -log artefacts/innovus
#
#  or, to stop after each stage and look at the layout:
#
#      innovus -stylus
#      source scripts/globals.tcl
#      source scripts/helpers.tcl
#      make_dirs
#      source scripts/init.tcl
#      gui_show
#      source scripts/floorplan.tcl
#      ...
#
#  That second form is the one to use the first time. Read the README next
#  to this file and do the whole flow through the GUI before you run this
#  script -- a script you have never watched run is a script you cannot
#  debug.
#
#  Each stage writes artefacts/db/post_<stage>.db, so you can restart from
#  the middle instead of from the top:
#
#      innovus -stylus
#      source scripts/globals.tcl ; source scripts/helpers.tcl
#      read_db artefacts/db/post_place.db
#      source scripts/cts.tcl
# ===========================================================================

source scripts/globals.tcl
source scripts/helpers.tcl

make_dirs
set REPORT_DIR $design(REPORT_DIR)

set t_start [clock seconds]

#########################
##  Initialize Design  ##
#########################
source scripts/init.tcl

#################
##  Floorplan  ##
#################
source scripts/floorplan.tcl

#################
##  Powergrid  ##
#################
source scripts/powergrid.tcl

#################
##  Placement  ##
#################
source scripts/place.tcl

############################
##  Clock-Tree Synthesis  ##
############################
source scripts/cts.tcl

#############
##  Route  ##
#############
source scripts/route.tcl

#######################
##  Optimize design  ##
#######################
source scripts/opt.tcl

#######################
##      Export       ##
#######################
source scripts/export.tcl

log_stage "Flow finished in [expr {[clock seconds] - $t_start}] s"

# `make pnr-gui` sets PNR_KEEP_GUI so the tool stays open with the finished
# layout on screen instead of exiting. Batch runs exit.
#
# Needs X11: log in with `ssh -X` (and XQuartz running, on a Mac). Verified
# working on isaserver -- `gui_show` succeeds with DISPLAY forwarded.
if {[info exists ::env(PNR_KEEP_GUI)]} {
  if {[catch {gui_show; gui_fit} e]} {
    puts "note: could not open the GUI ($e) -- did you log in with `ssh -X'?"
  }
} else {
  exit
}

# ===========================================================================
#  helpers.tcl -- the two logging procs every step script calls.
#
#  Innovus prints a lot. These make it possible to find where one stage
#  ended and the next began, in a log that is tens of thousands of lines
#  long. That is all they do; they are here because the SoC flow has them
#  and the step scripts read the same.
# ===========================================================================

proc log_stage {msg} {
  puts ""
  puts "############################################################################"
  puts "##  $msg"
  puts "##  [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}]"
  puts "############################################################################"
  puts ""
}

proc log {tag msg} {
  puts "-- \[$tag\] $msg"
}

# Make the output directories. Innovus will not create them, and a report
# redirected into a directory that does not exist is a stage that dies at
# the end, after all the work.
proc make_dirs {} {
  global design
  foreach d [list $design(REPORT_DIR) $design(DB_DIR) \
                  $design(EXPORT_DIR) $design(METRIC_DIR)] {
    file mkdir $d
  }
}

# Fail early and say which file, rather than letting init_design produce
# fifty lines of unresolved references.
proc check_inputs {} {
  global design
  foreach f [list $design(netlist) $design(default_sdc)] {
    if {![file exists $f]} {
      error "missing $f -- run `make synth` in lab1/ first"
    }
  }
  foreach f $design(ALL_LEFS) {
    if {![file exists $f]} { error "missing LEF $f -- check IHP_PDK_ROOT" }
  }
  foreach f [list $design(lib_slow) $design(lib_typ) $design(lib_fast)] {
    if {![file exists $f]} { error "missing Liberty $f -- check IHP_PDK_ROOT" }
  }
}

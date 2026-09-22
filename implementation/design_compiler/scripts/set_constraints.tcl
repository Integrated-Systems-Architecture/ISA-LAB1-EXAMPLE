# Timing and load constraints for cordic_accel, IHP SG13G2.
#
# Override the clock period from the shell before sourcing this file, or from
# the Makefile:   make synth CLK_PERIOD=3.0
# The point of the exercise is to sweep it: push the period down until the
# slack goes negative, and you have found the maximum frequency of your
# design as synthesized.

# The Makefile passes the period through the environment, so honour that
# before falling back to the default.
if {![info exists CLK_PERIOD]} {
  if {[info exists ::env(CLK_PERIOD)]} {
    set CLK_PERIOD [string trim $::env(CLK_PERIOD)]
  } else {
    # 130 nm at the slow corner: 10 ns (100 MHz) is the shipped default.
    # It is deliberately not aggressive -- with margin, CTS and the hold
    # fixing after it have room to work, and the flow closes. Sweep down
    # from here to find the maximum frequency; that is the exercise.
    set CLK_PERIOD 10.0
  }
}
if {![info exists CLK_PORT]} { set CLK_PORT clk_i }

puts "constraints: clock ${CLK_PORT}, period ${CLK_PERIOD} ns"

# A symbolic clock bound to the real clock pin of the design.
create_clock -name MY_CLK -period ${CLK_PERIOD} [get_ports ${CLK_PORT}]

# The clock is a special net: no buffering games, no optimisation.
set_dont_touch_network MY_CLK

# Real clocks jitter. With no better information, a small fraction of the
# period is the usual guess.
set_clock_uncertainty 0.07 [get_clocks MY_CLK]

# What the world outside promises us. Inputs are assumed to arrive at most
# 0.5 ns after the clock edge, outputs must be stable 0.5 ns before the next
# one. Both have to stay well below the clock period or the constraint is
# unsatisfiable no matter what the logic does.
set_input_delay  0.5 -max -clock MY_CLK [remove_from_collection [all_inputs] [get_ports ${CLK_PORT}]]
set_output_delay 0.5 -max -clock MY_CLK [all_outputs]

# What our outputs drive. Assume one buffer's input capacitance;
# sg13g2_buf_4 is a medium-strength buffer of this library, A is its input
# pin (X is the output). The library name carries the corner, so it follows
# whatever STDCELL_LIB the synthesis script selected.
if {![info exists STDCELL_LIB]} { set STDCELL_LIB sg13g2_stdcell_slow_1p08V_125C }
set OLOAD [load_of ${STDCELL_LIB}/sg13g2_buf_4/A]
set_load $OLOAD [all_outputs]

# The reset is asynchronous: it is not a timed path, and leaving it timed
# only produces violations that mean nothing.
if {[sizeof_collection [get_ports rst_ni -quiet]] > 0} {
  set_false_path -from [get_ports rst_ni]
}

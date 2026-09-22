// ===========================================================================
//  tc_clk_gating_sg13g2.sv -- the technology implementation of tc_clk_gating.
//
//  Same module name, same ports as the behavioural model in
//  tech_cells_generic (src/rtl/tc_clk.sv), different insides. The design
//  instantiates `tc_clk_gating` and never knows which one it got:
//
//    simulation  -> vendor/pulp_platform/tech_cells_generic/src/rtl/tc_clk.sv
//                   an always_latch plus an AND, readable and portable
//    synthesis   -> this file, sg13g2_lgcp_1, the library's integrated
//                   clock gating cell
//
//  The choice is made in cordic_accel.core: the `tech-generic` fileset for
//  the simulation targets, `tech-sg13g2` for the synthesis one. That is the
//  same swap X-HEEP does for its SRAM wrapper, and the same one you will
//  need if you add a memory to your accelerator -- see the README.
//
//  Why bother: a latch written in RTL is not a clock gate. Handed the
//  behavioural model, the synthesizer builds a latch out of standard cells
//  and ANDs the clock with its output, which produces glitches on the clock
//  net and no timing model worth having. An integrated clock gating cell is
//  one characterised cell, glitch-free by construction, and the timing tools
//  know what to do with it. Swapping it is not a formality.
// ===========================================================================

module tc_clk_gating #(
    /// Hint for technology mapping: 1 = the gate is needed for correctness,
    /// 0 = it is there to save power and may be replaced by a wire.
    parameter bit IS_FUNCTIONAL = 1'b1
) (
    input  logic clk_i,
    input  logic en_i,
    input  logic test_en_i,
    output logic clk_o
);

  // sg13g2_slgcp_1: the library's integrated clock gate WITH a scan enable.
  //   CLK   clock in
  //   GATE  functional enable, sampled while the clock is low
  //   SCE   scan/test enable: forces the gate open so scan can shift
  //   GCLK  gated clock out
  //
  // SG13G2 ships two of these and the difference matters:
  //
  //   sg13g2_lgcp_1    CLK, GATE, GCLK              no test pin
  //   sg13g2_slgcp_1   CLK, GATE, SCE, GCLK         SCE is declared in the
  //                                                 Liberty as
  //                                                 clock_gate_test_pin
  //
  // You could use the plain one and OR the test enable into GATE -- and it
  // would simulate correctly. It would also be wrong in a way that only
  // shows up much later: the DFT and timing tools recognise a clock gate by
  // those Liberty attributes, and with the OR outside the cell there is no
  // test pin to recognise. The scan inserter cannot prove the gate opens in
  // test mode, so it cannot prove the flops behind it are controllable.
  //
  // Design Compiler agrees. Look at a synthesised netlist: every gate the
  // tool inserts for you with `-gate_clock` is an sg13g2_slgcp_1, wrapped
  // in a module called SNPS_CLOCK_GATE_HIGH_*. This instance is the one
  // gate the DESIGN asked for, so it should look the same to the tools as
  // the ones the tool added itself.
  sg13g2_slgcp_1 i_icg (
      .CLK (clk_i),
      .GATE(en_i),
      .SCE (test_en_i),
      .GCLK(clk_o)
  );

endmodule

// ===========================================================================
//  sram_wrapper_generic.sv -- the SIMULATION implementation of sram_wrapper.
//
//  Exactly the same trick as the clock gate one directory over: one module
//  name, two implementations, the build picks one.
//
//    simulation  -> this file, tc_sram from tech_cells_generic: an array in
//                   SystemVerilog, readable, portable, initialisable
//    synthesis   -> ../sg13g2/sram_wrapper_sg13g2.sv, a real SRAM macro out
//                   of the PDK
//
//  The choice is made in cordic_accel.core, by the `tech-generic` and
//  `tech-sg13g2` filesets, and every target picks exactly one.
//
//  Why bother, when tc_sram elaborates perfectly well? Because a synthesis
//  tool handed tc_sram does not refuse it -- it builds you the array out of
//  flip-flops. A 1024x32 memory is 32 kbit of flops plus the address
//  decoding: tens of times the area of the macro, a fraction of its speed,
//  and a power number that means nothing. The failure is silent. That is
//  what makes it worth a file.
//
//  The port list below is the contract both implementations honour. Keep it
//  narrow: single port, one-cycle read latency, byte enables. Everything a
//  simple accelerator scratchpad needs, and nothing that the technology
//  macro cannot do.
// ===========================================================================

module sram_wrapper #(
    /// Number of words in the memory.
    parameter int unsigned NumWords  = 32'd1024,
    /// Width of one word, in bits. A multiple of 8 -- byte enables assume it.
    parameter int unsigned DataWidth = 32'd32,
    // DEPENDENT PARAMETERS, DO NOT OVERRIDE.
    parameter int unsigned AddrWidth = (NumWords > 32'd1) ? $clog2(NumWords) : 32'd1,
    parameter int unsigned BeWidth   = DataWidth / 32'd8
) (
    input  logic                 clk_i,
    input  logic                 rst_ni,
    /// Request. One access per asserted cycle.
    input  logic                 req_i,
    /// Write enable. Read when low.
    input  logic                 we_i,
    input  logic [AddrWidth-1:0] addr_i,
    input  logic [DataWidth-1:0] wdata_i,
    /// Byte enable, one bit per byte of wdata_i. Write only.
    input  logic [  BeWidth-1:0] be_i,
    /// Read data, valid one cycle after a request with we_i low.
    output logic [DataWidth-1:0] rdata_o
);

  // Latency 1 and NumPorts 1 are not free choices: they are what the SG13G2
  // macro does, and the two implementations have to behave identically or
  // the gate-level simulation stops matching the RTL one.
  tc_sram #(
      .NumWords   (NumWords),
      .DataWidth  (DataWidth),
      .ByteWidth  (32'd8),
      .NumPorts   (32'd1),
      .Latency    (32'd1),
      // "zeros" so that a read of a location the testbench never wrote
      // returns 0 instead of X. The macro powers up undefined; if your
      // design depends on the difference, it has a bug.
      .SimInit    ("zeros"),
      .PrintSimCfg(1'b0)
  ) i_sram (
      .clk_i,
      .rst_ni,
      .req_i  (req_i),
      .we_i   (we_i),
      .addr_i (addr_i),
      .wdata_i(wdata_i),
      .be_i   (be_i),
      .rdata_o(rdata_o)
  );

endmodule

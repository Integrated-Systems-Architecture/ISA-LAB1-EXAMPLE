// ===========================================================================
//  sram_wrapper_sg13g2.sv -- the SYNTHESIS implementation of sram_wrapper.
//
//  Same module name and same ports as ../generic/sram_wrapper_generic.sv,
//  a real IHP SG13G2 SRAM macro inside. The design instantiates
//  `sram_wrapper` and never knows which one it got; cordic_accel.core
//  decides, per target.
//
//  ---------------------------------------------------------------------
//  BEFORE YOU USE THIS FILE, CHECK IT AGAINST YOUR PDK.
//
//  The macro name below encodes a size. Yours is almost certainly a
//  different one. List what the PDK actually ships:
//
//      ls $IHP_PDK_ROOT/libs.ref/sg13g2_sram/verilog/
//      ls $IHP_PDK_ROOT/libs.ref/sg13g2_sram/lib/
//
//  and read the behavioural model of the one you pick -- it is the
//  authority on the port names, not this comment:
//
//      less $IHP_PDK_ROOT/libs.ref/sg13g2_sram/verilog/RM_IHPSG13_1P_<...>.v
//
//  The families are RM_IHPSG13_1P_<words>x<bits>_... (single port, 64x16 up
//  to 8192x32) and RM_IHPSG13_2P_<words>x<bits>_... (dual port). Most carry
//  a bit mask (`bm`) and BIST (`bist`) in the suffix. Pick the smallest one
//  that holds your data: an SRAM you half use is area you paid for.
//  ---------------------------------------------------------------------
//
//  Three more things have to line up, and none of them are in this file:
//
//    1. Design Compiler needs the macro's timing. Compile its Liberty the
//       same way the standard cells are compiled and append the .db to
//       link_library -- the MACRO_DBS list in scripts/dc_script.tcl is
//       there for that. NOT to target_library: the synthesizer must use the
//       memory you instantiated, never invent another one.
//    2. Innovus needs the macro's LEF (size, pins, blockages) and you have
//       to place it by hand in the floorplan -- see
//       implementation/innovus/scripts/02_floorplan.tcl.
//    3. The corners have to match. Standard cells at slow, macro at slow.
//       A typical memory under slow logic produces a timing report that is
//       fiction.
//
//  And the rule that outranks all three: simulate the configuration you
//  synthesise. Same word count, same width, same read latency.
// ===========================================================================

module sram_wrapper #(
    parameter int unsigned NumWords  = 32'd1024,
    parameter int unsigned DataWidth = 32'd32,
    // DEPENDENT PARAMETERS, DO NOT OVERRIDE.
    parameter int unsigned AddrWidth = (NumWords > 32'd1) ? $clog2(NumWords) : 32'd1,
    parameter int unsigned BeWidth   = DataWidth / 32'd8
) (
    input  logic                 clk_i,
    input  logic                 rst_ni,
    input  logic                 req_i,
    input  logic                 we_i,
    input  logic [AddrWidth-1:0] addr_i,
    input  logic [DataWidth-1:0] wdata_i,
    input  logic [  BeWidth-1:0] be_i,
    output logic [DataWidth-1:0] rdata_o
);

  // The macro is a fixed-size block of silicon. Parameters cannot resize it,
  // so the instantiation below is only correct for one configuration -- fail
  // loudly on any other rather than synthesise something that is not what
  // the RTL asked for.
  if (NumWords != 32'd1024 || DataWidth != 32'd32) begin : gen_no_macro
    $fatal(1, "sram_wrapper_sg13g2: no macro for %0dx%0d. Pick one from %s and instantiate it here.",
           NumWords, DataWidth, "$IHP_PDK_ROOT/libs.ref/sg13g2_sram/");
  end

  // The macro has no reset: an SRAM array powers up undefined and there is
  // no signal that changes that. Consume rst_ni so the port list stays
  // identical to the generic wrapper and lint stays quiet.
  logic unused_rst;
  assign unused_rst = rst_ni;

  // Byte enables -> bit mask. The macro masks per bit; we expose per byte,
  // because that is what a 32 bit bus gives you.
  logic [DataWidth-1:0] bit_mask;
  always_comb begin
    for (int unsigned b = 0; b < BeWidth; b++) bit_mask[b*8+:8] = {8{be_i[b]}};
  end

  // RM_IHPSG13_1P_1024x32_c2_bm_bist
  //   A_CLK       clock
  //   A_MEN       memory enable -- the request
  //   A_WEN       write enable  (with A_MEN)
  //   A_REN       read enable   (with A_MEN)
  //   A_ADDR      address
  //   A_DIN/A_DOUT  write / read data, A_DOUT valid one cycle after A_MEN
  //   A_BM        bit mask, 1 = write this bit
  //   A_DLY       internal timing trim. The PDK's own model refuses to run
  //               unless it is tied to 1'b1 -- it prints
  //               "ERROR: A_DLY must be tied to 1'b1" and stops. Tie it high.
  //   A_BIST_*    the built-in self test port. Tied off: no BIST controller
  //               in this design. A real chip has one, and then these go to
  //               it instead of to ground.
  RM_IHPSG13_1P_1024x32_c2_bm_bist i_sram (
      .A_CLK      (clk_i),
      .A_MEN      (req_i),
      .A_WEN      (we_i),
      .A_REN      (~we_i),
      .A_ADDR     (addr_i),
      .A_DIN      (wdata_i),
      .A_DOUT     (rdata_o),
      .A_BM       (bit_mask),
      .A_DLY      (1'b1),
      .A_BIST_CLK (1'b0),
      .A_BIST_EN  (1'b0),
      .A_BIST_MEN (1'b0),
      .A_BIST_WEN (1'b0),
      .A_BIST_REN (1'b0),
      .A_BIST_ADDR({AddrWidth{1'b0}}),
      .A_BIST_DIN ({DataWidth{1'b0}}),
      .A_BIST_BM  ({DataWidth{1'b0}})
  );

endmodule

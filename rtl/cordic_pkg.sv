// ===========================================================================
//  cordic_pkg.sv -- shared declarations for the CORDIC rotator.
//
//  This package is the SystemVerilog counterpart of cordic_pkg.vhd.  It is
//  worth reading the two side by side: they contain exactly the same
//  information, but SystemVerilog lets the design *and* the testbench import
//  it with a single `import cordic_pkg::*;`, while VHDL needs the design unit
//  to name the library and the package separately.
//
//  Number formats
//  --------------
//    x, y     signed, DW bits, QF fractional bits   (Q1.14 -> [-2, 2) )
//    theta    signed, AW bits, QA fractional bits   (Q2.13 -> [-4, 4) )
//
//  Internally the datapath is widened by GL bits at the bottom (precision)
//  and GM bits at the top (headroom for the CORDIC processing gain).
// ===========================================================================
// verilator lint_off UNUSEDPARAM
// (several constants below are consumed only by testbenches)
package cordic_pkg;

  timeunit      1ns;
  timeprecision 1ps;

  // -----------------------------------------------------------------------
  // Format parameters.  `parameter' at package scope behaves like VHDL's
  // deferred constant: it can be overridden only by a tool switch, not by
  // an instance, so treat it as a constant.
  // -----------------------------------------------------------------------
  parameter int unsigned DW = 16;   // external x/y width
  parameter int unsigned QF = 14;   // external x/y fractional bits
  parameter int unsigned AW = 16;   // external angle width
  parameter int unsigned QA = 13;   // external angle fractional bits
  parameter int unsigned N  = 14;   // number of micro-rotations
  parameter int unsigned GL = 2;    // guard bits at the LSB side
  parameter int unsigned GM = 2;    // guard bits at the MSB side

  localparam int unsigned IW  = DW + GL + GM;   // internal x/y width      (20)
  localparam int unsigned IQF = QF + GL;        // internal x/y frac. bits (16)
  localparam int unsigned IA  = AW + GL;        // internal angle width    (18)
  localparam int unsigned IQA = QA + GL;        // internal angle frac.    (15)

  // -----------------------------------------------------------------------
  // Types.  A `typedef' here plays the role of a VHDL subtype declared in a
  // package -- but note that SystemVerilog types carry no range checking:
  // `data_t' is simply "20 bits, interpreted as two's complement".
  // -----------------------------------------------------------------------
  typedef logic signed [DW-1:0] data_t;    // external x/y
  typedef logic signed [AW-1:0] angle_t;   // external angle
  typedef logic signed [IW-1:0] idata_t;   // internal x/y
  typedef logic signed [IA-1:0] iangle_t;  // internal angle

  // A packed struct is a *bit vector with named fields*.  It can cross a
  // module port, be assigned as a whole, and be cast to and from a plain
  // vector -- VHDL records cannot be treated as vectors at all.
  typedef struct packed {
    data_t  x;
    data_t  y;
    angle_t theta;
  } cordic_req_t;

  typedef struct packed {
    data_t x;
    data_t y;
  } cordic_rsp_t;

  // -----------------------------------------------------------------------
  // Elaboration-time constants.
  //
  // `$atan' and friends are real-valued system functions.  Calling them in a
  // constant expression is the SystemVerilog equivalent of using
  // ieee.math_real in a VHDL constant: the value is computed once, by the
  // tool, and never appears in the netlist.
  // -----------------------------------------------------------------------
  localparam int signed MAX_DATA =  (1 << (DW - 1)) - 1;   //  32767
  localparam int signed MIN_DATA = -(1 << (DW - 1));       // -32768

  // pi/2 and pi in the internal angle format
  localparam int signed HALF_PI_INT = 51472;   // round(pi/2 * 2**IQA)
  localparam int signed PI_INT      = 102944;  // round(pi   * 2**IQA)
  // pi in the *external* angle format, used by the input range check
  localparam int signed PI_EXT      = 25736;   // round(pi   * 2**QA)

  // The processing gain K = prod sqrt(1 + 2**-2i) and its reciprocal, in the
  // external x/y format.  Seed the rotator with X0_UNIT to obtain
  // (cos theta, sin theta) directly on the output.
  localparam int signed X0_UNIT = 9949;        // round(2**QF / 1.646760)

  // -----------------------------------------------------------------------
  // The arctangent ROM: atan(2^-i) for i in 0..N-1, in the internal angle
  // format (Q3.15 signed, 18 bits).
  //
  // Written out as literals, not computed.
  //
  // The natural way to write this in SystemVerilog is a constant function
  // that loops and calls $atan, the way VHDL initialises a constant array
  // from a function. It reads better and it is what this file used to do.
  // It is also not portable: QuestaSim 2020.4 refuses a constant function
  // containing real-valued system functions --
  //
  //     ** Error: (vlog-2118) The function 'build_atan_rom' is not a valid
  //     constant function.
  //
  // -- and Design Compiler 2021.06 does not implement $rtoi at all
  // (VER-956). Between them, every tool in this lab's flow rejects some
  // version of the elaborate-time form, and when the package fails to
  // analyze, every file that imports it fails with it.
  //
  // A table of integers is accepted by everything, and for a ROM that is
  // arguably what it always was: these numbers are part of the design's
  // specification, not a computation the tool should be repeating.
  //
  // They are generated by, and bit-identical to, model/cordic_golden.py:
  //
  //     python3 -c 'import math
  //     N, IQA = 14, 15
  //     print([round(math.atan(2.0**-i) * (1 << IQA)) for i in range(N)])'
  //
  // `make bitexact' is what keeps them honest: it compares this RTL against
  // the Python model and against the Example Cookbook's CORDIC, so if these
  // constants ever drift from the model the check fails.
  // -----------------------------------------------------------------------
  typedef iangle_t atan_rom_t [N];

  localparam atan_rom_t ATAN_ROM = '{
    18'sd25736 ,  // i=0   atan(2^-0) = 0.785398163 rad
    18'sd15193 ,  // i=1   atan(2^-1) = 0.463647609 rad
    18'sd8027  ,  // i=2   atan(2^-2) = 0.244978663 rad
    18'sd4075  ,  // i=3   atan(2^-3) = 0.124354995 rad
    18'sd2045  ,  // i=4   atan(2^-4) = 0.062418810 rad
    18'sd1024  ,  // i=5   atan(2^-5) = 0.031239833 rad
    18'sd512   ,  // i=6   atan(2^-6) = 0.015623729 rad
    18'sd256   ,  // i=7   atan(2^-7) = 0.007812341 rad
    18'sd128   ,  // i=8   atan(2^-8) = 0.003906230 rad
    18'sd64    ,  // i=9   atan(2^-9) = 0.001953123 rad
    18'sd32    ,  // i=10  atan(2^-10) = 0.000976562 rad
    18'sd16    ,  // i=11  atan(2^-11) = 0.000488281 rad
    18'sd8     ,  // i=12  atan(2^-12) = 0.000244141 rad
    18'sd4        // i=13  atan(2^-13) = 0.000122070 rad
  };

  // -----------------------------------------------------------------------
  // Narrow the internal datapath back to the external format, with
  // saturation.  Truncation of the GL guard bits is an arithmetic shift
  // right, which rounds towards minus infinity -- the golden model in
  // Python does exactly the same, so the two agree bit for bit.
  // -----------------------------------------------------------------------
  // The GL guard bits of `v' are dropped on purpose.
  // verilator lint_off UNUSEDSIGNAL
  function automatic data_t sat_narrow(input idata_t v);
    logic signed [IW-GL-1:0] t;   // DW + GM bits
    // The low IW-GL bits of an arithmetic shift right by GL are exactly the
    // part-select v[IW-1:GL]; writing it this way keeps the widths explicit.
    t = v[IW-1:GL];
    if      (int'(t) > MAX_DATA) sat_narrow = data_t'(MAX_DATA);
    else if (int'(t) < MIN_DATA) sat_narrow = data_t'(MIN_DATA);
    else                         sat_narrow = data_t'(t);
  endfunction
  // verilator lint_on UNUSEDSIGNAL

  // Convenience for testbenches: fixed point <-> real.
  function automatic real q_to_real(input int signed v, input int unsigned f);
    return real'(v) / (2.0 ** f);
  endfunction

  function automatic int signed real_to_q(input real v, input int unsigned f);
    // A real-to-integral cast rounds to nearest, ties away from zero
    // (IEEE 1800 6.12.2) -- which is what the `+/- 0.5 then truncate' this
    // used to spell out was doing. Not written with $rtoi, because Design
    // Compiler 2021.06 does not implement it (VER-956) and would fail the
    // whole package, and with it every file that imports cordic_pkg.
    //
    // This one is fine to leave as a function: it is called from testbench
    // code at run time, not in a constant expression, which is the case the
    // tools disagree about. See the ATAN_ROM comment above.
    return integer'(v * (2.0 ** f));
  endfunction

endpackage : cordic_pkg
// verilator lint_on UNUSEDPARAM

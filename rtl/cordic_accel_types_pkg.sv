// ===========================================================================
//  cordic_accel_types_pkg.sv -- the default bus types of the accelerator.
//
//  A macro cannot be expanded in a parameter default, so the structs live in
//  a package. That gives cordic_accel real default types instead of `logic`,
//  which means the module can be elaborated, linted and synthesised on its
//  own -- not only from a testbench that happens to pass the right types in.
//
//  An integrator (Lab 3, inside X-HEEP) overrides them with the SoC's own
//  struct types; the defaults here are the standalone configuration.
//
//  The OBI structs are written out rather than pulled from
//  `OBI_TYPEDEF_DEFAULT_ALL: X-HEEP already owns the package name `obi_pkg`
//  and puts a different, flatter OBI in it. Two packages with one name do
//  not merge, they collide, so the IP carries its own copy of the handful of
//  structs it needs and depends on no OBI package at all.
// ===========================================================================

`include "register_interface/typedef.svh"

package cordic_accel_types_pkg;

  // 32 bit address, 32 bit data, 1 bit id, no optional signals -- the
  // expansion of obi_pkg::ObiDefaultConfig.
  localparam int unsigned AddrWidth = 32;
  localparam int unsigned DataWidth = 32;
  localparam int unsigned IdWidth   = 1;

  // --- OBI: `OBI_TYPEDEF_DEFAULT_ALL(cordic_obi, ObiDefaultConfig) --------
  typedef logic cordic_obi_a_optional_t;

  typedef struct packed {
    logic [  AddrWidth-1:0] addr;
    logic                   we;
    logic [DataWidth/8-1:0] be;
    logic [  DataWidth-1:0] wdata;
    logic [    IdWidth-1:0] aid;
    cordic_obi_a_optional_t a_optional;
  } cordic_obi_a_chan_t;

  typedef struct packed {
    cordic_obi_a_chan_t a;
    logic               req;
  } cordic_obi_req_t;

  typedef logic cordic_obi_r_optional_t;

  typedef struct packed {
    logic [DataWidth-1:0]   rdata;
    logic [  IdWidth-1:0]   rid;
    logic                   err;
    cordic_obi_r_optional_t r_optional;
  } cordic_obi_r_chan_t;

  typedef struct packed {
    cordic_obi_r_chan_t r;
    logic               gnt;
    logic               rvalid;
  } cordic_obi_rsp_t;

  // --- Register interface -------------------------------------------------
  typedef logic [31:0] reg_addr_t;
  typedef logic [31:0] reg_data_t;
  typedef logic [ 3:0] reg_strb_t;

  `REG_BUS_TYPEDEF_ALL(cordic_reg, reg_addr_t, reg_data_t, reg_strb_t)

endpackage : cordic_accel_types_pkg

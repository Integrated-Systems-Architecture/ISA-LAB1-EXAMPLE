// ===========================================================================
//  tb_cordic_accel.sv -- self-checking testbench for the CORDIC accelerator.
//
//  One testbench, two simulators: plain SystemVerilog, no DPI, no C++ shim,
//  so `make sim` (Verilator) and `make questa` (QuestaSim) compile exactly
//  these sources and must agree.
//
//  The verification components come from the IPs themselves, not from
//  hand-written BFMs:
//
//    reg_test::reg_driver         drives the configuration interface
//                                 (register_interface)
//    obi_test::obi_rand_manager   drives the data bus as a second manager,
//                                 to preload the angles and read the results
//    obi_sim_mem                  the memory both managers talk to
//    obi_mux                      arbitrates the accelerator and the
//                                 testbench manager onto that one memory
//
//  That last piece is not just convenience: it is the situation the
//  accelerator will actually be in inside X-HEEP, sharing memory with a CPU.
//
//  Flow, twice:
//    1. the testbench manager writes the angles into memory at SRC
//    2. the reg driver programs N / SRC / DST / seeds and writes CTRL.START
//    3. it polls STATUS until DONE
//    4. the manager reads DST back and compares against the golden vectors
//
//  The second run uses the seed vector turned by 90 degrees and a different
//  destination: it puts real data in the y accumulator (the first run starts
//  from y = 0) and it proves the accelerator restarts cleanly, which is the
//  bug a single-run testbench always misses.
//
//  The comparison is bit-exact against model/cordic_golden.py -- integers,
//  not tolerances. Any difference is a bug, and the testbench prints the
//  first few before failing.
// ===========================================================================

`include "obi/typedef.svh"
`include "obi/assign.svh"
`include "register_interface/typedef.svh"
`include "register_interface/assign.svh"

module tb_cordic_accel;

  import obi_pkg::*;
  import cordic_pkg::*;

  // --------------------------------------------------------------------
  // Testbench parameters
  // --------------------------------------------------------------------
  // Clock period, in picoseconds, as a parameter so the gate-level runs can
  // be done at the frequency the design was synthesised for:
  //     vsim -g/tb_cordic_accel/ClkPeriodPs=5000 ...
  // Power scales with frequency, so measuring at 100 MHz a block that was
  // constrained at 200 MHz gives you half the dynamic power and no useful
  // answer.
  parameter  int unsigned ClkPeriodPs = 10000;
  localparam time ClkPeriod = ClkPeriodPs * 1ps;
  // Both are fractions of the period, not absolute times. They used to be
  // 2 ns and 8 ns, which is 20 % and 80 % of the 10 ns this testbench was
  // written for -- and silently wrong at any other period. Run the
  // gate-level flow at the 5 ns the design is synthesised for and an 8 ns
  // acquisition point lands PAST the next clock edge: the driver samples
  // the wrong cycle, the CSR reads come back stale, and the run dies with
  // `timeout waiting for STATUS.DONE' that looks like an RTL bug.
  localparam time ApplDelay = ClkPeriod / 5;      // stimulus 20 % after the edge
  localparam time AcqDelay  = (ClkPeriod * 4) / 5; // sampled 80 % in, before the next

  localparam int unsigned MaxElems = 4096;  // testbench array sizes

  localparam logic [31:0] SrcBase = 32'h0000_1000;   // where the angles live
  localparam logic [31:0] DstBase  = 32'h0000_2000;  // where run 1 writes
  localparam logic [31:0] DstBase2 = 32'h0000_3000;  // where run 2 writes

  // Register map, from data/cordic_accel.hjson (reggen assigns in order).
  localparam logic [31:0] REG_CTRL   = 32'h00;
  localparam logic [31:0] REG_STATUS = 32'h04;
  localparam logic [31:0] REG_N      = 32'h08;
  localparam logic [31:0] REG_SRC    = 32'h0C;
  localparam logic [31:0] REG_DST    = 32'h10;
  localparam logic [31:0] REG_SEEDX  = 32'h14;
  localparam logic [31:0] REG_SEEDY  = 32'h18;

  // --------------------------------------------------------------------
  // Bus types
  //
  // The accelerator and the testbench manager share one memory through an
  // obi_mux, and the mux widens the id field by one bit to remember which
  // port a response belongs to -- hence two configurations and two sets of
  // structs.
  // --------------------------------------------------------------------
  localparam obi_cfg_t ObiCfg    = ObiDefaultConfig;          // 32 bit, IdWidth 1
  localparam obi_cfg_t MemObiCfg = mux_grow_cfg(ObiCfg, 2);   // IdWidth 2

  `OBI_TYPEDEF_DEFAULT_ALL(obi, ObiCfg)
  `OBI_TYPEDEF_DEFAULT_ALL(mem_obi, MemObiCfg)

  typedef logic [31:0] reg_addr_t;
  typedef logic [31:0] reg_data_t;
  typedef logic [ 3:0] reg_strb_t;
  `REG_BUS_TYPEDEF_ALL(reg_bus, reg_addr_t, reg_data_t, reg_strb_t)

  // --------------------------------------------------------------------
  // Clock and reset
  // --------------------------------------------------------------------
  logic clk, rst_n;

  initial begin
    clk = 1'b0;
    forever #(ClkPeriod / 2) clk = ~clk;
  end

  initial begin
    rst_n = 1'b0;
    repeat (5) @(negedge clk);
    rst_n = 1'b1;
  end

  // --------------------------------------------------------------------
  // Configuration interface: REG_BUS driven by reg_test::reg_driver
  // --------------------------------------------------------------------
  REG_BUS #(.ADDR_WIDTH(32), .DATA_WIDTH(32)) reg_bus (clk);

  reg_bus_req_t reg_req;
  reg_bus_rsp_t reg_rsp;

  `REG_BUS_ASSIGN_TO_REQ(reg_req, reg_bus)
  `REG_BUS_ASSIGN_FROM_RSP(reg_bus, reg_rsp)

  typedef reg_test::reg_driver #(
    .AW ( 32        ),
    .DW ( 32        ),
    .TA ( ApplDelay ),
    .TT ( AcqDelay  )
  ) reg_driver_t;

  // --------------------------------------------------------------------
  // Data interface: the accelerator (manager 0) and the testbench manager
  // (manager 1) onto one obi_sim_mem.
  // --------------------------------------------------------------------
  obi_req_t dut_obi_req, tb_obi_req;
  obi_rsp_t dut_obi_rsp, tb_obi_rsp;

  OBI_BUS_DV #(
    .OBI_CFG          ( ObiCfg           ),
    .obi_a_optional_t ( obi_a_optional_t ),
    .obi_r_optional_t ( obi_r_optional_t )
  ) tb_obi (clk, rst_n);

  `OBI_ASSIGN_TO_REQ(tb_obi_req, tb_obi, ObiCfg)
  `OBI_ASSIGN_FROM_RSP(tb_obi, tb_obi_rsp, ObiCfg)

  typedef obi_test::obi_rand_manager #(
    .ObiCfg           ( ObiCfg           ),
    .obi_a_optional_t ( obi_a_optional_t ),
    .obi_r_optional_t ( obi_r_optional_t ),
    .TA               ( ApplDelay        ),
    .TT               ( AcqDelay         )
  ) obi_manager_t;

  mem_obi_req_t mem_req;
  mem_obi_rsp_t mem_rsp;

  obi_mux #(
    .SbrPortObiCfg      ( ObiCfg        ),
    .MgrPortObiCfg      ( MemObiCfg     ),
    .sbr_port_obi_req_t ( obi_req_t     ),
    .sbr_port_a_chan_t  ( obi_a_chan_t  ),
    .sbr_port_obi_rsp_t ( obi_rsp_t     ),
    .sbr_port_r_chan_t  ( obi_r_chan_t  ),
    .mgr_port_obi_req_t ( mem_obi_req_t ),
    .mgr_port_obi_rsp_t ( mem_obi_rsp_t ),
    .NumSbrPorts        ( 2             ),
    .NumMaxTrans        ( 8             ),
    .UseIdForRouting    ( 1'b0          )
  ) i_obi_mux (
    .clk_i           ( clk                       ),
    .rst_ni          ( rst_n                     ),
    .testmode_i      ( 1'b0                      ),
    .sbr_ports_req_i ( {tb_obi_req, dut_obi_req} ),
    .sbr_ports_rsp_o ( {tb_obi_rsp, dut_obi_rsp} ),
    .mgr_port_req_o  ( mem_req                   ),
    .mgr_port_rsp_i  ( mem_rsp                   )
  );

  obi_sim_mem #(
    .ObiCfg            ( MemObiCfg        ),
    .obi_req_t         ( mem_obi_req_t    ),
    .obi_rsp_t         ( mem_obi_rsp_t    ),
    .obi_r_chan_t      ( mem_obi_r_chan_t ),
    .WarnUninitialized ( 1'b0             ),
    .ApplDelay         ( ApplDelay        ),
    .AcqDelay          ( AcqDelay         )
  ) i_mem (
    .clk_i       ( clk     ),
    .rst_ni      ( rst_n   ),
    .obi_req_i   ( mem_req ),
    .obi_rsp_o   ( mem_rsp ),
    .mon_valid_o (         ),
    .mon_we_o    (         ),
    .mon_addr_o  (         ),
    .mon_wdata_o (         ),
    .mon_be_o    (         ),
    .mon_id_o    (         )
  );

  // --------------------------------------------------------------------
  // The device under test
  // --------------------------------------------------------------------
  // Two ways to instantiate the same thing.
  //
  // At RTL, cordic_accel is parameterised and the testbench says which
  // configuration it wants.
  //
  // At gate level it is not: synthesis resolved every parameter and the
  // netlist is one fixed module with no parameter ports at all. Overriding
  // a parameter a module does not have is an elaboration error, so the
  // gate-level build takes the plain instantiation -- which is correct
  // because the defaults in cordic_accel_types_pkg are exactly the values
  // passed below: 32 bit address, 32 bit data, 1 bit id, FifoDepth 4.
  //
  // The port connections are identical in both cases. Design Compiler maps
  // a packed struct port onto a vector of the same width, and SystemVerilog
  // connects a packed struct to a vector without complaint.
  //
  // implementation/power_analysis/questa/gate_sim.do defines GATE_LEVEL.
`ifdef GATE_LEVEL
  cordic_accel i_dut (
`else
  cordic_accel #(
    .AddrWidth ( ObiCfg.AddrWidth ),
    .DataWidth ( ObiCfg.DataWidth ),
    .IdWidth   ( ObiCfg.IdWidth   ),
    .obi_req_t ( obi_req_t     ),
    .obi_rsp_t ( obi_rsp_t     ),
    .reg_req_t ( reg_bus_req_t ),
    .reg_rsp_t ( reg_bus_rsp_t ),
    .FifoDepth ( 4             )
  ) i_dut (
`endif
    .clk_i      ( clk         ),
    .rst_ni     ( rst_n       ),
    .testmode_i ( 1'b0        ),
    .reg_req_i  ( reg_req     ),
    .reg_rsp_o  ( reg_rsp     ),
    .obi_req_o  ( dut_obi_req ),
    .obi_rsp_i  ( dut_obi_rsp )
  );

  // --------------------------------------------------------------------
  // Vectors, produced by model/cordic_golden.py
  // --------------------------------------------------------------------
  logic [31:0] theta_mem  [MaxElems];
  logic [31:0] golden_mem [MaxElems];
  logic [31:0] golden_swap[MaxElems];

  int unsigned n_elems;
  logic [15:0] seed_x, seed_y, swap_x, swap_y;
  int unsigned errors;

  string vecdir;

  // Read the element count and the seeds the generator used.
  task automatic read_config();
    int fd, rc, n, sx, sy, wx, wy;
    string path;
    path = {vecdir, "config.txt"};
    fd = $fopen(path, "r");
    if (fd == 0) $fatal(1, "cannot open %s -- run `make vectors` first", path);
    rc = $fscanf(fd, "%d %h %h %h %h", n, sx, sy, wx, wy);
    if (rc != 5) $fatal(1, "malformed %s", path);
    $fclose(fd);
    n_elems = n;
    seed_x  = sx[15:0];
    seed_y  = sy[15:0];
    swap_x  = wx[15:0];
    swap_y  = wy[15:0];
    if (n_elems == 0 || n_elems > MaxElems)
      $fatal(1, "element count %0d out of range (max %0d)", n_elems, MaxElems);
  endtask

  // --------------------------------------------------------------------
  // Stimulus
  // --------------------------------------------------------------------
  reg_driver_t  regs;
  obi_manager_t mgr;

  // Program the accelerator, start it, wait for DONE, check what it wrote.
  task automatic run_and_check(input string        label,
                               input logic [31:0]  dst,
                               input logic [15:0]  sx,
                               input logic [15:0]  sy,
                               ref   logic [31:0]  golden [MaxElems]);
    logic [31:0] rdata, status;
    logic        rid, err, ropt;
    int unsigned timeout, local_errors;

    local_errors = 0;

    regs.send_write(REG_N,     32'(n_elems), 4'hF, err);
    regs.send_write(REG_SRC,   SrcBase,      4'hF, err);
    regs.send_write(REG_DST,   dst,          4'hF, err);
    regs.send_write(REG_SEEDX, 32'(sx),      4'hF, err);
    regs.send_write(REG_SEEDY, 32'(sy),      4'hF, err);

    // Read one back: a CSR block that does not read back is a classic bug.
    regs.send_read(REG_N, rdata, err);
    assert (rdata[15:0] == 16'(n_elems))
      else $error("[TB] N read back as %0d, expected %0d", rdata[15:0], n_elems);

    regs.send_write(REG_CTRL, 32'h1, 4'hF, err);   // START

    // Poll STATUS.DONE. The bound is generous: the rotator needs N + 2 cycles
    // per angle, plus the bus traffic around it.
    timeout = 200 * n_elems + 1000;
    status  = '0;
    while (!status[0] && timeout > 0) begin
      regs.send_read(REG_STATUS, status, err);
      timeout--;
    end
    if (!status[0]) $fatal(1, "[TB] %s: timeout waiting for STATUS.DONE", label);
    assert (!status[1]) else $error("[TB] %s: BUSY still set after DONE", label);

    for (int unsigned i = 0; i < n_elems; i++) begin
      mgr.read(dst + 32'(i * 4), 1'b0, '0, rdata, rid, err, ropt);
      assert (!err) else $error("[TB] %s: read error at result %0d", label, i);
      if (rdata !== golden[i]) begin
        local_errors++;
        if (local_errors <= 8)
          $error("[TB] %s: result %0d: theta=%0d got x=%0d y=%0d, expected x=%0d y=%0d",
                 label, i, $signed(theta_mem[i][15:0]),
                 $signed(rdata[15:0]), $signed(rdata[31:16]),
                 $signed(golden[i][15:0]), $signed(golden[i][31:16]));
      end
    end

    if (local_errors == 0)
      $display("[TB] %s: %0d/%0d results match the golden model", label, n_elems, n_elems);
    else
      $display("[TB] %s: %0d of %0d results wrong", label, local_errors, n_elems);

    errors += local_errors;
  endtask

  initial begin : test
    logic [31:0] rdata;
    logic        rid, err, ropt;

    regs = new(reg_bus);
    mgr  = new(tb_obi, "tb_manager");

    if (!$value$plusargs("VECDIR=%s", vecdir)) vecdir = "vectors/";

    regs.reset_master();
    mgr.reset();
    errors = 0;

    read_config();
    $readmemh({vecdir, "theta.hex"},       theta_mem);
    $readmemh({vecdir, "golden.hex"},      golden_mem);
    $readmemh({vecdir, "golden_swap.hex"}, golden_swap);

    @(posedge rst_n);
    repeat (2) @(posedge clk);

    $display("[TB] %0d angles from %s", n_elems, vecdir);

    // The angles go into memory through the bus, the same way a CPU would
    // have put them there.
    for (int unsigned i = 0; i < n_elems; i++) begin
      mgr.write(SrcBase + 32'(i * 4), 4'hF, theta_mem[i], 1'b0, '0,
                rdata, rid, err, ropt);
      assert (!err) else $error("[TB] write error at angle %0d", i);
    end

    run_and_check("run1 (cos/sin)", DstBase,  seed_x, seed_y, golden_mem);
    run_and_check("run2 (seed +90)", DstBase2, swap_x, swap_y, golden_swap);

    repeat (5) @(posedge clk);

    if (errors == 0) $display("TEST PASSED");
    else             $display("TEST FAILED");

    $finish;
  end

  // A simulation that hangs must fail, not run forever.
  initial begin
    #10ms;
    $display("TEST FAILED -- global timeout");
    $fatal(1, "global timeout");
  end

endmodule : tb_cordic_accel

# Lab 1 -- standalone CORDIC accelerator: vendor, generate, simulate, check.
#
# Run every target from the root of this repository. Each one is a thin wrapper: the
# raw command it runs is printed by make, so you can see (and re-run) the
# fusesoc / regtool / verilator invocation underneath.
#
# Typical first run:
#
#   make vendor      fetch common_cells, tech_cells_generic,
#                    register_interface and obi into vendor/
#   make regs        reggen: data/$(ACCEL).hjson -> the CSR block
#   make vectors     Python golden model -> vectors/*.hex
#   make sim         Verilator, self-checking, prints TEST PASSED / FAILED
#   make questa      the same testbench on QuestaSim
#
# Requirements: the `x-heep` conda environment from Lab 0 (python, fusesoc,
# reggen's packages), verilator 5, and (for `questa`) vsim on PATH. On the ISA
# server `source /oss-tools/init.sh` sets all of it up; see SETUP.md.

ROOT      := $(realpath .)

# --- The design --------------------------------------------------------------
# ACCEL is the top module. The synthesis, place-and-route and power scripts
# are generic: they read ACCEL (and TB, CORE) from the environment to find the
# netlist and the top module. The lab1 template uses exactly the same scripts.
ACCEL     := cordic_accel
TB        := tb_$(ACCEL)
CORE      := isa:lab1:$(ACCEL)
VENDOR    := vendor/pulp_platform
VECDIR    ?= vectors
NANGLES   ?= 64
# Synthesis knobs, passed to the TCL through the environment. Keep the
# comments off the assignment lines: make would otherwise put the trailing
# spaces in the value.
# clock constraint, ns. 10 ns (100 MHz) is the shipped default: it leaves
# the tools real margin at 130 nm, which is what makes the flow close
# cleanly end to end. Sweep it down to find the maximum frequency -- that
# is the exercise -- but expect timing to get interesting below ~5 ns.
CLK_PERIOD    ?= 10.0
# PVT corner: slow_1p08V_125C (setup sign-off), typ_1p20V_25C, fast_1p32V_m40C
SG13G2_CORNER ?= slow_1p08V_125C
# The corner the POWER analysis uses, which is deliberately not the one you
# sign timing off at: dynamic power goes as C*V^2*f, so 1.08 V under-reports
# it, and leakage roughly doubles every 10 C, so 125 C over-reports that.
# Typical is what the chip on a desk does. See
# implementation/power_analysis/scripts/set_libs.tcl.
PWR_CORNER    ?= typ_1p20V_25C
# where the IHP SG13G2 open PDK is installed
IHP_PDK_ROOT  ?= /oss-tools/pdk/ihp-sg13g2
# Place and route knobs (implementation/innovus/scripts/globals.tcl)
# target core utilisation, 0..1
PNR_UTIL      ?= 0.60
# core aspect ratio (width / height)
PNR_ASPECT    ?= 1.00
# clock period for the gate-level power run, in ps. Leave it empty: the
# power flow then reads the period from the netlist's own SDC, so the power
# is always measured at the frequency the netlist was built for. Set it only
# to measure the same netlist at a slower clock.
PWR_CLK_PS    ?=
SYNDIR    := implementation/design_compiler
PNRDIR    := implementation/innovus
PWRDIR    := implementation/power_analysis
BUILD     := build

PYTHON    ?= python3
FUSESOC   ?= fusesoc
REGTOOL   ?= $(VENDOR)/register_interface/vendor/lowrisc_opentitan/util/regtool.py

# FuseSoC scans the cores root recursively, so `.` finds both the accelerator
# core and the .core files describing the vendored IPs under vendor/.
FUSESOC_FLAGS := --cores-root .

# --- Verilator on isaserver -------------------------------------------------
# Verilator there was built with conda's g++ (verilated.mk hard-codes
# x86_64-conda-linux-gnu-g++), and that compiler does not search
# /usr/include. The shared /oss-tools/init.sh deliberately unsets the
# CPPFLAGS/CXXFLAGS conda normally exports -- they break X-HEEP's RISC-V
# build -- so headers that exist only in the conda env are invisible and
# `--trace-fst` dies with
#
#     fatal error: zlib.h: No such file or directory
#
# Putting the conda include directory back is enough. Note what is NOT here:
# LD_LIBRARY_PATH. Exporting conda's lib directory globally makes
# dc_shell/innovus load conda's libstdc++ instead of their own, and they die
# with `version CXXABI_1.3.15 not found`. Compile-time include path only,
# and only for the Verilator targets.
VERILATOR_ENV := $(if $(CONDA_PREFIX),CPLUS_INCLUDE_PATH=$(CONDA_PREFIX)/include$(if $(CPLUS_INCLUDE_PATH),:$(CPLUS_INCLUDE_PATH)))

.PHONY: help
help:
	@echo "Lab 1 -- standalone CORDIC accelerator"
	@echo ""
	@echo "  make vendor        fetch the pulp IPs into vendor/ (util/vendor.py)"
	@echo "  make regs          generate the CSR block from data/$(ACCEL).hjson (reggen)"
	@echo "  make vectors       generate vectors/{theta,golden}.hex (Python golden model)"
	@echo "  make sim           simulate on Verilator via FuseSoC (self-checking)"
	@echo "  make questa        simulate on QuestaSim via FuseSoC (same testbench)"
	@echo "  make lint          Verilator lint of the synthesisable RTL"
	@echo "  make synth         logic synthesis with Design Compiler via FuseSoC"
	@echo "  make synth-clean   remove synthesis outputs (netlist, reports, work)"
	@echo "  make pnr           place and route with Innovus (batch)"
	@echo "  make pnr-gui       the same scripts with the Innovus GUI open"
	@echo "  make pnr-opt       post-route optimisation + export (2nd Innovus session)"
	@echo "  make pnr-all       make pnr followed by make pnr-opt"
	@echo "  make pnr-clean     remove place-and-route outputs"
	@echo "  make gds           open the layout in KLayout (needs ssh -X)"
	@echo "  make power         gate-level sim + PrimePower switching-activity power"
	@echo "  make power-sim     just the gate-level simulation (writes the VCD)"
	@echo "  make power-postlayout  the same, on the Innovus netlist + SDF + SPEF"
	@echo "  make power-report  just PrimePower, on the post-synthesis VCD already there"
	@echo "  make power-clean   remove VCDs and power reports"
	@echo "  make waves         Verilator run with FST tracing"
	@echo "  make model-check   accuracy of the golden model vs math.cos/sin"
	@echo "  make bitexact      golden model vs the cookbook rotator (model + RTL vectors)"
	@echo "  make clean         remove build products (keeps vendor/ and generated CSRs)"
	@echo "  make distclean     also remove vendor/ and the generated CSR block"
	@echo ""
	@echo "  vars: NANGLES=$(NANGLES)  VECDIR=$(VECDIR)"
	@echo "        CLK_PERIOD=$(CLK_PERIOD)  SG13G2_CORNER=$(SG13G2_CORNER)  PWR_CORNER=$(PWR_CORNER)"
	@echo "        IHP_PDK_ROOT=$(IHP_PDK_ROOT)"
	@echo "        PNR_UTIL=$(PNR_UTIL)  PNR_ASPECT=$(PNR_ASPECT)  PWR_CLK_PS=$(or $(PWR_CLK_PS),<from the SDC>)"

# --- Vendoring --------------------------------------------------------------
# One descriptor per IP under vendor/pulp_platform/. Each names an upstream
# repo and a pinned revision; util/vendor.py copies a snapshot (no submodule,
# no .git) into vendor/pulp_platform/<name> and writes a .lock.hjson recording
# exactly what was fetched.
VENDOR_HJSON := $(wildcard $(VENDOR)/*.vendor.hjson)

.PHONY: vendor
vendor:
	@for f in $(VENDOR_HJSON); do \
	  echo "$(PYTHON) util/vendor.py $$f"; \
	  $(PYTHON) util/vendor.py $$f || exit 1; \
	done

# --- Register block ---------------------------------------------------------
# reggen (OpenTitan's regtool, vendored inside register_interface) turns the
# HJSON register description into the CSR block and the C header the Lab 3
# driver will include. Re-run it whenever data/$(ACCEL).hjson changes.
.PHONY: regs
regs:
	$(PYTHON) $(REGTOOL) -r -t rtl data/$(ACCEL).hjson
	@mkdir -p sw
	$(PYTHON) $(REGTOOL) -D -o sw/$(ACCEL)_regs.h data/$(ACCEL).hjson
	@echo "generated rtl/$(ACCEL)_reg_{pkg,top}.sv and sw/$(ACCEL)_regs.h"

# --- Golden vectors ---------------------------------------------------------
# The model is the reference; the RTL has to match it bit for bit. The
# generator also emits config.txt, so the testbench knows how many angles to
# expect without being told twice.
.PHONY: vectors
vectors:
	$(PYTHON) model/cordic_golden.py -n $(NANGLES) -o $(VECDIR)

.PHONY: model-check
model-check:
	$(PYTHON) model/cordic_golden.py --selfcheck

# The testbench pins the RTL to model/cordic_golden.py on every `make sim`.
# This pins that model to the cookbook's CORDIC (Example Cookbook, ch. 10): its
# Python model and the vectors its VHDL and SystemVerilog testbenches run,
# both copied into model/cookbook/. Together they mean this accelerator and
# the cookbook rotator compute the same integers.
.PHONY: bitexact
bitexact:
	$(PYTHON) model/check_bitexact.py

# --- Simulation -------------------------------------------------------------
# FuseSoC resolves the dependency tree (the four vendored IPs), writes a
# filelist and calls the tool. `--run_options` passes the plusarg through to
# the simulation binary; the path is absolute because FuseSoC runs the binary
# from its own build directory.
.PHONY: sim
sim: vectors bitexact
	$(VERILATOR_ENV) $(FUSESOC) $(FUSESOC_FLAGS) run --target sim $(CORE) \
	  --run_options="+VECDIR=$(ROOT)/$(VECDIR)/"

# Note --vsim_options, not --run_options. The two backends take the plusarg
# by different names: edalize's verilator backend has --run_options (it runs
# the compiled binary), the modelsim backend does not and instead passes
# --vsim_options straight to vsim. Using the wrong one is not ignored --
# fusesoc stops with `error: unrecognized arguments'.
.PHONY: questa
questa: vectors bitexact
	$(FUSESOC) $(FUSESOC_FLAGS) run --target sim_questa $(CORE) \
	  --vsim_options="+VECDIR=$(ROOT)/$(VECDIR)/"

.PHONY: lint
lint:
	$(VERILATOR_ENV) $(FUSESOC) $(FUSESOC_FLAGS) run --target lint $(CORE)

# --- Logic synthesis (Synopsys Design Compiler) -----------------------------
# Same idea as `sim`: FuseSoC resolves the sources and calls the tool, and the
# tool-specific part lives in implementation/design_compiler/scripts/. Read
# implementation/design_compiler/README.md first and run the flow by hand
# once -- this target is the automated version of what you did there.
#
# Needs the EDA environment (source /eda/scripts/init_design_vision) and the
# IHP SG13G2 PDK. The PDK ships Liberty only, so the first run compiles the
# .lib into a .db under implementation/design_compiler/db/ and caches it.
.PHONY: synth
synth:
	@rm -f $(SYNDIR)/netlist/$(ACCEL).v
	ACCEL=$(ACCEL) CLK_PERIOD=$(CLK_PERIOD) SG13G2_CORNER=$(SG13G2_CORNER) IHP_PDK_ROOT=$(IHP_PDK_ROOT) \
	  $(FUSESOC) $(FUSESOC_FLAGS) run --target synth $(CORE)
# A failed dc_shell does not fail this target on its own: edalize's generated
# Makefile pipes the tool into `tee', and the exit status of a pipeline is
# tee's, which is always 0. So check for the thing synthesis is supposed to
# produce. The whole dc_shell transcript is in the log named below.
	@test -f $(SYNDIR)/netlist/$(ACCEL).v || { \
	  echo "synthesis produced no netlist -- see $(SYNDIR)/reports/synth.log"; exit 1; }
	@echo "netlist: $(SYNDIR)/netlist/$(ACCEL).v"
	@echo "reports: $(SYNDIR)/reports/ (synth.log is the full dc_shell transcript)"

.PHONY: synth-clean
synth-clean:
	rm -rf $(SYNDIR)/work $(SYNDIR)/reports $(SYNDIR)/netlist $(SYNDIR)/db \
	       $(SYNDIR)/*.log $(SYNDIR)/command.log $(SYNDIR)/default.svf

# --- Place and route (Cadence Innovus) --------------------------------------
# Unlike synthesis, this is not driven through FuseSoC: Innovus takes a
# netlist, not a source list, and the netlist is what `make synth` produced.
# The scripts are plain Tcl, one per step, in implementation/innovus/scripts/.
#
# Read implementation/innovus/README.md and run the flow through the GUI once
# before using these -- a script you have never watched run is a script you
# cannot debug.
#
# Needs the EDA environment (source /eda/scripts/init_cadence_2020-21).
PNR_ENV := ACCEL=$(ACCEL) IHP_PDK_ROOT=$(IHP_PDK_ROOT) SG13G2_CORNER=$(SG13G2_CORNER) \
           PNR_UTIL=$(PNR_UTIL) PNR_ASPECT=$(PNR_ASPECT) LAB_ROOT=$(ROOT)

# Innovus exits with status 1 whenever its log contains an **ERROR, and this
# flow always logs a few harmless ones (the IMPPP-4422 followpin checks on the
# rows the power ring covers, the IMPESO-* signoff-tool notes). So, as with
# `make synth', the exit status is ignored (the leading `-') and the target
# checks for what the stage is supposed to produce instead.
#
# The batch runs drop DISPLAY (env -u). Innovus connects to the X display
# whenever one is set, even with -batch, and dies ("The X11 connection broke")
# if it goes away mid-run -- which is exactly what happens when you start
# `make pnr-all' inside tmux over `ssh -X' and then log out. Only pnr-gui
# needs X.
.PHONY: pnr
pnr: $(SYNDIR)/netlist/$(ACCEL).v
	@rm -rf $(PNRDIR)/artefacts/db/post_route.db
	-cd $(PNRDIR) && env -u DISPLAY $(PNR_ENV) \
	  innovus -stylus -batch -files scripts/run_pnr_flow.tcl -log artefacts/innovus
	@test -e $(PNRDIR)/artefacts/db/post_route.db || { \
	  echo "place and route did not finish -- see $(PNRDIR)/artefacts/innovus.log"; exit 1; }

# Same scripts, GUI open. PNR_KEEP_GUI stops run_pnr_flow.tcl from calling
# exit, so you are left in the tool with the finished layout on screen.
.PHONY: pnr-gui
pnr-gui: $(SYNDIR)/netlist/$(ACCEL).v
	cd $(PNRDIR) && $(PNR_ENV) PNR_KEEP_GUI=1 \
	  innovus -stylus -log artefacts/innovus -files scripts/run_pnr_flow.tcl

# Post-route optimisation and export, in a SECOND Innovus session.
#
# Not part of `make pnr' on purpose: on Innovus 20.11 both opt_design
# -post_route and route_eco -fix_drc fail in the session that just did the
# routing, and opt_design fails badly -- it leaves unrouted ECO cells and
# the DRC count goes from 7 to 1754. The same commands on the same
# post_route.db in a fresh session work, and close hold. See the header of
# implementation/innovus/scripts/run_pnr_opt.tcl.
#
#   make pnr        -> routed design, hold NOT fixed
#   make pnr-opt    -> hold fixed, DRC clean, final exports
.PHONY: pnr-opt
pnr-opt:
	@rm -f $(PNRDIR)/artefacts/export/$(ACCEL)_pnr.v
	-cd $(PNRDIR) && env -u DISPLAY $(PNR_ENV) PNR_POST_ROUTE_OPT=1 \
	  innovus -stylus -batch -files scripts/run_pnr_opt.tcl -log artefacts/pnr_opt
	@test -f $(PNRDIR)/artefacts/export/$(ACCEL)_pnr.v || { \
	  echo "post-route optimisation did not finish -- see $(PNRDIR)/artefacts/pnr_opt.log"; exit 1; }

# Both steps, which is what you normally want.
.PHONY: pnr-all
pnr-all: pnr pnr-opt

$(SYNDIR)/netlist/$(ACCEL).v:
	@echo "no netlist yet -- run 'make synth' first"; exit 1

# --- Look at the layout -------------------------------------------------------
# The GDS Innovus wrote, in KLayout, with the PDK's layer properties loaded --
# without the .lyp every layer is an anonymous number in a colour KLayout made
# up. Needs X11 (`ssh -X isa`). KLayout is installed system-wide on the ISA
# server (/usr/bin/klayout).
.PHONY: gds
gds: $(PNRDIR)/artefacts/export/$(ACCEL).gds
	@command -v klayout >/dev/null || { \
	  echo "klayout not on PATH -- it is installed on the ISA server"; exit 1; }
	klayout -l $(IHP_PDK_ROOT)/libs.tech/klayout/tech/sg13g2.lyp $<

$(PNRDIR)/artefacts/export/$(ACCEL).gds:
	@echo "no GDS yet -- run 'make pnr-all' first"; exit 1

.PHONY: pnr-clean
pnr-clean:
	rm -rf $(PNRDIR)/artefacts $(PNRDIR)/*.log $(PNRDIR)/*.cmd \
	       $(PNRDIR)/innovus.* $(PNRDIR)/.innovus* $(PNRDIR)/timingReports

# --- Post-synthesis power analysis (QuestaSim + PrimePower) -----------------
# Two steps: a gate-level simulation of the synthesised netlist that records
# every transition into a VCD, then PrimePower turning that activity into
# watts. See implementation/power_analysis/README.md for why the
# `report_power` number from synthesis is not an answer.
#
# Synthesis signs timing off at the slow corner; power is measured at the
# typical one (PWR_CORNER). PrimePower reads the SAME netlist and the PDK's
# typical-corner Liberty, compiled once to a .db with lc_shell (cached next
# to the synthesis one) -- no re-synthesis.
#
# The gate-level simulation compiles the testbench from the file list FuseSoC
# writes for `make questa` (nothing is listed by hand), then the netlist on
# top of it. The testbench must instantiate the DUT as `i_dut` and compile
# under +define+GATE_LEVEL without parameter overrides -- a gate-level
# netlist has no parameters left.
#
# Needs all three environments: /oss-tools/init.sh (fusesoc), vsim on PATH,
# and source /eda/scripts/init_design_vision for pt_shell.
PWR_ENV := ACCEL=$(ACCEL) TB=$(TB) CORE=$(CORE) IHP_PDK_ROOT=$(IHP_PDK_ROOT) \
           PWR_CORNER=$(PWR_CORNER) VECDIR=$(ROOT)/$(VECDIR)
PWR_CLK := $(if $(PWR_CLK_PS),--clk-ps $(PWR_CLK_PS))

.PHONY: power
power: $(SYNDIR)/netlist/$(ACCEL).v vectors
	cd $(PWRDIR) && $(PWR_ENV) ./run_pwr_flow.sh $(PWR_CLK)

# Just the simulation. Useful while you are still getting the VCD scope
# right, since PrimePower is the slow half.
.PHONY: power-sim
power-sim: $(SYNDIR)/netlist/$(ACCEL).v vectors
	cd $(PWRDIR) && $(PWR_ENV) ./run_pwr_flow.sh --sim-only $(PWR_CLK)

# --- Post-LAYOUT power -------------------------------------------------------
# The same two steps on the Innovus netlist instead of the Design Compiler
# one, and it is a different measurement, not a refinement of the same one:
#
#   make power              ideal clock, no clock tree in the netlist,
#                           estimated wire capacitance, zero-delay
#                           simulation -- so no glitches. A lower bound.
#   make power-postlayout   the routed netlist WITH its clock tree, delays
#                           back-annotated from the Innovus SDF (glitches
#                           happen), and capacitance read from the SPEF
#                           Innovus extracted from the real wires.
#
# The clock tree alone is often a large share of a block's dynamic power and
# none of it exists before place and route. Report the post-layout number,
# and use the pair to say what layout cost you.
#
# Separate VCDs (vcd/<top>_pnr.vcd) and separate reports
# (reports/<top>_pnr_*.rpt), so running both leaves both to compare.
.PHONY: power-postlayout
power-postlayout: $(PNRDIR)/artefacts/export/$(ACCEL)_pnr.v vectors
	cd $(PWRDIR) && $(PWR_ENV) ./run_pwr_flow.sh --postlayout $(PWR_CLK)

$(PNRDIR)/artefacts/export/$(ACCEL)_pnr.v:
	@echo "no post-layout netlist yet -- run 'make pnr-all' first"; exit 1

# Just the analysis, on the VCD that is already there. Add
# `PWR_REPORT_ARGS=--postlayout` for the post-layout one.
.PHONY: power-report
power-report:
	cd $(PWRDIR) && $(PWR_ENV) ./run_pwr_flow.sh --skip-sim $(PWR_REPORT_ARGS)

.PHONY: power-clean
power-clean:
	rm -rf $(PWRDIR)/vcd $(PWRDIR)/reports $(PWRDIR)/*.log \
	       $(PWRDIR)/transcript $(PWRDIR)/vsim.wlf $(BUILD)/gate

# Same Verilator run, keeping the FST trace it writes for gtkwave.
.PHONY: waves
waves: sim
	@find $(BUILD) -name '*.fst' -print

.PHONY: clean
clean:
	rm -rf $(BUILD) work transcript vsim.wlf *.fst *.vcd
	rm -f $(VECDIR)/*.hex $(VECDIR)/config.txt

.PHONY: distclean
distclean: clean
	rm -rf $(VENDOR)/common_cells $(VENDOR)/tech_cells_generic \
	       $(VENDOR)/register_interface $(VENDOR)/obi
	rm -f rtl/$(ACCEL)_reg_pkg.sv rtl/$(ACCEL)_reg_top.sv sw/$(ACCEL)_regs.h

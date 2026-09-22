# Logic synthesis with Synopsys Design Compiler

Take the CORDIC accelerator you simulated in Lab 1 and turn it into a
gate-level netlist in **IHP SG13G2**, a 130 nm open PDK: real cells with real
characterisation data, real area, a real maximum frequency — and, later in
the course, real memories and real IO pads, because this PDK has them and a
chip needs them.

Work through this page **one command at a time, by hand, in the Design
Compiler shell**. Do not start from the scripts. Synthesis is a sequence of
decisions — which libraries, which constraints, which effort — and each
command's output tells you whether the previous decision was sensible. A
script hides that. Once the flow works, the last section shows you how to put
it back into scripts and drive it from FuseSoC, which is how you will actually
run the sweeps.

Everything below is run from **this directory**
(`lab1/implementation/design_compiler/`).

---

## 0. Before you start

**Source the EDA setup**, once per shell:

```bash
source /eda/scripts/init_design_vision
```

This puts `dc_shell-xg-t`, `design_vision`, `lc_shell` and `vcd2saif` on your
`PATH`. Nothing below works without it.

**Point at the PDK.** The scripts default to `/eda/dk/ihp-sg13g2`; if yours
is elsewhere, say so:

```bash
export IHP_PDK_ROOT=/path/to/ihp-sg13g2
```

Check it is really there — this is the file the synthesis needs:

```bash
ls $IHP_PDK_ROOT/libs.ref/sg13g2_stdcell/lib/
```

**Create the work directory.** `WORK` is where Design Compiler keeps its
intermediate files, and it will not create it for you:

```bash
mkdir -p work
```

That is all the preparation there is. Everything else — the libraries, the
search path, the `WORK` binding — you will type in §1, and it lives in
`scripts/dc_script.tcl` once you move to the scripted flow.

> **A note on `.synopsys_dc.setup`.** Most Design Compiler tutorials, the
> course notes included, start by writing a hidden file called
> `.synopsys_dc.setup` holding the library setup. Design Compiler reads it
> automatically — but **only from the directory `dc_shell` was started in**.
> Run the tool from somewhere else, as FuseSoC does from its build directory,
> and the file is silently ignored: you get a synthesis with no target library
> and a pile of errors that do not mention the setup file at all. A setup that
> applies to one of the two ways you run the flow and quietly does not apply
> to the other is worse than no setup file, so this lab does not use one. The
> library setup is written explicitly at the top of the synthesis script, and
> it is the same in both cases.

---

## 0b. The technology: IHP SG13G2

Everything the synthesizer knows about the silicon comes from the PDK, so it
is worth five minutes to see what is in it.

```
$IHP_PDK_ROOT/libs.ref/
├── sg13g2_stdcell/   the standard cells: lib/ lef/ gds/ verilog/ cdl/ doc/
├── sg13g2_io/        the IO pads (1.2 V core <-> 3.3 V outside)
├── sg13g2_sram/      the SRAM macros, 1-port and 2-port
└── sg13g2_pr/        the place-and-route technology files
```

**Standard cells.** Names read as `sg13g2_<function>_<drive>`:
`sg13g2_nand2_1`, `sg13g2_buf_4`, `sg13g2_inv_16`, flip-flops
`sg13g2_dfrbp_1` (and scan versions `sg13g2_sdfrbp_1`), the integrated clock
gating cells `sg13g2_lgcp_1` and `sg13g2_slgcp_1`. Input pins are `A`, `B`,
…, and **the output is `Y`** — check it yourself in the LEF or the Liberty
rather than assuming, because the convention differs between open PDKs and
a wrong pin name is a whole netlist that will not link.
Open `sg13g2_stdcell/doc/` and skim the cell list before you read your first
`report_area` — a netlist is a list of these names, and it is much easier to
read when you recognise them.

**Corners.** Liberty comes characterised at several process/voltage/
temperature points:

| file | corner | use for |
|------|--------|---------|
| `sg13g2_stdcell_slow_1p08V_125C.lib` | slow, 1.08 V, 125 °C | **setup sign-off**: the slowest silicon you may get |
| `sg13g2_stdcell_typ_1p20V_25C.lib` | typical, 1.20 V, 25 °C | exploring, quick iterations |
| `sg13g2_stdcell_fast_1p32V_m40C.lib` | fast, 1.32 V, −40 °C | hold analysis |

The scripts default to the **slow** corner. A frequency you report from the
typical corner is a frequency you cannot promise.

**Memories.** `sg13g2_sram/lib/` holds a large set of hard macros, single and
dual port, from `RM_IHPSG13_1P_64x16` up to `RM_IHPSG13_1P_8192x32`, most with
bit-mask and BIST. You will need one the moment your accelerator wants a
buffer bigger than a handful of flip-flops — see §10.

**Pads.** `sg13g2_io/` holds the IO cells, in 4 mA, 16 mA and 30 mA drive
variants, and the power/ground pads. Nothing in this lab uses them; the
full-chip lab does, because a die with no pads cannot be bonded.

**Liberty, not `.db`.** Design Compiler works from a compiled binary library.
Open PDKs ship the source form, `.lib`, so it has to be compiled once:

```tcl
read_lib  $IHP_PDK_ROOT/libs.ref/sg13g2_stdcell/lib/sg13g2_stdcell_slow_1p08V_125C.lib
write_lib sg13g2_stdcell_slow_1p08V_125C -format db -output db/sg13g2_stdcell_slow_1p08V_125C.db
```

(`lc_shell` does the same outside `dc_shell`; either needs a Library Compiler
licence.) `scripts/dc_script.tcl` does this for you on the first run and
caches the result in `db/`, so you only pay for it once.

## 1. Start Design Compiler

Two front ends, same tool:

```bash
design_vision      # graphical
dc_shell-xg-t      # shell
```

Use the shell. Every command prints to standard output, and you can redirect
any of them to a file to read the messages properly:

```tcl
elaborate cordic_accel -lib WORK > ./elaborate.txt
```

Now set up the libraries. First bind the logical library `WORK` to the real
directory you created:

```tcl
define_design_lib WORK -path ./work
```

Compile the technology library, as in §0b, and put the result somewhere the
tool will find it:

```tcl
sh mkdir -p db
read_lib  $env(IHP_PDK_ROOT)/libs.ref/sg13g2_stdcell/lib/sg13g2_stdcell_slow_1p08V_125C.lib
write_lib sg13g2_stdcell_slow_1p08V_125C -format db -output db/sg13g2_stdcell_slow_1p08V_125C.db
```

Then say where libraries are found — the compiled technology library and the
Synopsys ones (DesignWare):

```tcl
set search_path [concat [list . ./db \
                              /eda/synopsys/2021-22/RHELx86/SYN_2021.06-SP4/libraries/syn ] \
                        $search_path]
```

and name them:

```tcl
set target_library    [list "sg13g2_stdcell_slow_1p08V_125C.db" ]
set link_library      [list "*" "sg13g2_stdcell_slow_1p08V_125C.db" "dw_foundation.sldb" ]
set synthetic_library [list "dw_foundation.sldb" ]
```

- `target_library` — the cells the synthesizer is allowed to put in the
  netlist.
- `link_library` — everything needed to resolve a reference. `"*"` means "the
  designs already loaded in memory".
- `synthetic_library` — DesignWare. With it the tool recognises adders,
  multipliers, comparators and so on, and picks an implementation that meets
  your constraint. Without it you get whatever the RTL literally described,
  usually a ripple-carry adder.

DesignWare comes from the Synopsys installation, not from the PDK, so it is
there whatever technology you target.

---

## 2. Read the sources

`analyze` reads a source file and checks it. It needs the format (`-f
sverilog`; `verilog` and `vhdl` also exist) and the library to put the
intermediate files in (`-lib WORK`).

The accelerator does not stand alone: it instantiates cells from the four
vendored IPs, and those have to be read too, **packages first** — a package
must exist before anything that imports it is analyzed. Header files (`.svh`)
are not analyzed; they are found through `search_path`, so add the include
directories first:

```tcl
set VENDOR ../../vendor/pulp_platform
set search_path [concat [list $VENDOR/common_cells/include \
                              $VENDOR/register_interface/include \
                              $VENDOR/obi/include ] $search_path]
```

Then the vendored sources:

```tcl
analyze -f sverilog -lib WORK $VENDOR/common_cells/src/cf_math_pkg.sv
analyze -f sverilog -lib WORK $VENDOR/common_cells/src/fifo_v3.sv
analyze -f sverilog -lib WORK $VENDOR/common_cells/src/credit_counter.sv
analyze -f sverilog -lib WORK $VENDOR/tech_cells_generic/src/rtl/tc_clk.sv
analyze -f sverilog -lib WORK $VENDOR/register_interface/src/reg_intf.sv
analyze -f sverilog -lib WORK $VENDOR/register_interface/vendor/lowrisc_opentitan/src/prim_subreg_arb.sv
analyze -f sverilog -lib WORK $VENDOR/register_interface/vendor/lowrisc_opentitan/src/prim_subreg.sv
analyze -f sverilog -lib WORK $VENDOR/register_interface/vendor/lowrisc_opentitan/src/prim_subreg_ext.sv
analyze -f sverilog -lib WORK $VENDOR/obi/src/obi_pkg.sv
```

and the accelerator itself:

```tcl
analyze -f sverilog -lib WORK ../../rtl/cordic_pkg.sv
analyze -f sverilog -lib WORK ../../rtl/cordic_accel_types_pkg.sv
analyze -f sverilog -lib WORK ../../rtl/cordic_accel_reg_pkg.sv
analyze -f sverilog -lib WORK ../../rtl/cordic_accel_reg_top.sv
analyze -f sverilog -lib WORK ../../rtl/cordic_rot.sv
analyze -f sverilog -lib WORK ../../rtl/cordic_accel.sv
```

If `cordic_accel_reg_pkg.sv` or `cordic_accel_reg_top.sv` is missing, you have
not generated the CSR block yet: `make regs` in `lab1/`.

Before elaborating, ask the tool to keep the RTL hierarchy names in the
netlist:

```tcl
set power_preserve_rtl_hier_names true
```

You will need this at the end of the flow: switching activity is recorded on
instance names, and if the names change between RTL and netlist it cannot be
annotated back for power estimation.

---

## 3. Elaborate and link

`elaborate` builds the design from the analyzed sources: it resolves
parameters, unrolls generates and produces something that can be optimised.

```tcl
elaborate cordic_accel -lib WORK
```

(VHDL entities can have several architectures, hence the `-arch` option you
will see in examples; SystemVerilog modules do not need it.)

If the design instantiates the same block more than once and you want each
copy optimised independently:

```tcl
uniquify
```

Then resolve every reference against the libraries:

```tcl
link
```

Read the `link` output. Unresolved references are the single most common
failure here, and they always mean a missing `analyze` — a package, a cell, a
generated file.

---

## 4. Apply the constraints

An unconstrained synthesis is meaningless: with no clock the tool has no
reason to make anything fast, and it will not.

Create a symbolic clock and bind it to the real clock pin. The accelerator's
clock port is `clk_i`; 2 ns is 500 MHz:

```tcl
create_clock -name MY_CLK -period 2.0 [get_ports clk_i]
```

The clock net is special — it must not be buffered or restructured like
ordinary logic:

```tcl
set_dont_touch_network MY_CLK
```

Real clocks jitter. With no better number, take a small fraction of the
period:

```tcl
set_clock_uncertainty 0.07 [get_clocks MY_CLK]
```

Tell the tool when signals arrive and when they must be ready. Inputs are
assumed to arrive at most 0.5 ns after the edge, outputs must be stable 0.5 ns
before the next one:

```tcl
set_input_delay  0.5 -max -clock MY_CLK [remove_from_collection [all_inputs] [get_ports clk_i]]
set_output_delay 0.5 -max -clock MY_CLK [all_outputs]
```

Both have to stay well below the clock period, otherwise nothing you do to
the logic can satisfy the constraint.

Say what the outputs drive. Assume one buffer's input capacitance; `BUF_X4` is
a medium-strength buffer of this library and `A` is its input pin:

```tcl
set OLOAD [load_of sg13g2_stdcell_slow_1p08V_125C/sg13g2_buf_4/A]
set_load $OLOAD [all_outputs]
```

Note the library name in that path carries the corner: change corner, change
the name. `scripts/set_constraints.tcl` takes it from the variable the
synthesis script set, so the two cannot drift apart.

To see which cells the technology actually offers, read the Liberty source
or the cell list that comes with it:
`$IHP_PDK_ROOT/libs.ref/sg13g2_stdcell/lib/` and
`$IHP_PDK_ROOT/libs.ref/sg13g2_stdcell/doc/`.

The accelerator's reset is asynchronous, so it is not a timed path:

```tcl
set_false_path -from [get_ports rst_ni]
```

---

## 5. Synthesise

```tcl
compile
```

`compile` has many options (`man compile`). Two matter here.

Your registers have enables, so the tool can insert clock gating for you:

```tcl
compile -gate_clock
```

And `compile_ultra` is the higher-effort flow — it is what X-HEEP uses, and
what the shipped script runs:

```tcl
compile_ultra -gate_clock
```

Run both at the same clock constraint and compare area and slack. The
difference is the answer to "how much does effort buy?", and it is not always
large.

In this technology `-gate_clock` uses `sg13g2_lgcp_1`, the library's
integrated clock gating cell: a posedge latch and an AND, characterised as
one cell. That is the only kind of clock gate worth having — see §5b.

Note that the accelerator already instantiates a clock gate explicitly
(`tc_clk_gating`, around the rotator). That is an architectural decision — the
rotator is stopped for whole runs — while `-gate_clock` is the tool finding
enable-driven registers on its own. They are complementary.

---

## 5b. The clock gate you are synthesising is not the one you simulated

The accelerator instantiates `tc_clk_gating`. In simulation that module comes
from `tech_cells_generic`, and it is a behavioural model — an `always_latch`
and an `assign clk_o = clk_i & clk_en`. Perfectly good to simulate; **not
something to synthesise**. Handed that RTL, the tool builds a latch out of
standard cells and ANDs its output with the clock, which gives you a clock
net with a combinational gate in it, glitches when the enable moves at the
wrong moment, and a timing model nobody can sign off.

So the synthesis flow compiles a *different* file with the *same* module name
and ports, `implementation/tech/sg13g2/tc_clk_gating_sg13g2.sv`, which
instantiates `sg13g2_lgcp_1` directly:

```systemverilog
sg13g2_lgcp_1 i_icg (
    .CLK (clk_i),
    .GATE(en_i | test_en_i),
    .GCLK(clk_o)
);
```

The design never knows which one it got. The choice is made in
`cordic_accel.core`, by two filesets:

```yaml
  tech-generic:                      # simulation
    depend: [pulp-platform.org::tech_cells_generic]

  tech-sg13g2:                       # synthesis
    files: [implementation/tech/sg13g2/tc_clk_gating_sg13g2.sv]
```

and the targets pick one each: `sim` and `sim_questa` take `tech-generic`,
`synth` takes `tech-sg13g2`. Check it after a run — `grep tc_clk` in the
generated `*-read-sources.tcl` should show the sg13g2 file and nothing from
`tech_cells_generic`.

Remember this pattern. §10 is the same pattern again, for memories, where the
consequences of getting it wrong are much larger than one gate.

---

## 5c. Fine-grained clock gating is a lab exercise, not a power strategy

`compile_ultra -gate_clock` gates *registers*. It looks at every enable-driven
flip-flop bank in the design, decides which ones are worth it, and drops an
`sg13g2_lgcp_1` in front of each. You will see a few dozen of them in
`report_power`, and the dynamic power will go down. That is real, and it is
the right default to leave on.

It is also not how a chip saves power.

**In a real design you do not gate the clock a register bank at a time. You
switch the whole block off.** The accelerator is a peripheral hanging off the
SoC's clock controller, and the controller owns a single enable for it:

```
    reference clock ─► clock controller ─► gate ─► cordic_accel clk_i
                            ▲
                            │
                  CLK_ENABLE.cordic  (a CSR the driver writes)
```

The driver clears that bit when the kernel is done, and *everything* inside
the accelerator stops: the CSR block, the OBI manager, the FIFO, the rotator,
every one of the tool-inserted gates included. Nothing toggles, and the only
power the block draws is leakage. Set the bit again before the next kernel.
That is one gate, under software control, and it is worth more than every
fine-grained gate in the netlist put together.

Why the coarse one wins:

| | fine-grained (`-gate_clock`) | peripheral-level enable |
|---|---|---|
| who decides | the synthesizer, per register bank | software, per kernel |
| what stops | the registers behind that one enable | the entire block, clock tree included |
| when it helps | while the block is running and parts of it idle | whenever the block is not in use, which is most of the time |
| clock tree | still toggling, still burning power | gated at the root, off |
| cost | one ICG per bank, some area | one ICG, one CSR bit, one driver call |

Read the third row again. A duty cycle is what decides this. An accelerator
that runs 2 % of the time and is clocked the other 98 % wastes almost all its
energy in a clock tree that is distributing edges to registers whose enables
are low — and fine-grained gating does not touch the clock tree, because the
gates hang off its leaves. Gating at the root removes the tree as well.

So the two are not competing, they are at different granularities, and the
coarse one does the heavy lifting:

- **peripheral-level enable** — the architectural decision. Whole block on or
  off, driven by software, saves ~100 % of the dynamic power of an idle
  block. This is what X-HEEP does for every peripheral, and what Lab 3 wires
  up when the accelerator goes into the SoC.
- **block-internal gate** — what `cordic_accel` already does with its explicit
  `tc_clk_gating` around the rotator: the datapath is stopped for whole runs,
  a decision you made in the RTL because you know the dataflow and the tool
  does not.
- **`-gate_clock`** — the leftovers. Free, automatic, worth keeping on, and
  the smallest of the three.

You do the fine-grained one in this lab because it is the one Design Compiler
can show you: you flip an option, you read two `report_power` outputs, and
you see the mechanism. Do not mistake the exercise for the strategy. When the
accelerator reaches Lab 3, the first question is not "did the tool insert
enough gates", it is "who turns this block off, and when".

---

## 6. Read the results

**Timing.** The longest path, and whether the constraint is met:

```tcl
report_timing
```

Read the slack. "Met" with a small positive slack does *not* mean the tool
could not do better: tighten the period and it may restructure the logic —
swap a ripple-carry adder for a carry-lookahead one, for instance — and meet
that too. Negative slack means the netlist is not valid at this frequency.

To find the maximum frequency: constrain the period to 0, synthesise, and read
the resulting slack — that gives you T_min. Then re-run with the period set to
T_min and confirm it is met.

**Area.**

```tcl
report_area
```

The last lines are the ones to record: combinational, buffer/inverter,
non-combinational (the flip-flops), macro and interconnect area, plus the
totals. This design has no macros. Everything is in µm².

**Everything else**, useful once you start comparing versions:

```tcl
report_qor
report_resources -hierarchy
report_power
```

`report_power` here is an *estimate* from statistical switching assumptions.
The real number needs switching activity from a simulation — that is the
`vcd` → `saif` → `read_saif` → `report_power` flow, and it comes later in the
lab.

---

## 7. Save what the rest of the flow needs

Flatten the hierarchy. Place and route and the power estimation both work on
a flat netlist:

```tcl
ungroup -all -flatten
```

Force Verilog naming rules, so the names in the netlist survive tools that do
not speak SystemVerilog escaping:

```tcl
change_names -hierarchy -rules verilog
```

Write out the netlist, the cell delays and the constraints:

```tcl
write -f verilog -hierarchy -output ./netlist/cordic_accel.v
write_sdf ./netlist/cordic_accel.sdf
write_sdc ./netlist/cordic_accel.sdc
```

- the `.v` netlist is what you simulate at gate level and what Innovus places
  and routes,
- the `.sdf` carries the cell and net delays, so the gate-level simulation is
  timing-accurate,
- the `.sdc` carries your constraints forward to place and route.

Then:

```tcl
quit
```

---

## 8. Things that will bite you

**Synthesis is stateful.** If you change a constraint and re-run `compile` in
the same session, the result depends on the previous run. Sweeps done that way
are not reproducible. Either `remove_design -all` first, or quit and start a
fresh `dc_shell` for every data point. The shipped script starts with
`remove_design -all` for exactly this reason.

**Redirect the output.** Every command takes `>`:

```tcl
report_timing > reports/timing.rpt
```

Keep the logs. When a result surprises you three days later, the log is the
only thing that can explain it.

**`analyze` order matters.** Packages before their users, always.

---

## 9. Now put it in scripts

You have run the flow by hand. From here on, do not: type it once more into a
file and run the file. Every result you report has to be reproducible, and the
only reproducible thing is a script.

The scripts are already in `scripts/`, and they are the flow above, in order:

| file | what it holds |
|------|---------------|
| `dc_script.tcl` | the library setup of §1 and the flow itself: read → elaborate → constrain → compile → report → write |
| `analyze_sources.tcl` | the `analyze` commands of §2, in dependency order |
| `set_constraints.tcl` | the constraints of §4, with the clock period as a variable |

The libraries live at the top of `dc_script.tcl` rather than in a separate
file, for the reason given in §0: this way the same setup applies whether you
run the script by hand or through FuseSoC.

Run them standalone exactly as the course notes describe — the script is a
text file of shell commands, and `dc_shell` takes it with `-f`:

```bash
dc_shell-xg-t -f scripts/dc_script.tcl > synth.log
```

or, from inside `design_vision`:

```tcl
source scripts/dc_script.tcl
```

### Driving Design Compiler from FuseSoC

Typing the file list into `analyze_sources.tcl` by hand works, and it stops
working the moment you add a source file, or a dependency, or change an IP
version — the simulation file list and the synthesis file list drift apart,
and you synthesise something you never simulated.

FuseSoC already knows the file list: it is the same `.core` dependency tree
that `make sim` uses. The `synth` target in `lab1/cordic_accel.core` points
Design Compiler at it:

```yaml
  synth:
    <<: *default
    default_tool: design_compiler
    filesets: [rtl, tech-sg13g2]
    toplevel: cordic_accel
    tools:
      design_compiler:
        script_dir: ../../../implementation/design_compiler/scripts
        dc_script: dc_script.tcl
        report_dir: ../../../implementation/design_compiler/reports
        libs: dw_foundation.sldb
```

Note what is *not* there: the technology library. edalize would write it into
the project TCL it generates, but `dc_script.tcl` is sourced afterwards and
sets the full library list itself — it has to, because it also picks the
corner and compiles the `.db`. One place decides, and it is the script.

and the Makefile wraps it:

```bash
make synth                                    # from lab1/
make synth CLK_PERIOD=3.0                     # tighten the constraint
make synth SG13G2_CORNER=typ_1p20V_25C        # a different corner
make synth IHP_PDK_ROOT=/where/the/pdk/is     # a different PDK location
```

What actually happens: FuseSoC resolves the dependency tree, generates
`<core>-read-sources.tcl` containing exactly the `analyze` commands of §2 —
derived from the `.core`, so it cannot drift — pre-defines `TOP_MODULE`,
`SCRIPT_DIR`, `REPORT_DIR` and `READ_SOURCES`, and starts `dc_shell` on
`dc_script.tcl`. The script notices `READ_SOURCES` is defined and uses the
generated list instead of `analyze_sources.tcl`; run standalone, it falls back
to the hand-written one. Same script, same result, one source of truth for the
file list.

Two consequences worth understanding:

- `dc_shell` runs in `build/isa_lab1_cordic_accel_0.1.0/synth-design_compiler/`,
  not here. That is why every path in the `.core` climbs three directories,
  and why a `.synopsys_dc.setup` would be useless: it is only read from the
  start-up directory. `dc_script.tcl` sets the libraries itself.
- FuseSoC also passes `target_library` and `libs` to the tool, and edalize
  writes them into the project TCL it generates. `dc_script.tcl` is sourced
  after that and sets the full library list, so its values win. Keep the two
  in step anyway — a reader should not have to know which one loses.
- The reports and the netlist still land in this directory, because the paths
  point back here. `make synth-clean` removes them.

Sweeping the clock is now one line:

```bash
for p in 8.0 6.0 5.0 4.0 3.0 2.5; do make synth CLK_PERIOD=$p; done
```

which is the point of having a script at all.

---

## 10. If your design contains a memory

The accelerator as shipped has no SRAM: its angle FIFO is `fifo_v3`, which is
flip-flops. If you add a scratchpad — a line buffer, a coefficient store, a
result buffer — this section applies to you.

In simulation a memory is a behavioural model: `tc_sram` from
`tech_cells_generic`, an array in SystemVerilog. **It is not something to
synthesise.** A synthesis tool handed that model will either fail or, worse,
succeed and build you a few thousand flip-flops — a 1024×32 array as
registers is roughly 32 kbit of flops plus the decoding, tens of times the
area of the macro and nowhere near its speed.

A real SRAM is a hard macro that comes with the PDK. SG13G2 has a generous
set of them in `$IHP_PDK_ROOT/libs.ref/sg13g2_sram/`:

| | single port | dual port |
|---|---|---|
| names | `RM_IHPSG13_1P_<words>x<bits>_…` | `RM_IHPSG13_2P_<words>x<bits>_…` |
| sizes | 64×16 up to 8192×32 | 64×22 up to 1024×32 |
| extras | most with bit-mask (`bm`) and BIST | same |

and each ships what every tool in the flow needs:

| file | in | used by |
|------|----|---------|
| `lib/RM_…_typ_1p20V_25C.lib` | Liberty timing | Design Compiler, timing analysis |
| `lef/` | abstract: pins, blockages, size | Innovus, place and route |
| `verilog/` | behavioural model | simulation |
| `gds/`, `cdl/` | layout and netlist | tape-out, LVS |

The same rule as the clock gate, and for the same reason: **one module name,
two implementations, the build picks one.** This is exactly what X-HEEP does
— `hw/simulation/sram_wrapper.sv` uses `tc_sram`, `hw/asic/sky130/sram_wrapper.sv`
instantiates the technology macro, both define `sram_wrapper` with identical
ports, and the `.core` selects a fileset per target.

**The wrapper is already written.** Both halves of it, next to the clock
gate:

| file | instantiates | for |
|------|--------------|-----|
| `implementation/tech/generic/sram_wrapper_generic.sv` | `tc_sram` | simulation |
| `implementation/tech/sg13g2/sram_wrapper_sg13g2.sv` | `RM_IHPSG13_1P_1024x32_c2_bm_bist` | synthesis |

Same module name, `sram_wrapper`, same ports: single port, one-cycle read
latency, byte enables. Read both before you use either — the SG13G2 one has
a size assertion that fails loudly if you ask for a configuration it has no
macro for, and a comment explaining why `A_DLY` is tied high (the PDK's own
model refuses to run otherwise).

`cordic_accel.core` already carries them, in two filesets that **no target
currently uses**, because the accelerator as shipped has no SRAM:

```yaml
  mem-generic:
    files: [implementation/tech/generic/sram_wrapper_generic.sv]   # -> tc_sram
    depend: [pulp-platform.org::tech_cells_generic]

  mem-sg13g2:
    files: [implementation/tech/sg13g2/sram_wrapper_sg13g2.sv]     # -> RM_IHPSG13_1P_…
```

So the moment you instantiate `sram_wrapper` in your RTL, there are exactly
two things to do: pick a macro in `sram_wrapper_sg13g2.sv`, and add one
fileset to each target —

```yaml
targets:
  sim:        { filesets: [rtl, tech-generic, mem-generic, tb] }
  sim_questa: { filesets: [rtl, tech-generic, mem-generic, tb] }
  lint:       { filesets: [rtl, tech-generic, mem-generic] }
  synth:      { filesets: [rtl, tech-sg13g2,  mem-sg13g2] }
```

Two more things the synthesis needs, both in `scripts/dc_script.tcl`:

- **the macro's timing.** Compile its Liberty the same way the standard cells
  are compiled and append the `.db` to `link_library` — the `MACRO_DBS` list
  is there for exactly this. Do **not** put it in `target_library`: the
  synthesizer must not invent new memories, only use the one you
  instantiated. It becomes a black box, and shows up on the "macro" line of
  `report_area`.
- **the corner has to match.** Standard cells at slow, macro at slow. Mixing
  a typical memory with slow logic produces a timing report that is fiction.

And the rule that outranks all of it: **simulate the configuration you
synthesise.** Swap the wrapper, then re-run `make sim` against the model that
corresponds to the macro you picked — same word count, same width, same
read latency. A netlist that passes because it was built from a model you
never simulated is not a result.

---

## 11. Where this goes next

The netlist is not the end of the flow. Two directories next to this one
take it further, and both expect you to have run `make synth` first.

**`../innovus/` — place and route.** Turn the netlist into a layout: cells
in rows, a power grid, a real clock tree, wires on seven metal layers, and
a GDS. Same shape as this page: work through it in the GUI one command at a
time, then run the scripts. It is where the clock stops being ideal and
where the wire capacitance stops being a guess.

```bash
make pnr          # from lab1/, after make synth
```

**`../power_analysis/` — what does it actually burn.** The `report_power`
number above is an estimate from a default toggle rate; it is the same
whether your accelerator is running flat out or idle. Simulate the netlist
doing the real work in QuestaSim, record the switching activity, and hand
it to PrimePower.

```bash
make power        # from lab1/, after make synth
```

That is also where §5c stops being an argument and becomes a measurement:
synthesise with and without `-gate_clock`, run both, and read the
difference in watts.

---

## 12. Where this is all going

Nothing in this lab uses the IO library. The full-chip lab does: pads from
`$IHP_PDK_ROOT/libs.ref/sg13g2_io/` (4 mA, 16 mA and 30 mA drive, plus power
and ground pads), a pad ring around the core, and the core-to-pad level shift
between the 1.2 V logic and the 3.3 V outside world. That is why the PDK for
this course is SG13G2 and not a standard-cell-only academic library: cells,
memories and pads all come from the same kit, characterised together, so the
flow you learn here runs all the way to something that could be taped out.

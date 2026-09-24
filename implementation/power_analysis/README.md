# Post-synthesis power analysis: QuestaSim + Synopsys PrimePower

Measure what the accelerator actually burns, running the actual workload,
on the actual netlist.

You have already seen a power number: `report_power` at the end of
synthesis. This page is about why that number is not an answer, and what to
do instead.

Everything below is run from **this directory**
(`lab1/implementation/power_analysis/`).

---

## 0. Why the synthesis number is not enough

Dynamic power is

```
    P_dyn  =  alpha * C * V² * f
```

Three of those four terms the tools know exactly. `C` comes from the
netlist and the library. `V` and `f` you chose.

`alpha` — how often each node actually toggles — cannot be derived from a
netlist at all. It depends on the *data*. A CORDIC rotating 64 angles and a
CORDIC sitting idle are the same gates with the same capacitance, and their
power differs by two orders of magnitude.

So Design Compiler guesses. It propagates a default toggle rate from the
inputs and reports the result. That guess is the same whether your
accelerator is busy or idle, which tells you what it is worth.

**The fix is to measure `alpha` instead of guessing it.** Simulate the
netlist doing the real work, write down every transition, and hand that file
to a tool that knows what each cell costs per transition.

> **Known limitation, read before you report a number.** The post-synthesis
> run here is done at **zero delay**: back-annotating the Design Compiler SDF
> onto this netlist annotates cleanly and then makes the testbench's
> self-check fail, for reasons not yet understood (it is not the clock
> period — it fails identically at 10 ns and 50 ns). Without delays there are
> no glitches, so **glitch power is missing and the total is a lower bound**.
> Everything else — every real transition, from a real workload — is there.
> The accurate figure is the post-layout one in §8. `set USE_SDF 1` opts in
> if you want to investigate.

```
   synthesis                  simulation                  power analysis
  ┌───────────┐              ┌───────────┐               ┌────────────┐
  │    DC     │─ netlist.v ─▶│ QuestaSim │── design.vcd ─▶│ PrimePower │
  │           │─ netlist.sdf▶│  + cells  │               │  + .db     │─▶ W
  │           │─ netlist.sdc──────────────────────────────▶            │
  └───────────┘              └───────────┘               └────────────┘
```

Three terms come out, and they are different things:

| | what it is | scales with |
|---|---|---|
| **switching** | charging and discharging each net's load capacitance | activity |
| **internal** | burned inside a cell when it switches: short-circuit current while both stacks conduct, plus internal nodes | activity |
| **leakage** | current through transistors that are off | **time**, not activity |

Leakage is the one to think about. It is paid every second the block is
powered, whether or not it does anything. All the clock gating in §5c of the
synthesis README does exactly nothing for it. Only cutting the supply does —
and that is power gating, which is a different mechanism with a much larger
cost.

---

## 1. Before you start

**Source the EDA setup:**

```bash
source /eda/scripts/init_design_vision
```

This puts `pt_shell` (or `pwr_shell`), `vcd2saif` and friends on your PATH.
You also need `vsim`.

**You need a synthesised design.** From `lab1/`:

```bash
make synth
ls implementation/design_compiler/netlist/
# cordic_accel.v  cordic_accel.sdf  cordic_accel.sdc
ls implementation/design_compiler/db/
# sg13g2_stdcell_slow_1p08V_125C.db
```

All four are used here. The `.db` cache is the same one the synthesis built
— reusing it is not just convenient, it is one fewer thing that can
silently differ between the two analyses.

**Build the typical-corner `.db` as well**, because that is the corner you
want power at (§4):

```bash
make synth SG13G2_CORNER=typ_1p20V_25C
```

---

## 2. The whole thing, in one command

```bash
cd implementation/power_analysis
./run_pwr_flow.sh
```

or from `lab1/`:

```bash
make power
```

Then read `reports/cordic_accel_power.rpt`.

The rest of this page is what that script does, one step at a time, because
each step has a way of going quietly wrong.

---

## 3. Step 1 — gate-level simulation, recording switching activity

`questa/gate_sim.do`, or by hand from this directory.

Three things make this a *post-synthesis* simulation rather than an RTL one,
and all three matter:

**1. The netlist, not the RTL.** Obvious, and the point.

```tcl
vlib work
vlog -work work ../design_compiler/netlist/cordic_accel.v
```

**2. The library's Verilog cell models**, so each gate behaves like the cell
it is:

```tcl
vlog -work work $IHP_PDK_ROOT/libs.ref/sg13g2_stdcell/verilog/sg13g2_stdcell.v
```

You can also compile these once into a resource library and link it with
`vsim -L`. Either works; compiling them into `work` each time costs a few
seconds on a library this size and removes a version-skew failure mode.

**3. The SDF, so each gate takes as long as the cell takes:**

```tcl
vsim -t 1ps -sdftyp /tb_cordic_accel/i_dut=../design_compiler/netlist/cordic_accel.sdf \
     work.tb_cordic_accel
```

Drop the SDF and every gate switches at the same instant. The **glitches
disappear** — and with them a real part of the dynamic power. A glitch is a
node that transitions and then transitions back because its inputs arrived
at different times; it does no work and it costs the full `C·V²`. In an
arithmetic datapath with a long carry chain, like a CORDIC rotator, glitch
power can be a fifth of the total. A zero-delay simulation reports none of
it.

> The path on the left of the `=` is the **instance in the testbench**, not
> the module name. Get it wrong and Questa annotates nothing and says so
> only in a warning you will scroll past.

**Expected warnings**, both harmless:

- `Too few port connections for '...'. Expected 5, found 4.` /
  `Missing connection for port 'QN'.` — a flip-flop whose inverted output
  nobody uses. Design Compiler left it unconnected.
- `negative timing check limit ... forced to zero` — usually a `RECOVERY`
  arc on the asynchronous reset: the SDF says the minimum time between reset
  release and the next clock edge is negative, and Questa clamps it.

**The same testbench as `make questa`.** `tb/tb_cordic_accel.sv` is the same
file, driving the same stimulus, checking the same golden vectors. That is
the point: if the gate-level run does not also print `TEST PASSED`, the
netlist is wrong and any power number from it is meaningless.

Two things in it exist for this flow:

- `+define+GATE_LEVEL` makes the testbench instantiate the DUT **without a
  parameter override**. Synthesis resolved every parameter; the netlist is
  one fixed module with no parameter ports, and overriding a parameter a
  module does not have is an elaboration error. The defaults in
  `cordic_accel_types_pkg` are exactly the values the RTL branch passes, so
  the two builds are the same configuration.
- `ClkPeriodPs` is a parameter, so the run can be done at the frequency the
  design was synthesised for: `vsim -g/tb_cordic_accel/ClkPeriodPs=5000`.
  Power scales with frequency. Measuring a block at 100 MHz that was
  constrained at 200 MHz halves the dynamic power and answers nothing.

**Recording the activity:**

```tcl
vcd file vcd/cordic_accel_syn.vcd
vcd add -r /tb_cordic_accel/i_dut/*
run -all
```

A VCD lists every transition of every signal in the given scope with a
timestamp. Verbose, completely general, and read by both PrimePower and
Innovus.

**The scope is the DUT and below — not the testbench.** The behavioural
memory model and the bus drivers do not exist in silicon, and their toggling
is not your power.

**The simulation must cover the workload and stop.** The testbench calls
`$finish` when it is done, so `run -all` ends with the last checked result.
If instead you `run 2 us` and the design finishes at 1 µs, the last
microsecond is idle time recorded as part of the measurement, and the
average power comes out low. One fix is an `END_SIM_i` signal that stops
the clock; this testbench solves it by finishing.

---

## 4. Step 2 — power analysis in PrimePower

`scripts/pwr_script.tcl`. PrimePower is a mode of PrimeTime, so it runs in
`pt_shell` (some installations ship `pwr_shell`, the same binary with the
power licence pre-selected).

```tcl
set power_enable_analysis        true
set power_enable_timing_analysis true
set power_analysis_mode          averaged
```

`averaged` gives one number for the whole simulation. The alternative,
`time_based`, gives a waveform of power against time — that is how you find
the *peak*, which is what an IR drop or a decap budget needs. Much slower.

```tcl
read_db    $target_library
read_verilog $NETLIST
current_design cordic_accel
link_design
read_sdc   ../design_compiler/netlist/cordic_accel.sdc
```

**`current_design` explicitly.** `-gate_clock` put clock gating modules in
the netlist alongside the design, so more than one module is a candidate
top. The switching activity is annotated relative to whatever is current.

**Read the SDC.** Power is energy per unit time, and without a clock period
PrimePower does not know what "per unit time" means.

**Then the activity — and this is the step that goes wrong:**

```tcl
read_vcd $VCD_FILE -strip_path tb_cordic_accel/i_dut
```

`-strip_path` removes the part of the hierarchy that exists only in the
testbench. The VCD calls an instance `tb_cordic_accel/i_dut/<something>`;
the netlist calls it `<something>`. Strip the prefix and they line up.

**Get it wrong and nothing fails.** `read_vcd` succeeds, annotates zero
nets, and `report_power` silently falls back to the default toggle rate —
the very guess you came here to replace. You get a plausible-looking number
that is the synthesis estimate wearing a different hat.

There is exactly one way to know which happened:

```tcl
report_switching_activity -list_not_annotated -show_pin
```

**Read it.** A handful of unannotated pins is normal (tie cells, unused
outputs). A design's worth of them means the strip path is wrong.

Then:

```tcl
update_power
report_power -nosplit
report_power -nosplit -hierarchy
report_power -nosplit -cell_power -leaf
report_clock_gating -nosplit
```

---

## 5. Which corner, and why it is not the one you signed timing off at

| | corner | why |
|---|--------|-----|
| timing sign-off | slow, 1.08 V, 125 °C | worst case for **speed** |
| **power** | **typ, 1.20 V, 25 °C** | what the chip actually does |

Using the slow corner for power gets both terms wrong, in opposite
directions:

- **dynamic** goes as `V²`, so 1.08 V instead of 1.20 V **under**-reports it
  by about 20 %.
- **leakage** roughly doubles every 10 °C, so 125 °C instead of 25 °C
  **over**-reports it by a large factor.

Neither is the chip on a desk. Report typical, and say in your report that
that is what you did. `scripts/set_libs.tcl` selects it with
`ANALYSIS_MODE`.

---

## 5b. What the shipped design gives

So you know what a working run looks like, at 100 MHz on the typical corner:

```
  Net Switching Power  = 4.347e-04   (53.49%)
  Cell Internal Power  = 3.775e-04   (46.45%)
  Cell Leakage Power   = 4.613e-07   ( 0.06%)
                         ---------
Total Power            = 8.127e-04  (100.00%)
```

and by group:

| group | share |
|-------|-------|
| combinational | 52 % |
| **clock network** | **34 %** |
| register | 14 % |
| leakage | 0.06 % |

with `report_switching_activity` showing **2577 of 2577 nets (100 %)
annotated from the activity file** — which is the line that says the flow
actually worked.

Two observations to carry into your report:

**The clock network is a third of the power**, and this is the *synthesis*
netlist, whose clock is still ideal. After place and route there is a real
clock tree with real buffers and it gets bigger. Fine-grained clock gating
does not reduce it: the gates hang off the tree's leaves and the tree keeps
toggling above them. Only stopping the clock at the root does — §5c of the
synthesis README, now with a number attached.

**Leakage is 0.02 %.** At 130 nm, at 25 °C, static power is a rounding
error, and every watt worth chasing is dynamic. That is a property of this
node, not a general truth — the same block at 16 nm would tell a very
different story, and it is why power gating exists.

---

## 6. Reading the reports

`reports/cordic_accel_power.rpt` — the total, split three ways. This is the
number for your report, with the corner and the clock frequency next to it.
A power figure without both is not a measurement.

`reports/cordic_accel_hier.rpt` — the same, per level of hierarchy. Where
does it go? In this accelerator, expect the rotator (`i_cordic`) and the
angle FIFO to dominate, with the CSR block negligible. If something else
dominates, that is the interesting result.

`reports/cordic_accel_leaf.rpt` — per cell. Long, and the only way to find
the single net responsible for a surprise.

`reports/cordic_accel_clock_gating.rpt` — how many registers are gated and
how many are not. Every ungated enable-driven register is dynamic power you
are paying for nothing.

`reports/cordic_accel_not_annotated.rpt` — what the VCD did **not** cover.
Check this first, every time.

`reports/cordic_accel_power.csv` — the same numbers per cell, for a plot.

---

## 7. The experiment worth doing

You now have a way to measure the effect of a design decision instead of
arguing about it. The obvious one, and the one §5c of the synthesis README
sets up:

```bash
cd ../..

# 1. as shipped: tool clock gating on
make synth SG13G2_CORNER=typ_1p20V_25C
(cd implementation/power_analysis && ./run_pwr_flow.sh)
cp implementation/power_analysis/reports/cordic_accel_power.rpt /tmp/with_cg.rpt

# 2. edit scripts/dc_script.tcl: compile_ultra  (drop -gate_clock)
make synth SG13G2_CORNER=typ_1p20V_25C
(cd implementation/power_analysis && ./run_pwr_flow.sh)
diff /tmp/with_cg.rpt implementation/power_analysis/reports/cordic_accel_power.rpt
```

Then the one that actually matters. The workload above runs the accelerator
flat out. Real ones do not: an accelerator is idle most of the time. Write a
second testbench run that starts one kernel and then does nothing for ten
times as long, measure that, and compare it with the same idle period with
the block's clock stopped at the root.

The ratio between those two numbers is the argument for peripheral-level
clock gating, in watts, from your own design. It will be much larger than
the `-gate_clock` difference above — and that is the point §5c was making.

---

## 8. After place and route

Everything above this section uses the **synthesis** netlist: an ideal clock
with no tree in it, capacitance estimated from a wireload model, and a
zero-delay simulation, so no glitches. Three things missing, all of which
cost power.

Once `../innovus/` has run, measure again on what was actually built:

```bash
make power-postlayout     # from lab1/
```

or, by hand from this directory:

```bash
./run_pwr_flow.sh --postlayout
```

Three inputs change, and `--postlayout` switches all of them together:

| | `make power` | `make power-postlayout` |
|---|---|---|
| netlist | `design_compiler/netlist/<top>.v` | `innovus/artefacts/export/<top>_pnr.v` |
| delays | none (see §3) | `<top>_pnr.sdf`, annotated |
| capacitance | wireload estimate | `<top>_pnr.spef`, extracted from the routed wires |
| clock tree | not in the netlist | in the netlist |

Nothing is overwritten: the VCD is `vcd/<top>_pnr.vcd`, the reports are
`reports/<top>_pnr_*.rpt`. Run both and compare -- that difference is what
place and route cost you, and it is the interesting number for your report.

On the shipped CORDIC at 10 ns, typical corner:

```
                     post-synthesis   post-layout
clock_network            33.6 %           28.5 %
register                 13.4 %           13.8 %
combinational            53.0 %           57.8 %
Total                  0.821 mW         1.172 mW
```

43 % more power after layout, and none of it is a mistake: the clock tree is
real, the wires are real, and the SDF lets the glitches happen. Quote the
post-layout number, and say which one it is.

Two things to know before you read the numbers:

* **The corner is `typ_1p20V_25C`, not the slow corner timing was signed off
  at** -- see §5. `make power` and `make power-postlayout` both compile that
  Liberty into `design_compiler/db/` the first time they need it, with
  `lc_shell`; synthesis only caches the corner it ran at.
* **Innovus writes `current_design <top>` at the top of its SDC and
  PrimeTime refuses it** (`CMD-012`), stopping the SDC read at line 8 --
  which leaves the design with no clock and reports `clock_network` as
  0.0000 W. `scripts/init.tcl` strips that one line into
  `reports/<top>_pnr.sdc.pt` and reads the rest. If you write a post-layout
  flow of your own elsewhere, this will bite you.

Innovus can also do the power analysis itself, from the same VCD -- *Power →
Power Analysis → Setup*, then *Run*, with the VCD and the scope
`/tb_cordic_accel/i_dut`. Same input, same physics, different tool. Running both and
comparing is a good use of an afternoon.

---

## 9. Layout

```
power_analysis/
├── run_pwr_flow.sh          simulate, then analyse. Start here.
├── questa/
│   └── gate_sim.do          gate-level sim + SDF + VCD recording
├── scripts/
│   ├── pwr_script.tcl       the PrimePower flow
│   ├── init.tcl             read libraries, netlist, constraints, SPEF
│   ├── set_libs.tcl         which .db, which corner
│   └── gen_pwr_csv.tcl      per-cell CSV dump
├── vcd/                     generated, large, gitignored
└── reports/                 generated
```

Same shape as the SoC flow's `implementation/power_analysis/`, which is
where `gen_pwr_csv.tcl` comes from unchanged.

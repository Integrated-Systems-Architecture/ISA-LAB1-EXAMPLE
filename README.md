# Lab 1 — Standalone accelerator: RTL, synthesis, layout, power

MSc lab, groups of 3. Second of four activities: you take the kernel you chose
in Lab 0 and build it as real hardware, all the way from a golden model to a
placed-and-routed block with a measured power number.

| | | |
|---|---|---|
| Lab 0 | profile the provided apps and work out which kernel is worth accelerating | |
| **Lab 1** | implement the accelerator standalone, simulate it, synthesise it, place and route it, measure its power | *this directory* |
| Lab 2 | optimize it (retiming, pipelining, folding, arithmetic) and compare PPA with Lab 1 | |
| Lab 3 | integrate it into X-HEEP over OBI+REG, write the C driver, measure the real speedup | |

Lab 0 ended with a *candidate*. Lab 1 ends with **numbers**: a maximum
frequency, an area in µm², and a power figure in mW at a stated corner and
frequency. Lab 2 only means something because Lab 1 produced a baseline to
compare against, so measure carefully and write down how you measured.

## Start here

1. **[SETUP.md](SETUP.md)** — the two toolchains. On the **ISA server** both are
   installed: source three scripts and you are done. On your own machine you can
   do the RTL half only — synthesis, place and route and power need licences
   that live on the server.
2. **[TUTORIAL.md](TUTORIAL.md)** — a guided run of the whole flow on the
   accelerator that ships here, with the output you should see at each stage.
3. **The assignment is not here.** This directory is the worked reference, not
   your work. What you must build and hand in is in the lab1 template:
   [ASSIGNMENT.md](../lab1/ASSIGNMENT.md) and [REPORT.md](../lab1/REPORT.md).
   *(`TODO.md` in this tree is a leftover describing the older matmul example
   — ignore it.)*

## The whole flow, in order

Everything below runs on the **ISA server** (`ssh -X isa`). Copy it a line at a
time and read what comes back; every stage prints where it put its output.

```bash
# --- once per shell: the environments -------------------------------------
source /oss-tools/init.sh                    # python, fusesoc, verilator, klayout, $IHP_PDK_ROOT
source /eda/scripts/init_design_vision       # dc_shell, lc_shell, pt_shell/pwr_shell
source /eda/scripts/init_cadence_2020-21     # innovus   -- 2020-21, NOT 2021-22
source /eda/scripts/init_questa_core_prime   # vsim

# --- once per clone --------------------------------------------------------
make vendor          # fetch common_cells, tech_cells_generic, register_interface, obi
make regs            # reggen: data/cordic_accel.hjson -> CSR block + C header

# --- RTL -------------------------------------------------------------------
make sim             # Verilator, self-checking        -> TEST PASSED
make questa          # QuestaSim, the same testbench   -> TEST PASSED

# --- silicon ---------------------------------------------------------------
make synth           # Design Compiler  -> netlist, area, f_max        (~2 min)
make pnr-all         # Innovus: route, then optimise in a 2nd session  (~7 min)
make power           # gate sim + PrimePower, synthesis netlist        (~3 min)
make power-postlayout # the same on the routed netlist + SDF + SPEF    (~4 min)

# --- look at it ------------------------------------------------------------
make gds             # KLayout on the final layout  (needs ssh -X)
make pnr-gui         # Innovus with the GUI open    (needs ssh -X)
make help            # every target, every knob, current values
```

Long runs survive a dropped connection only inside `tmux` — see
[SETUP.md](SETUP.md).

## Where the outputs land

No stage prints its reports to the terminal: FuseSoC captures the tool's
output, and every script writes files instead. This table is where to look.

| after | file | what it tells you |
|---|---|---|
| `make synth` | `implementation/design_compiler/reports/synth.log` | the **whole dc_shell transcript** — read this when synthesis misbehaves |
| | `.../reports/qor.rpt` | slack, area, cell count. Start here |
| | `.../reports/timing.rpt`, `timing_top10.rpt` | the critical path, and the ten worst |
| | `.../reports/area.rpt`, `power_estimate.rpt` | area by hierarchy; a *guessed* power number (see below) |
| | `.../netlist/cordic_accel.{v,sdf,sdc,ddc}` | the gate-level netlist and its timing |
| `make pnr-all` | `implementation/innovus/artefacts/reports/08_export.*` | final setup and hold timing, DRC, gate count |
| | `.../artefacts/export/cordic_accel_pnr.{v,sdf,spef,sdc}` | the routed design, for the power run |
| | `.../artefacts/export/cordic_accel.gds` | the layout |
| | `.../artefacts/innovus.log`, `pnr_opt.log` | the two Innovus sessions |
| `make power` | `implementation/power_analysis/reports/cordic_accel_power.rpt` | switching / internal / leakage, post-synthesis |
| `make power-postlayout` | `.../reports/cordic_accel_pnr_power.rpt` | the same, post-layout — **this is the one to report** |
| | `.../reports/*_not_annotated.rpt` | how much of the design the VCD actually covered. Read it |

They are all gitignored. That is why `git status` stays clean after a run and
why your editor may hide them — the files are there.

## What ships here, and why it already works

Unlike Lab 0, **nothing in this directory is a stub**. A complete CORDIC
accelerator is provided, and the whole flow closes on it: it simulates, it
synthesises, it places and routes, and it reports power.

That is deliberate. When you replace the RTL with your own and something
breaks, you want to know it was your RTL and not the flow. Run the tutorial
end to end first, on hardware you did not write.

The example is the CORDIC rotator from the *Example Cookbook*, wrapped in the
interface an accelerator actually needs:

```
     REG_BUS (CSRs)                    OBI (data)
         │                                  │
         ▼                                  ▼
   ┌──────────────┐   ┌───────────┐   ┌────────────┐
   │  CSR block   │──►│  control  │◄─►│    OBI     │
   │  (reggen)    │   │    FSM    │   │  manager   │
   └──────────────┘   └─────┬─────┘   └────────────┘
                            │
              ┌─────────────▼──────────────┐
              │  clock gate ─► cordic_rot  │
              └────────────────────────────┘
```

Configuration goes through **CSRs** — generated by `reggen` from
`data/cordic_accel.hjson`, the same way every X-HEEP peripheral does it. Data
goes over **OBI**, because a stream of angles does not belong in registers.
That split is the interface contract Lab 3 will plug into, and it is worth
copying even if your kernel is nothing like a CORDIC.

## The four stages, and what each one is for

Each has its own README, and those are the real documentation — long, and
written to be worked through one command at a time in the tool's own shell
before you ever run the scripts.

| stage | directory | what comes out | needs |
|-------|-----------|----------------|-------|
| **simulate** | `tb/`, `model/` | `TEST PASSED` | Verilator, QuestaSim |
| **synthesise** | [`implementation/design_compiler/`](implementation/design_compiler/README.md) | netlist, f_max, area | Design Compiler |
| **place & route** | [`implementation/innovus/`](implementation/innovus/README.md) | layout, GDS, real timing | Innovus |
| **power** | [`implementation/power_analysis/`](implementation/power_analysis/README.md) | watts | QuestaSim + PrimePower |

```bash
make sim              # Verilator, self-checking
make questa           # QuestaSim, same testbench
make synth            # Design Compiler         (server only)
make pnr-all          # Innovus, route + opt    (server only)
make pnr-gui          # the same with the GUI   (server only, needs ssh -X)
make power            # gate sim + PrimePower, synthesis netlist (server only)
make power-postlayout # the same on the routed netlist          (server only)
make gds              # KLayout on the layout   (server only, needs ssh -X)
```

Every stage's scripts are split **one file per step**, so you can change the
floorplan without touching the routing, or retry CTS without redoing
placement. That is not tidiness — it is what makes a sweep take an afternoon
instead of a week.

## The technology: IHP SG13G2

A real 130 nm open PDK, not an academic cell library: standard cells, SRAM
macros and IO pads, all characterised together. Everything the flow knows
about silicon comes from it.

```
$IHP_PDK_ROOT/libs.ref/
├── sg13g2_stdcell/   lib/ lef/ gds/ verilog/ cdl/ doc/
├── sg13g2_sram/      1-port and 2-port macros, 64x16 up to 8192x32
├── sg13g2_io/        pads, 1.2 V core <-> 3.3 V outside
└── sg13g2_pr/        place-and-route technology files
```

Cell names read as `sg13g2_<function>_<drive>`: `sg13g2_nand2_1`,
`sg13g2_buf_4`, flip-flops `sg13g2_dfrbp_1`, the integrated clock gates
`sg13g2_lgcp_1` and `sg13g2_slgcp_1`. Inputs are `A`, `B`, …; outputs are `X`.
Open `sg13g2_stdcell/doc/` and skim the cell list before you read your first
`report_area` — a netlist is a list of these names.

Three PVT corners matter and they are not interchangeable:

| corner | use for |
|--------|---------|
| `slow_1p08V_125C` | **setup sign-off** — the slowest silicon you may get |
| `typ_1p20V_25C` | exploring, and **power** — see below |
| `fast_1p32V_m40C` | **hold** — data racing through fast silicon |

A frequency you report from the typical corner is a frequency you cannot
promise. A *power* number from the slow corner is equally wrong, in both
directions at once: 1.08 V under-reports dynamic power by ~20 %, and 125 °C
over-reports leakage by a large factor.

## One idea that runs through the whole lab

**One module name, two implementations, the build picks one.**

A clock gate written in RTL is an `always_latch` and an AND. Perfect to
simulate; catastrophic to synthesise — the tool builds a latch out of standard
cells, ANDs its output with the clock, and hands you a clock net with a
combinational gate in it. So the design instantiates `tc_clk_gating`, and
`cordic_accel.core` gives it a different file per target:

```yaml
  tech-generic:    # sim   -> behavioural model from tech_cells_generic
  tech-sg13g2:     # synth -> implementation/tech/sg13g2/tc_clk_gating_sg13g2.sv
```

The same pattern is already in place for memories (`sram_wrapper`, in
`implementation/tech/{generic,sg13g2}/`), unused until your accelerator wants a
scratchpad. There the stakes are higher: a synthesis tool handed a behavioural
`tc_sram` does not fail, it builds you the array out of flip-flops — a 1024×32
memory becomes 32 kbit of flops, tens of times the area of the macro. The
failure is silent, which is exactly why the wrapper exists.

X-HEEP does the same thing for the same reason. Recognise the pattern now; you
will need it in Lab 3.

## What the reports will actually say

For reference, the shipped accelerator on the ISA server, so you know roughly
what "working" looks like:

| | |
|---|---|
| RTL simulation | 64 angles, 2 runs, bit-exact against the Python model |
| synthesis | slack **MET** at 10 ns (100 MHz), slow corner |
| cells | 2483 standard cells, 450 flip-flops |
| clock gates | 1 architectural (around the rotator) + 18 inserted by `-gate_clock` |
| place and route | core 261.6 × 260.8 µm at 60 % utilisation, 8050 gates, 43 821 µm² |
| final timing | setup **+0.259 ns**, hold **−0.002 ns**, **0 DRC violations** |
| power, post-synthesis | **0.821 mW** at 100 MHz, typ corner |
| power, post-layout | **1.172 mW** — same workload, same corner, real clock tree and real wires |

And the one number worth arguing about, from the power breakdown:

| | post-synthesis | post-layout |
|---|---|---|
| combinational | 53 % | 58 % |
| **clock network** | **34 %** | **28 %** |
| registers | 13 % | 14 % |
| leakage | 0.06 % | 0.04 % |

43 % more total power after place and route, and none of it is an error: the
clock tree is real, the wires have real capacitance, and the SDF lets glitches
happen. Report the post-layout number and say that is what it is.

A third of this block's power is the clock network — and that is *before*
place and route builds a real clock tree, which only makes it bigger. No
amount of fine-grained clock gating removes it, because the gates hang off
the tree's leaves and the tree keeps toggling. Turning the block's clock off
at the root does remove it. That is §5c of the synthesis README, measured.

Your own accelerator will differ, and that is the point. Report the numbers
you measured, with the corner and the clock period next to them.

## When it breaks

Every entry here is a failure someone has actually hit on this flow, with the
message it prints. Read the message first; the tools are not subtle, they are
just quiet about where they wrote it.

**"Synthesis printed nothing / where is the log?"**
FuseSoC captures the tool's stdout, so `make synth` shows only `INFO: Running`.
The full dc_shell transcript is `implementation/design_compiler/reports/synth.log`
(48 kB of it). `build/*/synth-design_compiler/command.log` is Design Compiler's
command echo, not the run log. Both are gitignored, so `git status` and a
gitignore-aware editor will not show them.

**`cannot find .../sg13g2_stdcell_slow_1p08V_125C.lib -- is IHP_PDK_ROOT set correctly?`**
The PDK is not where the scripts expect. `source /oss-tools/init.sh` exports
`IHP_PDK_ROOT`; check with `ls $IHP_PDK_ROOT/libs.ref/sg13g2_stdcell/lib/`.
Synthesis now **stops** on this. It used to continue, silently mapping to
Design Compiler's built-in `gtech` library and producing a full set of reports
with zero area and meaningless slack — if you ever see `**SEQGEN**` or
`*ADD_UNS_OP*` in `reference.rpt`, that is what happened.

**`make synth` says nothing failed but there is no netlist**
It does fail now: the target checks for the netlist and stops. The reason the
check has to exist is that edalize pipes dc_shell into `tee`, and a pipeline's
exit status is `tee`'s, which is always 0.

**Innovus dies immediately: `*** CRASHED *** [signal 11]`**
You sourced `init_cadence_2021-22`. Innovus 21.1 needs AVX, and isaserver's
CPU (`QEMU Virtual CPU`, flags `sse4_2 popcnt` only) does not have it — it
segfaults right after the licence checkout, even on a two-line script. Use
`source /eda/scripts/init_cadence_2020-21`.

**`make pnr` finishes but hold is violated**
Expected: `make pnr` routes, `make pnr-opt` fixes hold in a **second** Innovus
session. `make pnr-all` does both. On 20.11 both `opt_design -post_route` and
`route_eco -fix_drc` fail in the session that did the routing — see the header
of `implementation/innovus/scripts/run_pnr_opt.tcl`. Even after `pnr-opt` the
shipped design ends at −0.002 ns hold on two paths.

**`missing .../sg13g2_stdcell_typ_1p20V_25C.db -- run make synth`**
Power analysis runs at the **typical** corner; synthesis only caches the corner
it synthesised at (`slow`). The Makefile now compiles that one Liberty with
`lc_shell` on demand (`$(PWR_DB)`), so this should no longer appear — if it
does, `lc_shell` is not on your `PATH`: `source /eda/scripts/init_design_vision`.

**Power report says `clock_network 0.0000 W`**
The SDC was not read, so PrimePower has no clock and no idea what "per second"
means. Post-layout this was Innovus writing `current_design <top>` at the top
of its SDC, which PrimeTime rejects (`Error: extra positional option`, CMD-012)
and then stops reading; `scripts/init.tcl` strips that line now. If it comes
back, read `pwr_shell_*.log` and look for `Errors reading SDC file`.

**`report_switching_activity` says large parts are not annotated**
The VCD scope or `-strip_path` is wrong, and PrimePower silently fell back to a
default toggle rate — the guess the whole flow exists to replace. The testbench
must instantiate the DUT as `i_dut`; check
`reports/*_not_annotated.rpt` before you believe any power number.

**`pt_shell_exec: error while loading shared libraries: libodbc.so.2`**
unixODBC is not installed on the machine. `run_pwr_flow.sh` symlinks the copy
that ships inside the VCS installation into `~/.local/eda-libs` and puts only
that one file on `LD_LIBRARY_PATH`. Do not put conda's `lib/` there instead —
the Synopsys tools then load conda's `libstdc++` and die with
`version CXXABI_1.3.15 not found`.

**`klayout: command not found`, or the layout opens in meaningless colours**
`source /oss-tools/init.sh` first. The colours come from the PDK's layer
properties, `$IHP_PDK_ROOT/libs.tech/klayout/tech/sg13g2.lyp`, which `make gds`
passes with `-l`; without it every layer is an anonymous number.

**Questa: `Module 'tb_cordic_accel' does not have a timeunit/timeprecision
specification in effect`**
Missing `-timescale 1ns/1ps`. The `sim_questa` target in the `.core` file and
`questa/gate_sim.do` both set it; a hand-rolled `vlog` will not.

**A gate-level simulation fails its self-check, RTL passes**
Post-synthesis, with the Design Compiler SDF annotated, this is a known
unresolved problem — which is why `make power` runs at zero delay and the
post-layout run (with the Innovus SDF) is the one that both annotates and
passes. See the long comment in `questa/gate_sim.do`.

## Tools you must understand (not just invoke)

You will be asked to explain these, not just show that you ran them:

- **FuseSoC** — resolves the `.core` dependency tree and drives Verilator,
  QuestaSim and Design Compiler from one file list, so the thing you
  synthesise is the thing you simulated.
- **reggen** — generates the CSR block and the C header from an hjson
  description. Lab 3's driver includes that header.
- **Design Compiler** — `analyze` → `elaborate` → constrain → `compile_ultra`.
  Understand why an unconstrained synthesis is meaningless.
- **Innovus** — floorplan → power → place → CTS → route → optimise → export.
  Understand why the clock stops being ideal at CTS and what that costs.
- **PrimePower** — turns simulated switching activity into watts. Understand
  why `report_power` after synthesis is not an answer.

## Reference material

Three kinds of reading. First, the **step-by-step guides in this repository** —
one per implementation stage, written to be worked through a command at a time
in the tool's own shell before you run the scripted version:

| | |
|---|---|
| [implementation/design_compiler/README.md](implementation/design_compiler/README.md) | libraries, constraints, `compile_ultra`, the reports, clock gating, memories, IO pads |
| [implementation/innovus/README.md](implementation/innovus/README.md) | floorplan, power grid, placement, CTS, routing, optimisation, export |
| [implementation/power_analysis/README.md](implementation/power_analysis/README.md) | the VCD, PrimePower, post-synthesis vs post-layout power |
| [TUTORIAL.md](TUTORIAL.md) | this accelerator through all of it, with the output at each stage |

Second, the **course cookbooks**, at
<https://github.com/Integrated-Systems-Architecture/ISA-BOOKS> (in the course
repository they are the `books/` submodule — `git submodule update --init
books`, sources and built PDFs).

| Question | Where |
|----------|-------|
| The CORDIC case study — golden model, VHDL, SystemVerilog, six testbenches | *Example Cookbook*, ch. 10 |
| Testbench structure, self-checking, UVM | *Verification Cookbook*, ch. 5–7 |
| Verilator, waveforms, self-checking testbenches | *Simulation Cookbook*, ch. 8 |
| `.core` files, FuseSoC, vendoring, reggen | *FuseSoC Cookbook*, ch. 1–4 |
| VHDL/SystemVerilog side by side, coding style | *Design Cookbook*, ch. 1–4 |
| git, tags and releases for the group | *Git Cookbook*, ch. 1–3 |

Third, the **technology's own documentation** — the standard cell list, with
each cell's function, drive strengths and pin names, in
`$IHP_PDK_ROOT/libs.ref/sg13g2_stdcell/doc/`.

## Layout

```
README.md SETUP.md TUTORIAL.md   read them in that order
                                 the assignment is in ../lab1/ASSIGNMENT.md

rtl/            cordic_pkg.sv  cordic_rot.sv  cordic_accel.sv
                cordic_accel_reg_{pkg,top}.sv   generated by `make regs`
tb/             tb_cordic_accel.sv -- one testbench, both simulators
model/          cordic_golden.py, check_bitexact.py
data/           cordic_accel.hjson -- the register description
sw/             cordic_accel_regs.h -- generated, used by the Lab 3 driver
vectors/        generated hex (gitignored)

implementation/
  tech/generic/       behavioural cells   (simulation)
  tech/sg13g2/        real library cells  (synthesis)
  design_compiler/    scripts/ + README.md
  innovus/            scripts/ + README.md
  power_analysis/     scripts/ questa/ + README.md

vendor/         pinned IP snapshots (gitignored, `make vendor`)
util/vendor.py  the vendoring tool
Makefile  cordic_accel.core
```

## What you hand in

1. Commit the report, filled in, with the reports and figures it refers to.
   Never commit `build/`, `vendor/pulp_platform/*/`, the generated CSR files,
   `vectors/`, or anything under `implementation/*/artefacts/`,
   `.../netlist/`, `.../reports/` or `.../vcd/` — they are generated, and they
   are in `.gitignore`.
2. **Publish a release of your repository.** The release is the submission: we
   read the code and the report at that tag, so anything committed afterwards
   does not count.

```bash
git add <the report> figures/
git commit -m "Lab 1: standalone accelerator, synthesis, P&R and power"
git push
gh release create lab1-final --title "Lab 1" --notes "Standalone accelerator: RTL, synthesis, P&R, power"
```

Without the `gh` CLI, do the same from the repository page on GitHub:
*Releases → Draft a new release → tag* `lab1-final` *→ Publish release*.

One release per group. Late fixes mean a new release — tell us, because we take
the latest one before the deadline.

See the *Git Cookbook*, ch. 3, for tags, releases and the group workflow.

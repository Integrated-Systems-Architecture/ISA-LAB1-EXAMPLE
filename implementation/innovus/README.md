# Place and route with Cadence Innovus

Take the gate-level netlist Design Compiler produced and turn it into a
layout: cells in rows, a power grid, a clock tree, wires on seven metal
layers, and at the end a GDS that could be sent to IHP.

Same approach as the synthesis lab next door. **Work through this page one
command at a time, in the GUI, and watch what each one does to the
picture.** Place and route is the part of the flow where you can see the
consequences of your decisions, and the picture is the point. Only when the
flow works do you go to §10 and run the scripts.

Everything below is run from **this directory**
(`lab1/implementation/innovus/`).

---

## 0. Before you start

**You need a netlist.** Innovus does not synthesise. Run the synthesis lab
first:

```bash
cd ../.. && make synth && cd implementation/innovus
ls ../design_compiler/netlist/
# cordic_accel.v  cordic_accel.sdf  cordic_accel.sdc  cordic_accel.ddc
```

Three of those four are inputs here: the `.v` is the design, the `.sdc` is
the constraint set it was built to, and the `.ddc` is not used. (The `.sdf`
belongs to the post-synthesis power analysis, one directory over.)

**Source the EDA setup**, once per shell:

```bash
source /eda/scripts/init_cadence_2020-21
```

**Point at the PDK**, if it is not in the default place:

```bash
export IHP_PDK_ROOT=/path/to/ihp-sg13g2
```

**Start the tool.** Innovus has two command languages — see §0b — and this
lab uses the newer one, so pass `-stylus`:

```bash
innovus -stylus
```

Do not background it with `&`. Innovus takes its commands from the shell you
started it in and prints its messages there.

Every run writes two files next to you: `innovus.log`, everything the tool
printed, and `innovus.cmd`, every command you issued — *including the ones
the GUI issued on your behalf when you clicked a menu*. That second file is
the bridge between §1–§9 and §10: click your way through the flow once, then
read `innovus.cmd` and you have the script.

---

## 0b. Two command languages, and why this lab picks one

Innovus understands two complete sets of commands for the same operations:

| | legacy (Common UI) | **Stylus** |
|---|---|---|
| floorplan | `floorPlan -r 1.0 0.6 10 10 10 10` | `create_floorplan -core_density_size {1.0 0.6 10 10 10 10}` |
| power ring | `addRing -nets {VDD VSS} ...` | `add_ring -nets {VDD VSS} ...` |
| placement | `placeDesign` / `optDesign -preCTS` | `place_opt_design` |
| CTS | `ccopt_design` | `ccopt_design` |
| routing | `routeDesign` | `route_design` |
| a setting | `setDesignMode -process 130` | `set_db design_process_node 130` |
| save | `saveDesign` | `write_db` |

Older tutorials use the legacy names, because they predate Stylus. The
scripts in `scripts/` use Stylus, because that is what current flows are written in — including the polHEEPo
and HEEPatia SoC flows you will meet if you continue in this group.

The **menus are the same either way**. When this page says
*Floorplan → Specify Floorplan*, it means the same click in both. Each step
script carries a header naming both the menu item and the legacy command, so
you can follow older material and the new scripts side by side.

Two things follow from `set_db` being the Stylus way to set anything:

- `get_db` is how you ask. `get_db design_process_node` prints the current
  value; `get_db insts` returns every instance; `get_db insts .name` returns
  their names. When you do not know what an object has, `get_db <object> .?`
  lists its attributes. This is the single most useful debugging command in
  the tool.
- Tab completion works on `set_db`/`get_db` names. Use it.

---

## 0c. The technology, from the place-and-route side

Synthesis needed one thing from the PDK: timing (`.lib`). Place and route
needs three.

```
$IHP_PDK_ROOT/libs.ref/sg13g2_stdcell/
├── lib/      Liberty      timing and power        (synthesis + P&R)
├── lef/      LEF          geometry                 (P&R only)
│   ├── sg13g2_tech.lef       layers, vias, rules, the site
│   └── sg13g2_stdcell.lef    one abstract per cell
├── gds/      GDSII        the actual layout        (stream-out only)
├── verilog/  cell models                            (gate-level sim)
└── cdl/      transistor netlists                    (LVS)
```

**The technology LEF** describes the silicon, not the cells: how many metal
layers there are, how wide and how far apart wires may be, what a via
between two layers looks like, and the *site* — the unit tile a standard
cell occupies.

```
SITE CoreSite
    CLASS CORE ;
    SYMMETRY Y ;
    SIZE 0.48 BY 3.78 ;
```

3.78 µm is the row height, and every cell in the library is exactly that
tall. That is what makes rows possible: cells abut, their VDD and VSS rails
line up into continuous horizontal wires, and the placer's job reduces to
choosing a row and an x-position. `SYMMETRY Y` means a cell may be mirrored
left-to-right, which is how the placer packs rows.

**The cell LEF** is an *abstract*: for each cell, its outline, where its
pins are and on which layer, and where its internal metal blocks routing.
Not the transistors — the router does not need them and they would make the
database enormous.

**The metal stack.** Seven routing layers, alternating direction:

| layer | direction | min width | used for |
|-------|-----------|-----------|----------|
| `Metal1` | horizontal | 0.16 µm | cell pins, cell rails |
| `Metal2` | vertical | 0.20 µm | signals |
| `Metal3` | horizontal | 0.20 µm | signals |
| `Metal4` | vertical | 0.20 µm | signals |
| `Metal5` | horizontal | 0.20 µm | signals |
| `TopMetal1` | vertical | 1.64 µm (pitch 3.28) | **power** |
| `TopMetal2` | horizontal | 2.00 µm (pitch 4.00) | **power** |

The alternation is not a convention, it is what makes routing work: a wire
runs on one layer, and to turn a corner it takes a via to the next layer,
whose preferred direction is perpendicular. A router that had to turn
corners on one layer would deadlock almost immediately.

The two top layers are ten times wider and ten times further apart than the
others. That makes them poor for signals and excellent for power: wide metal
is low-resistance metal, and IR drop is the thing a power grid exists to
prevent. `scripts/globals.tcl` reserves them for VDD and VSS and gives the
router `Metal1`–`Metal5`.

**Physical-only cells.** Cells with no logic, added by the tools:

| | in SG13G2 |
|---|---|
| filler | `sg13g2_fill_1`, `_2`, `_4`, `_8` |
| decap | `sg13g2_decap_4`, `sg13g2_decap_8` |
| antenna diode | `sg13g2_antennanp` |
| tie high / low | `sg13g2_tiehi`, `sg13g2_tielo` |
| well taps | **none — this library has no tap cells** |

That last row matters. Most PDKs need a tap cell every so many microns to
tie the wells, and most flows copied off the internet start with
`add_well_taps`. SG13G2 ties its wells inside each cell, so there is no
`sg13g2_tapcell` and the command has nothing to insert. If you copy a flow
from a Sky130 or Nangate tutorial, this is the first thing that will fail.

**No clock buffer family either.** There is no `sg13g2_clkbuf_*`. The clock
tree is built out of the ordinary `sg13g2_buf_4/8/16` and
`sg13g2_inv_4/8/16`, which is what `scripts/globals.tcl` hands CTS.

**No QRC deck, no captable.** A commercial PDK ships extraction decks that
turn geometry into resistance and capacitance, several of them, one per
interconnect corner. SG13G2 ships none, so Innovus uses its own rule-based
extraction from the technology LEF. It is good enough to close this lab. It
is not foundry sign-off, and the scripts say so where it matters.

---

## 1. Import the design

*Menu: **File → Import Design…***

The import needs three separate things and it is worth keeping them apart in
your head, because when the import fails it is always one of the three:

| | what | file |
|---|---|---|
| logical | the netlist | `../design_compiler/netlist/cordic_accel.v` |
| physical | layers, rules, cell outlines | `sg13g2_tech.lef`, `sg13g2_stdcell.lef` |
| timing | libraries, corners, constraints | the MMMC view file |

In the shell, load the design description and the helpers, then make the
output directories:

```tcl
source scripts/globals.tcl
source scripts/helpers.tcl
make_dirs
set REPORT_DIR $design(REPORT_DIR)
```

`scripts/globals.tcl` is the equivalent of a legacy `design.globals` file,
in the form the SoC flows use: one `$design(...)` array
holding every path, every cell name and every number, and nothing else in
the flow sets any of them. Open it now — it is the file you will edit most.

Then, one at a time:

```tcl
set_db init_power_nets  {VDD}
set_db init_ground_nets {VSS}
set_db design_process_node 130
read_mmmc     scripts/lab1.view
read_physical -lefs $design(ALL_LEFS)
read_netlist  $design(netlist)
init_design
```

Three of those deserve a sentence.

**`init_power_nets` / `init_ground_nets` before `init_design`.** They are how
the tool works out which pins of each cell are supplies. Set them after, and
every standard cell arrives with unconnected VDD and VSS.

**`design_process_node 130`.** Innovus defaults to a much smaller node, and
the default decides how it estimates wire R and C *before there are any
wires*. Every pre-route timing number depends on it. The legacy command for it
is `setDesignMode -process`, and it matters more here
than on a commercial PDK because there is no QRC deck to override it later.

**`read_mmmc`** — see §1b.

Then check what came in:

```tcl
check_design -type all -out_file $REPORT_DIR/01_init.check_design.rpt
check_timing -verbose
```

`check_timing` is the one people skip. It does not report violations; it
reports *paths that are not being checked at all* — unconstrained endpoints,
clocks that reach nothing, inputs with no arrival time. A path nobody checks
never shows up as violating.

`scripts/init.tcl` is all of the above plus the clock uncertainty and the
netlist clean-up.

---

## 1b. MMMC: what the timing setup actually is

Design Compiler optimised at one corner, one mode, one set of constraints.
Innovus does not work that way: it carries several simultaneously and every
optimisation step has to satisfy all of them at once. **M**ulti-**M**ode
**M**ulti-**C**orner.

Seven object types, each built from the previous. `scripts/lab1.view`
creates them in exactly this order and nothing else in the flow creates any:

```
  library set        one set of .lib files          = one PVT point
        │
  operating cond     the V and T it was characterised at
        │
  timing condition   library set + operating condition
        │                                      rc corner
        │                                   (how wires are
        ▼                                    turned into R and C)
  delay corner   ◄─────────────────────────────────┘
        │            everything needed to compute one delay
        │
        │            constraint mode
        │            (one SDC = one way the design is driven)
        ▼                   │
  analysis view  ◄──────────┘
        │
        ▼
  set_analysis_view -setup {...} -hold {...}
```

This lab uses three corners and one mode, which is the smallest honest
setup:

| view | corner | checked for | why |
|------|--------|-------------|-----|
| `setup_slow` | slow, 1.08 V, 125 °C | **setup** | the slowest silicon. Can the data get there in one cycle? |
| `hold_fast` | fast, 1.32 V, −40 °C | **hold** | the fastest silicon. Does the data race past a flop before it is captured? |
| `view_typ` | typ, 1.20 V, 25 °C | neither | not signed off on; the realistic one to look at |

**Hold is checked at the fast corner, not the slow one.** A hold violation
is data arriving *too early*. Fast silicon is what makes it early. Checking
hold in the slow corner finds nothing and proves nothing — and is a mistake
common enough that it is worth saying twice.

The SoC version of this file has twelve views: the same corners crossed with
four RC corners from the foundry's QRC decks. Same seven objects, same
order, more of them.

---

## 2. Floorplan

*Menu: **Floorplan → Specify Floorplan…***

The step with the most leverage and the least tool support. You are choosing
how big the block is and what shape it is. Congestion, wire length, timing
and power are all decided here, and no amount of optimisation downstream
recovers a bad floorplan.

```tcl
create_floorplan -site CoreSite -core_density_size {1.0 0.6 15 15 15 15}
```

The list is `{aspect_ratio  utilisation  left  bottom  right  top}`:

- **aspect ratio 1.0** — a square core. Your block has no reason to be any
  other shape; a block that has to fit next to something else does.
- **utilisation 0.6** — standard cells will occupy 60 % of the core area.
  The other 40 % is what the router needs to get wires between them, plus
  the filler at the end. Too high and the router cannot finish; too low and
  the block is mostly empty and every wire is longer than it needs to be.
- **15 15 15 15** — core-to-die margin on each side, in microns. The power
  ring lives in this channel, so it has to be wide enough for two rings and
  their spacings. `scripts/globals.tcl` computes it from the ring geometry
  rather than hard-coding it, so widening the ring widens the margin.

The tool sizes the die from the cell area it already knows. Look at the
picture: you now have a die, a core, and rows. The grey horizontal lines are
the rows, 3.78 µm apart.

Then the IO pins. This block has no pads — it is a block inside a chip, not
a chip — so its "pins" are points on the die edge where the level above will
connect:

```tcl
edit_pin -side Left  -layer 2 -spread_type center -spacing 2 \
         -pin [get_db ports .name -if {.direction == in}]
edit_pin -side Right -layer 2 -spread_type center -spacing 2 \
         -pin [get_db ports .name -if {.direction == out}]
snap_floorplan -all
```

`snap_floorplan` puts everything on the manufacturing grid (0.005 µm here).
Off-grid geometry is a DRC error you would otherwise find at the very end.

**If you added an SRAM**, it is placed by hand, here, before anything else.
A macro is a block of silicon a hundred times the size of a standard cell
and the placer will not choose a good position for it. Put it somewhere,
then keep the placer away from its edge with a halo — cells jammed against a
macro wall have nowhere to route:

```tcl
place_inst i_scratchpad/i_sram 40 40 R0
create_place_halo -insts i_scratchpad/i_sram -halo_deltas {10 10 10 10}
create_route_halo -bottom_layer Metal1 -top_layer Metal4 -space 5 \
                  -inst i_scratchpad/i_sram
```

`scripts/floorplan.tcl`, with the macro part commented and waiting.

---

## 3. Power plan

*Menus: **Power → Connect Global Nets…**, **Power → Power Planning → Add
Ring…**, **Power → Power Planning → Add Stripe…**, **Route → Special
Route…***

Every cell needs VDD and VSS before it can be placed. The supply is built
before the signals because it is the one network whose geometry you choose
rather than let a router discover.

Three pieces, built in this order, connected by vias as they go:

```
          ┌───────────── ring (TopMetal2 / TopMetal1) ─────────────┐
          │  ║        ║        ║        ║        ║        ║       │   stripes
          │  ║        ║        ║        ║        ║        ║       │   (TopMetal1)
          │ ═╬════════╬════════╬════════╬════════╬════════╬═════  │ ◄ followpins
          │ ═╬════════╬════════╬════════╬════════╬════════╬═════  │   (Metal1,
          │ ═╬════════╬════════╬════════╬════════╬════════╬═════  │    one pair
          │  ║        ║        ║        ║        ║        ║       │    per row)
          └────────────────────────────────────────────────────────┘
```

**1. Say what is a supply pin.** Every cell's LEF declares pins named `VDD`
and `VSS`. Connect all of them to the two global nets:

```tcl
connect_global_net VDD -type pg_pin -pin_base_name VDD -all -verbose
connect_global_net VSS -type pg_pin -pin_base_name VSS -all -verbose
```

**2. The ring**, in the channel the floorplan left. Horizontal segments on a
horizontal layer, vertical on a vertical one — going against a layer's
preferred direction is legal and wasteful. Both on thick top metal, because
the ring carries the whole block's current:

```tcl
add_ring -nets {VDD VSS} -type core_rings -follow core \
  -layer {top TopMetal2 bottom TopMetal2 left TopMetal1 right TopMetal1} \
  -width 3.0 -spacing 2.0 -offset 2.0
```

Click on a stripe afterwards and the bottom of the window tells you its
layer, its geometry and its coordinates. Look at the corners: those are vias
stacking down through the metal layers.

**3. Stripes.** The ring alone starves the middle of the core — current
would have to travel from the edge along the thin Metal1 rails, and the IR
drop in the centre would be the worst in the block. Stripes bring the supply
down into the core every 50 µm:

```tcl
add_stripes -nets {VDD VSS} -layer TopMetal1 -direction vertical \
  -width 2.0 -spacing 2.0 -set_to_set_distance 50 -start_from left
```

Pitch is the whole trade-off in one number: closer stripes mean a stiffer
supply and less room for signals. On a block this small you could nearly
skip them. On anything real you cannot.

**4. Followpins.** The Metal1 rails inside every row, and the vias tying
them up to the stripes and the ring. This is what actually feeds the cells:

```tcl
route_special -connect {core_pin stripe} -nets {VDD VSS} \
  -layer_change_range {Metal1 TopMetal1}
```

**5. Check it — both ways.**

```tcl
check_drc -check_only special -limit 100000
check_connectivity -type special -nets {VDD VSS}
```

Two different questions. DRC asks whether the geometry is manufacturable.
Connectivity asks whether it is all actually joined up. A power grid can be
perfectly legal and still contain an island connected to nothing, and that
island will feed a row of cells with no supply.

`scripts/powergrid.tcl`.

---

## 4. Placement

*Menus: **Place → Place Standard Cell…**, then **ECO → Optimize Design…**
with Design Stage **Pre-CTS**.*

```tcl
set_db place_global_clock_gate_aware true
place_opt_design -report_dir $REPORT_DIR/04_place.place_opt
```

One command, three things: it places, then optimises the logic for the
placement it just made — resizing gates, adding buffers, restructuring — and
re-places what it changed. Placement and pre-CTS optimisation are a single
step because separating them means optimising for positions that are about
to move.

`place_global_clock_gate_aware` keeps the registers behind one clock gate
together, so the gated clock net stays short. Those gates are the ones
`compile_ultra -gate_clock` inserted, plus the explicit `tc_clk_gating`
around the rotator.

Zoom in. You can now select a cell and read its name, see its pins, and
click a pin to see what it connects to — as a straight line, because nothing
is routed yet. What you are looking at is still only the abstract of each
cell: its outline, its orientation, and the pins the router will aim at.

Then look at three reports, in this order:

```tcl
report_timing -nworst 10  > $REPORT_DIR/04_place.timing_top10.rpt
report_area -detail       > $REPORT_DIR/04_place.area.rpt
report_congestion -hotspot > $REPORT_DIR/04_place.congestion.rpt
```

**Congestion is the one to learn to read.** It is the fraction of the
routing tracks in each region that the global router would need. Over 100 %
anywhere and the detailed router will not finish. The fix is never in this
step — it is a lower utilisation or a different aspect ratio, back in §2.

**The clock is still ideal here.** Every number above assumes the clock edge
reaches every flop simultaneously. Believe the setup slack. Do not believe
the hold slack: there is nothing to race against yet.

`scripts/place.tcl`.

---

## 5. Clock tree synthesis

*Menu: **Clock → CCOpt Clock Tree Debugger**, and **ECO → Optimize Design…**
with Design Stage **Post-CTS**.*

Up to now the clock was a fiction: one net reaching every flip-flop with no
delay. It is a tree of buffers, and this is where it gets built.

```tcl
set_db cts_buffer_cells   {sg13g2_buf_4 sg13g2_buf_8 sg13g2_buf_16}
set_db cts_inverter_cells {sg13g2_inv_4 sg13g2_inv_8 sg13g2_inv_16}
set_db cts_target_skew                0.10
set_db cts_target_max_transition_time 0.40
ccopt_design
```

Note the command. The legacy flow uses `set_ccopt_property target_skew
0.10`; Stylus has no such command (`invalid command name
"set_ccopt_property"`) and renames the properties as well —
`target_max_trans` becomes `cts_target_max_transition_time`. `get_db cts_*`
lists the real ones.

Two targets, both in nanoseconds, both in `scripts/globals.tcl`:

- **skew** — how much the arrival times at different flops may differ. Skew
  comes straight out of the setup budget, and it can manufacture hold
  violations where there were none.
- **max transition** — the slowest clock edge allowed anywhere in the tree.
  A lazy edge is jitter, and jitter is margin you have to give back.

**Why 0.40 ns and not something tighter.** Because of the library. SG13G2
ships its integrated clock gate in exactly one drive strength —
`sg13g2_lgcp_1` and `sg13g2_slgcp_1`, and that is the entire list — so the
weakest driver in the tree is fixed, and it still has to drive whatever CTS
puts after it. Ask for 0.15 ns and ccopt refuses to start:

```
**ERROR: (IMPCCOPT-1209): Non-leaf slew time target of 0.150ns is too low ...
The largest clock gate is unable to drive the largest inverter ... increase
the slew target to at least 0.317ns or remove these driver cells from the
CTS cell lists: sg13g2_inv_16 sg13g2_inv_8
**ERROR: (IMPCCOPT-1013): ... CTS will now terminate.
```

Two ways out: raise the target, or drop the strong inverters so the gate
never has to drive them. Raising it is the better trade, because those
strong cells are what keep the tree shallow. The log prints the exact
minimum it will accept — search it for `Too low;`. That is the number to
trust, not this page.

Then look at what you got:

```tcl
report_clock_trees
report_skew_groups
```

You can browse the tree in the GUI and highlight any level of it in the
layout. Do — a clock tree is the one structure in the design whose shape you
can actually see.

**Then hold.** Before CTS, hold checking was meaningless: no clock delay, no
race. Now there is, and `opt_design -post_cts -setup -hold` fixes it. Note
*how* it fixes it: by adding buffers whose only purpose is to make a fast
path slower. They cost area and they burn power and they are not optional.

One more thing this step does, and it is easy to miss:

```tcl
set_clock_uncertainty -setup 0.03 [all_clocks]
```

The uncertainty we set at import was a *budget for skew we could not yet
see*. The tree exists now and its skew is measured, so keeping the budget on
top of the measurement is double-counting — pessimism you pay for in area.
Hold uncertainty stays: that is jitter, and jitter does not go away.

`scripts/cts.tcl`.

---

## 6. Routing

*Menu: **Route → NanoRoute → Route…***

```tcl
route_design
```

Two phases inside one command. Global routing plans which region each net
crosses; detailed routing draws the actual wires and obeys the design rules.

Watch the shell. It prints the iteration count, the number of violations
remaining, the wire length per layer and the via count. A router that is
converging shows the violation count dropping each iteration. One that is
not is telling you the floorplan is too tight.

Then, and only then:

```tcl
set_db timing_analysis_type ocv
extract_rc
```

**This is where timing stops being an estimate.** Until now the wire delays
came from a statistical guess — "a net with this many pins in a block this
size". Now there are wires, so there is extraction, and the numbers move.
Sometimes a lot.

`ocv` is on-chip variation: within a corner, allow different parts of the
die to differ. It is pessimistic and it is what sign-off does.

`scripts/route.tcl`.

---

## 7. Post-route optimisation

*Menu: **ECO → Optimize Design…** with Design Stage **Post-Route**.*

```tcl
opt_design -post_route -setup
opt_design -post_route -hold
opt_design -post_route -drv
```

The last chance to fix timing. Everything here is an ECO: a few cells
change, only the nets they touch are re-routed, the rest of the routing
survives.

The order is not arbitrary:

1. **setup** — make the slow paths faster: bigger drivers, better buffering.
2. **hold** — make the fast paths slower. After setup, because setup is
   about to restructure some of the paths hold would have fixed.
3. **drv** — design rule violations: max transition, max capacitance, max
   fanout. Not timing, but a library is only characterised *inside* those
   limits, so a violated one makes every delay downstream of it a guess.

If setup slack is still negative here, the answer is not another
`opt_design`. It is a lower clock, a different floorplan, or a different
microarchitecture — and that is a result too, as long as you report it
rather than quietly relaxing the constraint.

`scripts/opt.tcl`.

---

## 8. Fillers, verification, export

*Menus: **Place → Physical Cell → Add Filler…**, **Verify → Verify
Connectivity**, **Verify → Verify DRC**, **File → Save → Netlist**, **Timing
→ Write SDF**.*

**Fillers first**, because they change the layout. The gaps between placed
cells are not empty silicon: the n-well and the implant layers have to be
continuous along a row, and a gap breaks them. Decaps go in before plain
filler — they do the same job and add supply decoupling while they are
there:

```tcl
add_fillers -base_cells {sg13g2_decap_8 sg13g2_decap_4} -prefix DECAP
add_fillers -base_cells {sg13g2_fill_8 sg13g2_fill_4 sg13g2_fill_2 sg13g2_fill_1} -prefix FILLER
```

**Then verify**, on the layout you are actually shipping:

```tcl
check_connectivity -type all
check_drc -limit 100000
```

Connectivity violations are usually floating wires. DRC violations are
usually geometry you asked for: a ring spacing narrower than the technology
allows, for instance. A clean timing report on a layout that fails either of
these means nothing.

**Then export.** Four files leave this step and each has exactly one
consumer:

```tcl
write_netlist artefacts/export/cordic_accel_pnr.v
write_sdf     artefacts/export/cordic_accel_pnr.sdf -recompute_delay_calc
write_parasitics -spef_file artefacts/export/cordic_accel_pnr.spef -rc_corner rc_slow
write_stream  -merge $design(ALL_GDS) artefacts/export/cordic_accel.gds
```

| file | consumer |
|------|----------|
| `.v` | gate-level simulation and power analysis — **this** netlist, with the clock tree in it, not Design Compiler's |
| `.sdf` | QuestaSim, for a timing-accurate gate-level simulation |
| `.spef` | PrimeTime, for static timing sign-off |
| `.gds` | the foundry |

`-recompute_delay_calc` on `write_sdf` is not optional. Without it you get
the delays as they stood at the last timing update, which may predate the
last ECO. Innovus itself tells you to pass it.

Also save the database, so you can come back:

```tcl
write_db artefacts/db/final.db
```

`scripts/export.tcl`.

---

## 9. Things that will bite you

**Floorplanning is cumulative.** Source `floorplan.tcl` twice in one session
and you get something different from sourcing it once. Every step script
that can starts by undoing its own previous effect (`delete_relative_floorplan
-all`, `unplace_obj -all`), but the safest sweep is a fresh Innovus per data
point — same rule as `remove_design -all` in synthesis.

**Read the log, not the shell.** The GUI scrolls. `innovus.log` does not.

**`check_timing` before `report_timing`.** A clean timing report on an
unconstrained design is a clean report on nothing.

**The netlist you simulate at gate level is the P&R one.** Design Compiler's
netlist has an ideal clock: no tree, no buffers, no skew. Once the layout
exists, that netlist is a different circuit.

**Do not copy a flow from another PDK without reading it.** SG13G2 has no
tap cells and no clock buffer family. A Sky130 or Nangate tutorial will have
`add_well_taps` and `sg13g2_clkbuf_*`-shaped assumptions in it, and both will
fail here in ways whose error messages do not point at the cause.

---

## 10. Now put it in scripts

You have run the flow once. From here on, do not.

`innovus.cmd` from your GUI session already contains every command you
issued. Compare it with `scripts/` — that is the exercise, and it is how the
scripts in this directory were written in the first place.

**One script per step**, so you can change one thing without re-reading the
others:

| file | what it holds | change it when |
|------|---------------|----------------|
| `globals.tcl` | **every** path, cell name and number | almost always — start here |
| `lab1.view` | MMMC: library sets, corners, analysis views | you add a macro, a corner or a mode |
| `helpers.tcl` | `log_stage`, `log`, `make_dirs`, `check_inputs` | never |
| `init.tcl` | import: LEF, MMMC, netlist, clock uncertainty | rarely |
| `floorplan.tcl` | die size, aspect, margins, IO pins, macros | **often** — this is the knob |
| `powergrid.tcl` | ring, stripes, followpins | IR drop or DRC after the power plan |
| `place.tcl` | placement and pre-CTS optimisation | rarely |
| `cts.tcl` | clock tree, post-CTS setup+hold optimisation | you want a different skew target |
| `route.tcl` | signal routing, extraction, OCV | rarely |
| `opt.tcl` | post-route setup / hold / DRV | rarely |
| `export.tcl` | fillers, verification, all four outputs | you need another output format |
| `run_pnr_flow.tcl` | sources the eight in order | never |

The whole flow:

```bash
innovus -stylus -files scripts/run_pnr_flow.tcl -log artefacts/innovus
```

or, from `lab1/`:

```bash
make pnr                          # batch
make pnr-gui                      # same scripts, GUI open, stops at the end
make pnr PNR_UTIL=0.75            # denser floorplan
make pnr PNR_ASPECT=2.0           # twice as wide as it is tall
make pnr CLK_PERIOD=3.0           # re-synthesise at 3 ns first, then route it
```

### Running it with the GUI

`make pnr-gui` runs exactly the same scripts and, instead of exiting at the
end, leaves you in the tool with the finished layout on screen (`gui_show`
and `gui_fit`). Everything the GUI can do — the design browser, the clock
tree debugger, the congestion and DRC markers, zooming into a cell — is
available from there.

It needs X11, so **log in with `ssh -X`**:

```bash
ssh -X isa      # XQuartz must be running, on a Mac
cd ~/isa-lab1/lab1
make pnr-gui
```

This is verified working on isaserver: with `DISPLAY` forwarded, `gui_show`
succeeds and Innovus opens normally. If X11 is not forwarded the flow still
completes and the scripts print

```
note: could not open the GUI (...) -- did you log in with `ssh -X'?
```

rather than failing, so a forgotten `-X` costs you the window and not the
run.

Two things are worth doing in the GUI rather than reading about:

- After `floorplan.tcl`, look at the rows and the die, then change
  `PNR_UTIL` and look again. The relationship between utilisation and the
  space left for routing is much clearer as a picture.
- After `cts.tcl`, open *Clock → CCOpt Clock Tree Debugger* and highlight
  the tree in the layout. It is the one structure in the design whose shape
  you can actually see.

**Restarting from the middle.** Every step writes
`artefacts/db/post_<stage>.db`. To retry CTS with a different skew target
without re-doing placement:

```tcl
innovus -stylus
source scripts/globals.tcl
source scripts/helpers.tcl
set REPORT_DIR $design(REPORT_DIR)
read_db artefacts/db/post_place.db
# edit scripts/cts.tcl, then:
source scripts/cts.tcl
```

That is the reason for one file per step, and it is the difference between a
sweep that takes an afternoon and one that takes a week.

---

## 11. What this flow leaves out

Everything here is a *block*. A chip needs four more things, and the SoC
flow in this group's `scripts/` directory has one script for each:

| | what it is | where it would go |
|---|---|---|
| **IO pads** | the ring of pad cells at the die edge, from `libs.ref/sg13g2_io/`, plus the level shift between 1.2 V core and 3.3 V outside | `fplan_io.tcl`, after the floorplan |
| **macro placement** | SRAMs placed by hand, with halos and their own power mesh | `fplan_memories.tcl` + `power_mesh.tcl` |
| **power intent** | a UPF file describing domains, isolation cells, retention flops, power switches — everything §5c of the synthesis README calls the real strategy | `read_power_intent` in `init.tcl` |
| **seal ring** | the guard structure around the die edge | `fplan_io.tcl` |

Read those scripts. They are four times the size of these, they do the same
eight steps in the same order, and the difference between them is exactly
the difference between a block and a chip.

---

## 12. Next: what is the power?

The layout exists, so the capacitance is real and the clock tree is real.
Neither was true after synthesis.

`../power_analysis/` takes the netlist and the SDF, simulates the real
workload on them in QuestaSim, and hands the switching activity to
PrimePower. That is the number to put in your report — not the estimate
`report_power` prints here, which still assumes a default toggle rate.

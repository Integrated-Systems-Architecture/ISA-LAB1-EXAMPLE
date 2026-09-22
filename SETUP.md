# Lab 1 — Setup

Everything you need to simulate the accelerator, synthesise it, place and route
it, and measure its power. Do this **once per machine**, before the tutorial.

Lab 1 needs two toolchains, and they are not the same one:

| | what it runs | where it comes from |
|---|---|---|
| **open source** | Verilator, FuseSoC, Python, reggen | `/oss-tools` on the ISA server, or you install it |
| **commercial EDA** | QuestaSim, Design Compiler, Innovus, PrimePower | `/eda` on the ISA server, **licence-locked** |

Everything from `make sim` down to `make lint` runs anywhere. **Everything from
`make synth` onwards runs only on the ISA server**, because that is where the
licences are. Plan on doing the RTL work wherever you like and the
implementation work on the server.

Supported hosts for the open-source half: **the ISA server** (nothing to
install), **Ubuntu/Debian Linux**, **Windows + WSL2 (Ubuntu)**, **macOS**.

---

## The short way: use the ISA server

Everything — both toolchains and the PDK — is already installed. You install
nothing.

### 1. Log in

```bash
ssh <your-user>@isaserver          # add -X for the Innovus and DC GUIs
```

X11 forwarding is not optional for Lab 1 the way it was for Lab 0: you are
told to run the synthesis and place-and-route flows through the GUI the first
time, and `design_vision` and `innovus` are graphical tools. Test it before
you need it:

```bash
ssh -X <your-user>@isaserver
xclock          # a clock should appear on your screen
```

On macOS you need [XQuartz](https://www.xquartz.org) installed and running
first. On Windows, WSL2 with WSLg handles X11 by itself.

### 2. Activate the open-source environment

```bash
source /oss-tools/init.sh
```

Same script as Lab 0, same contents: the conda environment carrying Python and
FuseSoC, plus Verilator and Verible on your `PATH`. Do it in **every** new
shell, or put the line in your `~/.bashrc`.

### 3. Activate the EDA environments

These are separate, and you source the one you need:

```bash
source /eda/scripts/init_design_vision     # Design Compiler, PrimeTime/PrimePower
source /eda/scripts/init_cadence_2020-21   # Innovus
source /eda/scripts/init_questa_core_prime # QuestaSim
```

> **Innovus: 2020-21, not 2021-22.** There is an `init_cadence_2021-22` next to
> it and it does not work on this machine. Innovus 21.1 requires AVX;
> isaserver's CPU is a `QEMU Virtual CPU` whose flags are `sse4_2 popcnt` and
> nothing else, so the tool segfaults immediately after checking out its
> licence — `*** CRASHED *** [signal 11]`, even on a two-line script. The
> Makefile's `pnr` targets assume 20.11 anyway.

Check what each one gave you:

```bash
which dc_shell-xg-t design_vision lc_shell   # after init_design_vision
which pt_shell pwr_shell vcd2saif            # the same script provides these
which innovus                                # after init_cadence_2020-21
which vsim vlog vlib                         # after init_questa_core_prime
```

**They can be sourced together.** The full set for a Lab 1 session:

```bash
source /oss-tools/init.sh
source /eda/scripts/init_design_vision
source /eda/scripts/init_cadence_2020-21
source /eda/scripts/init_questa_core_prime
```

> **Do not add `/oss-tools/conda/envs/x-heep/lib` to `LD_LIBRARY_PATH`.**
> It is tempting when something cannot find a shared library. The Synopsys and
> Cadence tools ship their own `libstdc++`, and conda's is newer; put conda's
> first and `dc_shell` dies with
> `version 'CXXABI_1.3.15' not found`. The Makefile is careful about this
> — see the `VERILATOR_ENV` comment in it — and so should you be.

### 4. The PDK

Lab 1 targets **IHP SG13G2**, a 130 nm open PDK. `/oss-tools/init.sh` already
exports it:

```bash
echo $IHP_PDK_ROOT       # /oss-tools/pdk/ihp-sg13g2
```

Set it yourself only if you are running somewhere else:

```bash
export IHP_PDK_ROOT=/path/to/ihp-sg13g2
```

Check it is really there — these four directories are what the flow reads:

```bash
ls $IHP_PDK_ROOT/libs.ref/
# sg13g2_io  sg13g2_pr  sg13g2_sram  sg13g2_stdcell

ls $IHP_PDK_ROOT/libs.ref/sg13g2_stdcell/
# cdl  doc  gds  lef  lib  verilog
```

| directory | holds | used by |
|-----------|-------|---------|
| `lib/` | Liberty: timing and power | Design Compiler, Innovus, PrimePower |
| `lef/` | geometry: layers, rules, cell outlines | Innovus |
| `verilog/` | behavioural cell models | QuestaSim, gate-level simulation |
| `gds/` | the layout | Innovus stream-out |

One directory sits outside `libs.ref/` and matters for `make gds`:

```bash
ls $IHP_PDK_ROOT/libs.tech/klayout/tech/sg13g2.lyp   # KLayout layer properties
```

Without that file a GDS opens in KLayout as anonymous numbered layers in
colours KLayout invented. KLayout itself (0.28.17) is installed system-wide on
the server, so `which klayout` answers `/usr/bin/klayout` with no environment
to source.

If `IHP_PDK_ROOT` is unset the flow falls back to the same
`/oss-tools/pdk/ihp-sg13g2`, so on the server you can leave it alone. Set it if
you are told the PDK has moved, or if you are running somewhere else.

### 5. Get your repository and check the flow

```bash
cd ~
git clone <your-group-repo> isa-lab1
cd isa-lab1/lab1

make vendor      # fetch the pulp IPs into vendor/
make regs        # reggen: data/cordic_accel.hjson -> the CSR block
make sim         # Verilator, self-checking -> TEST PASSED
```

`make sim` should end with:

```
[TB] 64 angles from /home/<you>/isa-lab1/lab1/vectors/
[TB] run1 (cos/sin): 64/64 results match the golden model
[TB] run2 (seed +90): 64/64 results match the golden model
TEST PASSED
```

That is the open-source half working. For the commercial half:

```bash
make synth       # Design Compiler -> a netlist. Takes a few minutes.
```

The first run also compiles the PDK's Liberty into the `.db` Design Compiler
needs and caches it under `implementation/design_compiler/db/`. That step needs
a **Library Compiler licence** and takes a minute; later runs reuse the cache.

### Long runs: use tmux

Synthesis sweeps and place-and-route take a while, and an SSH connection that
drops takes the job with it. Same advice as Lab 0:

```bash
tmux new -s lab1
# ... start the run ...
# Ctrl-b then d   to detach; log out; come back later with:
tmux attach -t lab1
```

---

## Licences

The commercial tools check out a licence when they start and release it when
they exit. There are not enough for everyone at once.

- **Quit the tool when you are done.** A `dc_shell` left open overnight is a
  licence nobody else can use.
- If you get `Error: Licence check failed`, someone else has them all. Wait,
  or ask on the course channel.
- `make synth` and `make pnr` each hold one for the length of the run. A sweep
  of six clock periods holds one six times in a row, not six at once.

---

## Your own machine

You can do all the RTL work locally: write the accelerator, run both
simulators, lint. You cannot synthesise, place and route, or measure power —
those need licences that live on the server.

### What you can install

| tool | needed for | how |
|------|------------|-----|
| Python 3.11 + FuseSoC + hjson | `make vendor`, `make regs`, `make vectors` | as in Lab 0 |
| Verilator 5.040 | `make sim`, `make lint` | as in Lab 0 |
| QuestaSim | `make questa` | free Intel/Altera Starter Edition, Linux and Windows only |
| GTKWave | looking at the traces | as in Lab 0 |

If you already did Lab 0's setup, the first two are done — Lab 1 adds no
Python packages. Reuse the same conda environment:

```bash
conda activate x-heep
cd lab1 && make vendor && make regs && make sim
```

### QuestaSim on your own machine

Optional. The point of `make questa` is that **the same testbench compiles on
both simulators** — if it only ever runs on Verilator you have not shown that.
But you can equally demonstrate it once on the server.

The free **Questa–Intel FPGA Starter Edition** is enough for this design. It is
Linux/Windows only; on macOS, use the server.

### The PDK on your own machine

You do not need it unless you want to read the library documentation, which is
worth an hour:

```bash
git clone --depth 1 https://github.com/IHP-GmbH/IHP-Open-PDK.git
export IHP_PDK_ROOT=$PWD/IHP-Open-PDK/ihp-sg13g2
```

The full clone is about 800 MB, most of it analog tech files the digital flow
never touches. The parts Lab 1 uses are `libs.ref/`, about 130 MB.

Start with the cell list:

```bash
ls $IHP_PDK_ROOT/libs.ref/sg13g2_stdcell/doc/
```

---

## What each tool is for

Worth having straight before you start, because the labs name them constantly:

| tool | stage | in | out |
|------|-------|-----|-----|
| **Verilator** | RTL simulation | SystemVerilog | `TEST PASSED` |
| **QuestaSim** | RTL and gate-level simulation | SystemVerilog, netlist + SDF | `TEST PASSED`, a VCD |
| **FuseSoC** | build orchestration | `.core` files | file lists, tool invocations |
| **reggen** | CSR generation | `data/cordic_accel.hjson` | the CSR block + a C header |
| **Design Compiler** | logic synthesis | RTL + Liberty + SDC | a gate-level netlist |
| **Library Compiler** | library compilation | Liberty `.lib` | `.db` |
| **Innovus** | place and route | netlist + LEF + SDC | a layout, GDS, SDF, SPEF |
| **PrimePower** | power analysis | netlist + VCD + Liberty | watts |

Lab 1 uses all of them. The three READMEs under `implementation/` take them one
at a time.

---

## When it breaks

**`fusesoc: command not found`** — you did not source `/oss-tools/init.sh`, or
you are in a shell where the conda environment is not active.

**`zlib.h: No such file or directory` during `make sim`** — Verilator on the
server was built with conda's compiler, which does not search `/usr/include`.
The Makefile fixes this itself by setting `CPLUS_INCLUDE_PATH`; if you are
invoking `fusesoc` by hand instead of through `make`, do the same:

```bash
CPLUS_INCLUDE_PATH=$CONDA_PREFIX/include fusesoc ... run --target sim ...
```

**`version 'CXXABI_1.3.15' not found` from `dc_shell` or `innovus`** — you have
conda's `lib` directory in `LD_LIBRARY_PATH`. Remove it and start a new shell.

**`cannot find .../sg13g2_stdcell_slow_1p08V_125C.lib`** — `IHP_PDK_ROOT` is
wrong. `ls $IHP_PDK_ROOT/libs.ref/sg13g2_stdcell/lib/` should list six `.lib`
files.

**`write_lib in dc_shell is not enabled ... (UIL-91)`** — the script handles
this with `enable_write_lib_mode`. If you hit it running commands by hand,
either call that first or compile the library outside `dc_shell`:

```bash
lc_shell -x "read_lib $IHP_PDK_ROOT/libs.ref/sg13g2_stdcell/lib/sg13g2_stdcell_slow_1p08V_125C.lib; \
             write_lib sg13g2_stdcell_slow_1p08V_125C -format db \
                       -output db/sg13g2_stdcell_slow_1p08V_125C.db; quit"
```

**Synthesis finishes in three seconds and the netlist directory is empty** —
something failed early and the script kept going. Read
`implementation/design_compiler/reports/synth.log` from the **top**, not the
bottom: the first error is the real one and the other two hundred are its
consequences.

**`Error: Cannot find the design 'cordic_accel' in the library 'WORK'`** — an
`analyze` failed. Search the log upwards for the first `Error:` on a source
file.

**A GUI does not open** — you forgot `-X`, or XQuartz is not running. `xclock`
is the test, not the EDA tool.

**`libodbc.so.2: cannot open shared object file`** from `pt_shell` or
`pwr_shell` — PrimeTime links against unixODBC and the package is not
installed on the server. `run_pwr_flow.sh` works around it by symlinking the
copy that ships inside the VCS installation into `~/.local/eda-libs` and
putting only that one directory on `LD_LIBRARY_PATH`. The real fix is
`yum install unixODBC` as root; when that happens the shim does nothing and
can be deleted.

**`** Error: (vlog-13276) Could not find field/method name (rready)`** — the
vendored OBI assign macros type-check a branch that `ObiDefaultConfig` makes
dead. Suppressed in `cordic_accel.core`; if you call `vlog` by hand, add
`-suppress 13276`.

**`** Error: (vsim-3009) [TSCALE]`** — the lab RTL declares no `timeunit`
and the vendored IPs do. Compile everything with `-timescale 1ns/1ps`, which
the `.core` already does.

**`(vlog-2118) The function ... is not a valid constant function`** — Questa
refuses a constant function that calls real-valued system functions
(`$atan`, `**` on reals). Design Compiler separately refuses `$rtoi`
(VER-956). If you need an elaborate-time table, write the constants out as
literals; `rtl/cordic_pkg.sv` shows the pattern and explains why.

**`error: unrecognized arguments: --run_options=...` from `make questa`** —
edalize's modelsim backend has no `--run_options`; plusargs go through
`--vsim_options`. The Makefile does this correctly; the trap is only if you
invoke `fusesoc` by hand.

**Disk full** — the server's root filesystem is shared and often close to full.
`make synth-clean`, `make pnr-clean` and `make power-clean` remove the
generated artefacts. VCD files are the worst offender: a gate-level VCD of a
long run is hundreds of megabytes.

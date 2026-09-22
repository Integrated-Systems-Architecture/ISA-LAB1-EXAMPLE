# Lab 1 — Standalone accelerator: implement + simulate

**Goal:** implement the accelerator you proposed in Lab 0 as **standalone RTL**
(no X-HEEP yet), and prove it correct with a **self-checking testbench** that
runs on **both** Verilator and QuestaSim against a golden model.

Synthesis (baseline PPA) is the second half of Lab 1 — see the synth guide once
your RTL passes simulation here.

> This scaffold uses **matmul** over an **OBI + CSR** interface as the worked
> example. If you picked a different app or the CV-XIF interface, keep the same
> structure (golden vectors → transactors → self-checking TB) and adapt the
> pieces. CV-XIF transactors come in a later drop.

---

## 0. What you are given

```
rtl/matmul_accel_pkg.sv   parameters + register map  (the TB<->RTL contract)
rtl/matmul_accel.sv       the accelerator  <-- YOU IMPLEMENT THIS (stub)
tb/                       a component library you MOUNT into a testbench:
  obi_if.sv reg_if.sv       interface bundles (wires)
  obi_mem_model.sv          OBI SLAVE RAM      (use if your accel is OBI master)
  obi_master_bfm.sv         OBI MASTER driver  (use if your accel is OBI slave)
  reg_driver.sv             CSR read/write/poll driver
  vector_check.sv           loads the golden vector, compares, reports (in-TB)
  tb_matmul_accel.sv        the TOP tb: wires the pieces for the OBI-master case
model/golden.py           Python golden model -> a.hex b.hex c_golden.hex
model/dump.h + host/      dump the SAME vectors from the real C kernel (host)
data/matmul_accel.hjson   register description for reggen (edit this)
util/vendor.py            vendoring tool; x-heep.vendor.hjson picks the revision
Makefile  *.core  flow/   build / vectors / sim (Verilator, QuestaSim, FuseSoC)
```

The **register map** (`matmul_accel_pkg.sv`) is the one hard contract: the CSR
driver programs `N`, the A/B/C base pointers, and `START`, then polls
`STATUS.done`. CSRs are **control/status/config only** — the matrices move over
OBI, not through registers. Change the map if you like, but update the driver.

## 1. Generate the golden vectors

Two equivalent routes — do at least one, understand both:

```bash
make vectors        # Python golden model (model/golden.py)
make host-vectors   # compile the REAL Lab-0 kernel for your host and dump
```

Both write `vectors/{a,b,c_golden}.hex` (256 words each, row-major). They must
match (same checksum) — that cross-check is the point. **`host-vectors` is how
you make a golden for whatever kernel you actually chose:** put your kernel in
`host/`, wrap the region you accelerate with the `DUMP_HEX(...)` macros from
`model/dump.h`, run it on your machine/the server, done. On the X-HEEP target
those macros compile to nothing, so the same C runs unchanged in Lab 3.

## 2. Generate the CSR block with reggen (recommended)

Instead of hand-decoding the register addresses, generate the CSR block the way
X-HEEP peripherals do — from an HJSON description:

```bash
make vendor   # pull X-HEEP into ./x-heep (reggen generator + reusable IPs)
make regs     # data/matmul_accel.hjson -> rtl/matmul_accel_reg_pkg.sv,
              #                             rtl/matmul_accel_reg_top.sv,
              #                             sw/matmul_accel_regs.h
```

Edit `data/matmul_accel.hjson` to describe your registers; `make regs` runs
reggen (via FuseSoC's `regtool` generator) and emits the `reg_top` block plus
the `reg2hw`/`hw2reg` structs and a C header you will reuse for the driver in
Lab 3. `rtl/matmul_accel.sv` has a commented sketch of how to instantiate the
generated `matmul_accel_reg_top`. `make vendor` also makes the pulp-platform IPs
available as core dependencies — `common_cells` and `tech_cells_generic`
(FIFOs, counters, synchronizers, clock gates) — so you don't reinvent them in
the datapath. This step is optional (you may hand-write the CSRs), but doing it
now is what makes Lab 3 integration routine. `fusesoc`/`regtool` run inside the
`core-v-mini-mcu` conda env.

## 3. Implement the accelerator (`rtl/matmul_accel.sv`)

Fill in the stub. Reference (OBI-master) contract:

- **CSR block** — decode `reg_addr_i`, hold `N`/`A_PTR`/`B_PTR`/`C_PTR`, latch
  the `START` pulse, expose `STATUS.{done,busy}`, always assert `reg_ready_o`.
- **FSM + datapath** — on `START`, read A and B from memory over the **OBI
  master** port, compute `C = A*B` (int32), write C back, raise `STATUS.done`.
- Start with the **naive** version (one MAC, triple loop). Correct first;
  optimisation is Lab 2.

Designing an **OBI slave** instead (TB pushes data in)? Delete the OBI master
port, add a slave port, and in `tb_matmul_accel.sv` swap `obi_mem_model` for
`obi_master_bfm` and use its `write_word`/`read_word` tasks. The CSR driver and
`vector_check` stay the same.

## 4. Simulate — both simulators, same testbench

```bash
make sim        # Verilator 5 (--binary), self-checking
make questa     # QuestaSim / ModelSim (commercial path)
make sim-fusesoc  # same run through the FuseSoC .core (Lab 3 preview)
```

The testbench **does the comparison itself** (`vector_check`): it prints
`TEST PASSED` and exits 0, or `TEST FAILED` and exits non-zero. The stub fails
by design until you implement the datapath. Both simulators must give the
**same** result — that is a graded check.

Waveforms are a debugging aid only: `make waves` then `gtkwave dump.fst`.

## 5. Deliverables

- [ ] `rtl/matmul_accel.sv` implemented; `make sim` prints `TEST PASSED`.
- [ ] `make questa` prints the **same** `TEST PASSED` (upload the transcript).
- [ ] Both golden routes (`make vectors`, `make host-vectors`) produce identical
      vectors — note the shared checksum in your report.
- [ ] Short note: OBI master vs slave — which you chose and why; how the two
      transactors differ.
- [ ] (Lab 1 part 2) baseline synthesis PPA — see the synth guide.

## How it is checked

CI runs the **Verilator** path: build vectors, `make sim`, expect `TEST PASSED`
(exit 0). A non-trivial datapath is required — a testbench that passes without
the accelerator actually driving OBI/CSR does not count. QuestaSim results are
**uploaded artifacts**, checked for the matching pass.

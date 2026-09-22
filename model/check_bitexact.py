#!/usr/bin/env python3
"""Check this lab's golden model against the cookbook's CORDIC rotator.

`model/cordic_golden.py` claims to be bit-exact with the worked example in
`books/examplecookbook/code/cordic/`, where the same rotator exists as VHDL, as
SystemVerilog and as a Python model checked against both. This script is what
makes that claim true rather than aspirational. It compares against two
independent references:

  1. the cookbook's own model, `cordic_model.py`, over a wide sweep of
     (x0, y0, theta);
  2. the vectors the cookbook's RTL testbenches run, `cordic_vectors.txt`,
     which came out of a real simulation of that RTL.

The testbench already pins the RTL in this lab to `cordic_golden.py` on every
`make sim`. This pins `cordic_golden.py` to the cookbook. Together they mean
the accelerator's rotator and the cookbook's rotator produce the same
integers.

The cookbook is a sibling directory of this lab, not a dependency of it: if it
is not there, this check reports that it was skipped and exits 0, so a
standalone checkout of the lab still builds and tests clean.

    python3 model/check_bitexact.py        # or: make bitexact
"""

import pathlib
import random
import sys

HERE = pathlib.Path(__file__).resolve().parent
LAB = HERE.parent
COOKBOOK = LAB.parent / "books" / "examplecookbook" / "code" / "cordic"

sys.path.insert(0, str(HERE))
import cordic_golden as ours  # noqa: E402


def s16(hexstr):
    v = int(hexstr, 16)
    return v - 65536 if v >= 32768 else v


def check_against_model():
    """Sweep + random + corner cases against the cookbook's Python model."""
    sys.path.insert(0, str(COOKBOOK / "python"))
    import cordic_model as book  # noqa: E402

    # The constants have to agree before the arithmetic can.
    for name in ("DW", "QF", "AW", "QA", "N", "GL", "GM", "HALF_PI", "X0_UNIT"):
        if getattr(ours, name) != getattr(book, name):
            print(f"constant {name} differs: ours={getattr(ours, name)} "
                  f"cookbook={getattr(book, name)}")
            return 1

    cases = [(ours.X0_UNIT, 0, t) for t in
             range(-ours.PI_EXT, ours.PI_EXT + 1, 37)]           # cos/sin sweep
    cases += [(ours.X0_UNIT, 0, t) for t in
              (0, 1, -1, ours.PI_EXT, -ours.PI_EXT,              # corners
               ours.PI_EXT // 2, -ours.PI_EXT // 2,
               ours.PI_EXT // 2 + 1, -ours.PI_EXT // 2 - 1)]
    random.seed(7)
    cases += [(random.randint(-32768, 32767),                    # arbitrary vectors
               random.randint(-32768, 32767),
               random.randint(-ours.PI_EXT, ours.PI_EXT))
              for _ in range(3000)]

    bad = 0
    for x, y, t in cases:
        got = ours.cordic_rot(x, y, t)
        want = book.cordic_rot(x, y, t)
        if got != want:
            bad += 1
            if bad <= 3:
                print(f"MISMATCH x={x} y={y} theta={t}: ours={got} cookbook={want}")
    print(f"cookbook model : {len(cases)} cases, {bad} mismatches")
    return bad


def check_against_vectors():
    """The vectors the cookbook's VHDL and SystemVerilog testbenches run."""
    path = COOKBOOK / "vectors" / "cordic_vectors.txt"
    if not path.is_file():
        print(f"cookbook vectors: {path} not present "
              f"(regenerate with `make vectors` in the cookbook), skipped")
        return 0

    rows = [ln.split() for ln in path.read_text().splitlines()
            if ln.strip() and not ln.startswith("#")]
    bad = 0
    for r in rows:
        got = ours.cordic_rot(s16(r[0]), s16(r[1]), s16(r[2]))
        want = (s16(r[3]), s16(r[4]))
        if got != want:
            bad += 1
            if bad <= 3:
                print(f"MISMATCH x={s16(r[0])} y={s16(r[1])} theta={s16(r[2])}: "
                      f"ours={got} rtl={want}")
    print(f"cookbook vectors: {len(rows)} cases, {bad} mismatches")
    return bad


def main():
    if not COOKBOOK.is_dir():
        print(f"cookbook not found at {COOKBOOK} -- check skipped")
        return 0
    return 1 if (check_against_model() + check_against_vectors()) else 0


if __name__ == "__main__":
    sys.exit(main())

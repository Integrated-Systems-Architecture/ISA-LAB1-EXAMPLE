#!/usr/bin/env python3
"""Bit-exact golden model of cordic_accel, and the test vector generator.

Every line of `cordic_rot` below maps onto one line of the RTL: the same
constants, the same guard bits, the same arithmetic shifts. The model is the
reference, the RTL has to match it exactly -- not "within a few LSB". A
tolerance check would hide the class of bug that actually happens in fixed
point design (a shift in the wrong direction, a truncation that rounds the
wrong way), which is why the testbench compares integers.

The same model lives in the cookbook (`books/examplecookbook/code/cordic/
python/cordic_model.py`), where it is checked against a VHDL and a SystemVerilog
implementation of the same rotator. This file is standalone on purpose: this
lab must build without the cookbook checked out.

Number formats
--------------
    x, y      signed, DW bits, QF fractional bits   (Q1.14 -> [-2, 2) )
    theta     signed, AW bits, QA fractional bits   (Q2.13 -> [-4, 4) )

    internal x, y   IW = DW + GL + GM bits, QF + GL fractional bits
    internal z      IA = AW + GL      bits, QA + GL fractional bits

GL adds precision at the bottom, GM adds headroom at the top so the CORDIC
processing gain cannot overflow the datapath.

Usage
-----
    python3 model/cordic_golden.py                 # write vectors/
    python3 model/cordic_golden.py -n 64 -o out    # 64 angles, elsewhere
    python3 model/cordic_golden.py --selfcheck     # accuracy vs math.cos/sin
"""

import argparse
import math
import os

# ---------------------------------------------------------------------------
# Parameters -- keep in step with rtl/cordic_pkg.sv
# ---------------------------------------------------------------------------
DW = 16          # external x/y width
QF = 14          # external x/y fractional bits
AW = 16          # external angle width
QA = 13          # external angle fractional bits
N = 14           # number of CORDIC micro-rotations
GL = 2           # guard bits added at the LSB side
GM = 2           # guard bits added at the MSB side

IW = DW + GL + GM        # internal x/y width           (20)
IQF = QF + GL            # internal x/y fractional bits (16)
IA = AW + GL             # internal angle width         (18)
IQA = QA + GL            # internal angle frac. bits    (15)

HALF_PI = round(math.pi / 2 * (1 << IQA))     # 51472
PI_INT = round(math.pi * (1 << IQA))          # 102944
PI_EXT = round(math.pi * (1 << QA))           # 25736, the input range limit

ATAN = [round(math.atan(2.0 ** -i) * (1 << IQA)) for i in range(N)]


def cordic_gain():
    """The processing gain K = prod sqrt(1 + 2**-2i)."""
    k = 1.0
    for i in range(N):
        k *= math.sqrt(1.0 + 2.0 ** (-2 * i))
    return k


K = cordic_gain()                              # ~1.64676
X0_UNIT = round((1 << QF) / K)                 # 9949, the "unit circle" seed


# ---------------------------------------------------------------------------
# Fixed point helpers
# ---------------------------------------------------------------------------
def to_signed(value, width):
    """Interpret the low `width` bits of `value` as two's complement."""
    value &= (1 << width) - 1
    if value & (1 << (width - 1)):
        value -= 1 << width
    return value


def wrap(value, width):
    """What a register of `width` bits does when the adder overflows it."""
    return to_signed(value, width)


def asr(value, shift):
    """Arithmetic shift right. Python's >> on a negative int floors, which is
    exactly what a hardware arithmetic shift does."""
    return value >> shift


def saturate(value, width):
    lo = -(1 << (width - 1))
    hi = (1 << (width - 1)) - 1
    return max(lo, min(hi, value))


def q_to_float(value, frac):
    return value / float(1 << frac)


def float_to_q(value, frac, width):
    return saturate(int(round(value * (1 << frac))), width)


# ---------------------------------------------------------------------------
# The bit-exact model of cordic_rot
# ---------------------------------------------------------------------------
def cordic_rot(x0, y0, theta):
    """Rotate (x0, y0) by `theta`. Integers in, integers out, external format.

    Returns (x, y) = K * (x0 cos t - y0 sin t), K * (x0 sin t + y0 cos t).
    """
    # 1. widen into the internal format
    x = x0 << GL
    y = y0 << GL
    z = theta << GL

    # 2. coarse rotation: the series converges only for |z| <= 1.7433 rad, so
    #    take out a whole quadrant first. Both rotations are exact.
    if z > HALF_PI:
        x, y, z = -y, x, z - HALF_PI
    elif z < -HALF_PI:
        x, y, z = y, -x, z + HALF_PI

    # 3. the micro-rotation loop: shift, add, table lookup. No multiplier.
    for i in range(N):
        dx = asr(y, i)
        dy = asr(x, i)
        if z >= 0:                       # rotate counter-clockwise
            xn, yn, zn = x - dx, y + dy, z - ATAN[i]
        else:                            # rotate clockwise
            xn, yn, zn = x + dx, y - dy, z + ATAN[i]
        x, y, z = wrap(xn, IW), wrap(yn, IW), wrap(zn, IA)

    # 4. narrow back down, with saturation
    return saturate(asr(x, GL), DW), saturate(asr(y, GL), DW)


def sincos(theta_rad):
    """cos/sin of an angle in radians, through the fixed point model."""
    theta = float_to_q(theta_rad, QA, AW)
    x, y = cordic_rot(X0_UNIT, 0, theta)
    return q_to_float(x, QF), q_to_float(y, QF)


# ---------------------------------------------------------------------------
# The accelerator model: memory in, memory out
# ---------------------------------------------------------------------------
def accel_run(thetas, seed_x=X0_UNIT, seed_y=0):
    """What cordic_accel writes to DST, given the words at SRC.

    One 32-bit word per element in and out; the result word is
    {y[15:0], x[15:0]}, which is what the RTL packs.
    """
    out = []
    for t in thetas:
        x, y = cordic_rot(seed_x, seed_y, to_signed(t, AW))
        out.append(((y & 0xFFFF) << 16) | (x & 0xFFFF))
    return out


# ---------------------------------------------------------------------------
# Vector generation
# ---------------------------------------------------------------------------
def make_angles(n):
    """A sweep over the full input range, endpoints included, plus the corner
    cases that break a careless implementation: 0, +-pi, +-pi/2 (the coarse
    rotation boundary) and +-1 LSB either side of it."""
    corners = [0, PI_EXT, -PI_EXT, PI_EXT // 2, -PI_EXT // 2,
               PI_EXT // 2 + 1, -PI_EXT // 2 - 1, 1, -1]
    corners = [c for c in corners if -PI_EXT <= c <= PI_EXT]

    if n <= len(corners):
        return corners[:n]

    sweep_n = n - len(corners)
    sweep = [(-PI_EXT + (2 * PI_EXT * i) // max(sweep_n - 1, 1))
             for i in range(sweep_n)]
    return corners + sweep


def write_hex(path, words):
    """One 32-bit word per line, the format $readmemh expects."""
    with open(path, "w") as f:
        for w in words:
            f.write(f"{w & 0xFFFFFFFF:08x}\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-n", "--num", type=int, default=64,
                    help="number of angles (default 64)")
    ap.add_argument("-o", "--outdir", default="vectors",
                    help="output directory (default vectors)")
    ap.add_argument("--seed-x", type=int, default=X0_UNIT,
                    help=f"x0 of the rotated vector (default {X0_UNIT}, gives cos/sin)")
    ap.add_argument("--seed-y", type=int, default=0, help="y0 (default 0)")
    ap.add_argument("--selfcheck", action="store_true",
                    help="report the model's accuracy against math.cos/sin and exit")
    args = ap.parse_args()

    if args.selfcheck:
        print(f"N = {N}, K = {K:.6f}, X0_UNIT = {X0_UNIT}, PI_EXT = {PI_EXT}")
        worst = 0.0
        steps = 721
        for k in range(steps):
            ang = -math.pi + 2 * math.pi * k / (steps - 1)
            ang = max(-math.pi, min(math.pi, ang))
            c, s = sincos(ang)
            worst = max(worst, abs(c - math.cos(ang)), abs(s - math.sin(ang)))
        print(f"worst |error| over [-pi, pi] = {worst:.6f} "
              f"({worst * (1 << QF):.2f} LSB)")
        return

    os.makedirs(args.outdir, exist_ok=True)
    angles = make_angles(args.num)
    results = accel_run(angles, args.seed_x, args.seed_y)

    # A second run with the seed vector turned 90 degrees. It exercises the
    # other half of the datapath (y is no longer zero, so both accumulators
    # carry real data) and, because the testbench runs it after the first, it
    # also proves the accelerator restarts cleanly.
    swap_x, swap_y = -args.seed_y, args.seed_x
    results_swap = accel_run(angles, swap_x, swap_y)

    write_hex(os.path.join(args.outdir, "theta.hex"),
              [a & 0xFFFF for a in angles])          # sign extension is the DUT's job
    write_hex(os.path.join(args.outdir, "golden.hex"), results)
    write_hex(os.path.join(args.outdir, "golden_swap.hex"), results_swap)
    with open(os.path.join(args.outdir, "config.txt"), "w") as f:
        # count in decimal, seeds in hex: the testbench reads them with
        # %d %h %h, and a hex seed avoids any sign ambiguity.
        f.write(f"{len(angles)} {args.seed_x & 0xFFFF:04x} {args.seed_y & 0xFFFF:04x} "
                f"{swap_x & 0xFFFF:04x} {swap_y & 0xFFFF:04x}\n")

    print(f"{len(angles)} angles -> {args.outdir}/theta.hex, "
          f"{args.outdir}/golden.hex, {args.outdir}/golden_swap.hex, "
          f"{args.outdir}/config.txt")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Generate QuikMini test vectors and golden results.

Usage: python3 scripts/gen_vectors.py [out_file]     (default build/vectors.txt)

Writes a whitespace-separated text file that tb/tb_quikmini.sv reads with
$fscanf:

    <number of tests>
    per test:
      <name> <K> <accum>
      <A: N*K ints, row-major>
      <B: K*N ints, row-major>
      <expected C after this run: N*N ints, row-major>

The golden model is a plain integer matmul. ACCUM runs add onto the previous
run's C, exactly like the hardware.
"""
import os
import random
import sys

N = 8
KMAX = 256
INT32_MIN, INT32_MAX = -(2**31), 2**31 - 1


def rand_mat(rng, rows, cols):
    return [[rng.randint(-128, 127) for _ in range(cols)] for _ in range(rows)]


def const_mat(rows, cols, value):
    return [[value] * cols for _ in range(rows)]


def matmul(a, b, k):
    return [[sum(a[i][t] * b[t][j] for t in range(k)) for j in range(N)] for i in range(N)]


def build_tests(rng):
    """Each test is (name, K, accum, A, B)."""
    tests = []

    # Edge cases
    tests.append(("k1_random", 1, 0, rand_mat(rng, N, 1), rand_mat(rng, 1, N)))
    eye = [[1 if i == j else 0 for j in range(N)] for i in range(N)]
    tests.append(("identity", N, 0, eye, rand_mat(rng, N, N)))
    tests.append(("zeros", 32, 0, const_mat(N, 32, 0), rand_mat(rng, 32, N)))
    tests.append(("max_neg_x_neg", KMAX, 0, const_mat(N, KMAX, -128), const_mat(KMAX, N, -128)))
    tests.append(("max_pos_x_neg", KMAX, 0, const_mat(N, KMAX, 127), const_mat(KMAX, N, -128)))

    # Random matrices across K (also the utilization sweep)
    for k in (8, 16, 32, 64, 100, 128, 224, 255, 256):
        tests.append((f"random_k{k}", k, 0, rand_mat(rng, N, k), rand_mat(rng, k, N)))

    # Accumulate mode: split K = 512 (> KMAX) across three runs
    for name, k, accum in (("split_k_part1", 128, 0), ("split_k_part2", 128, 1), ("split_k_part3", 256, 1)):
        tests.append((name, k, accum, rand_mat(rng, N, k), rand_mat(rng, k, N)))

    # A normal run right after accumulating must start fresh
    tests.append(("fresh_after_accum", 64, 0, rand_mat(rng, N, 64), rand_mat(rng, 64, N)))

    return tests


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "build/vectors.txt"
    rng = random.Random(18240)
    tests = build_tests(rng)

    c_prev = const_mat(N, N, 0)
    lines = [str(len(tests))]
    for name, k, accum, a, b in tests:
        assert 1 <= k <= KMAX and len(a) == N and len(a[0]) == k and len(b) == k
        c = matmul(a, b, k)
        if accum:
            c = [[c[i][j] + c_prev[i][j] for j in range(N)] for i in range(N)]
        assert all(INT32_MIN <= v <= INT32_MAX for row in c for v in row), name
        c_prev = c

        lines.append(f"{name} {k} {accum}")
        lines.append(" ".join(str(v) for row in a for v in row))
        lines.append(" ".join(str(v) for row in b for v in row))
        lines.append(" ".join(str(v) for row in c for v in row))

    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    with open(out, "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"wrote {len(tests)} tests to {out}")


if __name__ == "__main__":
    main()

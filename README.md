# QuikMini

An 8×8 INT8 systolic-array matrix multiply unit in SystemVerilog, built as an inference offload engine for the [KLW-32](../KLW-32) CPU.

QuikMini computes **C = A × B**, where A is 8×K and B is K×8 (signed INT8) and C is 8×8 (signed INT32), for any K from 1 to 256. Larger K is split across runs with accumulate mode.

| | |
|---|---|
| Array | 8×8 output-stationary, 64 INT8 multiply-accumulate (MAC) cells, INT32 accumulators |
| Peak throughput | 12.8 GOPS at 100 MHz (64 MACs × 2 ops × 100 MHz) |
| Run latency | K + 15 cycles |
| PE utilization | K / (K + 15): **94.5% at K = 256**, measured in simulation (12.1 GOPS sustained) |
| Interface | 32-bit word-addressed bus with KLW-32 memory timing |
| Target | Spartan-7 XC7S50 at 100 MHz (timing not run yet, see [Timing](#timing)) |

## How it works

```
                 B buffer (1 bank per column)
                 │      │            │
                 └─ skew: column j delayed j cycles
                 ▼      ▼            ▼
A buffer ─skew─▶ PE00 ─▶ PE01 ─▶ ... ─▶ PE07
(1 bank          │      │            │
 per row)  ────▶ PE10 ─▶ PE11 ─▶ ... ─▶ PE17
  row i          ...
  delayed  ────▶ PE70 ─▶ PE71 ─▶ ... ─▶ PE77
  i cycles
```

- **Output-stationary dataflow.** Each PE owns one output, C[i][j], and accumulates it in place. A values flow east and B values flow south, one hop per cycle. Any K works without moving partial sums out of the array.
- **Skew.** Row i of A and column j of B enter i and j cycles late, so PE(i,j) gets a[i][k] and b[k][j] on the same cycle.
- **Control travels with the data.** `valid`, `first` and `last` flags move east alongside A. `first` starts a new sum (`acc <= a*b`), so there is no global clear. `last` copies the finished sum into a separate result register, so results stay readable while the next run computes.
- **Buffers.** There is one bank per row of A and one per column of B. Every bank reads the same address k each cycle, so banks never conflict.
- **Measured, not computed.** Hardware counters record busy cycles and the number of PEs that did a MAC each cycle. Utilization is `MACS / (64 × CYCLES)`.

A run is busy for K + 15 cycles: K cycles to stream operands, 1 cycle of buffer read latency, and 14 cycles (2 × (8 − 1)) for the skew to fill and drain the array.

## Programming model

Word addresses (N = 8, KMAX = 256):

| Address | Name | Access | Meaning |
|---|---|---|---|
| `0x0000` | CTRL | W | bit0 START, bit1 ACCUM (add onto the previous C instead of overwriting) |
| `0x0001` | STATUS | R | bit0 BUSY, bit1 DONE, bit2 ERR (START with K = 0 or K > 256) |
| `0x0002` | K | RW | inner dimension, 1–256 |
| `0x0003` | CYCLES | R | busy cycles of the last run |
| `0x0004` | MACS | R | MACs done in the last run |
| `0x0005` | ID | R | `0x514D0001` ("QM", version 1) |
| `0x0006` | CONFIG | R | `{KMAX[15:0], N[15:0]}` |
| `0x0800 + i*8 + j` | C[i][j] | R | signed INT32 result |
| `0x1000 + i*256 + k` | A[i][k] | W | signed INT8 in `wdata[7:0]` |
| `0x1800 + k*8 + j` | B[k][j] | W | signed INT8 in `wdata[7:0]` |

Read data comes back the cycle after `re`, the same timing as KLW-32's `mem.sv`. QuikMini stores one INT8 per word because KLW-32 is word-addressed with no byte loads, so this is the layout KLW-32 software will use anyway.

**A run:** write A, B and K, write `CTRL = 1`, poll STATUS until DONE, then read C. Don't write A or B while BUSY.

**K > 256:** split K into chunks. Run the first chunk normally and the rest with `CTRL = 3` (START + ACCUM). The test suite does K = 512 as 128 + 128 + 256.

## Running

Requires Verilator 5 and Python 3.

```sh
make test        # lint + PE unit test + top-level test
make lint        # verilator --lint-only -Wall on the RTL
make pe          # PE unit test
make sim         # top-level test (regenerates vectors if needed)
make sim TRACE=1 # also writes build/quikmini.vcd
```

- **`tb/tb_pe.sv`:** 500 random dot products with random bubbles (valid low, garbage on the other inputs), extreme values, operand forwarding, and accumulate.
- **`tb/tb_quikmini.sv`:** drives the bus like a host CPU. It checks the ID/CONFIG registers and the error flag for bad K. It then runs every vector from `scripts/gen_vectors.py` and checks all 64 C words against an integer reference model, plus the CYCLES and MACS counters against the latency model.

## Results

All 18 vector tests pass. Measured in simulation (`make sim`):

| K | Cycles | MACs | PE utilization |
|---:|---:|---:|---:|
| 1 | 16 | 64 | 6.2% |
| 8 | 23 | 512 | 34.8% |
| 16 | 31 | 1,024 | 51.6% |
| 32 | 47 | 2,048 | 68.1% |
| 64 | 79 | 4,096 | 81.0% |
| 128 | 143 | 8,192 | 89.5% |
| 224 | 239 | 14,336 | 93.7% |
| 256 | 271 | 16,384 | **94.5%** |

At K = 256 and 100 MHz that is 12.1 GOPS sustained, out of 12.8 GOPS peak. Utilization is limited only by the fixed 15-cycle fill/drain cost, which is spread over more work as K grows.

## Timing

`make synth` runs Vivado out-of-context on a Spartan-7 XC7S50 (`xc7s50csga324-1`) with a 10 ns clock. It writes timing and utilization reports to `build/syn/` and prints WNS and estimated Fmax. Vivado doesn't run on macOS, so run it on a Linux machine.

Not run yet. Expectations:
- The 64 MACs should map to DSP48E1 slices (the XC7S50 has 120).
- The critical path should be the PE's multiply-add.
- 100 MHz should have plenty of margin.

The design uses synchronous resets (KLW-32 uses async) because DSP48 registers only support synchronous reset.

## Files

| Path | Contents |
|---|---|
| `rtl/qm_pe.sv` | Processing element: INT8 MAC, INT32 accumulator, forwarding registers |
| `rtl/qm_array.sv` | 8×8 grid of PEs |
| `rtl/qm_skew.sv` | Triangular input delay lines |
| `rtl/qm_bank.sv` | Operand buffer bank (one write port, one registered read port) |
| `rtl/quikmini.sv` | Top level: bus decode, CSRs, controller, buffers, counters |
| `tb/` | Testbenches |
| `scripts/gen_vectors.py` | Test vectors and integer reference model |
| `syn/` | Vivado build script and clock constraint |

## Next: connecting to the KLW-32

QuikMini is standalone for now. The plan:

1. Map QuikMini into KLW-32's unused address space (`0x01000–0xDFFFF`).
2. Write a KLW-32 assembly driver.
3. Compare against a software triple-loop matmul across matrix sizes.

A DMA engine that reads A and B straight from KLW-32 RAM would remove the CPU copy loop, which would otherwise dominate the speedup.

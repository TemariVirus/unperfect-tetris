# perfect-tetris

Blazingly fast Tetris perfect clear solver.

## Run

```bash
zig build run
```

Finds all perfect clear solutions of a give height from an empty board, and
saves the solutions to disk.

Settings may be adjusted in the top-level declarations in `src/main.zig`. If
the height is 4 or less, the `-Dsmall` option may be passed to the compiler for
a potential speedup.

## Demo

```bash
zig build demo
```

Continuously solves perfect clears and displays the solutions in the terminal.

To change the speed of the demo, adjust the `FRAMERATE` constant in `src/demo.zig`.

## Test

```bash
zig build test
```

Runs all tests.

## Benchmark

```bash
zig build bench
```

Runs the benchmarks.

If the height of the PC benchmark is 4 or less, the `-Dsmall` option may be
passed to the compiler for a potential speedup.

## Train

```bash
zig build train
```

Trains a population of neural networks to solve perfect clears as fast as possible.
The population is saved at the end of every generation.

Settings may be adjusted in the top-level declarations in `src/train.zig`. If
the height is 4 or less, the `-Dsmall` option may be passed to the compiler for
a potential speedup.

## Display

```bash
zig build display -- PATH
```

Displays the perfect clear solutions saved at `PATH`.

## Number of possible next sequences (with hold)*

| length |  non-equivalent |     time     |
|--------|-----------------|--------------|
|    1   |              28 |       <100ns |
|    2   |             196 |       <100ns |
|    3   |           1,365 |       <100ns |
|    4   |           9,198 |       <100ns |
|    5   |          57,750 |       1.03ms |
|    6   |         326,340 |      3.006ms |
|    7   |       1,615,320 |     19.363ms |
|    8   |       6,849,360 |     31.392ms |
|    9   |      24,857,280 |     89.685ms |
|   10   |      79,516,080 |    230.081ms |
|   11   |     247,474,080 |    647.921ms |
|   12   |     880,180,560 |       2.335s |
|   13   |   3,683,700,720 |       9.252s |
|   14   |  15,528,492,000 |      42.102s |
|   15   |  57,596,696,640 |     3m7.601s |
|   16   | 189,672,855,120 |   15m31.773s |
|   17   | 549,973,786,320 | 1h18m28.595s |

*Two sequences are considered equivalent if the set of all possible structures that can be built each are equal.

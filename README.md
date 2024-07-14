# perfect-tetris

Blazingly fast Tetris perfect clear solver.

## Zig Version

0.13.0

## Build commands

### Run

```bash
zig build run
```

Finds all perfect clear solutions of a give height from an empty board, and
saves the solutions to disk.

Settings may be adjusted in the top-level declarations in `src/main.zig`. If
the height is 4 or less, the `-Dsmall` option may be passed to the compiler for
a potential speedup.

### Demo

```bash
zig build demo
```

Continuously solves perfect clears and displays the solutions in the terminal.

To change the speed of the demo, adjust the `FRAMERATE` constant in `src/demo.zig`.

### Test

```bash
zig build test
```

Runs all tests.

### Benchmark

```bash
zig build bench
```

Runs the benchmarks.

If the height of the PC benchmark is 4 or less, the `-Dsmall` option may be
passed to the compiler for a potential speedup.

### Train

```bash
zig build train
```

Trains a population of neural networks to solve perfect clears as fast as possible.
The population is saved at the end of every generation.

Settings may be adjusted in the top-level declarations in `src/train.zig`. If
the height is 4 or less, the `-Dsmall` option may be passed to the compiler for
a potential speedup.

### Display

```bash
zig build display -- PATH
```

Displays the perfect clear solutions saved at `PATH`. Press `enter` to display
the next solution.

### Validate

```bash
zig build validate -- PATH
```

Validates the perfect clear solutions saved at `PATH`.

## .pc file format

The `.pc` file format is a binary format that stores perfect clear solutions.

The `.pc` format can only store solutions with up to 15 placements, and that
start with an empty board. The format consists of only a list of solutions with
no padding or metadata. The format of a solution is as follows:

| bytes | name       | description                                      |
| ----- | ---------- | ------------------------------------------------ |
| 0-5   | sequence   | The sequence of hold and next pieces             |
| 6-7   | holds      | 15 binary flags indicating where holds are used  |
| 8+    | placements | The list of placements that make up the solution |

### Sequence

The sequence is a 6-byte integer that stores the sequence of hold and next
pieces (a total of 16 3-bit values). The sequence is stored in little-endian
order. Bits 0-2 indicate the hold piece, bits 3-5 indicate the current piece,
bits 6-8 indicate the first piece in the next queue, bits 9-11 indicate the
second piece in the next queue, etc. Each 3-bit value maps to a different
piece:

| value | piece    |
| ----- | -------- |
| 000   | I        |
| 001   | O        |
| 010   | T        |
| 011   | S        |
| 100   | Z        |
| 101   | L        |
| 110   | J        |
| 111   | sentinel |

Once a sentinel value is reached, all subsequent values should also be sentinel
values. If no sentinel value is reached, the sequence is assumed to have the
maximum length of 16.

### Holds

The holds are stored as a 2-byte integer in little-endian order. The i-th bit
indicates whether a hold was used at the i-th placement. A `0` indicates no
hold, and a `1` indicates a hold. As there is a maxium of 15 placements, the
last bit is always `0`.

### Placements

The list of placements is stored in little-endian order, and the length of this
list is always the length of the sequence minus one. Each placement is stored
as a single byte, with the following format:

| bits | name     | description                                   |
| ---- | -------- | --------------------------------------------- |
| 0-1  | facing   | The direction the piece is facing when placed |
| 2-7  | position | The position of the piece. x + 10y            |

The type of piece is determined by the sequence and holds.

A value of '0' for facing indicates the piece is facing north; '1' indicates
east; '2' indicates south, and '3' indicates west.

Position is a value in the range [0, 59]. The x-coordinate is this value modulo
10, and the y-coordinate is this value divided by 10 (rounded down). The x- and
y-coordinates represent the center of the piece as defined by
[SRS true rotation](https://harddrop.com/wiki/File:SRS-true-rotations.png). The
x-axis starts at 0 at the leftmost column and increases rightwards. The y-axis
starts at 0 at the bottom row and increases upwards.

## Number of possible next sequences (with hold)

| length | non-equivalent\*  | time         |
| ------ | ----------------- | ------------ |
| 0      | 7                 | trivial      |
| 1      | 28                | <100ns       |
| 2      | 196               | <100ns       |
| 3      | 1,365             | <100ns       |
| 4      | 9,198             | <100ns       |
| 5      | 57,750            | 1.03ms       |
| 6      | 326,340           | 3.006ms      |
| 7      | 1,615,320         | 19.363ms     |
| 8      | 6,849,360         | 31.392ms     |
| 9      | 24,857,280        | 89.685ms     |
| 10     | 79,516,080        | 230.081ms    |
| 11     | 247,474,080       | 647.921ms    |
| 12     | 880,180,560       | 2.335s       |
| 13     | 3,683,700,720     | 9.252s       |
| 14     | 15,528,492,000    | 42.102s      |
| 15     | 57,596,696,640    | 3m7.601s     |
| 16     | 189,672,855,120   | 15m31.773s   |
| 17     | 549,973,786,320   | 1h18m28.595s |
| 18     | 1,554,871,505,040 | 2h17m20.902s |

\*Two sequences are considered equivalent if the set of all possible structures that can be built by each are equal.

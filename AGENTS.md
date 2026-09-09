<!--
Copyright 2026 Mattia Giambirtone & All Contributors

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
-->

# Working on Heimdall

Heimdall is a UCI chess engine written in Nim, with NNUE evaluation and an
optional terminal UI. Use the existing Makefile as the source of truth for
compiler flags, network architecture settings, and build targets.

## Build and verification

- **Never use `nim check` to verify changes.** Verify Nim changes by compiling
  through the Makefile, using `make dev` under normal circumstances.
- **Use `make dev` when all Makefile dependencies are already satisfied locally,
  so no network downloads need to happen.** It invokes the native build with
  `SKIP_DEPS=1`, skipping dependency installation and network fetching, and writes
  the engine to `bin/heimdall` (`.exe` on Windows).
- Local prerequisites include Nim **2.2.6** (pinned in `heimdall.nimble`), the
  declared Nimble packages, Clang, the platform linker (LLD on Linux/Windows,
  Apple ld on macOS), and the actual NNUE weights selected by `EVALFILE`.
  The default weights are `networks/files/gramr.bin`; a Git LFS pointer is not
  sufficient.
- **`make native` should almost never be needed. Use it only if `make dev` fails
  for reasons related to missing dependencies.** Inspect the failure first:
  `make native` runs `nimble install -d`, initializes the network submodule, and
  fetches the selected weights using Git LFS, so it may access the network.
  Do not use it to retry source-code compilation errors.
- Do not run bare `make`: its default target is intended for OpenBench and does
  not prepare the network. `nimble build` is unsupported. Do not replace the
  Makefile with ad hoc Nim compiler invocations.
- Keep validation proportional to the change. Documentation-only changes do not
  require an engine build. Report the checks actually run and any blockers.

## Tests and benchmarks

Run commands from the repository root, with dependencies and weights already
available. Choose tests relevant to the affected behavior:

- `make test`: builds `bin/testdall` with `IS_TEST=1` and runs a depth-9 bench.
- After `make dev`, run
  `python -m unittest discover -s tests -p 'test_*.py'` for UCI and Python test-tool
  regressions. To enable runtime checks, build with
  `make dev IS_TEST=1 EXE_BASE=bin/testdall` and set `HEIMDALL=bin/testdall` when
  running the Python tests.
- `make test-suite`: runs deeper benches and perft comparisons. This is slow and
  requires Python and Stockfish on `PATH`; see `python tests/suite.py -h` for
  explicit binary paths.
- `make bench`: builds with `make dev` and runs the engine's search benchmark.

<!-- Testing documentation consolidated with assistance from AI agents. -->

### Focused correctness tests

Build standalone Nim tests through `make dev`, using `MAIN`, `EXE_BASE`, and an
absolute `EVALFILE` path. Use `IS_TEST=1` for correctness checks and optimized
default builds for speed measurements.

Use focused tests for incremental/fresh NNUE evaluation, threat indexing,
move-generation and state/hash invariants, and search limits. NNUE checks include
pending updates, cloning, the 255-ply boundary, and all 960 castling arrangements
for both colors:

```sh
make dev MAIN=tests/test_nnue.nim IS_TEST=1 EXE_BASE=bin/test-nnue EVALFILE="$PWD/networks/files/gramr.bin"
bin/test-nnue
make dev MAIN=tests/test_movegen.nim IS_TEST=1 EXE_BASE=bin/test-movegen EVALFILE="$PWD/networks/files/gramr.bin"
bin/test-movegen
make dev MAIN=tests/test_limits.nim IS_TEST=1 EXE_BASE=bin/test-limits EVALFILE="$PWD/networks/files/gramr.bin"
bin/test-limits
make dev MAIN=tests/test_threat_index.nim IS_TEST=1 EXE_BASE=bin/test-threat-index EVALFILE="$PWD/networks/files/gramr.bin"
bin/test-threat-index
make dev MAIN=tests/test_threats.nim IS_TEST=1 EXE_BASE=bin/test-threats EVALFILE="$PWD/networks/files/gramr.bin"
bin/test-threats
```

The threat-index test checks every table entry against geometric attacks and
explicit exclusion rules, verifies the color bounds, and checks retained feature
indices for collisions and overflow. It also checks both indexers across perspectives
and mirroring, and verifies the perspective masks. The threat-collection test compares
runtime attacks and collected features against independent board geometry, including
friendly pawn defenses, writable output slices, and positions before and after special
moves and undo. Fixed expected indices from Viridithas additionally verify both
perspectives of the starting position and Kiwipete.

To check the scalar NNUE path, repeat its build with
`AVX2_SUPPORTED=0 AVX512_SUPPORTED=0 VNNI_SUPPORTED=0`; the diagnostic prints
the selected backend. Native builds append SIMD defines after `EXTRA_NFLAGS`,
so `EXTRA_NFLAGS=-u:simd` alone does not select the scalar path.

`tests/test_alloc.nim` checks allocation alignment. Add `EXTRA_NFLAGS=-d:noTHP`
to its build to exercise the allocator without huge-page advice; the same flag
can be used with the NNUE test.

### Performance comparisons

For performance comparisons, build separate baseline and candidate executables
with identical flags and network, then alternate runs on one CPU:

```sh
python scripts/compare_performance.py bin/baseline bin/candidate --cpu 2 --pairs 12 --perf --output comparison.json
```

The script checks node counts and saves paired timings, hardware counters and a
bootstrap interval. Omit `--perf` if hardware counters are unavailable. Use
`--mode perft --depth 7` for movegen comparisons. `tests/bench_nnue.nim` and
`tests/bench_setup.nim` provide separate inference and worker-setup benchmarks;
build them with the same `MAIN`/`EVALFILE` pattern. Measure optimized builds for
speed and use `IS_TEST=1` for correctness checks. Confirm microbenchmark gains
with full search: a repeated NNUE input corpus can hide branch-prediction costs.

For real UCI node/time budgets on a selected FEN corpus, use `--mode uci`:

```sh
python scripts/compare_performance.py bin/baseline bin/candidate --mode uci --positions src/heimdall/resources/misc/bench.txt --count 24 --offset 1 --stride 2 --limit-kind nodes --limit 200000 --cpu 2 --pairs 8 --perf --output comparison-uci.json
```

Use `--limit-kind time --limit 200` for 200 milliseconds per position. UCI NPS
uses the summed final search node/time reports, excluding engine startup and
position resets; raw results also record whole-process wall time. Fixed-node,
single-thread comparisons require matching per-position nodes, depths and best
moves. Timed and multithreaded searches do not have identical trees and are not
playing-strength tests. `--count`, `--offset` and `--stride` select distinct,
normalized FENs; too-short or incomplete searches are rejected.

### Profile-guided compilation

Optional profile-guided compilation is available through the same dev target:

```sh
make dev PGO=1 EXE_BASE=bin/heimdall-pgo
```

This needs Python and a matching `llvm-profdata` installation. It builds an
instrumented engine, trains with node and time budgets, merges the profiles, and
rebuilds using them. The default training set is 24 even-indexed positions from
the built-in benchmark corpus; the odd-indexed selection above is held out.
The ordinary full benchmark includes training positions, so it is not a held-out
PGO validation. Profile artifacts stay in ignored `build/pgo/`. Override
`PGO_DIR`, `PGO_POSITIONS`, `PGO_TRAIN_ARGS`, `PGO_TRAIN_NODES`, or `PGO_TRAIN_MSEC`
to customize training. Normal dev and OpenBench builds do not enable PGO.

## Project layout

- `src/heimdall.nim`: executable entry point and command handling.
- `src/heimdall/`: board representation, move generation, search, transposition
  tables, evaluation, and NNUE inference.
- `src/heimdall/uci/`: protocol parsing, sessions, and search workers.
- `src/heimdall/tui/`: terminal UI, play/analysis flows, input, and rendering.
- `src/heimdall/util/`: shared helpers, perft, SIMD, memory allocation, tuning,
  and data formats.
- `tests/`: regression tests, perft positions, and focused benchmarks.
- `scripts/`: performance, release, and development utilities.
- `networks/`: Git submodule containing the NNUE weights managed by Git LFS.

## Editing conventions

- Follow nearby Nim code: four-space indentation, existing naming conventions,
  grouped imports where appropriate, and `##` documentation for public APIs.
- Preserve unrelated working-tree changes. Keep patches focused and avoid
  incidental formatting or dependency/network updates.
- Treat search, move generation, NNUE, SIMD, and allocation code as performance
  sensitive. Support optimization claims with measurements and check correctness
  separately from speed.
- When changing position or evaluation state, check make/unmake, cloning,
  incremental updates, and special moves, including Chess960 castling.
- Preserve compatibility with the supported SIMD and scalar paths when changing
  shared code. Keep build settings in the Makefile rather than duplicating them.
- Keep generated binaries, caches, downloaded weights, and benchmark artifacts
  out of source changes unless the task explicitly calls for them.

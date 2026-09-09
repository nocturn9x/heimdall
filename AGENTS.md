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
  Multilayer TI inference is the default and requires an explicit `EVALFILE`.
  Use `SINGLE_LAYER=1` for the local `threans.bin` debugging fixture; the old
  PSQ-only production network is not a compatible TI file.
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

The production architecture is multilayer. Select the single-layer debug build
explicitly when using the toy fixture:

```sh
make dev SINGLE_LAYER=1 IS_TEST=1 EXE_BASE=bin/heimdall-single
make dev SINGLE_LAYER=1 MAIN=tests/test_single_layer.nim IS_TEST=1 EXE_BASE=bin/test-single-layer EVALFILE="$PWD/threans.bin"
bin/test-single-layer
make dev SINGLE_LAYER=1 MAIN=tests/test_nnue.nim IS_TEST=1 EXE_BASE=bin/test-single-nnue EVALFILE="$PWD/threans.bin"
bin/test-single-nnue
```

This configuration loads the local, untracked `threans.bin` fixture with 32
neurons, one input/output bucket, horizontal mirroring, separate king planes,
SCReLU, QA=255, QB=64, and scale=400. Threat weights are always loaded.
Initialization rebuilds both threat accumulators. Evaluation applies queued threat
diffs, rebuilding the moving king's perspective when its orientation changes.
The output head combines PSQ and TI before activation.
The dedicated test verifies the published accumulator values and
evaluations (startpos=98, Kiwipete=-205), plus inference from saved accumulators.
The single-layer output head is scalar even in SIMD builds; PSQ and TI updates use
the selected backend. The loader always expects threat rows between the PSQ
weights and FT biases. Use `VERBATIM_NET=0` with threans.
The fixture must never be shipped in a release. No fixture is downloaded by
`make dev`; use an absolute `EVALFILE` for standalone tests.

The default multilayer configuration (`SINGLE_LAYER=0`) uses a 768-neuron FT,
16 PSQ input buckets, eight output buckets, hidden sizes 16 and 32, dual
activation, and scale 400. Both scalar and SIMD inference
sum PSQ and TI before pairwise activation. It retains Heimdall's existing integer
quantization and output layout; matching a different trainer requires matching
its dimensions, quantization, bias scaling and file layout. Threat rows are always
present, with no PP rows. `VERBATIM_NET=0` remains required.

For a trained network, use `make dev EVALFILE=/absolute/path/to/net.bin`
and override the Makefile architecture variables as needed. For reproducible
correctness checks without trained weights:

```sh
python tests/make_multilayer_fixture.py build/tests/multilayer-ti.bin
make dev MAIN=tests/test_multilayer.nim IS_TEST=1 EXE_BASE=bin/test-multilayer EVALFILE="$PWD/build/tests/multilayer-ti.bin"
bin/test-multilayer
make dev MAIN=tests/test_nnue.nim IS_TEST=1 EXE_BASE=bin/test-multilayer-nnue EVALFILE="$PWD/build/tests/multilayer-ti.bin"
bin/test-multilayer-nnue
```

The synthetic fixture is only test data. The dedicated multilayer test compares
all output buckets and both perspectives against an independent canonical-layout
oracle, checks the effect of TI before activation, and verifies exact file export
and reload. Repeat with the scalar flags below. To check the optional single
activation, generate with `--dual 0` and build with `DUAL_ACTIVATION=0`.
The generator's `--l1` must match `L1_SIZE`; input/output buckets and hidden sizes
are fixed to the defaults above. SIMD multilayer inference requires `L1_SIZE` to
be divisible by four times the int16 vector lane count and both hidden sizes to
be divisible by the int32 lane count.

Build standalone Nim tests through `make dev`, using `MAIN`, `EXE_BASE`, and an
absolute `EVALFILE` path. Use `IS_TEST=1` for correctness checks and optimized
default builds for speed measurements.

Use focused tests for incremental/fresh NNUE evaluation, threat indexing,
move-generation and state/hash invariants, and search limits. NNUE checks include
pending updates, cloning, the 255-ply boundary, and all 960 castling arrangements
for both colors. Every comparison checks all PSQ and TI accumulator lanes as well
as the final score:

```sh
make dev SINGLE_LAYER=1 MAIN=tests/test_nnue.nim IS_TEST=1 EXE_BASE=bin/test-nnue EVALFILE="$PWD/threans.bin"
bin/test-nnue
make dev SINGLE_LAYER=1 MAIN=tests/test_movegen.nim IS_TEST=1 EXE_BASE=bin/test-movegen EVALFILE="$PWD/threans.bin"
bin/test-movegen
make dev SINGLE_LAYER=1 MAIN=tests/test_limits.nim IS_TEST=1 EXE_BASE=bin/test-limits EVALFILE="$PWD/threans.bin"
bin/test-limits
make dev SINGLE_LAYER=1 MAIN=tests/test_threat_index.nim IS_TEST=1 EXE_BASE=bin/test-threat-index EVALFILE="$PWD/threans.bin"
bin/test-threat-index
make dev SINGLE_LAYER=1 MAIN=tests/test_threats.nim IS_TEST=1 EXE_BASE=bin/test-threats EVALFILE="$PWD/threans.bin"
bin/test-threats
make dev SINGLE_LAYER=1 MAIN=tests/test_threat_diff.nim IS_TEST=1 EXE_BASE=bin/test-threat-diff EVALFILE="$PWD/threans.bin"
bin/test-threat-diff
make dev SINGLE_LAYER=1 MAIN=tests/test_threat_updates.nim IS_TEST=1 EXE_BASE=bin/test-threat-updates EVALFILE="$PWD/threans.bin"
bin/test-threat-updates
```

The threat-index test checks every table entry against geometric attacks and
explicit exclusion rules, verifies the color bounds, and checks retained feature
indices for collisions and overflow. It also checks both indexers across perspectives
and mirroring, and verifies the perspective masks. The threat-collection test compares
runtime attacks and collected features against independent board geometry, including
friendly pawn defenses, writable output slices, and positions before and after special
moves and undo. Fixed expected indices from Viridithas additionally verify both
perspectives of the starting position and Kiwipete.

The threat-diff test uses synthetic weights to check signed i8 arithmetic, empty
and unequal update lists, cancellation, full list capacity, unused tails, and
parent preservation for both perspectives. It also checks full rebuilds and, in
SIMD builds, all 256 signed-byte values through an unaligned widening load.
Build it with `L1_SIZE=768` to exercise a larger accumulator: this arithmetic test
does not load the network fixture. Repeat at that width with the scalar flags
below. TI arithmetic has AVX2 and AVX-512 paths; its accumulator buffers require
`ALIGNMENT_BOUNDARY` alignment and its width must be divisible by `CHUNK_SIZE`.
The threat-update test covers slider
discoveries and obstructions, occupied targets changing identity, pawn defenses,
king mirroring, promotions, en passant, castling, delayed refreshes, and selective
perspective updates. It also checks reuse of dirty child slots, pending and
evaluated undo, initialization after existing board history, cloning with pending
updates, and real moves below null moves.

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
- `src/heimdall/threats/`: TI feature indexing, diff collection, and row arithmetic.
  `eval.nim` owns the state wrappers; `refreshThreats(self, side, position)` and
  `refreshPSQ` both rebuild the current frame from the explicit position.
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

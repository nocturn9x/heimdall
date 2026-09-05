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
  For performance work, compare baseline and candidate binaries built with the
  same flags and network. Use `scripts/compare_performance.py` for repeated paired
  measurements; confirm microbenchmark results with full search.

Build standalone Nim tests through `make dev` as well. For example, to compare
incremental NNUE evaluation with fresh evaluation:

```sh
make dev MAIN=tests/test_nnue.nim IS_TEST=1 EXE_BASE=bin/test-nnue EVALFILE="$PWD/networks/files/gramr.bin"
bin/test-nnue
```

Use the same `MAIN`/`EXE_BASE`/absolute `EVALFILE` pattern for other Nim tests or
benchmarks in `tests/`. Use `IS_TEST=1` for correctness checks and optimized
default builds for speed measurements. See `README.md` for more testing details.

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

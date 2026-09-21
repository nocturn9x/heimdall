# Testing and benchmarks

Run commands from the repository root. Documentation changes do not require an
engine build. For source changes, use the Makefile; never use `nim check`.

## Regular checks

With dependencies and weights available:

```sh
make dev
python -m unittest discover -s tests -p 'test_*.py'
```

`make test` builds `bin/testdall` with `IS_TEST=1` and runs a depth-9 bench.
`make test-suite` runs deeper benches and perft comparisons and requires Python
and Stockfish on `PATH`. `make bench` builds with `make dev` and runs the search
benchmark.

For Python tests that launch the engine, build a test binary and select it:

```sh
make dev IS_TEST=1 EXE_BASE=bin/testdall
HEIMDALL=bin/testdall python -m unittest discover -s tests -p 'test_*.py'
```

## Focused NNUE checks

The local `threans.bin` fixture is for the single-layer debug architecture.
Use an absolute `EVALFILE` path and never ship this fixture in a release:

```sh
make dev SINGLE_LAYER=1 MAIN=tests/test_nnue.nim IS_TEST=1 \
  EXE_BASE=bin/test-nnue EVALFILE="$PWD/threans.bin"
bin/test-nnue
```

The focused tests include `test_single_layer.nim`, `test_nnue.nim`,
`test_movegen.nim`, `test_limits.nim`, `test_threat_index.nim`,
`test_threats.nim`, `test_threat_diff.nim`, and `test_threat_updates.nim`.
Build each through `make dev` with `SINGLE_LAYER=1`, `IS_TEST=1`, and the
appropriate `MAIN`, `EXE_BASE`, and `EVALFILE` values. The threat-diff test can
be widened with `L1_SIZE=768`; it does not load the network fixture.

To test the default multilayer architecture without trained weights:

```sh
python tests/make_multilayer_fixture.py build/tests/multilayer-ti.bin
make dev MAIN=tests/test_multilayer.nim IS_TEST=1 \
  EXE_BASE=bin/test-multilayer \
  EVALFILE="$PWD/build/tests/multilayer-ti.bin" EVAL_SCALE=400
bin/test-multilayer
```

Repeat with `SIMD=scalar` for the scalar path. `make test-simd SIMD=universal`
exercises every backend supported by the runner; use a specific backend such as
`SIMD=sse2` or `SIMD=neon` when needed. See [SIMD.md](SIMD.md) for the complete
matrix and cross-compilation options.

## Combined Linux executable

The packaging and cache regressions use synthetic payloads and require no engine
build or network weights:

```sh
python -m unittest discover -s tests -p 'test_linux_universal.py'
python -m unittest discover -s tests -p 'test_release*.py'
```

They check the shared network payload, source/settings/checksum validation,
architecture selection, cache permissions and repair, simultaneous cold starts,
paths and symlinks, UCI streams, arguments, environment, PID and signals. Launcher
execution tests run on Linux and require the same shell/coreutils/gzip tools as
the release executable.

After [assembling or downloading the combined executable](RELEASES.md#linux-universal-executable),
test the actual file on each native CPU family:

```sh
export HEIMDALL=/absolute/path/to/heimdall-VERSION-linux-universal
export HEIMDALL_CACHE_DIR="$PWD/build/tests/linux-universal-cache"
"$HEIMDALL" simd
python -m unittest discover -s tests -p 'test_uci.py'
python -m unittest discover -s tests -p 'test_runtime_simd.py'
```

Choose a fresh cache path to exercise first-launch extraction. Repeat the `simd`
command to exercise reuse. The cache must be on a filesystem that permits
execution. For a build matching the current checkout, also run
`python scripts/check_binary_benches.py --commit HEAD -- "$HEIMDALL"`.
The release workflow checks the combined executable on both native AMD64 and
ARM64 before publishing. `make test-simd SIMD=universal` separately checks the
underlying kernels; it does not cover this packaging layer.

## Performance comparisons

Build baseline and candidate binaries with identical flags and network, then
run paired measurements:

```sh
python scripts/compare_performance.py bin/baseline bin/candidate \
  --cpu 2 --pairs 12 --perf --output comparison.json
```

Use `--mode perft --depth 7` for move-generation comparisons or `--mode uci`
with a FEN corpus for fixed node or time budgets. The script checks node counts
and records timings, counters, and a bootstrap interval. `tests/bench_nnue.nim`
and `tests/bench_setup.nim` provide focused inference and setup benchmarks.

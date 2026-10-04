<!-- Copyright 2026 Mattia Giambirtone & All Contributors
SPDX-License-Identifier: Apache-2.0 -->

# Heimdall in a browser

The browser build uses Nim's C backend and Emscripten. It keeps the existing
UCI parser, search threads, stop flags, and NNUE implementation. A JavaScript
worker enqueues UCI strings; a dedicated Nim pthread handles commands and a
second pthread runs the primary search. Additional search workers use the same
shared transposition table.

## Build and run

Install the usual Nimble dependencies and obtain a compatible multilayer TI
network first. Install and activate [Emscripten](https://emscripten.org/docs/getting_started/downloads.html),
then make sure `emcc` is on `PATH`. The port was verified with Nim 2.2.6 and
Emscripten 6.0.10. For example, a local SDK can be installed in ignored storage:

```sh
git clone https://github.com/emscripten-core/emsdk.git build/emsdk
build/emsdk/emsdk install 6.0.10
build/emsdk/emsdk activate 6.0.10
source build/emsdk/emsdk_env.sh
make dev TARGET=wasm EVALFILE="$PWD/networks/files/tyrfing.bin"
make serve-wasm
```

Open <http://127.0.0.1:8080>. The Wasmdall website lets you play either color
against Heimdall or analyze a standard chess position. Click or drag pieces;
promotion offers all four choices. Live evaluation is always from White's
perspective, with search statistics, a suggested-move arrow, and a SAN best line.
Timed games offer base time plus Fischer increment presets and custom controls.
The displayed clocks charge elapsed time on the active side and add increment
only after a completed move. Heimdall receives the current `wtime`, `btime`,
`winc`, and `binc` when its search actually starts. Zero-increment controls enable
the engine's `EnableWeirdTCs` option. Flag fall ends the game, with a draw when
the opponent has insufficient mating material. Reviewing positions, pausing the
engine, or entering analysis pauses the clocks; takebacks restore their recorded
values. PGN exports include the time control and result. Practice mode retains
fixed thinking time per engine reply.

Search-thread count and hash memory are selectable in both modes. The hash
controls accept whole MiB values across the engine's advertised range (currently
1–256 MiB, default 64 MiB), including values that are not powers of two.
Changing it during search stops that search, resizes the table, and resumes on
the same position. Clear hash empties the table; both controls also work while
the engine is idle or analysis is paused. No server runs the search.

Use the move list or arrow keys to review a game, and move from an earlier
position in analysis to start a new line. `F` flips the board. The position panel
imports standard FEN, `startpos`, or PGN, copies the current FEN, and exports the
whole game as PGN. Chess960 is supported by the engine's UCI interface, but the
visual board currently uses standard chess rules. The original developer console
is still available at `/console.html`; it accepts raw UCI commands and positions.

The interface is plain HTML/CSS/JavaScript with a locally vendored, pinned
[chess.js](https://github.com/jhlywa/chess.js) rules library. Its license and
version record live in `web/vendor/`. Piece SVGs reuse Heimdall's existing assets.
After editing the frontend, `make wasm-assets` refreshes the served files without
recompiling the engine.

`make dev TARGET=wasm` does not install tools, dependencies, or weights.
The usual Makefile network architecture variables apply. `EMBED_NET=1` is
required: the selected network is included in the Wasm module, with no separate
runtime network-file fetch. The local single-layer debugging fixture remains
test data and must not be published.

Artifacts go in ignored `build/wasm/`: `heimdall.js`, `heimdall.wasm`,
the worker, website HTML/JS/CSS, `vendor/`, and `pieces/`. Deploy the website assets
alongside the three engine files; the Nim cache is only for builds.
Set `WASM_DIR` to use another directory;
pass that same value to `make serve-wasm`. `EMCC` can specify an explicit compiler
path. Native `bin/heimdall` is unaffected by a browser build.

## SIMD, threads, and memory

`SIMD=auto` selects the existing SSE4.1 facade translated to Wasm's 128-bit SIMD.
`SIMD=sse2`, `SIMD=ssse3`, and `SIMD=sse41` select the corresponding compatibility
path. `SIMD=scalar` disables explicit SIMD; the compiler may still optimize scalar
code using instructions allowed by that target. AVX and native runtime-dispatched
builds are separate native targets.

The SIMD browser module requires Wasm SIMD support. The engine uses ordinary
128-bit SIMD, without requiring Relaxed SIMD. SSE operations that lack a matching
Wasm instruction are implemented by Emscripten's compatibility headers.

`WASM_THREADS=64` sets the engine's build limit for search threads. The website
and console selectors offer 1 through the smaller of that limit and the browser's
`navigator.hardwareConcurrency`. This is a CPU availability hint, not a universal
browser worker limit; browser resource limits and memory still apply.

`WASM_THREAD_POOL=2` preloads workers for the UCI controller and primary search.
Additional workers are created on demand and reused. Thread setup runs on the
controller pthread while the module's JavaScript event loop remains free to load
workers, allowing synchronous Nim setup without exhausting a fixed pool. TT
clearing runs serially in browser builds. NUMA affinity and huge-page advice are
disabled. Allocations retain alignment.

The defaults are 256 MiB initial linear memory, a 2 GiB maximum, a 64 MiB TT,
and a browser TT limit of 256 MiB. Override `WASM_MEMORY` and `WASM_MAX_MEMORY`
with byte counts. Every search worker adds history, NNUE, and stack storage;
choose a smaller thread pool for devices with limited memory. Changing memory
limits does not automatically change the advertised TT limit. The maximum is a
growth limit; selecting more threads or a larger hash determines actual usage.

Both scalar and SIMD artifacts use pthreads and require `SharedArrayBuffer`.
Serve over HTTPS or localhost with these response headers:

```text
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

The included development server supplies those headers and binds to localhost.
Opening `index.html` directly, or serving with an ordinary `python -m http.server`,
does not provide the required isolation. Deploy the engine and website together and use
the `application/wasm` MIME type for the Wasm module.

## Worker interface

```js
const engine = new Worker("heimdall.worker.js");
engine.onmessage = ({data: line}) => console.log(line);
engine.postMessage("uci");
// Wait for uciok, then initialize options and positions as with native UCI.
engine.postMessage("position startpos moves e2e4 e7e5");
engine.postMessage("go infinite");
// Stop remains responsive while the search pthread is busy.
engine.postMessage("stop");
```

Input and output are strings. A message can contain several newline-separated
commands. Commands are limited to 64 KiB per line and the transport queues up to
256 lines. The exported `heimdall_command` returns 0 for an accepted line, 1
when closed, 2 for invalid input, and 3 when the queue is full. The wrapper reports
transport failures as `info string Browser engine error: ...` messages.
Send `quit` to stop the search and its threads; the wrapper reports
`info string Browser engine exited`. Dispose of the worker when finished.

## Verification

Node can execute the same generated module, including its pthreads:

```sh
make test-wasm EVALFILE="$PWD/networks/files/tyrfing.bin"
make test-wasm SIMD=scalar WASM_DIR=build/wasm-scalar EVALFILE="$PWD/networks/files/tyrfing.bin"
```

The regression checks startpos perft, finite and timed searches, immediate and
delayed stop, repeated searches, changing worker counts, TT clearing/resizing,
resource limits, and clean shutdown. To also compare single-thread scores, node
counts, PVs, and best moves with native searches using identical settings:

```sh
make dev SIMD=sse41 IS_TEST=1 EXE_BASE=bin/wasm-reference EVALFILE="$PWD/networks/files/tyrfing.bin"
make test-wasm WASM_NATIVE=bin/wasm-reference EVALFILE="$PWD/networks/files/tyrfing.bin"
```

For the real browser worker, website, and console, the optional Playwright test
starts its own isolated localhost server. It checks playing both colors,
cancelling searches while changing the board, analysis and thread changes,
history branching, imports, castling, en passant, promotion, mate-score
orientation, PGN export, responsive layout, console recovery, and shutdown:

```sh
python -m pip install playwright
python -m playwright install chromium
python scripts/test_wasm_browser.py
# Or use an already installed Chromium:
python scripts/test_wasm_browser.py --browser /path/to/chromium
node --test tests/test_browser_clock.mjs
```

Standalone Nim correctness tests use `WASM_MAIN` through the same Makefile.
Their selected network is additionally preloaded into the virtual filesystem,
allowing file export/reload comparisons. For example:

```sh
python tests/make_multilayer_fixture.py build/tests/multilayer-ti.bin
make dev TARGET=wasm WASM_MAIN=tests/test_multilayer.nim WASM_DIR=build/wasm-tests/multilayer SIMD=sse41 IS_TEST=1 EVAL_SCALE=400 EVALFILE="$PWD/build/tests/multilayer-ti.bin"
node scripts/run_wasm_test.js build/wasm-tests/multilayer/heimdall.js
```

The same pattern works for `tests/test_simd.nim` and other focused tests. Use
distinct directories for different artifacts and architectures.

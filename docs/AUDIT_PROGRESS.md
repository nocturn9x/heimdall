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

Authored with assistance from AI agents.
-->

# Project audit progress

Started: 2026-09-05

Status: **Complete** — the initial correctness pass, thirteen performance
experiments, final regression checks and combined measurements are complete.
Changes are local and uncommitted. All builds used `make dev`; no `nim check`.

Final observed gains on this Ryzen 9 5900X: **+2.56% search throughput at depth
14**, **+1.64% at depth 16**, and **+6.84% start-position perft throughput**.
Repeated eight-thread position setup improved from about **4.99 s to 0.0318 s
per 1,000 setups**. Search nodes and evaluation checksums are unchanged. These
are workload-specific measurements, not playing-strength results. Detailed
experiments, rejected candidates, intervals and reproduction data follow below.

## Scope and stopping point

This is a bounded maintenance pass: map the engine and its checks, establish a
baseline, investigate input handling and test reliability, then inspect selected
search/data-processing paths for correctness or avoidable work. Fix reproducible
issues and validate them before moving on. Stop after a few well-supported fixes
and a final regression pass; record larger or uncertain work for a future pass.

Use the Makefile's `dev` target for builds; do not use `nim check`. No user input
is needed for this pass. Changes remain local and uncommitted.

## Project map

- `src/heimdall.nim`: CLI dispatch, benchmark, data tools, UCI/TUI entry points.
- `src/heimdall/{position,board,movegen,moves,bitboards}.nim`: chess state and rules.
- `src/heimdall/{search,transpositions,nnue,eval}.nim`: search and evaluation.
- `src/heimdall/uci/`: command parsing, session lifecycle, search worker.
- `src/heimdall/tui/`: interactive board, analysis, play, input and rendering.
- `src/heimdall/util/`: limits, datasets, memory, chess helpers and tuning.
- `tests/`: Stockfish perft comparisons, position suites, viriformat unit tests.
- `Makefile`: `dev` builds with installed dependencies; `test` and `test-suite`
  enable runtime checks. Full suite uses deep perft and is explicitly expensive.

## Activity log

### 1. Initial reconnaissance — complete

- Working tree was clean; no applicable `AGENTS.md` files found.
- Read build configuration, existing test drivers and CLI entry point.
- Baseline `make dev` passed (native AVX2). Stockfish and Python are installed.
- Baseline `bench 8 --silent`: **386,302 nodes**. Timing is only a smoke check,
  not a controlled performance measurement.

### 2. Test reliability and UCI boundaries — complete

- Reproduced false-success suite status with a deliberately failed comparison in
  both serial and parallel modes: both returned `None` (shell success).
- Reproduced imported verbose comparator failure: `AttributeError` from treating
  `__builtins__` as a module when it is a dictionary.
- Reproduced SIGSEGVs for `position`, `go depth`, `go wtime`, and `getScale`.
  `setoption name` also read past the token array and printed invalid bytes.
- Reproduced rejection of tab-separated UCI commands.
- Reproduced hangs after `go wtime 1000 btime 1000` / `go ponder depth 1`, followed
  by `stop`: rejected worker requests left the search marked busy without a
  completion response. Moved rejection checks before asynchronous dispatch.
- Inspected TT sizing: UCI `Hash` compared MiB with an entry count, unnecessarily
  reallocating and clearing the table even when setting its current size.
- Added parser guards, recognized tab-separated tokens and multiword option
  names/values, and allowed limits after `searchmoves`.
- The comparator also accepted two empty engine outputs as matching results.
  It now requires completed perft summaries consistent with the divided counts;
  real zero-node terminal positions remain valid. Crash diagnostics now show the
  captured merged output instead of `None`.

### 3. Regression verification — complete

- Added 12 Python test-tool regressions and 9 engine integration tests, with
  subcases for missing arguments and each rejected-search path. All 21 pass on
  both the default dev build and the build with runtime checks enabled.
- The depth-8 benchmark remains exactly **386,302 nodes** after the fixes.
- Standard positions: **174/174 passed** at depth 3 against Stockfish.
- Full collection: **1,155/1,155 passed** at depth 3 against Stockfish, in 254.92
  seconds with two workers. This includes standard, Chess960 and edge positions.
- Documented quick regression commands in `README.md`.
- Non-bulk edge cases with verbose output: **21/21 passed** at depth 3.
- Checked dev build succeeded. Final regressions include allowed time-control
  exemptions, colored perft output and malformed `set` aliases. The checked
  binary also matches the 386,302-node depth-8 benchmark.
- Verified actual shell failure statuses with `/bin/true` standing in for an
  engine emitting no perft: both serial and parallel suite modes now exit 1.
- Reviewed viriformat reads and relabel chunk dispatch/cleanup. No changes in
  those modules during this pass; one allocation hotspot is recorded below.
- Stopped after four verified issue groups and the final regression pass, as
  planned. No benchmark NPS or playing-strength improvement is claimed.

## Findings and fixes

1. **Test runner false success and broken verbose output** — regression tests
   pass. Added common summary/exit status, empty-file handling,
   explicit pool cleanup and a one-worker minimum for single-core systems.
2. **UCI parser out-of-bounds access and token handling** — regression tests
   pass. Also reject negative perft depth and nonpositive
   search depth before entering recursive search.
3. **Rejected-search deadlock** — synchronous validation in place; all three
   rejected-search paths pass `stop`, a new game and a subsequent valid search.
4. **Redundant hash allocation/clearing** — compare configured MiB to configured
   MiB; regression confirms resetting 64 MiB does not resize, switching to 1 MiB
   resizes once, and repeating 1 MiB does not resize again.

## Validation

- Baseline and final `make dev`: passed.
- Final `make dev IS_TEST=1 EXE_BASE=bin/testdall`: passed.
- Baseline depth-8 benchmark: 386,302 nodes.
- Standard-position perft comparison at depth 3: 174/174 passed.
- All-position perft comparison at depth 3: 1,155/1,155 passed.
- Python test-tool and UCI regressions: 21/21 passed on each build.
- Post-fix depth-8 benchmark: 386,302 nodes on each build (unchanged).
- Non-bulk edge cases with verbose output: 21/21 passed at depth 3.
- Intentional failing comparisons: serial and parallel suite exit codes are 1.
- `git diff --check`: passed.

## Initial review coverage and limits

| Area | Work performed |
| --- | --- |
| Build and test tools | Read Makefile/CLI/test runners; built both configurations; repaired failure reporting. |
| UCI | Reviewed parser, dispatch and worker rejection paths; reproduced and fixed crashes/hangs. |
| Chess rules | Read selected FEN, attacks and move-handling code; compared move generation to Stockfish. |
| Search and memory | Reviewed search lifecycle, limits and TT allocation; fixed redundant UCI hash resizing. |
| Data processing | Reviewed viriformat reader and relabel chunk scheduling/cleanup; recorded profiling follow-up. |
| TUI, SIMD and playing strength | Mapped only; no claim of full review or strength testing. |

## Reproduction and validation commands

```sh
make dev
python -m unittest discover -s tests -p 'test_*.py' -v
make dev IS_TEST=1 EXE_BASE=bin/testdall
HEIMDALL=bin/testdall python -m unittest discover -s tests -p 'test_*.py' -v
NO_COLOR=1 NO_LOGO=1 bin/heimdall bench 8 --silent
NO_COLOR=1 NO_LOGO=1 python tests/suite.py -d 3 -b -p -w 2 -s -f tests/all.txt --heimdall bin/heimdall
python tests/suite.py -d 3 -s --no-silent -f tests/illegal_edge_cases.txt --heimdall bin/heimdall
```

## Initial deferred follow-up

- FEN parsing has a larger validation surface (rank/file counts, numeric ranges,
  and assertion-based king checks); this needs a separate pass with malformed-FEN
  coverage rather than a partial parser rewrite here.
- Profile viriformat ingestion before optimizing it: `readViriformatGame` calls
  `readExact(4)` for every move, allocating a fresh string for each record. A
  reusable stack buffer may reduce allocation overhead on large datasets. This
  is a source-level observation, not a measured throughput claim.
- Search lifecycle review here focused on rejected requests. Rapid valid
  `go`/`stop`/`ponderhit` sequences and completion-message ownership deserve a
  separate concurrency stress pass.
- Full depth-6/7 suite and playing-strength tests are outside this bounded pass.

## Second pass: performance investigation

Requested 2026-09-05. The earlier stopping point applies only to the initial
correctness pass. This investigation covers CPU profiles, generated C and machine
code, move generation, NNUE updates/inference, search bookkeeping, and memory
traffic. It will include repeated measurements, experiments that are rejected,
and correctness validation for accepted changes. No `nim check` or user input.

### Plan and experimental discipline

1. Save baseline binaries and record compiler/CPU/build configuration.
2. Profile representative single-thread search and perft workloads with `perf`;
   inspect call stacks, hardware counters, and generated C/assembly.
3. Audit hidden array/object copies, zero-initialization, managed-reference
   traffic, heap allocations, and missed inlining/vectorization in hot code.
4. Make isolated experimental changes and measure alternating baseline/candidate
   runs on the same CPU. Keep only correctness-preserving improvements supported
   by the measurements; do not tune search heuristics or claim Elo gains.
5. Validate retained changes with deterministic search benchmarks, checked builds,
   Stockfish perft comparisons, and targeted evaluation checks where needed.
6. Finish with a reproducible evidence summary and prioritized remaining work.

### Environment and activity

- Host: AMD Ryzen 9 5900X, 12 cores / 24 threads, AVX2, 64 MiB L3 in two domains.
- `perf`, Valgrind, Clang, LLVM objdump and CPU affinity tools are installed.
- `perf_event_paranoid=2`; testing whether user-space hardware events are usable.
- Existing first-pass changes are preserved as the new performance baseline.
- Compiler: Nim 2.2.6, Clang 22.1.8, native AVX2, atomic ARC, LTO. Baseline
  executable: `bin/perf-baseline`; symbolized profile executable:
  `bin/perf-baseline-profile` (`make dev DBG_SYMBOLS=1`). Raw profiles, generated
  C snapshots, assembly and measurement JSON are in `.cache/perf-audit/`.
- CPU 2 is used for single-thread measurements; its SMT sibling is CPU 14.
  This is a live workstation, so results need paired repetitions rather than
  relying on a single timing. No global frequency/governor settings were changed.

### Baseline profiles

User-space hardware events work without changing system permissions. A depth-16
search benchmark visited **16,052,624 nodes**. Its 7,000-sample cycle profile had
no lost samples. Self-time (functions can contain inlined callees):

| Function/path | Share of search samples |
| --- | ---: |
| NNUE forward inference | 22.28% |
| Incremental accumulator update | 17.59% |
| Main non-PV search | 16.43% |
| Move scoring | 8.83% |
| Accumulator refresh | 5.00% |
| Quiescence search | 4.64% |
| Static exchange evaluation | 4.58% |
| Make move | 3.87% |

Start-position bulk perft at depth 7 matched **3,195,901,860 nodes**, with pawn
generation (21.82%), make-move (17.28%), bishop generation (12.60%) and knight
generation (11.02%) leading its profile. Search and perft clearly stress different
paths; a perft speedup alone will not be called an engine speedup.

### Generated-code findings and experiment queue

- **Eliminated copy:** the `ftOut` array cast in `forwardFast` produces two array
  copies and a zero-initialization in generated C. Final assembly has one local
  activation buffer and no copy/clear call; Clang removes this overhead. Do not
  replace it with an unsafe pointer cast merely to make the C look shorter.
- **Real copy candidate:** SEE selects its seven-element weight array by value;
  the copy survives into machine code and sampled memory operations. Test a
  borrowed pointer to the selected immutable weights.
- **Synchronization:** `Atomic[Option[int]]` uses a spin lock in generated C,
  including for relaxed loads. `mateDepth` only uses this once per iteration, so
  it is not a priority. Per-thread node counters perform locked read-modify-write
  on every node despite having one writer; investigate a cheaper atomic publish.
- **NNUE:** investigate redundant initialization during refresh, inference work
  for zero activations, and whether delayed updates can skip intermediate work.
- **Movegen/search:** inspect selection-sort bookkeeping and the expensive pawn
  path; preserve move order as well as legal move sets in accepted changes.
- Added `scripts/compare_performance.py` for alternating baseline/candidate runs,
  deterministic node-count checks, raw samples and a bootstrap interval. Running
  a baseline-versus-itself calibration first.
- Added optional `MAIN` and `EXTRA_NFLAGS` Makefile variables so diagnostic Nim
  programs and isolated compiler caches can use `make dev` with the exact engine
  configuration. Default build behavior is unchanged.
- Calibration (six alternating pairs of the identical depth-14 binary): geometric
  mean difference -0.32%, bootstrap interval [-1.74%, +1.08%]. This establishes
  that an isolated 1% timing change is not convincing here.
- Added `tests/test_nnue.nim`. Baseline checked AVX2 build passes **7,940** comparisons
  of incremental versus fresh evaluation, checksum **1,192,624**, covering every
  move flag, Chess960 castling, delayed evaluation, long walks, undo and null moves.
- SEE pointer experiment completed 12 alternating benchmark pairs with
  instruction, cycle and branch counters; rejected (results below).
- **New C aliasing candidate:** `MoveList.len` is a `uint8`. In pawn generation's
  final assembly, every move store is followed by a reload of that length byte
  before incrementing it. C permits character-sized accesses to alias other
  objects, preventing Clang from retaining the index in a register. Testing a
  native integer length; the public `len()` return type remains `int`.
- **Hidden clearing on undo:** despite the first pass replacing `pop()` with
  `setLen()`, generated `setLen(seq[Position])` still clears all 344 bytes of each
  discarded position. `Position` defines a custom copy hook to forbid implicit
  copying, which makes Nim's `supportsCopyMem` false; `shrink` then resets removed
  elements. `setLenUninit` calls the same shrink path, so it would not fix this.
  Assembly confirms the stores. Investigating a narrowly scoped way to truncate
  this unmanaged stack without weakening the no-copy policy.
- Added `tests/bench_nnue.nim` to benchmark forward inference independently over
  128 captured accumulators from representative benchmark positions. It includes
  the implementation only in the diagnostic binary to access private state;
  production visibility is unchanged.
- Follow-up assembly disproves the proposed *byte-specific* explanation for
  move-list reloads: Nim passes `-fno-strict-aliasing`, and widening the length
  still leaves the reload after each move store. Recording that experiment,
  then testing a saved length across the store instead of changing its type.
- A small `make dev` probe confirms that a no-op `=wasMoved` hook removes the
  position-clearing shrink loop while preserving the compile-time ban on implicit
  copying. Before applying it to `Position`, guard every field with
  `supportsCopyMem` so future managed fields cannot silently invalidate the hook.
- User explicitly approved removing the custom `Position` copy hook. Test that
  simpler approach first: it should restore Nim's normal unmanaged-type handling
  and remove the shrink clearing without depending on a custom moved-from hook.
- Found a separate setup bottleneck: every `setBoard` allocates and zeroes a new
  huge-page eval state for every worker, then copies the entire accumulator stack
  although only its initialized prefix is usable. Investigate storage reuse and
  measure repeated UCI position setup separately from steady-state search.
- Saved-index append assembly now confirms the intended improvement: the pawn
  loop increments a register after the move store instead of reloading length
  from memory. The original byte-sized layout is preserved in this experiment.
- Removing the `Position` copy hook also produces the expected machine code:
  the sequence shrink path now just stores the new length. Five isolated engine
  variants built successfully with `make dev`; each retained the 386,302-node
  depth-8 smoke benchmark. Full paired measurements follow.
- While extending NNUE coverage, found a boundary mismatch: search calls raw
  evaluation at ply 255, but `MAX_ACCUMULATORS = 255` only provides indices 0–254.
  Added deterministic 255-ply knight cycles with eager and delayed evaluation to
  reproduce this under `make dev IS_TEST=1` before fixing the capacity.
- **Confirmed correctness fix:** the new checked test fails on the baseline with
  `index 255 not in 0 .. 254`. Increased the accumulator capacity to 256, accounting
  for the root. This is separate from the performance experiments.
- Capacity fix passes **8,471** checked incremental/full-refresh comparisons,
  checksum **1,227,928**, including both maximum-depth paths and their undo chains.
- Built an NNUE forward experiment that skips all-zero *pairs* of packed inputs.
  It preserves the original `vecDpbusdx2` grouping, including AVX2 intermediate
  arithmetic. First compare its output checksum and isolated inference cost;
  only then consider a full-search timing (branch behavior can differ there).
- **New measured memory finding:** `allocHeapAligned` reserves a rounded multiple
  of 2 MiB, but `hugePageAlloc` passes the original, shorter size to `madvise`.
  Reading `/proc/<running-benchmark>/smaps` confirms the consequence: the
  **1,768 KiB NNUE mapping has `THPeligible: 0`, `AnonHugePages: 0`**, despite its
  `hg` advice flag. The 3,020 KiB history mapping gets only one 2 MiB huge page;
  the 64 MiB TT gets its full allocation in huge pages. Test advising the entire
  already-allocated range; no global kernel setting changes are needed.
- Benchmark reporting issue: `runBench` uses process CPU time even with multiple
  search threads, which sums their CPU usage and understates parallel throughput.
  Prepared a small fix using monotonic elapsed time for `threads > 1`; preserve
  CPU timing for the single-thread comparisons. Apply during consolidation so
  it does not complicate the isolated experiment baselines.
- Concurrency check prompted by counter ownership: worker node counts are reset
  only when each worker dequeues `Go`. The main thread can inspect totals earlier
  and see the preceding search's counts. Reproduce a long search followed by a
  short node-limited one during validation; if confirmed, clear idle workers'
  counters before dispatch. This does not introduce concurrent counter writers.
- **Reproduced:** alternating 50,000- and 1,000-node searches with four workers
  sharing one CPU caused a short search to return a fallback move with no search
  iteration. Saved the transcript in `stale-counter-baseline.txt`. Added a targeted
  regression and prepared a pre-dispatch counter reset for consolidation.
- The targeted stale-counter regression fails on the baseline as expected.
  The other **23 Python regressions pass**, including node-limit and worker-restart
  coverage added in this pass.
- Integrated worker-state reuse and the idle-worker counter reset. A checked
  engine built with `make dev IS_TEST=1` now passes **all 24 Python regressions**,
  including the previously failing race test. Added direct reuse/self-copy checks
  to the NNUE diagnostic before starting the remaining paired measurements.
- Direct reuse and self-copy coverage now passes **8,491** checked evaluation
  comparisons, checksum **1,228,801**. No production lookup-table values, pruning
  thresholds, move ordering rules or network weights have been changed.
- Full-range advice is verified in a live candidate process: history storage now
  has **4,096 KiB** in huge pages and each NNUE state **2,048 KiB**, with
  `THPeligible: 1`. These are observed allocations, not a guarantee of future
  huge-page availability under memory pressure. Raw summaries are saved beside
  the baseline smaps evidence.
- All four NNUE candidates (sparse inference, refresh scratch initialization,
  per-perspective delayed updates, and worker-state reuse) pass **8,482** checked
  comparisons, checksum **1,228,392**, including cloning a partially evaluated
  path and undoing independently. Built a separate capacity-fixed NNUE reference
  so their timings do not attribute the necessary array-size correction to an
  algorithm change.

### Experiment results

| Experiment | Measurement | Decision |
| --- | --- | --- |
| Borrow SEE weights instead of copying | 12 depth-14 pairs: -1.68% throughput, 95% interval [-2.76%, -0.53%]; instructions -0.325%, cycles +1.83%; nodes unchanged | Reverted. The copy is real, but removing it did not make this build faster. Keep the evidence rather than claiming success from the C diff. |
| Widen move-list length to `int` | 12 depth-14 pairs: +1.18%, interval [+0.22%, +2.12%]; nodes unchanged | Small positive observation, but the targeted reload remains. Prefer testing the direct append fix before retaining a layout change. |
| Preserve the append index | Search: +0.51%, inconclusive. Four start-position depth-7 perft pairs: **+2.88%**, interval [+1.18%, +4.00%]; instructions -1.22%; every run returns 3,195,901,860 nodes | Retained for demonstrated movegen improvement. No independent whole-search gain is claimed. |
| Remove `Position` copy hook | Eight depth-14 pairs: +2.29%, interval [+1.31%, +3.34%]; nodes unchanged | Retained. Added a compile-time plain-data check to protect movegen's existing raw stack copies. The direct `shrink` follow-up is recorded below. |
| Replace per-node locked increments with atomic load/store | Eight depth-14 pairs: +0.75%, interval [-1.37%, +2.43%]; instructions +0.045%, cycles -0.93%; nodes unchanged | Not retained: ownership permits it, but single-thread timing is inconclusive. |
| Direct sequence `shrink` after removing the copy hook | Search: -0.09%, inconclusive. Four depth-7 perft pairs against the copy-hook fix: -0.09%, interval [-1.55%, +0.87%]; instructions -1.39%, cycles unchanged | Not retained: removing calls/instructions did not improve either measured workload. |
| Advise the full rounded huge-page allocation | Six depth-14 pairs: +3.13%, interval [+2.46%, +3.87%]; instructions unchanged, cycles -2.75%; nodes unchanged | Retained. smaps verifies restored huge-page backing. Full pages can increase RSS by about 1.3 MiB per search manager on this configuration; the virtual allocation was already rounded. |
| Skip zero NNUE input pairs | Initial repeated-corpus forward test: +3.42%. Six full-search pairs against the capacity-fixed reference: **-14.65%**, interval [-16.43%, -13.38%]; instructions +4.75%, branches +39.33%, branch misses +250.13%; nodes unchanged | Rejected. Repeating a small activation corpus gave a misleading picture of branch behavior in search. The full-search reference also removes the capacity-change confound from the initial microbenchmark. |
| Per-perspective lazy accumulator reconstruction | Six depth-14 pairs: +0.19%, interval [-1.91%, +1.91%]; instructions +0.16%, cycles effectively unchanged; nodes/checksums unchanged | Not retained. The additional validity state and reconstruction logic did not produce a demonstrated search gain. Prototype and checked-test results remain available. |
| Leave refresh scratch arrays uninitialized | Six depth-14 pairs: +0.59%, interval [-1.05%, +2.02%]; instructions -0.020%; checksums/nodes unchanged | Not retained: confirmed redundant 512-byte clearing, but no demonstrated whole-search gain in this run. |
| Seed selection sort from its first element | Six depth-14 pairs: +0.93%, interval [-0.22%, +2.08%]; instructions +0.812%, branches -0.728%; nodes unchanged | Not retained: simpler source did not produce a clear throughput improvement. |
| Specialize SEE by its compile-time context | Six depth-14 pairs: +2.20%, interval [+1.40%, +2.92%]; cycles -2.22%, instructions +0.39%; nodes unchanged | Retained. All call sites use constant contexts. This worked better than the earlier weight-pointer experiment, despite executing more instructions. |
| Reuse worker NNUE storage and copy live prefixes | Four paired runs of 1,000 setups / 8 threads: about 4.99 s to 0.0318 s (157× setup throughput). `perf stat`: minor faults 3,116,771 → 9,661; baseline spent 4.10 s in the kernel | Retained. This removes repeated allocation/page faults and unused frame copies; it is **not** a 157× search speedup. |

The SEE result also demonstrates why instruction count alone is insufficient:
the shorter code was slower. Exact results are in `see-comparison.json`, and
baseline/candidate assembly is retained for future compiler/code-layout work.

### Bounded experiment queue — complete

All thirteen experiments above are complete. Retained the supported changes and
removed the rejected or inconclusive prototypes from production source. The
direct `shrink()` follow-up did remove instructions, but did not improve either
measured workload. The remaining work is combined performance measurement and
final regression validation; no additional tuning candidates are being added.

The comparison runner now terminates the whole subprocess group on timeout or
interruption, including engines started beneath `perf`/`taskset`. A deliberately
timed-out parent/child fixture verified that no running descendant remained.

While checking the touched allocator's portability, found that its no-THP path
uses ordinary `alloc`, which does not promise the over-alignment required by SIMD
objects. Added a `noTHP` build define to exercise that existing fallback locally
and an allocation-alignment test. Reproduce before changing the fallback; this
is a correctness check on the allocator, not another open-ended tuning project.
The forced-fallback test **fails on the old path** at the 64-byte alignment
assertion. Updated allocation to honor `alignof(T)` (and at least 64 bytes), using
the matching aligned free on every platform. Native huge-page behavior retains
the same 2 MiB alignment and full-range advice. Testing 64- and 128-byte objects
in both paths, plus the NNUE code on the fallback path.
Both allocation paths now pass the 64-/128-byte alignment test. The optional
`-d:noTHP` define allows exercising the fallback without changing kernel settings.
The full checked SIMD NNUE test also passes on the forced fallback: **8,491**
comparisons, checksum **1,228,801**. The fallback alignment problem is fixed;
actual Windows/macOS execution is not available on this Linux host.

### Memory-counter follow-up

Three runs each of the baseline and full-advice prototype at depth 14 recorded
the same 8,107,163 nodes and effectively identical instruction counts. Average
L1 data-TLB misses fell **38.6 million → 19.3 million**; L2 misses from data-cache
misses fell **443.0 million → 431.5 million**. The TLB measurements vary markedly
(perf reports ±7.44% and ±31.55%), so treat these as supporting evidence for the
mapping fix, not a precise universal reduction. Profiles and counter logs remain
in `.cache/perf-audit/`.

### Final consolidation and validation — complete

- Default and checked `make dev` builds pass all **24 Python regressions** each.
- Final checked AVX2 and scalar NNUE diagnostics both pass **8,491 comparisons**,
  checksum **1,228,801**. This includes cloning/reusing live prefixes, pending
  updates, independent undo, every move flag, and the maximum-ply boundary.
- The checked viriformat tests pass. Tuning-build, broader perft, memory checks,
  combined paired timings and multithread throughput checks follow sequentially
  so validation work does not compete with performance measurements.
- Tuning-enabled checked build passes and preserves **386,302** depth-8 nodes.
- All **1,155/1,155** positions pass bulk perft against Stockfish at depth 4.
  All **21/21** edge positions pass non-bulk depth-4 perft with runtime checks.
- All **7/7** heavy standard positions pass bulk perft at depth 6. Valgrind
  Memcheck (`--error-exitcode=99 --leak-check=no`) reports no errors while the
  final checked NNUE diagnostic completes its 8,491 comparisons.
- Correctness validation is complete. Final combined measurements run at search
  depths 14/16 and perft depth 7, followed by multithread smoke/scaling checks and
  a fresh cycle profile. Timing jobs do not overlap builds or the test suites.

### Combined results

The final executable includes all retained changes and the correctness fixes.
Compare it directly with the saved performance baseline; do not add up the
isolated experiment gains. Both use the default optimized `make dev` flags.

| Workload | Paired runs | Throughput change | Bootstrap 95% interval | Nodes per run |
| --- | ---: | ---: | --- | ---: |
| Search, depth 14 | 12 | **+2.56%** | [+1.77%, +3.27%] | 8,107,163 |
| Search, depth 16 | 6 | **+1.64%** | [+0.47%, +2.95%] | 16,052,624 |
| Start-position bulk perft, depth 7 | 4 | **+6.84%** | [+5.94%, +7.72%] | 3,195,901,860 |

Depth-14 medians: baseline **1,143,621 NPS**, final **1,177,519 NPS**. Paired
hardware-counter changes: cycles **-2.49%**, instructions **-0.19%**, branches
**+1.22%**, branch misses **-0.37%**. The table uses the geometric mean of paired
ratios, which differs from the ratio of the two medians. Raw samples and binary
hashes: `.cache/perf-audit/final-search-d14.json`.

Depth-16 medians: baseline **1,173,819 NPS**, final **1,191,809.5 NPS**. Cycles
fall **1.61%**, instructions **0.21%**, with identical nodes in all runs. The
smaller gain at depth 16 is recorded separately rather than pooled with depth 14.
Raw samples: `.cache/perf-audit/final-search-d16.json`.

Combined perft medians: baseline **188,502,781 NPS**, final **201,435,246.5 NPS**.
Cycles fall **6.17%**, instructions **3.26%**, branches **1.53%**; every run
returns **3,195,901,860 nodes**. Raw samples:
`.cache/perf-audit/final-perft-d7.json`. This is a movegen workload; the separate
search measurements above determine the observed engine-search gain.

### Multithread checks and final profile

All 24 timed searches across three FENs and 1/2/4/8 threads complete normally.
Each search has a 1.5-second move limit and affinity to physical cores 0–11.
Median NPS across those three positions:

| Threads | Baseline | Final |
| ---: | ---: | ---: |
| 1 | 1,178,830 | 1,183,744 |
| 2 | 2,359,063 | 2,395,744 |
| 4 | 4,815,830 | 4,899,041 |
| 8 | 9,167,330 | 9,120,052 |

These short, nondeterministic parallel searches demonstrate scaling and successful
completion. Per-position changes are mixed; no statistically supported parallel
speedup is claimed. The worker-restart, tiny-node-limit and stale-worker-count
regressions also pass in both optimized and checked engine builds. Raw output:
`.cache/perf-audit/smp-comparison.json`.

The four-thread CLI bench now reports elapsed wall time: a depth-12 run reports
**2.543 s** within **2.722 s** of measured whole-process time. Its reported
**4,745,641 NPS** therefore reflects aggregate parallel throughput instead of
dividing by the sum of thread CPU times. Single-thread bench timing is preserved.
Evidence: `.cache/perf-audit/final-smp-bench.json`.

The final depth-16 cycle profile has no lost samples. Leading self-time shares
(including any callees the compiler inlines):

| Function/path | Share |
| --- | ---: |
| NNUE forward inference | 23.83% |
| Incremental accumulator update | 17.62% |
| Main non-PV search | 16.75% |
| Move scoring | 10.20% |
| Accumulator refresh | 4.85% |
| Quiescence search | 4.25% |
| Make move | 4.07% |

NNUE inference, updates and refreshes still account for about **46.3%** of sampled
cycles. Percentages are relative shares, not absolute regressions; specialization
also changes inlining and attribution. Use the paired timings for speed claims.
Final profile and flat report: `.cache/perf-audit/final-search.data` and
`.cache/perf-audit/final-search-flat.txt`.

### Retained changes and remaining priorities

Retained performance changes: plain-data `Position` handling eliminates the
344-byte clearing on undo; move-list append preserves its index across the store;
huge-page advice covers the rounded allocation; SEE specializes its constant
context; worker NNUE storage is reused and only live frame prefixes are copied.
Also fixed the NNUE maximum-ply capacity, fallback allocation alignment, stale
worker totals at a new search, and parallel bench timing. The earlier UCI and
test-runner fixes remain in place.

No playing-strength claim is made. All deterministic search node counts and
NNUE checksums are preserved, and no heuristics, pruning thresholds or network
weights changed. Native AVX2, scalar, tuning-enabled, and forced-no-THP builds
were exercised; other CPU architectures and actual Windows/macOS execution were
not available on this Linux host. Whole huge-page backing can use about 1.3 MiB
more resident memory per search manager on this configuration.

Future work, in priority order, rather than extending this pass indefinitely:

1. Profile NNUE vector kernels and accumulator memory traffic with larger,
   diverse search traces. The sparse-input and extra-laziness prototypes here
   did not improve full search; repeated-input microbenchmarks are insufficient.
2. Investigate history/TT and network locality across the CPU's two L3 domains
   under longer multithread searches. The short scaling sample above cannot
   distinguish small wins from scheduling and tree variation.
3. Revisit per-thread node publishing only with an independent multithread
   measurement and node-limit correctness checks; the single-thread experiment
   did not establish a useful gain.
4. Follow up separately on malformed-FEN handling and dataset-reader allocation
   behavior recorded in the first pass. Neither is part of the retained hot-path
   changes.

Reproduction tooling lives in `scripts/compare_performance.py`,
`tests/bench_nnue.nim`, `tests/bench_setup.nim`, `tests/test_nnue.nim`, and
`tests/test_alloc.nim`; build examples are in `README.md`. All raw experiment
JSON, logs, C snapshots, assembly and profiles remain in `.cache/perf-audit/`,
with baseline/candidate binaries in `bin/`. The bounded investigation is finished;
no benchmark or test job is intentionally left running.

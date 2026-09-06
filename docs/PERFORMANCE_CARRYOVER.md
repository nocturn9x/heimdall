# Search-optimization carryover experiments

Started: 2026-09-06

Status: **Complete**. Evaluated selected ideas from `perf/search-optimizations`
(`898de94`) on top of `perf/audit-optimizations` (`230b018`). Retained limiter
fast paths, shared-perspective NNUE decoding, and optional PGO; rejected both
prefetch candidates. Fixed depth-limited MultiPV completion and a newly traced
root-aspiration early-stop bug. Final native timed throughput improved **1.65%**;
opt-in PGO improved a further **3.77%** in its separate final comparison. Changes
remain local and uncommitted pending review. All Nim builds used `make dev`;
mandatory diagnostic invariants use `doAssert`.

## Order and acceptance criteria

1. Fix depth-limited MultiPV completion, including mixed depth/node/time limits.
   Test limiter fast paths separately from the correctness change.
2. Test decoding each NNUE move once for both accumulator perspectives. This is
   distinct from the previously rejected consecutive-move batching experiment.
3. Add and evaluate optional PGO with separate training and held-out workloads;
   keep the default `dev` and OpenBench build behavior unchanged.
4. Test TT and accumulator prefetches separately, then confirm retained changes.

Compare optimized binaries with identical networks on CPU 2, using alternating
pairs and hardware counters where applicable. Do not overlap timed runs with
builds or other benchmarks. Preserve deterministic node counts/checksums for
throughput comparisons and distinguish any correctness-driven tree change.
Record rejected experiments, not just wins. Keep binaries, profiles, and raw
measurements under ignored `.cache/perf-audit3/`.

## Reconnaissance

- Starting working tree was clean; branch matches its remote.
- Reproduced the MultiPV issue before this pass: with `MultiPV=3`, `go depth 2`
  reports all three depth-1 lines but only the first depth-2 line. Adding a
  generous node limit reproduces the same result.
- Cause: `highestDepth` is published after each variation, but the hard-depth
  test interprets it as completion of the whole iteration. The old branch's
  early return only bypasses that check when neither node nor time limits exist.
- Queued PGO, shared-perspective decoding, and prefetching for isolated trials.

## Results

### Limit correctness and measurement setup

- Saved a fresh optimized baseline; depth-13 bench remains **5,834,033 nodes**.
  SHA-256: `5a95efebec4ccc2df105278a44a4eae5cd85675bd2a17d532ec891b19ecb5076`.
- Added MultiPV regressions for depths 1/2/3, 1/4 threads, and four combinations
  of depth/node/time limits. All 24 cases reproduced the missing-variation bug.
- Moved depth termination to the between-iterations soft check and removed it
  from hard checks, including mixed limits. Single-PV bench remains 5,834,033.
- The checked standalone limiter diagnostic passed depth boundaries, hard node
  limits including child counts, deterministic expired-clock sampling, pondering,
  disable/re-enable, and clearing/reusing the limiter.
- Worker result selection can intentionally append a deeper worker PV at
  shutdown; tests require all requested-depth lines from the main search but do
  not incorrectly require that final worker line to obey the main depth cap.
- Added a UCI workload driver for real node/time budgets and disjoint corpus
  subsets. It reports aggregate search NPS from final UCI node/time summaries;
  it excludes startup/reset time from NPS but records whole-process wall time.
  Five tool regressions passed. A 24-position/200,000-node smoke run completed
  4,800,012 nodes; these tiny budget overshoots must match in deterministic pairs.
- Tested cached limiter-kind/time-sampling gates against the isolated
  correctness-fixed binary, not against a different search contract.
- The optimized fast-path candidate passed all **31 Python regressions**; the
  checked correctness-only engine also passed the new 24-case MultiPV matrix.
  Mandatory standalone limiter checks passed on both implementations.
- Fixed-node UCI comparisons additionally require per-position node counts,
  attained depths, and bestmove/ponder strings to match. Timed searches naturally
  visit different numbers of nodes, so their throughput is measured without
  pretending that their trees or playing strength are identical.
- Prepared optional `make dev PGO=1` plumbing while timing the limiter. Training
  will use 24 even-indexed FENs, with node and time budgets in separate raw
  profiles; the 24 odd-indexed FENs are held out. These are held-out positions,
  not a claim of independent game-level cross-validation. Default builds and
  OpenBench behavior are unchanged. PGO evaluation comes after the NNUE trial.

### 1. Limiter fast paths — retained

- Against the correctness-only fix, eight depth-14 pairs: **-0.13%** throughput,
  95% bootstrap interval **[-0.81%, +0.35%]**; instructions -0.66%, cycles +0.03%.
  No depth-search improvement is claimed.
- Eight fixed-time UCI pairs (24 held-out FENs, 200 ms each): **+0.91%** search
  throughput, interval **[+0.40%, +1.44%]**. Retained for the timed-search gain.
  Timed runs perform different work; raw whole-process counters are not
  interpreted as fixed-work reductions. Results: `limits-depth14.json` and
  `limits-time.json` under `.cache/perf-audit3/`.

### 2. Shared-perspective NNUE decoding — retained

- Ported only the shared move decode and single refresh flag, not prefetching or
  the older allocation/clone implementation. The 256-frame capacity and live
  prefix copying remain intact. Existing scalar/SIMD arithmetic kernels are
  reused without changing their operations.
- Checked SIMD and forced-scalar NNUE diagnostics both passed **8,491
  comparisons, checksum 1,228,801**, including clone/rebinding and the 255-ply
  boundary. The native depth-13 smoke benchmark stayed at **5,834,033 nodes**.
- Eight depth-14 pairs: **+0.56%**, interval **[-0.07%, +1.24%]**; instructions
  -0.62%, cycles -0.56%. Eight held-out 200,000-node UCI pairs: **+0.93%**,
  interval **[-0.25%, +1.78%]**; instructions -0.55%, cycles -0.88%.
  All per-position results match, but neither timing interval excludes zero.
- The predeclared final confirmation, eight pairs with 1,000,000 nodes per
  held-out position: **+1.56%**, interval **[+0.58%, +2.50%]**; instructions
  -0.58%, cycles -1.58%. Per-position nodes/depths/best moves match. Retained
  based on this longer representative workload, not the inconclusive short
  runs. Every sample is included, including the slower fifth short pair and
  seventh long pair. Raw results: `nnue-pair-depth14.json`, `nnue-pair-nodes.json`, and
  `nnue-pair-confirm.json` under the artifact directory.
- Expanded the NNUE diagnostic to all 960 castling arrangements for both colors,
  explicitly covering stationary kings/rooks and king/rook swaps. Also tightened
  limiter tests for mate-only limits, node budgets during pondering, and clock
  override/reset behavior. The expanded NNUE tests passed **17,731 comparisons,
  checksum 4,912,681**, on both SIMD and scalar. All mandatory limiter checks
  and all **31 Python regressions** passed with the accepted native engine.

### 3. Optional PGO — retained, opt-in only

- `make dev PGO=1` trains a separate executable with node and timed searches,
  merges exactly those two profiles, and uses the merged profile in the final
  build. Explicit `EXE` overrides are preserved without overwriting the trainer;
  standalone test `MAIN` values are rejected for this engine-only workflow.
- Clang and `llvm-profdata` both report version **22.1.8**. Training and held-out
  positions are disjoint after whitespace normalization/deduplication. No
  machine-function-splitting flag or default OpenBench change is imported.
- The actual build completed without warnings or dependency downloads, including
  an explicit `EXE=.cache/perf-audit3/pgo-candidate` override. Training completed
  4,800,006 fixed-budget nodes and 3,670,018 timed nodes; the merged front-end
  profile contains **5,173 functions and 38,856 blocks**. Build log and profiles
  are under the ignored artifact directory.
- PGO passed depth-13 bench (**5,834,033 nodes**) and all **31 Python tests**.
  Eight held-out fixed-node pairs against the accepted native NNUE version:
  **+4.52%**, interval **[+2.62%, +6.60%]**; instructions -6.98%, cycles -4.83%,
  branches -13.32%. All per-position results match. Eight fixed-time pairs:
  **+5.05%**, interval **[+3.71%, +6.46%]**. Retained as an optional build path;
  normal dev/OpenBench defaults remain unchanged. Raw results are `pgo-nodes.json`
  and `pgo-time.json`. The standalone-test guard also rejected an invalid `MAIN`
  in a dry-run check, before any training/build actions.

### 4. Prefetch candidates — both reverted

- Prepared the old branch's approximate-child-key TT prefetch before make-move
  and exact prefetch after a null move. Existing post-move exact prefetches and
  atomic node publication remain untouched. No accumulator prefetch is included
  in this candidate. Built optimized/checked versions, then tested
  depth-14 throughput against the accepted native NNUE version (not PGO).
- TT candidate passed optimized depth-13 bench (**5,834,033 nodes**), checked
  depth-9 bench (**774,807 nodes**), and all **31 checked-engine Python tests**.
  Eight depth-14 pairs: **+1.33%**, interval **[-0.31%, +3.26%]**; instructions
  +0.61%, cycles -1.41%. This was inconclusive. The final confirmation used six
  pairs with 1,000,000 nodes per held-out position; acceptance required a positive interval.
- TT confirmation: **+0.08%**, interval **[-1.37%, +1.41%]**; instructions
  +0.61%, cycles -0.35%. Per-position results match, but the latency benefit did
  not confirm. **Reverted** the approximate-key helper and all three new TT hints;
  `search.nim` was unchanged at this point (a later correctness fix is below). Results:
  `tt-prefetch-depth14.json` and `tt-prefetch-confirm.json`.
- Prepared accumulator destination prefetching as the next separate candidate.
  It hints only the first cache line of the next frame for each perspective;
  frame capacity, lazy-update bookkeeping, and arithmetic remain unchanged.
- The accumulator candidate was built on the accepted NNUE version without TT
  changes. Checked SIMD/scalar correctness and measured depth-14 plus held-out
  200,000-node throughput separately from PGO.
- Accumulator-prefetch checked SIMD/scalar tests both passed **17,731
  comparisons, checksum 4,912,681**; optimized depth-13 bench preserved
  **5,834,033 nodes**.
- Accumulator depth-14 result, eight pairs: **-1.31%**, interval
  **[-2.33%, -0.09%]**; instructions +0.07%, cycles +1.23%.
- Accumulator fixed-node result, eight pairs: **-0.99%**, interval
  **[-1.86%, -0.26%]**; instructions +0.07%, cycles +0.80%. Per-position results
  match, but both workloads show a slowdown. **Reverted** the helper and both
  destination hints. Results: `acc-prefetch-depth14.json` and
  `acc-prefetch-nodes.json`.

## Final validation — additional correctness finding

- Final production code contains the depth/MultiPV correctness fix, root
  aspiration depth guard, limiter fast paths, and shared-perspective NNUE decoding.
  Optional PGO remains opt-in.
  Neither prefetch candidate remains. No node-publication, allocation, global
  huge-page-advice, move-ordering, or search-heuristic changes were imported.
- Rebuilt normal/checked engines and focused diagnostics; then confirmed aggregate
  native throughput against the original baseline and PGO against final native
  using 400 ms per held-out position. PGO was retrained after the additional
  correctness fix; neither rejected prefetch experiment is in the final builds.
- Focused tests passed: limiter diagnostics; **17,731 NNUE comparisons** each
  on SIMD, scalar, and no-THP builds (checksum **4,912,681**); **44,987 move-list
  checks and 41,065 state/hash transitions**; all **31 checked-engine Python
  regressions**. The optimized final pass then caught an intermittent short-node
  test failure, so aggregate timing was paused rather than dismissing it.
- Reproduced the same failure in the **original baseline: 4 of 30 stress runs**.
  Temporary tracing ruled out a reporting-only problem and identified an empty
  root PV after an aspiration retry at **depth zero** (one trace: 7,332 actual
  nodes for a 50,000-node request). No node/time limit had expired. A warm shared
  TT can cause repeated fail-high retries until the unbounded reduction reaches
  quiescence, which may return a TT/stand-pat score without searching a move.
- Clamp root aspiration retry depth to at least one. This is a separate search
  correctness fix, not a throughput claim. The existing stress test now performs
  48 alternating searches per run and documents both late-worker and warm-TT
  coverage. All temporary tracing is removed. Revalidated and retrained PGO because
  production search code changed after its earlier measurements.
- With the clamp, optimized and checked engines both pass all **31 Python
  regressions**. **60 consecutive expanded warm-TT stress runs passed** (2,880
  searches). Depth-13 remains **5,834,033 nodes**, checked depth-9 **774,807**.
  Final PGO profiles are under `.cache/perf-audit3/pgo-final-data/`.
- PGO retraining completed without warnings: 4,800,006 fixed-budget training
  nodes, 3,639,302 timed training nodes; **5,173 functions, 38,857 blocks** in
  the merged profile. The final executable is `.cache/perf-audit3/pgo-final`.
- Confirmed zero overlap between training and held-out sets both as complete
  normalized FENs and as board/turn/castling/en-passant tuples. They are still
  position-level, not independent game-level, held-out sets.
- The benchmark tool's normal script and module (`python -m scripts...`) entry
  points both work. All five pure-Python workload regressions passed again;
  whitespace checking is clean. The only remaining `search.nim` change is the
  root aspiration depth guard.
- Final PGO passed all **31 Python regressions** and **10 additional stress
  runs (480 searches)**. Two-pair fixed-node smoke checks matched per-position
  nodes, depths, and best moves across original baseline, final native, and final
  PGO. These short smoke runs are correctness checks, not speed claims.

## Aggregate confirmation

- Final native versus the original `230b018` baseline, eight alternating pairs,
  24 held-out positions at **400 ms each**, CPU 2: **+1.65% search throughput**,
  95% bootstrap interval **[+1.20%, +2.10%]**. Every pair was positive.
  Native includes both correctness fixes; fixed-node signatures and depth-13
  bench still match on the selected workloads. Raw results:
  `.cache/perf-audit3/final-native-time.json`.
- Final retrained PGO versus final native, six alternating pairs on the same
  400 ms held-out workload: **+3.77%**, interval **[+0.25%, +6.92%]**. This wider
  interval includes all samples, including the two slower final pairs. It is
  consistent with the earlier positive held-out PGO measurements, but not a
  promise of the same gain on other machines. Raw results:
  `.cache/perf-audit3/final-pgo-time.json`.
- Fixed-time samples perform different amounts of work. Their raw whole-process
  counters are not interpreted as fixed-work instruction reductions. No Elo or
  playing-strength improvement is claimed, and component percentages are not
  added together.

## Handoff

- Final normal engine: `bin/heimdall`; checked engine: `bin/testdall`; tested PGO
  engine: `.cache/perf-audit3/pgo-final`. Reproduce the optional build with
  `make dev PGO=1 EXE_BASE=bin/heimdall-pgo`. Default dev/OpenBench builds stay native.
- All **31 Python regressions** pass on normal, checked, and final PGO engines.
  Mandatory limiter, NNUE SIMD/scalar/no-THP, and movegen/state checks pass.
  Original/final depth-13 benches are **5,834,033 nodes**; fixed-node per-position
  signatures match across all three optimized engines. The perft tool smoke
  preserves **4,865,609 nodes** at start-position depth 5.
- No temporary tracing, new TT hints, or accumulator prefetch helpers remain.
  Binaries, profiles, and raw measurements are ignored artifacts, not source
  changes. No commits, pushes, dependency downloads, or branch changes were made
  during this pass.
- Measurements are specific to this Linux/Ryzen 9 5900X host, native AVX2,
  Nim 2.2.6 and Clang/LLVM 22.1.8. Scalar correctness was also checked; other
  hardware/operating systems and playing strength were not evaluated here.

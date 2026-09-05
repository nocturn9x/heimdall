# Performance audit, follow-up pass

Started: 2026-09-05

Status: **Complete**. This pass began from the complete, uncommitted state
documented in `docs/AUDIT_PROGRESS.md`. Thirteen new experiments produced five
retained performance improvements and one capture-only correctness fix. Combined
throughput improved **3.86% at search depth 14, 4.28% at search depth 16, and
11.28% at start-position bulk-perft depth 7** on this host. Broad correctness
checks passed; the three inconclusive/slower NNUE candidates were reverted.
All Nim builds used `make dev`; this audit did not use `nim check`.

## Baseline and discipline

- Preserve all pre-existing working-tree changes from the earlier audit.
- Save an exact baseline executable before changing production code.
- Keep search node counts, perft totals, and NNUE comparison checksums stable
  within throughput experiments; isolate and identify any correctness change
  that necessarily changes the search tree.
- Use isolated candidates and paired runs on the same CPU for timing claims.
- Treat move generation and NNUE as the primary targets, while following profile
  evidence into other hot paths when warranted.
- Record unsuccessful and inconclusive experiments as well as retained changes.

## Initial queue

1. Rebuild and fingerprint the current baseline; confirm deterministic search,
   NNUE, and move-generation checks.
2. Capture fresh search and perft profiles from the consolidated prior result.
3. Audit generated code and data layout in move generation, move scoring, NNUE
   update/refresh/inference, and make/unmake paths.
4. Measure isolated hypotheses, promote only representative wins, and validate
   retained changes in SIMD and scalar configurations.

## Activity log

### 1. Reconnaissance and profiling

- Read the complete prior audit. Its retained changes are the baseline for this
  pass: move-list index preservation, plain-data position-stack truncation,
  full-range huge-page advice, compile-time SEE specialization, and reusable
  per-worker NNUE storage.
- Avoiding already rejected experiments: borrowed SEE weights, widened move-list
  length, per-node atomic load/store publication, direct sequence shrink, sparse
  NNUE inference, per-perspective lazy accumulators, uninitialized refresh
  scratch, and seeded selection sort.
- Baseline rebuilt successfully with `make dev`: SHA-256
  `f9ae98b51a9ea3fd2da741cad8a95d5e5f36e9d250885fd65d0930a5e4606039`.
  Toolchain and host match the prior pass: Nim 2.2.6, Clang 22.1.8, Ryzen 9
  5900X, native AVX2. The saved binary is
  `.cache/perf-audit2/baseline`.
- A symbolized depth-16 profile visited the expected **16,052,624 nodes** at
  1,116,427 NPS and lost no samples. Leading self-cycle shares: NNUE forward
  23.23%, accumulator updates 17.45%, main non-PV search 16.57%, move scoring
  10.55%, refresh 4.68%, quiescence 4.53%, and make-move 4.00%.
- Annotated assembly attributes most NNUE forward samples to the L1 `vpmaddubsw`
  / `vpmaddwd` propagation loop. Clang already unrolls its two output vectors
  and two source-pair accumulators into four independent chains. First novel
  experiment: preserve the exact paired arithmetic while processing two source
  groups per iteration with eight independent chains.
- Movegen review found that `capturesOnly=true` still calls `generateCastling`.
  This contradicts the public contract and can admit a quiet castle into
  quiescence. It is queued for a targeted reproducer and occurrence count rather
  than being mixed into the first throughput experiment.
- Added a focused capture-only movegen diagnostic. It fails on the baseline
  because a castling-ready position returns two captures plus two castles.
  Guarding castling generation makes the diagnostic pass. This changes the
  deterministic search tree (depth 8: 386,302 -> 387,438; depth 14: 8,107,163
  -> 8,581,626), proving the bug reached quiescence. It is retained as a
  contract/correctness fix, but no NPS comparison across that tree change is
  treated as a speed result.
- Compile-time-specialized the move picker for quiescence after enforcing that
  invariant. Killer and countermove tables contain quiet refutations, so capture
  scoring can omit those impossible probes without changing move order.
- Fresh start-position depth-7 bulk-perft profile returned the expected
  **3,195,901,860 nodes**. Leading self-cycle shares were pawn generation 22.08%,
  make-move 17.06%, bishop generation 11.47%, rook generation 10.65%, perft
  bookkeeping 9.98%, knight generation 7.89%, king generation 7.25%, and
  castling generation 5.53%.
- Castling assembly showed generic `Piece.shortCastling`/`longCastling` case
  trees for targets whose piece kind and color are already known, plus three
  separate occupancy tests per side. Replaced them with direct home-rank target
  squares and one union clearance mask. Chess960 rook/king removal from the
  occupancy and per-square attack tests are unchanged.
- A temporary depth-16 instrumented search counted **12,268,544 evaluations**:
  380,900 with no pending update, 11,151,130 with one, and 736,514 (6.0%)
  with two or more. Multi-update evaluations represented roughly 1.98 million
  update applications, about 15% of all applied updates. This is enough to test
  fusing adjacent simple quiet updates, provided every intermediate accumulator
  frame is still materialized for correct undo/evaluate behavior. The temporary
  instrumentation is not part of production source.

## Experiment results

| Experiment | Representative measurement | Decision |
| --- | --- | --- |
| Eight independent AVX2 L1 accumulation chains | 8 depth-14 search pairs: -1.56%, bootstrap interval [-3.99%, +0.94%]; instructions +3.52%, cycles +1.40%; nodes unchanged. All 8,491 checked NNUE comparisons preserved checksum 1,228,801. | Reverted. More instructions and no representative search gain; register pressure is a possible cause, not an established one. |
| Compile-time quiescence move-picker specialization | 8 depth-14 pairs against the capture-correct baseline: **+1.78%**, interval [+0.29%, +3.38%]; instructions -0.60%, cycles -1.51%, branches -2.26%; every run visited 8,581,626 nodes. | Retained. It removes impossible quiet-refutation probes while preserving move order and node count. |
| Dedicated compile-time capture generator | 8 depth-14 pairs against the specialized picker: -0.01%, interval [-1.55%, +1.83%]; instructions -0.23%, cycles -0.05%, branches -0.32%; nodes unchanged. | Reverted. Removing masked-off pawn-push work did not produce a representative cycle or throughput gain. |
| Direct castling targets and union clearance mask | Perft, 4 depth-7 pairs: **+1.40%**, interval [+0.32%, +2.49%]; instructions -3.92%, cycles -1.28%, branches -5.28%; 3,195,901,860 nodes. Search, 8 depth-14 pairs: **+0.90%**, interval [+0.10%, +1.73%]; cycles -0.76%, branch misses -1.43%; 8,581,626 nodes. | Retained. Both representative workloads support the change, and broad Chess960 validation passed. |
| Caller-side null en-passant guard | Perft, 4 depth-7 pairs: +2.91%, interval [+0.57%, +5.30%], instructions -2.11%. Search, 8 depth-14 pairs: **-3.04%**, interval [-4.40%, -1.78%], instructions -0.18% but cycles +3.20% and branch misses +2.12%; nodes unchanged in each workload. | Reverted. The appealing perft gain translated into a clear search regression, which takes precedence. |
| Fuse paired quiet NNUE updates while retaining both frames | 8 depth-14 pairs: +0.26%, interval [-0.34%, +0.86%]; instructions -0.13%, cycles -0.22%, branches -0.40%, branch misses +0.50%; nodes unchanged. Checked NNUE diagnostic preserved all 8,491 comparisons and checksum 1,228,801. | Reverted. Correct but inconclusive, and the added pairing machinery was not justified by the small effect. |
| One enemy threat map for all quiet king moves | 4 depth-7 perft pairs: **-5.23%**, interval [-5.82%, -4.65%]; instructions +5.42%, cycles +5.63%, branches +5.53%; nodes unchanged. | Reverted. Per-destination `isAttacked` short-circuiting is markedly cheaper than generating every enemy attack. |
| Transpose continuation history for sibling locality | 8 depth-14 pairs: +0.52%, interval [-0.06%, +1.06%]; instructions +1.95%, cycles -0.69%, branch misses +0.30%; nodes unchanged. | Reverted. Small and inconclusive; pre-indexing the shared history context may be worth testing separately. |
| Fuse piece relocation's bitboard/hash updates | 8 depth-14 pairs: **-1.63%**, interval [-3.01%, -0.20%]; instructions -0.31%, cycles +1.66%, branch misses +1.12%; nodes unchanged. Expanded checked movegen/state diagnostic passed. | Reverted. Fewer instructions did not compensate for the representative cycle regression. |
| Fuse mixed Finny-refresh remainders | 8 depth-14 pairs: +0.77%, interval [-0.14%, +1.44%]; instructions -0.35%, cycles -0.89%. Independent 6 depth-16 pairs: +0.63%, interval [-0.50%, +1.66%]; instructions -0.38%, cycles -0.83%; 18,132,000 nodes throughout. Checked SIMD and scalar comparisons passed. | Reverted. Both representative estimates were positive but neither excluded noise; the extra refresh dispatch and exported kernel were not justified by a clear search win. |
| Defer make-move king/rook metadata until needed | Perft, 4 depth-7 pairs: **+1.14%**, interval [+0.89%, +1.53%]; instructions -1.21%, cycles -0.95%. Search, 8 depth-14 pairs: -0.13%, interval [-0.98%, +0.88%]; instructions -0.23%, cycles +0.02%; nodes unchanged. Full checked movegen/state test passed. | Retained as a measured perft improvement with neutral search. No whole-search gain is attributed to this change. |
| Compile-time pawn color | Perft, 4 depth-7 pairs: **+3.85%**, interval [+3.05%, +4.65%]; instructions -4.08%, cycles -3.26%, branches -2.80%. Search, 8 depth-14 pairs: +0.49%, interval [-0.78%, +1.73%]; instructions -0.23%, cycles -0.51%; nodes unchanged. Full checked movegen/state test passed. | Retained for the clear perft gain; isolated search effect is inconclusive, with no demonstrated regression. Combined-patch confirmation passed. |
| Pre-indexed continuation rows and capture-only scoring | 8 depth-14 pairs: **+2.84%**, interval [+1.91%, +4.07%]; instructions -2.19%, cycles -2.80%, branches -0.72%; nodes unchanged. Optimized and checked depth-8 benches both preserved 387,438 nodes. | Retained. Resolving the shared history context once made the earlier inconclusive layout change worthwhile. |

## Validation log

- All mandatory invariants in the new movegen and NNUE diagnostics use
  `doAssert`; validation does not rely on production `assert` statements
  surviving optimized builds. Confirmed after the user's reminder.
- Baseline build and profiling completed without dependency downloads.
- Eight-chain NNUE candidate: checked diagnostic passed 8,491 comparisons with
  checksum 1,228,801 before the slower candidate was reverted.
- Capture-only movegen diagnostic: reproduced the baseline assertion failure,
  then passed after excluding castling.
- Direct castling candidate: focused checked movegen diagnostic passed; baseline
  and candidate start-position depth-6 perft both returned 119,060,324 nodes.
- Paired-update NNUE candidate: checked AVX2 diagnostic passed all 8,491
  comparisons with checksum 1,228,801 before the inconclusive code was reverted.
- Expanded checked movegen diagnostic passed **39,407 capture-list comparisons
  and 37,405 state/hash transitions**, including every root move in the full
  corpus and deterministic deeper walks. Undo and cloned history restoration
  matched all saved parents, and every special-move flag was exercised.
- Continuation-layout candidate compiled successfully and preserved depth-8
  search at 387,438 nodes; its completed depth-14 result is in the table above.
- Fused-relocation candidate passed **44,987 capture-list checks and 41,065
  state/hash transitions**, now including cleared castling paths for all 960
  arrangements and both colors. Stationary-king, stationary-rook, and king/rook
  swaps were explicitly exercised. Depth-8 search stayed at 387,438 nodes.
- NNUE mixed-refresh-tail candidate passed **8,491 comparisons, checksum
  1,228,801**, in both explicitly identified SIMD and scalar checked builds.
  Depth-8 search stayed at 387,438 nodes before paired timing.
- Deferred-metadata candidate passed the full movegen/state diagnostic
  (44,987 / 41,065), with all regression conditions expressed as `doAssert`.
  Its depth-8 search remained 387,438 nodes.
- Pawn-color candidate passed the same 44,987 / 41,065 invariant checks and
  preserved the 387,438-node depth-8 benchmark before performance measurement.
- The full movegen diagnostic also passed in the optimized default build,
  still running all 44,987 / 41,065 `doAssert` invariants.
- Pre-indexed scoring compiled successfully and preserved the depth-8 search
  count at 387,438 before checked-engine and performance validation.

## Follow-up activity

- Resumed the interrupted castling whole-search measurement using the saved
  binaries. No partial or interrupted run is treated as a completed result.
- Tested a continuation-history transpose: index by preceding move first and
  candidate move last so sibling destinations share nearby cache lines. This
  changes storage layout, not scores or history updates.
- Expanded `tests/test_movegen.nim` to compare capture lists against filtered
  full lists, rebuild all position hashes/bitboards after moves, and check
  make/unmake, null moves, and clones across the standard/Chess960 corpus.
- NNUE weights occupy an ordinary global object, unlike the huge-page-backed
  accumulator and history storage. Inspected that large read-mostly table's
  actual mapping before considering a new allocator.
- Mapping inspection during an actual benchmark showed **40 MiB of anonymous
  huge pages in the 41.1 MiB BSS mapping containing the 36.2 MiB network**.
  This host already promotes the weights automatically. Deprioritized a new
  global-network allocator: it would add ownership/initialization complexity
  without addressing a demonstrated missing huge-page mapping here.
- Tested fusing relocation's remove/spawn bookkeeping into
  one XOR per piece/color bitboard and per applicable hash. The moving piece
  retains its kind and color, so the classification need not run twice.
- Separate search-heuristic finding: `isKillerMove` bounds `ply` using
  `killerMoves[0].high()` (the inner dimension) instead of the outer ply
  dimension. With one killer slot, non-root lookups are disabled. Recorded for
  a dedicated heuristic/strength test; not mixed into throughput-only changes.
- Scalar validation forces the Makefile's native legacy branch with
  `AVX2_SUPPORTED=0 AVX512_SUPPORTED=0 VNNI_SUPPORTED=0`. Merely putting `-u:simd`
  in `EXTRA_NFLAGS` is insufficient because native SIMD defines come later.
  The NNUE diagnostic now prints its selected backend to make this verifiable.
- Tested batching the mixed add/sub remainders in Finny-cache refreshes. The
  candidate preserved the existing quad batches and used two-/four-feature
  kernels for the tail. It was reverted after inconclusive search measurements.
- Followed the make-move profile into unconditional metadata loads: king
  square/piece and both castling-rook squares were read even for ordinary pawn
  or minor-piece moves, then kept live across stack growth and copying. Tested
  and retained reading metadata only in the appropriate special-move branch.
- Completed the remaining queue: deferred make-move metadata, color-specialized
  pawn generation, and pre-indexed move-scoring history. Froze production
  changes before full regression and aggregate performance confirmation.
- Pawn-color specialization replaces repeated runtime direction/rank decisions
  with two compile-time versions selected once at the generator entry. Move
  order, legality masks, and the shared en-passant helper remain unchanged.
- Final scoring experiment combines the previously tested history transpose
  with row pointers resolved once per sibling list, avoiding repeated index
  calculations. Capture-only scoring also omits the impossible quiet-history
  branch. All history values, updates, and ordering ties remain unchanged.
- All thirteen experiments are complete. Production source stayed frozen during
  aggregate measurements and broad validation; five throughput candidates and
  the separately identified capture-only correctness fix are retained.

## Retained changes in this pass

1. Exclude castling from capture-only generation (correctness; changes search
   nodes, and is isolated from all throughput comparisons).
2. Specialize capture-only move scoring, removing impossible quiet-refutation
   probes and quiet-history work.
3. Compute castling destinations directly and combine occupancy-clearance tests.
4. Defer king/rook metadata in make-move until its relevant branch.
5. Specialize pawn generation for the two colors without changing move order.
6. Store continuation history by preceding move, and resolve the three shared
   row pointers once per move list.

The prior audit's uncommitted changes are preserved. NNUE production code is
unchanged from that starting point: all three new arithmetic/update candidates
were reverted after measurement. The NNUE test now reports its actual backend.

## Aggregate measurements and final validation

- **Depth-14 search, 8 pairs:** +3.86% throughput, interval [+2.89%, +4.96%];
  instructions -3.23%, cycles -3.81%, branches -3.26%; every run searched
  8,581,626 nodes. Raw result: `.cache/perf-audit2/final-search-depth14.json`.
- **Depth-16 search, 6 pairs:** +4.28% throughput, interval [+3.58%, +4.92%];
  instructions -3.23%, cycles -4.18%, branches -3.43%; every run searched
  18,132,000 nodes. Raw result: `.cache/perf-audit2/final-search-depth16.json`.
- **Start-position depth-7 bulk perft, 4 pairs:** +11.28% throughput, interval
  [+10.70%, +11.85%]; instructions -8.78%, cycles -10.05%, branches -7.46%;
  every run returned 3,195,901,860 nodes. Raw result:
  `.cache/perf-audit2/final-perft.json`. This is a separately measured combined
  result, not a sum of individual candidate estimates.
- Final `make dev` completed and produced `bin/heimdall`.
- The final movegen implementation passed **44,987 capture-list checks and
  41,065 state/hash transitions** in both checked and optimized builds. These
  include all special-move flags and all 960 cleared castling arrangements for
  both colors; mandatory checks use `doAssert` in both configurations.
- Final checked SIMD NNUE diagnostic passed 8,491 comparisons, checksum
  1,228,801, with the retained move-generation changes.
- Final checked scalar and forced-no-THP SIMD NNUE diagnostics also passed
  8,491 comparisons each, with the identical checksum 1,228,801.
- Python test-tool and UCI regressions: **24/24 passed on the final native
  binary, and 24/24 on the checked binary** (6.24 / 6.39 seconds).
  Logs: `.cache/perf-audit2/python-default.log` and `python-checked.log`.
- Checked non-bulk edge-position perft: **21/21 passed against Stockfish at
  depth 4** (7.15 seconds). Log: `.cache/perf-audit2/perft-checked-edge.log`.
- Full standard/Chess960 corpus: **1,155/1,155 passed against Stockfish at
  depth 4**, using optimized bulk perft (129.54 seconds).
  Log: `.cache/perf-audit2/perft-all.log`.
- Heavy standard positions: **7/7 passed against Stockfish at depth 6**,
  using optimized bulk perft (75.82 seconds).
  Log: `.cache/perf-audit2/perft-heavy.log`.
- `make dev IS_TEST=1 ENABLE_TUNING=1` compiled successfully; its depth-8 smoke
  benchmark also visited exactly 387,438 nodes.
- Valgrind Memcheck on the final optimized depth-8 benchmark reported **0 errors
  from 0 contexts**, with 387,438 nodes. Leak checking was disabled; no leak-free
  claim is made. Log: `.cache/perf-audit2/valgrind-final.log`.
- A final symbolized depth-16 profile visited 18,132,000 nodes and lost no
  samples (319K cycle samples). Leading current self-cycle shares: NNUE forward
  23.19%, accumulator updates 18.28%, main non-PV search 16.97%, quiet move
  scoring 5.96%, quiescence 4.90%, refresh 4.82%, and make-move 4.08%.
  NNUE forward/update/refresh still totals about **46.3%**. Changed inlining and
  the corrected search tree mean these shares are current profiling targets,
  not direct before/after function-speed ratios.
- Combined search is compared against `.cache/perf-audit2/capture-only-fix`,
  which has the same corrected tree. Perft can also be compared to the original
  saved baseline because ordinary perft's legal move set is unchanged.
- Results are host/compiler-specific paired measurements, not Elo estimates.
  Intervals are exploratory bootstrap intervals from the saved raw pairs.
- Final source review checked the equivalence of the union clearance mask,
  castling flag/target correspondence, unchanged pawn move order, consistent
  transposition of every continuation-history read/write, matching 1/2/4-ply
  conditions, and row-pointer lifetime within the owning search manager.
- Final tracked diff and new test/journal whitespace checks found no errors.
  `src/heimdall/nnue.nim` has no remaining diff; the final executable fingerprint
  still matches the measured binary after all diagnostic builds.
- The thirteen exploratory experiments account for **122 paired measurements**,
  excluding warmups, profiles, smoke checks, and aggregate confirmation runs.
- Including aggregate confirmation, **140 pairs / 280 timed runs** completed,
  in addition to warmups, correctness checks, and sampling profiles.
- Final native binary SHA-256:
  `faa42416c80b5c13a3bd31c1fac5d8b34db07daa19aa67eda36f7a4e34f1846b`.
- Capture-correct search baseline SHA-256:
  `e307be825bc6382b6588268ac42ca69249905e2ddf802a876c7a96e206c81799`.

## Reproduction

Run from the repository root with the existing local dependencies and weights.
The saved baseline binaries are local ignored artifacts, not regenerated from
the final source. Run timed comparisons sequentially, without competing builds
or tests. CPU 2 was used here; select an available CPU on another host. New output
names below preserve the recorded audit samples.

```sh
make dev
python scripts/compare_performance.py .cache/perf-audit2/capture-only-fix bin/heimdall --depth 14 --pairs 8 --cpu 2 --perf --output .cache/perf-audit2/repeat-search14.json
python scripts/compare_performance.py .cache/perf-audit2/capture-only-fix bin/heimdall --depth 16 --pairs 6 --cpu 2 --perf --output .cache/perf-audit2/repeat-search16.json
python scripts/compare_performance.py .cache/perf-audit2/baseline bin/heimdall --mode perft --depth 7 --pairs 4 --cpu 2 --perf --output .cache/perf-audit2/repeat-perft.json
```

Focused correctness checks (build variants of the same `MAIN` sequentially):

```sh
make dev MAIN=tests/test_movegen.nim IS_TEST=1 EXE_BASE=bin/test-movegen EVALFILE="$PWD/networks/files/gramr.bin"
bin/test-movegen
make dev MAIN=tests/test_movegen.nim EXE_BASE=bin/test-movegen-opt EVALFILE="$PWD/networks/files/gramr.bin"
bin/test-movegen-opt
make dev MAIN=tests/test_nnue.nim IS_TEST=1 EXE_BASE=bin/test-nnue EVALFILE="$PWD/networks/files/gramr.bin"
bin/test-nnue
make dev MAIN=tests/test_nnue.nim IS_TEST=1 AVX2_SUPPORTED=0 AVX512_SUPPORTED=0 VNNI_SUPPORTED=0 EXE_BASE=bin/test-nnue-scalar EVALFILE="$PWD/networks/files/gramr.bin"
bin/test-nnue-scalar
make dev MAIN=tests/test_nnue.nim IS_TEST=1 EXTRA_NFLAGS=-d:noTHP EXE_BASE=bin/test-nnue-fallback EVALFILE="$PWD/networks/files/gramr.bin"
bin/test-nnue-fallback
make dev IS_TEST=1 EXE_BASE=bin/testdall
python -m unittest discover -s tests -p 'test_*.py'
HEIMDALL=bin/testdall python -m unittest discover -s tests -p 'test_*.py'
python tests/suite.py -d 4 -b -p -w 4 -s -f tests/all.txt --heimdall bin/heimdall
python tests/suite.py -d 6 -b -p -w 2 -s -f tests/standard_heavy.txt --heimdall bin/heimdall
python tests/suite.py -d 4 -p -w 2 -s -f tests/illegal_edge_cases.txt --heimdall bin/testdall
```

## Limits and future targets

- No network weights, network architecture, dependency versions, or system
  performance settings were changed. Generated binaries, raw timings, profiles,
  and diagnostic logs remain ignored under `.cache/perf-audit2/`.
- Performance claims apply to this Ryzen/AVX2/Clang configuration and these
  deterministic workloads. Scalar correctness was checked, not scalar speed;
  AVX-512/VNNI and other operating systems were not runtime-tested here.
- No Elo or playing-strength claim is made. The capture-only correctness fix
  changes the search tree; all search speed comparisons isolate that change by
  using the capture-correct baseline.
- NNUE still consumes roughly 46.3% of sampled self cycles across forward,
  update, and refresh. Future candidates need a new hypothesis, not another
  unmeasured increase in unrolling or update-batching machinery.
- The separate killer-table dimension finding remains a dedicated
  heuristic/strength-testing task. It is documented above, not silently folded
  into the throughput work.
- Prior audit changes were preserved; nothing was committed or downloaded.

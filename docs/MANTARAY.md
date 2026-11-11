# MantaRay v7 backend

Heimdall can use [MantaRay](https://github.com/TheBlackPlague/MantaRay/tree/v7)
for both incremental feature updates and forward inference. This is opt-in;
ordinary builds retain the native Nim backend.

The submodule pins v7 commit `6791a964bc4edc71af78ecdcacfd4857e8a8ca32`.
Initialize it once (this command accesses the network):

```sh
git submodule update --init vendor/MantaRay
```

Build with the existing Makefile, Nim 2.2.2+, and a C++23-capable Clang/toolchain
(tested with Clang 23.1.4 and Nim 2.2.12):

```sh
make dev MANTARAY=1 EVALFILE="$PWD/networks/files/remiel.bin" EXE_BASE=bin/heimdall-mantaray
```

`MANTARAY_INCLUDE` can point to another checkout's `include` directory;
`MANTARAY_CXX` defaults to `clang++`. The compiler and linker must support the
same LLVM bitcode version when using LTO. `make dev` never fetches these headers
or weights. The bridge is rebuilt on every build to avoid stale header/define
caches. Objects live in ignored `build/mantaray/<executable>/` directories.

The implementation uses a small C ABI bridge compiled as C++23. Nim continues
to use its C backend. The Makefile supplies the architecture, dimensions and
scale to both sides; the network still uses Nim's embedding mechanism, so
`#embed` is not needed. `EMBED_NET=0` and runtime EvalFile loading also work.

## Network compatibility

The supported model is Heimdall's multilayer TI architecture: TI60144 plus
16 mirrored king buckets with separate king planes, eight material output
buckets, QA=255, FT shift=9, L1 shift=8, and Q=64. `L1_SIZE`, `L2_SIZE`,
`L3_SIZE`, `EVAL_SCALE`, and `DUAL_ACTIVATION` are configurable. The other
quantization/feature settings are checked at compile time. Single-layer and
nonzero `L1_BIAS_SHIFT` configurations are rejected.

Disk matrices remain in Heimdall's canonical `[input][bucket][output]` order;
MantaRay packs its own kernels. The dual head applies `min(x*x, Q*Q)` to the
signed L1 output, including negative inputs. Its other branch clamps to
`[0,Q]` then scales by Q. The PSQ/TI sum wraps as int16 before activation,
matching the native backend. Hidden/output layer weights and biases must fit
the graph's declared bounds; an incompatible file fails at load time with a
tensor/index diagnostic. Original bytes, including accepted Bullet padding,
are preserved by the mixed-mode `verbatim PATH` command (send `icu` first).

## State and lifetime

The board adapter borrows the bitboards and packed mailbox. It converts a8=0
to a1=0 on access, without copying a position. Every state owns a lazy MantaRay
stack with 256 entries. A move is queued before `doMove`, then pushed with its
resulting board at the next update or evaluation. Null moves require no stack
entry because neither feature set changes. This works with MantaRay assertions
enabled; `IS_TEST=1` enables those assertions.

Clones copy stack history and the queued move. Destructors release stacks and
shared immutable networks. Network loading is serialized and identical weights
are shared between workers. A reload cannot invalidate an existing state's
network. Each new search state is initialized or copied before evaluation.

## Verification

The NNUE regression suite compares every incremental MantaRay accumulator lane
with a refreshed MantaRay stack, and compares scores against both fresh
MantaRay inference and native Nim inference:

```sh
make dev MANTARAY=1 MAIN=tests/test_nnue.nim IS_TEST=1 \
  EXE_BASE=bin/test-mantaray EVALFILE="$PWD/networks/files/remiel.bin"
bin/test-mantaray
```

Use `EXTRA_NFLAGS=-d:mantarayVerify` on an engine build to compare every search
evaluation against a full MantaRay rebuild. For reproducible synthetic tests:

```sh
python tests/make_multilayer_fixture.py build/tests/mantaray-ti.bin
make dev MANTARAY=1 SIMD=scalar MAIN=tests/test_nnue.nim IS_TEST=1 \
  EXE_BASE=bin/test-mantaray-scalar EVALFILE="$PWD/build/tests/mantaray-ti.bin"
bin/test-mantaray-scalar
```

`SIMD=scalar` forces MantaRay's scalar backend. Explicit ISA selections and
`SIMD=auto` follow the Makefile compiler flags. Runtime dispatch
(`SIMD=universal`) and cross-compilation targets are currently rejected.
Linux x86-64 is the validated platform; Windows, macOS and AArch64 remain
unverified. Standalone native tests that inspect or mutate native accumulators
or weights should continue to run without `MANTARAY=1`.

## Inspecting the graph and kernels

```sh
make -s mantaray-ir SIMD=avx2
make -s mantaray-ir SIMD=scalar MANTARAY_ACCUMULATORS=combined
```

The diagnostic uses the same model, architecture flags, dimensions, quantization
and accumulator grouping as the engine. It prints canonical IR with inferred
ranges and types, the actual stack's accumulator slots, MantaRay's kernel
selection explanations, runtime scratch buffers and `sizeof(Stack)`. It neither
loads nor downloads network weights. Use `MANTARAY_DIR` to relocate its binary.

For the default AVX2 model, inspection found:

| Stage | Selected implementation |
| --- | --- |
| FT activation | Packed pairwise MulHi, with the one-sided clamp optimization |
| L1 | Sparse `u8 × i8` Maddubs, bias initialization fused into the dot product |
| Dual activation | One vectorized pointwise stage including the L1 shift |
| L2 | Broadcast `i16 × i16` Madd, fused bias and output clamp |
| L3 | RowDot `i32 × i32` MulLo, fused bias |

All three dense layers select just the requested material bucket. There are no
Generic or Reference stages. Although raw PSQ/TI sum facts can be int32, the
actual stored accumulator slots are int16 because of `Wrap<i16>`. The pointwise
stage's six IR nodes do not imply six separate array passes: the runtime emits
vectorized expressions into the L2 input. The padded inference scratch buffers
total 832 bytes at the default dimensions.

`MANTARAY_ACCUMULATORS=split` (the default) retains separate PSQ and TI accumulators;
`MANTARAY_ACCUMULATORS=combined` stores their modular sum. Combined storage
reduces four slots to two and avoids adding the feature sets during activation.
At the default dimensions, the AVX2 stack object shrinks from 1,245,568 to
647,296 bytes (about 48%). The tradeoff is that a king-bucket refresh involves
both feature sets. This switch affects runtime storage, not disk layout or
network mathematics.

## Local results (2026-11-11)

On an AMD Ryzen 7 5700U, all of the following passed 17,797 position
comparisons, including native-score parity, every MantaRay accumulator lane,
all 960 castling arrangements for both colors, promotions, en passant, null
move descendants, pending/evaluated undo, cloning, and the 255-ply boundary:

| Backend | Network | Activation |
| --- | --- | --- |
| AVX2 | local `remiel.bin` | dual |
| Scalar | generated synthetic fixture | dual |
| SSE2 | generated synthetic fixture (`--dual 0`) | single |

These runs also verified exact canonical export, rejection of invalid files,
and independent network ownership across reloads and clones. The unchanged
native implementation passed the same expanded position corpus. A two-thread
UCI search after an EvalFile reload and canonical export also passed.

The engine built with `IS_TEST=1 EXTRA_NFLAGS=-d:mantarayVerify` matched the
native depth-9 benchmark at **800,673 nodes**, checking fresh evaluation
throughout search. Python discovery ran 109 tests: 103 passed, five skipped,
and one existing Linux launcher permissions test failed. That same failure
reproduced with the native baseline (`test_unsafe_cache_permissions_symlinks_and_relative_paths_are_rejected`).

The initial split-storage integration used identical default architecture settings and the same
`remiel.bin`. Eight alternating depth-11 benchmark pairs pinned to CPU 2 each
searched **2,265,154 nodes**. MantaRay's geometric mean speedup was **4.26%**
(bootstrap 95% interval **3.83%–4.75%**); median throughput was 915,967 versus
880,183 nodes/s. No hardware counters were collected. This measures search
speed on this machine, not playing strength. Reproduce with:

```sh
make dev EXE_BASE=bin/heimdall-native
make dev MANTARAY=1 EXE_BASE=bin/heimdall-mantaray
python scripts/compare_performance.py bin/heimdall-native bin/heimdall-mantaray \
  --cpu 2 --pairs 8 --depth 11 --output build/mantaray-comparison.json
```

PGO, other CPUs and other operating systems have not been validated.

## IR-guided experiments (2026-11-11)

Two equivalent alternatives were measured against the initial MantaRay split
build, using the same compiler settings and `remiel.bin` on the Ryzen 7 5700U:

| Change | Workload | Speed change | Bootstrap 95% interval |
| --- | --- | --- | --- |
| Combine PSQ and TI accumulators | Six paired depth-11 benches | +3.26% | +0.14% to +6.69% |
| Clamp signed L1 values to `[-64,64]` before squaring | Six paired depth-11 benches | -2.83% | -4.23% to -1.44% |
| Combine PSQ and TI accumulators | Twelve paired fixed-node UCI runs | -1.30% | -3.73% to +0.95% |

The activation rewrite retained the same lowered stages and scratch buffers;
it was discarded. It implements `square(clamp(x,-64,64))`, which is equivalent
to `min(x*x,4096)` for this graph, but did not improve generated-code performance.

Combined storage retains the same forward kernels with two accumulator slots.
The longer UCI measurement used 24 odd-indexed benchmark positions, 200,000
nodes per position, one search thread and CPU 2. Every run searched 4,800,000
nodes and matched per-position depths and best moves. It did not confirm the
short bench's apparent gain. Split storage remains the default; combined
storage is available for its smaller stack, with workload-dependent performance.

Both storage choices passed the AVX2, scalar and SSE2 correctness configurations
above: 17,797 comparisons each, including all stored accumulator lanes and
network lifetime checks. Combined storage additionally passed four focused UCI
regressions covering worker restarts, fresh/incremental policy scores, MultiPV
depth limits and node limits with workers.

Reproduce the longer comparison with:

```sh
make dev MANTARAY=1 MANTARAY_ACCUMULATORS=split EXE_BASE=bin/heimdall-mantaray-split
make dev MANTARAY=1 MANTARAY_ACCUMULATORS=combined EXE_BASE=bin/heimdall-mantaray-combined
python scripts/compare_performance.py bin/heimdall-mantaray-split bin/heimdall-mantaray-combined \
  --mode uci --positions src/heimdall/resources/misc/bench.txt \
  --count 24 --offset 1 --stride 2 --limit-kind nodes --limit 200000 \
  --cpu 2 --pairs 12 --output build/mantaray-combined-uci.json
```

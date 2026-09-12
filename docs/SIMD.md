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

# SIMD backends

Inference, PSQ updates and threat updates use the same `vec*` API in
`src/heimdall/util/simd.nim`. Static builds select one backend at compile time. `SIMD=universal` compiles the
same kernels for several backends and selects one at startup, sharing one network
and accumulator representation.

| Backend | Register bytes | Build selection | Portable target |
| --- | ---: | --- | --- |
| SSE2 | 16 | `make dev SIMD=sse2` | `make sse2` (baseline x86-64) |
| SSSE3 | 16 | `make dev SIMD=ssse3` | `make ssse3` (x86-64 + SSSE3) |
| SSE4.1 | 16 | `make dev SIMD=sse41` | `make sse41` (x86-64 + SSE4.1) |
| AVX2 | 32 | `make dev SIMD=avx2` | `make avx2` (x86-64-v3) |
| AVX-512 | 64 | `make dev SIMD=avx512` | `make avx512` |
| AVX-512 VNNI | 64 | `make dev SIMD=avx512-vnni` | `make avx512-vnni` |
| AArch64 NEON | 16 | `make dev SIMD=neon` | `make neon` (ARMv8-A) |
| Scalar | — | `make dev SIMD=scalar` | `make scalar` (host architecture) |

Supply an absolute `EVALFILE` for the selected network architecture, as with any
other build. `make dev` never fetches dependencies or weights. The named platform
targets prepare dependencies unless `SKIP_DEPS=1` is supplied.

`SIMD=auto` is the default: VNNI, AVX-512, AVX2, SSE4.1, SSSE3, SSE2, NEON, then
scalar, according to the compiler's native feature macros. AArch64 detection uses
`-mcpu=native`. Explicit SSE2, SSSE3, SSE4.1 and NEON selections use their baseline
ISA flags, even when compiling on a newer CPU. Selecting a backend does not emulate
its instructions: running it requires the corresponding CPU or an emulator.
The Makefile clears backend defines from local `nim.cfg` and `EXTRA_NFLAGS`
before applying its selection. Use `SIMD=scalar` for scalar inference checks;
disabling only the AVX feature probes can now select SSE2, SSSE3 or SSE4.1.

Public target and artifact names use this scheme only for versions newer than
1.5.0. The [README legacy artifact guide](../README.md#legacy-artifacts-versions-13-through-150)
covers earlier downloads. Old Make target names are not aliases.

Portable targets separate compatibility from tuning: `avx2` uses
`-march=x86-64-v3`, `avx512` uses `-march=x86-64-v4`, and `avx512-vnni` adds
`-mavx512vnni` to v4. SSE targets start at `-march=x86-64` and explicitly enable
SSSE3 or SSE4.1 as needed. `TUNE=generic` is the portable default;
`make avx2 TUNE=znver2` changes only `-mtune`, retaining the same v3 requirement.
Native compiler flags still use the build host's CPU. No separate Zen 2 artifact
is published.

`make macos-amd64` and `make macos-arm64` are convenience targets for native
Intel and Apple Silicon Mac hosts, selecting SSE2 and NEON respectively. The
Makefile uses Apple ld, an 8 MiB stack, and a configurable
`MACOSX_DEPLOYMENT_TARGET` (default `11.0`). See [release builds](RELEASES.md) for
the corresponding artifact names and independently selectable CI jobs.

## Universal binaries

```sh
make dev SIMD=universal EVALFILE=/absolute/path/to/net.bin
bin/heimdall simd
HEIMDALL_SIMD=sse2 bin/heimdall bench 9
make test-simd SIMD=universal
```

`make universal SKIP_DEPS=1` builds the same target with locally available
prerequisites. On x86-64 it contains scalar/autovectorized, SSE2, SSSE3, SSE4.1,
AVX2, AVX-512 and AVX-512 VNNI kernels. On AArch64 it contains scalar and NEON.
The default priority follows that order, choosing the last supported backend.
The x86 compiler runtime checks CPUID and the operating system's enabled vector
register state. Unsupported or unknown `HEIMDALL_SIMD` overrides fail at startup.
Static builds ignore the override and report only their compiled backend.
Selection is immutable after initialization and shared by all search threads.
`heimdall simd` reports the selected and supported backends without loading weights.

Each ISA variant specializes an entire PSQ operation, TI diff/rebuild, or forward
pass. Vector primitives remain inline and vector values never cross the dispatch
boundary. The `simdKernel` pragma in `util/simd_dispatch.nim` specializes backend
conditionals and binds primitives to the corresponding module. Scalar accumulator
arithmetic explicitly wraps, including in correctness builds. Small accumulator
rows that do not meet the chosen vector width use the scalar implementation.

The Makefile compiles ordinary engine code and initialization for baseline
x86-64 or ARMv8-A. ISA-specific kernels and their helpers carry function target
attributes on x86; LTO preserves those boundaries. Do not add native or advanced
ISA flags globally to a universal build. The scalar path may be autovectorized
within the baseline ISA. `SIMD=auto` retains the existing native build behavior.

Linux and Windows binaries cover one CPU family each. On a Mac,
`make macos-universal SKIP_DEPS=1 EVALFILE=/absolute/path/to/net.bin` compiles
both CPU families and combines them with `xcrun lipo`. Both slices use the same
network layout; the disk weights are embedded once per slice. This target needs
Apple's SDK, uses separate Nim caches, and builds without PGO. A native universal
build can still use the existing optional PGO flow.

## Shared packing layout

Multilayer networks with FT widths divisible by 128 use the same AVX-512 dense
weight permutation on every backend. PSQ weights, TI weights, FT biases and both
accumulator stacks remain in canonical neuron order. The disk format is unchanged;
export reverses the dense weight permutation.

CJ's trick produces the same packed bytes using narrower registers. Each letter
below represents eight int16 values, and each packed pair contains sixteen bytes:

```text
AVX-512: pack([a,b,c,d], [e,f,g,h]) = [ae,bf,cg,dh]
AVX2:    concat(pack([a,b], [e,f]), pack([c,d], [g,h]))
SSE/NEON: concat(pack(a,e), pack(b,f), pack(c,g), pack(d,h))
```

Concatenation is consecutive stores, requiring no extra shuffle instructions.
Each perspective is processed separately in blocks of 64 pairwise products.
The dense weight loader always uses the same four-byte group order:
`[0,1,8,9,2,3,10,11,4,5,12,13,6,7,14,15]`. Scalar inference uses the inverse index
mapping. The non-VNNI two-dot operations retain their eight-input grouping.
Small debug architectures whose FT width is not divisible by 128 retain canonical
dense weights and use the scalar head. Incompatible hidden-layer widths also
fall back to that head. The single-layer debugging architecture is unchanged.

## Maintenance boundary

SSE2, SSSE3 and SSE4.1 instantiate `simd_backends/x86_128.nim`, using the existing pinned
`nimsimd` dependency. `vecMaddubs16` selects between two implementations: SSE2
widens bytes, forms int32 pair sums, then saturates; SSSE3 has a direct instruction.
Signed int32 min/max
and low multiplication use SSE2 sequences in the SSE2/SSSE3 builds. SSE4.1
selects direct `_mm_max_epi32`, `_mm_min_epi32`, `_mm_mullo_epi32` and
`_mm_cvtepi8_epi16` intrinsics in that same module. It uses an explicit SSE4.1
feature flag and does not require SSE4.2, POPCNT or AVX.

NEON uses a small local C adapter and Nim declarations in `simd_backends/`.
The pinned `nimsimd` NEON bindings expose unsigned operations only, so they
cannot express the signed inference operations directly. The adapter uses the
compiler's standard `arm_neon.h`; there is no new library, generated binding
step, or fetched portability header. Its one opaque register type preserves the
existing interchangeable `VEPI16`/`VEPI32` API. ARM support is limited to
little-endian AArch64; AArch32, SVE and optional ARM dot-product extensions are
outside this implementation.

SIMD threat-row updates and rebuilds keep four accumulator registers live,
sharing each feature index and row address across four chunks. A single-register
loop handles smaller widths and remaining lanes. `vecLoadI8AsI16x2` loads two
consecutive chunks: its shared x86 fallback uses the existing widening loads,
while NEON shares one 16-byte load between the low and high signed-byte halves.
NEON's NNUE dot helpers use `SADALP` to widen, sum and accumulate signed int16
pairs, retaining the existing pair saturation and x2 wrapping semantics.
The byte multiply-add splits even and odd bytes within each 16-bit lane,
multiplies them separately, and uses a saturating 16-bit add. Each product fits
in int16, so this avoids widening pair sums to int32 and narrowing them again.
The common PSQ quiet/capture updates process four vectors per iteration on SSE2,
AVX2 and NEON, with a single-vector loop for smaller widths and remaining lanes.
Other backends retain compiler-controlled unrolling for these PSQ operations.
The first matrix multiply processes two four-byte input groups per iteration
on SSE2 and NEON to reduce register pressure. The saturated pair products and x2 int16
wrapping retain their original grouping; only the wrapping int32 sums are
regrouped into one accumulation chain.

Existing inference changes written against `vec*` apply to every backend.
Adding a new primitive still requires a wrapper and a shared contract test;
compiler or runner upgrades can still need attention. This keeps maintenance
small but cannot guarantee literally zero maintenance.

## Integer and layout contract

- Loads/stores use a whole register. Callers retain the existing 64-byte
  accumulator alignment. `vecLoadI8AsI16` reads exactly one signed byte per int16
  lane, accepts unaligned input and sign extends without reading a full register.
  `vecLoadI8AsI16x2` reads twice that many bytes into two int16 vectors and also
  accepts unaligned input.
- Integer adds, subtracts and low products wrap. Signed high multiplication,
  arithmetic versus logical shifts, and saturating int16-to-uint8 packing retain
  the x86 semantics. The NEON shift wrappers handle oversized counts explicitly.
- Primitive SSE2, SSSE3, SSE4.1 and NEON packing concatenates two eight-lane
  inputs, and `vecPermute` is an identity. Inference uses the common packing
  schedule above; primitive contracts and disk weights remain unchanged.
- The new backends match **non-VNNI** `vecDpbusd`/`vecDpbusdx2`: adjacent byte
  products saturate to int16, and x2 adds those pair sums with int16 wrapping
  before widening. Existing VNNI instead accumulates full products directly into
  int32. Tests preserve both contracts; arbitrary overflowing inputs are not
  assumed to agree across VNNI, non-VNNI and scalar inference.

## Verification and CI

Run `make test-simd SIMD=universal`, `SIMD=sse2`, `SIMD=ssse3`, `SIMD=sse41`, `SIMD=neon`, or another
backend. It generates synthetic weights under ignored `build/simd/` and runs:

- `test_simd`: every primitive, signed edges and randomized lanes, overflow,
  saturating dot products, packing, shifts, and unaligned byte widening.
- `test_multilayer`: both activation modes, both perspectives and all buckets
  against the independent canonical-layout oracle; exact export and reload.
- `test_nnue`: all-lane incremental/fresh comparisons, pending updates, cloning,
  the ply boundary and all Chess960 castling arrangements.
- `test_threat_diff` at width 768 and `test_threat_updates`.

For universal builds the target discovers supported backends and forces each one
through the same binaries. It also checks rejection of unknown/unsupported
backends. Python/UCI regressions include matching scores, node counts and best
moves across the available backends. Use `SIMD_TEST_DIR` to keep cross-build
artifacts separate; `SIMD_TEST_RUNNER` and the Makefile executable suffix also
apply to universal tests.

For threat-row tail checks, also build `tests/test_threat_diff.nim` at one or
five int16 vector widths: `L1_SIZE=8`/`40` for SSE and NEON, `16`/`80` for AVX2,
and `32`/`160` for AVX-512. Use an absolute `EVALFILE` as for other standalone
tests. The arithmetic test does not load the file. `test_nnue` directly checks
PSQ quiet/capture updates at one, four and five vector widths, including int16
wrapping and parent preservation.

Start the GitHub SIMD workflow manually from **Actions → SIMD correctness →
Run workflow** (`workflow_dispatch`). It runs the same target for scalar, SSE2, SSSE3, SSE4.1 and
AVX2 on Linux x86-64 and NEON on native `ubuntu-24.04-arm`, then builds the engine
and runs Python/UCI regressions. Universal builds run on both Linux CPU families,
Windows, Intel Mac and Apple Silicon. The Apple Silicon job also checks both
slices of the combined executable using Rosetta. QEMU's Opteron G1, Conroe,
Penryn and Haswell models check minimum ISA compatibility and runtime fallback,
including AVX2 hardware without OSXSAVE support.
The **Release binaries** workflow gives every Linux, Windows and macOS artifact
its own job. Tag pushes build only universal targets; manual dispatch can also
select individual SIMD targets, a platform, or all variants and publish them to
an existing tag. Intel and Apple Silicon Mac jobs
run natively on `macos-15-intel` and `macos-15`. AVX-512/VNNI correctness runs
require suitable hardware; release bench checks skip unsupported binaries.
Nim 2.2.6 is installed from its source archive on Linux ARM64 because that
release has no official Linux ARM64 binary archive.

For cross-compilation, keep using `make dev`/`make test-simd`: supply
`EXTRA_NFLAGS=--cpu:arm64`, `HOST_ARCH=aarch64-linux-gnu`, cross Clang target/sysroot
settings through `CFLAGS` and `LFLAGS`, and `SIMD=neon` or `SIMD=universal`.
`SIMD_TEST_RUNNER="qemu-aarch64 -L /path/to/sysroot"`
prefixes test execution. Cross-compilers need target libc, compiler runtime and,
for the full engine, zlib development files. The named `neon` target assumes a
native ARM compiler unless these overrides are supplied.

Correctness under emulation does not establish performance on physical Core 2,
older SSE2 CPUs or ARM hardware. Measure optimized binaries with the same
network and ISA flags using `scripts/compare_performance.py`; confirm any
inference microbenchmark gain with full search before making a speed claim.

References: [Clang SSE2 intrinsics](https://clang.llvm.org/doxygen/emmintrin_8h.html),
[Clang SSSE3 intrinsics](https://clang.llvm.org/doxygen/tmmintrin_8h.html),
[Arm NEON intrinsics](https://arm-software.github.io/acle/neon_intrinsics/advsimd.html),
[GitHub runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners),
[Nim release archives](https://nim-lang.org/install.html).

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
`src/heimdall/util/simd.nim`. Backend selection is compile-time; there is no
runtime dispatch or architecture-specific copy of the inference algorithm.

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

## Maintenance boundary

SSE2, SSSE3 and SSE4.1 share `simd_backends/x86_128.nim`, using the existing pinned
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

Existing inference changes written against `vec*` apply to every backend.
Adding a new primitive still requires a wrapper and a shared contract test;
compiler or runner upgrades can still need attention. This keeps maintenance
small but cannot guarantee literally zero maintenance.

## Integer and layout contract

- Loads/stores use a whole register. Callers retain the existing 64-byte
  accumulator alignment. `vecLoadI8AsI16` reads exactly one signed byte per int16
  lane, accepts unaligned input and sign extends without reading a full register.
- Integer adds, subtracts and low products wrap. Signed high multiplication,
  arithmetic versus logical shifts, and saturating int16-to-uint8 packing retain
  the x86 semantics. The NEON shift wrappers handle oversized counts explicitly.
- SSE2, SSSE3, SSE4.1 and NEON packing produces consecutive bytes and `vecPermute`
  is an identity. The existing weight loader's identity permutation already handles
  128-bit inference. Disk weights and network dimensions remain unchanged.
- The new backends match **non-VNNI** `vecDpbusd`/`vecDpbusdx2`: adjacent byte
  products saturate to int16, and x2 adds those pair sums with int16 wrapping
  before widening. Existing VNNI instead accumulates full products directly into
  int32. Tests preserve both contracts; arbitrary overflowing inputs are not
  assumed to agree across VNNI, non-VNNI and scalar inference.

## Verification and CI

Run `make test-simd SIMD=sse2`, `SIMD=ssse3`, `SIMD=sse41`, `SIMD=neon`, or another
backend. It generates synthetic weights under ignored `build/simd/` and runs:

- `test_simd`: every primitive, signed edges and randomized lanes, overflow,
  saturating dot products, packing, shifts, and unaligned byte widening.
- `test_multilayer`: both activation modes, both perspectives and all buckets
  against the independent canonical-layout oracle; exact export and reload.
- `test_nnue`: all-lane incremental/fresh comparisons, pending updates, cloning,
  the ply boundary and all Chess960 castling arrangements.
- `test_threat_diff` at width 768 and `test_threat_updates`.

The GitHub SIMD workflow runs the same target for scalar, SSE2, SSSE3, SSE4.1 and
AVX2 on Linux x86-64 and NEON on native `ubuntu-24.04-arm`, then builds the engine
and runs Python/UCI regressions. It also runs the x86 primitive tests under QEMU's
Opteron G1, Conroe and Penryn CPU models to check minimum ISA compatibility.
Linux release CI builds separate amd64 and arm64 artifacts. Existing Windows
release targets use the same feature-set artifact names as Linux through the
Makefile. AVX-512/VNNI correctness runs require
suitable hardware; their release builds keep the existing host capability checks.
Nim 2.2.6 is installed from its source archive on Linux ARM64 because that
release has no official Linux ARM64 binary archive.

For cross-compilation, keep using `make dev`/`make test-simd`: supply
`EXTRA_NFLAGS=--cpu:arm64`, cross Clang target/sysroot settings through `CFLAGS`
and `LFLAGS`, and `SIMD=neon`. `SIMD_TEST_RUNNER="qemu-aarch64 -L /path/to/sysroot"`
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

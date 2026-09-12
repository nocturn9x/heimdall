# Building and installation

The latest stable release is the easiest way to install Heimdall. See the
[download table in the README](../README.md#how-to-pick-the-right-executable)
for the universal archive that matches your system.

## Requirements

- Nim 2.2.6, pinned in `heimdall.nimble`
- Clang and the platform linker (LLD on Linux/Windows, Apple `ld` on macOS)
- Git LFS when fetching network weights

The Makefile is the only supported build interface. Do not use bare `make` or
`nimble build`; bare `make` is reserved for OpenBench.

## Build from source

With dependencies and weights already installed, use `make dev`. It selects a
backend for the host CPU and writes `bin/heimdall`. A fresh setup can use
`make native`, which installs dependencies, initializes the network submodule,
and fetches the selected weights.

For an explicit local build with an existing network:

```sh
make dev SIMD=avx2 EVALFILE=/absolute/path/to/net.bin
```

Use `make dev SIMD=universal EVALFILE=/absolute/path/to/net.bin` for runtime
backend selection. Run `bin/heimdall simd` to see the selected backend, or set
`HEIMDALL_SIMD=avx2` to force one. On macOS,
`make macos-universal SKIP_DEPS=1 EVALFILE=/absolute/path/to/net.bin` combines
Intel and Apple Silicon slices.

Portable targets use generic CPU tuning. For example, `make avx2 TUNE=znver2`
uses `-march=x86-64-v3 -mtune=znver2` while retaining the AVX2 requirement.
The old `legacy`, `modern`, `zen2`, and `vnni` target names are gone. Intel and
Apple Silicon Macs can use `make macos-amd64` and `make macos-arm64`
respectively. The resulting executable is in `bin/$(EXE)`.

See [SIMD.md](SIMD.md) for backend targets, scalar builds, universal dispatch,
cross-compilation, and architecture-specific constraints. See
[RELEASES.md](RELEASES.md) for release artifacts and workflow details.

## Legacy releases

For releases 1.3 through 1.5.0, the historical targets from fastest to slowest
were `vnni`, `avx512`, `zen2`, `haswell`, and `core2`. All require a 64-bit
processor. Releases after 1.5 use the universal binaries described in the
[README](../README.md#how-to-pick-the-right-executable).

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

# Android UCI engine

Heimdall can be cross-compiled into a standalone Android executable for
`arm64-v8a` (64-bit phones/tablets) or `x86_64` (64-bit emulators/devices).
The default minimum Android version is 5.0, API 21. These are UCI subprocess
executables with embedded NNUE weights, rather than APKs or JNI libraries.
An Android chess app must support importing/running external UCI engines.
App-specific installation and packaging depend on that app.

## Build

Install Nim 2.2.2 or newer, the project's Nimble dependencies, GNU Make and an
[Android NDK](https://developer.android.com/ndk/downloads). NDK r28 or newer is
recommended; r28c is used in CI. Linux and macOS hosts are supported. Windows
hosts need a POSIX shell and GNU Make, such as MSYS2, with the Windows NDK; WSL
uses the Linux NDK. The NDK supplies Clang, LLD and Android's libc/sysroot.

With dependencies and a compatible trained multilayer TI network available:

```sh
export ANDROID_NDK_HOME=/absolute/path/to/android-ndk
make dev TARGET=android EVALFILE=/absolute/path/to/net.bin
```

This writes `bin/heimdall-android-arm64-v8a`. `make android` is a convenience
alias for the same build. Both targets use installed dependencies and weights;
neither installs the NDK nor fetches packages or network weights. See the
[building guide](BUILDING.md) for dependency setup and network architecture
settings. Android uses the same Makefile NNUE settings as other platforms.

For an emulator build:

```sh
make dev TARGET=android ANDROID_ABI=x86_64 EVALFILE=/absolute/path/to/net.bin
```

This writes `bin/heimdall-android-x86_64`. The supported overrides are:

| Variable | Default | Purpose |
| --- | --- | --- |
| `ANDROID_NDK_HOME` | `ANDROID_NDK_ROOT` | Installed NDK directory, not the SDK directory |
| `ANDROID_ABI` | `arm64-v8a` | `arm64-v8a` or `x86_64`; 32-bit ABIs are unsupported |
| `ANDROID_API` | `21` | Minimum API level, at least 21 and supported by the NDK |
| `ANDROID_HOST_TAG` | Detected from build host | NDK prebuilt directory: `linux-x86_64`, `darwin-x86_64` or `windows-x86_64` |
| `EXE_BASE` | `bin/heimdall-android-<ABI>` | Output path, with no `.exe` extension |
| `SIMD` | `auto` | ABI baseline: NEON on ARM64, SSE2 on x86-64 |

`SIMD=scalar` and `SIMD=universal` also work for both ABIs. Explicit x86
backends require matching device CPU features. Android `auto` never selects
the build host's instruction set. CPU tuning retains the selected ABI baseline.
Build caches are separated by ABI, API level and SIMD selection under ignored
`build/android/`. Host-driven `PGO=1` is rejected because the Android executable
cannot run as a native host training process.

The build uses NDK Clang with an explicit Android target, dynamically links
Android system libraries and produces a position-independent executable.
LOAD and RELRO segments are aligned for both 4 KiB and 16 KiB page devices,
following [Android's page-size guidance](https://developer.android.com/guide/practices/page-sizes).
Aligned allocation uses `posix_memalign`, which is available at the API 21
baseline. Huge-page probing and desktop NUMA placement are disabled, leaving
thread placement to Android's scheduler. Search threads, UCI options, Chess960,
network loading and command-line benchmarks remain available.

Android sessions always use plain UCI input/output, with no line editor,
interactive prompt or logo. The built-in terminal UI is disabled. No terminal
UI libraries or external zlib library are required at runtime.

## Run and verify

For development with a matching connected device or emulator:

```sh
adb push bin/heimdall-android-arm64-v8a /data/local/tmp/heimdall
adb shell chmod 755 /data/local/tmp/heimdall
printf 'uci\nisready\nposition startpos\ngo depth 4\nwait\nquit\n' |
    adb shell -T /data/local/tmp/heimdall
```

Use the x86-64 executable for an x86-64 emulator. `/data/local/tmp` is for adb
development; a chess app needs its own supported engine installation mechanism
and an executable location permitted by Android. Copying an executable to shared
storage alone does not install it in an app.

Build configuration tests run without an NDK or device:

```sh
python -m unittest discover -s tests -p test_android.py
```

To include device UCI, perft and search-worker tests after pushing the binary:

```sh
HEIMDALL_ANDROID=/data/local/tmp/heimdall \
    python -m unittest discover -s tests -p test_android.py
```

Set `ANDROID_SERIAL` when multiple devices are attached. Set
`HEIMDALL_ANDROID_REFERENCE=/absolute/path/to/native/heimdall` to also compare
fixed-depth scores, nodes, principal variations and best moves. The reference
must use identical weights and architecture settings, with a non-VNNI backend
such as `SIMD=sse2`.

Standalone Nim correctness tests also use `make dev TARGET=android`, with
`MAIN`, `EXE_BASE`, `IS_TEST=1` and an absolute `EVALFILE`. Generate synthetic
weights with `tests/make_multilayer_fixture.py`; its oracle tests require
`EVAL_SCALE=400`. Push the resulting test executables to `/data/local/tmp`.
For `test_multilayer`, also push the fixture and set
`TMPDIR=/data/local/tmp HEIMDALL_TEST_NET=/data/local/tmp/multilayer-ti.bin`
when running it. Synthetic test networks must not be distributed as engine
release weights.

The **Android correctness** workflow builds both ABIs, checks ELF format and
page alignment, and runs allocation, SIMD, multilayer NNUE, incremental state
and UCI tests on an Android x86-64 emulator. The release job also runs the common
UCI regressions through an adb wrapper with `HEIMDALL_REMOTE=1`, which skips
host-only CPU affinity checks. ARM64 builds receive compilation
checks; physical ARM64 device and chess-app integration checks remain useful
before distributing a release. The separate **Release binaries** workflow
includes both Android universal downloads in automatic tag releases and its
default selection, using embedded production weights. It also accepts
`target=android` or either complete Android target name. See
[Android release builds](RELEASES.md#android-targets) for packaging and checks.

The ARM64 NEON build has also passed UCI, perft, search-worker, allocation, SIMD,
multilayer inference and incremental NNUE tests on a Xiaomi Mi 11i running
Android 14. Fixed-depth search results and the depth-9 benchmark node count
matched a native SSE2 build using the same production network.

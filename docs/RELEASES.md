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

# Release builds

The [README](../README.md#how-to-pick-the-right-executable) explains which
universal executable to download; [SIMD documentation](SIMD.md) covers individual
backend names for manual builds and older releases.
The **Release binaries** GitHub workflow automatically publishes only universal
downloads: combined Linux AMD64/ARM64, standalone Linux AMD64 and ARM64 fallbacks,
Windows amd64, and combined macOS. Targets can be selected independently.
Individual SIMD artifacts are available through manual runs. The SIMD correctness
workflow remains manual-only.

## Linux universal executable

`heimdall-<version>-linux-universal` is one executable file for AMD64 and ARM64.
It contains a `/bin/sh` launcher, two compressed native engines built with
`SIMD=universal EMBED_NET=0`, and **one compressed copy of the network weights**.
The AMD64 engine retains runtime x86 SIMD selection; ARM64 selects scalar or NEON.
Linux ELF files specify one machine architecture, so the shell launcher chooses
and extracts the native engine before executing it. This does not use emulation.

Download the executable directly, or extract it from the `.tar.gz` archive.
A direct download may need execute permission before it can run:

```sh
chmod +x heimdall-VERSION-linux-universal
```

Replace `VERSION` with the downloaded filename's version, then select the
executable in your chess GUI. The executable can be moved or symlinked by itself.
It requires `/bin/sh`, `gzip` and GNU coreutils (`uname`, `readlink`, `dd`, `sha256sum`, `stat`, `id`,
`mkdir`, `mktemp`, `chmod`, `mv`, `rm`). The engines retain their normal Linux
library requirements. A GUI must accept executable scripts.

If the combined executable fails to start or does not work in your chess GUI,
download `linux-amd64-universal.tar.gz` for Intel/AMD x86-64 or
`linux-arm64-universal.tar.gz` for ARM64/AArch64 from the same release, or download
the matching executable directly. Extract the archive or set execute permission
on the direct download, then select its native executable in the GUI. These
fallbacks embed their weights, require no launcher or runtime cache, and are included in
automatic releases. They can also be selected individually in the workflow.

On first launch, the executable extracts only the selected engine and shared
`network.bin` into a private cache. The cache location is:

1. `$HEIMDALL_CACHE_DIR`, if set;
2. `$XDG_CACHE_HOME/heimdall`, if set;
3. `$HOME/.cache/heimdall` otherwise.

The cache path must be absolute, writable, owned by the current user and have
mode `700`. The cache directory itself and each entry must not be symlinks.
Its filesystem must permit execution: if the default cache is on a `noexec`
mount, set `HEIMDALL_CACHE_DIR` to a private directory on an executable filesystem.
Each content/launcher version and CPU family gets a separate entry. Extracted
engine/network files have modes `500`/`400`. Both are SHA-256 checked before
**every** launch; missing or corrupt files are extracted again. Temporary files
are private and installed atomically, allowing simultaneous starts and repair
while an older process is running. Interrupted extraction is cleaned up on normal
exit and catchable termination signals. Old entries are not removed automatically;
you can delete the cache when no Heimdall process is using it. The next launch
recreates it. As with any process, SIGKILL or a power failure can leave temporary
files, which can also be deleted then.

First launch adds decompression and disk writes; subsequent launches still read
and hash the cached engine and weights. The launcher emits errors on stderr and
keeps stdout clear for UCI. It uses `exec`, preserving arguments, environment
(including `HEIMDALL_SIMD`), UCI pipes, working directory, PID, signals and exit
status. The engine's default network loads from `network.bin` beside its cached
executable; `EvalFile` overrides and resetting to `<default>` continue to work.
Ordinary builds still embed their weights (`EMBED_NET=1`, the default).

CI builds and bench-checks internal slices on `ubuntu-24.04` and
`ubuntu-24.04-arm` from the same source SHA. Each slice archive records that SHA,
architecture settings, and engine/network hashes. Assembly rejects mismatched
sources, settings, weights, ELF architectures or checksums. It writes one shared
weights payload, then both native runners check the resulting executable with
the production bench and UCI/runtime-SIMD regressions. Publication waits for both
checks. Internal slice archives remain available in Actions but are never
published to Gitea. Standalone fallbacks are built separately with embedded
weights and published by the native build jobs.

Automatic tag releases and the default `universal` selection publish all three
Linux executables: `linux-universal`, `linux-amd64-universal` and
`linux-arm64-universal`. The two standalone fallbacks embed their weights and
need no launcher or runtime cache. Selecting `linux` or `all` also publishes
individual SIMD variants. An explicit `linux-universal` selection builds only
the combined executable; either standalone fallback can be rebuilt separately
with its complete target name and the same `release_tag`. The internal
`*-universal-slice.tar.gz` Actions artifacts are assembly inputs, not standalone
fallback downloads.

To assemble locally, build each internal slice on its matching Linux host from
the same commit, network and Makefile settings:

```sh
# On AMD64:
python scripts/release.py slice-linux --target linux-amd64-universal --skip-deps --artifacts build/slices
# On ARM64:
python scripts/release.py slice-linux --target linux-arm64-universal --skip-deps --artifacts build/slices
# Collect both *-universal-slice.tar.gz archives in build/slices, then on Linux:
python scripts/release.py combine-linux --slices build/slices --artifacts build/release
```

Supply the same `--tag` to all three commands for a tagged release. Compilation
still goes through the source checkout's Makefile; assembly compiles nothing.
Pass custom network/architecture settings through Make's environment, for example
`MAKEFLAGS='EVALFILE=/absolute/path/to/net.bin'`. The source Makefile must support
`EMBED_NET=0`; older tags without it cannot produce this combined artifact.
No cross-compiler is needed. Test the resulting executable on both CPU families.

The release publishes the executable, its `<executable>.sha256`, and a `.tar.gz`
archive containing both. For direct downloads, download the checksum file as well
and run `sha256sum -c <executable>.sha256` in their directory. The same check works
after extracting the archive. Setting execute permission does not change the
file's checksum.
The self-extracting file is deterministic for identical inputs and packaging
Python/zlib versions; the outer download archive retains normal release metadata.

## macOS targets

| Native Make target | Required build host | Release target | Backend |
| --- | --- | --- | --- |
| `macos-amd64` | Intel Mac | `macos-amd64-sse2` | SSE2 |
| `macos-arm64` | Apple Silicon Mac | `macos-arm64-neon` | NEON |
| `macos-universal` | Either Mac CPU family | `macos-universal` | Runtime x86 SIMD + ARM NEON |

With Nim 2.2.6, Apple Clang, and the dependencies and network already installed:

```sh
make macos-amd64 SKIP_DEPS=1 EVALFILE=/absolute/path/to/net.bin
# On Apple Silicon:
make macos-arm64 SKIP_DEPS=1 EVALFILE=/absolute/path/to/net.bin
```

The combined Mac target cross-compiles both slices with Apple Clang and joins
them using `lipo`; it embeds the weights once per slice. It uses separate build
caches and disables PGO because both architectures need to build on either host.

These targets use the same network architecture and quantization settings as
every other Makefile build and write `bin/heimdall` by default. The single-slice
targets require the matching native host; the combined target supports either
Mac CPU family. `MACOSX_DEPLOYMENT_TARGET=11.0` is the default minimum OS target; it can
be overridden for a local build. The linker remains Apple ld with an 8 MiB stack.
macOS builds use system libraries and do not request static linking.

CI uses native `macos-15-intel` and `macos-15` runners and the official Nim 2.2.6
macOS binaries. It runs the production bench on each resulting executable.
The deployment target does not mean every older macOS release is tested.
No Apple signing identity or notarization step is configured.

## Add one artifact to an existing release

In GitHub **Actions → Release binaries → Run workflow**:

1. Choose **master** in **Use workflow from**, to use the current CI tooling.
2. Set `target` to one complete target name, such as `macos-arm64-neon`.
3. Set `release_tag` to the existing tag, such as `1.5.1-dev`.
4. Leave `source_ref` empty to build the exact commit referenced by that tag.

Only the selected target is compiled, bench-checked, packaged and uploaded
(`linux-universal` builds and checks both Linux slices).
The existing tag is not moved. A rerun replaces only files belonging to that
target; other release assets and older aggregate archives remain intact.

Tag pushes always select `universal`, including both standalone Linux fallbacks.
Manual runs and the local planning command also default to `universal`;
choose `all` explicitly to build every individual
SIMD variant as well. Manual `linux`, `windows`, and `macos` selections include
all variants for that platform, including the combined package (`macos` selects
all three Mac builds). A complete target name builds just that artifact. No push
to a branch or pull request starts the release workflow.

Current selectable targets:

- `linux-amd64-sse2`, `linux-amd64-ssse3`, `linux-amd64-sse41`,
  `linux-amd64-avx2`, `linux-amd64-avx512`, `linux-amd64-avx512-vnni`.
- `linux-amd64-universal`, `linux-arm64-neon`, `linux-arm64-universal`, `linux-universal`.
- `windows-amd64-sse2`, `windows-amd64-ssse3`, `windows-amd64-sse41`,
  `windows-amd64-avx2`, `windows-amd64-avx512`, `windows-amd64-avx512-vnni`.
- `windows-amd64-universal`.
- `macos-amd64-sse2`, `macos-arm64-neon`, `macos-universal`.

The catalog lives in `scripts/release.py`; Makefile owns compiler flags, network
settings and filename versioning. Native targets become independent matrix jobs,
including their uploads. `linux-universal` expands into two native slice builds
followed by assembly, checks on both architectures, and publication. Publication
jobs for the same release tag and target are serialized to prevent simultaneous
replacements of the same assets.

## Source selection and publishing

`source_ref` accepts a branch, tag or commit SHA. With no `release_tag`, a manual
run uploads only GitHub Actions artifacts. With a `release_tag`, the source must
resolve to the same commit as that tag; mismatches fail before starting builds.
This keeps the source of a newly added binary consistent with the release.

The current workflow and packaging helpers are checked out separately from the
engine source. This allows current CI tooling to build an older tag without
changing its files. The tagged Makefile must already support the selected SIMD
backend. The 1.5.1-dev source contains both SSE2 and NEON, so its Mac builds can be
added without recreating the tag.

Publishing uses the existing `GITEA_BASE_URL`, `GITEA_REPO` and `GITEA_TOKEN`
secrets. If the tag has no release record yet, the existing publisher creates one;
stable versions start as drafts, while alpha/beta/rc/dev releases are prereleases.
Each target owns three uniquely named files: its executable, an executable-name
`.sha256` file, and a `.tar.gz` archive (`.zip` on Windows) containing both.
Users can download the executable directly instead of the archive. On Linux and
macOS they may need `chmod +x /path/to/downloaded/executable`; on Windows they
download the `.exe` file directly. All formats contain the same executable.
Checksums are per executable so one target cannot overwrite another target's manifest.

For a local check using existing dependencies and weights:

```sh
python scripts/release.py plan --target macos --tag 1.5.1-dev
python scripts/release.py build --target linux-amd64-sse2 --skip-deps --artifacts build/release
```

The build command runs from the source checkout on a matching host, uses its
Makefile, and checks the resulting binary against that commit's recorded bench.
It does not publish anything. The default output directory is `artifacts`; the
example keeps local artifacts under ignored `build/` instead.
Use `plan --target linux-universal` to select the combined CI package, and
`combine-linux` to assemble it locally after building both slices.
The helper requires GNU Make with `--eval` support. macOS CI installs Homebrew's
Make and places its `libexec/gnubin` directory on `PATH` ahead of Apple's Make.

Runner labels are documented in the [GitHub runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).
Compiler archives are linked from [Nim's previous releases](https://nim-lang.org/install.html).

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

Release filenames retain the feature-set scheme documented in the
[README](../README.md#how-to-pick-the-right-executable), for versions after 1.5.0.
The **Release binaries** GitHub workflow builds one artifact per job, so a failed
or newly added target can be built independently. The SIMD correctness workflow
remains manual-only.

## macOS targets

| Native Make target | Required build host | Release target | Backend |
| --- | --- | --- | --- |
| `macos-amd64` | Intel Mac | `macos-amd64-sse2` | SSE2 |
| `macos-arm64` | Apple Silicon Mac | `macos-arm64-neon` | NEON |

With Nim 2.2.6, Apple Clang, and the dependencies and network already installed:

```sh
make macos-amd64 SKIP_DEPS=1 EVALFILE=/absolute/path/to/net.bin
# On Apple Silicon:
make macos-arm64 SKIP_DEPS=1 EVALFILE=/absolute/path/to/net.bin
```

These targets use the same architecture and quantization settings as every other
Makefile build. They require the matching native host and write `bin/heimdall` by
default. `MACOSX_DEPLOYMENT_TARGET=11.0` is the default minimum OS target; it can
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

Only the selected target is compiled, bench-checked, packaged and uploaded.
The existing tag is not moved. A rerun replaces only files belonging to that
target; other release assets and older aggregate archives remain intact.

Use `target=macos` to add both Mac builds. `linux`, `windows`, and `all` select
those groups. A tag push selects `all` automatically. No push to a branch or
pull request starts the release workflow.

Current selectable targets:

- `linux-amd64-sse2`, `linux-amd64-ssse3`, `linux-amd64-sse41`,
  `linux-amd64-avx2`, `linux-amd64-avx512`, `linux-amd64-avx512-vnni`.
- `linux-arm64-neon`.
- `windows-amd64-sse2`, `windows-amd64-ssse3`, `windows-amd64-sse41`,
  `windows-amd64-avx2`, `windows-amd64-avx512`, `windows-amd64-avx512-vnni`.
- `macos-amd64-sse2`, `macos-arm64-neon`.

The catalog lives in `scripts/release.py`; Makefile owns compiler flags, network
settings and filename versioning. Each selected target becomes an independent
matrix job, including its upload. Jobs for the same release tag and target are
serialized to prevent simultaneous replacements of the same assets.

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
Every target owns three uniquely named files: its executable, an executable-name
`.sha256` file, and a `.tar.gz` archive (`.zip` on Windows) containing both.
Checksums are per binary so one target cannot overwrite another target's manifest.

For a local check using existing dependencies and weights:

```sh
python scripts/release.py plan --target macos --tag 1.5.1-dev
python scripts/release.py build --target linux-amd64-sse2 --skip-deps --artifacts build/release
```

The build command runs from the source checkout on a matching host, uses its
Makefile, and checks the resulting binary against that commit's recorded bench.
It does not publish anything. The default output directory is `artifacts`; the
example keeps local artifacts under ignored `build/` instead.
The helper requires GNU Make with `--eval` support. macOS CI installs Homebrew's
Make and places its `libexec/gnubin` directory on `PATH` ahead of Apple's Make.

Runner labels are documented in the [GitHub runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).
Compiler archives are linked from [Nim's previous releases](https://nim-lang.org/install.html).

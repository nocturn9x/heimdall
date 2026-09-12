#!/usr/bin/env python3
# Copyright 2026 Mattia Giambirtone & All Contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Authored with assistance from AI agents.

"""Plan independent release jobs and build/package one Makefile backend."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import zipfile


X86_BACKENDS = ("sse2", "ssse3", "sse41", "avx2", "avx512", "avx512-vnni", "universal")
# This catalog owns CI target selection; compiler and network settings stay in Makefile.
PLATFORMS = (
    ("linux", "amd64", "ubuntu-24.04", X86_BACKENDS),
    ("linux", "arm64", "ubuntu-24.04-arm", ("neon", "universal")),
    ("windows", "amd64", "windows-latest", X86_BACKENDS),
    ("macos", "amd64", "macos-15-intel", ("sse2",)),
    ("macos", "arm64", "macos-15", ("neon",)),
)
TARGETS = {
    f"{system}-{arch}-{backend}": dict(target=f"{system}-{arch}-{backend}",
                                     os=system, arch=arch, runner=runner, backend=backend)
    for system, arch, runner, backends in PLATFORMS
    for backend in backends
}
TARGETS["macos-universal"] = dict(target="macos-universal", os="macos", arch="universal",
                                  runner="macos-15", backend="universal", make_target="macos-universal")


def matrix(selection):
    targets = [value for key, value in TARGETS.items()
               if selection in ("all", value["os"], key) or
               (selection == "universal" and value["backend"] == "universal")]
    if not targets:
        raise ValueError(f"Unknown release target {selection!r}; choose all, universal, linux, windows, macos, or "
                         + ", ".join(TARGETS))
    return {"include": targets}


def git(*args):
    return subprocess.check_output(["git", *args], text=True).strip()


def source_commit(ref):
    return git("rev-parse", "--verify", "--end-of-options", ref + "^{commit}")


def release_source(ref, tag, workflow_ref):
    """Published additions use the tagged source with the current workflow tooling."""
    if tag:
        subprocess.run(["git", "check-ref-format", "refs/tags/" + tag], check=True)
        tagged = source_commit("refs/tags/" + tag)
        source = source_commit(ref) if ref else tagged
        if source != tagged:
            raise ValueError("The source ref must match the release tag when publishing")
        return source
    return source_commit(ref or workflow_ref)


def outputs(values):
    if path := os.environ.get("GITHUB_OUTPUT"):
        with open(path, "a", encoding="utf-8") as stream:
            for key, value in values.items():
                print(f"{key}={value}", file=stream)


def plan(args):
    tag_push = (os.environ.get("GITHUB_EVENT_NAME") == "push"
                and os.environ.get("GITHUB_REF_TYPE") == "tag")
    # Automatic releases contain only universal binaries; expanded selections
    # remain available through manual workflow runs and the local CLI.
    selected = matrix("universal" if tag_push else args.target)
    tag = args.tag
    if not tag and tag_push:
        tag = os.environ["GITHUB_REF_NAME"]
    version_flags(tag)
    source = release_source(args.ref, tag, os.environ.get("GITHUB_REF", "HEAD"))
    values = dict(matrix=json.dumps(selected, separators=(",", ":")), source_sha=source, tag=tag)
    outputs(values)
    print(json.dumps(values, indent=2))


def version_flags(tag):
    match = re.fullmatch(r"v?(\d+)\.(\d+)\.(\d+)", tag)
    if match:
        return ["IS_RELEASE=1", *[f"{part}_VERSION={n}" for part, n in
                zip(("MAJOR", "MINOR", "PATCH"), match.groups())]]
    # Untagged builds and alpha/beta/rc/dev tags use the Makefile prerelease naming.
    if tag and not any(marker in tag.lower() for marker in ("alpha", "beta", "rc", "dev")):
        raise ValueError("Use a semantic version or an alpha/beta/rc/dev tag")
    return ["IS_RELEASE=0"]


def make_config(flags):
    # Query the source revision's Makefile, including older tags that predate this
    # helper. GNU Make --eval adds only a print target; no build flags are duplicated.
    rule = ("heimdall-release-config: ; @echo $(OS_TAG) $(ARCH_TAG) $(RELEASE_BASE) "
            "$(PRERELEASE_BASE) x$(EXE_EXT)")
    result = subprocess.check_output(
        ["make", "--no-print-directory", "-s", "--eval=" + rule, "heimdall-release-config", *flags],
        text=True,
    ).strip().split()
    if len(result) != 5:
        raise ValueError(f"Unexpected Makefile release configuration: {result!r}")
    return result


def package(binary, directory):
    """Each target owns its binary, checksum and archive, so uploads cannot collide."""
    directory.mkdir(parents=True, exist_ok=True)
    copied = directory / binary.name
    shutil.copy2(binary, copied)
    checksum = directory / (binary.name + ".sha256")
    checksum.write_bytes((hashlib.sha256(copied.read_bytes()).hexdigest() + "  " + binary.name + "\n").encode("utf-8"))
    if binary.suffix == ".exe":
        archive = directory / (binary.stem + ".zip")
        with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as bundle:
            for item in (copied, checksum):
                bundle.write(item, item.name)
    else:
        archive = directory / (binary.name + ".tar.gz")
        with tarfile.open(archive, "w:gz") as bundle:
            for item in (copied, checksum):
                bundle.add(item, arcname=item.name)
    return [copied, checksum, archive]


def build(args):
    target = TARGETS[args.target]
    flags = version_flags(args.tag)
    system, arch, release, prerelease, extension = make_config(flags)
    if system != target["os"] or (target["arch"] != "universal" and arch != target["arch"]):
        raise ValueError(f"{args.target} requires a {target['os']}/{target['arch']} build host; "
                         f"Makefile reports {system}/{arch}")
    source = source_commit("HEAD")
    if args.tag:
        release_source(source, args.tag, "HEAD")
    base = release if "IS_RELEASE=1" in flags else prerelease
    if target["arch"] == "universal":
        base = base.removesuffix("-" + arch)
    binary_base = Path("bin") / (base + "-" + target["backend"])
    binary = Path(str(binary_base) + extension.removeprefix("x"))
    command = ["make", target.get("make_target", target["backend"]), "NIMBLE_FLAGS=-y", *flags, f"EXE_BASE={binary_base}"]
    if args.skip_deps:
        command.append("SKIP_DEPS=1")
    print("Building " + args.target, flush=True)
    subprocess.run(command, check=True)
    # Use the current bench checker for current artifact names, with the source
    # tag's recorded bench. The tagged Makefile still owns compiler/network flags.
    subprocess.run([sys.executable, str(Path(__file__).with_name("check_binary_benches.py")),
                    "--commit", source, "--", str(binary)], check=True)
    files = package(binary, args.artifacts)
    outputs(dict(artifact_name=binary_base.name))
    print("Packaged: " + ", ".join(map(str, files)), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    planning = commands.add_parser("plan", help="Select jobs and resolve the source revision")
    planning.add_argument("--target", default="universal")
    planning.add_argument("--ref", default="")
    planning.add_argument("--tag", default="")
    building = commands.add_parser("build", help="Build and check one target from the current directory")
    building.add_argument("--target", required=True, choices=TARGETS)
    building.add_argument("--tag", default="")
    building.add_argument("--artifacts", type=Path, default=Path("artifacts"))
    building.add_argument("--skip-deps", action="store_true", help="Use locally installed dependencies and weights")
    args = parser.parse_args()
    try:
        (plan if args.command == "plan" else build)(args)
    except (ValueError, subprocess.CalledProcessError) as exc:
        parser.exit(1, str(exc) + "\n")


if __name__ == "__main__":
    main()

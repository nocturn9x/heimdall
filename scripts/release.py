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
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import shlex
import subprocess
import sys
import tarfile
import tempfile
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
LINUX_SLICES = ("linux-amd64-universal", "linux-arm64-universal")
TARGETS["linux-universal"] = dict(target="linux-universal", os="linux", arch="universal",
                                  backend="universal")


def includes_linux_bundle(selection):
    return selection in ("all", "universal", "linux", "linux-universal")


def matrix(selection):
    targets = [value for key, value in TARGETS.items()
               if selection in ("all", value["os"], key) or
               (selection == "universal" and value["backend"] == "universal")]
    if not targets:
        raise ValueError(f"Unknown release target {selection!r}; choose all, universal, linux, windows, macos, or "
                         + ", ".join(TARGETS))
    # Default universal releases also publish standalone Linux fallbacks. An
    # explicit linux-universal selection builds only the internal bundle slices.
    jobs = {target["target"]: dict(target, publish=True) for target in targets
            if target["target"] != "linux-universal"}
    if includes_linux_bundle(selection):
        for name in LINUX_SLICES:
            jobs.setdefault(name, dict(TARGETS[name], publish=False))
    return {"include": list(jobs.values())}


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
    selection = "universal" if tag_push else args.target
    selected = matrix(selection)
    tag = args.tag
    if not tag and tag_push:
        tag = os.environ["GITHUB_REF_NAME"]
    version_flags(tag)
    source = release_source(args.ref, tag, os.environ.get("GITHUB_REF", "HEAD"))
    values = dict(matrix=json.dumps(selected, separators=(",", ":")), source_sha=source, tag=tag,
                  linux_universal=str(includes_linux_bundle(selection)).lower())
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


def validate_elf(data, machine):
    if (len(data) < 64 or data[:7] != b"\x7fELF\x02\x01\x01"
            or int.from_bytes(data[16:18], "little") not in (2, 3)
            or int.from_bytes(data[18:20], "little") != machine):
        raise ValueError(f"Expected a little-endian ELF64 executable for machine {machine}")


def linux_executable(amd64, arm64, network, output):
    """Write a shell header, two compressed engines and one shared network."""
    for data, machine in ((amd64, 62), (arm64, 183)):
        validate_elf(data, machine)
    payloads = dict(AMD64=amd64, ARM64=arm64, NETWORK=network)
    template = Path(__file__).with_name("linux-universal.sh").read_text(encoding="utf-8")
    values = {key + "_HASH": hashlib.sha256(data).hexdigest() for key, data in payloads.items()}
    values["BUNDLE_ID"] = hashlib.sha256((template + json.dumps(values, sort_keys=True)).encode()).hexdigest()
    compressed = {key: gzip.compress(data, mtime=0) for key, data in payloads.items()}
    for key, data in compressed.items():
        values[key + "_SIZE"] = str(len(data))
        values[key + "_OFFSET"] = "0"
    # Offsets are decimal and their own lengths contribute to the header size.
    while True:
        header = re.sub(r"@([A-Z0-9_]+)@", lambda match: values[match[1]], template).encode("utf-8")
        offset = len(header)
        previous = dict(values)
        for key, data in compressed.items():
            values[key + "_OFFSET"] = str(offset)
            offset += len(data)
        if previous == values:
            break
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("wb") as stream:
        stream.write(header)
        for data in compressed.values():
            stream.write(data)
    output.chmod(0o755)


def slice_linux(args):
    """Build an engine without embedded weights and record its matching network."""
    target = TARGETS[args.target]
    flags = version_flags(args.tag)
    system, arch, stable, development, _ = make_config(flags)
    if system != "linux" or arch != target["arch"]:
        raise ValueError(f"{args.target} requires its matching native Linux host")
    source = source_commit("HEAD")
    if args.tag:
        release_source(source, args.tag, "HEAD")
    flags.append("EMBED_NET=0")
    # The tagged Makefile owns settings. Older sources must already support
    # external default weights; merely passing an unknown Make variable is unsafe.
    rule = ("heimdall-slice-config:\n"
            "\t@echo $(EMBED_NET) $(filter -d:embedNet=%,$(CUSTOM_FLAGS))\n"
            "\t@echo $(EVALFILE)\n\t@echo $(MAIN)\n\t@echo $(CUSTOM_FLAGS)")
    config = subprocess.check_output(["make", "--no-print-directory", "-s", "--eval=" + rule,
                                      "heimdall-slice-config", *flags], text=True).splitlines()
    if len(config) != 4 or config[0].strip() != "0 -d:embedNet=false":
        raise ValueError("The source Makefile does not support EMBED_NET=0")
    network_path = (Path(config[2]).parent / config[1]).resolve()
    settings = [flag for flag in shlex.split(config[3]) if not flag.startswith("-d:evalFile=")]
    directory = Path("build/release-slices") / arch
    binary = directory / "heimdall"
    command = ["make", "universal", "NIMBLE_FLAGS=-y", *flags, f"EXE_BASE={binary}"]
    if args.skip_deps:
        command.append("SKIP_DEPS=1")
    subprocess.run(command, check=True)
    shutil.copyfile(network_path, directory / "network.bin")
    subprocess.run([sys.executable, str(Path(__file__).with_name("check_binary_benches.py")),
                    "--commit", source, "--", str(binary)], check=True)
    data = binary.read_bytes()
    network = (directory / "network.bin").read_bytes()
    validate_elf(data, 62 if arch == "amd64" else 183)
    metadata = dict(source=source, arch=arch, settings=settings,
                    engine_sha256=hashlib.sha256(data).hexdigest(),
                    network_sha256=hashlib.sha256(network).hexdigest())
    base = stable if "IS_RELEASE=1" in flags else development
    args.artifacts.mkdir(parents=True, exist_ok=True)
    archive = args.artifacts / (base + "-universal-slice.tar.gz")
    with tarfile.open(archive, "w:gz") as bundle:
        for name, contents in (("heimdall", data), ("network.bin", network),
                               ("metadata.json", json.dumps(metadata, sort_keys=True).encode())):
            info = tarfile.TarInfo(name)
            info.size = len(contents)
            info.mode = 0o755 if name == "heimdall" else 0o644
            bundle.addfile(info, io.BytesIO(contents))
    print("Packaged internal slice: " + str(archive), flush=True)


def read_linux_slice(path, arch, source):
    with tarfile.open(path) as archive:
        if sorted(archive.getnames()) != ["heimdall", "metadata.json", "network.bin"]:
            raise ValueError(f"Unexpected members in {path}")
        if any(not member.isfile() for member in archive.getmembers()):
            raise ValueError(f"Non-file member in {path}")
        metadata = json.load(archive.extractfile("metadata.json"))
        engine = archive.extractfile("heimdall").read()
        network = archive.extractfile("network.bin").read()
    if not isinstance(metadata, dict) or not isinstance(metadata.get("settings"), list):
        raise ValueError(f"Invalid slice metadata in {path}")
    if metadata.get("source") != source or metadata.get("arch") != arch:
        raise ValueError(f"Source/architecture mismatch in {path}")
    for key, data in (("engine", engine), ("network", network)):
        if metadata.get(key + "_sha256") != hashlib.sha256(data).hexdigest():
            raise ValueError(f"Checksum mismatch for {key} in {path}")
    validate_elf(engine, 62 if arch == "amd64" else 183)
    return engine, network, metadata


def combine_linux(args):
    flags = version_flags(args.tag)
    system, arch, stable, development, _ = make_config(flags)
    if system != "linux":
        raise ValueError("combine-linux requires a Linux source checkout")
    source = source_commit("HEAD")
    if args.tag:
        release_source(source, args.tag, "HEAD")
    base = (stable if "IS_RELEASE=1" in flags else development).removesuffix("-" + arch)
    slices = [read_linux_slice(args.slices / (base + "-" + cpu + "-universal-slice.tar.gz"), cpu, source)
              for cpu in ("amd64", "arm64")]
    if slices[0][1] != slices[1][1] or slices[0][2]["settings"] != slices[1][2]["settings"]:
        raise ValueError("Linux slices must use identical network weights and architecture settings")
    name = base + "-universal"
    with tempfile.TemporaryDirectory() as temp:
        binary = Path(temp) / name
        linux_executable(slices[0][0], slices[1][0], slices[0][1], binary)
        files = package(binary, args.artifacts)
    outputs(dict(artifact_name=name))
    print("Packaged: " + ", ".join(map(str, files)), flush=True)


def build(args):
    if args.target == "linux-universal":
        raise ValueError("Use slice-linux for linux-amd64-universal and linux-arm64-universal on their native hosts, "
                         "then use combine-linux --slices DIRECTORY")
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
    slicing = commands.add_parser("slice-linux", help="Build one internal Linux slice with external default weights")
    slicing.add_argument("--target", required=True, choices=LINUX_SLICES)
    slicing.add_argument("--tag", default="")
    slicing.add_argument("--artifacts", type=Path, default=Path("slices"))
    slicing.add_argument("--skip-deps", action="store_true")
    combining = commands.add_parser("combine-linux", help="Combine bench-checked Linux slice artifacts")
    combining.add_argument("--slices", type=Path, required=True, help="Directory containing both internal slice archives")
    combining.add_argument("--tag", default="")
    combining.add_argument("--artifacts", type=Path, default=Path("artifacts"))
    args = parser.parse_args()
    try:
        {"plan": plan, "build": build, "slice-linux": slice_linux, "combine-linux": combine_linux}[args.command](args)
    except (OSError, ValueError, tarfile.TarError, subprocess.CalledProcessError) as exc:
        parser.exit(1, str(exc) + "\n")


if __name__ == "__main__":
    main()

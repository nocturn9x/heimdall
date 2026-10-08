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

"""Check independent release selection, source identity and artifact ownership."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import struct
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import zipfile


def module(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).resolve().parents[1] / "scripts" / (name + ".py"))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


release = module("release")
publish = module("publish_gitea_release")


def android_elf(machine=183):
    data = bytearray(16385)
    data[:7] = b"\x7fELF\x02\x01\x01"
    struct.pack_into("<HH", data, 16, 3, machine)
    struct.pack_into("<Q", data, 32, 64)
    struct.pack_into("<HH", data, 54, 56, 4)
    interpreter = b"/system/bin/linker64\0"
    data[288:288 + len(interpreter)] = interpreter
    for index, header in enumerate((
        (1, 4, 0, 0, 0, 309, 309, 16384),
        (1, 5, 16384, 16384, 16384, 1, 16384, 16384),
        (3, 4, 288, 288, 288, len(interpreter), len(interpreter), 1),
        (0x6474E552, 4, 16384, 16384, 16384, 1, 16384, 1),
    )):
        struct.pack_into("<IIQQQQQQ", data, 64 + index * 56, *header)
    return bytes(data)


class ReleaseWorkflowTests(unittest.TestCase):
    def test_one_target_creates_only_one_build_job(self):
        jobs = release.matrix("macos-arm64-neon")["include"]
        self.assertEqual(len(jobs), 1)
        self.assertEqual((jobs[0]["os"], jobs[0]["arch"], jobs[0]["backend"]), ("macos", "arm64", "neon"))
        self.assertEqual(len(release.matrix("macos")["include"]), 3)
        self.assertEqual(len(release.matrix("all")["include"]), 21)
        with self.assertRaises(ValueError):
            release.matrix("macos-arm64-avx2")

    def test_universal_targets_cover_each_platform_and_both_mac_architectures(self):
        jobs = release.matrix("universal")["include"]
        self.assertEqual({job["target"] for job in jobs},
                         {"linux-amd64-universal", "linux-arm64-universal",
                          "windows-amd64-universal", "macos-universal",
                          "android-amd64-universal", "android-arm64-universal"})
        mac = release.matrix("macos-universal")["include"][0]
        self.assertEqual(mac["make_target"], "macos-universal")
        self.assertEqual(mac["arch"], "universal")
        self.assertEqual({job["target"] for job in jobs if job["publish"]},
                         {"linux-amd64-universal", "linux-arm64-universal",
                          "windows-amd64-universal", "macos-universal",
                          "android-amd64-universal", "android-arm64-universal"})

    def test_android_selection_creates_only_cross_build_jobs(self):
        jobs = release.matrix("android")["include"]
        self.assertEqual({job["target"] for job in jobs},
                         {"android-amd64-universal", "android-arm64-universal"})
        self.assertTrue(all(job["os"] == "android" and job["runner"] == "ubuntu-24.04"
                            and job["publish"] for job in jobs))

    def test_combined_linux_builds_both_slices_without_publishing_them(self):
        jobs = release.matrix("linux-universal")["include"]
        self.assertEqual({job["target"] for job in jobs}, set(release.LINUX_SLICES))
        self.assertTrue(all(not job["publish"] for job in jobs))
        self.assertTrue(release.includes_linux_bundle("universal"))
        for selection in ("linux", "all"):
            jobs = release.matrix(selection)["include"]
            self.assertEqual(len(jobs), len({job["target"] for job in jobs}))
            self.assertTrue(all(job["publish"] for job in jobs))
        for selection in release.LINUX_SLICES:
            self.assertFalse(release.includes_linux_bundle(selection))
            self.assertTrue(release.matrix(selection)["include"][0]["publish"])

    def test_published_additions_use_the_tagged_source(self):
        with patch.object(release, "source_commit", side_effect=lambda ref: {"refs/tags/1.5.1-dev": "tagged", "master": "newer"}[ref]), \
             patch.object(release.subprocess, "run"):
            self.assertEqual(release.release_source("", "1.5.1-dev", "master"), "tagged")
            with self.assertRaisesRegex(ValueError, "must match"):
                release.release_source("master", "1.5.1-dev", "master")
            self.assertEqual(release.release_source("master", "", "master"), "newer")

    def test_manual_run_from_a_tag_does_not_implicitly_publish(self):
        args = argparse.Namespace(target="all", ref="", tag="")
        with patch.dict(os.environ, {"GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_REF_TYPE": "tag",
                                     "GITHUB_REF_NAME": "1.5.1-dev", "GITHUB_REF": "refs/tags/1.5.1-dev"}), \
             patch.object(release, "release_source", return_value="sha"), \
             patch.object(release, "outputs") as outputs, patch("builtins.print"):
            release.plan(args)
        self.assertEqual(outputs.call_args.args[0]["tag"], "")
        self.assertEqual(json.loads(outputs.call_args.args[0]["matrix"]), release.matrix("all"))

    def test_tag_push_includes_combined_linux_and_standalone_fallbacks(self):
        args = argparse.Namespace(target="all", ref="", tag="")
        with patch.dict(os.environ, {"GITHUB_EVENT_NAME": "push", "GITHUB_REF_TYPE": "tag",
                                     "GITHUB_REF_NAME": "1.5.1-dev", "GITHUB_REF": "refs/tags/1.5.1-dev"}), \
             patch.object(release, "release_source", return_value="sha"), \
             patch.object(release, "outputs") as outputs, patch("builtins.print"):
            release.plan(args)
        self.assertEqual(outputs.call_args.args[0]["tag"], "1.5.1-dev")
        self.assertEqual(outputs.call_args.args[0]["linux_universal"], "true")
        self.assertEqual(json.loads(outputs.call_args.args[0]["matrix"]), release.matrix("universal"))
        jobs = json.loads(outputs.call_args.args[0]["matrix"])["include"]
        self.assertEqual({job["target"] for job in jobs if job["os"] == "linux" and job["publish"]},
                         {"linux-amd64-universal", "linux-arm64-universal"})

    def test_default_cli_plan_selects_only_universal_binaries(self):
        with patch("sys.argv", ["release.py", "plan"]), \
             patch.dict(os.environ, {"GITHUB_EVENT_NAME": "workflow_dispatch"}), \
             patch.object(release, "release_source", return_value="sha"), \
             patch.object(release, "outputs") as outputs, patch("builtins.print"):
            release.main()
        self.assertEqual(json.loads(outputs.call_args.args[0]["matrix"]), release.matrix("universal"))

    def test_stable_and_development_version_flags(self):
        self.assertEqual(release.version_flags("v1.5.2"),
                         ["IS_RELEASE=1", "MAJOR_VERSION=1", "MINOR_VERSION=5", "PATCH_VERSION=2"])
        self.assertEqual(release.version_flags("1.5.2-dev"), ["IS_RELEASE=0"])
        with self.assertRaises(ValueError):
            release.version_flags("garbage")

    def test_target_packages_have_disjoint_names_and_verifiable_contents(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            names = set()
            for target in release.TARGETS.values():
                if target["target"] == "linux-universal":
                    continue  # The combined Linux archive is covered separately.
                binary = directory / ("heimdall-1.5.1-" + target["target"] + (".exe" if target["os"] == "windows" else ""))
                binary.write_bytes(b"test executable")
                binary.chmod(0o755)
                files = release.package(binary, directory / "artifacts")
                current = {p.name for p in files}
                self.assertFalse(names & current, target)
                names |= current
                expected = hashlib.sha256(binary.read_bytes()).hexdigest() + "  " + binary.name + "\n"
                self.assertEqual(files[1].read_text(), expected)
                if target["os"] == "windows":
                    with zipfile.ZipFile(files[2]) as archive:
                        self.assertEqual(set(archive.namelist()), {binary.name, files[1].name})
                else:
                    with tarfile.open(files[2]) as archive:
                        self.assertEqual(set(archive.getnames()), {binary.name, files[1].name})
                        self.assertTrue(archive.getmember(binary.name).mode & 0o111)

    def test_uploading_one_target_does_not_delete_another_targets_assets(self):
        with tempfile.TemporaryDirectory() as temp:
            binary = Path(temp) / "heimdall-1.5.1-macos-arm64-neon"
            binary.write_bytes(b"test executable")
            assets = [{"id": 11, "name": binary.name}, {"id": 12, "name": "heimdall-1.5.1-linux-amd64-sse2"}]
            with patch.dict(os.environ, {"GITEA_BASE_URL": "https://gitea.example", "GITEA_REPO": "owner/repo", "GITEA_TOKEN": "test"}), \
                 patch("sys.argv", ["publish", "--tag", "1.5.1", "--files", str(binary)]), \
                 patch.object(publish, "get_release", return_value={"id": 7, "assets": assets}), \
                 patch.object(publish, "request_empty") as delete, patch.object(publish, "upload_file") as upload, \
                 patch("builtins.print"):
                self.assertEqual(publish.main(), 0)
            self.assertEqual(delete.call_count, 1)
            self.assertTrue(delete.call_args.args[1].endswith("/assets/11"))
            self.assertEqual(upload.call_count, 1)

    def test_make_config_uses_source_makefile_naming(self):
        config = release.make_config(["MAJOR_VERSION=7", "MINOR_VERSION=8", "PATCH_VERSION=9"])
        self.assertIn("heimdall-7.8.9-", config[2])
        self.assertTrue(config[3].startswith("heimdall-dev-"))


class AndroidReleaseTests(unittest.TestCase):
    def test_build_uses_cross_compiler_and_prepares_dependencies(self):
        flags = ["TARGET=android", "ANDROID_ABI=arm64-v8a", "PGO=0", "EMBED_NET=1"]
        with patch.object(release.subprocess, "run") as run:
            release.build_android(release.TARGETS["android-arm64-universal"], Path("bin/engine"), flags, False)
        prepare, build = [call.args[0] for call in run.call_args_list]
        self.assertEqual(prepare, ["make", "deps", "net", "NIMBLE_FLAGS=-y", *flags])
        self.assertEqual(build, ["make", "dev", "SIMD=universal", *flags, "EXE_BASE=bin/engine", "SKIP_DEPS=1"])

    def test_skip_deps_does_not_fetch_weights(self):
        with patch.object(release.subprocess, "run") as run:
            release.build_android(release.TARGETS["android-amd64-universal"], Path("bin/engine"), [], True)
        self.assertEqual(run.call_count, 1)
        self.assertEqual(run.call_args.args[0][1], "dev")

    def test_valid_android_layouts_for_both_architectures(self):
        for machine in (62, 183):
            with self.subTest(machine=machine):
                release.validate_android_elf(android_elf(machine), machine)

    def test_rejects_host_architecture_and_invalid_android_layouts(self):
        # Offsets refer to ELF64 header fields or the fixture's program headers.
        mutations = (
            (16, "<H", 2),       # Non-PIE.
            (18, "<H", 62),      # Wrong architecture.
            (32, "<Q", 0),       # Missing program header table.
            (54, "<H", 8),       # Undersized headers.
            (56, "<H", 0),       # No segments.
            (56, "<H", 400),     # Truncated header table.
            (64 + 32, "<Q", 20000),  # Truncated LOAD segment.
            (64 + 48, "<Q", 4096),   # Four-KiB LOAD alignment.
            (120 + 16, "<Q", 16385), # Incongruent LOAD address.
            (176, "<I", 0),          # No Android interpreter.
            (232 + 40, "<Q", 4096),  # Four-KiB RELRO boundary.
        )
        for offset, format_, value in mutations:
            with self.subTest(offset=offset, value=value):
                data = bytearray(android_elf())
                struct.pack_into(format_, data, offset, value)
                with self.assertRaises(ValueError):
                    release.validate_android_elf(data, 183)
        data = bytearray(android_elf())
        data[288] = ord("x")
        with self.assertRaisesRegex(ValueError, "linker64"):
            release.validate_android_elf(data, 183)

    def test_invalid_binary_prevents_packaging(self):
        args = argparse.Namespace(target="android-arm64-universal", tag="", skip_deps=True,
                                  artifacts=Path("unused"))
        with patch.object(release, "make_config", return_value=("android", "arm64", "release", "dev", "x")), \
             patch.object(release, "source_commit", return_value="source"), \
             patch.object(release, "build_android"), \
             patch.object(Path, "read_bytes", return_value=b"host executable"), \
             patch.object(release, "package") as package, patch("builtins.print"):
            with self.assertRaisesRegex(ValueError, "ELF64"):
                release.build(args)
        package.assert_not_called()

    def test_cross_build_packages_without_running_target_on_host(self):
        for arch, abi, machine in (("arm64", "arm64-v8a", 183), ("amd64", "x86_64", 62)):
            args = argparse.Namespace(target=f"android-{arch}-universal", tag="", skip_deps=True,
                                      artifacts=Path("artifacts"))
            with self.subTest(arch=arch), \
                 patch.object(release, "make_config", return_value=("android", arch, "release", "dev", "x")), \
                 patch.object(release, "source_commit", return_value="source"), \
                 patch.object(release, "build_android") as build, \
                 patch.object(Path, "read_bytes", return_value=android_elf(machine)), \
                 patch.object(release, "package", return_value=[]) as package, \
                 patch.object(release.subprocess, "run") as run, patch("builtins.print"):
                release.build(args)
            self.assertIn("TARGET=android", build.call_args.args[2])
            self.assertIn("ANDROID_ABI=" + abi, build.call_args.args[2])
            self.assertIn("PGO=0", build.call_args.args[2])
            self.assertIn("EMBED_NET=1", build.call_args.args[2])
            package.assert_called_once()
            run.assert_not_called()

    def test_source_without_android_support_fails_before_build(self):
        args = argparse.Namespace(target="android-arm64-universal", tag="", skip_deps=True,
                                  artifacts=Path("unused"))
        with patch.object(release, "make_config", return_value=("linux", "amd64", "release", "dev", "x")), \
             patch.object(release, "build_android") as build:
            with self.assertRaisesRegex(ValueError, "build configuration"):
                release.build(args)
        build.assert_not_called()


class PGOReleaseTests(unittest.TestCase):
    def test_desktop_targets_require_pgo_and_prepare_dependencies(self):
        for name, target in release.TARGETS.items():
            if name == "linux-universal" or target["os"] == "android":
                continue  # Packaging joins already compiled slices.
            with self.subTest(target=name), \
                 patch.object(release.subprocess, "check_output",
                              return_value="-fprofile-instr-generate -fprofile-instr-use=data"), \
                 patch.object(release.subprocess, "run") as run:
                release.build_pgo(target, Path("bin/engine"), ["IS_RELEASE=1"], False)
                prepare, build = [call.args[0] for call in run.call_args_list]
                self.assertEqual(prepare, ["make", "deps", "net", "NIMBLE_FLAGS=-y", "IS_RELEASE=1"])
                self.assertIn("PGO=1", build)
                self.assertIn("SIMD=" + target["backend"], build)
                self.assertIn("EXE_BASE=bin/engine", build)
                self.assertIn("SKIP_DEPS=1", build)
                self.assertEqual(build[1], target.get("make_target", "dev"))
                self.assertEqual("PGO_TRAIN_SIMD=sse2" in build,
                                 target["arch"] == "amd64" and target["backend"] != "universal")

    def test_skip_deps_never_fetches_weights(self):
        with patch.object(release.subprocess, "check_output",
                          return_value="-fprofile-instr-generate -fprofile-instr-use=data"), \
             patch.object(release.subprocess, "run") as run:
            release.build_pgo(release.TARGETS["linux-arm64-universal"], Path("bin/engine"), [], True)
        self.assertEqual(run.call_count, 1)
        self.assertIn("PGO=1", run.call_args.args[0])

    def test_older_makefiles_cannot_silently_publish_unprofiled_binaries(self):
        for planned in ("nim c engine.nim", "-fprofile-instr-generate", "-fprofile-instr-use=data"):
            with self.subTest(planned=planned), \
                 patch.object(release.subprocess, "check_output", return_value=planned), \
                 patch.object(release.subprocess, "run") as run:
                with self.assertRaisesRegex(ValueError, "does not support PGO"):
                    release.build_pgo(release.TARGETS["macos-universal"], Path("bin/engine"), [], False)
                run.assert_not_called()

    def test_failed_training_prevents_checks_and_packaging(self):
        args = argparse.Namespace(target="linux-amd64-universal", tag="", skip_deps=True,
                                  artifacts=Path("unused"))
        with patch.object(release, "make_config", return_value=("linux", "amd64", "release", "dev", "x")), \
             patch.object(release, "source_commit", return_value="source"), \
             patch.object(release.subprocess, "check_output",
                          return_value="-fprofile-instr-generate -fprofile-instr-use=data"), \
             patch.object(release.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "make")) as run, \
             patch.object(release, "package") as package, patch("builtins.print"):
            with self.assertRaises(subprocess.CalledProcessError):
                release.build(args)
        self.assertEqual(run.call_count, 1)
        package.assert_not_called()

    def make_plan(self, target, *flags):
        return subprocess.check_output(["make", "--dry-run", target, "SKIP_DEPS=1", "SIMD=universal", *flags],
                                       cwd=Path(__file__).resolve().parents[1], text=True)

    def test_mac_universal_profiles_each_slice_before_lipo(self):
        plan = self.make_plan("macos-universal", "PGO=1", "UNAME_S=Darwin", "HOST_ARCH=arm64-apple-darwin")
        compiles = [line for line in plan.splitlines() if line.startswith("nim c ")]
        self.assertEqual(len(compiles), 4)
        for arch, generate, use in (("amd64", compiles[0], compiles[1]),
                                    ("arm64", compiles[2], compiles[3])):
            self.assertIn("--cpu:" + arch, generate)
            self.assertIn("-fprofile-instr-generate", generate)
            self.assertIn("--cpu:" + arch, use)
            self.assertIn("/" + arch + "/pgo/heimdall.profdata", use)
            self.assertIn("-fprofile-instr-use=", use)
        self.assertGreater(plan.index("xcrun lipo -create"), plan.rindex("nim c "))

    def test_fixed_isa_training_keeps_the_release_instruction_set(self):
        plan = self.make_plan("dev", "PGO=1", "SIMD=avx512-vnni", "PGO_TRAIN_SIMD=sse2",
                              "UNAME_S=Linux", "HOST_ARCH=x86_64-linux-gnu")
        generate, use = [line for line in plan.splitlines() if line.startswith("nim c ")]
        self.assertIn("-march=x86-64 -mtune=", generate)
        self.assertIn("-fprofile-instr-generate", generate)
        self.assertIn("-march=x86-64-v4", use)
        self.assertIn("-mavx512vnni", use)
        self.assertIn("-fprofile-instr-use=", use)

    def test_ordinary_dev_builds_still_leave_pgo_disabled(self):
        plan = self.make_plan("dev", "PGO=0")
        self.assertNotIn("-fprofile-instr", plan)
        self.assertNotIn("uci_workload.py", plan)

    def test_external_network_is_staged_for_the_training_executable(self):
        plan = self.make_plan("dev", "PGO=1", "EMBED_NET=0")
        self.assertIn("Path('build/pgo/heimdall-train", plan)
        self.assertLess(plan.index("shutil.copyfile"), plan.index("scripts/uci_workload.py"))
        self.assertNotIn("shutil.copyfile", self.make_plan("dev", "PGO=1", "EMBED_NET=1"))

    @unittest.skipIf(os.name == "nt", "Models the MSYS2 POSIX shell")
    def test_msys2_uses_shell_environment_and_native_profile_paths(self):
        with tempfile.TemporaryDirectory() as temp:
            cygpath = Path(temp) / "cygpath"
            cygpath.write_text('#!/bin/sh\nprintf "C:/profiles/%s\\n" "$(basename "$2")"\n')
            cygpath.chmod(0o755)
            with patch.dict(os.environ, {"PATH": temp + os.pathsep + os.environ["PATH"]}):
                plan = self.make_plan("dev", "PGO=1", "OS=Windows_NT", "SHELL=/bin/sh",
                                      "HOST_ARCH=x86_64-w64-mingw32")
        self.assertIn('mkdir -p "build/pgo"', plan)
        self.assertIn('LLVM_PROFILE_FILE="C:/profiles/nodes.profraw"', plan)
        self.assertIn('LLVM_PROFILE_FILE="C:/profiles/time.profraw"', plan)
        self.assertIn('-fprofile-instr-use=C:/profiles/heimdall.profdata', plan)
        self.assertNotIn('set "LLVM_PROFILE_FILE=', plan)


if __name__ == "__main__":
    unittest.main()

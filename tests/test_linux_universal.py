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

"""Check the combined Linux executable, shared weights and private cache."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import gzip
import io
import importlib.util
import json
import os
import re
from pathlib import Path
import signal
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("release", ROOT / "scripts/release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


def elf(machine):
    header = bytearray(64)
    header[:7] = b"\x7fELF\x02\x01\x01"
    header[16:18] = (3).to_bytes(2, "little")
    header[18:20] = machine.to_bytes(2, "little")
    return bytes(header)


class LinuxPackageTests(unittest.TestCase):
    def test_executable_contains_one_network_and_two_valid_compressed_slices(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            binary = directory / "heimdall-linux-universal"
            network = b"shared network weights" * 100
            release.linux_executable(elf(62), elf(183), network, binary)
            data = binary.read_bytes()
            header = data.split(b"# Compressed payload follows.\n", 1)[0].decode()
            self.assertNotIn("@NETWORK", header)
            for key, expected in (("amd64", elf(62)), ("arm64", elf(183))):
                block = header.split("arch=" + key, 1)[1].split(";;", 1)[0]
                offset = int(re.search(r"engine_offset=(\d+)", block)[1])
                size = int(re.search(r"engine_size=(\d+)", block)[1])
                self.assertEqual(gzip.decompress(data[offset:offset + size]), expected)
            offset, size = map(int, re.search(r'extract (\d+) (\d+) "\$stage/network.bin"', header).groups())
            self.assertEqual(gzip.decompress(data[offset:offset + size]), network)
            self.assertEqual(offset + size, len(data))
            release.linux_executable(elf(62), elf(183), network, binary)
            self.assertEqual(binary.read_bytes(), data)
            files = release.package(binary, directory / "artifacts")
            self.assertEqual(files[1].read_text(), hashlib.sha256(data).hexdigest() + "  " + binary.name + "\n")
            with tarfile.open(files[2]) as archive:
                self.assertEqual(set(archive.getnames()), {binary.name, files[1].name})
                if os.name == "posix":
                    self.assertEqual(archive.getmember(binary.name).mode, 0o755)

    def test_wrong_architecture_non_elf_and_truncated_inputs_are_rejected(self):
        for bad in (elf(183), b"#!/bin/sh\n", elf(62)[:20]):
            with self.assertRaisesRegex(ValueError, "ELF64"):
                release.validate_elf(bad, 62)

    def test_combine_rejects_wrong_source_checksums_network_and_settings(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            def write_slice(arch, **overrides):
                data = elf(62 if arch == "amd64" else 183)
                network = overrides.pop("network", b"shared weights")
                metadata = dict(source="source", arch=arch, settings=["-d:embedNet=false"],
                                engine_sha256=hashlib.sha256(data).hexdigest(),
                                network_sha256=hashlib.sha256(network).hexdigest())
                metadata.update(overrides)
                path = directory / ("heimdall-dev-abcdef-linux-" + arch + "-universal-slice.tar.gz")
                with tarfile.open(path, "w:gz") as archive:
                    for name, payload in (("heimdall", data), ("network.bin", network),
                                          ("metadata.json", json.dumps(metadata).encode())):
                        member = tarfile.TarInfo(name)
                        member.size = len(payload)
                        archive.addfile(member, io.BytesIO(payload))
            write_slice("amd64")
            write_slice("arm64")
            args = argparse.Namespace(tag="", slices=directory, artifacts=directory / "out")
            with patch.object(release, "make_config", return_value=("linux", "amd64", "unused",
                              "heimdall-dev-abcdef-linux-amd64", "x")), \
                 patch.object(release, "source_commit", return_value="source"), \
                 patch.object(release, "outputs") as outputs, patch("builtins.print"):
                release.combine_linux(args)
                self.assertEqual(outputs.call_args.args[0]["artifact_name"], "heimdall-dev-abcdef-linux-universal")
                for changes, error in ((dict(source="other"), "Source/architecture"),
                                       (dict(engine_sha256="bad"), "Checksum"),
                                       (dict(network=b"other weights"), "identical network"),
                                       (dict(settings=["other settings"]), "identical network")):
                    write_slice("arm64", **changes)
                    with self.assertRaisesRegex(ValueError, error):
                        release.combine_linux(args)


@unittest.skipUnless(sys.platform.startswith("linux"), "Linux launcher uses Linux readlink")
class LinuxLauncherTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="heimdall bundle ")
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.bundle = self.directory / "relocated package"
        self.bundle.mkdir()
        self.launcher = self.bundle / "heimdall"
        self.network = b"one shared network"
        engines = []
        for arch in ("amd64", "arm64"):
            engines.append(("#!" + sys.executable + "\n" +
                            "import json, os, sys, time\nfrom pathlib import Path\n" +
                            "assert Path(sys.argv[0]).with_name('network.bin').read_bytes() == " + repr(self.network) + "\n" +
                            "if 'wait' in sys.argv: print(os.getpid(), flush=True); time.sleep(30)\n" +
                            "print(json.dumps([" + repr(arch) + ", sys.argv[1:], " +
                            "os.getcwd(), os.environ.get('HEIMDALL_SIMD'), sys.stdin.read()]))\n" +
                            "print('engine stderr', file=sys.stderr)\n" +
                            "sys.exit(23)\n").encode())
        # Launcher protocol tests use tiny scripts; production packaging validates ELF.
        with patch.object(release, "validate_elf"):
            release.linux_executable(*engines, self.network, self.launcher)
        commands = self.directory / "commands"
        commands.mkdir()
        uname = commands / "uname"
        uname.write_text('#!/bin/sh\ncase "$1" in -s) echo "${TEST_OS:-Linux}";; -m) echo "$TEST_ARCH";; esac\n')
        uname.chmod(0o755)
        self.env = {**os.environ, "PATH": str(commands) + ":" + os.environ["PATH"],
                    "TEST_ARCH": "x86_64", "HEIMDALL_SIMD": "scalar",
                    "HEIMDALL_CACHE_DIR": str(self.directory / "private cache")}

    def run_launcher(self, command=None, **env):
        return subprocess.run([str(command or self.launcher), "a b", "", "--flag"],
                              input="uci\nisready\n", capture_output=True, text=True,
                              cwd=self.directory, env={**self.env, **env}, timeout=10)

    def test_selects_both_families_and_preserves_uci_arguments_environment_and_cwd(self):
        for arch, expected in (("x86_64", "amd64"), ("amd64", "amd64"),
                               ("aarch64", "arm64"), ("arm64", "arm64")):
            with self.subTest(arch=arch):
                result = self.run_launcher(TEST_ARCH=arch)
                self.assertEqual(result.returncode, 23, result.stderr)
                self.assertEqual(json.loads(result.stdout),
                                 [expected, ["a b", "", "--flag"], str(self.directory),
                                  "scalar", "uci\nisready\n"])
                self.assertEqual(result.stderr, "engine stderr\n")

    def test_symlink_and_path_launches_locate_the_payload(self):
        link = self.directory / "engine link"
        link.symlink_to(self.launcher)
        for command, env in ((link, {}), ("heimdall", {"PATH": str(self.bundle) + ":" + self.env["PATH"]})):
            result = self.run_launcher(command, **env)
            self.assertEqual(result.returncode, 23, result.stderr)

    def test_exec_preserves_pid_and_direct_signal_delivery(self):
        with subprocess.Popen([str(self.launcher), "wait"], stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, text=True, env=self.env) as process:
            try:
                self.assertEqual(int(process.stdout.readline()), process.pid)
                process.terminate()
                self.assertEqual(process.wait(timeout=5), -signal.SIGTERM)
            finally:
                if process.poll() is None:
                    process.kill()

    def test_repeated_launch_reuses_cache_and_corruption_is_repaired(self):
        self.assertEqual(self.run_launcher().returncode, 23)
        root = Path(self.env["HEIMDALL_CACHE_DIR"])
        cache = next(root.iterdir())
        binary, network = cache / "heimdall", cache / "network.bin"
        for path in (root, cache):
            self.assertEqual(path.stat().st_mode & 0o777, 0o700)
        self.assertEqual(binary.stat().st_mode & 0o777, 0o500)
        self.assertEqual(network.stat().st_mode & 0o777, 0o400)
        before = binary.stat().st_mtime_ns
        self.assertEqual(self.run_launcher().returncode, 23)
        self.assertEqual(binary.stat().st_mtime_ns, before)
        network.chmod(0o600)
        network.write_bytes(b"corrupt")
        self.assertEqual(self.run_launcher().returncode, 23)
        self.assertEqual(network.read_bytes(), self.network)
        binary.unlink()
        self.assertEqual(self.run_launcher().returncode, 23)
        self.assertEqual(sorted(p.name for p in cache.iterdir()), ["heimdall", "network.bin"])

    def test_concurrent_cold_starts_publish_identical_files_without_stale_locks(self):
        with ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(lambda _: self.run_launcher(), range(16)))
        for result in results:
            self.assertEqual(result.returncode, 23, result.stderr)
        cache = next(Path(self.env["HEIMDALL_CACHE_DIR"]).iterdir())
        self.assertEqual(sorted(p.name for p in cache.iterdir()), ["heimdall", "network.bin"])

    def test_unsupported_os_architecture_and_truncated_payload_fail_on_stderr(self):
        for env, message in (({"TEST_OS": "Darwin"}, "requires Linux"),
                             ({"TEST_ARCH": "riscv64"}, "AMD64 or ARM64")):
            result = self.run_launcher(**env)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(result.stdout, "")
            self.assertIn(message, result.stderr)
        self.launcher.write_bytes(self.launcher.read_bytes()[:-10])
        result = self.run_launcher()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertIn("extraction failed", result.stderr)
        root = Path(self.env["HEIMDALL_CACHE_DIR"])
        self.assertEqual(list(root.glob("*/.extract.*")), [])

    def test_unsafe_cache_permissions_symlinks_and_relative_paths_are_rejected(self):
        root = Path(self.env["HEIMDALL_CACHE_DIR"])
        root.mkdir(mode=0o755)
        self.assertIn("private", self.run_launcher().stderr)
        root.rmdir()
        target = self.directory / "target"
        target.mkdir(mode=0o700)
        root.symlink_to(target, target_is_directory=True)
        self.assertIn("not a symlink", self.run_launcher().stderr)
        self.assertIn("absolute path", self.run_launcher(HEIMDALL_CACHE_DIR="relative").stderr)

    def test_xdg_cache_default(self):
        result = self.run_launcher(HEIMDALL_CACHE_DIR="", XDG_CACHE_HOME=str(self.directory / "xdg"))
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertEqual(len(list((self.directory / "xdg/heimdall").glob("*/network.bin"))), 1)


if __name__ == "__main__":
    unittest.main()

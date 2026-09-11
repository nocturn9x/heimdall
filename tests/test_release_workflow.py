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
import os
from pathlib import Path
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


class ReleaseWorkflowTests(unittest.TestCase):
    def test_one_target_creates_only_one_build_job(self):
        jobs = release.matrix("macos-arm64-neon")["include"]
        self.assertEqual(len(jobs), 1)
        self.assertEqual((jobs[0]["os"], jobs[0]["arch"], jobs[0]["backend"]), ("macos", "arm64", "neon"))
        self.assertEqual(len(release.matrix("macos")["include"]), 2)
        self.assertEqual(len(release.matrix("all")["include"]), 15)
        with self.assertRaises(ValueError):
            release.matrix("macos-arm64-avx2")

    def test_published_additions_use_the_tagged_source(self):
        with patch.object(release, "source_commit", side_effect=lambda ref: {"refs/tags/1.5.1-dev": "tagged", "master": "newer"}[ref]), \
             patch.object(release.subprocess, "run"):
            self.assertEqual(release.release_source("", "1.5.1-dev", "master"), "tagged")
            with self.assertRaisesRegex(ValueError, "must match"):
                release.release_source("master", "1.5.1-dev", "master")
            self.assertEqual(release.release_source("master", "", "master"), "newer")

    def test_manual_run_from_a_tag_does_not_implicitly_publish(self):
        args = argparse.Namespace(target="macos", ref="", tag="")
        with patch.dict(os.environ, {"GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_REF_TYPE": "tag",
                                     "GITHUB_REF_NAME": "1.5.1-dev", "GITHUB_REF": "refs/tags/1.5.1-dev"}), \
             patch.object(release, "release_source", return_value="sha"), \
             patch.object(release, "outputs") as outputs, patch("builtins.print"):
            release.plan(args)
        self.assertEqual(outputs.call_args.args[0]["tag"], "")

    def test_tag_push_publishes_without_manual_inputs(self):
        args = argparse.Namespace(target="all", ref="", tag="")
        with patch.dict(os.environ, {"GITHUB_EVENT_NAME": "push", "GITHUB_REF_TYPE": "tag",
                                     "GITHUB_REF_NAME": "1.5.1-dev", "GITHUB_REF": "refs/tags/1.5.1-dev"}), \
             patch.object(release, "release_source", return_value="sha"), \
             patch.object(release, "outputs") as outputs, patch("builtins.print"):
            release.plan(args)
        self.assertEqual(outputs.call_args.args[0]["tag"], "1.5.1-dev")

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


if __name__ == "__main__":
    unittest.main()

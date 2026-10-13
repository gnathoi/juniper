#!/usr/bin/env python3
"""Regression tests for EPEL metalinks consumed by rpm-ostree countme."""
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "build_files/normalize-epel-metalinks.py"
TEMPLATE = """[epel]
metalink=https://mirrors.fedoraproject.org/metalink?repo=epel${releasever_minor:+-z}-$releasever&arch=$basearch
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-EPEL-$releasever_major
gpgcheck=1
countme=1
enabled=1
"""

class MetalinkTests(unittest.TestCase):
    def normalize(self, version, text=TEMPLATE):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory) / "epel.repo"
            repo.write_text(text)
            result = subprocess.run(["python3", str(SCRIPT), version, directory], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            first = repo.read_text()
            result = subprocess.run(["python3", str(SCRIPT), version, directory], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(repo.read_text(), first, "normalization must be idempotent")
            return first

    def test_minor_release_uses_z_stream(self):
        expected = TEMPLATE.replace("${releasever_minor:+-z}", "-z")
        self.assertEqual(self.normalize("10.2"), expected)

    def test_major_release_uses_latest_stream(self):
        expected = TEMPLATE.replace("${releasever_minor:+-z}", "")
        self.assertEqual(self.normalize("10"), expected)

    def test_zero_minor_is_present(self):
        self.assertEqual(self.normalize("10.0"), TEMPLATE.replace("${releasever_minor:+-z}", "-z"))

    def test_only_metalinks_change(self):
        text = TEMPLATE + "# ${releasever_minor:+-z}\nname=EPEL ${releasever_minor:+-z}\n"
        result = self.normalize("10.2", text)
        self.assertIn("name=EPEL ${releasever_minor:+-z}", result)
        self.assertIn("# ${releasever_minor:+-z}", result)
        self.assertIn("countme=1", result)
        self.assertIn("gpgcheck=1", result)
        self.assertIn("$releasever_major", result)

    def test_unknown_version_fails_without_editing(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory) / "epel.repo"
            repo.write_text(TEMPLATE)
            result = subprocess.run(["python3", str(SCRIPT), "not-a-version", directory], capture_output=True, text=True)
            self.assertIn("unsupported release version", result.stderr)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(repo.read_text(), TEMPLATE)

if __name__ == "__main__":
    unittest.main()

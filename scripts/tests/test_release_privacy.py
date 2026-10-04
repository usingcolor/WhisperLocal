import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "check-release-privacy.py"
spec = importlib.util.spec_from_file_location("release_privacy", SCRIPT)
privacy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(privacy)


class ReleasePrivacyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.app = Path(self.temp.name) / "Example.app"
        (self.app / "Contents" / "MacOS").mkdir(parents=True)
        (self.app / "Contents" / "Info.plist").write_bytes(b"bundle metadata")
        self.binary = self.app / "Contents" / "MacOS" / "Example"

    def test_rejects_paths_inside_binary_data(self):
        self.binary.write_bytes(b"\x00\xff/Users/private-person/src/App.swift\x00")
        _, findings = privacy.check_app(self.app)
        self.assertEqual(findings, [("Contents/MacOS/Example", 1)])

    def test_rejects_unicode_account_names(self):
        self.binary.write_bytes("/Users/테스트/src/App.swift".encode())
        self.assertEqual(len(privacy.check_app(self.app)[1]), 1)

    def test_allows_hosted_runner_and_anonymized_paths(self):
        self.binary.write_bytes(
            b"/Users/runner/work/App.swift\x00/Users/developer/example/App.swift"
        )
        self.assertEqual(privacy.check_app(self.app)[1], [])

    def test_keeps_approved_certificate_publisher_identity(self):
        self.binary.write_bytes(b"Developer ID Application: Example User (TEAM)")
        self.assertEqual(privacy.check_app(self.app)[1], [])

    def test_scans_embedded_frameworks(self):
        framework = self.app / "Contents" / "Frameworks" / "Example.framework"
        framework.mkdir(parents=True)
        (framework / "Example").write_bytes(b"/Users/private-person/lib/File.cpp")
        self.assertEqual(privacy.check_app(self.app)[1][0][1], 1)

    def test_failure_output_does_not_repeat_private_account(self):
        self.binary.write_bytes(b"/Users/private-person/src/App.swift")
        result = subprocess.run(
            [sys.executable, str(SCRIPT), str(self.app)], capture_output=True
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(b"private-person", result.stdout + result.stderr)

    def test_missing_bundle_fails_closed(self):
        result = subprocess.run(
            [sys.executable, str(SCRIPT), str(self.app / "missing")],
            capture_output=True,
        )
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()

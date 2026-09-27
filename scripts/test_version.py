"""Run with: python -m unittest discover -s scripts -p test_version.py"""
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("version", Path(__file__).with_name("ci-version.py"))
version = importlib.util.module_from_spec(spec)
spec.loader.exec_module(version)


class VersionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.project = Path(self.directory.name) / "project.pbxproj"
        self.original = (b"// untouched\r\nMARKETING_VERSION = 0.3.5;\r\n"
                         b"CURRENT_PROJECT_VERSION = 6;\r\n") * 4
        self.project.write_bytes(self.original)

    def test_release_increments_preserve_other_bytes(self):
        for action, expected in (("patch", b"0.3.6"), ("minor", b"0.4.0"), ("major", b"1.0.0")):
            with self.subTest(action=action):
                self.project.write_bytes(self.original)
                version.update(self.project, action)
                self.assertEqual(self.project.read_bytes(), self.original.replace(b"0.3.5", expected).replace(b"= 6;", b"= 7;"))

    def test_check_does_not_write(self):
        self.assertEqual(version.update(self.project, "check"), "0.3.5 (local build 6)")
        self.assertEqual(self.project.read_bytes(), self.original)

    def test_rejects_invalid_or_inconsistent_configuration_without_writing(self):
        for broken in (
            self.original.replace(b"0.3.5", b"0.4.0", 1),
            self.original.replace(b"= 6;", b"= 7;", 1),
            self.original.replace(b"0.3.5", b"0.3"),
            self.original.replace(b"= 6;", b"= 0;"),
            b"// no version",
        ):
            with self.subTest(source=broken):
                self.project.write_bytes(broken)
                with self.assertRaises(ValueError):
                    version.update(self.project, "patch")
                self.assertEqual(self.project.read_bytes(), broken)


if __name__ == "__main__":
    unittest.main()

import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("updater", ROOT / "scripts/update-wine-mono.py")
updater = importlib.util.module_from_spec(spec)
spec.loader.exec_module(updater)

SOURCE = '''#define MONO_VERSION "11.3.0"
#if defined(__i386__) || defined(__x86_64__)
#define MONO_ARCH "x86"
#define MONO_SHA "{x86}"
#elif defined(__aarch64__)
#define MONO_ARCH "arm64"
#define MONO_SHA "{arm}"
#endif
'''.format(x86="a" * 64, arm="b" * 64)


class UpdateTests(unittest.TestCase):
    def test_selects_x86_checksum(self):
        self.assertEqual(updater.parse_addons(SOURCE), ("11.3.0", "a" * 64))

    def test_rejects_unknown_source_format(self):
        for source in ["", SOURCE.replace("MONO_SHA", "NEW_SHA"), SOURCE.replace('"11.3.0"', '"invalid"')]:
            with self.assertRaises(ValueError):
                updater.parse_addons(source)

    def test_update_is_idempotent(self):
        metadata = {"versions": {"Proton8-25": None}, "downloads": {}}
        updater.apply_release(metadata, "11.20", "11.3.0", "url", "hash")
        once = updater.render(metadata)
        updater.apply_release(metadata, "11.20", "11.3.0", "url", "hash")
        self.assertEqual(once, updater.render(metadata))
        self.assertIsNone(metadata["versions"]["Proton8-25"])

    def test_refuses_mapping_or_source_replacement(self):
        metadata = {"versions": {}, "downloads": {}}
        updater.apply_release(metadata, "11.20", "11.3.0", "url", "hash")
        before = copy.deepcopy(metadata)
        for wine, mono, url, checksum in [
            ("11.20", "12.0.0", "url", "hash"),
            ("11.21", "11.3.0", "url", "different"),
            ("11.21", "11.3.0", "different", "hash"),
        ]:
            with self.assertRaises(ValueError):
                updater.apply_release(metadata, wine, mono, url, checksum)
            self.assertEqual(metadata, before)

    def test_checksum_verification(self):
        payload = b"test MSI payload"
        with patch.object(updater.urllib.request, "urlopen", return_value=io.BytesIO(payload)):
            sri = updater.verify_download("https://example.invalid/mono.msi", hashlib.sha256(payload).hexdigest())
            self.assertTrue(sri.startswith("sha256-"))
        with patch.object(updater.urllib.request, "urlopen", return_value=io.BytesIO(payload)):
            with self.assertRaises(ValueError):
                updater.verify_download("https://example.invalid/mono.msi", "0" * 64)

    def test_release_discovery_excludes_prereleases_and_sorts_numerically(self):
        tags = "\n".join("sha\trefs/tags/wine-" + v for v in ["11.9", "11.20", "12.0-rc1", "11.0", "11.0.2"])
        with patch.object(updater.subprocess, "check_output", return_value=tags):
            self.assertEqual(updater.discover_versions(), ["11.0.2", "11.20"])

    def test_invalid_release_rejected_before_network_access(self):
        with patch.object(updater, "read_url") as fetch:
            with self.assertRaises(ValueError):
                updater.release_metadata("11.20; arbitrary command")
            fetch.assert_not_called()

    def test_later_failure_leaves_catalog_untouched(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "wine-mono.json"
            before = updater.render({"versions": {}, "downloads": {}})
            path.write_text(before)
            with patch.object(updater, "METADATA", path), patch(
                "sys.argv", ["updater", "--wine-version", "11.20", "--wine-version", "11.21"]
            ), patch.object(updater, "release_metadata", side_effect=[
                ("11.3.0", "checksum", "url", "source"), ValueError("bad later source")
            ]), patch.object(updater, "verify_download", return_value="hash"):
                with self.assertRaises(ValueError):
                    updater.main()
            self.assertEqual(path.read_text(), before)

    def test_check_mode_reports_update_without_writing(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "wine-mono.json"
            before = updater.render({"versions": {}, "downloads": {}})
            path.write_text(before)
            with patch.object(updater, "METADATA", path), patch(
                "sys.argv", ["updater", "--wine-version", "11.20", "--check"]
            ), patch.object(updater, "release_metadata", return_value=(
                "11.3.0", "checksum", "url", "source"
            )), patch.object(updater, "verify_download", return_value="hash"):
                self.assertEqual(updater.main(), 1)
            self.assertEqual(json.loads(path.read_text()), json.loads(before))


if __name__ == "__main__":
    unittest.main()

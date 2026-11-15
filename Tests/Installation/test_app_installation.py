import importlib.util
import pathlib
import plistlib
import shutil
import tempfile
import unittest
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("app_installation", ROOT / "scripts/app_installation.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def fake_app(path, version="1.0", content=b"synthetic application bytes"):
    (path / "Contents/MacOS").mkdir(parents=True)
    (path / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "com.local.keyman", "CFBundleExecutable": "Keyman", "CFBundleShortVersionString": version
    }))
    (path / "Contents/MacOS/Keyman").write_bytes(content)
    (path / "Contents/MacOS/Keyman").chmod(0o755)
    return path


class InstallationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="keyman-install-test-")
        self.root = pathlib.Path(self.temp.name)
        self.user_root = self.root / "user"
        self.project = self.root / "project"
        self.project.mkdir()
        self.official = fake_app(self.user_root / "Applications/Keyman.app")
        self.registry_calls = []

    def tearDown(self):
        self.temp.cleanup()

    def registry(self, action, path):
        self.registry_calls.append((action, path))

    def test_archive_restores_bytes_permissions_and_deduplicates_renamed_copies(self):
        archive, expected = module.archive_bundle(self.official, self.root / "archives")
        copy = self.root / "renamed.backup"
        shutil.copytree(self.official, copy)
        second, _ = module.archive_bundle(copy, self.root / "archives")
        self.assertEqual(archive, second)
        module.verify_archive(archive, expected)
        self.assertEqual(len(list((self.root / "archives").glob("*.zip"))), 1)

    def test_changed_or_corrupt_backup_cannot_remove_original(self):
        archive, expected = module.archive_bundle(self.official, self.root / "archives")
        archive.write_bytes(b"damaged")
        with self.assertRaises(zipfile.BadZipFile):
            module.retire_bundle(self.official, archive, expected, self.registry)
        self.assertTrue(self.official.exists())
        self.assertEqual(self.registry_calls, [])

    def test_cleanup_retains_config_and_only_retires_expected_copies(self):
        support = self.user_root / "Library/Application Support/Keyman"
        support.mkdir(parents=True)
        config = support / "config.json"
        config.write_text("fixture configuration")
        fake_app(self.user_root / "Applications/Keyman.backup.old.app")
        fake_app(support / "App Backups/Keyman.old.backup")
        fake_app(self.project / "dist/Keyman.app")
        unrelated = fake_app(self.user_root / "Applications/Another.app")
        before = module.manifest(self.official)
        report = module.cleanup(self.project, self.user_root, self.registry, [])
        self.assertEqual(len(report["retiredCopies"]), 3)
        self.assertEqual(module.manifest(self.official), before)
        self.assertTrue(unrelated.exists())
        self.assertTrue((self.project / "dist/Keyman.app.zip").exists())
        self.assertEqual(config.read_text(), "fixture configuration")
        self.assertEqual(module.cleanup(self.project, self.user_root, self.registry, [])["retiredCopies"], [])

    def test_identical_install_keeps_app_inode_and_makes_no_backup(self):
        source, _ = module.archive_bundle(self.official, self.root / "packages")
        inode = self.official.stat().st_ino
        report = module.install(source, self.project, self.user_root, self.registry, lambda _: None, [])
        self.assertFalse(report["applicationReplaced"])
        self.assertEqual(self.official.stat().st_ino, inode)
        self.assertFalse((self.user_root / "Library/Application Support/Keyman/App Archives.noindex").exists())
        self.assertEqual((self.user_root / ".local/bin/keyman").resolve(), (self.official / "Contents/MacOS/Keyman").resolve())

    def test_failed_install_restores_previous_app(self):
        different = fake_app(self.root / "new/Keyman.app", version="2.0", content=b"new synthetic bytes")
        source, _ = module.archive_bundle(different, self.root / "packages")
        before = module.manifest(self.official)
        def verify(path):
            if path == self.official:
                raise ValueError("Simulated installed verification failure")
        with self.assertRaises(ValueError):
            module.install(source, self.project, self.user_root, self.registry, verify, [])
        self.assertEqual(module.manifest(self.official), before)

    def test_running_old_copy_is_not_removed(self):
        old = fake_app(self.user_root / "Applications/Keyman.backup.running.app")
        with self.assertRaises(RuntimeError):
            module.cleanup(self.project, self.user_root, self.registry, [old / "Contents/MacOS/Keyman"])
        self.assertTrue(old.exists())

    def test_archive_traversal_is_rejected_before_extracting(self):
        archive = self.root / "bad.zip"
        with zipfile.ZipFile(archive, "w") as package:
            package.writestr("../escaped", "bad")
        with self.assertRaises(ValueError):
            module.safe_extract(archive, self.root / "extracted")
        self.assertFalse((self.root / "escaped").exists())


if __name__ == "__main__":
    unittest.main()

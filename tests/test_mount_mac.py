import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


REPOSITORY = Path(__file__).parents[1]
SCRIPT = Path(os.environ.get("BENTO_MOUNT_MAC", REPOSITORY / "hosts/bento-vm/mount-mac.sh"))


class MountMacTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="bento-mount-tests."))
        self.mount = self.root / "mnt/bento-mac"
        self.link = self.root / "home/chime/Mac"
        self.link.parent.mkdir(parents=True)
        self.devices = self.root / "devices"
        self.devices.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.marker = self.root / "mounted"
        self.link_marker = self.root / "state/managed-link"
        self.warning = self.root / "warning"
        self._stub("mountpoint", '[[ -e "$BENTO_TEST_MOUNTED" ]]')
        self._stub("mount", 'touch "$BENTO_TEST_MOUNTED"')
        self._stub("umount", 'rm -f "$BENTO_TEST_MOUNTED"')
        self._stub("chown", ":")
        self._stub("systemd-cat", 'cat > "$BENTO_TEST_WARNING"')
        self.environment = os.environ.copy()
        self.environment.update(
            {
                "PATH": f"{self.bin}:{self.environment['PATH']}",
                "BENTO_MAC_MOUNT_PATH": str(self.mount),
                "BENTO_MAC_LINK_PATH": str(self.link),
                "BENTO_VIRTIO_DEVICES": str(self.devices),
                "BENTO_MAC_MARKER_PATH": str(self.link_marker),
                "BENTO_TEST_MOUNTED": str(self.marker),
                "BENTO_TEST_WARNING": str(self.warning),
            }
        )

    def tearDown(self):
        shutil.rmtree(self.root, ignore_errors=True)

    def _stub(self, name, body):
        path = self.bin / name
        bash = shutil.which("bash") or "/bin/bash"
        path.write_text(f"#!{bash}\n{body}\n")
        path.chmod(0o755)

    def run_script(self, *arguments):
        return subprocess.run(
            [os.environ.get("BASH", "bash"), str(SCRIPT), *arguments],
            env=self.environment,
            capture_output=True,
            text=True,
        )

    def add_tag(self):
        device = self.devices / "virtio1"
        device.mkdir()
        (device / "mount_tag").write_text("bento-mac\0")

    def test_absent_tag_leaves_no_paths(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.mount.exists())
        self.assertFalse(self.link.exists())

    def test_tag_mounts_and_creates_only_managed_symlink(self):
        self.add_tag()
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.marker.exists())
        self.assertTrue(self.link.is_symlink())
        self.assertTrue(self.link_marker.exists())
        self.assertEqual(self.mount.parent.stat().st_mode & 0o777, 0o755)
        self.assertEqual(os.readlink(self.link), str(self.mount))
        result = self.run_script("--stop")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.link.exists())
        self.assertFalse(self.link_marker.exists())
        self.assertFalse(self.mount.exists())

    def test_existing_mac_path_is_preserved_and_warned(self):
        self.add_tag()
        self.link.mkdir()
        sentinel = self.link / "mine"
        sentinel.write_text("keep")
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sentinel.read_text(), "keep")
        self.assertIn("already exists", self.warning.read_text())

    def test_preexisting_matching_symlink_is_preserved_and_warned(self):
        self.add_tag()
        self.link.symlink_to(self.mount)
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.link.is_symlink())
        self.assertFalse(self.link_marker.exists())
        self.assertIn("already exists", self.warning.read_text())
        result = self.run_script("--stop")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.link.is_symlink())


if __name__ == "__main__":
    unittest.main()

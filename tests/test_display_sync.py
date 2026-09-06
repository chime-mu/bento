#!/usr/bin/env python3

import os
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parents[1]
DISPLAY_SYNC = Path(
    os.environ.get("BENTO_DISPLAY_SYNC", REPOSITORY / "home/chime/display-sync.sh")
)
BASH = shutil.which("bash")
if BASH is None:
    raise RuntimeError("bash is required")


def finish_checksum(block: bytearray, offset: int = 0) -> None:
    block[offset + 127] = (-sum(block[offset : offset + 127])) & 0xFF


def displayid_edid(
    width: int,
    height: int,
    physical_width_cm: int,
    physical_height_cm: int,
    *,
    pixel_clock: int,
    hblank: int,
    hfront: int,
    hsync: int,
    vblank: int,
    vfront: int,
    vsync: int,
) -> bytes:
    edid = bytearray(256)
    edid[:8] = b"\x00\xff\xff\xff\xff\xff\xff\x00"
    edid[21:23] = bytes([physical_width_cm, physical_height_cm])
    edid[126] = 1
    finish_checksum(edid)

    extension = bytearray(128)
    extension[:8] = bytes([0x70, 0x13, 0x17, 0x03, 0x00, 0x03, 0x00, 0x14])
    timing = bytearray(20)
    timing[0:3] = (pixel_clock // 10_000 - 1).to_bytes(3, "little")
    timing[3] = 0x80  # preferred
    timing[4:6] = (width - 1).to_bytes(2, "little")
    timing[6:8] = (hblank - 1).to_bytes(2, "little")
    timing[8:10] = (hfront - 1).to_bytes(2, "little")
    timing[10:12] = (hsync - 1).to_bytes(2, "little")
    timing[12:14] = (height - 1).to_bytes(2, "little")
    timing[14:16] = (vblank - 1).to_bytes(2, "little")
    timing[16:18] = (vfront - 1).to_bytes(2, "little")
    timing[18:20] = (vsync - 1).to_bytes(2, "little")
    extension[8:28] = timing
    extension[28] = (-sum(extension[1:28])) & 0xFF
    finish_checksum(extension)
    edid[128:] = extension
    return bytes(edid)


def legacy_edid() -> bytes:
    edid = bytearray(128)
    edid[:8] = b"\x00\xff\xff\xff\xff\xff\xff\x00"
    # 1920x1080@60 on a 509x286 mm low-PPI display. This is the legacy DTD
    # shape emitted by QEMU for modes that fit in the base EDID block.
    edid[54:72] = bytes.fromhex(
        "02 3a 80 18 71 38 2d 40 58 2c 45 00 fd 1e 11 00 00 18"
    )
    finish_checksum(edid)
    return bytes(edid)


def static_qemu_edid() -> bytes:
    # Captured from Homebrew QEMU 11.1.1 with Bento's software launch flags.
    # Cocoa published a transient 320x135 DTD at startup, which is not usable;
    # the otherwise-valid compatibility list begins with 5120x2160.
    return bytes.fromhex(
        "00 ff ff ff ff ff ff 00 49 14 34 12 00 00 00 00 "
        "2a 18 01 04 a5 05 02 78 06 ee 91 a3 54 4c 99 26 "
        "0f 50 54 21 08 00 e1 c0 d1 c0 d1 00 a9 40 b3 00 "
        "95 00 81 80 81 40 68 01 40 70 10 87 04 00 50 09 "
        "00 00 3a 18 00 00 00 18 00 00 00 f7 00 0a 00 40 "
        "82 00 28 20 00 00 00 00 00 00 00 00 00 fd 00 32 "
        "7d 1e a0 ff 01 0a 20 20 20 20 20 20 00 00 00 fc "
        "00 51 45 4d 55 20 4d 6f 6e 69 74 6f 72 0a 01 a2 "
        "02 03 0b 00 46 7d 65 60 59 1f 61 00 00 00 10 00 "
        "00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 "
        "10 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 "
        "00 00 10 00 00 00 00 00 00 00 00 00 00 00 00 00 "
        "00 00 00 00 10 00 00 00 00 00 00 00 00 00 00 00 "
        "00 00 00 00 00 00 10 00 00 00 00 00 00 00 00 00 "
        "00 00 00 00 00 00 00 00 10 00 00 00 00 00 00 00 "
        "00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 2f"
    )


class DisplaySyncTests(unittest.TestCase):
    maxDiff = None

    def run_sync(
        self,
        *arguments: str,
        environment: dict[str, str] | None = None,
        input_text: str | None = None,
        check: bool = True,
    ) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        if environment:
            env.update(environment)
        return subprocess.run(
            ["bash", str(DISPLAY_SYNC), *arguments],
            input=input_text,
            text=True,
            capture_output=True,
            env=env,
            check=check,
        )

    def decode(self, temporary: Path, name: str, edid: bytes) -> tuple[str, str]:
        path = temporary / name
        path.write_bytes(edid)
        result = self.run_sync("--decode-edid", str(path))
        mode, scale = result.stdout.strip().split("\t")
        return mode, scale

    def test_decodes_displayid_at_scale_two(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            mode, scale = self.decode(
                Path(directory),
                "retina.edid",
                displayid_edid(
                    5120,
                    2880,
                    59,
                    33,
                    pixel_clock=1_236_000_000,
                    hblank=1792,
                    hfront=1280,
                    hsync=153,
                    vblank=100,
                    vfront=14,
                    vsync=14,
                ),
            )
        self.assertEqual(
            mode,
            "modeline 1236 5120 6400 6553 6912 2880 2894 2908 2980 -hsync -vsync",
        )
        self.assertEqual(scale, "2")

    def test_decodes_displayid_at_scale_one_point_five(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            mode, scale = self.decode(
                Path(directory),
                "fractional.edid",
                displayid_edid(
                    3840,
                    2160,
                    60,
                    34,
                    pixel_clock=594_000_000,
                    hblank=560,
                    hfront=176,
                    hsync=88,
                    vblank=90,
                    vfront=8,
                    vsync=10,
                ),
            )
        self.assertEqual(
            mode,
            "modeline 594 3840 4016 4104 4400 2160 2168 2178 2250 -hsync -vsync",
        )
        self.assertEqual(scale, "1.5")

    def test_decodes_legacy_edid_at_scale_one(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            mode, scale = self.decode(Path(directory), "legacy.edid", legacy_edid())
        self.assertEqual(
            mode,
            "modeline 149 1920 2008 2052 2200 1080 1084 1089 1125 -hsync -vsync",
        )
        self.assertEqual(scale, "1")

    def test_static_qemu_edid_uses_readable_fallback(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            mode, scale = self.decode(
                Path(directory), "stock-qemu.edid", static_qemu_edid()
            )
        self.assertEqual(mode, "1920x1080@60")
        self.assertEqual(scale, "1")

    def test_rejects_malformed_edid(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "malformed.edid"
            malformed = bytearray(legacy_edid())
            malformed[20] ^= 0x01
            path.write_bytes(malformed)
            result = self.run_sync("--decode-edid", str(path), check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def make_runtime(self, temporary: Path, edid: bytes) -> tuple[dict[str, str], Path]:
        drm_root = temporary / "drm"
        connector = drm_root / "card0-Virtual-1"
        connector.mkdir(parents=True)
        (connector / "status").write_text("connected\n", encoding="utf-8")
        (connector / "edid").write_bytes(edid)

        fake_bin = temporary / "bin"
        fake_bin.mkdir()
        hyprctl_log = temporary / "hyprctl.log"
        hyprctl = fake_bin / "hyprctl"
        hyprctl.write_text(
            f'#!{BASH}\nprintf "%s\\n" "$*" >>"$BENTO_HYPRCTL_LOG"\nprintf "ok\\n"\n',
            encoding="utf-8",
        )
        hyprctl.chmod(0o755)
        environment = {
            "PATH": f"{fake_bin}:{os.environ['PATH']}",
            "BENTO_DISPLAY_SYNC_DRM_ROOT": str(drm_root),
            "BENTO_HYPRCTL_LOG": str(hyprctl_log),
        }
        return environment, hyprctl_log

    def test_applies_once_at_session_start(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            environment, log = self.make_runtime(
                temporary,
                displayid_edid(
                    5120,
                    2880,
                    59,
                    33,
                    pixel_clock=1_236_000_000,
                    hblank=1792,
                    hfront=1280,
                    hsync=153,
                    vblank=100,
                    vfront=14,
                    vsync=14,
                ),
            )
            self.run_sync("--once", environment=environment)
            calls = log.read_text(encoding="utf-8").splitlines()
        self.assertEqual(
            calls,
            [
                'eval hl.monitor({ output = "", mode = "modeline 1236 5120 6400 '
                '6553 6912 2880 2894 2908 2980 -hsync -vsync", position = "auto", '
                'scale = "2" })'
            ],
        )

    def test_only_drm_hotplug_changes_trigger_an_update(self) -> None:
        events = """\
ACTION=change
SUBSYSTEM=drm
HOTPLUG=1

ACTION=add
SUBSYSTEM=drm
HOTPLUG=1

ACTION=change
SUBSYSTEM=drm
HOTPLUG=0

ACTION=change
SUBSYSTEM=drm
HOTPLUG=1
"""
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            environment, log = self.make_runtime(temporary, legacy_edid())
            self.run_sync("--from-stdin", environment=environment, input_text=events)
            calls = log.read_text(encoding="utf-8").splitlines()
        self.assertEqual(len(calls), 2)
        self.assertTrue(
            all(call.endswith('position = "auto", scale = "1" })') for call in calls)
        )

    def test_recreates_udev_monitor_after_it_exits(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            fake_bin = temporary / "bin"
            fake_bin.mkdir()
            monitor_log = temporary / "udev-monitor.log"
            udevadm = fake_bin / "udevadm"
            udevadm.write_text(
                f'#!{BASH}\nprintf "run\\n" >>"$BENTO_UDEV_MONITOR_LOG"\n',
                encoding="utf-8",
            )
            udevadm.chmod(0o755)
            empty_drm = temporary / "drm"
            empty_drm.mkdir()
            environment = os.environ.copy()
            environment.update(
                {
                    "PATH": f"{fake_bin}:{environment['PATH']}",
                    "BENTO_DISPLAY_SYNC_DRM_ROOT": str(empty_drm),
                    "BENTO_DISPLAY_SYNC_RETRY_SECONDS": "0.01",
                    "BENTO_UDEV_MONITOR_LOG": str(monitor_log),
                }
            )
            process = subprocess.Popen(
                ["bash", str(DISPLAY_SYNC)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                env=environment,
            )
            try:
                deadline = time.monotonic() + 2
                while time.monotonic() < deadline:
                    if monitor_log.exists() and len(
                        monitor_log.read_text(encoding="utf-8").splitlines()
                    ) >= 2:
                        break
                    time.sleep(0.02)
                else:
                    self.fail("udevadm monitor was not recreated")
            finally:
                process.terminate()
                process.wait(timeout=2)


if __name__ == "__main__":
    unittest.main()

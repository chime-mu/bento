import json
import os
import shutil
import signal
import stat
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


REPOSITORY = Path(__file__).parents[1]
RUN_VM = REPOSITORY / "scripts/run-vm.sh"


class RunVMTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix=".bento-run-tests-", dir=REPOSITORY))
        self.artifacts = self.root / "artifacts"
        self.artifacts.mkdir(mode=0o755)
        (self.artifacts / "bento.qcow2").write_bytes(b"disk")
        (self.artifacts / "edk2-aarch64-vars.fd").write_bytes(b"vars")
        (self.artifacts / "bento-app.log").write_text("log")
        (self.artifacts / "bridge.log").write_text("bridge log")
        self.efi = self.root / "efi.fd"
        self.efi.write_bytes(b"efi")
        self.arguments = self.root / "qemu-arguments"
        self.ready = self.root / "qemu-ready"
        self.qemu = self.root / "qemu-stub"
        self.qemu.write_text(
            """#!/usr/bin/env bash
set -eu
if [[ ${1:-} == --version ]]; then
  echo 'QEMU emulator version 11.1.1 (Bento test)'
  exit 0
fi
if [[ ${1:-} == -device && ${2:-} == help ]]; then
  printf '%s\n' virtio-gpu-gl-pci virtio-gpu-pci virtio-serial-pci virtserialport virtio-9p-pci intel-hda hda-micro
  exit 0
fi
if [[ ${1:-} == -fsdev && ${2:-} == local,help ]]; then
  printf '%s\n' 'uid=<num>' 'gid=<num>'
  exit 0
fi
if [[ " $* " == *" -audiodev help "* ]]; then
  printf '%s\n' sdl
  exit 0
fi
printf '%s\n' "$@" > "$BENTO_TEST_ARGUMENTS"
touch "$BENTO_TEST_READY"
trap 'exit 0' TERM INT
while :; do sleep 0.1; done
"""
        )
        self.qemu.chmod(0o755)
        self.environment = os.environ.copy()
        self.environment.update(
            {
                "BENTO_ARTIFACTS": str(self.artifacts),
                "BENTO_EFI_CODE": str(self.efi),
                "BENTO_EFI_VARS_SIZE_MB": "1",
                "BENTO_QEMU": str(self.qemu),
                "BENTO_SOFTWARE_QEMU": str(self.qemu),
                "BENTO_CLIPBOARD_BRIDGE": str(self.root / "missing-bridge"),
                "BENTO_TEST_ARGUMENTS": str(self.arguments),
                "BENTO_TEST_READY": str(self.ready),
                "HOME": str(self.root),
            }
        )

    def tearDown(self):
        shutil.rmtree(self.root, ignore_errors=True)

    def wait_for(self, path, timeout=5):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if path.exists():
                return
            time.sleep(0.02)
        self.fail(f"timed out waiting for {path}")

    def start(self, *arguments, environment=None):
        process = subprocess.Popen(
            [str(RUN_VM), *arguments],
            cwd=REPOSITORY,
            env=environment or self.environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and not self.ready.exists():
            if process.poll() is not None:
                stdout, stderr = process.communicate()
                self.fail(f"run-vm exited before QEMU started:\n{stdout}\n{stderr}")
            time.sleep(0.02)
        if not self.ready.exists():
            process.terminate()
            stdout, stderr = process.communicate(timeout=5)
            self.fail(f"timed out waiting for QEMU stub:\n{stdout}\n{stderr}")
        self.wait_for(self.artifacts / "runtime.json")
        qemu_arguments = self.arguments.read_text().splitlines()
        descriptor = json.loads((self.artifacts / "runtime.json").read_text())
        return process, qemu_arguments, descriptor

    def stop(self, process):
        process.send_signal(signal.SIGTERM)
        stdout, stderr = process.communicate(timeout=5)
        self.assertFalse((self.artifacts / "runtime.json").exists())
        self.assertFalse(any(self.artifacts.glob("runtime.*")))
        return stdout, stderr

    def test_default_launch_is_loopback_private_and_clipboard_enabled(self):
        process, arguments, descriptor = self.start()
        self.assertIn("user,id=bento-net,hostfwd=tcp:127.0.0.1:2222-:22", arguments)
        self.assertIn("virtio-net-pci,netdev=bento-net,romfile=", arguments)
        self.assertIn("virtio-blk-pci,drive=bento-disk,bootindex=1,romfile=", arguments)
        self.assertIn("strict=on", arguments)
        self.assertIn("virtio-serial-pci,id=bento-integrations,romfile=", arguments)
        self.assertIn(
            "virtserialport,bus=bento-integrations.0,nr=1,chardev=bento-audio-bridge,name=dev.bento.audio",
            arguments,
        )
        self.assertIn(
            "virtserialport,bus=bento-integrations.0,nr=2,chardev=bento-clipboard,name=dev.bento.clipboard",
            arguments,
        )
        self.assertEqual(
            sum(value.startswith("virtio-serial-pci") for value in arguments), 1
        )
        self.assertIn("sdl,id=bento-audio", arguments)
        self.assertIn("intel-hda,id=bento-hda,romfile=", arguments)
        self.assertIn("hda-micro,bus=bento-hda.0,audiodev=bento-audio", arguments)
        self.assertIn("virtio-gpu-gl-pci,max_outputs=1,xres=1920,yres=1080", arguments)
        self.assertEqual(descriptor["gpu"], "virgl")
        self.assertEqual(descriptor["version"], 2)
        self.assertTrue(descriptor["audio"])
        runtime = Path(descriptor["qmp"]).parent
        self.assertEqual(Path(descriptor["audioSocket"]).parent, runtime)
        self.assertEqual(Path(descriptor["audioRoutes"]).parent, runtime)
        self.assertEqual(stat.S_IMODE(self.artifacts.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(runtime.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE((self.artifacts / "runtime.json").stat().st_mode), 0o600)
        for name in (
            "bento.qcow2",
            "edk2-aarch64-vars.fd",
            "edk2-aarch64-vars.profile",
            "bento-app.log",
            "bridge.log",
        ):
            self.assertEqual(stat.S_IMODE((self.artifacts / name).stat().st_mode), 0o600)
        self.stop(process)

    def test_rendering_modes_keep_the_patched_runtime(self):
        cases = [
            (["--windowed"], "cocoa,gl=es", "virtio-gpu-gl-pci"),
            (["--no-gl"], "-display", "virtio-gpu-pci"),
            (["--headless"], "none", "virtio-gpu-pci"),
        ]
        for launch_arguments, display_marker, gpu in cases:
            with self.subTest(arguments=launch_arguments):
                self.ready.unlink(missing_ok=True)
                self.arguments.unlink(missing_ok=True)
                process, arguments, _ = self.start(*launch_arguments, "--no-clipboard")
                self.assertTrue(any(value.startswith(gpu) for value in arguments))
                self.assertTrue(any(display_marker in value for value in arguments))
                self.stop(process)

    def test_share_with_spaces_and_unicode_has_owner_mapping(self):
        shared = self.root / "My shared ünicode folder"
        shared.mkdir()
        process, arguments, _ = self.start("--share", str(shared), "--no-clipboard")
        self.assertIn(
            f"local,id=bento-mac,path={shared},security_model=none,multidevs=remap,uid=1000,gid=100",
            arguments,
        )
        self.assertIn("virtio-9p-pci,fsdev=bento-mac,mount_tag=bento-mac,romfile=", arguments)
        self.stop(process)

    def test_no_share_clipboard_or_audio_adds_no_integration_devices(self):
        process, arguments, descriptor = self.start(
            "--no-share", "--no-clipboard", "--no-audio"
        )
        self.assertFalse(any("bento-mac" in value or "bento-clipboard" in value for value in arguments))
        self.assertFalse(any("bento-audio" in value or "intel-hda" in value for value in arguments))
        self.assertFalse(any(value.startswith("virtio-serial-pci") for value in arguments))
        self.assertFalse(descriptor["audio"])
        self.stop(process)

    def test_audio_defaults_overrides_and_conflicts(self):
        cases = [
            ([], True),
            (["--windowed"], True),
            (["--headless"], False),
            (["--headless", "--audio"], True),
            (["--no-audio"], False),
        ]
        for launch_arguments, enabled in cases:
            with self.subTest(arguments=launch_arguments):
                self.ready.unlink(missing_ok=True)
                self.arguments.unlink(missing_ok=True)
                process, arguments, descriptor = self.start(
                    *launch_arguments, "--no-clipboard"
                )
                self.assertEqual(descriptor["audio"], enabled)
                self.assertEqual("sdl,id=bento-audio" in arguments, enabled)
                self.stop(process)

        result = subprocess.run(
            [str(RUN_VM), "--audio", "--no-audio"],
            cwd=REPOSITORY,
            env=self.environment,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("mutually exclusive", result.stderr)

    def test_invalid_ports_and_paths_are_rejected(self):
        for arguments in (
            ["--ssh-port", "0"],
            ["--ssh-port", "65536"],
            ["--ssh-port", "2x"],
            ["--share", "relative"],
            ["--share", str(self.root)],
        ):
            with self.subTest(arguments=arguments):
                result = subprocess.run(
                    [str(RUN_VM), *arguments],
                    cwd=REPOSITORY,
                    env=self.environment,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                )
                self.assertEqual(result.returncode, 2)

        shared = self.root / "real"
        shared.mkdir()
        symlink = self.root / "link"
        symlink.symlink_to(shared)
        result = subprocess.run(
            [str(RUN_VM), "--share", str(symlink)],
            cwd=REPOSITORY,
            env=self.environment,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("symbolic links", result.stderr)

    def test_refused_second_launch_preserves_running_vm_descriptor(self):
        descriptor = self.artifacts / "runtime.json"
        original = '{"version":1,"pid":99,"qmp":"existing"}\n'
        descriptor.write_text(original)
        with (self.artifacts / "bento.qcow2").open("rb"):
            result = subprocess.run(
                [str(RUN_VM), "--headless"],
                cwd=REPOSITORY,
                env=self.environment,
                capture_output=True,
                text=True,
            )
        self.assertEqual(result.returncode, 1)
        self.assertIn("already running", result.stderr)
        self.assertEqual(descriptor.read_text(), original)

    def test_stock_fallback_boots_but_rejects_share(self):
        environment = self.environment.copy()
        environment["BENTO_QEMU"] = str(self.root / "no-patched-qemu")
        process, arguments, descriptor = self.start(
            "--no-gl", "--no-clipboard", "--no-audio", environment=environment
        )
        self.assertEqual(descriptor["gpu"], "software")
        self.assertIn("virtio-gpu-pci,max_outputs=1,xres=1920,yres=1080", arguments)
        self.stop(process)

        shared = self.root / "share"
        shared.mkdir()
        result = subprocess.run(
            [str(RUN_VM), "--share", str(shared), "--no-gl", "--no-clipboard", "--no-audio"],
            cwd=REPOSITORY,
            env=environment,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("guest-owner-capable", result.stderr)

    def test_audio_topology_marker_migrates_efi_vars(self):
        old_profile = self.artifacts / "edk2-aarch64-vars.profile"
        old_profile.write_text(
            "qemu=QEMU emulator version 11.1.1 (Bento test)|machine=virt,accel=hvf,gic-version=3|gpu=virtio-gpu-gl-pci|topology=bento-20260905-v3\n"
        )
        process, _, _ = self.start("--no-clipboard")
        self.assertIn("topology=bento-20260905-v4", old_profile.read_text())
        self.stop(process)

    def test_bridge_is_restarted_and_stopped_with_qemu(self):
        bridge_count = self.root / "bridge-count"
        bridge = self.root / "bridge-stub"
        bridge.write_text(
            """#!/usr/bin/env bash
set -eu
count=0
if [[ -r $BENTO_TEST_BRIDGE_COUNT ]]; then read -r count < "$BENTO_TEST_BRIDGE_COUNT"; fi
count=$((count + 1))
printf '%s\n' "$count" > "$BENTO_TEST_BRIDGE_COUNT"
if [[ $count -eq 1 ]]; then exit 1; fi
trap 'exit 0' TERM INT
while :; do sleep 0.1; done
"""
        )
        bridge.chmod(0o755)
        environment = self.environment.copy()
        environment["BENTO_CLIPBOARD_BRIDGE"] = str(bridge)
        environment["BENTO_TEST_BRIDGE_COUNT"] = str(bridge_count)
        process, _, _ = self.start(environment=environment)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if bridge_count.exists() and int(bridge_count.read_text()) >= 2:
                break
            time.sleep(0.05)
        else:
            self.fail("clipboard bridge was not restarted")
        self.stop(process)


if __name__ == "__main__":
    unittest.main()

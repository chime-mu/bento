import json
import os
import socket
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path


REPOSITORY = Path(__file__).parents[1]
SCRIPT = REPOSITORY / "scripts/vm-screenshot.sh"


class VMScreenshotTests(unittest.TestCase):
    def test_consumes_private_version_2_runtime_descriptor(self):
        with tempfile.TemporaryDirectory(prefix=".bq.", dir=REPOSITORY) as temporary:
            artifacts = Path(temporary)
            runtime = artifacts / "runtime.private"
            runtime.mkdir(mode=0o700)
            qmp = runtime / "qmp.sock"
            output = artifacts / "screen.png"
            descriptor = artifacts / "runtime.json"
            descriptor.write_text(
                json.dumps(
                    {
                        "version": 2,
                        "qmp": str(qmp),
                        "pid": os.getpid(),
                        "sshPort": 2345,
                        "gpu": "software",
                        "audio": False,
                    }
                )
            )
            descriptor.chmod(0o600)
            commands = []
            ready = threading.Event()

            def serve():
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
                    server.bind(str(qmp))
                    server.listen(1)
                    ready.set()
                    connection, _ = server.accept()
                    with connection, connection.makefile("rwb", buffering=0) as stream:
                        stream.write(b'{"QMP":{"version":{"qemu":{"major":11}}}}\n')
                        while True:
                            line = stream.readline()
                            if not line:
                                return
                            command = json.loads(line)
                            commands.append(command)
                            if command["execute"] == "screendump":
                                Path(command["arguments"]["filename"]).write_bytes(b"png")
                            stream.write(b'{"return":{}}\n')
                            if command["execute"] == "screendump":
                                return

            thread = threading.Thread(target=serve)
            thread.start()
            self.assertTrue(ready.wait(2))
            environment = os.environ.copy()
            environment["BENTO_ARTIFACTS"] = str(artifacts)
            result = subprocess.run(
                [str(SCRIPT), "--scanout", str(output)],
                cwd=REPOSITORY,
                env=environment,
                capture_output=True,
                text=True,
                timeout=10,
            )
            thread.join(timeout=2)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(output.read_bytes(), b"png")
            self.assertEqual([value["execute"] for value in commands], ["qmp_capabilities", "screendump"])


if __name__ == "__main__":
    unittest.main()

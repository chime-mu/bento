import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SOURCE = Path(os.environ.get(
    "BENTO_CLIPBOARD_AGENT",
    Path(__file__).parents[1] / "home/chime/clipboard-agent.py",
))
SPEC = importlib.util.spec_from_file_location("bento_clipboard_agent", SOURCE)
agent = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = agent
SPEC.loader.exec_module(agent)


class FakeClipboard:
    def __init__(self, current=None):
        self.current = current
        self.written = []

    def read(self):
        return self.current

    def write(self, content):
        self.current = content
        self.written.append(content)


class ClipboardAgentTests(unittest.TestCase):
    def test_fragmented_framing_and_payload_validation(self):
        content = agent.ClipboardContent("text", "héllo".encode())
        encoded = agent.encode_clipboard(content)
        framer = agent.NDJSONFramer()
        lines = []
        for byte in encoded:
            lines += framer.feed(bytes([byte]))
        self.assertEqual(len(lines), 1)
        self.assertEqual(agent.decode_message(lines[0]), ("clipboard", content))
        with self.assertRaises(agent.ProtocolError):
            agent.decode_message(b"not json")
        with self.assertRaises(agent.ProtocolError):
            agent.ClipboardContent("png", b"x" * (agent.MAX_PAYLOAD + 1))
        with self.assertRaises(agent.ProtocolError):
            agent.NDJSONFramer().feed(b"x" * (agent.MAX_LINE + 1))

    def test_initial_mac_sync_both_directions_and_echo_suppression(self):
        guest = FakeClipboard(agent.ClipboardContent("text", b"old guest"))
        sent = []
        session = agent.ClipboardAgent(guest, sent.append)
        session.connected()
        self.assertEqual(agent.decode_message(sent.pop(0))[0], "sync")

        mac = agent.ClipboardContent("text", b"from mac")
        session.receive(agent.encode_clipboard(mac).rstrip(b"\n"))
        self.assertEqual(guest.written, [mac])
        session.receive(agent.encode_sync().rstrip(b"\n"))
        session.local_changed()
        self.assertEqual(sent, [], "Mac clipboard was echoed back")

        guest.current = agent.ClipboardContent("png", b"\x89PNGguest")
        session.local_changed()
        self.assertEqual(agent.decode_message(sent[0].rstrip(b"\n")), ("clipboard", guest.current))

    def test_local_return_to_previously_sent_value_is_not_suppressed(self):
        suppressor = agent.EchoSuppressor()
        first = agent.ClipboardContent("text", b"first").fingerprint
        remote = agent.ClipboardContent("text", b"remote").fingerprint

        self.assertTrue(suppressor.should_send_local(first))
        self.assertTrue(suppressor.should_apply_remote(remote))
        self.assertTrue(suppressor.should_send_local(first))

    def test_wl_paste_prefers_text_and_wl_copy_uses_matching_mime(self):
        calls = []

        def run(arguments, **kwargs):
            calls.append((arguments, kwargs))
            if arguments[0] == "wl-paste":
                return subprocess.CompletedProcess(arguments, 0, stdout=b"both offered")
            return subprocess.CompletedProcess(arguments, 0, stdout=b"")

        clipboard = agent.WaylandClipboard(run)
        content = clipboard.read()
        self.assertEqual(content, agent.ClipboardContent("text", b"both offered"))
        self.assertEqual(len([call for call in calls if call[0][0] == "wl-paste"]), 1)
        clipboard.write(agent.ClipboardContent("png", b"png"))
        self.assertEqual(calls[-1][0], ["wl-copy", "--type", "image/png"])
        self.assertEqual(calls[-1][1]["input"], b"png")

    def test_png_fallback(self):
        def run(arguments, **kwargs):
            mime = arguments[-1]
            return subprocess.CompletedProcess(
                arguments,
                1 if mime == "text/plain" else 0,
                stdout=b"" if mime == "text/plain" else b"png",
            )

        self.assertEqual(
            agent.WaylandClipboard(run).read(),
            agent.ClipboardContent("png", b"png"),
        )

    def test_reconnect_loop_and_watcher_restart(self):
        attempts = []
        delays = []

        def session(port):
            attempts.append(port)
            if len(attempts) < 3:
                raise OSError("disconnected")

        agent.run_forever("fake-port", session=session, delay=delays.append, stop_after=3)
        self.assertEqual(attempts, ["fake-port"] * 3)
        self.assertEqual(delays, [0.5, 0.5])

        class Watcher:
            def poll(self):
                return 1

        replacement = object()
        self.assertIs(
            agent.restart_watcher_if_needed(Watcher(), "fifo", lambda _: replacement),
            replacement,
        )

    def test_nonblocking_write_waits_for_backpressure(self):
        written = []
        attempts = 0

        def partial_write(descriptor, remaining):
            nonlocal attempts
            attempts += 1
            if attempts == 1:
                raise BlockingIOError()
            chunk = bytes(remaining[:2])
            written.append(chunk)
            return len(chunk)

        with mock.patch.object(agent.os, "write", side_effect=partial_write), \
             mock.patch.object(agent.select, "select", return_value=([], [7], [])) as wait:
            agent.write_all(7, b"payload")
        self.assertEqual(b"".join(written), b"payload")
        wait.assert_called_once_with([], [7], [])

    def test_home_manager_service_is_restartable(self):
        module = Path(os.environ.get("BENTO_CLIPBOARD_MODULE", SOURCE.parent / "clipboard.nix")).read_text()
        self.assertIn('Restart = "always";', module)
        self.assertIn("dev.bento.clipboard", module)


if __name__ == "__main__":
    unittest.main()

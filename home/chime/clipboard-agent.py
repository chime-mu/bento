#!/usr/bin/env python3
"""Bento guest clipboard agent.

The wire format is versioned newline-delimited JSON. Clipboard contents are never logged.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import json
import os
import select
import selectors
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import BinaryIO, Callable

VERSION = 1
MAX_PAYLOAD = 16 * 1024 * 1024
MAX_BASE64 = ((MAX_PAYLOAD + 2) // 3) * 4
MAX_LINE = MAX_BASE64 + 4096
PORT = "/dev/virtio-ports/dev.bento.clipboard"


class ProtocolError(ValueError):
    pass


@dataclass(frozen=True)
class ClipboardContent:
    kind: str
    data: bytes

    def __post_init__(self) -> None:
        if self.kind not in ("text", "png"):
            raise ProtocolError("unsupported clipboard kind")
        if len(self.data) > MAX_PAYLOAD:
            raise ProtocolError("clipboard payload exceeds 16 MiB")
        if self.kind == "text":
            try:
                self.data.decode("utf-8")
            except UnicodeDecodeError as error:
                raise ProtocolError("clipboard text is not UTF-8") from error

    @property
    def fingerprint(self) -> str:
        return hashlib.sha256(self.kind.encode() + b"\0" + self.data).hexdigest()


def encode_sync() -> bytes:
    return json.dumps({"version": VERSION, "type": "sync"}, separators=(",", ":")).encode() + b"\n"


def encode_clipboard(content: ClipboardContent) -> bytes:
    message = {
        "version": VERSION,
        "type": "clipboard",
        "kind": content.kind,
        "data": base64.b64encode(content.data).decode("ascii"),
        "sha256": content.fingerprint,
    }
    return json.dumps(message, separators=(",", ":"), sort_keys=True).encode() + b"\n"


def decode_message(line: bytes) -> tuple[str, ClipboardContent | None]:
    if len(line) > MAX_LINE:
        raise ProtocolError("oversized clipboard message")
    try:
        value = json.loads(line)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ProtocolError("malformed clipboard message") from error
    if not isinstance(value, dict) or value.get("version") != VERSION:
        raise ProtocolError("unsupported clipboard protocol version")
    if value.get("type") == "sync":
        return "sync", None
    if value.get("type") != "clipboard" or value.get("kind") not in ("text", "png"):
        raise ProtocolError("unsupported clipboard message")
    encoded = value.get("data")
    expected = value.get("sha256")
    if not isinstance(encoded, str) or not isinstance(expected, str):
        raise ProtocolError("malformed clipboard message")
    if len(encoded.encode("ascii", "ignore")) > MAX_BASE64:
        raise ProtocolError("oversized clipboard payload")
    try:
        data = base64.b64decode(encoded, validate=True)
    except (binascii.Error, ValueError) as error:
        raise ProtocolError("invalid clipboard base64 data") from error
    content = ClipboardContent(value["kind"], data)
    if content.fingerprint != expected:
        raise ProtocolError("clipboard fingerprint mismatch")
    return "clipboard", content


class NDJSONFramer:
    def __init__(self) -> None:
        self.buffer = bytearray()

    def feed(self, fragment: bytes) -> list[bytes]:
        self.buffer.extend(fragment)
        lines: list[bytes] = []
        while True:
            try:
                newline = self.buffer.index(0x0A)
            except ValueError:
                break
            line = bytes(self.buffer[:newline])
            del self.buffer[: newline + 1]
            if len(line) > MAX_LINE:
                raise ProtocolError("oversized clipboard message")
            if line:
                lines.append(line)
        if len(self.buffer) > MAX_LINE:
            raise ProtocolError("oversized clipboard message")
        return lines


class EchoSuppressor:
    def __init__(self) -> None:
        self.last_sent: str | None = None
        self.last_applied: str | None = None

    def should_send_local(self, fingerprint: str) -> bool:
        if self.last_applied is not None:
            applied = self.last_applied
            self.last_applied = None
            if fingerprint == applied:
                self.last_sent = fingerprint
                return False

            # A different Wayland value after applying remote content is a real
            # local change, even when it matches something sent earlier.
            self.last_sent = fingerprint
            return True
        if fingerprint == self.last_sent:
            return False
        self.last_sent = fingerprint
        return True

    def should_apply_remote(self, fingerprint: str) -> bool:
        if fingerprint in (self.last_sent, self.last_applied):
            return False
        self.last_applied = fingerprint
        return True


class WaylandClipboard:
    def __init__(self, run: Callable[..., subprocess.CompletedProcess[bytes]] = subprocess.run) -> None:
        self.run = run

    def read(self) -> ClipboardContent | None:
        text = self.run(
            ["wl-paste", "--no-newline", "--type", "text/plain"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        if text.returncode == 0:
            return ClipboardContent("text", text.stdout)
        png = self.run(
            ["wl-paste", "--no-newline", "--type", "image/png"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        if png.returncode == 0:
            return ClipboardContent("png", png.stdout)
        return None

    def write(self, content: ClipboardContent) -> None:
        mime = "text/plain;charset=utf-8" if content.kind == "text" else "image/png"
        self.run(
            ["wl-copy", "--type", mime],
            input=content.data,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=True,
        )


class ClipboardAgent:
    def __init__(self, clipboard: WaylandClipboard, send: Callable[[bytes], None]) -> None:
        self.clipboard = clipboard
        self.send = send
        self.suppressor = EchoSuppressor()
        self.ready = False

    def connected(self) -> None:
        # Ask the Mac for its clipboard. Local watcher events stay muted until the host's
        # sync marker arrives, so connection setup always initializes Mac -> guest.
        self.ready = False
        self.send(encode_sync())

    def receive(self, line: bytes) -> None:
        message_type, content = decode_message(line)
        if message_type == "sync":
            self.ready = True
            return
        assert content is not None
        if self.suppressor.should_apply_remote(content.fingerprint):
            self.clipboard.write(content)

    def local_changed(self) -> None:
        if not self.ready:
            return
        content = self.clipboard.read()
        if content is not None and self.suppressor.should_send_local(content.fingerprint):
            self.send(encode_clipboard(content))


def write_all(descriptor: int, data: bytes) -> None:
    view = memoryview(data)
    while view:
        try:
            written = os.write(descriptor, view)
        except BlockingIOError:
            # The virtio port is deliberately nonblocking so disconnects cannot wedge
            # the session reader. A near-limit payload can fill its transmit queue;
            # wait for backpressure to clear rather than dropping the clipboard.
            select.select([], [descriptor], [])
            continue
        except InterruptedError:
            continue
        if written == 0:
            raise OSError("clipboard port accepted no data")
        view = view[written:]


def notify(fifo: str) -> int:
    # wl-paste supplies the clipboard on stdin. Discard it: the main process queries text
    # first and PNG second, independent of which MIME caused this notification.
    while sys.stdin.buffer.read(64 * 1024):
        pass
    with open(fifo, "wb", buffering=0) as stream:
        stream.write(b"1")
    return 0


def start_watcher(fifo: str) -> subprocess.Popen[bytes]:
    return subprocess.Popen(
        ["wl-paste", "--watch", sys.executable, os.path.abspath(__file__), "--notify", fifo],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def restart_watcher_if_needed(
    watcher: subprocess.Popen[bytes],
    fifo: str,
    starter: Callable[[str], subprocess.Popen[bytes]] = start_watcher,
) -> subprocess.Popen[bytes]:
    return starter(fifo) if watcher.poll() is not None else watcher


def run_session(port: str, clipboard: WaylandClipboard | None = None) -> None:
    descriptor = os.open(port, os.O_RDWR | os.O_NONBLOCK)
    runtime = os.environ.get("XDG_RUNTIME_DIR", tempfile.gettempdir())
    fifo = os.path.join(runtime, f"bento-clipboard-{os.getpid()}.fifo")
    os.mkfifo(fifo, 0o600)
    fifo_descriptor = os.open(fifo, os.O_RDWR | os.O_NONBLOCK)
    watcher = start_watcher(fifo)
    selector = selectors.DefaultSelector()
    selector.register(descriptor, selectors.EVENT_READ, "port")
    selector.register(fifo_descriptor, selectors.EVENT_READ, "clipboard")
    framer = NDJSONFramer()
    agent = ClipboardAgent(clipboard or WaylandClipboard(), lambda data: write_all(descriptor, data))
    agent.connected()
    try:
        while True:
            watcher = restart_watcher_if_needed(watcher, fifo)
            for key, _ in selector.select(timeout=0.25):
                if key.data == "clipboard":
                    try:
                        while os.read(fifo_descriptor, 4096):
                            pass
                    except BlockingIOError:
                        pass
                    agent.local_changed()
                else:
                    try:
                        fragment = os.read(descriptor, 64 * 1024)
                    except BlockingIOError:
                        continue
                    if not fragment:
                        return
                    for line in framer.feed(fragment):
                        try:
                            agent.receive(line)
                        except ProtocolError:
                            continue
    finally:
        watcher.terminate()
        try:
            watcher.wait(timeout=1)
        except subprocess.TimeoutExpired:
            watcher.kill()
        selector.close()
        os.close(fifo_descriptor)
        os.close(descriptor)
        Path(fifo).unlink(missing_ok=True)


def run_forever(
    port: str,
    session: Callable[[str], None] = run_session,
    delay: Callable[[float], None] = time.sleep,
    stop_after: int | None = None,
) -> None:
    attempts = 0
    while stop_after is None or attempts < stop_after:
        try:
            session(port)
        except (OSError, ProtocolError, subprocess.SubprocessError):
            pass
        attempts += 1
        if stop_after is None or attempts < stop_after:
            delay(0.5)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", default=PORT)
    parser.add_argument("--notify")
    arguments = parser.parse_args()
    if arguments.notify:
        return notify(arguments.notify)
    run_forever(arguments.port)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

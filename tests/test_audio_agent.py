import importlib.util
import json
import os
import unittest
from pathlib import Path
from unittest import mock


REPOSITORY = Path(__file__).parents[1]
SOURCE = Path(os.environ.get(
    "BENTO_AUDIO_AGENT",
    REPOSITORY / "hosts/bento-vm/audio-agent.py",
))
AUDIO_MODULE = Path(os.environ.get(
    "BENTO_AUDIO_MODULE",
    REPOSITORY / "hosts/bento-vm/audio.nix",
))
WAYBAR_MODULE = Path(os.environ.get(
    "BENTO_WAYBAR_MODULE",
    REPOSITORY / "home/chime/waybar.nix",
))
SPEC = importlib.util.spec_from_file_location("bento_audio_agent", SOURCE)
agent = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(agent)


class PactlStub:
    sink = "alsa_output.pci.analog-stereo"
    source = "alsa_input.pci.analog-stereo"

    def __init__(self):
        self.calls = []
        self.loaded = set()
        self.next_id = 100
        self.default_sink = self.sink
        self.default_source = self.source

    def __call__(self, *arguments, check=True):
        self.calls.append(arguments)
        if arguments == ("list", "short", "sinks"):
            return f"1\t{self.sink}\talsa\ts16le\tRUNNING\n"
        if arguments == ("list", "short", "sources"):
            return f"2\t{self.source}\talsa\ts16le\tRUNNING\n"
        if arguments == ("list", "short", "modules"):
            return "\n".join(f"{item}\tmodule" for item in self.loaded)
        if arguments[0] == "load-module":
            result = str(self.next_id)
            self.next_id += 1
            self.loaded.add(result)
            return result
        if arguments[0] == "unload-module":
            self.loaded.discard(arguments[1])
            return ""
        if arguments[0] == "set-default-sink":
            self.default_sink = arguments[1]
            return ""
        if arguments[0] == "set-default-source":
            self.default_source = arguments[1]
            return ""
        if arguments == ("get-default-sink",):
            return self.default_sink
        if arguments == ("get-default-source",):
            return self.default_source
        raise AssertionError(arguments)


def catalog():
    return {
        "type": "catalog",
        "outputs": [{"deviceUID": "speaker", "name": "Studio Display"}],
        "inputs": [{"deviceUID": "mic", "name": "Desk Microphone"}],
        "selectedOutputUID": "speaker",
        "selectedInputUID": None,
    }


class AudioAgentTests(unittest.TestCase):
    def make_mirror(self):
        sent = []
        pactl = PactlStub()
        patcher = mock.patch.object(agent, "run_pactl", side_effect=pactl)
        patcher.start()
        self.addCleanup(patcher.stop)
        mirror = agent.PipeWireMirror(sent.append)
        self.addCleanup(mirror.close)
        return mirror, pactl, sent

    def test_catalog_is_strict_newline_delimited_json(self):
        encoded = agent.encode_message({"type": "get-catalog"})
        self.assertTrue(encoded.endswith(b"\n"))
        self.assertEqual(json.loads(encoded), {"type": "get-catalog"})
        self.assertEqual(agent.decode_catalog(json.dumps(catalog()).encode()), catalog())
        invalid = catalog() | {"extra": True}
        with self.assertRaises(ValueError):
            agent.decode_catalog(json.dumps(invalid).encode())
        with self.assertRaises((ValueError, json.JSONDecodeError)):
            agent.decode_catalog(b"not-json")

    def test_mirrors_system_default_and_physical_mac_devices(self):
        mirror, pactl, _ = self.make_mirror()
        mirror.apply(catalog())
        sink_loads = [call for call in pactl.calls if call[:2] == ("load-module", "module-remap-sink")]
        source_loads = [call for call in pactl.calls if call[:2] == ("load-module", "module-remap-source")]
        self.assertEqual(len(sink_loads), 2)
        self.assertEqual(len(source_loads), 2)
        self.assertTrue(all(f"master={pactl.sink}" in call for call in sink_loads))
        self.assertTrue(all(f"master={pactl.source}" in call for call in source_loads))
        self.assertEqual(pactl.default_sink, agent.endpoint_name("output", "speaker"))
        self.assertEqual(pactl.default_source, agent.endpoint_name("input", None))

    def test_guest_device_choices_send_stable_uid_routes(self):
        mirror, pactl, sent = self.make_mirror()
        mirror.apply(catalog())
        sent.clear()
        mirror.last_health_check = float("inf")
        pactl.default_sink = agent.endpoint_name("output", None)
        pactl.default_source = agent.endpoint_name("input", "mic")
        mirror.poll_selection()
        self.assertEqual(sent, [
            {"type": "select", "direction": "output", "deviceUID": None},
            {"type": "select", "direction": "input", "deviceUID": "mic"},
        ])

    def test_lost_pipewire_modules_request_catalog_rebuild(self):
        mirror, pactl, sent = self.make_mirror()
        mirror.apply(catalog())
        sent.clear()
        pactl.loaded.clear()
        mirror.last_health_check = 0
        with mock.patch.object(agent.time, "monotonic", return_value=3):
            mirror.poll_selection()
        self.assertEqual(sent, [{"type": "get-catalog"}])

    def test_port_wait_and_service_configuration(self):
        with mock.patch.object(agent.os, "open", side_effect=[FileNotFoundError(), 17]), \
             mock.patch.object(agent.time, "sleep") as sleep:
            self.assertEqual(agent.open_port(), 17)
            sleep.assert_called_once_with(1)

        module = AUDIO_MODULE.read_text()
        waybar = WAYBAR_MODULE.read_text()
        self.assertIn("dev.bento.audio", module)
        self.assertIn('default.clock.quantum     = 4096', module)
        self.assertIn('Restart = "on-failure";', module)
        self.assertIn("pavucontrol", module)
        self.assertIn('on-click = "pavucontrol";', waybar)
        self.assertIn("@DEFAULT_AUDIO_SOURCE@ toggle", waybar)


if __name__ == "__main__":
    unittest.main()

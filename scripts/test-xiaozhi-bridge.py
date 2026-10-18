#!/usr/bin/env python3
"""Offline contract checks; no microphone capture or cloud requests."""
import importlib.util
import json
import math
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from types import SimpleNamespace
sys.dont_write_bytecode = True

BRIDGE = Path(__file__).resolve().parents[1] / 'TodoIsland/Resources/xiaozhi_voice_bridge.py'
spec = importlib.util.spec_from_file_location('bridge', BRIDGE)
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


class BridgeTests(unittest.TestCase):
    def test_noise_gate_and_finite_bounded_meter(self):
        for rms in [0, -1, .001, math.nan, math.inf]:
            self.assertEqual(bridge.normalized_level(rms), 0)
        self.assertGreater(bridge.normalized_level(.1), .5)
        self.assertEqual(bridge.normalized_level(10), 1)

    def test_reopening_uses_current_defaults_and_bluetooth_native_rates(self):
        # Changing the system default changes the next selection. No saved client
        # name or stale cached sample-rate is an input to this policy.
        routes = {
            'input': dict(index=0, name='Built-in Mic', default_samplerate=48000, max_input_channels=1),
            'output': dict(index=1, name='Built-in Speakers', default_samplerate=48000, max_output_channels=2),
        }
        sd = SimpleNamespace(query_devices=lambda *, kind: routes[kind])
        built_in = bridge.system_device_config(sd, SimpleNamespace, 20)
        self.assertEqual((built_in.input_device_id, built_in.output_device_id), (0, 1))
        routes['input'] = dict(index=4, name='Headset', default_samplerate=24000, max_input_channels=1)
        routes['output'] = dict(index=5, name='Headset', default_samplerate=48000, max_output_channels=2)
        headset = bridge.system_device_config(sd, SimpleNamespace, 20)
        self.assertEqual((headset.input_device_id, headset.output_device_id), (4, 5))
        self.assertEqual((headset.input_sample_rate, headset.output_sample_rate), (24000, 48000))
        self.assertEqual((headset.input_frame_size, headset.output_frame_size), (480, 960))
        routes['input'] = dict(index=0, name='Built-in Mic', default_samplerate=48000, max_input_channels=1)
        mixed = bridge.system_device_config(sd, SimpleNamespace, 20)
        self.assertEqual((mixed.input_device_id, mixed.output_device_id), (0, 5),
            'Output headphones must not force changing the chosen system microphone')

    def test_unavailable_default_fails_instead_of_silently_using_speakers(self):
        sd = SimpleNamespace(query_devices=lambda **_: dict(index=-1, default_samplerate=0, max_input_channels=0))
        with self.assertRaises(RuntimeError):
            bridge.system_device_config(sd, SimpleNamespace, 20)

    def test_missing_binding_never_creates_identity_or_opens_audio(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([sys.executable, str(BRIDGE), directory, directory], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(json.loads(result.stdout), {'type': 'error', 'code': 'not_bound'})
            self.assertEqual(list(Path(directory).iterdir()), [])


if __name__ == '__main__':
    unittest.main()

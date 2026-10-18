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

    def test_missing_binding_never_creates_identity_or_opens_audio(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([sys.executable, str(BRIDGE), directory, directory], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(json.loads(result.stdout), {'type': 'error', 'code': 'not_bound'})
            self.assertEqual(list(Path(directory).iterdir()), [])


if __name__ == '__main__':
    unittest.main()

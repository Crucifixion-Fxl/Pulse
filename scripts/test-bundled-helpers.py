#!/usr/bin/env python3
"""Probe real bundled helpers with synthetic input; no account or media data."""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPERS = ROOT / 'Pulse/Resources/Helpers'


class BundledHelperTests(unittest.TestCase):
    def test_helpers_target_macos_14_and_arm64(self):
        for name in ('AgentHookBridge', 'MediaRemoteHelper.dylib'):
            binary = str(HELPERS / name)
            subprocess.run(['lipo', binary, '-verify_arch', 'arm64'], check=True)
            info = subprocess.check_output(['xcrun', 'vtool', '-show-build', binary], text=True)
            self.assertIn('minos 14.0', info)
            subprocess.run(['codesign', '--verify', '--strict', binary], check=True)

    def test_media_helper_loads_and_exports_bootstrap(self):
        # Exercise the same loader as NowPlayingController without starting
        # capture, keyboard taps, playback controls or the media service.
        loader = r'''
use DynaLoader;
my $lib = DynaLoader::dl_load_file(shift) or die DynaLoader::dl_error();
for my $symbol ('bootstrap', 'ti_mediahelper_main') {
  DynaLoader::dl_find_symbol($lib, $symbol) or die "Missing $symbol";
}
'''
        subprocess.run(['/usr/bin/perl', '-e', loader, str(HELPERS / 'MediaRemoteHelper.dylib')],
                       check=True, timeout=10)

    def test_agent_bridge_delivers_event_to_private_socket(self):
        with tempfile.TemporaryDirectory(prefix='pulse-bridge-', dir='/tmp') as directory:
            address = str(Path(directory) / 'test.sock')
            with socket.socket(socket.AF_UNIX) as server:
                server.bind(address)
                server.listen(1)
                server.settimeout(8)
                environment = dict(os.environ, DOISLAND_AGENTS_SOCKET_PATH=address)
                environment.pop('DOISLAND_AGENTS_SKIP', None)
                payload = {'session_id': 'pulse-build-smoke', 'cwd': directory}
                child = subprocess.Popen([str(HELPERS / 'AgentHookBridge'), '--source', 'codex',
                                          '--event', 'SessionStart'], stdin=subprocess.PIPE,
                                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment)
                try:
                    child.stdin.write(json.dumps(payload).encode())
                    child.stdin.close()
                    with server.accept()[0] as client:
                        client.settimeout(5)
                        chunks = []
                        while chunk := client.recv(65536):
                            chunks.append(chunk)
                        event = json.loads(b''.join(chunks))
                        self.assertEqual(event['session_id'], 'pulse-build-smoke')
                        client.sendall(b'{}\n')
                    self.assertEqual(child.wait(timeout=5), 0)
                finally:
                    if child.poll() is None:
                        child.kill()
                        child.wait()
                    child.stdout.close()
                    child.stderr.close()


if __name__ == '__main__':
    unittest.main()

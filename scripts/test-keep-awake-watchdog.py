#!/usr/bin/env python3
"""Run the shipped watchdog against fake power/launchd commands, without root."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'helpers/keep-awake/KeepAwakeWatchdog.sh'


class WatchdogTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.base = self.root / 'lease'
        self.base.mkdir()
        self.request = self.root / 'request'
        self.request.write_text('running')
        self.state = self.root / 'power'
        self.state.write_text('0')
        (self.root / 'battery').write_text("Now drawing from 'AC Power'\n100%; charged")
        self.plists = self.root / 'LaunchDaemons'
        self.plists.mkdir()
        (self.plists / 'test.plist').write_text('fixture')
        (self.base / 'status').write_text('armed')
        (self.base / 'config').write_text('2000\n1234\n501\nTEST START\n' + str(self.request) + '\n')
        self.command('pmset', '''#!/bin/sh
case "$*" in
  '-g') printf 'SleepDisabled %s\\n' "$(cat "$FIXTURE/power")" ;;
  '-g batt') cat "$FIXTURE/battery" ;;
  '-a disablesleep 1') echo enable >> "$FIXTURE/trace"; echo 1 > "$FIXTURE/power" ;;
  '-a disablesleep 0') echo restore >> "$FIXTURE/trace"; [ ! -f "$FIXTURE/fail-restore" ] || exit 1; echo 0 > "$FIXTURE/power" ;;
  *) exit 98 ;;
esac
''')
        self.command('launchctl', '#!/bin/sh\necho unload >> "$FIXTURE/trace"\n')
        self.command('date', '#!/bin/sh\necho 1000\n')
        self.command('sleep', '''#!/bin/sh
if [ -f "$FIXTURE/revert" ]; then echo 0 > "$FIXTURE/power"; fi
if [ -f "$FIXTURE/stop-during-start" ]; then echo stop > "$FIXTURE/request"; fi
''')
        self.command('ps', '''#!/bin/sh
if [ -f "$FIXTURE/dead" ]; then exit 1; fi
case "$*" in *uid=*) echo 501 ;; *lstart=*) echo 'TEST START' ;; *) exit 99 ;; esac
''')
        source = SOURCE.read_text().replace('/Library/LaunchDaemons', str(self.plists))
        for name, original in [('pmset','/usr/bin/pmset'),('launchctl','/bin/launchctl'),
                               ('date','/bin/date'),('sleep','/bin/sleep'),('ps','/bin/ps')]:
            source = source.replace(original, str(self.root / name))
        self.script = self.root / 'watchdog.sh'
        self.script.write_text(source)

    def command(self, name, text):
        file = self.root / name
        file.write_text(text)
        file.chmod(0o755)

    def run_tick(self):
        result = subprocess.run(['/bin/sh', str(self.script), str(self.base), 'test'],
                                env={**os.environ, 'FIXTURE': str(self.root)}, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        return (self.base / 'status').read_text().strip()

    def test_start_then_manual_stop_restores_and_unloads(self):
        self.assertEqual(self.run_tick(), 'active')
        self.assertEqual(self.state.read_text().strip(), '1')
        self.assertTrue((self.base / 'owned').exists())
        self.request.write_text('stop')
        self.assertEqual(self.run_tick(), 'stopped')
        self.assertEqual(self.state.read_text().strip(), '0')
        self.assertFalse((self.base / 'owned').exists())
        self.assertFalse((self.plists / 'test.plist').exists())

    def test_deadline_is_enforced_by_helper(self):
        self.run_tick()
        p = self.base / 'config'
        p.write_text(p.read_text().replace('2000', '999'))
        self.assertEqual(self.run_tick(), 'expired')
        self.assertEqual(self.state.read_text().strip(), '0')

    def test_crash_or_reboot_owner_missing_restores(self):
        self.run_tick()
        (self.root / 'dead').touch()
        self.assertEqual(self.run_tick(), 'owner-exited')
        self.assertEqual(self.state.read_text().strip(), '0')

    def test_recycled_pid_cannot_keep_session_alive(self):
        self.run_tick()
        p = self.base / 'config'
        p.write_text(p.read_text().replace('TEST START', 'OLDER PROCESS'))
        self.assertEqual(self.run_tick(), 'owner-exited')

    def test_restore_failure_keeps_journal_and_retries(self):
        self.run_tick()
        self.request.write_text('stop')
        (self.root / 'fail-restore').touch()
        self.assertEqual(self.run_tick(), 'restore-failed')
        self.assertTrue((self.base / 'owned').exists())
        self.assertTrue((self.plists / 'test.plist').exists())
        (self.root / 'fail-restore').unlink()
        self.assertEqual(self.run_tick(), 'interrupted')
        self.assertFalse((self.base / 'owned').exists())

    def test_existing_sleep_override_is_not_owned_or_changed(self):
        self.state.write_text('1')
        self.assertEqual(self.run_tick(), 'conflict')
        self.assertEqual(self.state.read_text(), '1')
        self.assertFalse((self.base / 'owned').exists())

    def test_os_reverting_override_cannot_report_active(self):
        (self.root / 'revert').touch()
        self.assertEqual(self.run_tick(), 'unsupported')
        self.assertEqual(self.state.read_text().strip(), '0')

    def test_stop_during_start_does_not_report_active(self):
        (self.root / 'stop-during-start').touch()
        self.assertEqual(self.run_tick(), 'stopped')

    def test_low_battery_ends_session(self):
        self.run_tick()
        (self.root / 'battery').write_text("Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1)\t10%; discharging")
        self.assertEqual(self.run_tick(), 'low-battery')
        self.assertEqual(self.state.read_text().strip(), '0')

    def test_interrupted_power_write_restores_before_other_actions(self):
        (self.base / 'status').write_text('starting')
        (self.base / 'owned').touch()
        self.state.write_text('1')
        self.assertEqual(self.run_tick(), 'interrupted')
        self.assertEqual(self.state.read_text().strip(), '0')

    def test_request_cannot_extend_or_execute_shell(self):
        self.run_tick()
        self.request.write_text('running; touch ' + str(self.root / 'injected'))
        self.assertEqual(self.run_tick(), 'stopped')
        self.assertFalse((self.root / 'injected').exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)

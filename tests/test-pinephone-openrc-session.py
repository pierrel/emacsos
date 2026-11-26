"""Exercise the real session checks and cleanup with isolated child stubs."""
from pathlib import Path
import os
import signal
import subprocess
import tempfile
import time
import unittest

SOURCE = (Path(__file__).resolve().parents[1] / 'deploy/pinephone/openrc-session').read_text()
CLEANUP = SOURCE[SOURCE.index('cleanup() {'):SOURCE.index('\ntrap cleanup EXIT')]
RUNTIME = SOURCE[SOURCE.index('while :; do\n') + len('while :; do\n'):SOURCE.index('    sleep 30 &')]
STARTUP = SOURCE[SOURCE.index('attempt=0\n', SOURCE.index('emacs_pid=$!')):SOURCE.index('power_ready=$runtime/power-ready')]

# Only the temporary directory and stub children are reachable from these pieces.
HEADER = '''set -eu
runtime=$1
probe_file=$runtime/probe
keyboard_pid=1; emacs_pid=2; sway_pid=3; power_pid=4; idle_pid=5
pipewire_pid=6; wireplumber_pid=7; pulse_pid=8; dbus_pid=9
timer_pid=; sms_pid=; sway_socket=; wayland_socket=; dbus_address_file=; power_ready=
fail() { printf '%s\\n' "$1"; exit 1; }
kill() { [ "$1" != -0 ]; }
wait() { printf '%s\\n' "$1" >>"$runtime/waited"; }
killall() { :; }
timeout() { return 1; }
sleep() { :; }
probe_sway() { printf '%s\\n' '{"app_id":"emacs","active": true}' >"$probe_file"; }
probe_emacs() { return 1; }
'''


class SessionTests(unittest.TestCase):
    def run_piece(self, directory, piece):
        return subprocess.run(['sh', '-c', HEADER + CLEANUP + '\n' + piece,
                               'session-fixture', str(directory)],
                              capture_output=True, text=True, timeout=3)

    def test_runtime_busy_and_required_process_exit(self):
        with tempfile.TemporaryDirectory() as directory:
            alive = 'kill() { return 0; }\n'
            result = self.run_piece(directory, alive + RUNTIME)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            dead = 'kill() { return 1; }\n'
            result = self.run_piece(directory, dead + RUNTIME)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('a required UI process exited', result.stdout)

    def test_actual_idle_launch_blanks_at_60_then_requests_at_240(self):
        start = SOURCE.index('"$root/process-group" /usr/bin/swayidle -w')
        launch = SOURCE[start:SOURCE.index('\nidle_pid=$!', start)]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            capture = root / 'idle-argv'
            wrapper = root / 'process-group'
            wrapper.write_text('#!/bin/sh\nprintf "%s\n" "$@" > "$CAPTURE"\n')
            wrapper.chmod(0o755)
            result = subprocess.run(
                ['/bin/sh', '-c', 'root=$1; CAPTURE=$2; export CAPTURE\n' + launch + '\nwait',
                 'idle-launch-fixture', str(root), str(capture)],
                capture_output=True, text=True, timeout=3)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            argv = capture.read_text().splitlines()
            self.assertEqual(argv, ['/usr/bin/swayidle', '-w', 'timeout', '60',
                                    str(root) + '/session-power idle-blank', 'timeout', '240',
                                    'doas -n /usr/local/sbin/emacsos-openrc-suspend request',
                                    'resume', str(root) + '/session-power resume'])

    def test_startup_still_requires_responsive_emacs(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.run_piece(directory, 'kill() { return 0; }\n' + STARTUP)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Emacs server did not become ready', result.stdout)

    def test_respawn_discards_stale_monitor_readiness_before_child_runs(self):
        start = SOURCE.index('power_ready=$runtime/power-ready')
        startup = SOURCE[start:SOURCE.index('# Optional configured SMS', start)]
        launch = '"$root/process-group" "$root/session-power" monitor >"$power_ready" &'
        # Hold the child before its redirection, a legal scheduling point after &.
        startup = startup.replace(launch, '{ read gate <"$root/launch-gate";\n' +
                                  launch[:-1] + '\n} &')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'power-ready').write_text('ready\n')
            os.mkfifo(root / 'launch-gate')
            (root / 'process-group').write_text('#!/bin/sh\nexec "$@"\n')
            (root / 'session-power').write_text(
                '#!/bin/sh\nif [ "$1" = monitor ]; then\n'
                'touch "$TEST_ROOT/registered"; echo ready; sleep 30\n'
                'else touch "$TEST_ROOT/display"; fi\n')
            for name in ('process-group', 'session-power'):
                (root / name).chmod(0o755)
            script = ('set -eu\nroot=$1; runtime=$1; export TEST_ROOT=$1\n'
                      'fail() { exit 1; }\n'
                      'grep() { if command grep "$@"; then result=ready; rc=0; '
                      'else result=not-ready; rc=1; fi; '
                      'if [ ! -e "$root/checked" ]; then '
                      'printf "%s\\n" "$result" >"$root/first-read"; '
                      'touch "$root/checked"; fi; return "$rc"; }\n' +
                      startup + '\nwait "$power_pid"\n')
            process = subprocess.Popen(['/bin/sh', '-c', script, 'respawn', directory],
                                       start_new_session=True,
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                # Parent reaches its first readiness read while child cannot run.
                deadline = time.monotonic() + 2
                while not (root / 'checked').exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue((root / 'checked').exists())
                self.assertEqual((root / 'first-read').read_text(), 'not-ready\n',
                                 'first readiness read accepted the interrupted attempt token')
                self.assertFalse((root / 'display').exists(),
                                 'stale token admitted display before fresh monitor registration')
                with (root / 'launch-gate').open('w') as gate:
                    gate.write('continue\n')
                deadline = time.monotonic() + 2
                while not (root / 'display').exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue((root / 'registered').exists())
                self.assertTrue((root / 'display').exists())
            finally:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()



if __name__ == '__main__':
    unittest.main()

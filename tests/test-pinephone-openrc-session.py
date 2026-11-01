"""Exercise the real session checks and cleanup with isolated child stubs."""
from pathlib import Path
import subprocess
import tempfile
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

    def test_startup_still_requires_responsive_emacs(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.run_piece(directory, 'kill() { return 0; }\n' + STARTUP)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Emacs server did not become ready', result.stdout)



if __name__ == '__main__':
    unittest.main()

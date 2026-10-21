"""Exercise the real session checks and cleanup with isolated child stubs."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

SOURCE = (Path(__file__).resolve().parents[1] / 'deploy/pinephone/openrc-session').read_text()
CLEANUP = SOURCE[SOURCE.index('cleanup() {'):SOURCE.index('\ntrap cleanup EXIT')]
CREATE_FIFO = SOURCE[SOURCE.index('mkfifo -m 0600'):SOURCE.index('"$root/process-group" "$root/session-power" monitor')]
RUNTIME = SOURCE[SOURCE.index('while :; do\n') + len('while :; do\n'):SOURCE.index('    sleep 30 &')]
STARTUP = SOURCE[SOURCE.index('attempt=0\n', SOURCE.index('emacs_pid=$!')):SOURCE.index('mkfifo -m 0600')]

# Only the temporary directory and stub children are reachable from these pieces.
HEADER = '''set -eu
runtime=$1
probe_file=$runtime/probe
keyboard_pid=1; emacs_pid=2; sway_pid=3; power_pid=4; idle_pid=5
pipewire_pid=6; wireplumber_pid=7; pulse_pid=8; dbus_pid=9
timer_pid=; sway_socket=; wayland_socket=; dbus_address_file=; power_fifo=
fail() { printf '%s\\n' "$1"; exit 1; }
kill() { [ "$1" != -0 ]; }
wait() { printf '%s\\n' "$1" >>"$runtime/waited"; }
killall() { :; }
timeout() { return 1; }
sleep() { :; }
probe_sway() { printf '%s\\n' '{"app_id":"emacs","active": true}' >"$probe_file"; }
probe_emacs() { return 1; }
rm() {
    if [ "${3-}" = "$runtime/power-events" ]; then
        grep -Fx 4 "$runtime/waited" >/dev/null
        grep -Fx 5 "$runtime/waited" >/dev/null
    fi
    command rm "$@"
}
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

    def test_owned_fifo_is_removed_after_readers_and_can_be_recreated(self):
        with tempfile.TemporaryDirectory() as directory:
            for _ in range(2):
                Path(directory, 'waited').unlink(missing_ok=True)
                result = self.run_piece(directory, CREATE_FIFO + '\ncleanup\n')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse(Path(directory, 'power-events').exists())

    def test_failed_creation_preserves_existing_fifo(self):
        with tempfile.TemporaryDirectory() as directory:
            fifo = Path(directory, 'power-events')
            os.mkfifo(fifo)
            inode = fifo.stat().st_ino
            result = self.run_piece(directory, 'trap cleanup EXIT\n' + CREATE_FIFO)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(fifo.stat().st_ino, inode)

    def test_cleanup_preserves_unowned_or_replaced_objects(self):
        for kind in ('fifo', 'file', 'symlink'):
            for owned in (False, True):
                with self.subTest(kind=kind, owned=owned), tempfile.TemporaryDirectory() as directory:
                    fifo = Path(directory, 'power-events')
                    target = Path(directory, 'target')
                    target.write_text('preserve')
                    if kind == 'fifo':
                        if owned:  # The owned FIFO's removal is covered above.
                            continue
                        os.mkfifo(fifo)
                    elif kind == 'file':
                        fifo.write_text('preserve')
                    else:
                        fifo.symlink_to(target)
                    inode = fifo.lstat().st_ino
                    flag = 'power_fifo=' + shlex.quote(str(fifo)) + '\n' if owned else ''
                    result = self.run_piece(directory, flag + 'cleanup\n')
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(fifo.lstat().st_ino, inode)
                    self.assertEqual(target.read_text(), 'preserve')


if __name__ == '__main__':
    unittest.main()

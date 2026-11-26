"""Real helper processes/locks with fixed private I/O sinks, not kernel sleep."""
import fcntl
import os
from pathlib import Path
import pwd
import shutil
import subprocess
import tempfile
import time
import unittest

SOURCE = Path('/source')


class SuspendPolicy(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='phone-policy-')
        self.root = Path(self.temp.name)
        self.root.chmod(0o755)
        user = pwd.getpwnam('emacsos-lab')
        self.uid, self.gid = user.pw_uid, user.pw_gid
        self.runtime = self.root / 'runtime'
        self.runtime.mkdir(mode=0o700)
        os.chown(self.runtime, self.uid, self.gid)
        self.state = self.runtime / 'power-state'
        self.state.write_bytes(b'blank\n')
        self.state.chmod(0o600)
        os.chown(self.state, self.uid, self.gid)
        self.display = self.root / 'display.lock'
        self.display.touch(mode=0o600)
        os.chown(self.display, self.uid, self.gid)
        self.call = self.root / 'call.lock'
        self.call.touch(mode=0o600)
        self.power = self.root / 'power'
        self.power.mkdir()
        for name, value in [('mem_sleep', 's2idle [deep]\n'),
                            ('sync_on_suspend', '1\n'), ('wakeup_count', '3\n'), ('state', '')]:
            (self.power / name).write_text(value)
        self.supply = self.root / 'supply'
        self.supply.mkdir()
        for name in ['online', 'present']:
            (self.supply / name).write_text('0\n')
        self.modem = self.root / 'modem'
        self.port = self.modem / 'usb1/1-1'
        self.port.mkdir(parents=True)
        (self.port / 'idVendor').write_text('2c7c\n')
        (self.port / 'idProduct').write_text('0125\n')
        wakeups = [self.root / 'gpio/wakeup', self.root / 'axp/wakeup',
                   self.port / 'power/wakeup', self.supply / 'power/wakeup']
        for p in wakeups:
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text('disabled\n')
        self.call_status = self.root / 'call-status'
        self.call_status.write_text('0')
        checker = self.root / 'call-check'
        checker.write_text('''#!/usr/bin/python3
import os,pathlib,sys
locks = [pathlib.Path(x).stat() for x in %r]
for p in pathlib.Path('/proc/self/fd').iterdir():
 try: st=p.stat()
 except FileNotFoundError: continue
 if any((st.st_dev,st.st_ino)==(x.st_dev,x.st_ino) for x in locks):sys.exit(99)
pathlib.Path(%r).write_text('checked')
sys.exit(int(pathlib.Path(%r).read_text()))
''' % ([str(self.call), str(self.display)], str(self.root/'checked'), str(self.call_status)))
        checker.chmod(0o755)
        text = (SOURCE / 'openrc-power-monitor').read_text()
        replacements = {
            "Path('/run/emacsos-ui')": self.runtime,
            "Path('/sys/power')": self.power,
            "Path('/sys/class/power_supply/axp20x-usb')": self.supply,
            "Path('/sys/devices/platform/soc/1c1b000.usb')": self.modem,
            "'/usr/local/sbin/emacsos-openrc-call'": repr(str(checker)),
            "'/run/emacsos-openrc-call.lock'": repr(str(self.call)),
            "'/run/emacsos-power-state.lock'": repr(str(self.display)),
            "Path('/run')": self.root,
            "Path('/sys/devices/platform/gpio-keys/power/wakeup')": wakeups[0],
            "Path('/sys/devices/platform/soc/1f03400.rsb/sunxi-rsb-3a3/axp221-pek/power/wakeup')": wakeups[1],
        }
        for old, new in replacements.items():
            if isinstance(new, Path): new = 'Path(%r)' % str(new)
            text = text.replace(old, new)
        installed = Path('/usr/local/share/emacsos-openrc')
        installed.mkdir(parents=True, exist_ok=True)
        (installed / 'power-monitor').write_text(text)
        self.helper = self.root / 'suspend'
        shutil.copy2(SOURCE / 'openrc-suspend-root', self.helper)
        self.helper.chmod(0o755)
        self.children = []

    def tearDown(self):
        for p in self.children:
            if p.poll() is None: p.kill()
            p.wait(timeout=3)
            if p.stderr: p.stderr.close()
        self.temp.cleanup()

    def run_helper(self):
        p = subprocess.run([str(self.helper)], capture_output=True, timeout=6)
        self.assertEqual(p.returncode, 0, p.stderr.decode())
        return p

    def assert_veto(self):
        self.run_helper()
        self.assertEqual((self.power / 'state').read_bytes(), b'')

    def test_normal_public_entry_and_query_fd_closure(self):
        self.run_helper()
        self.assertEqual((self.power / 'state').read_bytes(), b'mem\n')
        self.assertTrue((self.root / 'checked').exists())

    def test_active_or_unknown_call_is_successful_veto(self):
        for status in ['1', '75']:
            with self.subTest(status=status):
                self.call_status.write_text(status)
                self.assert_veto()

    def test_usb_and_nonblank_are_successful_vetoes(self):
        (self.supply / 'online').write_text('1\n')
        self.assert_veto()
        (self.supply / 'online').write_text('0\n')
        self.state.write_text('active\n')
        self.assert_veto()

    def test_unavailable_state_is_bounded_successful_veto(self):
        self.state.unlink()
        os.mkfifo(self.state, 0o600)
        os.chown(self.state, self.uid, self.gid)
        self.assert_veto()

    def test_unsafe_lock_is_successful_veto(self):
        self.display.chmod(0o666)
        self.assert_veto()

    def test_busy_call_or_display_lock_vetoes(self):
        for path in [self.call, self.display]:
            with self.subTest(lock=path.name), path.open('r+b') as held:
                fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
                self.assert_veto()

    def test_counter_timeout_is_successful_veto(self):
        counter = self.power / 'wakeup_count'
        counter.unlink()
        os.mkfifo(counter)
        keeper = os.open(counter, os.O_RDWR | os.O_NONBLOCK)
        try: self.assert_veto()
        finally: os.close(keeper)

    def startup(self):
        text = (SOURCE / 'openrc-session-power').read_text()
        text = text.replace('XDG_RUNTIME_DIR=/run/emacsos-ui', 'XDG_RUNTIME_DIR=' + str(self.runtime))
        text = text.replace('/run/emacsos-power-state.lock', str(self.display))
        text = text.replace("stat -c '%u:%a:%F' /run", "stat -c '%u:%a:%F' " + str(self.root))
        p = self.root / 'session-power'
        p.write_text(text)
        p.chmod(0o755)
        return subprocess.run(['su', '-s', '/bin/sh', 'emacsos-lab', '-c', str(p)+' startup'],
                              capture_output=True, timeout=3)

    def test_writer_retains_locks_through_actual_blocked_write(self):
        # A filled real pipe models a blocked mem syscall, not kernel suspend.
        sink = self.power / 'state'
        sink.unlink()
        os.mkfifo(sink)
        keeper = os.open(sink, os.O_RDWR | os.O_NONBLOCK)
        try:
            try:
                while True: os.write(keeper, b'x' * 4096)
            except BlockingIOError: pass
            child = subprocess.Popen([str(self.helper)], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            self.children.append(child)
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                if 'pipe_write' in Path('/proc/%d/wchan' % child.pid).read_text(): break
                if child.poll() is not None: self.fail(child.stderr.read().decode())
                time.sleep(.01)
            else: self.fail('helper did not reach the actual blocking write')
            self.assertNotEqual(self.startup().returncode, 0)
            os.read(keeper, 8192)
            self.assertEqual(child.wait(timeout=3), 0)
            result = self.startup()
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            self.assertEqual(self.state.read_bytes(), b'waking\n')
            sink.unlink()
            sink.write_bytes(b'')
            self.assert_veto()
        finally: os.close(keeper)


if __name__ == '__main__':
    unittest.main()

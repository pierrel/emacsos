"""Real pidfd/epoll ownership tests with synthetic eventfds, not phone hardware."""
import ctypes
import importlib.machinery
import os
from pathlib import Path
import pwd
import select
import signal
import struct
import subprocess
import sys
import tempfile
import types
import unittest

MODULE = Path('/source/openrc-power-monitor')
CHILD = '''import os,select,struct
for n in (3,4,5):os.dup2(0,n)
ep=select.epoll()
for n in (3,5):
 fd=os.eventfd(0,os.EFD_NONBLOCK);os.dup2(fd,n);os.close(fd)
 ep.register(n,select.EPOLLIN | (0 if os.environ.get('NO_WAKEUP') else 1<<29))
os.dup2(ep.fileno(),4);ep.close()
if os.environ.get('WRONG_DESCRIPTION'):
 fd=os.eventfd(0,os.EFD_NONBLOCK);os.dup2(fd,3);os.close(fd)
if not os.environ.get('WRONG_UID'):
 os.setgroups([]);os.setresgid(int(os.environ['TEST_GID']),int(os.environ['TEST_GID']),int(os.environ['TEST_GID']))
 os.setresuid(int(os.environ['TEST_UID']),int(os.environ['TEST_UID']),int(os.environ['TEST_UID']))
ready=int(os.environ['TEST_READY']);command=int(os.environ['TEST_COMMAND']);reply=int(os.environ['TEST_REPLY'])
os.write(ready,b'r')
while True:
 c=os.read(command,1)
 if c==b'q':break
 if c==b'w':os.write(3,struct.pack('Q',1))
 if c==b'r':
  ep=select.epoll.fromfd(os.dup(4));ep.poll(0);os.read(3,8);ep.close()
 if c==b'p':
  ep=select.epoll.fromfd(os.dup(4));ep.poll(0);ep.close()
 os.write(reply,b'a')
'''


def high_pipe():
    import fcntl
    original = os.pipe()
    high = tuple(fcntl.fcntl(fd, fcntl.F_DUPFD_CLOEXEC, 40) for fd in original)
    for fd in original:
        os.close(fd)
    return high


class InputOwnership(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='native-input-')
        self.root = Path(self.temp.name)
        self.child_script = self.root / 'monitor'
        self.child_script.write_text(CHILD)
        self.module = types.ModuleType('input_under_test')
        exec(compile(MODULE.read_bytes(), str(MODULE), 'exec'), self.module.__dict__)
        self.module.CGROUP = self.root / 'cgroup.procs'
        self.module.CGROUP.write_text('')
        self.module.MONITOR = str(self.child_script)
        self.user = pwd.getpwnam('emacsos-lab')
        # Real hardware binding is separately probed on the phone. These fixtures
        # deliberately use actual eventfds; epoll metadata and MOD are not mocked.
        self.module.verify_input = self.synthetic_input
        self.children = []
        self.guard = None

    def synthetic_input(self, fd, _name, _key):
        self.assertEqual(os.readlink(f'/proc/self/fd/{fd}'), 'anon_inode:[eventfd]')

    def child(self, **mode):
        ready = high_pipe()
        command = high_pipe()
        reply = high_pipe()
        env = os.environ | {'TEST_UID': str(self.user.pw_uid), 'TEST_GID': str(self.user.pw_gid),
                            'TEST_READY': str(ready[1]), 'TEST_COMMAND': str(command[0]),
                            'TEST_REPLY': str(reply[1])} | mode
        process = subprocess.Popen(['/usr/bin/python3', '-I', str(self.child_script), 'monitor'],
                                   env=env, pass_fds=(ready[1], command[0], reply[1]))
        self.assertTrue(select.select([ready[0]], [], [], 2)[0])
        os.read(ready[0], 1)
        fds = ready + command + reply
        self.children.append((process, fds, command[1], reply[0]))
        self.module.CGROUP.write_text(''.join(f'{p.pid}\n' for p, *_ in self.children))
        return process

    def command(self, process, value):
        _, _, command, reply = next(row for row in self.children if row[0] is process)
        os.write(command, value)
        if value != b'q':
            self.assertTrue(select.select([reply], [], [], 2)[0])
            os.read(reply, 1)

    def acquire(self):
        self.guard = self.module.import_input_guard(self.user.pw_uid)
        self.assertTrue(all(os.get_inheritable(fd) for fd in (3, 4, 5)))
        return self.guard

    def tearDown(self):
        if self.guard is not None:
            self.guard.close()
        for fd in (3, 4, 5):
            try:
                os.close(fd)
            except OSError:
                pass
        for process, fds, *_ in self.children:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=2)
            for fd in fds:
                os.close(fd)
        self.temp.cleanup()

    def test_no_monitor_vetoes(self):
        with self.assertRaises(SystemExit):
            self.acquire()

    def test_wrong_credentials_veto(self):
        self.child(WRONG_UID='1')
        with self.assertRaises(SystemExit):
            self.acquire()

    def test_ambiguous_monitors_veto(self):
        self.child()
        self.child()
        with self.assertRaises(SystemExit):
            self.acquire()

    def test_missing_wakeup_registration_vetoes(self):
        self.child(NO_WAKEUP='1')
        with self.assertRaises(SystemExit):
            self.acquire()

    def test_same_inode_different_open_description_vetoes(self):
        self.child(WRONG_DESCRIPTION='1')
        with self.assertRaises((SystemExit, OSError)):
            self.acquire()

    def test_unread_input_survives_monitor_death(self):
        process = self.child()
        self.command(process, b'w')
        guard = self.acquire()
        self.command(process, b'q')
        process.wait(timeout=2)
        # Test-only poll observes retained readiness. Production import never polls.
        self.assertTrue(guard.poll(0))
        self.assertEqual(os.read(3, 8), struct.pack('Q', 1))
        self.module.verify_guard()

    def test_continuing_monitor_and_processed_input_keep_identity(self):
        process = self.child()
        self.command(process, b'w')
        self.acquire()
        self.command(process, b'r')  # Consumer read; no next poll/action completion yet.
        self.module.verify_guard()
        self.command(process, b'q')
        process.wait(timeout=2)
        self.module.verify_guard()

    def test_exit_during_acquisition_vetoes(self):
        process = self.child()
        original = self.module.read_limited
        stopped = False
        def read(path, limit):
            nonlocal stopped
            value = original(path, limit)
            if path.name == 'cmdline' and not stopped:
                stopped = True
                self.command(process, b'q')
                process.wait(timeout=2)
            return value
        self.module.read_limited = read
        with self.assertRaises((SystemExit, OSError)):
            self.acquire()


class ProviderDependency(unittest.TestCase):
    """Validate real fixed files/proc executable; only the bus reply is a fixture."""
    def setUp(self):
        import hashlib, shutil
        self.root=Path('/etc/elogind')
        self.config=b'[Sleep]\nAllowSuspendInterrupts=no\nSuspendByUsing=/usr/local/sbin/emacsos-openrc-suspend\n'
        for name in ('logind.conf','sleep.conf'):
            path=self.root/(name+'.d/50-emacsos-native-sleep.conf')
            path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(self.config);path.chmod(0o644)
        (self.root/'logind.conf').write_text('[Sleep]\nAllowSuspendInterrupts=yes\n')
        self.daemon=Path('/usr/libexec/elogind/elogind');self.daemon.parent.mkdir(parents=True,exist_ok=True)
        shutil.copyfile(sys.executable,self.daemon)
        digest=hashlib.sha256(self.daemon.read_bytes()).hexdigest()
        text=MODULE.read_text().replace('64de5adeccbd458ad32687b9a9ced9b2f9013db63b6ebf6ab7f76ace1a5bd748',digest)
        self.module=types.ModuleType('dependency_under_test');exec(compile(text,str(MODULE),'exec'),self.module.__dict__)
        Path('/usr/bin/busctl').write_text('#!/bin/sh\ncase "$*" in *GetConnectionUnixProcessID*) echo "u $PPID" ;; *) echo \'s ":1.42"\' ;; esac\n')
        Path('/usr/bin/busctl').chmod(0o755)
    def tearDown(self):
        (self.root/'sleep.conf.d/99-override.conf').unlink(missing_ok=True)
    def test_selected_provider_and_both_configs_pass(self):
        self.module.provider_check()
    def test_missing_sleep_config_rejected(self):
        (self.root/'sleep.conf.d/50-emacsos-native-sleep.conf').unlink()
        with self.assertRaises(FileNotFoundError):self.module.provider_check()
    def test_wrong_sleep_config_rejected(self):
        (self.root/'sleep.conf.d/50-emacsos-native-sleep.conf').write_text('[Sleep]\nSuspendByUsing=/bin/true\n')
        with self.assertRaises(SystemExit):self.module.provider_check()
    def test_competing_sleep_config_rejected(self):
        (self.root/'sleep.conf.d/99-override.conf').write_text('[Sleep]\nSuspendByUsing=/bin/true\n')
        with self.assertRaises(SystemExit):self.module.provider_check()
    def test_stock_or_different_provider_rejected(self):
        self.daemon.write_bytes(b'different-provider')
        with self.assertRaises(SystemExit):self.module.provider_check()


if __name__ == '__main__':
    unittest.main()

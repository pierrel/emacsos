"""Native package/policy and persistent display-lock checks with private fixtures."""
import os
from pathlib import Path
import pwd
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

MODULE = Path('/source/openrc-power-monitor')


class ProviderDependency(unittest.TestCase):
    """Validate fixed files/proc identity with fixture bus and package replies."""
    def setUp(self):
        self.root=Path('/etc/elogind')
        self.config=b'[Sleep]\nAllowSuspendInterrupts=no\nSuspendByUsing=/usr/local/sbin/emacsos-openrc-suspend\n'
        for name in ('sleep.conf',):
            path=self.root/(name+'.d/50-emacsos-native-sleep.conf')
            path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(self.config);path.chmod(0o644)
        (self.root/'logind.conf').write_text('[Sleep]\nAllowSuspendInterrupts=yes\n')
        self.daemon=Path('/usr/libexec/elogind/elogind');self.daemon.parent.mkdir(parents=True,exist_ok=True)
        self.daemon.unlink(missing_ok=True)
        self.daemon.symlink_to(sys.executable)
        text=MODULE.read_text()
        self.module=types.ModuleType('dependency_under_test');exec(compile(text,str(MODULE),'exec'),self.module.__dict__)
        original_run=subprocess.run
        def run(argv,*args,**kwargs):
            if argv[0]=='/sbin/apk':
                self.assertEqual(argv,['/sbin/apk','info','--installed','elogind=257.16-r1'])
                return subprocess.CompletedProcess(argv,0)
            return original_run(argv,*args,**kwargs)
        self.package=patch.object(self.module.subprocess,'run',side_effect=run)
        self.package.start();self.addCleanup(self.package.stop)
        Path('/usr/bin/busctl').write_text('#!/bin/sh\ncase "$*" in *GetConnectionUnixProcessID*) echo "u $PPID" ;; *) echo \'s ":1.42"\' ;; esac\n')
        Path('/usr/bin/busctl').chmod(0o755)
    def tearDown(self):
        (self.root/'sleep.conf.d/99-override.conf').unlink(missing_ok=True)
    def test_selected_provider_and_sleep_config_pass(self):
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
    def test_continued_setting_cannot_reset_helper(self):
        (self.root/'sleep.conf.d/99-override.conf').write_text('[Sleep]\nSuspendByUsing\\\n=\n')
        with self.assertRaises(SystemExit):self.module.provider_check()
    def test_installed_provider_must_be_active(self):
        self.daemon.unlink()
        self.daemon.write_bytes(b'different-provider')
        with self.assertRaises(SystemExit):self.module.provider_check()
    def test_unselected_package_rejected(self):
        self.module.subprocess.run.side_effect=lambda argv,**kwargs:subprocess.CompletedProcess(argv,1)
        with self.assertRaises(SystemExit):self.module.provider_check()


class PersistentDisplayLock(unittest.TestCase):
    """Run the actual initd create-once block against root-owned fixture paths."""
    def test_restart_preserves_owned_inode_and_rejects_unsafe_existing_files(self):
        import fcntl
        user=pwd.getpwnam('emacsos-lab')
        block=Path('/source/emacsos-ui.initd').read_text().split('    # Never replace the lock inode',1)[1].split('    runtime=/run/emacsos-ui',1)[0]
        block='    # Never replace the lock inode'+block
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);lock=root/'lock'
            code='uid='+str(user.pw_uid)+'; group='+str(user.pw_gid)+'\nprepare() {\n'+block.replace('/run/emacsos-power-state.lock',str(lock))+'\n}\nprepare\n'
            def run():return subprocess.run(['/bin/sh','-c',code],capture_output=True,text=True,timeout=2)
            self.assertEqual(run().returncode,0)
            lock.write_text('retained')
            with lock.open('r+') as held:
                fcntl.flock(held,fcntl.LOCK_EX)
                inode=os.fstat(held.fileno()).st_ino
                self.assertEqual(run().returncode,0)
                self.assertEqual(lock.stat().st_ino,inode)
                self.assertEqual(lock.read_text(),'retained')
            os.link(lock,root/'alias')
            self.assertNotEqual(run().returncode,0)
            (root/'alias').unlink();lock.unlink()
            target=root/'untouched';target.write_text('untouched');lock.symlink_to(target)
            self.assertNotEqual(run().returncode,0)
            self.assertEqual(target.read_text(),'untouched')


if __name__ == '__main__':
    unittest.main()

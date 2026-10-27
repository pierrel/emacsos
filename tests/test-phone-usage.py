"""Exercise usage evidence, real append contention and bounded power hooks."""
from importlib.machinery import SourceFileLoader
import importlib.util
import json
import fcntl
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'deploy/pinephone/openrc-usage'
loader = SourceFileLoader('phone_usage', str(SOURCE))
spec = importlib.util.spec_from_loader(loader.name, loader)
usage = importlib.util.module_from_spec(spec)
loader.exec_module(usage)


def stamp(event, boot, mono, **fields):
    return {'event': event, 'boot_id': 'boot-a', 'utc': boot + 10000,
            'boottime': boot, 'monotonic_before': mono, 'monotonic_after': mono + .0001, **fields}


class UsageTests(unittest.TestCase):
    def report(self, records, current=None):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / 'usage.jsonl').write_text(''.join(json.dumps(row) + '\n' for row in records))
            with patch.object(usage, 'clock', return_value=current or records[-1]):
                return usage.report(path)

    def test_actual_sleep_and_awake_gap_are_separate(self):
        records = [stamp('sample', 10, 10), stamp('suspend-attempt', 20, 20, attempt='1'),
                   stamp('suspend-return', 3620, 20.01, attempt='1', status=0),
                   stamp('sample', 3910, 310.01)]
        result = self.report(records)
        self.assertFalse(result['issues'], result)
        self.assertAlmostEqual(result['confirmed_sleep_intervals'][0]['seconds_min'], 3599.9899)
        records.append(stamp('sample', 4510, 910.01))
        result = self.report(records)
        self.assertIn('awake sampling gap: 600.0s', result['issues'])

    def test_missing_suspend_events_do_not_explain_gap(self):
        result = self.report([stamp('sample', 10, 10), stamp('sample', 3910, 310)])
        self.assertFalse(result['confirmed_sleep_intervals'])
        self.assertTrue(any('without paired sleep evidence' in issue for issue in result['issues']))

    def test_refused_and_failed_suspend_do_not_count_as_sleep(self):
        for status in (1, 75, 77):
            with self.subTest(status=status):
                result = self.report([stamp('suspend-attempt', 20, 20, attempt='3'),
                                      stamp('suspend-return', 20.1, 20.1, attempt='3', status=status)])
                self.assertFalse(result['confirmed_sleep_intervals'])

    def test_unpaired_event_and_stopped_collector_are_faults(self):
        records = [stamp('sample', 10, 10), stamp('suspend-attempt', 20, 20, attempt='1')]
        result = self.report(records, stamp('report', 700, 700))
        self.assertTrue(any('no outcome' in issue for issue in result['issues']))
        self.assertTrue(any('no samples' in issue for issue in result['issues']))

    def test_power_events_do_not_hide_dead_periodic_sampler(self):
        records = [stamp('sample', 10, 10)]
        for t in (130, 250, 370, 490):
            records += [stamp('suspend-attempt', t, t, attempt=str(t)),
                        stamp('suspend-return', t + .01, t + .01, attempt=str(t), status=77)]
        result = self.report(records)
        self.assertTrue(any('no samples for' in issue for issue in result['issues']))
        self.assertTrue(any('no usage samples' in issue for issue in self.report(records[1:])['issues']))

    def test_trailing_awake_gap_survives_offline_and_later_boot_reports(self):
        records = [stamp('sample', 10, 10),
                   stamp('suspend-attempt', 600, 600, attempt='1'),
                   stamp('suspend-return', 601, 601, attempt='1', status=77)]
        for later in ([], [stamp('sample', 1, 1, boot_id='boot-b')]):
            with self.subTest(later_boot=bool(later)):
                result = self.report(records + later, stamp('report', 2, 2, boot_id='offline'))
                self.assertTrue(any('trailing awake sampling gap' in issue for issue in result['issues']), result)
                self.assertFalse(result['live_freshness_checked'])
        result = self.report(records[1:] + [stamp('sample', 1, 1, boot_id='boot-b')])
        self.assertIn('no usage samples retained for recorded boot boot-a', result['issues'])
        sleeping = [stamp('sample', 10, 10),
                    stamp('suspend-attempt', 20, 20, attempt='1'),
                    stamp('suspend-return', 3620, 20.01, attempt='1', status=0)]
        self.assertFalse(self.report(sleeping)['issues'])

    def test_retained_boot_prefix_outage_is_reported(self):
        records = [stamp('collector-start', 10, 10),
                   stamp('collector-start', 700, 700), stamp('sample', 700, 700)]
        self.assertTrue(any('leading awake sampling gap' in issue for issue in self.report(records)['issues']))
        self.assertFalse(self.report(records[1:])['issues'])
        sleeping = [stamp('suspend-attempt', 10, 10, attempt='1'),
                    stamp('suspend-return', 3610, 10.01, attempt='1', status=0),
                    stamp('sample', 3620, 20.01)]
        self.assertFalse(self.report(sleeping)['issues'])

    def test_retained_prefix_and_tail_unexplained_sleep_is_a_fault(self):
        for records in ([stamp('collector-start', 10, 10), stamp('sample', 3710, 310)],
                        [stamp('sample', 10, 10), stamp('collector-start', 3710, 310)]):
            with self.subTest(events=[row['event'] for row in records]):
                self.assertTrue(any('without paired sleep evidence' in issue
                                    for issue in self.report(records)['issues']))

    def test_live_boundary_unknown_sleep_is_a_fault(self):
        result = self.report([stamp('sample', 10, 10)], stamp('report', 3611, 11))
        self.assertTrue(result['live_freshness_checked'])
        self.assertTrue(any('without paired sleep evidence' in issue for issue in result['issues']))

    def test_reused_attempt_id_preserves_missing_outcome(self):
        records = [stamp('sample', 10, 10), stamp('suspend-attempt', 20, 20, attempt='1'),
                   stamp('suspend-attempt', 30, 30, attempt='1'),
                   stamp('suspend-return', 31, 31, attempt='1', status=77),
                   stamp('sample', 310, 310)]
        self.assertTrue(any('missing outcome' in issue for issue in self.report(records)['issues']))

    def test_report_clock_is_captured_with_snapshot_before_parsing(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / 'usage.jsonl').write_text(json.dumps(stamp('sample', 10, 10)) + '\n')
            (path / 'write.lock').touch(mode=0o600)
            current = stamp('report', 10, 10)
            original = json.loads
            def decode(line):
                current.update(stamp('report', 3611, 11))
                with (path / 'usage.jsonl').open('a') as stream:
                    stream.write(json.dumps(stamp('suspend-attempt', 11, 11, attempt='1')) + '\n')
                    stream.write(json.dumps(stamp('suspend-return', 3611, 11, attempt='1', status=0)) + '\n')
                return original(line)
            def capture_clock():
                with (path / 'write.lock').open('rb') as lock:
                    with self.assertRaises(BlockingIOError):
                        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return dict(current)
            with patch.object(usage.json, 'loads', side_effect=decode), \
                    patch.object(usage, 'clock', side_effect=capture_clock) as observed:
                result = usage.report(path)
            self.assertEqual(observed.call_count, 1)
            self.assertFalse(result['issues'], result)
            self.assertEqual(result['samples'], 1)

    def test_mixed_sleep_issue_reports_only_unexplained_lower_bound(self):
        records = [stamp('sample', 10, 10), stamp('suspend-attempt', 20, 20, attempt='1'),
                   stamp('suspend-return', 3620, 20, attempt='1', status=0),
                   stamp('sample', 3920, 310)]
        self.assertEqual(self.report(records)['issues'], [
            'sampling gap contains at least 10.0s suspended time without paired sleep evidence'])

    def test_old_boot_samples_do_not_certify_current_boot_collector(self):
        records = [stamp('sample', 10, 10),
                   stamp('suspend-attempt', 1100, 1100, attempt='1', boot_id='boot-b'),
                   stamp('suspend-return', 1101, 1101, attempt='1', status=77, boot_id='boot-b')]
        self.assertTrue(any('no usage samples' in issue for issue in self.report(records)['issues']))

    def test_previous_boot_sleep_never_covers_current_boot_gap(self):
        records = [stamp('suspend-attempt', 10, 10, attempt='1'),
                   stamp('suspend-return', 110, 10, attempt='1', status=0),
                   stamp('sample', 10, 10, boot_id='boot-b'),
                   stamp('sample', 210, 110, boot_id='boot-b')]
        result = self.report(records)
        self.assertTrue(any('without paired sleep evidence' in issue for issue in result['issues']))

    def test_pair_overlap_credits_only_sleep_within_sample_window(self):
        records = [stamp('suspend-attempt', 10, 10, attempt='1'),
                   stamp('sample', 110, 10),
                   stamp('suspend-return', 110.1, 10.1, attempt='1', status=0),
                   stamp('sample', 210, 60)]
        result = self.report(records)
        self.assertTrue(any('without paired sleep evidence' in issue for issue in result['issues']))

    def test_clock_skew_alone_does_not_prove_suspend(self):
        records = [stamp('suspend-attempt', 20, 20, attempt='1'),
                   stamp('suspend-return', 21.00001, 21, attempt='1', status=0)]
        result = self.report(records)
        self.assertFalse(result['confirmed_sleep_intervals'])
        self.assertTrue(any('no positive clock evidence' in issue for issue in result['issues']))

    def test_collection_records_power_and_multiple_routes_without_arguments(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            proc, sys = root / 'proc', root / 'sys'
            def put(path, text):
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text)
            put(proc / 'stat', 'cpu 100 0 30 500 10 0 0 0 0 0\n')
            put(proc / 'meminfo', 'MemTotal: 2048 kB\nMemAvailable: 1024 kB\nSwapTotal: 0 kB\nSwapFree: 0 kB\n')
            fields = ['S'] + ['0'] * 21
            fields[11], fields[12], fields[19], fields[21] = '20', '5', '100', '7'
            put(proc / '44/stat', '44 (worker) ' + ' '.join(fields))
            put(proc / '44/cmdline', 'private-message\0secret-token')
            put(proc / 'net/route', 'Iface Destination Gateway Flags RefCnt Use Metric Mask\nwlan0 00000000 0100007F 0003 0 0 10 00000000\nwwan0 00000000 0100007F 0003 0 0 20 00000000\n')
            put(proc / 'net/ipv6_route', '\n'.join(
                '0' * 32 + ' 00 ' + '0' * 32 + ' 00 ' + '0' * 32 + ' 0000000a 00000000 00000000 ' + flags + ' ' + interface
                for flags, interface in [('00200200', 'lo'), ('00000000', 'down0'), ('00000003', 'wlan0')]) + '\n')
            for name, values in {'battery': {'type':'Battery','capacity':'100','status':'Discharging','online':'1'},
                                 'usb': {'type':'USB','online':'1'}}.items():
                for key, value in values.items(): put(sys / 'class/power_supply' / name / key, value)
            for name in ('wlan0', 'wwan0'):
                put(sys / 'class/net' / name / 'operstate', 'up')
                put(sys / 'class/net' / name / 'statistics/rx_bytes', '100')
                put(sys / 'class/net' / name / 'statistics/tx_bytes', '200')
            with patch.object(usage, 'PROC', proc), patch.object(usage, 'SYS', sys), \
                    patch.object(usage.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, 'enabled:disabled\n')):
                result, previous = usage.collect()
                put(proc / 'stat', 'cpu 150 0 30 550 10 0 0 0 0 0\n')
                put(proc / '45/stat', '45 (new-worker) ' + ' '.join(fields))
                following, _ = usage.collect(previous)
            self.assertEqual(result['power_supplies']['battery']['status'], 'Discharging')
            self.assertEqual(result['power_supplies']['usb']['online'], '1')
            self.assertEqual([r['interface'] for r in result['default_routes']], ['wlan0', 'wwan0', 'wlan0'])
            self.assertEqual(result['default_routes'][-1], {'family': 'ipv6', 'interface': 'wlan0', 'metric': 10})
            self.assertEqual(following['cpu_percent'], 50)
            new_process = next(row for row in following['top_processes'] if row['pid'] == 45)
            self.assertIsNone(new_process['cpu_percent'])
            self.assertEqual(result['networkmanager_radio_enabled'], {'wifi': 'enabled', 'wwan': 'disabled'})
            self.assertNotIn('private-message', json.dumps(result))
            self.assertEqual(result['top_processes'][0]['comm'], 'worker')

    def test_real_process_writers_serialize_and_rotate_private_logs(self):
        with tempfile.TemporaryDirectory() as directory:
            script = Path(directory) / 'writer.py'
            source = SOURCE.read_text().replace("DIRECTORY = Path('/var/lib/emacsos-lab/.local/state/emacsos-usage')",
                                               f'DIRECTORY = Path({directory!r})').replace('MAX_BYTES = 2 * 1024 * 1024', 'MAX_BYTES = 350')
            script.write_text(source)
            children = [subprocess.Popen(['python3', '-I', str(script), 'event', 'suspend-attempt', str(i)])
                        for i in range(8)]
            for child in children: self.assertEqual(child.wait(timeout=5), 0)
            logs = list(Path(directory).glob('usage*.jsonl'))
            self.assertLessEqual(len(logs), usage.FILES)
            records = [json.loads(line) for p in logs for line in p.read_text().splitlines()]
            self.assertTrue(records)
            self.assertEqual(len({r['attempt'] for r in records}), len(records))
            self.assertTrue(all(p.stat().st_mode & 0o077 == 0 for p in logs))

    def test_report_retains_open_snapshot_when_files_rotate_during_parse(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            sets = {'usage.2.jsonl': [stamp('sample', 0, 0), stamp('suspend-attempt', 10, 10, attempt='1')],
                    'usage.1.jsonl': [stamp('suspend-return', 110, 10, attempt='1', status=0), stamp('sample', 310, 210)],
                    'usage.jsonl': [stamp('sample', 400, 300)]}
            for name, records in sets.items():
                (path / name).write_text(''.join(json.dumps(row) + '\n' for row in records))
            (path / 'write.lock').touch(mode=0o600)
            original = json.loads
            rotated = False
            def decode(line):
                nonlocal rotated
                if not rotated:
                    rotated = True
                    os.replace(path / 'usage.1.jsonl', path / 'usage.2.jsonl')
                    os.replace(path / 'usage.jsonl', path / 'usage.1.jsonl')
                    (path / 'usage.jsonl').write_text(json.dumps(stamp('sample', 500, 400)) + '\n')
                return original(line)
            with patch.object(usage.json, 'loads', side_effect=decode), \
                    patch.object(usage, 'clock', return_value=stamp('report', 400, 300)):
                result = usage.report(path)
            self.assertEqual(result['samples'], 3)
            self.assertFalse(result['issues'], result)

    def test_symlink_log_and_hardlink_lock_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            target = path / 'keep'
            target.write_text('untouched')
            (path / 'usage.jsonl').symlink_to(target)
            with patch.object(usage, 'DIRECTORY', path), self.assertRaises(OSError):
                usage.append('collector-start')
            self.assertEqual(target.read_text(), 'untouched')
            (path / 'usage.jsonl').unlink()
            (path / 'write.lock').unlink()
            target.chmod(0o600)
            os.link(target, path / 'write.lock')
            with patch.object(usage, 'DIRECTORY', path), self.assertRaises(ValueError):
                usage.append('collector-start')

    def test_report_rejects_fifo_without_waiting_for_a_writer(self):
        with tempfile.TemporaryDirectory() as directory:
            os.mkfifo(Path(directory) / 'write.lock')
            result = subprocess.run(['python3', '-I', str(SOURCE), 'report', directory],
                                    capture_output=True, text=True, timeout=3)
            self.assertEqual(result.returncode, 1)
            self.assertIn('bounded regular file', result.stderr)

    def test_hook_has_real_timeout_and_does_not_inherit_guard_descriptors(self):
        source = (ROOT / 'deploy/pinephone/openrc-session-power').read_text()
        hook = source[source.index('usage_event() {'):source.index('\nsway() {')]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            script = path / 'event.py'
            output = path / 'fds'
            script.write_text('import os,sys,time\nfrom pathlib import Path\n'
                              f'Path({str(output)!r}).write_text(str([fd for fd in (3,4,5,9) if os.path.exists("/proc/self/fd/"+str(fd))]))\n'
                              'time.sleep(10)\n')
            hook = hook.replace('/usr/local/share/emacsos-openrc/usage', str(script))
            result = subprocess.run(['sh', '-c', 'exec 3</dev/null 4</dev/null 5</dev/null 9</dev/null\n' + hook + '\nusage_event suspend-attempt 1\necho power-continues'],
                                    capture_output=True, text=True, timeout=4)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(output.read_text(), '[]')
            self.assertIn('power-continues', result.stdout)
            self.assertIn('was not recorded', result.stderr)


if __name__ == '__main__':
    unittest.main()

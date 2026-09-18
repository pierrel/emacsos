import importlib.util
import json
import os
import socket
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock


MODULE_PATH = (
    Path(__file__).parents[1]
    / "deploy"
    / "pinephone"
    / "swipe-learning-collector.py"
)
SPEC = importlib.util.spec_from_file_location("swipe_learning_collector", MODULE_PATH)
collector = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(collector)


SESSION = "0123456789abcdef0123456789abcdef"
DICTIONARY = "a" * 64
FEEDBACK = {
    "type": "feedback",
    "version": 1,
    "algorithm": "geometry-feedback-v1",
    "dictionary": DICTIONARY,
    "trace": "ab",
    "word": "word",
}


def gesture(gesture_id=1, candidates=None, presentation=None):
    candidates = candidates if candidates is not None else []
    return {
        "type": "gesture",
        "version": 1,
        "session": SESSION,
        "gesture": gesture_id,
        "algorithm": "geometry-v1",
        "dictionary": DICTIONARY,
        "trace": "ab",
        "points": [[1, 2], [3, 4]],
        "geometry": [[index, index + 1] for index in range(26)],
        "key_height": 42,
        "candidates": candidates,
        "presentation": presentation or ("top-queued" if candidates else "no-candidate"),
    }


def resolution(outcome, gesture_id=1, **extra):
    return {
        "type": "resolution",
        "version": 1,
        "session": SESSION,
        "gesture": gesture_id,
        "outcome": outcome,
    } | extra


def encoded(record):
    return json.dumps(record, separators=(",", ":")).encode()


def feedback_trace(index):
    return "ab" * 31 + chr(ord("c") + index // 2) + ("a" if index % 2 == 0 else "b")


def private_state(root):
    path = root / "state"
    path.mkdir(mode=0o700)
    return path


class CollectorTests(unittest.TestCase):
    def _start_collector(self, store, epoch):
        try:
            saved = os.dup(6)
        except OSError:
            saved = -1
        reader, writer = os.pipe()
        os.dup2(writer, 6)
        os.close(writer)
        left, right = socket.socketpair(socket.AF_UNIX, socket.SOCK_DGRAM)
        worker = threading.Thread(
            target=collector.collect, args=(left.detach(), 6, epoch, store)
        )
        worker.start()
        return worker, right, reader, saved

    @staticmethod
    def _restore_ready_fd(saved):
        if saved >= 0:
            os.dup2(saved, 6)
            os.close(saved)

    @staticmethod
    def _reserve_ready_fd():
        try:
            saved = os.dup(6)
        except OSError:
            saved = -1
        null = os.open("/dev/null", os.O_RDONLY)
        os.dup2(null, 6)
        os.close(null)
        return saved

    def test_show_does_not_create_absent_state(self):
        with tempfile.TemporaryDirectory() as temporary:
            state = Path(temporary) / "absent" / "state"
            result = subprocess.run(
                [MODULE_PATH, "--state-dir", state, "show"],
                capture_output=True,
                text=True,
                check=True,
            )
            summary = json.loads(result.stdout)
            self.assertFalse(summary["enabled"])
            self.assertEqual(summary["capture"], "off")
            self.assertEqual(summary["gestures"], 0)
            self.assertFalse(state.exists())

    def test_validation_distinguishes_raw_no_candidate_from_attribution(self):
        raw = collector.validate_record(encoded(gesture()))
        missing = collector.validate_record(
            encoded(resolution("explicit-lookup-failure"))
        )
        misswipe = collector.validate_record(
            encoded(resolution("explicit-user-misswipe"))
        )
        collector.validate_pair(raw, missing)
        collector.validate_pair(raw, misswipe)
        with self.assertRaises(collector.InvalidRecord):
            collector.validate_pair(
                gesture(candidates=[{"word": "ab", "score": 1, "rank": 1}]),
                missing,
            )

    def test_exact_schema_and_bounds_reject_malformed_records(self):
        record = gesture()
        record["application"] = "secret"
        with self.assertRaises(collector.InvalidRecord):
            collector.validate_record(encoded(record))
        record = gesture()
        record["points"] = [[1, 2]]
        with self.assertRaises(collector.InvalidRecord):
            collector.validate_record(encoded(record))
        with self.assertRaises(collector.InvalidRecord):
            collector.validate_record(b"{" + b"x" * collector.JSON_MAX)
        record = gesture()
        record["version"] = True
        with self.assertRaises(collector.InvalidRecord):
            collector.validate_record(encoded(record))
        record = gesture(candidates=[{"word": "ab", "score": 1, "rank": True}])
        with self.assertRaises(collector.InvalidRecord):
            collector.validate_record(encoded(record))

    def test_pairing_duplicates_pending_export_and_erase(self):
        with tempfile.TemporaryDirectory() as temporary:
            state = private_state(Path(temporary))
            store = collector.Store(state)
            try:
                self.assertTrue(store.append(encoded(gesture())))
                self.assertFalse(store.append(encoded(gesture())))
                summary = store.summary()
                self.assertEqual(summary["gestures"], 1)
                self.assertEqual(summary["pending"], 1)
                name, count = store.export()
                self.assertEqual(count, 1)
                exported = (state / name).read_text()
                self.assertIn('"type":"pending"', exported)
                self.assertIn('"state":"unresolved"', exported)
                self.assertEqual(
                    store.summary(include_records=True)["records"][0]["state"],
                    "unresolved",
                )
                store.append(encoded(resolution("explicit-user-misswipe")))
                self.assertEqual(
                    store.summary()["outcomes"], {"explicit-user-misswipe": 1}
                )
                with self.assertRaises(collector.InvalidRecord):
                    store.append(encoded(resolution("explicit-lookup-failure")))
                store.set_enabled(False)
                store.erase()
                self.assertFalse(store.enabled())
                self.assertFalse((state / "journal.jsonl").exists())
                self.assertFalse((state / name).exists())
            finally:
                store.close()

    def test_orphan_and_incompatible_resolution_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            store = collector.Store(private_state(Path(temporary)))
            try:
                with self.assertRaises(collector.InvalidRecord):
                    store.append(encoded(resolution("no-candidate-unattributed")))
                store.append(
                    encoded(
                        gesture(
                            candidates=[{"word": "ab", "score": 5, "rank": 1}]
                        )
                    )
                )
                with self.assertRaises(collector.InvalidRecord):
                    store.append(encoded(resolution("explicit-user-misswipe")))
            finally:
                store.close()

    def test_torn_tail_is_repaired_before_append(self):
        with tempfile.TemporaryDirectory() as temporary:
            state = private_state(Path(temporary))
            line = collector.canonical(gesture())
            (state / "journal.jsonl").write_bytes(line + b'{"type":')
            os.chmod(state / "journal.jsonl", 0o600)
            (state / "export-1.tmp").write_text("partial")
            os.chmod(state / "export-1.tmp", 0o600)
            store = collector.Store(state)
            try:
                self.assertEqual(store.summary()["gestures"], 1)
                self.assertEqual(
                    (state / "journal.jsonl").read_bytes(), line + b'{"type":'
                )
                self.assertTrue((state / "export-1.tmp").exists())
                store.append(encoded(resolution("explicit-user-misswipe")))
                data = (state / "journal.jsonl").read_bytes()
                self.assertTrue(data.endswith(b"\n"))
                self.assertEqual(
                    data,
                    line + collector.canonical(resolution("explicit-user-misswipe")),
                )
            finally:
                store.close()

    def test_private_file_and_symlink_checks(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            state = private_state(root)
            target = root / "target"
            target.write_text("")
            (state / "journal.jsonl").symlink_to(target)
            store = collector.Store(state)
            try:
                with self.assertRaises(OSError):
                    store.summary()
            finally:
                store.close()

            os.unlink(state / "journal.jsonl")
            os.mkfifo(state / "journal.jsonl", 0o600)
            store = collector.Store(state)
            try:
                with self.assertRaises(OSError):
                    store.summary()
            finally:
                store.close()

            os.unlink(state / "journal.jsonl")
            (state / "journal.jsonl").write_text("")
            os.chmod(state / "journal.jsonl", 0o644)
            store = collector.Store(state)
            try:
                with self.assertRaises(OSError):
                    store.summary()
            finally:
                store.close()

    def test_journal_compacts_before_crossing_hard_gesture_bound(self):
        with tempfile.TemporaryDirectory() as temporary:
            store = collector.Store(private_state(Path(temporary)))
            try:
                with mock.patch.object(collector, "JOURNAL_HIGH_GESTURES", 2), mock.patch.object(
                    collector, "JOURNAL_LOW_GESTURES", 1
                ):
                    store.append(encoded(gesture(1)))
                    store.append(encoded(gesture(2)))
                    store.append(encoded(gesture(3)))
                self.assertEqual(store.summary()["gestures"], 1)
            finally:
                store.close()

    def test_exports_prune_only_after_new_snapshot_and_obey_write_budget(self):
        with tempfile.TemporaryDirectory() as temporary:
            state = private_state(Path(temporary))
            store = collector.Store(state)
            try:
                store.append(encoded(gesture()))
                with mock.patch.object(collector, "EXPORT_HIGH_COUNT", 2), mock.patch.object(
                    collector, "EXPORT_LOW_COUNT", 1
                ):
                    store.export()
                    store.export()
                    newest, _ = store.export()
                exports = sorted(state.glob("export-*.jsonl"))
                self.assertEqual([item.name for item in exports], [newest])
                with mock.patch.object(collector, "EXPORT_WRITE_BUDGET", 1):
                    with self.assertRaises(OSError):
                        store.export()
            finally:
                store.close()

    def test_export_publish_failure_keeps_completed_snapshots(self):
        with tempfile.TemporaryDirectory() as temporary:
            state = private_state(Path(temporary))
            store = collector.Store(state)
            try:
                store.append(encoded(gesture()))
                with mock.patch.object(collector, "EXPORT_HIGH_COUNT", 2), mock.patch.object(
                    collector, "EXPORT_LOW_COUNT", 1
                ):
                    store.export()
                    store.export()
                    real_rename = collector.os.rename

                    def fail_export_publish(source, destination, **arguments):
                        if str(source).startswith("export-") and str(source).endswith(
                            ".tmp"
                        ):
                            raise OSError("publish failed")
                        return real_rename(source, destination, **arguments)

                    with mock.patch.object(
                        collector.os, "rename", side_effect=fail_export_publish
                    ):
                        with self.assertRaises(OSError):
                            store.export()
                self.assertEqual(
                    sorted(item.name for item in state.glob("export-*.jsonl")),
                    ["export-1.jsonl", "export-2.jsonl"],
                )
            finally:
                store.close()

    def test_torn_export_budget_recovery_exhausts_budget(self):
        with tempfile.TemporaryDirectory() as temporary:
            state = private_state(Path(temporary))
            (state / "export-budget.tmp").write_bytes(b"6")
            os.chmod(state / "export-budget.tmp", 0o600)
            store = collector.Store(state)
            try:
                store.append(encoded(gesture()))
                with self.assertRaises(OSError):
                    store.export()
                self.assertEqual(
                    (state / "export-budget").read_text(),
                    str(collector.EXPORT_WRITE_BUDGET),
                )
            finally:
                store.close()

    def test_interrupted_budget_recovery_preserves_temporary(self):
        with tempfile.TemporaryDirectory() as temporary:
            state = private_state(Path(temporary))
            marker = state / "export-budget.tmp"
            marker.write_bytes(b"6")
            os.chmod(marker, 0o600)
            store = collector.Store(state)
            try:
                store.summary()
                self.assertTrue(marker.exists())
                with mock.patch.object(collector.os, "write", side_effect=OSError("full")):
                    with self.assertRaises(OSError):
                        store.export()
                self.assertTrue(marker.exists())
                store.export()
                self.assertEqual(
                    (state / "export-budget").read_text(),
                    str(collector.EXPORT_WRITE_BUDGET),
                )
            finally:
                store.close()

    def test_collector_lifetime_datagram_budget_latches_off(self):
        with tempfile.TemporaryDirectory() as temporary:
            state = private_state(Path(temporary))
            store = collector.Store(state)
            try:
                with mock.patch.object(collector, "COLLECTOR_DATAGRAM_BUDGET", 1):
                    store.append(encoded(gesture()))
                    with self.assertRaises(collector.BudgetExhausted):
                        store.append(encoded(gesture()))
                self.assertTrue(store.capture_exhausted)
            finally:
                store.close()
            store = collector.Store(state)
            try:
                self.assertTrue(store.summary()["session_budget_exhausted"])
                store.erase()
                self.assertFalse(store.summary()["session_budget_exhausted"])
                self.assertEqual(store.admitted, 0)
                self.assertEqual(store.written, 0)
            finally:
                store.close()

    def test_disabled_append_and_live_collector_erase_fail_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            state = private_state(Path(temporary))
            collector_store = collector.Store(state)
            manager = collector.Store(state)
            try:
                epoch = collector_store.set_enabled(True)
                self.assertIsNotNone(epoch)
                self.assertTrue(
                    collector_store.append(encoded(gesture()), require_epoch=epoch)
                )
                manager.set_enabled(False)
                with self.assertRaises(collector.EpochMismatch):
                    collector_store.append(
                        encoded(gesture(gesture_id=2)), require_epoch=epoch
                )
                with collector_store.collector_session():
                    with self.assertRaisesRegex(OSError, "disable, restart UI, then erase"):
                        manager.erase()
                manager.erase()
                self.assertEqual(manager.summary()["gestures"], 0)
            finally:
                manager.close()
                collector_store.close()

    def test_duplicate_uses_cached_index_instead_of_reparsing_journal(self):
        with tempfile.TemporaryDirectory() as temporary:
            store = collector.Store(private_state(Path(temporary)))
            try:
                store.append(encoded(gesture()))
                with mock.patch.object(
                    collector, "validate_record", wraps=collector.validate_record
                ) as validate:
                    self.assertFalse(store.append(encoded(gesture())))
                self.assertEqual(validate.call_count, 1)
            finally:
                store.close()

    def test_resolution_is_rejected_if_compaction_evicts_its_gesture(self):
        with tempfile.TemporaryDirectory() as temporary:
            store = collector.Store(private_state(Path(temporary)))
            try:
                store.append(encoded(gesture(1)))
                store.append(encoded(gesture(2)))
                journal_size = (Path(temporary) / "state" / "journal.jsonl").stat().st_size
                with mock.patch.object(
                    collector, "JOURNAL_HIGH_BYTES", journal_size + 1
                ), mock.patch.object(collector, "JOURNAL_LOW_GESTURES", 1):
                    with self.assertRaises(collector.InvalidRecord):
                        store.append(
                            encoded(resolution("explicit-user-misswipe", gesture_id=1))
                        )
                self.assertEqual(store.summary()["gestures"], 1)
            finally:
                store.close()

    def test_stale_managed_export_temporary_is_recovered(self):
        with tempfile.TemporaryDirectory() as temporary:
            state = private_state(Path(temporary))
            stale = state / "export-1.tmp"
            stale.write_text("partial")
            os.chmod(stale, 0o600)
            store = collector.Store(state)
            try:
                name, _ = store.export()
                self.assertEqual(name, "export-1.jsonl")
                self.assertFalse(stale.exists())
            finally:
                store.close()

    def test_recovery_rejects_incompatible_complete_export(self):
        with tempfile.TemporaryDirectory() as temporary:
            state = private_state(Path(temporary))
            stale = state / "export-1.tmp"
            stale.write_bytes(
                collector.canonical(
                    gesture(candidates=[{"word": "ab", "score": 1, "rank": 1}])
                )
                + collector.canonical(resolution("explicit-user-misswipe"))
            )
            os.chmod(stale, 0o600)
            store = collector.Store(state)
            try:
                name, _ = store.export()
                self.assertEqual(name, "export-1.jsonl")
                self.assertNotIn(
                    b'"outcome":"explicit-user-misswipe"',
                    (state / name).read_bytes(),
                )
            finally:
                store.close()

    def test_epoch_status_and_erase_readiness_are_fail_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            store = collector.Store(private_state(Path(temporary)))
            try:
                first = store.set_enabled(True)
                self.assertRegex(first or "", r"^[0-9a-f]{32}$")
                store.start_session(first or "")
                self.assertEqual(store.capture_status(), (True, "armed for next UI session"))
                second = store.set_enabled(True)
                self.assertNotEqual(first, second)
                self.assertEqual(
                    store.capture_status(), (True, "armed for next UI session")
                )
                with self.assertRaisesRegex(OSError, "disable, restart UI, then erase"):
                    store.erase_ready()
                store.set_enabled(False)
                store.erase_ready()
            finally:
                store.close()

    def test_json_rejects_duplicate_members_and_noninteger_tokens(self):
        raw = encoded(gesture())
        duplicate = raw[:-1] + b',"version":1}'
        with self.assertRaisesRegex(collector.InvalidRecord, "duplicate JSON member"):
            collector.validate_record(duplicate)
        for token in (b"1.0", b"1e0", b"01", b"-0", b"NaN"):
            candidate = raw.replace(b'"gesture":1', b'"gesture":' + token)
            with self.assertRaises(collector.InvalidRecord):
                collector.validate_record(candidate)

    def test_feedback_is_strict_private_bounded_and_excluded_from_export(self):
        with tempfile.TemporaryDirectory() as temporary:
            state = private_state(Path(temporary))
            store = collector.Store(state)
            try:
                invalid = FEEDBACK | {"reason": "replacement"}
                with self.assertRaises(collector.InvalidRecord):
                    store.append(encoded(invalid))
                with self.assertRaises(collector.InvalidRecord):
                    store.append(encoded(FEEDBACK | {"trace": "aabb"}))
                self.assertTrue(store.append(encoded(FEEDBACK)))
                self.assertTrue(store.append(encoded(FEEDBACK)))
                entries = store._read_feedback()
                self.assertEqual(entries, [("geometry-feedback-v1", DICTIONARY, "ab", "word", 2)])
                self.assertNotIn("feedback.state", store.export()[0])
                self.assertNotIn(b'"type":"feedback"', (state / "export-1.jsonl").read_bytes())
                store.set_enabled(False)
                store.erase()
                self.assertFalse((state / "feedback.state").exists())
            finally:
                store.close()

    def test_feedback_snapshot_has_exact_maximum_and_keeps_other_builds(self):
        entries = [
            (
                "a" * 24,
                "b" * 64,
                feedback_trace(index),
                "d" * 24,
                65535,
            )
            for index in range(32)
        ]
        state = collector.Store._feedback_bytes(entries)
        self.assertEqual(len(state), collector.FEEDBACK_MAX_BYTES)
        self.assertEqual(collector.Store._parse_feedback(state), entries)

    def test_feedback_eviction_is_global_and_count_saturates(self):
        with tempfile.TemporaryDirectory() as temporary:
            store = collector.Store(private_state(Path(temporary)))
            try:
                for index in range(33):
                    record = FEEDBACK | {
                        "algorithm": "other-v1" if index == 0 else "geometry-feedback-v1",
                        "trace": feedback_trace(index),
                    }
                    store.append(encoded(record))
                entries = store._read_feedback()
                self.assertEqual(len(entries), 32)
                self.assertNotIn(feedback_trace(0), [entry[2] for entry in entries])
                final = FEEDBACK | {"trace": "ab", "word": "word"}
                store._replace(
                    "feedback.tmp",
                    "feedback.state",
                    collector.Store._feedback_bytes(
                        [(final["algorithm"], final["dictionary"], "ab", "word", 65535)]
                    ),
                )
                store.append(encoded(final))
                self.assertEqual(store._read_feedback()[-1][-1], 65535)
            finally:
                store.close()

    def test_feedback_reads_require_the_complete_committed_or_stale_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            state = private_state(Path(temporary))
            store = collector.Store(state)
            try:
                store.append(encoded(FEEDBACK))
                real_read = collector.os.read
                calls = 0

                def short_read(fd, amount):
                    nonlocal calls
                    calls += 1
                    return real_read(fd, max(1, amount // 2)) if calls == 1 else b""

                with mock.patch.object(collector.os, "read", side_effect=short_read):
                    with self.assertRaisesRegex(collector.InvalidRecord, "partial state"):
                        store._read_feedback()

                temporary_data = collector.Store._feedback_bytes(
                    [("geometry-feedback-v1", DICTIONARY, "ab", "word", 1)]
                )
                (state / "feedback.tmp").write_bytes(temporary_data)
                os.chmod(state / "feedback.tmp", 0o600)
                calls = 0
                with mock.patch.object(collector.os, "read", side_effect=short_read), mock.patch.object(
                    collector.Store, "_parse_feedback", wraps=collector.Store._parse_feedback
                ) as parse:
                    store._recover_temporaries()
                self.assertEqual(parse.call_count, 0)
                self.assertFalse((state / "feedback.tmp").exists())
            finally:
                store.close()

    def test_feedback_write_budget_is_a_fatal_persistence_error(self):
        with tempfile.TemporaryDirectory() as temporary:
            store = collector.Store(private_state(Path(temporary)))
            try:
                with mock.patch.object(collector, "COLLECTOR_WRITE_BUDGET", 0):
                    with self.assertRaises(collector.FeedbackPersistenceError):
                        store.append(encoded(FEEDBACK))
                self.assertTrue(store.capture_exhausted)
            finally:
                store.close()

    def test_feedback_persistence_failure_closes_collector_and_reports_stopped(self):
        with tempfile.TemporaryDirectory() as temporary:
            original_ready = self._reserve_ready_fd()
            state = private_state(Path(temporary))
            store = collector.Store(state)
            manager = collector.Store(state)
            peer = None
            reader = None
            saved = None
            try:
                epoch = store.set_enabled(True)
                self.assertIsNotNone(epoch)
                worker, peer, reader, saved = self._start_collector(store, epoch or "")
                self.assertEqual(os.read(reader, 5), b"ready")
                self.assertTrue(peer.recv(collector.FEEDBACK_MAX_BYTES).startswith(collector.FEEDBACK_HEADER))
                with mock.patch.object(collector, "COLLECTOR_WRITE_BUDGET", 0):
                    peer.send(encoded(FEEDBACK))
                    worker.join(1)
                self.assertFalse(worker.is_alive())
                with self.assertRaises(OSError):
                    peer.send(encoded(FEEDBACK))
                self.assertEqual(
                    manager.capture_status(), (True, "not capturing: collector-stopped")
                )
            finally:
                if peer is not None:
                    peer.close()
                if reader is not None:
                    os.close(reader)
                if saved is not None:
                    self._restore_ready_fd(saved)
                manager.close()
                store.close()
                self._restore_ready_fd(original_ready)

    def test_busy_store_lock_drops_only_the_admitted_packet(self):
        with tempfile.TemporaryDirectory() as temporary:
            original_ready = self._reserve_ready_fd()
            state = private_state(Path(temporary))
            manager = collector.Store(state)
            store = collector.Store(state)
            peer = None
            reader = None
            saved = None
            try:
                epoch = store.set_enabled(True)
                self.assertIsNotNone(epoch)
                original_admit = store.admit
                original_append = store.append
                attempts = 0
                persisted = threading.Event()

                def busy_once(value):
                    nonlocal attempts
                    attempts += 1
                    if attempts == 1:
                        raise collector.StoreBusy("swipe learning store is busy")
                    original_admit(value)

                def note_append(*arguments, **keywords):
                    result = original_append(*arguments, **keywords)
                    persisted.set()
                    return result

                with mock.patch.object(store, "admit", side_effect=busy_once), mock.patch.object(
                    store, "append", side_effect=note_append
                ):
                    worker, peer, reader, saved = self._start_collector(store, epoch or "")
                    self.assertEqual(os.read(reader, 5), b"ready")
                    peer.recv(collector.FEEDBACK_MAX_BYTES)
                    peer.send(encoded(FEEDBACK))
                    peer.send(encoded(FEEDBACK))
                    self.assertTrue(persisted.wait(0.5))
                    manager.set_enabled(False)
                    peer.send(encoded(FEEDBACK))
                    worker.join(1)
                self.assertFalse(worker.is_alive())
                self.assertEqual(store._read_feedback()[-1][-1], 1)
            finally:
                if peer is not None:
                    peer.close()
                if reader is not None:
                    os.close(reader)
                if saved is not None:
                    self._restore_ready_fd(saved)
                manager.close()
                store.close()
                self._restore_ready_fd(original_ready)

    def test_startup_failure_waits_for_ordinary_store_contention(self):
        with tempfile.TemporaryDirectory() as temporary:
            original_ready = self._reserve_ready_fd()
            state = private_state(Path(temporary))
            store = collector.Store(state)
            manager = collector.Store(state)
            peer = None
            reader = None
            saved = None
            try:
                epoch = store.set_enabled(True)
                self.assertIsNotNone(epoch)
                with manager.locked(), mock.patch.object(
                    store, "startup_snapshot", side_effect=collector.InvalidRecord("bad state")
                ):
                    worker, peer, reader, saved = self._start_collector(store, epoch or "")
                    worker.join(0.05)
                    self.assertTrue(worker.is_alive())
                worker.join(1)
                self.assertFalse(worker.is_alive())
                self.assertEqual(os.read(reader, 5), b"")
                self.assertEqual(
                    manager.capture_status(), (True, "not capturing: invalid-feedback-state")
                )
            finally:
                if peer is not None:
                    peer.close()
                if reader is not None:
                    os.close(reader)
                if saved is not None:
                    self._restore_ready_fd(saved)
                manager.close()
                store.close()
                self._restore_ready_fd(original_ready)

    def test_store_lock_contention_fails_without_waiting(self):
        with tempfile.TemporaryDirectory() as temporary:
            state = private_state(Path(temporary))
            holder = collector.Store(state)
            contender = collector.Store(state)
            try:
                with holder.locked():
                    with self.assertRaisesRegex(OSError, "store is busy"):
                        contender.summary()
            finally:
                holder.close()
                contender.close()

    def test_transport_must_be_connected_unnamed_unix_datagram(self):
        left, right = socket.socketpair(socket.AF_UNIX, socket.SOCK_DGRAM)
        try:
            self.assertTrue(collector._valid_transport(left))
        finally:
            left.close()
            right.close()
        left, right = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            self.assertFalse(collector._valid_transport(left))
        finally:
            left.close()
            right.close()
        unconnected = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        try:
            self.assertFalse(collector._valid_transport(unconnected))
        finally:
            unconnected.close()
        network = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            network.connect(("127.0.0.1", 9))
            self.assertFalse(collector._valid_transport(network))
        finally:
            network.close()

if __name__ == "__main__":
    unittest.main()

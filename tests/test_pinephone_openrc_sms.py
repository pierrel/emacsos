#!/usr/bin/env python3
"""Unit tests for the stdin-only PinePhone root SMS helper."""

import importlib.util
from importlib.machinery import SourceFileLoader
import io
import json
import pathlib
import sys
import types
import unittest
from datetime import datetime, timedelta
import tempfile
import sqlite3
from unittest import mock


class FakeDbus(types.ModuleType):
    String = str
    ObjectPath = str

    @staticmethod
    def Dictionary(value, signature=None):
        assert signature == "sv"
        return dict(value)

    @staticmethod
    def Interface(obj, interface):
        return obj.interfaces[interface]

    @staticmethod
    def SystemBus():
        raise AssertionError("tests inject a bus")


sys.modules["dbus"] = FakeDbus("dbus")
SOURCE = pathlib.Path(__file__).parents[1] / "deploy/pinephone/openrc-sms-root"
SPEC = importlib.util.spec_from_loader(
    "openrc_sms_root", SourceFileLoader("openrc_sms_root", str(SOURCE)))
assert SPEC and SPEC.loader
SMS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SMS)


class Proxy:
    def __init__(self, **interfaces):
        self.interfaces = interfaces


class Manager:
    def __init__(self, objects):
        self.objects = objects

    def GetManagedObjects(self, timeout):
        assert timeout == 10
        return self.objects


class Messaging:
    def __init__(self, bus):
        self.bus = bus
        self.created = None
        self.deleted = None

    def Create(self, payload, timeout):
        assert timeout == 15
        self.created = payload
        self.bus.replacement_owner = ":1.99"
        return "/org/freedesktop/ModemManager1/SMS/12"

    def Delete(self, path, timeout):
        assert timeout == 10
        self.deleted = path


class SmsObject:
    def __init__(self):
        self.sent = 0

    def Send(self, timeout):
        assert timeout == 30
        self.sent += 1


class Bus:
    def __init__(self):
        self.owner = ":1.7"
        self.replacement_owner = self.owner
        self.names = []
        self.messaging = Messaging(self)
        self.message_properties = {}
        self.sms = SmsObject()
        self.manager = Manager({
            "/org/freedesktop/ModemManager1/Modem/3": {
                SMS.MESSAGING: {"Messages": []},
                SMS.THREE_GPP: {"RegistrationState": 1},
            },
        })

    def get_name_owner(self, name):
        assert name == SMS.MM_NAME
        return self.owner

    def get_object(self, name, path):
        self.names.append(name)
        # Every proxy must remain pinned to the captured owner even after
        # Create simulates replacement of the well-known service.
        assert name == self.owner
        if path == SMS.MM_ROOT:
            return Proxy(**{SMS.OBJECT_MANAGER: self.manager})
        if path in self.message_properties:
            def get_all(interface, timeout):
                assert interface == SMS.SMS and timeout == 2
                return self.message_properties[path]
            return Proxy(**{"org.freedesktop.DBus.Properties": types.SimpleNamespace(GetAll=get_all)})
        if path.endswith("/Modem/3"):
            return Proxy(**{SMS.MESSAGING: self.messaging})
        if path.endswith("/SMS/12"):
            return Proxy(**{SMS.SMS: self.sms})
        raise AssertionError(path)


class HelperTests(unittest.TestCase):
    def test_parse_preserves_exact_unicode_and_quotes(self):
        body = 'Hi “Ana” 👋\nSecond line'
        raw = json.dumps({"number": "+14155550123", "text": body}).encode()
        self.assertEqual(SMS.parse_request(raw), ("+14155550123", body))

    def test_parse_rejects_shape_number_nul_and_size(self):
        invalid = [
            {},
            {"number": "+14155550123", "text": "hi", "extra": 1},
            {"number": "Ana", "text": "hi"},
            {"number": "+14155550123", "text": "a\0b"},
            {"number": "+14155550123", "text": "a" * 4097},
        ]
        for value in invalid:
            with self.subTest(value=value), self.assertRaises(ValueError):
                SMS.parse_request(json.dumps(value).encode())

    def test_parse_rejects_oversized_wire_before_json(self):
        with self.assertRaises(ValueError):
            SMS.parse_request(b"x" * (SMS.MAX_REQUEST_BYTES + 1))

    def test_wire_bound_allows_worst_case_valid_json_escaping(self):
        body = "\x01" * SMS.MAX_BODY_BYTES
        raw = json.dumps({"number": "+14155550123", "text": body}).encode()
        self.assertLessEqual(len(raw), SMS.MAX_REQUEST_BYTES)
        self.assertEqual(SMS.parse_request(raw), ("+14155550123", body))

    def test_send_pins_unique_owner_and_preserves_payload(self):
        bus = Bus()
        self.assertEqual(SMS.send_sms(bus, "+14155550123", 'Exact “text”'), "sent")
        self.assertEqual(bus.messaging.created,
                         {"number": "+14155550123", "text": 'Exact “text”'})
        self.assertEqual(bus.sms.sent, 1)
        self.assertEqual(bus.messaging.deleted,
                         "/org/freedesktop/ModemManager1/SMS/12")
        self.assertTrue(bus.names)
        self.assertEqual(set(bus.names), {":1.7"})

    def test_zero_or_multiple_modems_are_definite_failures(self):
        for objects, expected in [
            ({}, "not-sent:no-modem"),
            ({"/m/1": {SMS.MESSAGING: {}}, "/m/2": {SMS.MESSAGING: {}}},
             "not-sent:multiple-modems"),
        ]:
            bus = Bus()
            bus.manager.objects = objects
            self.assertEqual(SMS.send_sms(bus, "+14155550123", "hi"), expected)

    def test_precreate_proxy_failure_is_definitely_not_sent(self):
        bus = Bus()
        original = bus.get_object

        def fail_modem_proxy(name, path):
            if path.endswith("/Modem/3"):
                raise OSError("service unavailable")
            return original(name, path)

        bus.get_object = fail_modem_proxy
        self.assertEqual(SMS.send_sms(bus, "+14155550123", "hi"),
                         "not-sent:dbus-unavailable")

    def test_unregistered_modem_never_creates_an_sms(self):
        bus = Bus()
        bus.manager.objects["/org/freedesktop/ModemManager1/Modem/3"][
            SMS.THREE_GPP]["RegistrationState"] = 2
        self.assertEqual(SMS.send_sms(bus, "+14155550123", "hi"),
                         "not-sent:no-service")
        self.assertIsNone(bus.messaging.created)

    def test_create_or_send_failure_is_unknown(self):
        bus = Bus()
        bus.messaging.Create = lambda *_args, **_kwargs: (_ for _ in ()).throw(RuntimeError())
        self.assertEqual(SMS.send_sms(bus, "+14155550123", "hi"),
                         "unknown:create-failed")
        bus = Bus()
        bus.sms.Send = lambda *_args, **_kwargs: (_ for _ in ()).throw(RuntimeError())
        self.assertEqual(SMS.send_sms(bus, "+14155550123", "hi"),
                         "unknown:send-failed")

    def _run_main(self, raw, *, euid=0, argv=None, flock_error=None,
                  open_error=None):
        emitted = []
        database = sqlite3.connect(":memory:")
        database.row_factory = sqlite3.Row
        database.execute("CREATE TABLE messages (id TEXT PRIMARY KEY, direction TEXT, number TEXT, text TEXT, status TEXT, occurred_at TEXT, observation TEXT UNIQUE, ack_status TEXT)")
        source = raw if hasattr(raw, "read") else io.BytesIO(raw)
        stdin = types.SimpleNamespace(buffer=source)
        lock = mock.MagicMock()
        flock = mock.Mock(side_effect=flock_error)
        bus = Bus()
        with (
            mock.patch.object(SMS.os, "geteuid", return_value=euid),
            mock.patch.object(SMS.sys, "argv",
                              ["emacsos-openrc-sms"] if argv is None else argv),
            mock.patch.object(SMS.sys, "stdin", stdin),
            mock.patch.object(SMS.signal, "signal"),
            mock.patch.object(SMS.signal, "alarm"),
            mock.patch.object(SMS.fcntl, "flock", flock),
            mock.patch.object(SMS.dbus, "SystemBus", return_value=bus),
            mock.patch.object(SMS, "open", return_value=lock,
                              side_effect=open_error, create=True),
            mock.patch.object(SMS, "_emit", side_effect=emitted.append),
            mock.patch.object(SMS, "journal", return_value=database),
        ):
            status = SMS.main()
        return status, emitted, flock, bus

    def test_main_rejects_wrong_authority_or_arguments_before_input(self):
        for euid, argv in [
            (1000, ["emacsos-openrc-sms"]),
            (0, ["emacsos-openrc-sms", "secret"]),
        ]:
            with self.subTest(euid=euid, argv=argv):
                status, emitted, flock, _bus = self._run_main(
                    b'{"number":"+14155550123","text":"hi"}',
                    euid=euid, argv=argv)
                self.assertEqual(status, 2)
                self.assertEqual(emitted, ["not-sent:invalid-input"])
                flock.assert_not_called()

    def test_main_rejects_bad_input_before_lock_or_dbus(self):
        status, emitted, flock, bus = self._run_main(b'{"number":"Ana"}')
        self.assertEqual(status, 2)
        self.assertEqual(emitted, ["not-sent:invalid-input"])
        flock.assert_not_called()
        self.assertFalse(bus.names)

    def test_main_bounds_incomplete_input(self):
        source = mock.Mock()
        source.read.side_effect = SMS.InputTimeout()
        status, emitted, flock, _bus = self._run_main(source)
        self.assertEqual(status, 2)
        self.assertEqual(emitted, ["not-sent:input-timeout"])
        flock.assert_not_called()

    def test_main_reports_lock_contention_without_touching_dbus(self):
        status, emitted, _flock, bus = self._run_main(
            b'{"number":"+14155550123","text":"hi"}',
            flock_error=BlockingIOError())
        self.assertEqual(status, 1)
        self.assertEqual(emitted, ["not-sent:busy"])
        self.assertFalse(bus.names)

    def test_main_converts_lock_file_failure_to_controlled_not_sent(self):
        status, emitted, flock, _bus = self._run_main(
            b'{"number":"+14155550123","text":"hi"}',
            open_error=OSError("sensitive diagnostic"))
        self.assertEqual(status, 1)
        self.assertEqual(emitted, ["not-sent:dbus-unavailable"])
        flock.assert_not_called()

    def test_main_distinguishes_timeout_before_and_during_create(self):
        source = b'{"number":"+14155550123","text":"hi"}'
        for create_attempted, expected in [
            (False, "not-sent:time-limit"),
            (True, "unknown:time-limit"),
        ]:
            with self.subTest(create_attempted=create_attempted):
                def timeout(_bus, _number, _text, attempt):
                    attempt["create"] = create_attempted
                    raise SMS.InputTimeout()

                with mock.patch.object(SMS, "send_sms", side_effect=timeout):
                    status, emitted, _flock, _bus = self._run_main(source)
                self.assertEqual(status, 1)
                self.assertEqual(emitted, [expected])

    def test_main_emits_one_terminal_result_for_exact_request(self):
        raw = json.dumps(
            {"number": "+14155550123", "text": 'Exact “text” 👋'}
        ).encode()
        status, emitted, flock, bus = self._run_main(raw)
        self.assertEqual(status, 0)
        self.assertEqual(emitted, ["sent"])
        flock.assert_called_once()
        self.assertEqual(bus.messaging.created,
                         {"number": "+14155550123", "text": 'Exact “text” 👋'})




class JournalTests(unittest.TestCase):
    def test_lookup_is_exact_read_only_and_never_contacts_modem(self):
        with tempfile.TemporaryDirectory() as directory:
            with mock.patch.object(SMS, "JOURNAL_PATH", str(pathlib.Path(directory) / "messages.sqlite3")):
                connection = SMS.journal()
                SMS.begin_attempt(connection, "outbox_test", "+15555550100", 'Exact "text" 👋')
                before = list(connection.execute("SELECT * FROM messages"))
                connection.close()
                with mock.patch.object(SMS.dbus, "SystemBus", side_effect=AssertionError("lookup must not access modem")):
                    for identity, expected in (("outbox_test", "unknown"), ("missing", None)):
                        output = io.StringIO()
                        with mock.patch.object(SMS.sys, "stdout", output):
                            SMS.receipt_operation({"operation": "lookup", "message_id": identity})
                        value = json.loads(output.getvalue())["message"]
                        self.assertEqual(value["status"] if value else None, expected)
                        if value:
                            self.assertEqual((value["number"], value["text"]), ("+15555550100", 'Exact "text" 👋'))
                connection = SMS.journal()
                self.assertEqual([tuple(row) for row in connection.execute("SELECT * FROM messages")], [tuple(row) for row in before])
                connection.close()

    def test_write_before_effect_and_uncertain_replay_never_sends_again(self):
        with tempfile.TemporaryDirectory() as directory:
            with mock.patch.object(SMS, "JOURNAL_PATH", str(pathlib.Path(directory) / "private" / "messages.sqlite3")):
                connection = SMS.journal()
                status, created = SMS.begin_attempt(connection, "attempt1", "+15555550100", 'Exact "text" 👋')
                self.assertEqual((status, created), ("unknown", True))
                connection.close()  # crash before or after actual effect is indistinguishable
                connection = SMS.journal()
                self.assertEqual(SMS.begin_attempt(connection, "attempt1", "+15555550100", 'Exact "text" 👋'), ("unknown", False))
                with self.assertRaises(ValueError):
                    SMS.begin_attempt(connection, "attempt1", "+15555550100", "changed")
                connection.rollback()
                connection.execute("UPDATE messages SET status='sent' WHERE id='attempt1'")
                connection.commit()
                self.assertEqual(SMS.begin_attempt(connection, "attempt1", "+15555550100", 'Exact "text" 👋'), ("sent", False))
                self.assertEqual(SMS.begin_attempt(connection, "attempt2", "+15555550100", 'Exact "text" 👋'), ("unknown", True))
                connection.close()

    def test_receipt_ack_of_unknown_cannot_hide_later_terminal_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            with mock.patch.object(SMS, "JOURNAL_PATH", str(pathlib.Path(directory) / "private" / "messages.sqlite3")):
                connection = SMS.journal()
                SMS.begin_attempt(connection, "attempt1", "+15555550100", "hi")
                connection.execute("UPDATE messages SET ack_status='unknown',status='sent'")
                connection.commit()
                self.assertEqual(connection.execute("SELECT id FROM messages WHERE ack_status IS NULL OR ack_status != status").fetchone()[0], "attempt1")
                connection.close()


class ReceiptBudgetTests(unittest.TestCase):
    def test_maximum_escaped_receipts_drain_in_finite_bounded_batches(self):
        with tempfile.TemporaryDirectory() as directory:
            with mock.patch.object(SMS, "JOURNAL_PATH", str(pathlib.Path(directory) / "private" / "messages.sqlite3")):
                connection = SMS.journal()
                for index in range(9):
                    SMS.begin_attempt(connection, 'message' + str(index), '+15555550100', '\x01' * 4096)
                connection.close()
                ids = []
                for _ in range(3):
                    output = io.StringIO()
                    with mock.patch.object(SMS.sys, 'stdout', output):
                        SMS.receipt_operation({'operation': 'receipts'})
                    self.assertLess(len(output.getvalue().encode()), 128 * 1024)
                    rows = json.loads(output.getvalue())['receipts']
                    ids.extend(row['id'] for row in rows)
                    with mock.patch.object(SMS.sys, 'stdout', io.StringIO()):
                        for row in rows:
                            SMS.receipt_operation({'operation': 'ack', 'message_id': row['id'], 'status': row['status']})
                self.assertEqual(len(set(ids)), 9)



class IncomingObservationTests(unittest.TestCase):
    def test_punctuation_empty_text_and_distinct_objects_are_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            with mock.patch.object(SMS, 'JOURNAL_PATH', str(pathlib.Path(directory) / 'private' / 'messages.sqlite3')):
                connection = SMS.journal()
                bus = Bus()
                for index in (21, 22):
                    path = f'/org/freedesktop/ModemManager1/SMS/{index}'
                    bus.manager.objects['/org/freedesktop/ModemManager1/Modem/3'][SMS.MESSAGING]['Messages'].append(path)
                    bus.message_properties[path] = {'State': 3, 'Number': 'T-Mobile', 'Text': ''}
                with mock.patch.object(SMS, 'Path', return_value=types.SimpleNamespace(read_text=lambda: 'synthetic-boot')):
                    SMS.collect_incoming(connection, bus)
                    SMS.collect_incoming(connection, bus)
                rows = connection.execute("SELECT id,number,text FROM messages").fetchall()
                self.assertEqual(len(rows), 2)
                self.assertNotEqual(rows[0]['id'], rows[1]['id'])
                self.assertTrue(all(row['number'] == 'T-Mobile' and row['text'] == '' for row in rows))
                connection.close()

    def test_large_escaped_incoming_receipts_still_drain_under_transport_cap(self):
        with tempfile.TemporaryDirectory() as directory:
            with mock.patch.object(SMS, 'JOURNAL_PATH', str(pathlib.Path(directory) / 'private' / 'messages.sqlite3')):
                connection = SMS.journal()
                for index in range(5):
                    connection.execute("INSERT INTO messages (id,direction,number,text,status,occurred_at,observation,ack_status) VALUES (?, 'incoming', '', ?, 'received', '2026-10-24T00:00:00+00:00', ?, NULL)", ('large'+str(index), '\x01'*SMS.MAX_INCOMING_BYTES, 'observation'+str(index)))
                connection.commit(); connection.close()
                seen = []
                for _ in range(5):
                    output = io.StringIO()
                    with mock.patch.object(SMS.sys, 'stdout', output): SMS.receipt_operation({'operation': 'receipts'})
                    self.assertLess(len(output.getvalue().encode()), 2*1024*1024)
                    rows = json.loads(output.getvalue())['receipts']
                    self.assertEqual(len(rows), 1)
                    seen.append(rows[0]['id'])
                    with mock.patch.object(SMS.sys, 'stdout', io.StringIO()):
                        SMS.receipt_operation({'operation':'ack', 'message_id':rows[0]['id'], 'status':'received'})
                self.assertEqual(len(set(seen)), 5)



class RetryFairnessTests(unittest.TestCase):
    def test_four_rejected_receipts_cannot_starve_later_messages(self):
        with tempfile.TemporaryDirectory() as directory:
            with mock.patch.object(SMS, 'JOURNAL_PATH', str(pathlib.Path(directory) / 'private' / 'messages.sqlite3')):
                connection = SMS.journal()
                for index in range(6): SMS.begin_attempt(connection, 'message'+str(index), '+15555550100', 'hi')
                connection.close()
                batches = []
                for _ in range(2):
                    output = io.StringIO()
                    with mock.patch.object(SMS.sys, 'stdout', output): SMS.receipt_operation({'operation':'receipts'})
                    batches.append([row['id'] for row in json.loads(output.getvalue())['receipts']])
                    # No ACK: simulate four permanently rejected HTTP400 handoffs.
                self.assertEqual(batches[0], ['message0','message1','message2','message3'])
                self.assertIn('message4', batches[1]); self.assertIn('message5', batches[1])
                connection = SMS.journal()
                self.assertEqual(connection.execute('SELECT COUNT(*) FROM messages WHERE ack_status IS NULL').fetchone()[0], 6)
                connection.close()


class LeafFailureTests(unittest.TestCase):
    def test_unreadable_listed_leaf_does_not_hide_later_received_message(self):
        with tempfile.TemporaryDirectory() as directory:
            with mock.patch.object(SMS, 'JOURNAL_PATH', str(pathlib.Path(directory)/'private'/'messages.sqlite3')):
                connection=SMS.journal();bus=Bus()
                paths=['/org/freedesktop/ModemManager1/SMS/20','/org/freedesktop/ModemManager1/SMS/21']
                bus.manager.objects['/org/freedesktop/ModemManager1/Modem/3'][SMS.MESSAGING]['Messages']=paths
                bus.message_properties[paths[1]]={'State':3,'Number':'CITY BANK','Text':'still captured'}
                with mock.patch.object(SMS,'Path',return_value=types.SimpleNamespace(read_text=lambda:'synthetic-boot')):
                    SMS.collect_incoming(connection,bus)
                row=connection.execute('SELECT number,text FROM messages').fetchone()
                self.assertEqual(tuple(row),('CITY BANK','still captured'))
                connection.close()


class RetainedInventoryTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.patch = mock.patch.object(SMS, 'JOURNAL_PATH', str(pathlib.Path(self.directory.name)/'private'/'messages.sqlite3'))
        self.patch.start()
        self.connection = SMS.journal()
        self.bus = Bus()

    def tearDown(self):
        self.connection.close()
        self.patch.stop()
        self.directory.cleanup()

    def messages(self, indices):
        paths = [f'/org/freedesktop/ModemManager1/SMS/{index}' for index in indices]
        self.bus.manager.objects['/org/freedesktop/ModemManager1/Modem/3'][SMS.MESSAGING]['Messages'] = paths
        self.bus.message_properties = {path: {'State':3, 'Number':'+15555550100', 'Text':'identical',
                                             'Timestamp':'2026-10-26T01:00:00+00:00'} for path in paths}
        return paths

    def collect(self):
        SMS.collect_incoming(self.connection, self.bus)
        return [dict(row) for row in self.connection.execute('SELECT * FROM messages ORDER BY rowid')]

    def test_original_timestamp_and_multiplicity_survive_reenumeration(self):
        self.messages([20,21])
        first = self.collect()
        self.assertEqual(len(first),2)
        self.assertTrue(all(not row['archive_only'] for row in first))
        self.assertTrue(all(row['occurred_at']=='2026-10-26T01:00:00+00:00' for row in first))
        self.assertNotEqual(first[0]['id'],first[1]['id'])
        self.bus.owner=':1.99'
        self.messages([0,1])
        self.assertEqual(self.collect(),first)
        self.messages([0,1,2])
        after=self.collect()
        self.assertEqual(len(after),3)
        self.assertFalse(after[-1]['archive_only'])

    def test_exact_legacy_bootstrap_preserves_uuid_time_and_ack(self):
        self.messages([20])
        boot=pathlib.Path('/proc/sys/kernel/random/boot_id').read_text().strip()
        observation=boot+':'+self.bus.owner+':/org/freedesktop/ModemManager1/SMS/20'
        self.connection.execute("INSERT INTO messages (id,direction,number,text,status,occurred_at,observation,ack_status) VALUES ('legacy','incoming','+15555550100','identical','received','2026-10-20T00:00:00+00:00',?,'received')",(observation,))
        self.connection.commit()
        before=[dict(row) for row in self.connection.execute('SELECT * FROM messages')]
        before[0]['archive_only']=1
        self.assertEqual(self.collect(),before)
        self.bus.owner=':1.100';self.messages([0])
        self.assertEqual(self.collect(),before)

    def test_partial_identical_bootstrap_does_not_reuse_mapped_uuid(self):
        paths=self.messages([20,21])
        del self.bus.message_properties[paths[0]]
        first=self.collect()
        self.assertEqual(len(first),1)
        self.messages([20,21])
        after=self.collect()
        self.assertEqual(len(after),2)
        self.assertEqual(after[0]['id'],first[0]['id'])
        self.assertNotEqual(after[0]['id'],after[1]['id'])
        self.assertTrue(all(not row['archive_only'] for row in after))

    def test_partial_namespace_publication_retains_original_sms_timestamp(self):
        self.messages([20]); first=self.collect()
        self.bus.owner=':1.99'; self.messages([0]); self.collect()
        self.messages([0,1])
        after=self.collect()
        self.assertEqual(len(after),2)
        self.assertEqual(after[-1]['occurred_at'],first[0]['occurred_at'])

    def test_failed_leaf_delayed_capture_uses_sms_timestamp(self):
        paths=self.messages([20])
        del self.bus.message_properties[paths[0]]
        self.collect()
        self.messages([20])
        row=self.collect()[0]
        self.assertEqual(row['occurred_at'],'2026-10-26T01:00:00+00:00')
        self.assertFalse(row['archive_only'])

    def test_missing_invalid_and_naive_timestamp_are_archive_only_without_now(self):
        for timestamp in (None, '', 'bad', '2026-10-26T01:00:00'):
            with self.subTest(timestamp=timestamp):
                paths=self.messages([30])
                if timestamp is None:
                    del self.bus.message_properties[paths[0]]['Timestamp']
                else:
                    self.bus.message_properties[paths[0]]['Timestamp']=timestamp
                self.collect()
        rows=self.connection.execute('SELECT occurred_at,archive_only FROM messages').fetchall()
        self.assertTrue(all(row['occurred_at'] is None and row['archive_only'] for row in rows))
        self.assertEqual(len(rows),3)  # Missing and empty are the same absent timestamp.

    def test_timezone_offset_is_preserved_and_mutable_fields_do_not_replay(self):
        paths=self.messages([20])
        self.bus.message_properties[paths[0]]['Timestamp']='2026-10-25T16:06:32-07'
        first=self.collect()
        self.assertEqual(first[0]['occurred_at'],'2026-10-25T16:06:32-07:00')
        self.bus.message_properties[paths[0]].update(Storage=2,DeliveryState=1)
        self.assertEqual(self.collect(),first)

    def test_reused_path_different_timestamp_preserves_independent_content(self):
        paths=self.messages([20]);first=self.collect()
        self.bus.message_properties[paths[0]]['Timestamp']='2026-10-26T02:00:00+00:00'
        after=self.collect()
        self.assertEqual(len(after),2)
        self.assertNotEqual(after[0]['id'],after[1]['id'])
        self.assertEqual(after[0],first[0])

    def test_legacy_schema_migration_preserves_payload_time_and_ack(self):
        self.connection.close()
        pathlib.Path(SMS.JOURNAL_PATH).unlink()
        old=sqlite3.connect(SMS.JOURNAL_PATH)
        old.execute('CREATE TABLE messages (id TEXT PRIMARY KEY,direction TEXT,number TEXT,text TEXT,status TEXT,occurred_at TEXT,observation TEXT UNIQUE,ack_status TEXT)')
        old.execute("INSERT INTO messages VALUES ('old','incoming','source','history','received','2026-10-25T00:00:00+00:00','oldowner:path','received')")
        old.execute("INSERT INTO messages VALUES ('out','outgoing','dest','hi','sent','2026-10-25T00:00:00+00:00',NULL,'sent')")
        old.commit();old.close()
        pathlib.Path(SMS.JOURNAL_PATH).chmod(0o600)
        self.connection=SMS.journal()
        incoming=self.connection.execute("SELECT * FROM messages WHERE id='old'").fetchone()
        self.assertEqual((incoming['text'],incoming['occurred_at'],incoming['ack_status'],incoming['archive_only']),('history','2026-10-25T00:00:00+00:00','received',1))
        outgoing=self.connection.execute("SELECT * FROM messages WHERE id='out'").fetchone()
        self.assertEqual((outgoing['status'],outgoing['ack_status'],outgoing['archive_only']),('sent','sent',0))
        cutoff=self.connection.execute('SELECT occurred_at FROM incoming_cutover').fetchone()[0]
        boundary=datetime.fromisoformat(cutoff)
        for index,seconds in enumerate((-1,0,1),40):
            paths=self.messages([index])
            self.bus.message_properties[paths[0]]['Timestamp']=(boundary+timedelta(seconds=seconds)).isoformat()
            self.collect()
        flags=[row[0] for row in self.connection.execute("SELECT archive_only FROM messages WHERE number='+15555550100' ORDER BY rowid")]
        self.assertEqual(flags,[1,1,0])
        self.connection.close();self.connection=SMS.journal()
        self.assertEqual(self.connection.execute('SELECT occurred_at FROM incoming_cutover').fetchone()[0],cutoff)


if __name__ == '__main__': unittest.main()

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
import signal
import time
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
    def test_punctuation_empty_text_preserved_and_identical_objects_collapse(self):
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
                self.assertEqual(len(rows), 1)
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

    def alert_poll(self):
        output = io.StringIO()
        with mock.patch.object(SMS.dbus, 'SystemBus', return_value=self.bus), mock.patch.object(SMS.sys, 'stdout', output):
            SMS.receipt_operation({'operation':'alerts'})
        return json.loads(output.getvalue())['alerts']

    def activate_alerts(self):
        self.connection.execute("UPDATE incoming_alert_start SET occurred_at='2026-10-26T00:00:00+00:00'")
        self.connection.commit()

    def test_local_alerts_skip_fifteen_old_reenumerated_objects_then_claim_new_once(self):
        self.activate_alerts()
        self.messages(range(15))
        for value in self.bus.message_properties.values(): value['Timestamp']='2026-10-25T23:00:00+00:00'
        self.assertEqual([self.alert_poll() for _ in range(5)], [[]]*5)
        original=[dict(row) for row in self.connection.execute('SELECT * FROM messages ORDER BY rowid')]
        self.assertEqual(len(original),1)
        self.bus.owner=':1.99'
        self.messages(range(200,215))
        for value in self.bus.message_properties.values(): value['Timestamp']='2026-10-25T23:00:00+00:00'
        self.assertEqual([self.alert_poll() for _ in range(5)], [[]]*5)
        self.assertEqual([dict(row) for row in self.connection.execute('SELECT * FROM messages ORDER BY rowid')],original)
        path='/org/freedesktop/ModemManager1/SMS/215'
        self.bus.manager.objects['/org/freedesktop/ModemManager1/Modem/3'][SMS.MESSAGING]['Messages'].append(path)
        self.bus.message_properties[path]={'State':3,'Number':'+15555550100','Text':'genuinely new',
                                           'Timestamp':'2026-10-26T01:00:00+00:00'}
        ids=[identity for _ in range(5) for identity in self.alert_poll()]
        self.assertEqual(len(ids),1)
        self.assertEqual(self.alert_poll(),[])
        self.connection.execute("UPDATE messages SET ack_status=status")
        self.connection.commit()
        self.assertEqual(self.alert_poll(),[])
        self.assertEqual(self.connection.execute('SELECT occurred_at FROM incoming_alert_start').fetchone()[0],
                         '2026-10-26T00:00:00+00:00')

    def test_local_alerts_identicals_collapse_and_survive_restart_and_ack(self):
        self.activate_alerts()
        paths=self.messages([20,21])
        for value in self.bus.message_properties.values(): value['State']=2
        self.assertEqual(self.alert_poll(),[])
        for value in self.bus.message_properties.values(): value['State']=3
        ids=self.alert_poll()
        self.assertEqual(len(ids),1)
        self.connection.close()
        self.connection=SMS.journal()
        self.bus.owner=':1.99'
        self.messages([30,31])
        self.assertEqual(self.alert_poll(),[])
        self.assertEqual(self.connection.execute('SELECT occurred_at FROM incoming_alert_start').fetchone()[0],
                         '2026-10-26T00:00:00+00:00')

    def test_local_alerts_missing_and_equal_source_times_stay_history(self):
        self.activate_alerts()
        paths=self.messages([20,21,22])
        for path,value in zip(paths, ['', 'invalid', '2026-10-26T00:00:00+00:00']):
            self.bus.message_properties[path]['Timestamp']=value
        self.assertEqual(self.alert_poll(),[])

    def test_original_timestamp_and_content_identity_survive_reenumeration(self):
        self.messages([20,21])
        first = self.collect()
        self.assertEqual(len(first),1)
        self.assertFalse(first[0]['archive_only'])
        self.assertEqual(first[0]['occurred_at'],'2026-10-26T01:00:00+00:00')
        self.bus.owner=':1.99'
        self.messages([0,1,2])
        self.assertEqual(self.collect(),first)

    def test_legacy_inventory_maps_to_existing_id_without_rewriting_history(self):
        self.messages([20])
        content=json.dumps(['+15555550100','identical',[],
                            '2026-10-26T01:00:00+00:00','',0,-1],separators=(',',':'))
        self.connection.execute('CREATE TABLE incoming_inventory (content TEXT,ordinal INTEGER,message_id TEXT)')
        for ordinal in (1,2):
            identity='legacy'+str(ordinal)
            self.connection.execute("INSERT INTO messages (id,direction,number,text,status,occurred_at,observation,ack_status) VALUES (?, 'incoming','+15555550100','identical','received','2026-10-20T00:00:00+00:00',?,'received')",(identity,'oldnamespace'+str(ordinal)))
            self.connection.execute('INSERT INTO incoming_inventory VALUES (?,?,?)',(content,ordinal,identity))
        self.connection.execute('DROP TABLE incoming_keys')
        self.connection.commit()
        before=[dict(row) for row in self.connection.execute('SELECT * FROM messages ORDER BY rowid')]
        self.connection.close();self.connection=SMS.journal()
        self.assertEqual(self.collect(),before)
        self.assertEqual(self.connection.execute('SELECT message_id FROM incoming_keys').fetchone()[0],'legacy1')
        self.bus.owner=':1.100';self.messages([0])
        self.assertEqual(self.collect(),before)

    def test_partial_identical_observations_collapse_to_existing_identity(self):
        paths=self.messages([20,21])
        del self.bus.message_properties[paths[0]]
        first=self.collect()
        self.assertEqual(len(first),1)
        self.messages([20,21])
        after=self.collect()
        self.assertEqual(len(after),1)
        self.assertEqual(after[0]['id'],first[0]['id'])
        self.assertTrue(all(not row['archive_only'] for row in after))

    def test_partial_namespace_publication_retains_original_sms_timestamp(self):
        self.messages([20]); first=self.collect()
        self.bus.owner=':1.99'; self.messages([0]); self.collect()
        self.messages([0,1])
        after=self.collect()
        self.assertEqual(len(after),1)
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
        paths=self.messages([30,31,32,33])
        for path,timestamp in zip(paths,(None,'','bad','2026-10-26T01:00:00')):
            if timestamp is None:
                del self.bus.message_properties[path]['Timestamp']
            else:
                self.bus.message_properties[path]['Timestamp']=timestamp
        rows=self.collect()
        self.assertEqual(len(rows),3)
        self.assertTrue(all(row['occurred_at'] is None and row['archive_only'] for row in rows))

    def test_timezone_offset_is_preserved_and_mutable_fields_do_not_replay(self):
        paths=self.messages([20])
        self.bus.message_properties[paths[0]]['Timestamp']='2026-10-25T16:06:32-07'
        first=self.collect()
        self.assertEqual(first[0]['occurred_at'],'2026-10-25T16:06:32-07:00')
        self.bus.message_properties[paths[0]].update(Storage=2,DeliveryState=1)
        self.assertEqual(self.collect(),first)

    def test_added_hint_reads_new_completed_sms_before_large_retained_store_and_slow_leaf(self):
        self.activate_alerts()
        for count in (15,1000):
            with self.subTest(retained=count):
                paths=self.messages(range(count))
                for properties in self.bus.message_properties.values():
                    properties['Timestamp']='2026-10-25T23:00:00+00:00'
                fresh='/org/freedesktop/ModemManager1/SMS/99999'
                self.bus.manager.objects['/org/freedesktop/ModemManager1/Modem/3'][SMS.MESSAGING]['Messages'].append(fresh)
                self.bus.message_properties[fresh]={'State':3,'Number':'+15555550100','Text':f'new arrival {count}',
                                                    'Timestamp':'2026-10-28T00:01:00+00:00'}
                original=self.bus.get_object;reads=[]
                def object_for(owner,path):
                    obj=original(owner,path)
                    if path in self.bus.message_properties:
                        reads.append(path)
                        if path==paths[0]:
                            def unavailable(*args,**kwargs):raise TimeoutError('synthetic slow leaf')
                            obj.interfaces['org.freedesktop.DBus.Properties'].GetAll=unavailable
                    return obj
                with mock.patch.object(self.bus,'get_object',side_effect=object_for):
                    SMS.collect_incoming(self.connection,self.bus,hint=fresh)
                self.assertEqual(reads[0],fresh)
                self.assertEqual(len(reads),4)
                rows=self.connection.execute("SELECT * FROM messages WHERE text=?",(f'new arrival {count}',)).fetchall()
                self.assertEqual(len(rows),1)
                self.assertEqual(rows[0]['occurred_at'],'2026-10-28T00:01:00+00:00')
                self.assertEqual(len(SMS.claim_incoming_alerts(self.connection)),1)
                self.assertEqual(SMS.claim_incoming_alerts(self.connection),[])

    def test_multipart_completion_hint_does_not_wait_for_history_sweep(self):
        self.activate_alerts()
        paths=self.messages(range(1000))
        for properties in self.bus.message_properties.values():
            properties['Timestamp']='2026-10-25T23:00:00+00:00'
        multipart=paths[-1]
        self.bus.message_properties[multipart].update(State=2,Text='multipart new',Timestamp='2026-10-28T00:01:00+00:00')
        SMS.collect_incoming(self.connection,self.bus,hint=multipart)
        self.assertEqual(SMS.claim_incoming_alerts(self.connection),[])
        # Pinned MM emits PropertiesChanged State3, not another Added.
        self.bus.message_properties[multipart]['State']=3
        SMS.collect_incoming(self.connection,self.bus,hint=multipart)
        ids=SMS.claim_incoming_alerts(self.connection)
        self.assertEqual(len(ids),1)
        SMS.collect_incoming(self.connection,self.bus,hint=multipart)
        self.assertEqual(SMS.claim_incoming_alerts(self.connection),[])

    def test_equivalent_source_timezone_reobservations_share_one_identity(self):
        paths=self.messages([20])
        first=self.collect()
        self.bus.owner=':1.90';paths=self.messages([200])
        self.bus.message_properties[paths[0]]['Timestamp']='2026-10-25T18:00:00-07:00'
        self.assertEqual(self.collect(),first)

    def test_new_object_path_different_timestamp_preserves_independent_content(self):
        paths=self.messages([20]);first=self.collect()
        paths=self.messages([21])
        self.bus.message_properties[paths[0]]['Timestamp']='2026-10-26T02:00:00+00:00'
        after=self.collect()
        self.assertEqual(len(after),2)
        self.assertNotEqual(after[0]['id'],after[1]['id'])
        self.assertEqual(after[0],first[0])

    def test_real_alarm_preserves_completed_read_and_next_poll_progresses(self):
        paths=self.messages([20,21,22])
        self.bus.message_properties[paths[2]]['Text']='different message'
        original=self.bus.get_object
        blocked=[]
        def get_object(owner,path):
            obj=original(owner,path)
            if path==paths[1]:
                iface=obj.interfaces['org.freedesktop.DBus.Properties']
                def slow(*args,**kwargs):
                    blocked.append(path)
                    signal.setitimer(signal.ITIMER_REAL,.01)
                    time.sleep(1)
                iface.GetAll=slow
            return obj
        self.bus.get_object=get_object
        previous=signal.signal(signal.SIGALRM,SMS._alarm)
        try:
            with self.assertRaises(SMS.InputTimeout):self.collect()
        finally:
            signal.setitimer(signal.ITIMER_REAL,0)
            signal.signal(signal.SIGALRM,previous)
            self.connection.rollback()
        first=[dict(row) for row in self.connection.execute('SELECT * FROM messages')]
        self.assertEqual(len(first),1)
        # Next poll processes never-attempted22 before retrying failed21.
        try:
            signal.signal(signal.SIGALRM,SMS._alarm)
            with self.assertRaises(SMS.InputTimeout):self.collect()
        finally:
            signal.setitimer(signal.ITIMER_REAL,0)
            signal.signal(signal.SIGALRM,previous)
            self.connection.rollback()
        after=[dict(row) for row in self.connection.execute('SELECT * FROM messages ORDER BY rowid')]
        self.assertEqual(len(after),2)
        self.assertEqual(after[0],first[0])
        self.assertEqual(len(blocked),2)

    def test_failed_prefix_rotates_and_batched_identicals_collapse(self):
        paths=self.messages(list(range(20,29)))
        for path in paths[:4]:del self.bus.message_properties[path]
        self.assertEqual(self.collect(),[])
        after=self.collect()
        self.assertEqual(len(after),1)
        # Remaining good leaf gets a turn despite four permanently bad paths.
        after=self.collect()
        self.assertEqual(len(after),1)
        self.assertEqual(len({row['id'] for row in after}),1)
        self.bus.owner=':1.200';self.messages(list(range(40,45)))
        self.collect();after=self.collect()
        self.assertEqual(len(after),1)

    def test_same_path_new_source_timestamp_is_read_without_payload_cache(self):
        paths=self.messages([20]);first=self.collect()
        paths=self.messages([20])
        self.bus.message_properties[paths[0]]['Timestamp']='2026-10-26T02:00:00+00:00'
        after=self.collect()
        self.assertEqual(len(after),2)
        self.assertEqual(after[0],first[0])

    def test_content_key_and_message_roll_back_together_but_scan_progress_persists(self):
        self.messages([20])
        with mock.patch.object(SMS,'capture_incoming',side_effect=sqlite3.OperationalError('interrupted')):
            with self.assertRaises(sqlite3.OperationalError):self.collect()
        self.connection.rollback()
        self.assertEqual(self.connection.execute('SELECT COUNT(*) FROM incoming_keys').fetchone()[0],0)
        self.assertIsNotNone(self.connection.execute('SELECT path FROM incoming_scan').fetchone()[0])
        self.assertEqual(self.connection.execute('SELECT COUNT(*) FROM messages').fetchone()[0],0)
        self.assertEqual(len(self.collect()),1)

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
        self.assertEqual((incoming['alert_claimed'],outgoing['alert_claimed']),(1,1))
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

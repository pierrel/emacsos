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
        self.sms = SmsObject()
        self.manager = Manager({
            "/org/freedesktop/ModemManager1/Modem/3": {SMS.MESSAGING: {}},
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


if __name__ == "__main__":
    unittest.main()

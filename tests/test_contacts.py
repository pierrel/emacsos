import importlib.util
import os
from pathlib import Path

import pytest

spec = importlib.util.spec_from_file_location("contacts", Path(__file__).parent.parent / "phone-contacts.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def test_mapping_names_types_and_plain_fields(tmp_path):
    p = tmp_path / "contacts.yml"
    text = '''Alex Example:
  phone: "+12025550123"
  phone_satellite_backup: "2025550124"
  email: "alex@example.net"
  email_community: "alex.other@example.net"
  birthday: 1990-03-04
  notes: |
    A synthetic multiline note.
    Keep this field unchanged.
Jordan:
  name: Jordan Example
  phone_work: "+12025550125"
'''
    p.write_text(text)
    assert module.read_labels(p) == {
        "+12025550123": "Alex Example",
        "2025550124": "Alex Example [satellite_backup]",
        "+12025550125": "Jordan Example [work]",
    }
    assert p.read_text() == text


@pytest.mark.parametrize("text", [
    "Alex: [",
    "contacts: []",
    "Alex:\n  phone: 12025550123",
    "Alex:\n  phone: 'bad number'",
    "Alex:\n  password: secret",
    "Alex:\n  name: A\n  name: B",
    "Alex: &a {notes: *a}",
    "Alex: !!python/object/apply:os.system ['true']",
    "Alex:\n  phone_: '+12025550123'",
    "Alex:\n  notes: [unsupported, list]",
    "Alex:\n  birthday: 1990",
])
def test_invalid_data_rejected(tmp_path, text):
    p = tmp_path / "contacts.yml"
    p.write_text(text)
    with pytest.raises(Exception):
        module.read_labels(p)


def test_duplicate_numbers_are_ambiguous(tmp_path):
    p = tmp_path / "contacts.yml"
    p.write_text('Alex:\n  phone: "+12025550123"\nJordan:\n  phone_home: "+12025550123"\n')
    assert module.read_labels(p) == {}


def test_national_numbers_remain_exact(tmp_path):
    p = tmp_path / "contacts.yml"
    p.write_text('Alex:\n  phone: "2025550123"\n  phone_mobile: "+12025550123"\n')
    assert module.read_labels(p) == {
        "2025550123": "Alex", "+12025550123": "Alex [mobile]"}


def test_file_bound_and_special_file(tmp_path):
    p = tmp_path / "contacts.yml"
    p.write_bytes(b" " * (256 * 1024 + 1))
    with pytest.raises(ValueError):
        module.read_labels(p)
    p.unlink()
    os.mkfifo(p)
    with pytest.raises(ValueError):
        module.read_labels(p)

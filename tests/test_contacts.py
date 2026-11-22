import importlib.util
from pathlib import Path

spec = importlib.util.spec_from_file_location("contacts", Path(__file__).parent.parent / "phone-contacts.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def test_exact_lookup_and_ambiguity(tmp_path):
    p = tmp_path / "contacts.yaml"
    p.write_text('contacts:\n- name: Alex\n  phones: ["+12025550123", "2025550123"]\n')
    assert module.read_labels(p) == {"+12025550123": "Alex", "2025550123": "Alex"}


import pytest

@pytest.mark.parametrize("text", [
    "contacts: [",
    "contacts: {}",
    "contacts:\n- name: Alex\n  phones: [12025550123]",
    "contacts:\n- name: Alex\n  phones: ['bad number']",
    "contacts:\n- name: Alex\n  phones: []\n  password: secret",
    "contacts:\n- name: A\n  name: B\n  phones: []",
    "contacts: &a [*a]",
    "contacts: !!python/object/apply:os.system ['true']",
])
def test_invalid_data_rejected(tmp_path, text):
    p = tmp_path / "contacts.yaml"
    p.write_text(text)
    with pytest.raises(Exception):
        module.read_labels(p)

def test_duplicate_numbers_are_ambiguous(tmp_path):
    p = tmp_path / "contacts.yaml"
    p.write_text('contacts:\n- name: Alex\n  phones: ["+12025550123"]\n- name: Alex\n  phones: ["+12025550123"]\n')
    assert module.read_labels(p) == {}


def test_file_bound_and_special_file(tmp_path):
    p = tmp_path / "contacts.yaml"
    p.write_bytes(b" " * (256 * 1024 + 1))
    with pytest.raises(ValueError):
        module.read_labels(p)
    p.unlink()
    import os
    os.mkfifo(p)
    with pytest.raises(ValueError):
        module.read_labels(p)

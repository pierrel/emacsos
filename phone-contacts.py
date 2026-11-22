"""Validate a local contacts YAML file and emit display-only SMS labels.

No Git, network, contact resolution for sending, or file writes occur here.
"""
import os
import re
import resource
import stat
import sys


def read_labels(path):
    """Read the supported flat schema and omit every duplicated phone key."""
    import yaml

    # Aliases are not needed for the flat contact format. Reject them before
    # construction so a small document cannot expand into a huge object graph.
    class Loader(yaml.SafeLoader):
        pass

    def mapping(loader, node):
        pairs = loader.construct_pairs(node)
        result = {}
        for key, value in pairs:
            if not isinstance(key, str) or key in result:
                raise ValueError("duplicate or non-string key")
            result[key] = value
        return result

    Loader.add_constructor("tag:yaml.org,2002:map", mapping)
    descriptor = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise ValueError("not a regular file")
        raw = stream.read(256 * 1024 + 1)
    if len(raw) > 256 * 1024:
        raise ValueError("file too large")
    for token in yaml.scan(raw):
        if isinstance(token, (yaml.tokens.AliasToken,)):
            raise ValueError("aliases unsupported")
    data = yaml.load(raw, Loader=Loader)
    if not isinstance(data, dict) or set(data) != {"contacts"}:
        raise ValueError("expected contacts")
    contacts = data["contacts"]
    if not isinstance(contacts, list) or len(contacts) > 1000:
        raise ValueError("expected bounded list")
    labels = {}
    for contact in contacts:
        if not isinstance(contact, dict):
            raise ValueError("expected contact")
        if set(contact) - {"name", "phones", "emails", "aliases"}:
            raise ValueError("unsupported field")
        if not isinstance(contact.get("name"), str) or not contact["name"].strip():
            raise ValueError("expected name")
        if len(contact["name"]) > 128:
            raise ValueError("name too long")
        for field in ("phones", "emails", "aliases"):
            values = contact.get(field, [])
            if not isinstance(values, list) or len(values) > 16:
                raise ValueError("expected bounded string list")
            for value in values:
                if not isinstance(value, str) or not value or len(value) > 128:
                    raise ValueError("expected bounded string")
        if "phones" not in contact:
            raise ValueError("expected phones")
        for number in contact["phones"]:
            if not re.fullmatch(r"\+?[0-9]{5,15}", number):
                raise ValueError("expected exact SMS number")
            # Even two entries with the same name can be different people.
            labels[number] = None if number in labels else contact["name"]
    return {number: name for number, name in labels.items() if name is not None}


if __name__ == "__main__":
    import json
    resource.setrlimit(resource.RLIMIT_AS, (128 * 1024 * 1024,) * 2)
    resource.setrlimit(resource.RLIMIT_CPU, (2, 2))
    try:
        labels = read_labels(sys.stdin.read(4097))
        print(json.dumps(labels))
    except Exception:
        # Parser errors can quote private data. Only the UI's fixed notice is shown.
        sys.exit(1)

"""Validate a local contacts YAML file and emit display-only SMS labels.

No Git, network, contact resolution for sending, or file writes occur here.
"""
import os
import re
import resource
import stat
import sys


def read_labels(path):
    """Read contact-key mappings and omit every duplicated exact phone value."""
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
    # Birthdays are text, including date-looking YAML scalars. Never infer a date.
    Loader.add_constructor("tag:yaml.org,2002:timestamp", Loader.construct_scalar)
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
    if not isinstance(data, dict) or len(data) > 1000:
        raise ValueError("expected bounded contact mapping")
    labels = {}
    for key, contact in data.items():
        if not key.strip() or len(key) > 128 or not isinstance(contact, dict):
            raise ValueError("expected named contact mapping")
        name = contact.get("name", key)
        if not isinstance(name, str) or not name.strip() or len(name) > 128:
            raise ValueError("expected name")
        for field, value in contact.items():
            typed = any(field.startswith(prefix) and len(field) > len(prefix)
                        for prefix in ("phone_", "email_"))
            if field not in {"name", "phone", "email", "birthday", "notes"} and not typed:
                raise ValueError("unsupported field")
            if not isinstance(value, str):
                raise ValueError("expected string field")
            if field == "phone" or field.startswith("phone_"):
                if not re.fullmatch(r"\+?[0-9]{5,15}", value):
                    raise ValueError("expected exact SMS number")
                suffix = field[len("phone_"):] if field.startswith("phone_") else ""
                label = f"{name} [{suffix}]" if suffix else name
                # Two fields may identify different people or different phone types.
                labels[value] = None if value in labels else label
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

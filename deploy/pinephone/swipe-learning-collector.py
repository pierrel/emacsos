#!/usr/bin/env python3
"""Validate and retain bounded local swipe-learning evidence."""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import select
import socket
import stat
import sys
import time
from collections import OrderedDict
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterator

JSON_MAX = 4096
JOURNAL_HIGH_GESTURES = 2048
JOURNAL_LOW_GESTURES = 1536
JOURNAL_HIGH_BYTES = 8 * 1024 * 1024
JOURNAL_LOW_BYTES = 6 * 1024 * 1024
EXPORT_HIGH_COUNT = 4
EXPORT_LOW_COUNT = 3
EXPORT_HIGH_BYTES = 32 * 1024 * 1024
EXPORT_LOW_BYTES = 24 * 1024 * 1024
EXPORT_WRITE_BUDGET = 64 * 1024 * 1024
COLLECTOR_DATAGRAM_BUDGET = 8192
COLLECTOR_WRITE_BUDGET = 64 * 1024 * 1024
SHOW_PAGE_SIZE = 4
FEEDBACK_HEADER = b"feedback-v1\n"
FEEDBACK_MAX_ENTRIES = 32
FEEDBACK_MAX_BYTES = 5964
DEFAULT_STATE = Path("/var/lib/emacsos-lab/.local/state/emacsos/swipe-learning")

HEX32 = re.compile(r"[0-9a-f]{32}\Z")
HEX64 = re.compile(r"[0-9a-f]{64}\Z")
WORD = re.compile(r"[a-z]{2,24}\Z")
TRACE = re.compile(r"[a-z]{2,64}\Z")
ALGORITHM = re.compile(r"[a-z0-9-]{1,24}\Z")
OUTCOMES = {
    "top-committed",
    "alternate-selected",
    "explicit-lookup-failure",
    "explicit-user-misswipe",
    "retracted-then-reswiped",
    "manual-correction-ambiguous",
}


class InvalidRecord(ValueError):
    """A datagram or retained record violates the capture schema."""


class BudgetExhausted(RuntimeError):
    """The bounded collector lifetime has exhausted its admission budget."""


class EpochMismatch(RuntimeError):
    """The active collector no longer owns the enabled epoch."""


class FeedbackPersistenceError(OSError):
    """A valid feedback record could not be atomically retained."""


class StoreBusy(OSError):
    """A nonblocking management lock attempt found the store in use."""


def _collapsed_trace(trace: str) -> bool:
    return all(left != right for left, right in zip(trace, trace[1:]))


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise InvalidRecord("duplicate JSON member")
        result[key] = value
    return result


def _integer_token(token: str) -> int:
    if not re.fullmatch(r"-?(?:0|[1-9][0-9]*)", token) or token == "-0":
        raise InvalidRecord("invalid integer token")
    return int(token)


def _reject_float(_token: str) -> float:
    raise InvalidRecord("floating point is not allowed")


def _decode_json(raw: bytes) -> Any:
    try:
        return json.loads(
            raw.decode("ascii"),
            object_pairs_hook=_unique_object,
            parse_int=_integer_token,
            parse_float=_reject_float,
            parse_constant=_reject_float,
        )
    except (UnicodeDecodeError, json.JSONDecodeError, RecursionError) as error:
        raise InvalidRecord("invalid JSON") from error


def _integer(value: Any, minimum: int, maximum: int) -> bool:
    return type(value) is int and minimum <= value <= maximum


def _point(value: Any) -> bool:
    return (
        type(value) is list
        and len(value) == 2
        and all(_integer(item, -(2**31), 2**31 - 1) for item in value)
    )


def _identity(record: dict[str, Any]) -> tuple[str, int]:
    return record["session"], record["gesture"]


def validate_record(raw: bytes) -> dict[str, Any]:
    """Return one exact-schema wire record, or raise InvalidRecord."""
    if not raw or len(raw) > JSON_MAX or b"\x00" in raw:
        raise InvalidRecord("invalid datagram size")
    record = _decode_json(raw)
    if type(record) is not dict or not _integer(record.get("version"), 1, 1):
        raise InvalidRecord("invalid object or version")
    kind = record.get("type")
    if kind == "feedback":
        expected = {"type", "version", "algorithm", "dictionary", "trace", "word"}
        if set(record) != expected:
            raise InvalidRecord("invalid feedback fields")
        if not isinstance(record["algorithm"], str) or not ALGORITHM.fullmatch(
            record["algorithm"]
        ):
            raise InvalidRecord("invalid feedback algorithm")
        if not isinstance(record["dictionary"], str) or not HEX64.fullmatch(
            record["dictionary"]
        ):
            raise InvalidRecord("invalid feedback dictionary")
        if (
            not isinstance(record["trace"], str)
            or not TRACE.fullmatch(record["trace"])
            or not _collapsed_trace(record["trace"])
        ):
            raise InvalidRecord("invalid feedback trace")
        if not isinstance(record["word"], str) or not WORD.fullmatch(record["word"]):
            raise InvalidRecord("invalid feedback word")
        return record
    common = {"type", "version", "session", "gesture"}
    if not isinstance(record.get("session"), str) or not HEX32.fullmatch(
        record["session"]
    ):
        raise InvalidRecord("invalid session")
    if not _integer(record.get("gesture"), 1, 2**64 - 1):
        raise InvalidRecord("invalid gesture id")
    if kind == "gesture":
        expected = common | {
            "algorithm",
            "dictionary",
            "trace",
            "points",
            "geometry",
            "key_height",
            "candidates",
            "presentation",
        }
        if set(record) != expected:
            raise InvalidRecord("invalid gesture fields")
        trace = record["trace"]
        if not isinstance(trace, str) or not TRACE.fullmatch(trace):
            raise InvalidRecord("invalid trace")
        if not isinstance(record["algorithm"], str) or not ALGORITHM.fullmatch(
            record["algorithm"]
        ):
            raise InvalidRecord("invalid algorithm")
        if not isinstance(record["dictionary"], str) or not HEX64.fullmatch(
            record["dictionary"]
        ):
            raise InvalidRecord("invalid dictionary")
        if (
            type(record["points"]) is not list
            or len(record["points"]) != len(trace)
            or not all(_point(point) for point in record["points"])
            or type(record["geometry"]) is not list
            or len(record["geometry"]) != 26
            or not all(_point(point) for point in record["geometry"])
            or not _integer(record["key_height"], 1, 2**32 - 1)
        ):
            raise InvalidRecord("invalid geometry")
        candidates = record["candidates"]
        if type(candidates) is not list or len(candidates) > 3:
            raise InvalidRecord("invalid candidates")
        for index, candidate in enumerate(candidates, 1):
            if type(candidate) is not dict or set(candidate) != {
                "word",
                "score",
                "rank",
            }:
                raise InvalidRecord("invalid candidate fields")
            if (
                not isinstance(candidate["word"], str)
                or not WORD.fullmatch(candidate["word"])
                or not _integer(candidate["score"], 0, 2**64 - 1)
                or not _integer(candidate["rank"], index, index)
            ):
                raise InvalidRecord("invalid candidate")
        presentation = record["presentation"]
        if not candidates and presentation != "no-candidate":
            raise InvalidRecord("missing no-candidate presentation")
        if candidates and presentation != "top-queued":
            raise InvalidRecord("invalid candidate presentation")
    elif kind == "resolution":
        expected = common | {"outcome"}
        if record.get("outcome") == "alternate-selected":
            expected.add("selected_rank")
        if set(record) != expected or record.get("outcome") not in OUTCOMES:
            raise InvalidRecord("invalid resolution fields")
        if record["outcome"] == "alternate-selected" and not _integer(
            record.get("selected_rank"), 2, 3
        ):
            raise InvalidRecord("invalid selected rank")
    else:
        raise InvalidRecord("invalid record type")
    return record


def validate_pair(gesture: dict[str, Any], resolution: dict[str, Any]) -> None:
    """Reject a resolution incompatible with its observed decoder result."""
    if _identity(gesture) != _identity(resolution):
        raise InvalidRecord("resolution identity mismatch")
    count = len(gesture["candidates"])
    outcome = resolution["outcome"]
    if outcome == "alternate-selected" and resolution["selected_rank"] > count:
        raise InvalidRecord("selected rank was not presented")
    if outcome in {"explicit-lookup-failure", "explicit-user-misswipe"} and count != 0:
        raise InvalidRecord("no-candidate attribution has candidates")
    if outcome in {
        "top-committed",
        "alternate-selected",
        "retracted-then-reswiped",
        "manual-correction-ambiguous",
    } and count == 0:
        raise InvalidRecord("candidate outcome has no candidate")


def canonical(record: dict[str, Any]) -> bytes:
    """Encode a validated record deterministically as one JSONL line."""
    return json.dumps(record, separators=(",", ":"), ensure_ascii=True).encode() + b"\n"


class Store:
    """Private, locked journal plus derived feedback state for local controls."""

    def __init__(self, path: Path, create: bool = True):
        self.dir_fd = self._open_directory(path, create)
        try:
            if create:
                os.close(self._open("lock", os.O_RDWR | os.O_CREAT))
        except BaseException:
            os.close(self.dir_fd)
            raise
        self.admitted = 0
        self.written = 0
        self.capture_exhausted = False
        self._journal_signature: tuple[int, int, int, int] | None = None
        self._journal_records: list[dict[str, Any]] | None = None
        self._journal_episodes: OrderedDict[
            tuple[str, int], tuple[dict[str, Any], dict[str, Any] | None]
        ] | None = None

    @staticmethod
    def _open_directory(path: Path, create: bool) -> int:
        if not path.is_absolute():
            raise OSError("state directory must be absolute")
        current = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
        try:
            for part in path.parts[1:]:
                try:
                    child = os.open(
                        part,
                        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                        dir_fd=current,
                    )
                except FileNotFoundError:
                    if not create:
                        raise
                    os.mkdir(part, 0o700, dir_fd=current)
                    child = os.open(
                        part,
                        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                        dir_fd=current,
                    )
                    os.fsync(child)
                    os.fsync(current)
                os.close(current)
                current = child
            info = os.fstat(current)
            if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
                raise OSError("state directory is not private and owner-only")
            return current
        except BaseException:
            os.close(current)
            raise

    def close(self) -> None:
        os.close(self.dir_fd)

    def _open(self, name: str, flags: int, mode: int = 0o600) -> int:
        fd = os.open(
            name, flags | os.O_NOFOLLOW | os.O_NONBLOCK, mode, dir_fd=self.dir_fd
        )
        info = os.fstat(fd)
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != os.getuid()
            or info.st_nlink != 1
            or stat.S_IMODE(info.st_mode) != 0o600
        ):
            os.close(fd)
            raise OSError(f"unsafe state file: {name}")
        return fd

    @contextmanager
    def locked(self, wait: bool = False) -> Iterator[None]:
        fd = self._open("lock", os.O_RDWR)
        try:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | (0 if wait else fcntl.LOCK_NB))
            except BlockingIOError as error:
                raise StoreBusy("swipe learning store is busy") from error
            yield
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
            os.close(fd)

    def _read_journal(self, repair: bool = True) -> list[dict[str, Any]]:
        try:
            fd = self._open("journal.jsonl", os.O_RDWR if repair else os.O_RDONLY)
        except FileNotFoundError:
            return []
        try:
            size = os.fstat(fd).st_size
            if size > JOURNAL_HIGH_BYTES:
                raise InvalidRecord("journal exceeds hard bound")
            chunks: list[bytes] = []
            remaining = size + 1
            while remaining:
                chunk = os.read(fd, remaining)
                if not chunk:
                    break
                chunks.append(chunk)
                remaining -= len(chunk)
            data = b"".join(chunks)
            if data and not data.endswith(b"\n"):
                end = data.rfind(b"\n") + 1
                if repair:
                    os.ftruncate(fd, end)
                    os.fsync(fd)
                    os.fsync(self.dir_fd)
                data = data[:end]
        finally:
            os.close(fd)
        records = []
        for line in data.splitlines():
            records.append(validate_record(line))
        return records

    def _signature(self) -> tuple[int, int, int, int] | None:
        try:
            info = os.stat("journal.jsonl", dir_fd=self.dir_fd, follow_symlinks=False)
        except FileNotFoundError:
            return None
        return info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns

    def _load_journal(self) -> tuple[
        list[dict[str, Any]],
        OrderedDict[tuple[str, int], tuple[dict[str, Any], dict[str, Any] | None]],
    ]:
        signature = self._signature()
        if (
            self._journal_records is None
            or self._journal_episodes is None
            or signature != self._journal_signature
        ):
            self._journal_records = self._read_journal()
            self._journal_episodes = self._index(self._journal_records)
            self._journal_signature = self._signature()
        return self._journal_records, self._journal_episodes

    def _cache(
        self,
        records: list[dict[str, Any]],
        episodes: OrderedDict[
            tuple[str, int], tuple[dict[str, Any], dict[str, Any] | None]
        ],
    ) -> None:
        self._journal_records = records
        self._journal_episodes = episodes
        self._journal_signature = self._signature()

    def _recover_temporaries(self) -> None:
        changed = False
        for name in os.listdir(self.dir_fd):
            export_match = re.fullmatch(r"export-([1-9][0-9]*)\.tmp", name)
            if name not in {"journal.tmp", "export-budget.tmp", "feedback.tmp"} and not export_match:
                continue
            info = os.stat(name, dir_fd=self.dir_fd, follow_symlinks=False)
            if (
                not stat.S_ISREG(info.st_mode)
                or info.st_uid != os.getuid()
                or info.st_nlink != 1
                or stat.S_IMODE(info.st_mode) != 0o600
            ):
                raise OSError(f"unsafe state file: {name}")
            if export_match:
                final = f"export-{export_match.group(1)}.jsonl"
                try:
                    self._validate_export_temporary(name)
                    os.stat(final, dir_fd=self.dir_fd, follow_symlinks=False)
                except FileNotFoundError:
                    fd = self._open(name, os.O_RDONLY)
                    try:
                        os.fsync(fd)
                    finally:
                        os.close(fd)
                    os.rename(
                        name,
                        final,
                        src_dir_fd=self.dir_fd,
                        dst_dir_fd=self.dir_fd,
                    )
                    os.fsync(self.dir_fd)
                except InvalidRecord:
                    os.unlink(name, dir_fd=self.dir_fd)
                else:
                    os.unlink(name, dir_fd=self.dir_fd)
            elif name == "export-budget.tmp":
                data = str(EXPORT_WRITE_BUDGET).encode()
                fd = self._open(
                    "export-budget", os.O_WRONLY | os.O_CREAT | os.O_TRUNC
                )
                try:
                    view = memoryview(data)
                    while view:
                        view = view[os.write(fd, view) :]
                    os.fsync(fd)
                finally:
                    os.close(fd)
                os.unlink(name, dir_fd=self.dir_fd)
                os.fsync(self.dir_fd)
            elif name == "feedback.tmp":
                try:
                    self._parse_feedback(self._read_complete(name, FEEDBACK_MAX_BYTES))
                except InvalidRecord:
                    pass
                os.unlink(name, dir_fd=self.dir_fd)
            else:
                os.unlink(name, dir_fd=self.dir_fd)
            changed = True
        self._prune_exports()
        if changed:
            os.fsync(self.dir_fd)

    def _validate_export_temporary(self, name: str) -> None:
        fd = self._open(name, os.O_RDONLY)
        try:
            size = os.fstat(fd).st_size
            if size > JOURNAL_HIGH_BYTES + JOURNAL_HIGH_GESTURES * 128:
                raise InvalidRecord("oversized export temporary")
            chunks: list[bytes] = []
            received = 0
            while received <= size:
                chunk = os.read(fd, min(65536, size + 1 - received))
                if not chunk:
                    break
                chunks.append(chunk)
                received += len(chunk)
        finally:
            os.close(fd)
        data = b"".join(chunks)
        if data and not data.endswith(b"\n"):
            raise InvalidRecord("partial export temporary")
        gestures: dict[tuple[str, int], dict[str, Any]] = {}
        resolved: set[tuple[str, int]] = set()
        for line in data.splitlines():
            value = _decode_json(line)
            if type(value) is dict and value.get("type") == "pending":
                if set(value) != {"type", "version", "session", "gesture", "state"}:
                    raise InvalidRecord("invalid pending export record")
                if (
                    not _integer(value.get("version"), 1, 1)
                    or value.get("state") != "unresolved"
                    or not isinstance(value.get("session"), str)
                    or not HEX32.fullmatch(value["session"])
                    or not _integer(value.get("gesture"), 1, 2**64 - 1)
                    or _identity(value) not in gestures
                    or _identity(value) in resolved
                ):
                    raise InvalidRecord("invalid pending export record")
                resolved.add(_identity(value))
            else:
                record = validate_record(line)
                identity = _identity(record)
                if record["type"] == "gesture":
                    if identity in gestures:
                        raise InvalidRecord("duplicate export gesture")
                    gestures[identity] = record
                else:
                    if identity not in gestures or identity in resolved:
                        raise InvalidRecord("invalid export resolution")
                    validate_pair(gestures[identity], record)
                    resolved.add(identity)
        if set(gestures) != resolved:
            raise InvalidRecord("incomplete export temporary")

    def _charge(self, amount: int) -> None:
        if self.capture_exhausted or self.written + amount > COLLECTOR_WRITE_BUDGET:
            self._latch_exhausted()
            raise BudgetExhausted("collector write budget exhausted")
        self.written += amount

    def _admit(self, require_epoch: str | None) -> None:
        if require_epoch is not None and self._epoch_unlocked() != require_epoch:
            raise EpochMismatch("collector epoch is no longer enabled")
        self.admitted += 1
        if self.admitted > COLLECTOR_DATAGRAM_BUDGET:
            self._latch_exhausted()
            raise BudgetExhausted("collector datagram budget exhausted")

    def admit(self, require_epoch: str) -> None:
        """Charge one nonempty datagram before transport or schema admission."""
        with self.locked():
            self._admit(require_epoch)

    @staticmethod
    def _parse_feedback(data: bytes) -> list[tuple[str, str, str, str, int]]:
        if (
            not data
            or len(data) > FEEDBACK_MAX_BYTES
            or b"\x00" in data
            or not data.startswith(FEEDBACK_HEADER)
        ):
            raise InvalidRecord("invalid feedback state")
        entries: list[tuple[str, str, str, str, int]] = []
        for line in data[len(FEEDBACK_HEADER) :].splitlines(keepends=True):
            if not line.endswith(b"\n") or len(entries) >= FEEDBACK_MAX_ENTRIES:
                raise InvalidRecord("invalid feedback state")
            fields = line[:-1].split(b"\t")
            if len(fields) != 5:
                raise InvalidRecord("invalid feedback state")
            try:
                algorithm, dictionary, trace, word, count_text = (
                    field.decode("ascii") for field in fields
                )
            except UnicodeDecodeError as error:
                raise InvalidRecord("invalid feedback state") from error
            if (
                not ALGORITHM.fullmatch(algorithm)
                or not HEX64.fullmatch(dictionary)
                or not TRACE.fullmatch(trace)
                or not _collapsed_trace(trace)
                or not WORD.fullmatch(word)
                or not re.fullmatch(r"[1-9][0-9]{0,4}", count_text)
                or int(count_text) > 65535
            ):
                raise InvalidRecord("invalid feedback state")
            entry = (algorithm, dictionary, trace, word, int(count_text))
            if entry[:4] in [old[:4] for old in entries]:
                raise InvalidRecord("duplicate feedback state")
            entries.append(entry)
        if b"\n" not in data or not data.endswith(b"\n"):
            raise InvalidRecord("invalid feedback state")
        return entries

    @staticmethod
    def _feedback_bytes(entries: list[tuple[str, str, str, str, int]]) -> bytes:
        data = FEEDBACK_HEADER + b"".join(
            f"{algorithm}\t{dictionary}\t{trace}\t{word}\t{count}\n".encode()
            for algorithm, dictionary, trace, word, count in entries
        )
        if len(entries) > FEEDBACK_MAX_ENTRIES or len(data) > FEEDBACK_MAX_BYTES:
            raise InvalidRecord("feedback state exceeds bound")
        return data

    def _read_complete(self, name: str, maximum: int) -> bytes:
        """Read exactly one bounded regular state file or reject a short read."""
        fd = self._open(name, os.O_RDONLY)
        try:
            size = os.fstat(fd).st_size
            if size > maximum:
                raise InvalidRecord(f"oversized state file: {name}")
            chunks: list[bytes] = []
            remaining = size
            while remaining:
                chunk = os.read(fd, remaining)
                if not chunk:
                    raise InvalidRecord(f"partial state file: {name}")
                chunks.append(chunk)
                remaining -= len(chunk)
            if os.read(fd, 1):
                raise InvalidRecord(f"changed state file: {name}")
            return b"".join(chunks)
        finally:
            os.close(fd)

    def _read_feedback(self) -> list[tuple[str, str, str, str, int]]:
        try:
            return self._parse_feedback(
                self._read_complete("feedback.state", FEEDBACK_MAX_BYTES)
            )
        except FileNotFoundError:
            return []

    def _append_feedback(self, record: dict[str, Any]) -> None:
        try:
            entries = self._read_feedback()
            key = (record["algorithm"], record["dictionary"], record["trace"], record["word"])
            count = 1
            retained = []
            for old in entries:
                if old[:4] == key:
                    count = min(65535, old[4] + 1)
                else:
                    retained.append(old)
            if len(retained) == FEEDBACK_MAX_ENTRIES:
                retained.pop(0)
            retained.append((*key, count))
            data = self._feedback_bytes(retained)
            self._charge(len(data))
            self._replace("feedback.tmp", "feedback.state", data)
        except (InvalidRecord, BudgetExhausted, OSError) as error:
            raise FeedbackPersistenceError(str(error)) from error

    def _latch_exhausted(self) -> None:
        self.capture_exhausted = True
        fd = self._open("session-budget-exhausted", os.O_WRONLY | os.O_CREAT)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
        os.fsync(self.dir_fd)

    @staticmethod
    def _index(records: list[dict[str, Any]]) -> OrderedDict[
        tuple[str, int], tuple[dict[str, Any], dict[str, Any] | None]
    ]:
        episodes: OrderedDict[
            tuple[str, int], tuple[dict[str, Any], dict[str, Any] | None]
        ] = OrderedDict()
        for record in records:
            identity = _identity(record)
            if record["type"] == "gesture":
                if identity in episodes:
                    if episodes[identity][0] == record:
                        continue
                    raise InvalidRecord("conflicting duplicate gesture")
                episodes[identity] = (record, None)
            else:
                if identity not in episodes:
                    raise InvalidRecord("orphan resolution")
                gesture, old = episodes[identity]
                validate_pair(gesture, record)
                if old is not None:
                    if old == record:
                        continue
                    raise InvalidRecord("conflicting duplicate resolution")
                episodes[identity] = (gesture, record)
        return episodes

    def append(
        self, raw: bytes, require_epoch: str | None = None, admitted: bool = False
    ) -> bool:
        """Append one valid record; return False only for an exact duplicate."""
        with self.locked():
            self._recover_temporaries()
            if not admitted:
                self._admit(require_epoch)
            elif require_epoch is not None and self._epoch_unlocked() != require_epoch:
                raise EpochMismatch("collector epoch is no longer enabled")
            record = validate_record(raw)
            if record["type"] == "feedback":
                self._append_feedback(record)
                return True
            records, episodes = self._load_journal()
            identity = _identity(record)
            if identity in episodes:
                gesture, resolution = episodes[identity]
                old = gesture if record["type"] == "gesture" else resolution
                if old == record:
                    return False
                if record["type"] == "gesture" or resolution is not None:
                    raise InvalidRecord("conflicting duplicate")
                validate_pair(gesture, record)
            elif record["type"] == "resolution":
                raise InvalidRecord("orphan resolution")
            line = canonical(record)
            journal_missing = self._journal_signature is None
            current_size = self._journal_signature[2] if self._journal_signature else 0
            gesture_count = len(episodes)
            if (
                gesture_count + (record["type"] == "gesture")
                > JOURNAL_HIGH_GESTURES
                or current_size + len(line) > JOURNAL_HIGH_BYTES
            ):
                compacted = self._compacted([*records, record])
                self._charge(len(compacted))
                self._replace("journal.tmp", "journal.jsonl", compacted)
                records = self._read_journal()
                episodes = self._index(records)
                if identity not in episodes:
                    self._cache(records, episodes)
                    raise InvalidRecord("record was evicted by compaction")
                self._cache(records, episodes)
                return True
            else:
                self._charge(len(line))
            fd = self._open("journal.jsonl", os.O_WRONLY | os.O_APPEND | os.O_CREAT)
            try:
                view = memoryview(line)
                while view:
                    view = view[os.write(fd, view) :]
                os.fsync(fd)
            finally:
                os.close(fd)
            if journal_missing:
                os.fsync(self.dir_fd)
            records = [*records, record]
            if record["type"] == "gesture":
                episodes[identity] = (record, None)
            else:
                episodes[identity] = (episodes[identity][0], record)
            self._cache(records, episodes)
        return True

    def _compacted(self, records: list[dict[str, Any]]) -> bytes:
        episodes = list(self._index(records).values())
        kept: list[tuple[dict[str, Any], dict[str, Any] | None]] = []
        size = 0
        for episode in reversed(episodes):
            episode_size = len(canonical(episode[0])) + (
                len(canonical(episode[1])) if episode[1] else 0
            )
            if len(kept) >= JOURNAL_LOW_GESTURES or size + episode_size > JOURNAL_LOW_BYTES:
                break
            kept.append(episode)
            size += episode_size
        return b"".join(
            canonical(record)
            for episode in reversed(kept)
            for record in episode
            if record is not None
        )

    def _replace(self, temporary: str, destination: str, data: bytes) -> None:
        try:
            os.unlink(temporary, dir_fd=self.dir_fd)
        except FileNotFoundError:
            pass
        self._write_exclusive(temporary, data)
        os.rename(
            temporary,
            destination,
            src_dir_fd=self.dir_fd,
            dst_dir_fd=self.dir_fd,
        )
        os.fsync(self.dir_fd)

    def summary(self, include_records: bool = False, page: int = 0) -> dict[str, Any]:
        with self.locked():
            episodes = self._index(self._read_journal(repair=False))
            outcomes: dict[str, int] = {}
            pending = 0
            rendered = []
            for index, (gesture, resolution) in enumerate(episodes.values()):
                if resolution is None:
                    pending += 1
                else:
                    outcome = resolution["outcome"]
                    outcomes[outcome] = outcomes.get(outcome, 0) + 1
                if (
                    include_records
                    and page * SHOW_PAGE_SIZE
                    <= index
                    < (page + 1) * SHOW_PAGE_SIZE
                ):
                    rendered.append(
                        {
                            "gesture": gesture,
                            "resolution": resolution,
                            "state": "unresolved" if resolution is None else "resolved",
                        }
                    )
            enabled, capture = self._capture_status_unlocked()
            return {
                "enabled": enabled,
                "capture": capture,
                "gestures": len(episodes),
                "pending": pending,
                "outcomes": outcomes,
                "records": rendered,
                "page": page,
                "page_size": SHOW_PAGE_SIZE,
                "session_budget_exhausted": self.capture_exhausted
                or self._marker_exists("session-budget-exhausted"),
            }

    def export(self) -> tuple[str, int]:
        with self.locked():
            self._recover_temporaries()
            _, episodes = self._load_journal()
            sequence = self._next_sequence()
            final = f"export-{sequence}.jsonl"
            temporary = f"export-{sequence}.tmp"
            lines: list[bytes] = []
            for gesture, resolution in episodes.values():
                lines.append(canonical(gesture))
                if resolution is not None:
                    lines.append(canonical(resolution))
                else:
                    lines.append(canonical(
                        {
                            "type": "pending",
                            "version": 1,
                            "session": gesture["session"],
                            "gesture": gesture["gesture"],
                            "state": "unresolved",
                        }
                    ))
            data = b"".join(lines)
            budget = self._read_number("export-budget")
            if budget + len(data) > EXPORT_WRITE_BUDGET:
                raise OSError("export write budget exhausted; erase to reset it")
            self._replace(
                "export-budget.tmp", "export-budget", str(budget + len(data)).encode()
            )
            self._write_exclusive(temporary, data)
            os.rename(temporary, final, src_dir_fd=self.dir_fd, dst_dir_fd=self.dir_fd)
            os.fsync(self.dir_fd)
            self._prune_exports()
            return final, len(episodes)

    def _write_exclusive(self, name: str, data: bytes) -> None:
        fd = self._open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL)
        try:
            view = memoryview(data)
            while view:
                view = view[os.write(fd, view) :]
            os.fsync(fd)
        finally:
            os.close(fd)

    def _read_number(self, name: str) -> int:
        try:
            fd = self._open(name, os.O_RDONLY)
        except FileNotFoundError:
            return 0
        try:
            data = os.read(fd, 32)
            if os.read(fd, 1) or not re.fullmatch(rb"0|[1-9][0-9]*", data):
                raise OSError(f"invalid {name}")
            return int(data)
        finally:
            os.close(fd)

    def _exports(self) -> list[tuple[int, str, int]]:
        exports = []
        for name in os.listdir(self.dir_fd):
            match = re.fullmatch(r"export-([1-9][0-9]*)\.jsonl", name)
            if not match:
                continue
            info = os.stat(name, dir_fd=self.dir_fd, follow_symlinks=False)
            if (
                not stat.S_ISREG(info.st_mode)
                or info.st_uid != os.getuid()
                or info.st_nlink != 1
                or stat.S_IMODE(info.st_mode) != 0o600
            ):
                raise OSError(f"unsafe state file: {name}")
            exports.append((int(match.group(1)), name, info.st_size))
        return sorted(exports)

    def _prune_exports(self) -> None:
        exports = self._exports()
        total = sum(item[2] for item in exports)
        if len(exports) <= EXPORT_HIGH_COUNT and total <= EXPORT_HIGH_BYTES:
            return
        while len(exports) > EXPORT_LOW_COUNT or total > EXPORT_LOW_BYTES:
            _, name, size = exports.pop(0)
            os.unlink(name, dir_fd=self.dir_fd)
            total -= size
        os.fsync(self.dir_fd)

    def _next_sequence(self) -> int:
        maximum = 0
        for sequence, _, _ in self._exports():
            maximum = max(maximum, sequence)
        return maximum + 1

    def set_enabled(self, enabled: bool) -> str | None:
        with self.locked():
            if enabled:
                epoch = os.getrandom(16, os.GRND_NONBLOCK).hex()
                self._replace("enabled.tmp", "enabled", epoch.encode())
            else:
                epoch = None
                try:
                    os.unlink("enabled", dir_fd=self.dir_fd)
                except FileNotFoundError:
                    pass
            try:
                os.unlink("status", dir_fd=self.dir_fd)
            except FileNotFoundError:
                pass
            os.fsync(self.dir_fd)
            self._journal_signature = None
            self._journal_records = None
            self._journal_episodes = None
            return epoch

    def _marker_exists(self, name: str) -> bool:
        try:
            fd = self._open(name, os.O_RDONLY)
        except FileNotFoundError:
            return False
        os.close(fd)
        return True

    def _read_small(self, name: str, maximum: int = 128) -> bytes | None:
        try:
            fd = self._open(name, os.O_RDONLY)
        except FileNotFoundError:
            return None
        try:
            data = os.read(fd, maximum + 1)
            if len(data) > maximum or os.read(fd, 1):
                raise OSError(f"oversized state file: {name}")
            return data
        finally:
            os.close(fd)

    def _epoch_unlocked(self) -> str | None:
        data = self._read_small("enabled", 32)
        if data is None:
            return None
        try:
            epoch = data.decode("ascii")
        except UnicodeDecodeError:
            return ""
        return epoch if HEX32.fullmatch(epoch) else ""

    def start_session(self, epoch: str) -> None:
        """Validate EPOCH and reset bounded session counters before publication."""
        with self.locked():
            if self._epoch_unlocked() != epoch:
                raise EpochMismatch("collector epoch is no longer enabled")
            try:
                os.unlink("session-budget-exhausted", dir_fd=self.dir_fd)
            except FileNotFoundError:
                pass
            else:
                os.fsync(self.dir_fd)
            self.admitted = 0
            self.written = 0
            self.capture_exhausted = False

    def startup_snapshot(self, epoch: str) -> bytes:
        """Return one validated complete snapshot for the exact enabled epoch."""
        with self.locked():
            if self._epoch_unlocked() != epoch:
                raise EpochMismatch("collector epoch is no longer enabled")
            return self._feedback_bytes(self._read_feedback())

    def publish_capturing(self, epoch: str) -> None:
        with self.locked():
            if self._epoch_unlocked() != epoch:
                raise EpochMismatch("collector epoch is no longer enabled")
            self._replace("status.tmp", "status", f"capturing {epoch}".encode())

    def startup_failed(self, epoch: str, reason: str) -> None:
        with self.locked(wait=True):
            if self._epoch_unlocked() == epoch:
                self._replace(
                    "status.tmp", "status", f"startup-failed {epoch} {reason}".encode()
                )

    @contextmanager
    def collector_session(self) -> Iterator[None]:
        """Hold the single-collector lifetime lock."""
        fd = self._open("collector.lock", os.O_RDWR | os.O_CREAT)
        try:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise OSError("another swipe collector is active") from error
            yield
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
            os.close(fd)

    def _collector_running(self) -> bool:
        try:
            fd = self._open("collector.lock", os.O_RDWR)
        except FileNotFoundError:
            return False
        try:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return True
            fcntl.flock(fd, fcntl.LOCK_UN)
            return False
        finally:
            os.close(fd)

    def enabled(self) -> bool:
        with self.locked():
            return bool(self._epoch_unlocked())

    def erase_ready(self) -> None:
        """Refuse unless erase can safely be armed by the UI."""
        with self.locked():
            if self._marker_exists("enabled") or self._collector_running():
                raise OSError("disable, restart UI, then erase")

    def capture_status(self) -> tuple[bool, str]:
        """Return marker enabled state and one truthful fixed status string."""
        with self.locked():
            return self._capture_status_unlocked()

    def _capture_status_unlocked(self) -> tuple[bool, str]:
        epoch = self._epoch_unlocked()
        if epoch is None:
            return False, "off"
        if not epoch:
            return False, "not capturing: invalid-marker"
        status_data = self._read_small("status")
        status = ""
        if status_data is not None:
            try:
                status = status_data.decode("ascii")
            except UnicodeDecodeError:
                status = ""
        if status == f"capturing {epoch}":
            if self._collector_running():
                return True, "capturing"
            return True, "not capturing: collector-stopped"
        if status == f"startup-failed {epoch} invalid-feedback-state":
            return True, "not capturing: invalid-feedback-state"
        if status == f"startup-failed {epoch} snapshot-send-failed":
            return True, "not capturing: snapshot-send-failed"
        return True, "armed for next UI session"

    def erase(self) -> None:
        with self.locked():
            if self._marker_exists("enabled"):
                raise OSError("disable, restart UI, then erase")
            if self._collector_running():
                raise OSError("disable, restart UI, then erase")
            self._recover_temporaries()
            for name in os.listdir(self.dir_fd):
                if name in {
                    "journal.jsonl",
                    "journal.tmp",
                    "feedback.state",
                    "feedback.tmp",
                    "export-budget",
                    "session-budget-exhausted",
                    "status",
                    "status.tmp",
                } or re.fullmatch(
                    r"(?:export-[1-9][0-9]*|export-budget)\.(?:jsonl|tmp)", name
                ):
                    os.unlink(name, dir_fd=self.dir_fd)
            os.fsync(self.dir_fd)
            self.admitted = 0
            self.written = 0
            self.capture_exhausted = False


def _valid_transport(sock: socket.socket) -> bool:
    try:
        return (
            sock.family == socket.AF_UNIX
            and sock.type == socket.SOCK_DGRAM
            and sock.getsockname() in ("", b"")
            and sock.getpeername() in ("", b"")
        )
    except OSError:
        return False


def collect(fd: int, ready_fd: int, epoch: str, store: Store) -> None:
    """Send one startup snapshot, then drain feedback for exactly EPOCH."""
    if not HEX32.fullmatch(epoch) or ready_fd != 6:
        raise OSError("invalid collector epoch")
    ready_info = os.fstat(ready_fd)
    if not stat.S_ISFIFO(ready_info.st_mode):
        raise OSError("invalid collector readiness pipe")
    sock = socket.socket(fileno=fd)
    try:
        if not _valid_transport(sock):
            raise OSError("collector transport is not an unnamed Unix datagram pair")
        sock.setblocking(False)
        with store.collector_session():
            try:
                store.start_session(epoch)
                snapshot = store.startup_snapshot(epoch)
            except (InvalidRecord, OSError):
                store.startup_failed(epoch, "invalid-feedback-state")
                return
            try:
                if sock.send(snapshot) != len(snapshot):
                    raise OSError("short snapshot send")
            except OSError:
                store.startup_failed(epoch, "snapshot-send-failed")
                return
            store.publish_capturing(epoch)
            if os.write(ready_fd, b"ready") != 5:
                raise OSError("collector readiness write failed")
            os.close(ready_fd)
            ready_fd = -1
            tokens = 16.0
            last_refill = time.monotonic()
            while True:
                now = time.monotonic()
                tokens = min(16.0, tokens + (now - last_refill) * 8.0)
                last_refill = now
                if tokens < 1.0:
                    select.select([], [], [], (1.0 - tokens) / 8.0)
                    continue
                readable, _, _ = select.select([sock], [], [])
                if not readable:
                    continue
                for _ in range(min(16, int(tokens))):
                    try:
                        data, ancillary, flags, _ = sock.recvmsg(JSON_MAX, 256)
                    except BlockingIOError:
                        break
                    except OSError:
                        return
                    if not data:
                        return
                    tokens -= 1.0
                    try:
                        store.admit(epoch)
                    except StoreBusy:
                        continue
                    except (EpochMismatch, BudgetExhausted, OSError):
                        return
                    if ancillary or flags & (socket.MSG_TRUNC | socket.MSG_CTRUNC):
                        continue
                    if not store.capture_exhausted:
                        try:
                            store.append(data, require_epoch=epoch, admitted=True)
                        except StoreBusy:
                            continue
                        except EpochMismatch:
                            return
                        except FeedbackPersistenceError:
                            return
                        except (InvalidRecord, BudgetExhausted, OSError):
                            continue
    finally:
        if ready_fd >= 0:
            os.close(ready_fd)
        sock.close()


def empty_summary(page: int) -> dict[str, Any]:
    """Describe capture before its private state directory exists."""
    return {
        "enabled": False,
        "capture": "off",
        "gestures": 0,
        "pending": 0,
        "outcomes": {},
        "records": [],
        "page": page,
        "page_size": SHOW_PAGE_SIZE,
        "session_budget_exhausted": False,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--state-dir", type=Path, default=DEFAULT_STATE)
    parser.add_argument("--fd", type=int, default=3)
    parser.add_argument("--ready-fd", type=int, default=-1)
    parser.add_argument("--epoch")
    parser.add_argument("--page", type=int, default=0)
    parser.add_argument(
        "command",
        choices=(
            "collect",
            "enable",
            "disable",
            "show",
            "export",
            "erase-ready",
            "erase",
        ),
    )
    args = parser.parse_args(argv)
    store = None
    try:
        if args.command == "show" and args.page < 0:
            raise OSError("page must be nonnegative")
        try:
            store = Store(args.state_dir, create=args.command != "show")
        except FileNotFoundError:
            if args.command != "show":
                raise
            print(json.dumps(empty_summary(args.page), indent=2, ensure_ascii=True))
            return 0
        if args.command == "collect":
            collect(args.fd, args.ready_fd, args.epoch or "", store)
            return 0
        if args.command == "enable":
            store.set_enabled(True)
            result = {
                "message": "Armed for next UI session",
                "enabled": True,
            }
        elif args.command == "disable":
            store.set_enabled(False)
            result = {
                "message": "Persistence off now; keyboard observation stops next UI session",
                "enabled": False,
            }
        elif args.command == "show":
            result = store.summary(include_records=True, page=args.page)
        elif args.command == "export":
            name, count = store.export()
            result = {"message": "Export complete", "file": name, "gestures": count}
        elif args.command == "erase-ready":
            store.erase_ready()
            result = {"message": "Erase is ready"}
        else:
            store.erase()
            result = {
                "message": "Learning data erased",
                "enabled": store.enabled(),
            }
        print(json.dumps(result, indent=2, ensure_ascii=True))
        return 0
    except (BudgetExhausted, EpochMismatch, InvalidRecord, OSError) as error:
        print(f"swipe learning: {error}", file=sys.stderr)
        return 1
    finally:
        if store is not None:
            store.close()


if __name__ == "__main__":
    raise SystemExit(main())

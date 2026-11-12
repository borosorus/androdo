"""Checkpointed JSON metadata and a durable event journal for PhoneBackup.

The manifest is a readable snapshot; small checksummed events are appended to
an adjacent journal during operations. Checkpoints replace the snapshot
atomically before clearing the journal. History pruning is represented as a
durable intent so blob deletion can be retried safely after interruption.
"""

from __future__ import annotations

from datetime import datetime, timezone
import json
import hashlib
import math
import os
from pathlib import Path
import stat
import tempfile
from typing import Any, Dict, Optional, Union
import uuid


MANIFEST_VERSION = 2
JOURNAL_VERSION = 1
MANIFEST_FILENAME = ".phonebackup-manifest.json"
JOURNAL_FILENAME = ".phonebackup-journal.jsonl"


class ManifestError(Exception):
    """Manifest is unreadable, corrupt, or from an unsupported format."""


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def _valid_relpath(relpath: str) -> bool:
    if not isinstance(relpath, str) or not relpath or "\x00" in relpath:
        return False
    # Manifest paths always use Android/POSIX separators, independently of the
    # host running the program. Backslash remains a valid filename character.
    if relpath.startswith("/"):
        return False
    return all(part not in ("", ".", "..") for part in relpath.split("/"))


class Manifest:
    """Load, update, and atomically persist a backup manifest.

    File entries are keyed by paths relative to the backup root. Missing phone
    files should not be removed from ``files``. History metadata is pruned only
    through a journaled intent coordinated by the backup layer.
    """

    def __init__(self, path: Union[os.PathLike, str]):
        self.path = Path(path)
        self.journal_path = self.path.with_name(JOURNAL_FILENAME)
        self.data: Dict[str, Any] = {}
        self._sequence = 0
        self._history_ids = set()
        self._journal_valid_bytes = 0
        self._journal_last_sequence = 0
        self._journal_needs_repair = False
        self._needs_migration = False
        self._poisoned = False
        self._initialized_on_disk = False
        self._pending_selection = None

    @classmethod
    def for_backup(cls, backup_dir: Union[os.PathLike, str]) -> "Manifest":
        return cls(Path(backup_dir) / MANIFEST_FILENAME)

    def load(self, create: bool = False, remote_root: str = "/sdcard") -> "Manifest":
        """Read an existing manifest, or initialize one when ``create`` is true.

        Corrupt files are never silently replaced. Callers can report the
        ``ManifestError`` and let the user recover the sidecar explicitly.
        """
        self._poisoned = False
        self._pending_selection = None
        self._journal_valid_bytes = 0
        self._journal_last_sequence = 0
        self._journal_needs_repair = False
        self._needs_migration = False
        self._initialized_on_disk = self.path.exists()
        if self.path.is_symlink():
            raise ManifestError("refusing to read a symlink as the backup manifest")
        if not self.path.exists():
            if self.journal_path.is_symlink() or self.journal_path.exists():
                raise ManifestError("backup journal exists without its manifest: {}".format(self.journal_path))
            if not create:
                raise ManifestError("backup manifest does not exist: {}".format(self.path))
            self.data = {
                "version": MANIFEST_VERSION,
                "backup_id": str(uuid.uuid4()),
                "checkpoint_seq": 0,
                "remote_root": remote_root,
                "created_at": _now(),
                "last_attempt": None,
                "last_success": None,
                # A newly created backup has no verified successful run yet.
                # Treat it as incomplete until finish_success commits a scan.
                "incomplete": True,
                "last_error": None,
                "files": {},
                "pending": {},
                "pending_prune": None,
                "history": {},
                "selection": {"include": [], "exclude": []},
                "validated_selection": None,
            }
            self._sequence = 0
            self._history_ids = set()
            self._initialized_on_disk = False
            return self
        try:
            with self.path.open("r", encoding="utf-8") as stream:
                value = json.load(stream)
        except (OSError, UnicodeError, json.JSONDecodeError) as exc:
            raise ManifestError("cannot read backup manifest {}: {}".format(self.path, exc)) from exc
        legacy = value.get("version") == 1 if isinstance(value, dict) else False
        self._validate(value)
        self.data = value
        self._needs_migration = legacy
        self._sequence = value.get("checkpoint_seq", 0)
        self._history_ids = {
            version["id"] for versions in value.get("history", {}).values() for version in versions
        }
        self._load_journal()
        return self

    def _validate(self, value: Any) -> None:
        if not isinstance(value, dict):
            raise ManifestError("manifest root must be a JSON object")
        if value.get("version") not in (1, MANIFEST_VERSION):
            raise ManifestError("unsupported manifest version: {!r}".format(value.get("version")))
        if value.get("version") == MANIFEST_VERSION:
            if not isinstance(value.get("backup_id"), str) or not value["backup_id"]:
                raise ManifestError("manifest backup_id is missing or invalid")
            sequence = value.get("checkpoint_seq")
            if isinstance(sequence, bool) or not isinstance(sequence, int) or sequence < 0:
                raise ManifestError("manifest checkpoint_seq is invalid")
        if not isinstance(value.get("remote_root"), str) or not value["remote_root"]:
            raise ManifestError("manifest remote_root is missing or invalid")
        if "incomplete" in value and not isinstance(value["incomplete"], bool):
            raise ManifestError("manifest incomplete flag must be a boolean")
        if value.get("last_success") is not None and not isinstance(value["last_success"], str):
            raise ManifestError("manifest last_success must be a string or null")
        if value.get("last_error") is not None and not isinstance(value["last_error"], str):
            raise ManifestError("manifest last_error must be a string or null")
        if value.get("last_attempt") is not None and not isinstance(value["last_attempt"], dict):
            raise ManifestError("manifest last_attempt must be an object or null")
        if not isinstance(value.get("files"), dict):
            raise ManifestError("manifest files must be a JSON object")
        from .Selection import manifest_selection
        try:
            value["selection"] = manifest_selection(value.get("selection", {}))
        except (TypeError, ValueError) as exc:
            raise ManifestError(str(exc)) from exc
        if "validated_selection" not in value:
            # Older manifests predate selection persistence; a completed
            # backup proves their implicit all-files selection was valid.
            value["validated_selection"] = (
                dict(value["selection"]) if value.get("last_success") is not None else None
            )
        elif value["validated_selection"] is not None:
            try:
                value["validated_selection"] = manifest_selection(value["validated_selection"])
            except (TypeError, ValueError) as exc:
                raise ManifestError("invalid validated selection: {}".format(exc)) from exc
        if "pending" not in value:
            value["pending"] = {}
        if not isinstance(value["pending"], dict):
            raise ManifestError("manifest pending must be a JSON object")
        pending_prune = value.setdefault("pending_prune", None)
        if pending_prune is not None:
            if not isinstance(pending_prune, dict):
                raise ManifestError("manifest pending_prune must be an object or null")
            ids = pending_prune.get("version_ids")
            version_paths = pending_prune.get("version_paths")
            blobs = pending_prune.get("files")
            if (not isinstance(ids, list) or not ids or
                    any(not isinstance(item, str) or not item for item in ids) or len(set(ids)) != len(ids)):
                raise ManifestError("invalid pending prune version IDs")
            if (not isinstance(version_paths, dict) or set(version_paths) != set(ids) or
                    any(not _valid_relpath(path) for path in version_paths.values())):
                raise ManifestError("invalid pending prune version paths")
            if not isinstance(blobs, list):
                raise ManifestError("invalid pending prune files")
            for blob in blobs:
                if not isinstance(blob, dict) or not _valid_relpath(blob.get("path")) or \
                        not blob["path"].startswith(".phonebackup-history/"):
                    raise ManifestError("unsafe pending prune path")
                digest = blob.get("sha256")
                size = blob.get("size")
                if (not isinstance(digest, str) or len(digest) != 64 or
                        any(char not in "0123456789abcdef" for char in digest)):
                    raise ManifestError("invalid pending prune SHA-256")
                if isinstance(size, bool) or not isinstance(size, int) or size < 0:
                    raise ManifestError("invalid pending prune size")
        if "history" not in value:
            value["history"] = {}
        if not isinstance(value["history"], dict):
            raise ManifestError("manifest history must be a JSON object")
        global_version_ids = set()
        for relpath, versions in value["history"].items():
            if not _valid_relpath(relpath) or not isinstance(versions, list):
                raise ManifestError("invalid history entry for {!r}".format(relpath))
            for version in versions:
                if not isinstance(version, dict):
                    raise ManifestError("invalid history version for {!r}".format(relpath))
                version_id = version.get("id")
                stored_path = version.get("path")
                digest = version.get("sha256")
                size = version.get("size")
                mtime = version.get("mtime")
                if (not isinstance(version_id, str) or not version_id or
                        version_id in global_version_ids):
                    raise ManifestError("invalid or duplicate history version id for {!r}".format(relpath))
                global_version_ids.add(version_id)
                if not _valid_relpath(stored_path) or not stored_path.startswith(".phonebackup-history/"):
                    raise ManifestError("unsafe history path for {!r}".format(relpath))
                if (not isinstance(digest, str) or len(digest) != 64 or
                        any(c not in "0123456789abcdef" for c in digest)):
                    raise ManifestError("invalid history SHA-256 for {!r}".format(relpath))
                if isinstance(size, bool) or not isinstance(size, int) or size < 0:
                    raise ManifestError("invalid history size for {!r}".format(relpath))
                if (isinstance(mtime, bool) or not isinstance(mtime, (int, float)) or
                        not math.isfinite(mtime)):
                    raise ManifestError("invalid history mtime for {!r}".format(relpath))
                if not isinstance(version.get("captured_at"), str):
                    raise ManifestError("invalid history timestamp for {!r}".format(relpath))
        for relpath, record in list(value["files"].items()) + list(value["pending"].items()):
            if not _valid_relpath(relpath):
                raise ManifestError("unsafe or invalid path in manifest: {!r}".format(relpath))
            if not isinstance(record, dict):
                raise ManifestError("invalid file record for {!r}".format(relpath))
            if isinstance(record.get("size"), bool) or not isinstance(record.get("size"), int) or record["size"] < 0:
                raise ManifestError("invalid size for {!r}".format(relpath))
            if (isinstance(record.get("mtime"), bool) or
                    not isinstance(record.get("mtime"), (int, float)) or
                    not math.isfinite(record["mtime"])):
                raise ManifestError("invalid mtime for {!r}".format(relpath))
            digest = record.get("sha256")
            if digest is not None and (not isinstance(digest, str) or len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest)):
                raise ManifestError("invalid SHA-256 for {!r}".format(relpath))
            target_digest = record.get("target_sha256")
            if target_digest is not None and (relpath not in value["pending"] or
                                               not isinstance(target_digest, str) or len(target_digest) != 64 or
                                               any(c not in "0123456789abcdef" for c in target_digest)):
                raise ManifestError("invalid pending target SHA-256 for {!r}".format(relpath))
            temp_path = record.get("temp_path")
            if temp_path is not None and not _valid_relpath(temp_path):
                raise ManifestError("invalid pending temporary path for {!r}".format(relpath))

    def save(self) -> None:
        """Write a compact JSON checkpoint and then atomically clear the journal."""
        if not self.data:
            raise ManifestError("cannot save an uninitialized manifest")
        if self._poisoned:
            raise ManifestError("manifest writer is unusable after an uncertain journal write; reload it")
        self.data["version"] = MANIFEST_VERSION
        self.data.setdefault("backup_id", str(uuid.uuid4()))
        self.data["checkpoint_seq"] = self._sequence
        self._validate(self.data)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        encoded = json.dumps(self.data, ensure_ascii=True, sort_keys=True, indent=2) + "\n"
        fd, temp_name = tempfile.mkstemp(prefix=self.path.name + ".", suffix=".tmp", dir=str(self.path.parent))
        try:
            with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as stream:
                stream.write(encoded)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temp_name, self.path)
            self._fsync_parent(self.path)
            self._replace_journal(b"")
            self._initialized_on_disk = True
            self._needs_migration = False
            self._journal_valid_bytes = 0
            self._journal_last_sequence = self._sequence
            self._journal_needs_repair = False
            self._history_ids = {
                version["id"] for versions in self.data.get("history", {}).values() for version in versions
            }
        except BaseException:
            self._poisoned = True
            try:
                os.unlink(temp_name)
            except OSError:
                pass
            raise

    checkpoint = save

    @staticmethod
    def _fsync_parent(path: Path) -> None:
        if os.name != "nt":
            dir_fd = os.open(str(path.parent), os.O_RDONLY)
            try:
                os.fsync(dir_fd)
            finally:
                os.close(dir_fd)

    def _replace_journal(self, content: bytes) -> None:
        if self.journal_path.is_symlink():
            raise ManifestError("refusing to replace a symlink as the backup journal")
        fd, temp_name = tempfile.mkstemp(prefix=self.journal_path.name + ".", suffix=".tmp",
                                         dir=str(self.journal_path.parent))
        try:
            with os.fdopen(fd, "wb") as stream:
                stream.write(content)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temp_name, self.journal_path)
            self._fsync_parent(self.journal_path)
        except BaseException:
            try:
                os.unlink(temp_name)
            except OSError:
                pass
            raise

    def _load_journal(self) -> None:
        if self.journal_path.is_symlink():
            raise ManifestError("refusing to read a symlink as the backup journal")
        if not self.journal_path.exists():
            return
        mode = self.journal_path.lstat().st_mode
        if not stat.S_ISREG(mode):
            raise ManifestError("backup journal is not a regular file")
        if self._needs_migration:
            raise ManifestError("legacy manifest has an unexpected journal sidecar")

        checkpoint_seq = self.data["checkpoint_seq"]
        previous_sequence = None
        applied_sequence = checkpoint_seq
        valid_bytes = 0
        with self.journal_path.open("rb") as stream:
            while True:
                line_start = stream.tell()
                line = stream.readline()
                if not line:
                    break
                if not line.endswith(b"\n"):
                    self._journal_needs_repair = True
                    break
                try:
                    envelope = json.loads(line.decode("utf-8"))
                    event = envelope["event"]
                    checksum = envelope["sha256"]
                    canonical = json.dumps(event, ensure_ascii=True, sort_keys=True,
                                           separators=(",", ":")).encode("ascii")
                    if not isinstance(checksum, str) or hashlib.sha256(canonical).hexdigest() != checksum:
                        raise ManifestError("backup journal checksum mismatch")
                    if event.get("format") != JOURNAL_VERSION:
                        raise ManifestError("unsupported backup journal record version")
                    if event.get("backup_id") != self.data["backup_id"]:
                        raise ManifestError("backup journal belongs to a different backup")
                    sequence = event.get("sequence")
                    if isinstance(sequence, bool) or not isinstance(sequence, int) or sequence < 1:
                        raise ManifestError("invalid backup journal sequence")
                    if previous_sequence is not None and sequence != previous_sequence + 1:
                        raise ManifestError("backup journal sequence gap")
                    if previous_sequence is None and sequence > checkpoint_seq + 1:
                        raise ManifestError("backup journal starts after a sequence gap")
                    previous_sequence = sequence
                    if sequence > checkpoint_seq:
                        if sequence != applied_sequence + 1:
                            raise ManifestError("backup journal sequence gap after checkpoint")
                        self._validate_event(event.get("operation"), event.get("data"))
                        self._apply_event(event["operation"], event["data"])
                        applied_sequence = sequence
                    valid_bytes = stream.tell()
                except ManifestError:
                    raise
                except (UnicodeError, ValueError, KeyError, TypeError, AttributeError) as exc:
                    raise ManifestError("cannot read backup journal record at byte {}: {}".format(
                        line_start, exc
                    )) from exc
        self._sequence = applied_sequence
        self._journal_valid_bytes = valid_bytes
        self._journal_last_sequence = previous_sequence or 0

    def _ensure_journal_base(self) -> None:
        if self._poisoned:
            raise ManifestError("manifest writer is unusable after an uncertain journal write; reload it")
        if self._needs_migration or not self._initialized_on_disk:
            self.data["version"] = MANIFEST_VERSION
            self.data.setdefault("backup_id", str(uuid.uuid4()))
            self.data.setdefault("checkpoint_seq", 0)
            self.checkpoint()

    def _prepare_journal_append(self) -> None:
        if self.journal_path.is_symlink():
            raise ManifestError("refusing to append to a symlink as the backup journal")
        if self.journal_path.exists() and not stat.S_ISREG(self.journal_path.lstat().st_mode):
            raise ManifestError("backup journal is not a regular file")
        if not self.journal_path.exists():
            return
        journal_stat = self.journal_path.lstat()
        if self._journal_last_sequence <= self.data["checkpoint_seq"]:
            self._replace_journal(b"")
            self._journal_valid_bytes = 0
            self._journal_last_sequence = self.data["checkpoint_seq"]
            self._journal_needs_repair = False
        elif self._journal_needs_repair:
            with self.journal_path.open("rb") as stream:
                valid = stream.read(self._journal_valid_bytes)
            self._replace_journal(valid)
            self._journal_needs_repair = False
        elif journal_stat.st_nlink > 1:
            with self.journal_path.open("rb") as stream:
                valid = stream.read(self._journal_valid_bytes)
            self._replace_journal(valid)

    def _commit(self, operation: str, data: Dict[str, Any]) -> None:
        self._require_loaded()
        self._ensure_journal_base()
        self._validate_event(operation, data)
        sequence = self._sequence + 1
        event = {
            "format": JOURNAL_VERSION,
            "backup_id": self.data["backup_id"],
            "sequence": sequence,
            "operation": operation,
            "data": data,
        }
        canonical = json.dumps(event, ensure_ascii=True, sort_keys=True,
                               separators=(",", ":")).encode("ascii")
        encoded = json.dumps({"event": event, "sha256": hashlib.sha256(canonical).hexdigest()},
                             ensure_ascii=True, sort_keys=True,
                             separators=(",", ":")).encode("ascii") + b"\n"
        try:
            self._prepare_journal_append()
            self.journal_path.parent.mkdir(parents=True, exist_ok=True)
            created = not self.journal_path.exists()
            flags = os.O_WRONLY | os.O_APPEND | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)
            descriptor = os.open(str(self.journal_path), flags, 0o600)
            try:
                opened = os.fstat(descriptor)
                current = self.journal_path.lstat()
                if (not stat.S_ISREG(opened.st_mode) or opened.st_nlink != 1 or
                        (opened.st_dev, opened.st_ino) != (current.st_dev, current.st_ino)):
                    raise ManifestError("backup journal changed or has unsafe hard links")
                remaining = memoryview(encoded)
                while remaining:
                    written = os.write(descriptor, remaining)
                    if written <= 0:
                        raise OSError("could not append backup journal record")
                    remaining = remaining[written:]
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
            if created:
                self._fsync_parent(self.journal_path)
        except BaseException:
            self._poisoned = True
            raise
        self._apply_event(operation, data)
        self._sequence = sequence
        self._journal_last_sequence = sequence
        self._journal_valid_bytes += len(encoded)

    def _validate_event(self, operation: str, data: Any) -> None:
        if not isinstance(data, dict):
            raise ManifestError("invalid backup journal event data")
        if operation == "attempt":
            from .Selection import manifest_selection
            try:
                manifest_selection(data.get("selection"))
            except (TypeError, ValueError) as exc:
                raise ManifestError("invalid journal selection: {}".format(exc)) from exc
            if not isinstance(data.get("attempt"), dict) or not isinstance(data["attempt"].get("id"), str):
                raise ManifestError("invalid journal attempt")
        elif operation == "refresh_files":
            records = data.get("records")
            if not isinstance(records, dict):
                raise ManifestError("invalid journal file refresh")
            for path, record in records.items():
                self._validate_file_record(path, record)
        elif operation in ("pending_set", "file_commit"):
            self._validate_file_record(data.get("path"), data.get("record"),
                                       pending=operation == "pending_set")
        elif operation == "pending_field":
            path, field, value = data.get("path"), data.get("field"), data.get("value")
            if not _valid_relpath(path) or field not in ("sha256", "temp_path"):
                raise ManifestError("invalid journal pending field")
            if field == "sha256" and (not isinstance(value, str) or len(value) != 64 or
                                       any(char not in "0123456789abcdef" for char in value)):
                raise ManifestError("invalid journal pending SHA-256")
            if field == "temp_path" and not _valid_relpath(value):
                raise ManifestError("invalid journal pending temporary path")
            if path not in self.data.get("pending", {}):
                raise ManifestError("journal pending field has no transfer record")
        elif operation == "history_add":
            path, version = data.get("path"), data.get("version")
            if not _valid_relpath(path) or not isinstance(version, dict):
                raise ManifestError("invalid journal history entry")
            self._validate_history_version(path, version)
            if version["id"] in self._history_ids:
                raise ManifestError("duplicate journal history version ID")
        elif operation == "begin_prune":
            intent = data.get("intent")
            if not isinstance(intent, dict):
                raise ManifestError("invalid journal prune intent")
            self._validate_pending_prune(intent)
            ids = set(intent["version_ids"])
            available = {version["id"] for versions in self.data.get("history", {}).values()
                         for version in versions}
            if not ids or not ids <= available:
                raise ManifestError("journal prune references unknown history versions")
        elif operation == "finish_prune":
            if data:
                raise ManifestError("invalid journal prune completion")
        elif operation == "finish_success":
            from .Selection import manifest_selection
            try:
                manifest_selection(data.get("selection"))
            except (TypeError, ValueError) as exc:
                raise ManifestError("invalid journal completed selection") from exc
            if not isinstance(data.get("finished_at"), str):
                raise ManifestError("invalid journal completion timestamp")
        elif operation == "fail":
            if not isinstance(data.get("error"), str) or not isinstance(data.get("finished_at"), str):
                raise ManifestError("invalid journal failure record")
        else:
            raise ManifestError("unknown backup journal operation: {!r}".format(operation))

    @staticmethod
    def _validate_file_record(path: str, record: Any, pending: bool = False) -> None:
        if not _valid_relpath(path) or not isinstance(record, dict):
            raise ManifestError("invalid journal file record")
        if isinstance(record.get("size"), bool) or not isinstance(record.get("size"), int) or record["size"] < 0:
            raise ManifestError("invalid journal file size")
        if (isinstance(record.get("mtime"), bool) or not isinstance(record.get("mtime"), (int, float)) or
                not math.isfinite(record["mtime"])):
            raise ManifestError("invalid journal file mtime")
        digest = record.get("sha256")
        if digest is not None and (not isinstance(digest, str) or len(digest) != 64 or
                                   any(char not in "0123456789abcdef" for char in digest)):
            raise ManifestError("invalid journal file SHA-256")
        target_digest = record.get("target_sha256")
        if pending and target_digest is not None and (not isinstance(target_digest, str) or
                                                      len(target_digest) != 64 or
                                                      any(char not in "0123456789abcdef" for char in target_digest)):
            raise ManifestError("invalid journal pending target SHA-256")
        if pending and record.get("temp_path") is not None and not _valid_relpath(record["temp_path"]):
            raise ManifestError("invalid journal temporary path")

    @staticmethod
    def _validate_history_version(path: str, version: Dict[str, Any]) -> None:
        stored_path = version.get("path")
        digest = version.get("sha256")
        if not isinstance(version.get("id"), str) or not version["id"]:
            raise ManifestError("invalid history version ID for {!r}".format(path))
        if not _valid_relpath(stored_path) or not stored_path.startswith(".phonebackup-history/"):
            raise ManifestError("unsafe history path for {!r}".format(path))
        if (not isinstance(digest, str) or len(digest) != 64 or
                any(char not in "0123456789abcdef" for char in digest)):
            raise ManifestError("invalid history SHA-256 for {!r}".format(path))
        size, mtime = version.get("size"), version.get("mtime")
        if isinstance(size, bool) or not isinstance(size, int) or size < 0:
            raise ManifestError("invalid history size for {!r}".format(path))
        if (isinstance(mtime, bool) or not isinstance(mtime, (int, float)) or not math.isfinite(mtime)):
            raise ManifestError("invalid history mtime for {!r}".format(path))
        if not isinstance(version.get("captured_at"), str):
            raise ManifestError("invalid history timestamp for {!r}".format(path))

    def _validate_pending_prune(self, pending_prune: Any) -> None:
        if not isinstance(pending_prune, dict):
            raise ManifestError("invalid pending prune record")
        ids = pending_prune.get("version_ids")
        version_paths = pending_prune.get("version_paths")
        blobs = pending_prune.get("files")
        if (not isinstance(ids, list) or not ids or
                any(not isinstance(item, str) or not item for item in ids) or len(set(ids)) != len(ids)):
            raise ManifestError("invalid pending prune version IDs")
        if (not isinstance(version_paths, dict) or set(version_paths) != set(ids) or
                any(not _valid_relpath(path) for path in version_paths.values())):
            raise ManifestError("invalid pending prune version paths")
        if not isinstance(blobs, list):
            raise ManifestError("invalid pending prune files")
        for blob in blobs:
            if not isinstance(blob, dict) or not _valid_relpath(blob.get("path")) or \
                    not blob["path"].startswith(".phonebackup-history/"):
                raise ManifestError("unsafe pending prune path")
            digest, size = blob.get("sha256"), blob.get("size")
            if (not isinstance(digest, str) or len(digest) != 64 or
                    any(char not in "0123456789abcdef" for char in digest)):
                raise ManifestError("invalid pending prune SHA-256")
            if isinstance(size, bool) or not isinstance(size, int) or size < 0:
                raise ManifestError("invalid pending prune size")

    def _apply_event(self, operation: str, data: Dict[str, Any]) -> None:
        if operation == "attempt":
            self.data["selection"] = data["selection"]
            self.data["last_attempt"] = data["attempt"]
            self.data["incomplete"] = True
            self.data["last_error"] = None
        elif operation == "refresh_files":
            self.data["files"].update(data["records"])
        elif operation == "pending_set":
            self.data["pending"][data["path"]] = data["record"]
        elif operation == "pending_field":
            self.data["pending"][data["path"]][data["field"]] = data["value"]
        elif operation == "file_commit":
            self.data["files"][data["path"]] = data["record"]
            self.data["pending"].pop(data["path"], None)
        elif operation == "history_add":
            self.data["history"].setdefault(data["path"], []).append(data["version"])
            self._history_ids.add(data["version"]["id"])
        elif operation == "begin_prune":
            ids = set(data["intent"]["version_ids"])
            for path, versions in list(self.data["history"].items()):
                remaining = [version for version in versions if version["id"] not in ids]
                if remaining:
                    self.data["history"][path] = remaining
                else:
                    self.data["history"].pop(path, None)
            self._history_ids.difference_update(ids)
            self.data["pending_prune"] = data["intent"]
        elif operation == "finish_prune":
            self.data["pending_prune"] = None
        elif operation == "finish_success":
            if isinstance(self.data.get("last_attempt"), dict):
                self.data["last_attempt"]["finished_at"] = data["finished_at"]
            self.data["last_success"] = data["finished_at"]
            self.data["validated_selection"] = data["selection"]
            self.data["incomplete"] = False
            self.data["last_error"] = None
        elif operation == "fail":
            if isinstance(self.data.get("last_attempt"), dict):
                self.data["last_attempt"]["finished_at"] = data["finished_at"]
            self.data["incomplete"] = True
            self.data["last_error"] = data["error"]

    def begin_attempt(self) -> str:
        self._require_loaded()
        attempt_id = str(uuid.uuid4())
        self._commit("attempt", {
            "selection": dict(self._pending_selection or self.data.get(
                "selection", {"include": [], "exclude": []}
            )),
            "attempt": {"id": attempt_id, "started_at": _now()},
        })
        self._pending_selection = None
        return attempt_id

    def set_selection(self, include, exclude) -> None:
        self._require_loaded()
        from .Selection import Selection
        try:
            selection = Selection(include, exclude)
        except (TypeError, ValueError) as exc:
            raise ManifestError("invalid backup selection: {}".format(exc)) from exc
        self._pending_selection = {"include": selection.include, "exclude": selection.exclude}

    def record_file(self, relpath: str, size: int, mtime: float, sha256: Optional[str] = None) -> None:
        self._require_loaded()
        if not _valid_relpath(relpath):
            raise ManifestError("unsafe or invalid backup path: {!r}".format(relpath))
        if isinstance(size, bool) or not isinstance(size, int) or size < 0:
            raise ManifestError("size must be a non-negative integer")
        if not isinstance(mtime, (int, float)) or isinstance(mtime, bool) or not math.isfinite(mtime):
            raise ManifestError("mtime must be numeric")
        if sha256 is not None and (len(sha256) != 64 or any(c not in "0123456789abcdef" for c in sha256)):
            raise ManifestError("sha256 must be a lowercase hexadecimal SHA-256 digest")
        self._commit("file_commit", {
            "path": relpath, "record": {"size": size, "mtime": mtime, "sha256": sha256}
        })

    def record_files(self, records: Dict[str, Dict[str, Any]]) -> None:
        """Durably refresh metadata for the files skipped in one update plan."""
        if not records:
            return
        self._commit("refresh_files", {"records": records})

    def add_history(self, relpath: str, version: Dict[str, Any]) -> None:
        self._commit("history_add", {"path": relpath, "version": version})

    def begin_prune(self, intent: Dict[str, Any]) -> None:
        self._commit("begin_prune", {"intent": intent})

    def finish_prune(self) -> None:
        self._commit("finish_prune", {})

    def begin_file(self, relpath: str, size: int, mtime: float,
                   temp_path: Optional[str] = None,
                   target_sha256: Optional[str] = None) -> None:
        """Record transfer intent before touching a destination file."""
        self._require_loaded()
        if not _valid_relpath(relpath):
            raise ManifestError("unsafe or invalid backup path: {!r}".format(relpath))
        if isinstance(size, bool) or not isinstance(size, int) or size < 0:
            raise ManifestError("size must be a non-negative integer")
        if not isinstance(mtime, (int, float)) or isinstance(mtime, bool) or not math.isfinite(mtime):
            raise ManifestError("mtime must be numeric")
        if temp_path is not None and not _valid_relpath(temp_path):
            raise ManifestError("unsafe pending temporary path: {!r}".format(temp_path))
        if target_sha256 is not None and (not isinstance(target_sha256, str) or len(target_sha256) != 64 or
                                          any(char not in "0123456789abcdef" for char in target_sha256)):
            raise ManifestError("invalid pending target SHA-256")
        previous = self.data.setdefault("pending", {}).get(relpath, {})
        record = {"size": size, "mtime": mtime}
        if "sha256" in previous:
            record["sha256"] = previous["sha256"]
        if target_sha256 is not None:
            record["target_sha256"] = target_sha256
        if temp_path is not None:
            record["temp_path"] = temp_path
        elif "temp_path" in previous:
            record["temp_path"] = previous["temp_path"]
        self._commit("pending_set", {"path": relpath, "record": record})

    def set_pending_digest(self, relpath: str, sha256: str) -> None:
        self._require_loaded()
        if relpath not in self.data.setdefault("pending", {}):
            raise ManifestError("no pending transfer for {!r}".format(relpath))
        if not isinstance(sha256, str) or len(sha256) != 64 or any(c not in "0123456789abcdef" for c in sha256):
            raise ManifestError("sha256 must be a lowercase hexadecimal SHA-256 digest")
        self._commit("pending_field", {"path": relpath, "field": "sha256", "value": sha256})

    def set_pending_temp(self, relpath: str, temp_path: str) -> None:
        self._require_loaded()
        if relpath not in self.data.setdefault("pending", {}):
            raise ManifestError("no pending transfer for {!r}".format(relpath))
        if not _valid_relpath(temp_path):
            raise ManifestError("unsafe pending temporary path: {!r}".format(temp_path))
        self._commit("pending_field", {"path": relpath, "field": "temp_path", "value": temp_path})

    def finish_success(self) -> None:
        self._require_loaded()
        if self.data.get("pending"):
            raise ManifestError("cannot mark backup successful while transfers remain pending: {}".format(
                ", ".join(sorted(self.data["pending"]))
            ))
        finished = _now()
        selection = dict(self.data.get("selection", {"include": [], "exclude": []}))
        self._commit("finish_success", {"finished_at": finished, "selection": selection})

    def fail(self, error: str) -> None:
        self._require_loaded()
        self._commit("fail", {"error": str(error), "finished_at": _now()})

    def status_summary(self) -> Dict[str, Any]:
        self._require_loaded()
        records = self.data["files"].values()
        return {
            "remote_root": self.data["remote_root"],
            "last_attempt": self.data.get("last_attempt"),
            "last_success": self.data.get("last_success"),
            "incomplete": bool(self.data.get("incomplete", False)),
            "last_error": self.data.get("last_error"),
            "file_count": len(self.data["files"]),
            "total_size": sum(record["size"] for record in records),
            "files_with_sha256": sum(1 for record in self.data["files"].values() if record.get("sha256")),
            "pending_count": len(self.data.get("pending", {})),
            "pending_prune_ids": list((self.data.get("pending_prune") or {}).get("version_ids", [])),
            "pending_prune_file_count": len((self.data.get("pending_prune") or {}).get("files", [])),
            "history_version_count": sum(len(versions) for versions in self.data.get("history", {}).values()),
            "selection": self.data.get("selection", {"include": [], "exclude": []}),
        }

    def _require_loaded(self) -> None:
        if not self.data:
            raise ManifestError("manifest has not been loaded or initialized")

"""Non-destructive, manifest-backed Android to local directory backups."""

from __future__ import annotations

import hashlib
import logging
import os
import errno
from pathlib import Path
import stat
import subprocess
import shlex
import sys
import tempfile
import time
import unicodedata
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone
import shutil
from typing import Dict, Iterator, List, Optional, Tuple

from .FileSystems.Android import AndroidFileSystem
from .FileSystems.Base import FileMeta
from .Manifest import Manifest, ManifestError, MANIFEST_FILENAME, JOURNAL_FILENAME
from .Selection import Selection

LOCK_FILENAME = ".phonebackup.lock"
HISTORY_DIRECTORY = ".phonebackup-history"


class BackupError(RuntimeError):
    pass


def _iter_files(tree, parts: Tuple[str, ...] = ()) -> Iterator[Tuple[str, FileMeta]]:
    if isinstance(tree, FileMeta):
        if tree.size is not None:
            yield "/".join(parts), tree
        return
    if isinstance(tree, tuple) and len(tree) >= 3:
        if tree[2] is not None:
            yield "/".join(parts), tree
        return
    if not isinstance(tree, dict):
        raise BackupError("ADB scan returned an unsupported tree entry")
    for name, child in tree.items():
        if name == ".":
            continue
        if name in ("", ".", "..") or "/" in name or "\0" in name:
            raise BackupError("ADB returned an unsafe filename that cannot be stored")
        yield from _iter_files(child, parts + (name,))


def _iter_directories(tree, parts: Tuple[str, ...] = ()) -> Iterator[Tuple[str, FileMeta]]:
    if not isinstance(tree, dict):
        return
    meta = tree.get(".")
    if isinstance(meta, FileMeta) and parts:
        yield "/".join(parts), meta
    for name, child in tree.items():
        if name == ".":
            continue
        if name in ("", "..") or "/" in name or "\0" in name:
            raise BackupError("ADB returned an unsafe directory name")
        yield from _iter_directories(child, parts + (name,))


def _hash_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _fsync_file(path: Path) -> None:
    with path.open("r+b") as stream:
        os.fsync(stream.fileno())


def _fsync_directory(path: Path) -> None:
    # Windows does not expose portable directory fsync through Python. File
    # contents are still flushed there; macOS and POSIX persist rename entries.
    if os.name == "nt":
        return
    descriptor = os.open(str(path), os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _mkdirs_durable(path: Path) -> None:
    missing = []
    current = path
    while not current.exists():
        if current.is_symlink():
            raise BackupError("Refusing to create a backup through a symlink: {}".format(current))
        missing.append(current)
        parent = current.parent
        if parent == current:
            break
        current = parent
    path.mkdir(parents=True, exist_ok=True)
    for created in reversed(missing):
        _fsync_directory(created.parent)
        _fsync_directory(created)


def _safe_target(root: Path, relpath: str) -> Path:
    parts = relpath.split("/")
    if not parts or any(p in ("", ".", "..") for p in parts):
        raise BackupError("Unsafe path from Android: {!r}".format(relpath))
    path = root
    for part in parts[:-1]:
        path = path / part
        try:
            mode = path.lstat().st_mode
        except FileNotFoundError:
            continue
        if stat.S_ISLNK(mode) or not stat.S_ISDIR(mode):
            raise BackupError("Refusing to traverse non-directory or symlink in backup path: {}".format(path))
    target = path / parts[-1]
    try:
        mode = target.lstat().st_mode
    except FileNotFoundError:
        return target
    if stat.S_ISLNK(mode) or not stat.S_ISREG(mode):
        raise BackupError("Refusing to replace non-file or symlink: {}".format(target))
    return target


def _ensure_directory(root: Path, relpath: str) -> Path:
    path = root
    for part in relpath.split("/"):
        if part in ("", ".", ".."):
            raise BackupError("Unsafe directory path from Android: {!r}".format(relpath))
        path = path / part
        try:
            mode = path.lstat().st_mode
        except FileNotFoundError:
            path.mkdir()
            _fsync_directory(path.parent)
            continue
        if stat.S_ISLNK(mode) or not stat.S_ISDIR(mode):
            raise BackupError("Refusing to replace or traverse non-directory in backup path: {}".format(path))
        try:
            names = os.listdir(str(path.parent))
        except OSError:
            names = []
        if part not in names and not any(unicodedata.normalize("NFD", name) == unicodedata.normalize("NFD", part)
                                         for name in names):
            raise BackupError("Destination path aliases another name on this filesystem: {}".format(path))
    return path


def _directory_contains(parent: Path, child: Path) -> bool:
    """Compare directory identities while walking ancestors, including case aliases."""
    parent_metadata = parent.stat()
    identity = parent_metadata.st_dev, parent_metadata.st_ino
    current = child
    while True:
        try:
            metadata = current.stat()
        except OSError:
            return False
        if (metadata.st_dev, metadata.st_ino) == identity:
            return True
        if current.parent == current:
            return False
        current = current.parent


def _file_identity(path: Path):
    metadata = path.lstat()
    if not stat.S_ISREG(metadata.st_mode):
        return None
    return metadata.st_dev, metadata.st_ino


def _build_identity_index(root: Path, relpaths):
    identities = {}
    for relpath in relpaths:
        target = _safe_target(root, relpath)
        try:
            identity = _file_identity(target)
        except FileNotFoundError:
            continue
        if identity is None:
            continue
        other = identities.get(identity)
        if other is not None and other != relpath:
            raise BackupError("Destination paths {!r} and {!r} alias on this filesystem".format(relpath, other))
        identities[identity] = relpath
    return identities


def _check_file_identity(target: Path, relpath: str, identities) -> None:
    try:
        identity = _file_identity(target)
    except FileNotFoundError:
        return
    other = identities.get(identity)
    if other is not None and other != relpath:
        raise BackupError("Destination paths {!r} and {!r} alias on this filesystem".format(relpath, other))


def _pending_target_hash(record, target: Path):
    target_hash = _hash_file(target)
    allowed_hashes = {record.get("sha256"), record.get("target_sha256")}
    return target_hash if target_hash in allowed_hashes else None


def _archive_previous_version(root: Path, manifest: Manifest, relpath: str,
                              source: Path, incoming_sha256: str) -> None:
    """Preserve the bytes being replaced as an immutable per-file version."""
    before_digest = _hash_file(source)
    if before_digest == incoming_sha256:
        return
    stored_relpath = "{}/{}/{}".format(
        HISTORY_DIRECTORY, hashlib.sha256(relpath.encode("utf-8", "surrogateescape")).hexdigest(), before_digest
    )
    stored = _safe_target(root, stored_relpath)
    if stored.exists():
        if not stat.S_ISREG(stored.lstat().st_mode) or _hash_file(stored) != before_digest:
            raise BackupError("Existing history object is corrupt or unsafe: {}".format(stored))
    else:
        _ensure_directory(root, "/".join(stored_relpath.split("/")[:-1]))
        descriptor, temp_name = tempfile.mkstemp(prefix=".phonebackup-history-", suffix=".partial",
                                                 dir=str(stored.parent))
        os.close(descriptor)
        temporary = Path(temp_name)
        try:
            shutil.copyfile(str(source), str(temporary))
            digest = _hash_file(temporary)
            if digest != before_digest or _hash_file(source) != before_digest:
                raise BackupError("File changed while its previous version was being preserved: {}".format(relpath))
            source_stat = source.stat()
            os.utime(temporary, ns=(source_stat.st_atime_ns, source_stat.st_mtime_ns))
            _fsync_file(temporary)
            _publish_new_file(temporary, stored, before_digest)
            _fsync_directory(stored.parent)
        finally:
            try:
                temporary.unlink()
                _fsync_directory(stored.parent)
            except FileNotFoundError:
                pass

    old_record = manifest.data.get("files", {}).get(relpath, {})
    source_stat = source.stat()
    archived_mtime = (
        old_record.get("mtime", source_stat.st_mtime)
        if old_record.get("sha256") == before_digest else source_stat.st_mtime
    )
    version = {
        "id": str(uuid.uuid4()),
        "path": stored_relpath,
        "sha256": before_digest,
        "size": source_stat.st_size,
        "mtime": archived_mtime,
        "captured_at": datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
    }
    manifest.add_history(relpath, version)


def _run_android_command(android: AndroidFileSystem, command: List[str]) -> None:
    for line in android.adb_shell(command):
        if line:
            raise BackupError("Unexpected Android shell output: {}".format(line))


def _publish_new_file(temp: Path, target: Path, expected_sha256: str) -> None:
    """Publish a new file without replacing a path created by another process."""
    try:
        os.link(str(temp), str(target))
        return
    except FileExistsError as exc:
        raise BackupError("Refusing to overwrite a destination file created during transfer: {}".format(target)) from exc
    except OSError as exc:
        unsupported = {errno.EPERM, errno.ENOSYS, errno.ENOTSUP, getattr(errno, "EOPNOTSUPP", errno.ENOTSUP)}
        if exc.errno not in unsupported:
            raise

    # Some external filesystems do not support hard links. Reserve the path
    # with O_EXCL before copying the already validated temporary contents.
    try:
        descriptor = os.open(str(target), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except FileExistsError as exc:
        raise BackupError("Refusing to overwrite a destination file created during transfer: {}".format(target)) from exc
    try:
        output_stream = os.fdopen(descriptor, "wb")
        descriptor = -1
        with output_stream as output, temp.open("rb") as source:
            while True:
                block = source.read(1024 * 1024)
                if not block:
                    break
                output.write(block)
            output.flush()
        source_stat = temp.stat()
        os.utime(target, ns=(source_stat.st_atime_ns, source_stat.st_mtime_ns))
        with target.open("r+b") as output:
            os.fsync(output.fileno())
        if _hash_file(target) != expected_sha256:
            raise BackupError("Validated transfer changed while publishing {}".format(target))
    except BaseException:
        if descriptor >= 0:
            os.close(descriptor)
        raise


def _publish_local_export(temp: Path, target: Path) -> None:
    """Atomically publish a new export without falling back to partial writes."""
    try:
        os.link(str(temp), str(target))
    except FileExistsError as exc:
        raise BackupError("Refusing to overwrite a destination file created during export: {}".format(target)) from exc
    except OSError as exc:
        unsupported = {errno.EPERM, errno.ENOSYS, errno.ENOTSUP, getattr(errno, "EOPNOTSUPP", errno.ENOTSUP)}
        if exc.errno in unsupported:
            raise BackupError(
                "Destination filesystem does not support atomic no-overwrite export; choose another location or pass --overwrite"
            ) from exc
        raise


def _validate_host_path_collisions(paths, case_insensitive: bool) -> None:
    """Reject distinct Android paths that the host volume would alias."""
    if not case_insensitive:
        return
    seen = {}
    for relpath in paths:
        parts = relpath.split("/")
        for end in range(1, len(parts) + 1):
            original = "/".join(parts[:end])
            key = unicodedata.normalize("NFD", original).casefold()
            previous = seen.setdefault(key, original)
            if previous != original:
                raise BackupError(
                    "Android paths {!r} and {!r} collide on a case-insensitive or Unicode-normalizing destination".format(
                        previous, original
                    )
                )


@contextmanager
def _backup_lock(root: Path):
    lock_path = root / LOCK_FILENAME
    if lock_path.is_symlink():
        raise BackupError("Refusing to use a symlink as the backup lock")
    with lock_path.open("a+b") as stream:
        windows_lock = os.name == "nt"
        try:
            if windows_lock:
                import msvcrt
                stream.seek(0, os.SEEK_END)
                if stream.tell() == 0:
                    stream.write(b"\0")
                    stream.flush()
                stream.seek(0)
                msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except (OSError, BlockingIOError) as exc:
            raise BackupError("Another phonebackup operation is using {}".format(root)) from exc
        try:
            yield
        finally:
            if windows_lock:
                import msvcrt
                stream.seek(0)
                msvcrt.locking(stream.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                import fcntl
                fcntl.flock(stream.fileno(), fcntl.LOCK_UN)


class Backup:
    """Operate on a backup directory; all file replacement is atomic."""

    def __init__(self, destination: str, adb_arguments: List[str], encoding: str = "UTF-8", remote_root: str = "/sdcard"):
        self.root = Path(destination).expanduser().absolute()
        self.remote_root = remote_root
        self.manifest_path = self.root / MANIFEST_FILENAME
        self.manifest = Manifest.for_backup(self.root)
        self.adb_arguments = adb_arguments
        self.encoding = encoding
        self.android = None

    def _get_android(self) -> AndroidFileSystem:
        if self.android is None:
            if "-s" not in self.adb_arguments:
                result = subprocess.run(self.adb_arguments + ["devices"], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                if result.returncode:
                    message = result.stderr.decode("utf-8", "replace").strip()
                    raise BackupError("Could not list ADB devices{}".format(": " + message if message else ""))
                devices = []
                for line in result.stdout.decode("utf-8", "replace").splitlines():
                    fields = line.split()
                    if len(fields) >= 2 and fields[1] == "device":
                        devices.append(fields[0])
                if not devices:
                    raise BackupError("No authorized ADB device found; connect a phone and accept its debugging prompt")
                if len(devices) > 1:
                    raise BackupError("Multiple ADB devices found; select one with --device SERIAL")
                self.adb_arguments = self.adb_arguments + ["-s", devices[0]]
            self.android = AndroidFileSystem(self.adb_arguments, self.encoding)
        return self.android

    def close(self):
        proc = getattr(self.android, "proc_adb_shell", None) if self.android is not None else None
        if proc is not None and proc.poll() is None:
            proc.stdin.close()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.terminate()

    def scan(self, selection: Optional[Selection] = None, allow_missing_includes: bool = False,
             allow_scan_errors: bool = False, validate_destination: bool = True) -> List[Tuple[str, FileMeta]]:
        android = self._get_android()
        android.test_connection()
        android.scan_errors = []
        android.scan_error_paths = []
        selection = selection or Selection()
        self.source_root = self.remote_root
        # `/sdcard` is commonly the Android compatibility symlink to
        # `/storage/emulated/<user>`. Resolve only the requested root; child
        # symlinks remain rejected by the scanner.
        root_stat = android.lstat(self.remote_root)
        if stat.S_ISLNK(root_stat.st_mode):
            self.source_root = android.realpath(self.remote_root)
        all_files: List[Tuple[str, FileMeta]] = []
        all_directories: List[Tuple[str, FileMeta]] = []
        missing_include_roots = set()
        if selection.include:
            for include_root in selection.minimal_include_roots():
                if selection.excludes_path(include_root):
                    continue
                remote_path = self.source_root.rstrip("/") + "/" + include_root
                current = self.source_root
                components = include_root.split("/")
                missing_ancestor = False
                for index, component in enumerate(components[:-1], start=1):
                    current = current.rstrip("/") + "/" + component
                    try:
                        ancestor = android.lstat(current)
                    except FileNotFoundError:
                        if not allow_missing_includes:
                            raise BackupError("Selected Android path does not exist: {}".format(include_root))
                        missing_include_roots.add(include_root)
                        missing_include_roots.add("/".join(components[:index]))
                        missing_ancestor = True
                        break
                    if stat.S_ISLNK(ancestor.st_mode):
                        raise BackupError("Selected Android path traverses a symlink: {}".format(include_root))
                    if not stat.S_ISDIR(ancestor.st_mode):
                        raise BackupError("Selected Android path has a non-directory ancestor: {}".format(include_root))
                if missing_ancestor:
                    continue
                try:
                    tree = android.get_files_tree(remote_path)
                except FileNotFoundError as exc:
                    # A disappeared, explicitly included path is equivalent to
                    # its files having disappeared from a full scan. Keep the
                    # old backup and let diff report those paths as preserved.
                    if not allow_missing_includes:
                        raise BackupError("Selected Android path does not exist: {}".format(include_root)) from exc
                    missing_include_roots.add(include_root)
                    continue
                if tree is None:
                    raise BackupError("Selected Android path is not a regular file or directory: {}".format(include_root))
                prefix = tuple(include_root.split("/"))
                all_files.extend(_iter_files(tree, prefix))
                all_directories.extend(_iter_directories(tree, prefix))
        else:
            tree = android.get_files_tree(self.source_root)
            if tree is None:
                raise BackupError("Android source is not a regular file or directory")
            all_files = list(_iter_files(tree))
            all_directories = list(_iter_directories(tree))
        errors = getattr(android, "scan_errors", [])
        error_paths = getattr(android, "scan_error_paths", [])
        relevant_errors = []
        for index, error in enumerate(errors):
            error_path = error_paths[index] if index < len(error_paths) else None
            parts = android.relative_parts(self.source_root, error_path) if error_path else None
            relpath = "/".join(parts) if parts is not None else None
            if (relpath in missing_include_roots and
                    ("No such file" in error or "not found" in error.lower())):
                continue
            if relpath is None or not selection.excludes_path(relpath):
                relevant_errors.append(error)
        self.scan_warnings = list(relevant_errors)
        if relevant_errors and not allow_scan_errors:
            raise BackupError("Incomplete Android scan: " + "; ".join(relevant_errors))
        self.directories = [(path, meta) for path, meta in all_directories if selection.selects_directory(path)]
        files = [(path, meta) for path, meta in all_files if selection.selects_file(path)]
        if validate_destination:
            _validate_host_path_collisions(
                [relpath for relpath, _ in files] + [relpath for relpath, _ in self.directories],
                case_insensitive=(sys.platform == "darwin" or os.name == "nt"),
            )
            reserved = (MANIFEST_FILENAME, JOURNAL_FILENAME, LOCK_FILENAME, HISTORY_DIRECTORY)
            if any(relpath.split("/", 1)[0] in reserved for relpath, _ in files):
                raise BackupError("Phone contains reserved backup metadata path; refusing to overwrite it")
        return files

    def paths(self) -> Dict[str, object]:
        """List source paths without creating or changing a backup directory."""
        files = self.scan(Selection(), allow_scan_errors=True, validate_destination=False)
        entries = [
            {"path": path, "type": "directory", "size": None, "mtime": meta.mtime}
            for path, meta in getattr(self, "directories", [])
        ]
        entries.extend(
            {"path": path, "type": "file", "size": meta.size, "mtime": meta.mtime}
            for path, meta in files
        )
        entries.sort(key=lambda entry: (entry["path"], entry["type"]))
        return {"remote_root": self.source_root, "entries": entries, "warnings": self.scan_warnings}

    def history(self, relpath: Optional[str] = None) -> Dict[str, object]:
        """Return retained prior versions, optionally for one relative path."""
        if self.root.is_symlink() or not self.root.is_dir():
            raise BackupError("Backup directory does not exist or is unsafe")
        with _backup_lock(self.root):
            self._prepare_root(False, check_remote_root=False)
            versions = self.manifest.data.get("history", {})
            if relpath is not None:
                try:
                    relpath = Selection([relpath]).include[0]
                except (IndexError, TypeError, ValueError) as exc:
                    raise BackupError("Invalid Android file path: {}".format(exc)) from exc
                return {"path": relpath, "versions": list(versions.get(relpath, []))}
            return {"files": {path: list(items) for path, items in sorted(versions.items())}}

    def prune_history(self, version_ids: List[str], relpath: Optional[str] = None,
                      apply: bool = False) -> Dict[str, object]:
        """Preview or remove explicitly selected per-file history versions."""
        if not version_ids or any(not isinstance(item, str) or not item for item in version_ids):
            raise BackupError("Select one or more history version IDs")
        requested = set(version_ids)
        if relpath is not None:
            try:
                relpath = Selection([relpath]).include[0]
            except (IndexError, TypeError, ValueError) as exc:
                raise BackupError("Invalid Android file path: {}".format(exc)) from exc
        if self.root.is_symlink() or not self.root.is_dir():
            raise BackupError("Backup directory does not exist or is unsafe")
        with _backup_lock(self.root):
            self._prepare_root(False, check_remote_root=False)
            pending_prune = self.manifest.data.get("pending_prune")
            if pending_prune is not None:
                pending_ids = set(pending_prune["version_ids"])
                same_selection = (
                    requested == pending_ids and
                    (relpath is None or all(path == relpath for path in pending_prune["version_paths"].values()))
                )
                if apply and not same_selection:
                    raise BackupError(
                        "A history prune is pending; repeat the same version IDs and path scope with --apply"
                    )
                if same_selection and not apply:
                    retained = {
                        version["path"]
                        for versions in self.manifest.data.get("history", {}).values()
                        for version in versions
                    }
                    pending_files = []
                    for blob in pending_prune["files"]:
                        if blob["path"] in retained:
                            continue
                        target = _safe_target(self.root, blob["path"])
                        try:
                            metadata = target.lstat()
                        except FileNotFoundError:
                            continue
                        if not stat.S_ISREG(metadata.st_mode) or _hash_file(target) != blob["sha256"]:
                            raise BackupError("Pending prune file changed; leaving it in place: {}".format(target))
                        pending_files.append(blob)
                    bytes_pending = sum(blob["size"] for blob in pending_files)
                    print("{} version(s); {} history file(s), {} bytes remain to be pruned".format(
                        len(requested), len(pending_files), bytes_pending
                    ))
                    return {"versions": len(requested), "files": len(pending_files),
                            "bytes": bytes_pending, "applied": False}
                if apply:
                    removed_files, removed_bytes = self._finish_pending_prune()
                    print("Completed pending prune: {} history file(s), {} bytes removed".format(
                        removed_files, removed_bytes
                    ))
                    return {"versions": len(requested), "files": removed_files,
                            "bytes": removed_bytes, "applied": True}
            history = self.manifest.data.get("history", {})
            selected = []
            for path, versions in history.items():
                if relpath is not None and path != relpath:
                    continue
                for version in versions:
                    if version["id"] in requested:
                        selected.append((path, version))
            found = {version["id"] for _, version in selected}
            unknown = requested - found
            if unknown:
                raise BackupError("Unknown history version ID(s): {}".format(", ".join(sorted(unknown))))

            selected_ids = {version["id"] for _, version in selected}
            selected_paths = {version["path"] for _, version in selected}
            retained_paths = {
                version["path"]
                for path, versions in history.items()
                for version in versions
                if version["id"] not in selected_ids
            }
            orphan_paths = sorted(selected_paths - retained_paths)
            orphan_records = {}
            for path, version in selected:
                orphan_records[version["path"]] = version
            bytes_to_remove = 0
            existing_orphans = set()
            for stored_relpath in orphan_paths:
                target = _safe_target(self.root, stored_relpath)
                try:
                    metadata = target.lstat()
                except FileNotFoundError:
                    continue
                version = orphan_records[stored_relpath]
                if not stat.S_ISREG(metadata.st_mode) or _hash_file(target) != version["sha256"]:
                    raise BackupError("Refusing to prune a corrupt or changed history file: {}".format(target))
                existing_orphans.add(stored_relpath)
                bytes_to_remove += metadata.st_size
            files_to_remove = len(existing_orphans)
            for path, version in selected:
                print("{} {}  {}  {} bytes  {}".format(
                    "PRUNE" if apply else "WOULD PRUNE", path, version["id"],
                    version["size"], version["captured_at"]
                ))
            print("{} version(s); {} history file(s), {} bytes {}".format(
                len(selected), files_to_remove, bytes_to_remove,
                "will be removed" if apply else "would be removed"
            ))
            if not apply:
                return {"versions": len(selected), "files": files_to_remove,
                        "bytes": bytes_to_remove, "applied": False}

            pending_files = [
                {"path": path, "sha256": orphan_records[path]["sha256"],
                 "size": orphan_records[path]["size"]}
                for path in sorted(existing_orphans)
            ]
            self.manifest.begin_prune({
                "version_ids": sorted(selected_ids),
                "version_paths": {version["id"]: path for path, version in selected},
                "files": pending_files
            })
            self._finish_pending_prune()
            return {"versions": len(selected), "files": files_to_remove,
                    "bytes": bytes_to_remove, "applied": True}

    def _finish_pending_prune(self):
        """Finish blob deletion after its history references were durably removed."""
        pending = self.manifest.data.get("pending_prune")
        if pending is None:
            return 0, 0
        removed_files = removed_bytes = 0
        retained_paths = {
            version["path"]
            for versions in self.manifest.data.get("history", {}).values()
            for version in versions
        }
        for blob in pending["files"]:
            if blob["path"] in retained_paths:
                continue
            target = _safe_target(self.root, blob["path"])
            try:
                metadata = target.lstat()
            except FileNotFoundError:
                continue
            if not stat.S_ISREG(metadata.st_mode) or _hash_file(target) != blob["sha256"]:
                raise BackupError("Pending prune file changed; leaving it in place: {}".format(target))
            target.unlink()
            _fsync_directory(target.parent)
            removed_files += 1
            removed_bytes += metadata.st_size
            try:
                target.parent.rmdir()
                _fsync_directory(target.parent.parent)
            except OSError:
                pass
        self.manifest.finish_prune()
        self.manifest.checkpoint()
        return removed_files, removed_bytes

    def _restore_source(self, relpath: str, version_id: Optional[str]):
        try:
            relpath = Selection([relpath]).include[0]
        except (IndexError, TypeError, ValueError) as exc:
            raise BackupError("Invalid Android file path: {}".format(exc)) from exc
        if relpath.split("/", 1)[0] in (MANIFEST_FILENAME, JOURNAL_FILENAME, LOCK_FILENAME, HISTORY_DIRECTORY):
            raise BackupError("Refusing to restore into a reserved PhoneBackup metadata path")
        if version_id is None:
            record = self.manifest.data.get("files", {}).get(relpath)
            if record is None:
                raise BackupError("No current backup copy exists for {}".format(relpath))
            source = _safe_target(self.root, relpath)
            has_stored_hash = bool(record.get("sha256"))
            digest = record.get("sha256") or _hash_file(source)
            return relpath, source, digest, record["size"], record["mtime"], "current", has_stored_hash
        versions = self.manifest.data.get("history", {}).get(relpath, [])
        version = next((item for item in versions if item.get("id") == version_id), None)
        if version is None:
            raise BackupError("No historical version {} exists for {}".format(version_id, relpath))
        source = _safe_target(self.root, version["path"])
        return relpath, source, version["sha256"], version["size"], version["mtime"], version_id, True

    def restore(self, relpath: str, to_local: Optional[str] = None, to_phone: bool = False,
                version_id: Optional[str] = None, overwrite: bool = False,
                dry_run: bool = False) -> Dict[str, object]:
        if (to_local is None) == (not to_phone):
            raise BackupError("Choose exactly one restore target: --to-local or --to-phone")
        if self.root.is_symlink() or not self.root.is_dir():
            raise BackupError("Backup directory does not exist or is unsafe")
        with _backup_lock(self.root):
            self._prepare_root(False, check_remote_root=to_phone)
            relpath, source, digest, size, mtime, version, has_stored_hash = self._restore_source(relpath, version_id)
            try:
                mode = source.lstat().st_mode
            except FileNotFoundError as exc:
                raise BackupError("Restore source is missing: {}".format(source)) from exc
            if not stat.S_ISREG(mode) or source.stat().st_size != size or _hash_file(source) != digest:
                raise BackupError("Restore source failed integrity verification: {}".format(source))
            if not has_stored_hash:
                print("WARNING: no stored SHA-256 for {}; verifying this restore against its current local bytes only".format(relpath))
            if to_local is not None:
                return self._restore_local(relpath, source, digest, size, mtime, version,
                                           to_local, overwrite, dry_run)
            return self._restore_phone(relpath, source, digest, size, mtime, version, overwrite, dry_run)

    def _restore_local(self, relpath, source, digest, size, mtime, version,
                       destination, overwrite, dry_run):
        requested = Path(destination).expanduser().absolute()
        if requested.name in ("", ".", ".."):
            raise BackupError("Local restore destination must name a file")
        try:
            parent = requested.parent.resolve(strict=True)
        except OSError as exc:
            raise BackupError("Local restore parent directory does not exist: {}".format(requested.parent)) from exc
        if not parent.is_dir():
            raise BackupError("Local restore parent is not a directory: {}".format(parent))
        target = parent / requested.name
        try:
            mode = target.lstat().st_mode
        except FileNotFoundError:
            exists = False
        else:
            exists = True
            if stat.S_ISLNK(mode) or not stat.S_ISREG(mode):
                raise BackupError("Refusing to replace non-file or symlink: {}".format(target))
            if not overwrite:
                raise BackupError("Local restore destination already exists; pass --overwrite: {}".format(target))
        if _directory_contains(self.root.resolve(), parent):
            raise BackupError("Local restore destination cannot be inside the backup directory")
        print("{} {} -> {} (version {})".format("Would restore" if dry_run else "Restoring", relpath, target, version))
        if dry_run:
            return {"target": str(target), "version": version, "restored": False}
        descriptor, temp_name = tempfile.mkstemp(prefix=".phonebackup-restore-", suffix=".partial", dir=str(parent))
        os.close(descriptor)
        temporary = Path(temp_name)
        try:
            shutil.copyfile(str(source), str(temporary))
            if temporary.stat().st_size != size or _hash_file(temporary) != digest:
                raise BackupError("Local restore copy failed integrity verification")
            os.utime(temporary, (mtime, mtime))
            _fsync_file(temporary)
            if overwrite:
                # Recheck even when absent at preflight: a symlink or special
                # file may have appeared while the export was staged.
                try:
                    mode = target.lstat().st_mode
                except FileNotFoundError:
                    mode = None
                if mode is not None and (stat.S_ISLNK(mode) or not stat.S_ISREG(mode)):
                    raise BackupError("Refusing to replace non-file or symlink: {}".format(target))
                os.replace(str(temporary), str(target))
            else:
                _publish_local_export(temporary, target)
            _fsync_directory(parent)
        finally:
            try:
                temporary.unlink()
            except FileNotFoundError:
                pass
        print("Restored {} to {}".format(relpath, target))
        return {"target": str(target), "version": version, "restored": True}

    def _restore_phone(self, relpath, source, digest, size, mtime, version, overwrite, dry_run):
        android = self._get_android()
        android.test_connection()
        remote_root = self.manifest.data["remote_root"]
        root_stat = android.lstat(remote_root)
        if stat.S_ISLNK(root_stat.st_mode):
            remote_root = android.realpath(remote_root)
        components = relpath.split("/")
        current = remote_root
        for component in components[:-1]:
            current = current.rstrip("/") + "/" + component
            try:
                ancestor = android.lstat(current)
            except FileNotFoundError:
                continue
            if stat.S_ISLNK(ancestor.st_mode) or not stat.S_ISDIR(ancestor.st_mode):
                raise BackupError("Refusing to restore through a non-directory or symlink: {}".format(current))
        target = remote_root.rstrip("/") + "/" + relpath
        try:
            target_stat = android.lstat(target)
        except FileNotFoundError:
            exists = False
        else:
            exists = True
            if stat.S_ISLNK(target_stat.st_mode) or not stat.S_ISREG(target_stat.st_mode):
                raise BackupError("Refusing to replace non-file or symlink on Android: {}".format(target))
            if not overwrite:
                raise BackupError("Android restore destination already exists; pass --overwrite: {}".format(target))
        print("{} {} -> Android:{} (version {})".format(
            "Would restore" if dry_run else "Restoring", relpath, target, version
        ))
        if dry_run:
            return {"target": target, "version": version, "restored": False}
        parent = target.rsplit("/", 1)[0]
        _run_android_command(android, ["mkdir", "-p", parent])
        temporary = parent.rstrip("/") + "/.phonebackup-restore-" + uuid.uuid4().hex + ".partial"
        try:
            result = subprocess.run(self.adb_arguments + ["push", str(source), temporary],
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if result.returncode:
                message = result.stderr.decode("utf-8", "replace").strip() or "adb push returned {}".format(result.returncode)
                raise BackupError("Phone restore transfer failed: {}".format(message))
            temporary_stat = android.lstat(temporary)
            if not stat.S_ISREG(temporary_stat.st_mode) or temporary_stat.st_size != size:
                raise BackupError("Phone restore temporary file failed size verification")
            try:
                target_stat = android.lstat(target)
            except FileNotFoundError:
                pass
            else:
                if stat.S_ISLNK(target_stat.st_mode) or not stat.S_ISREG(target_stat.st_mode):
                    raise BackupError("Refusing to replace non-file or symlink on Android: {}".format(target))
                if not overwrite:
                    raise BackupError("Android restore destination appeared during transfer: {}".format(target))
            if overwrite:
                _run_android_command(android, ["mv", "-f", "-T", temporary, target])
                try:
                    android.lstat(temporary)
                except FileNotFoundError:
                    moved = True
                else:
                    moved = False
                if not moved:
                    raise BackupError("Android restore temporary file was not published")
            else:
                # Toybox ln creates the destination directory entry atomically
                # and fails if the target appeared after preflight. `mv -n`
                # has a stat/rename race and is not suitable for this case.
                try:
                    _run_android_command(android, ["ln", "-T", temporary, target])
                except BrokenPipeError as exc:
                    reason = str(exc).lower().rsplit(": ", 1)[-1]
                    if reason in ("permission denied", "operation not permitted"):
                        raise BackupError(
                            "Android refused the hard-link step required for a no-overwrite phone restore. "
                            "Confirm the destination does not exist, then retry with --overwrite: {}".format(target)
                        ) from exc
                    raise
            final_stat = android.lstat(target)
            if not stat.S_ISREG(final_stat.st_mode) or final_stat.st_size != size:
                raise BackupError("Restored Android file failed size verification")
            if not overwrite:
                _run_android_command(android, ["rm", "-f", temporary])
            android.utime(target, (mtime, mtime))
        finally:
            try:
                _run_android_command(android, ["rm", "-f", temporary])
            except Exception:
                pass
        print("Restored {} to Android:{}".format(relpath, target))
        return {"target": target, "version": version, "restored": True}

    def _prepare_root(self, create: bool, check_remote_root: bool = True):
        if self.manifest_path.is_symlink():
            raise BackupError("Refusing to read or overwrite a symlink as the backup manifest")
        if create:
            if self.root.exists():
                if self.root.is_symlink() or not self.root.is_dir():
                    raise BackupError("Backup destination must be a real directory")
                try:
                    self.manifest.load(remote_root=self.remote_root)
                    if check_remote_root and self.manifest.data.get("remote_root") != self.remote_root:
                        raise BackupError("Backup was created from {}; use the same --remote-root".format(self.manifest.data.get("remote_root")))
                except ManifestError as exc:
                    if self.manifest_path.exists() or "does not exist" not in str(exc):
                        raise
                    if any(entry.name != LOCK_FILENAME for entry in self.root.iterdir()):
                        raise BackupError("Destination is not an existing phonebackup; refusing to use a non-empty directory")
                else:
                    raise BackupError("Destination already contains a phonebackup; use update instead of new")
            self.root.mkdir(parents=True, exist_ok=True)
            self.manifest.load(create=True, remote_root=self.remote_root)
        else:
            if not self.root.is_dir() or self.root.is_symlink():
                raise BackupError("Backup directory does not exist or is unsafe")
            self.manifest.load(remote_root=self.remote_root)
            if check_remote_root and self.manifest.data.get("remote_root") != self.remote_root:
                raise BackupError("Backup was created from {}; use the same --remote-root".format(self.manifest.data.get("remote_root")))

    def _plan_transfers(self, files, recovering: bool, dry_run: bool):
        manifest_files = self.manifest.data.setdefault("files", {})
        identities = {}
        pending_owned = {}
        refreshed = {}
        transfers: List[Tuple[str, FileMeta, Path]] = []
        skipped = changed = 0
        tolerance = max(getattr(self._get_android(), "mtime_precision", 1), 2)
        try:
            identities = _build_identity_index(self.root, manifest_files)
            for relpath, meta in files:
                target = _safe_target(self.root, relpath)
                old = manifest_files.get(relpath)
                try:
                    local = target.lstat()
                except FileNotFoundError:
                    local = None
                pending = self.manifest.data.get("pending", {}).get(relpath)
                if local is not None and old is None:
                    owned_hash = _pending_target_hash(pending, target) if pending else None
                    if owned_hash is None:
                        raise BackupError(
                            "Refusing to overwrite an untracked or incomplete destination file: {}. "
                            "Move that file aside, then rerun update to recover the pending transfer.".format(target)
                        )
                    pending_owned[relpath] = owned_hash
                if local is not None:
                    _check_file_identity(target, relpath, identities)
                identical_meta = local is not None and stat.S_ISREG(local.st_mode) and local.st_size == meta.size
                fresh = identical_meta and abs(int(local.st_mtime) - int(meta.mtime)) <= tolerance and not recovering
                if fresh and old and old.get("sha256"):
                    fresh = _hash_file(target) == old["sha256"]
                if fresh:
                    skipped += 1
                    if not dry_run:
                        refreshed[relpath] = {"size": meta.size, "mtime": meta.mtime,
                                              **({"sha256": old["sha256"]} if old and old.get("sha256") else {})}
                    continue
                transfers.append((relpath, meta, target))
                if old is not None:
                    changed += 1
        except Exception as exc:
            if not dry_run:
                try:
                    self.manifest.fail(str(exc))
                    self.manifest.checkpoint()
                except ManifestError:
                    pass
                print("Failed: 0 transferred, 0 skipped, 1 failed; backup marked incomplete: {}".format(exc))
            raise
        return transfers, skipped, changed, identities, pending_owned, refreshed

    def _resolve_selection(self, include, exclude, all_files: bool) -> Selection:
        if all_files:
            return Selection()
        stored = self.manifest.data.get("selection", {"include": [], "exclude": []})
        try:
            return Selection(stored["include"] if include is None else include,
                             stored["exclude"] if exclude is None else exclude)
        except (TypeError, ValueError) as exc:
            raise BackupError("Invalid backup selection: {}".format(exc)) from exc

    def run(self, create: bool = False, dry_run: bool = False, include=None, exclude=None,
            all_files: bool = False) -> Dict[str, object]:
        if self.root.is_symlink():
            raise BackupError("Backup destination must be a real directory")
        if create:
            _mkdirs_durable(self.root)
        elif not self.root.is_dir():
            raise BackupError("Backup directory does not exist or is unsafe")
        with _backup_lock(self.root):
            return self._run_locked(create, dry_run, include, exclude, all_files)

    def _run_locked(self, create: bool, dry_run: bool, include=None, exclude=None,
                    all_files: bool = False) -> Dict[str, object]:
        started = time.monotonic()
        self._prepare_root(create)
        selection = self._resolve_selection(include, exclude, all_files)
        allow_missing_includes = (
            include is None and not all_files and
            self.manifest.data.get("validated_selection") ==
            {"include": selection.include, "exclude": selection.exclude}
        )
        recovering = bool(self.manifest.data.get("incomplete"))
        if not dry_run:
            self.manifest.set_selection(selection.include, selection.exclude)
            self.manifest.begin_attempt()
        try:
            files = self.scan(selection, allow_missing_includes=allow_missing_includes)
        except Exception as exc:
            if not dry_run:
                try:
                    self.manifest.fail(str(exc))
                    self.manifest.checkpoint()
                except ManifestError:
                    pass
                print("Failed: 0 transferred, 0 skipped, 1 failed in {:.1f}s; backup marked incomplete: {}".format(
                    time.monotonic() - started, exc))
            raise
        transfers, skipped, changed, identities, pending_owned, refreshed = self._plan_transfers(
            files, recovering, dry_run
        )
        new_files = len(transfers) - changed

        if dry_run:
            for relpath, _, _ in transfers:
                print("{} {}".format("UPDATE" if relpath in self.manifest.data.get("files", {}) else "NEW", relpath))
            print("{} new, {} changed, {} unchanged".format(new_files, changed, skipped))
            return {"transferred": 0, "new": new_files, "changed": changed, "skipped": skipped, "bytes": 0}

        transferred = byte_count = 0
        changed_paths = {relpath for relpath, _, _ in transfers
                         if relpath in self.manifest.data.get("files", {})}
        changed_transferred = 0
        try:
            # Journal skipped-file metadata before starting transfers.
            self.manifest.record_files(refreshed)
            self.created_directory_identities = {}
            for relpath, _ in sorted(getattr(self, "directories", []), key=lambda item: item[0].count("/")):
                directory = _ensure_directory(self.root, relpath)
                metadata = directory.stat()
                identity = metadata.st_dev, metadata.st_ino
                other_relpath = self.created_directory_identities.get(identity)
                if other_relpath is not None and other_relpath != relpath:
                    raise BackupError("Android directories {!r} and {!r} alias on this filesystem".format(
                        relpath, other_relpath
                    ))
                self.created_directory_identities[identity] = relpath
            for relpath, meta, target in transfers:
                parent_relpath = "/".join(relpath.split("/")[:-1])
                if parent_relpath:
                    _ensure_directory(self.root, parent_relpath)
                # Recheck every parent after creation to guard against symlink
                # replacement and avoid writing outside the backup root.
                target = _safe_target(self.root, relpath)
                pending_before = relpath in self.manifest.data.get("pending", {})
                tracked_before = relpath in self.manifest.data.get("files", {})
                try:
                    target_stat = target.lstat()
                    target_existed = True
                except FileNotFoundError:
                    target_stat = None
                    target_existed = False
                replace_existing = tracked_before or (relpath in pending_owned and target_existed)
                if replace_existing and not tracked_before and pending_before:
                    pending_record = self.manifest.data["pending"][relpath]
                    if _pending_target_hash(pending_record, target) != pending_owned[relpath]:
                        raise BackupError("Pending destination changed ownership during transfer: {}".format(target))
                fd, temp_name = tempfile.mkstemp(prefix=".phonebackup-", suffix=".partial", dir=str(target.parent))
                os.close(fd)
                temp = Path(temp_name)
                try:
                    temp_relpath = temp.relative_to(self.root).as_posix()
                    self.manifest.begin_file(relpath, size=meta.size, mtime=meta.mtime,
                                             temp_path=temp_relpath,
                                             target_sha256=pending_owned.get(relpath))
                    _fsync_directory(temp.parent)
                    remote = self.source_root.rstrip("/") + "/" + relpath
                    result = subprocess.run(self.android.adb_arguments + ["pull", remote, str(temp)],
                                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                    if result.returncode:
                        message = result.stderr.decode("utf-8", "replace").strip() or "adb pull returned {}".format(result.returncode)
                        raise BackupError("Transfer failed for {}: {}".format(relpath, message))
                    size = temp.stat().st_size
                    if size != meta.size:
                        raise BackupError("Incomplete transfer for {}: expected {} bytes, received {}".format(relpath, meta.size, size))
                    os.utime(temp, (meta.mtime, meta.mtime))
                    digest = _hash_file(temp)
                    _fsync_file(temp)
                    self.manifest.set_pending_digest(relpath, digest)
                    target = _safe_target(self.root, relpath)
                    if tracked_before:
                        try:
                            target.lstat()
                        except FileNotFoundError:
                            pass
                        else:
                            _archive_previous_version(self.root, self.manifest, relpath, target, digest)
                    if replace_existing and not tracked_before:
                        try:
                            target_stat = target.lstat()
                        except FileNotFoundError:
                            # The previously owned interrupted target vanished;
                            # publish this completed transfer as a new path.
                            replace_existing = False
                        else:
                            if _pending_target_hash(self.manifest.data["pending"][relpath], target) != pending_owned[relpath]:
                                raise BackupError("Pending destination changed ownership during transfer: {}".format(target))
                    _check_file_identity(target, relpath, identities)
                    old_identity = None
                    try:
                        old_identity = _file_identity(target)
                    except FileNotFoundError:
                        pass
                    if replace_existing:
                        os.replace(str(temp), str(target))
                    else:
                        _publish_new_file(temp, target, digest)
                    _fsync_directory(target.parent)
                    try:
                        temp.unlink()
                        _fsync_directory(target.parent)
                    except FileNotFoundError:
                        pass
                    if old_identity is not None and identities.get(old_identity) == relpath:
                        identities.pop(old_identity, None)
                    new_identity = _file_identity(target)
                    identities[new_identity] = relpath
                    self.manifest.record_file(relpath, size=meta.size, mtime=meta.mtime, sha256=digest)
                    transferred += 1
                    if relpath in changed_paths:
                        changed_transferred += 1
                    byte_count += size
                    logging.info("Transferred %s (%d bytes)", relpath, size)
                finally:
                    pending = self.manifest.data.get("pending", {}).get(relpath)
                    keep_for_recovery = False
                    if pending is not None:
                        try:
                            current_target = target.lstat()
                            keep_for_recovery = _pending_target_hash(pending, target) is not None
                        except (FileNotFoundError, BackupError, OSError):
                            pass
                    if not keep_for_recovery:
                        try:
                            temp.unlink()
                        except FileNotFoundError:
                            pass
            # Restore current Android directory mtimes after file and manifest
            # writes. The backup root itself contains the manifest, so its
            # timestamp is necessarily managed by the host.
            for relpath, meta in sorted(getattr(self, "directories", []),
                                        key=lambda item: item[0].count("/"), reverse=True):
                directory = _ensure_directory(self.root, relpath)
                os.utime(directory, (meta.mtime, meta.mtime))
                _fsync_directory(directory)
            self.manifest.finish_success()
            self.manifest.checkpoint()
        except Exception as exc:
            try:
                self.manifest.fail(str(exc))
                self.manifest.checkpoint()
            except ManifestError:
                pass
            print("Partial: {} transferred ({} new, {} changed), {} skipped, 1 failed, {} bytes in {:.1f}s; backup marked incomplete: {}".format(
                transferred, transferred - changed_transferred, changed_transferred, skipped,
                byte_count, time.monotonic() - started, exc))
            raise
        elapsed = time.monotonic() - started
        result = {"transferred": transferred, "new": new_files, "changed": changed, "skipped": skipped,
                  "bytes": byte_count, "elapsed": elapsed, "failed": 0}
        print("Complete: {transferred} transferred ({new} new, {changed} changed), {skipped} skipped, {bytes} bytes in {elapsed:.1f}s".format(**result))
        return result

    def diff(self, include=None, exclude=None, all_files: bool = False) -> Dict[str, int]:
        if self.root.is_symlink() or not self.root.is_dir():
            raise BackupError("Backup directory does not exist or is unsafe")
        with _backup_lock(self.root):
            return self._diff_locked(include, exclude, all_files)

    def _diff_locked(self, include=None, exclude=None, all_files: bool = False) -> Dict[str, int]:
        self._prepare_root(False)
        selection = self._resolve_selection(include, exclude, all_files)
        allow_missing_includes = (
            include is None and not all_files and
            self.manifest.data.get("validated_selection") ==
            {"include": selection.include, "exclude": selection.exclude}
        )
        files = self.scan(selection, allow_missing_includes=allow_missing_includes)
        manifest_files = self.manifest.data.get("files", {})
        recovering = bool(self.manifest.data.get("incomplete"))
        planned, _, changed, _, _, _ = self._plan_transfers(files, recovering, dry_run=True)
        for relpath, _, _ in planned:
            print("{} {}".format("UPDATE" if relpath in manifest_files else "NEW", relpath))
        transfers = len(planned)
        live_paths = {relpath for relpath, _ in files}
        preserved = missing_backup = 0
        for relpath in sorted(manifest_files):
            if relpath not in live_paths:
                target = _safe_target(self.root, relpath)
                try:
                    mode = target.lstat().st_mode
                except FileNotFoundError:
                    print("MISSING BACKUP {}".format(relpath))
                    missing_backup += 1
                    continue
                if not stat.S_ISREG(mode):
                    print("INVALID BACKUP TYPE {}".format(relpath))
                    missing_backup += 1
                    continue
                reason = "not found on phone" if selection.selects_file(relpath) else "outside current selection"
                print("PRESERVED ({}) {}".format(reason, relpath))
                preserved += 1
        print("{} new, {} changed; {} file(s) would be transferred".format(transfers - changed, changed, transfers))
        return {"new": transfers - changed, "changed": changed, "files": len(files),
                "preserved": preserved, "missing_backup": missing_backup}

    def verify(self) -> Dict[str, int]:
        if self.root.is_symlink() or not self.root.is_dir():
            raise BackupError("Backup directory does not exist or is unsafe")
        with _backup_lock(self.root):
            return self._verify_locked()

    def _verify_locked(self) -> Dict[str, int]:
        if self.root.is_symlink() or not self.root.is_dir():
            raise BackupError("Backup directory does not exist or is unsafe")
        if self.manifest_path.is_symlink():
            raise BackupError("Refusing to read a symlink as the backup manifest")
        self.manifest.load()
        checked = failed = no_hash = history_checked = 0
        for relpath, record in sorted(self.manifest.data.get("files", {}).items()):
            target = _safe_target(self.root, relpath)
            if not target.exists():
                print("MISSING {}".format(relpath)); failed += 1; continue
            if not record.get("sha256"):
                print("NO HASH {} (local metadata only)".format(relpath)); no_hash += 1; continue
            if _hash_file(target) != record["sha256"]:
                print("CORRUPT {}".format(relpath)); failed += 1
            else:
                checked += 1
        for relpath in sorted(self.manifest.data.get("pending", {})):
            print("PENDING {} (transfer did not complete)".format(relpath))
            failed += 1
        for relpath, versions in sorted(self.manifest.data.get("history", {}).items()):
            for version in versions:
                target = _safe_target(self.root, version["path"])
                if not target.exists() or _hash_file(target) != version["sha256"]:
                    print("CORRUPT HISTORY {} ({})".format(relpath, version["id"]))
                    failed += 1
                else:
                    history_checked += 1
        print("Verified {} current file(s) and {} historical version(s), {} missing/corrupt, {} without stored hashes (local integrity only)".format(
            checked, history_checked, failed, no_hash
        ))
        return {"checked": checked, "history_checked": history_checked, "failed": failed, "no_hash": no_hash}


def status(destination: str) -> Dict[str, object]:
    root = Path(destination).expanduser().absolute()
    if root.is_symlink() or not root.is_dir():
        raise BackupError("Backup directory does not exist or is unsafe")
    with _backup_lock(root):
        manifest_path = root / MANIFEST_FILENAME
        if manifest_path.is_symlink():
            raise BackupError("Refusing to read a symlink as the backup manifest")
        manifest = Manifest.for_backup(root).load()
        summary = manifest.status_summary()
    print("Backup: {}".format(root))
    print("Source: {}".format(summary["remote_root"]))
    print("Last attempt: {}".format(summary["last_attempt"] or "never"))
    print("Last success: {}".format(summary["last_success"] or "never"))
    print("Files: {} ({} with SHA-256), total {} bytes".format(summary["file_count"], summary["files_with_sha256"], summary["total_size"]))
    print("Historical versions: {}".format(summary["history_version_count"]))
    if summary["pending_prune_ids"]:
        resume = "phonebackup prune-history {} {} --apply".format(
            shlex.quote(str(root)),
            " ".join("--version {}".format(shlex.quote(version_id))
                     for version_id in summary["pending_prune_ids"])
        )
        print("Pending history prune: {} ({} blob(s)); resume with: {}".format(
            ", ".join(summary["pending_prune_ids"]), summary["pending_prune_file_count"],
            resume
        ))
    selection = summary["selection"]
    print("Includes: {}".format(", ".join(selection["include"]) if selection["include"] else "everything"))
    print("Excludes: {}".format(", ".join(selection["exclude"]) if selection["exclude"] else "none"))
    if summary["pending_count"]:
        print("Pending transfers: {}".format(summary["pending_count"]))
    print("State: {}".format("INCOMPLETE" if summary["incomplete"] else "complete"))
    if summary["last_error"]:
        print("Last error: {}".format(summary["last_error"]))
    return summary

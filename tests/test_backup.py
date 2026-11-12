"""End-to-end backup tests against a small fake ADB executable."""

import os
import hashlib
import json
from pathlib import Path
import errno

import pytest

from BestestADBSync.Backup import (
    Backup, BackupError, _backup_lock, _build_identity_index, _publish_new_file,
    _pending_target_hash, _validate_host_path_collisions, status,
)
from BestestADBSync.Manifest import MANIFEST_FILENAME
from BestestADBSync import backup_main


FAKE_ADB = r'''#!/usr/bin/env python3
import os, shlex, shutil, stat, sys
from pathlib import Path

device = Path(os.environ["PHONEBACKUP_FAKE_DEVICE"])
args = sys.argv[1:]
if args and args[0] == "devices":
    print("List of devices attached")
    if os.environ.get("PHONEBACKUP_FAKE_MULTI") == "1":
        print("FAKE123\tdevice")
        print("SECOND456\tdevice")
    else:
        print("FAKE123\tdevice")
    sys.exit(0)
if "-s" in args:
    if args[args.index("-s") + 1] != "FAKE123":
        print("wrong device selected", file=sys.stderr); sys.exit(1)
    args = args[args.index("-s") + 2:]
if args and args[0] == "pull":
    src = device / args[1].lstrip("/")
    if not src.is_file():
        print("adb: failed to stat remote object", file=sys.stderr); sys.exit(1)
    shutil.copyfile(src, args[2])
    sys.exit(0)
if args and args[0] == "push":
    src = Path(args[1])
    dst = device / args[2].lstrip("/")
    if not src.is_file():
        print("local file missing", file=sys.stderr); sys.exit(1)
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(src, dst)
    sys.exit(0)
if not args or args[0] != "shell":
    sys.exit(2)
marker = "ADBSYNC END OF COMMAND"
last_status = 0
for line in sys.stdin:
    command = line.strip()
    if command.endswith("</dev/null"):
        command = command[:-len("</dev/null")].strip()
    words = shlex.split(command)
    if not words:
        continue
    if words[0] == "find":
        root = words[1]
        hostroot = device / root.lstrip("/")
        if not hostroot.exists():
            print("find: '%s': No such file or directory" % root)
            sys.stdout.flush()
            last_status = 1
            continue
        entries = [hostroot]
        if hostroot.is_dir() and "-maxdepth" not in words:
            entries += sorted(hostroot.rglob("*"))
        for item in entries:
            remote = "/" + item.relative_to(device).as_posix()
            mode = item.lstat()
            kind = "l" if item.is_symlink() else ("d" if item.is_dir() else "-")
            perms = stat.filemode(mode.st_mode)[1:]
            size = mode.st_size if item.is_file() else 4096
            record = "%s%s|%d|%d|%s\0" % (kind, perms, size, int(mode.st_mtime), remote)
            sys.stdout.buffer.write(record.encode())
        sys.stdout.buffer.flush()
        last_status = int(os.environ.get("PHONEBACKUP_FAKE_FIND_EXIT", "0"))
        denied = os.environ.get("PHONEBACKUP_FAKE_DENIED")
        if denied and root == "/sdcard" and "-maxdepth" not in words:
            sys.stdout.write("find: '/sdcard/%s': Permission denied\0" % denied)
            sys.stdout.flush()
            last_status = 1
        fatal = os.environ.get("PHONEBACKUP_FAKE_FIND_FATAL")
        if fatal and root == "/sdcard" and "-maxdepth" not in words:
            last_status = int(fatal)
    elif words[0] == "mkdir":
        target = device / words[-1].lstrip("/")
        target.mkdir(parents=True, exist_ok=True)
        last_status = 0
    elif words[0] == "mv":
        no_clobber = "-n" in words
        force = "-f" in words
        target_is_file = "-T" in words
        paths = [word for word in words[1:] if not word.startswith("-")]
        source, target = (device / path.lstrip("/") for path in paths[-2:])
        if target_is_file and target.is_dir():
            last_status = 1
        elif no_clobber and target.exists():
            last_status = 0
        elif target.exists() and not force:
            last_status = 1
        else:
            os.replace(source, target)
            last_status = 0
    elif words[0] == "ln":
        target_is_file = "-T" in words
        paths = [word for word in words[1:] if not word.startswith("-")]
        source, target = (device / path.lstrip("/") for path in paths[-2:])
        if target_is_file and os.path.lexists(target):
            last_status = 1
        else:
            os.link(source, target)
            last_status = 0
    elif words[0] == "rm":
        target = device / words[-1].lstrip("/")
        try:
            target.unlink()
        except FileNotFoundError:
            pass
        last_status = 0
    elif words[0] == "touch":
        last_status = 0
    elif words[0] == "echo":
        print(words[1].replace("$?", str(last_status)))
        sys.stdout.flush()
    elif words[0] == "realpath":
        target = (device / words[1].lstrip("/")).resolve()
        print("/" + target.relative_to(device).as_posix())
        sys.stdout.flush()
    elif words[0] == ":":
        last_status = 0
'''


@pytest.fixture
def fake_adb(tmp_path, monkeypatch):
    device = tmp_path / "device"
    (device / "sdcard").mkdir(parents=True)
    exe = tmp_path / "fake-adb"
    exe.write_text(FAKE_ADB)
    exe.chmod(0o755)
    monkeypatch.setenv("PHONEBACKUP_FAKE_DEVICE", str(device))
    return exe, device


def run_backup(exe, target, *args):
    return Backup(str(target), [str(exe), "-s", "FAKE123"], remote_root="/sdcard")


def test_new_update_incremental_and_remote_deletions_remain(fake_adb, tmp_path):
    exe, device = fake_adb
    phone = device / "sdcard"
    (phone / "hidden").mkdir()
    (phone / "empty").mkdir()
    os.utime(phone / "empty", (1_600_000_000, 1_600_000_000))
    (phone / "hidden" / "café name.txt").write_text("first")
    (phone / ".dotfile").write_text("hidden")
    (phone / "stable.txt").write_text("stay")
    (phone / "line\nbreak\\name.txt").write_text("odd name")
    destination = tmp_path / "backup"

    backup = run_backup(exe, destination)
    try:
        result = backup.run(create=True)
        assert result["transferred"] == 4
        assert (destination / "hidden" / "café name.txt").read_text() == "first"
        assert (destination / ".dotfile").read_text() == "hidden"
        assert (destination / "line\nbreak\\name.txt").read_text() == "odd name"
        assert (destination / "empty").is_dir()
        assert int((destination / "empty").stat().st_mtime) == 1_600_000_000
    finally:
        backup.close()

    old_mtime = int((destination / ".dotfile").stat().st_mtime)
    repeated_new = run_backup(exe, destination)
    try:
        with pytest.raises(BackupError, match="already contains a phonebackup"):
            repeated_new.run(create=True)
    finally:
        repeated_new.close()
    (phone / "hidden" / "café name.txt").write_text("changed size")
    (phone / "new.txt").write_text("new")
    (phone / ".dotfile").unlink()
    backup = run_backup(exe, destination)
    try:
        result = backup.run()
        assert result["transferred"] == 2
        assert result["skipped"] == 2
        assert (destination / "hidden" / "café name.txt").read_text() == "changed size"
        assert (destination / "new.txt").read_text() == "new"
        assert (destination / ".dotfile").exists()
        assert int((destination / ".dotfile").stat().st_mtime) == old_mtime
        assert backup.verify()["failed"] == 0
        assert status(str(destination))["file_count"] == 5
    finally:
        backup.close()


def test_saved_selection_controls_updates_and_scope_changes_preserve_old_files(fake_adb, tmp_path):
    exe, device = fake_adb
    phone = device / "sdcard"
    (phone / "DCIM").mkdir()
    (phone / "Documents").mkdir()
    (phone / "DCIM" / "photo.jpg").write_text("photo")
    (phone / "Documents" / "notes.txt").write_text("notes")
    destination = tmp_path / "backup"
    backup = run_backup(exe, destination)
    try:
        backup.run(create=True, include=["DCIM"])
        assert (destination / "DCIM" / "photo.jpg").exists()
        assert not (destination / "Documents" / "notes.txt").exists()
        assert backup.manifest.data["selection"] == {"include": ["DCIM"], "exclude": []}
    finally:
        backup.close()

    (phone / "DCIM" / "new.jpg").write_text("new")
    (phone / "Documents" / "new.txt").write_text("not yet")
    backup = run_backup(exe, destination)
    try:
        result = backup.run()
        assert result["transferred"] == 1
        assert (destination / "DCIM" / "new.jpg").exists()
        assert not (destination / "Documents" / "new.txt").exists()
        result = backup.run(include=["Documents"])
        assert result["transferred"] == 2
        assert (destination / "DCIM" / "photo.jpg").exists()
        assert (destination / "Documents" / "new.txt").exists()
        assert backup.manifest.data["selection"] == {"include": ["Documents"], "exclude": []}
    finally:
        backup.close()


def test_changed_files_keep_per_file_history_and_verify_history_blobs(fake_adb, tmp_path):
    exe, device = fake_adb
    source = device / "sdcard" / "photo.txt"
    source.write_text("version one")
    destination = tmp_path / "backup"
    backup = run_backup(exe, destination)
    try:
        backup.run(create=True)
        source.write_text("version two is longer")
        backup.run()
        history = backup.history("photo.txt")["versions"]
        assert len(history) == 1
        assert (destination / history[0]["path"]).read_text() == "version one"
        assert (destination / "photo.txt").read_text() == "version two is longer"
        source.write_text("version three is longest")
        backup.run()
        history = backup.history("photo.txt")["versions"]
        assert len(history) == 2
        assert [((destination / item["path"]).read_text()) for item in history] == [
            "version one", "version two is longer"
        ]
        assert backup.verify()["history_checked"] == 2
        history_path = destination / history[0]["path"]
        history_path.write_text("corrupt")
        assert backup.verify()["failed"] == 1
        with pytest.raises(BackupError, match="integrity verification"):
            backup.restore("photo.txt", version_id=history[0]["id"], to_local=str(tmp_path / "bad-export"))
        assert not (tmp_path / "bad-export").exists()
    finally:
        backup.close()


def test_history_prune_defaults_to_preview_and_apply_removes_selected_version(fake_adb, tmp_path, capsys):
    exe, device = fake_adb
    source = device / "sdcard" / "note.txt"
    source.write_text("version one")
    destination = tmp_path / "backup"
    backup = run_backup(exe, destination)
    try:
        backup.run(create=True)
        source.write_text("version two is longer")
        backup.run()
        version = backup.history("note.txt")["versions"][0]
        history_file = destination / version["path"]
        result = backup.prune_history([version["id"]])
        assert result["applied"] is False
        assert "WOULD PRUNE note.txt" in capsys.readouterr().out
        assert history_file.read_text() == "version one"
        assert len(backup.history("note.txt")["versions"]) == 1
        result = backup.prune_history([version["id"]], apply=True)
        assert result["applied"] is True
        assert not history_file.exists()
        assert backup.history("note.txt")["versions"] == []
        assert backup.verify()["history_checked"] == 0
    finally:
        backup.close()


def test_prune_history_retry_finishes_after_unlink_failure(fake_adb, tmp_path, monkeypatch, capsys):
    exe, device = fake_adb
    source = device / "sdcard" / "note.txt"
    source.write_text("before")
    destination = tmp_path / "backup"
    backup = run_backup(exe, destination)
    try:
        backup.run(create=True)
        source.write_text("after")
        backup.run()
        version = backup.history("note.txt")["versions"][0]
        stored = destination / version["path"]
        original_unlink = Path.unlink

        def fail_history_unlink(path, *args, **kwargs):
            if path == stored:
                raise OSError("simulated unlink failure")
            return original_unlink(path, *args, **kwargs)

        monkeypatch.setattr(Path, "unlink", fail_history_unlink)
        with pytest.raises(OSError, match="simulated unlink failure"):
            backup.prune_history([version["id"]], apply=True)
        assert stored.exists()
        assert backup.history("note.txt")["versions"] == []
        assert backup.manifest.data["pending_prune"]["version_ids"] == [version["id"]]
        summary = status(str(destination))
        status_output = capsys.readouterr().out
        assert summary["pending_prune_ids"] == [version["id"]]
        assert "phonebackup prune-history" in status_output
        assert "--apply" in status_output
        with pytest.raises(BackupError, match="repeat the same version IDs"):
            backup.prune_history(["unknown-version"], apply=True)
        assert stored.exists()

        monkeypatch.setattr(Path, "unlink", original_unlink)
        result = backup.prune_history([version["id"]], apply=True)
        assert result["applied"] is True
        assert result["files"] == 1
        assert not stored.exists()
        assert backup.manifest.data["pending_prune"] is None
    finally:
        backup.close()


def test_prune_retry_keeps_blob_that_new_history_references(fake_adb, tmp_path, monkeypatch):
    exe, device = fake_adb
    source = device / "sdcard" / "note.txt"
    source.write_text("before")
    destination = tmp_path / "backup"
    backup = run_backup(exe, destination)
    try:
        backup.run(create=True)
        source.write_text("after")
        backup.run()
        selected = backup.history("note.txt")["versions"][0]
        shared_blob = destination / selected["path"]
        original_unlink = Path.unlink

        def fail_history_unlink(path, *args, **kwargs):
            if path == shared_blob:
                raise OSError("simulated unlink failure")
            return original_unlink(path, *args, **kwargs)

        monkeypatch.setattr(Path, "unlink", fail_history_unlink)
        with pytest.raises(OSError, match="simulated unlink failure"):
            backup.prune_history([selected["id"]], apply=True)
        monkeypatch.setattr(Path, "unlink", original_unlink)

        (destination / "note.txt").write_text("before")
        source.write_text("third version")
        backup.run()
        newly_retained = [version for version in backup.history("note.txt")["versions"]
                          if version["path"] == selected["path"]]
        assert len(newly_retained) == 1

        backup.prune_history([selected["id"]], apply=True)
        assert shared_blob.read_text() == "before"
        assert newly_retained[0] in backup.history("note.txt")["versions"]
        assert backup.verify()["failed"] == 0
    finally:
        backup.close()


def test_prune_history_preview_does_not_count_missing_blob(fake_adb, tmp_path):
    exe, device = fake_adb
    source = device / "sdcard" / "note.txt"
    source.write_text("before")
    destination = tmp_path / "backup"
    backup = run_backup(exe, destination)
    try:
        backup.run(create=True)
        source.write_text("after")
        backup.run()
        version = backup.history("note.txt")["versions"][0]
        (destination / version["path"]).unlink()
        result = backup.prune_history([version["id"]])
        assert result == {"versions": 1, "files": 0, "bytes": 0, "applied": False}
        result = backup.prune_history([version["id"]], apply=True)
        assert result == {"versions": 1, "files": 0, "bytes": 0, "applied": True}
    finally:
        backup.close()


def test_prune_shared_history_blob_keeps_remaining_reference(fake_adb, tmp_path):
    exe, device = fake_adb
    source = device / "sdcard" / "note.txt"
    source.write_text("version one")
    destination = tmp_path / "backup"
    backup = run_backup(exe, destination)
    try:
        backup.run(create=True)
        source.write_text("version two is longer")
        backup.run()
        first = backup.history("note.txt")["versions"][0]
        current = destination / "note.txt"
        current.write_text("version one")
        source.write_text("version three is much longer")
        backup.run()
        versions = backup.history("note.txt")["versions"]
        repeated = [version for version in versions if version["path"] == first["path"]]
        assert len(repeated) == 2
        shared_file = destination / first["path"]
        backup.prune_history([repeated[0]["id"]], apply=True)
        assert shared_file.read_text() == "version one"
        assert any(version["path"] == first["path"] for version in backup.history("note.txt")["versions"])
        remaining_id = next(version["id"] for version in backup.history("note.txt")["versions"]
                            if version["path"] == first["path"])
        backup.prune_history([remaining_id], apply=True)
        assert not shared_file.exists()
    finally:
        backup.close()


def test_prune_history_cli_previews_unless_apply_is_given(fake_adb, tmp_path, monkeypatch, capsys):
    exe, device = fake_adb
    source = device / "sdcard" / "note.txt"
    source.write_text("before")
    destination = tmp_path / "backup"
    backup = run_backup(exe, destination)
    try:
        backup.run(create=True)
        source.write_text("after")
        backup.run()
        version = backup.history("note.txt")["versions"][0]
        stored = destination / version["path"]
    finally:
        backup.close()

    monkeypatch.setattr("sys.argv", [
        "phonebackup", "prune-history", str(destination), "--version", version["id"]
    ])
    assert backup_main() == 0
    assert "WOULD PRUNE" in capsys.readouterr().out
    assert stored.exists()

    monkeypatch.setattr("sys.argv", [
        "phonebackup", "prune-history", str(destination), "--version", version["id"], "--apply"
    ])
    assert backup_main() == 0
    assert "PRUNE note.txt" in capsys.readouterr().out
    assert not stored.exists()


def test_tracked_target_recreated_during_pull_is_archived_before_replacement(fake_adb, tmp_path, monkeypatch):
    exe, device = fake_adb
    source = device / "sdcard" / "note.txt"
    source.write_text("initial")
    destination = tmp_path / "backup"
    backup = run_backup(exe, destination)
    try:
        backup.run(create=True)
        (destination / "note.txt").unlink()
        source.write_text("incoming update")
        original_run = __import__("subprocess").run
        def recreate_destination(command, **kwargs):
            if "pull" in command:
                (destination / "note.txt").write_text("concurrent local bytes")
            return original_run(command, **kwargs)
        monkeypatch.setattr("BestestADBSync.Backup.subprocess.run", recreate_destination)
        backup.run()
        versions = backup.history("note.txt")["versions"]
        assert len(versions) == 1
        assert (destination / versions[0]["path"]).read_text() == "concurrent local bytes"
        assert (destination / "note.txt").read_text() == "incoming update"
    finally:
        backup.close()


def test_history_capture_failure_preserves_current_backup_file(fake_adb, tmp_path, monkeypatch):
    import BestestADBSync.Backup as backup_module
    exe, device = fake_adb
    source = device / "sdcard" / "note.txt"
    source.write_text("original bytes")
    destination = tmp_path / "backup"
    backup = run_backup(exe, destination)
    try:
        backup.run(create=True)
        source.write_text("replacement bytes")
        original_copy = backup_module.shutil.copyfile
        def fail_history_copy(src, dst):
            if Path(dst).name.startswith(".phonebackup-history-"):
                raise OSError("simulated history storage failure")
            return original_copy(src, dst)
        monkeypatch.setattr(backup_module.shutil, "copyfile", fail_history_copy)
        with pytest.raises(OSError, match="history storage failure"):
            backup.run()
        assert (destination / "note.txt").read_text() == "original bytes"
        assert backup.manifest.data["incomplete"] is True
    finally:
        backup.close()


def test_restore_exports_current_or_historical_version_with_overwrite_guard(fake_adb, tmp_path):
    exe, device = fake_adb
    source = device / "sdcard" / "document.txt"
    source.write_text("older")
    destination = tmp_path / "backup"
    backup = run_backup(exe, destination)
    try:
        backup.run(create=True)
        old_mtime = source.stat().st_mtime
        source.write_text("newer")
        os.utime(source, (old_mtime + 60, old_mtime + 60))
        backup.run()
        version = backup.history("document.txt")["versions"][0]["id"]
        exported = tmp_path / "exported.txt"
        backup.restore("document.txt", to_local=str(exported), version_id=version)
        assert exported.read_text() == "older"
        with pytest.raises(BackupError, match="inside the backup"):
            backup.restore("document.txt", to_local=str(destination / ".phonebackup-manifest.json"), overwrite=True)
        with pytest.raises(BackupError, match="already exists"):
            backup.restore("document.txt", to_local=str(exported))
        backup.restore("document.txt", to_local=str(exported), overwrite=True)
        assert exported.read_text() == "newer"
    finally:
        backup.close()


def test_restore_warns_when_manifest_has_no_stored_hash(fake_adb, tmp_path, capsys):
    exe, device = fake_adb
    (device / "sdcard" / "legacy.txt").write_text("legacy")
    backup = run_backup(exe, tmp_path / "backup")
    try:
        backup.run(create=True)
        backup.manifest.data["files"]["legacy.txt"]["sha256"] = None
        backup.manifest.save()
        exported = tmp_path / "legacy-export.txt"
        backup.restore("legacy.txt", to_local=str(exported))
        assert exported.read_text() == "legacy"
        assert "no stored SHA-256" in capsys.readouterr().out
    finally:
        backup.close()


def test_no_overwrite_export_fails_atomically_without_hardlink_support(fake_adb, tmp_path, monkeypatch):
    import BestestADBSync.Backup as backup_module
    exe, device = fake_adb
    (device / "sdcard" / "note.txt").write_text("saved")
    backup = run_backup(exe, tmp_path / "backup")
    try:
        backup.run(create=True)
        target = tmp_path / "export.txt"
        def unsupported_link(_source, _target):
            raise OSError(errno.EPERM, "hard links unsupported")
        monkeypatch.setattr(backup_module.os, "link", unsupported_link)
        with pytest.raises(BackupError, match="atomic no-overwrite export"):
            backup.restore("note.txt", to_local=str(target))
        assert not target.exists()
        assert not list(tmp_path.glob(".phonebackup-restore-*.partial"))
    finally:
        backup.close()


def test_local_overwrite_does_not_replace_symlink_created_during_staging(fake_adb, tmp_path, monkeypatch):
    import BestestADBSync.Backup as backup_module
    exe, device = fake_adb
    (device / "sdcard" / "note.txt").write_text("saved")
    destination = tmp_path / "backup"
    backup = run_backup(exe, destination)
    try:
        backup.run(create=True)
        outside = tmp_path / "outside.txt"
        outside.write_text("keep")
        target = tmp_path / "export.txt"
        original_copy = backup_module.shutil.copyfile
        def create_symlink_during_copy(source, output):
            result = original_copy(source, output)
            target.symlink_to(outside)
            return result
        monkeypatch.setattr(backup_module.shutil, "copyfile", create_symlink_during_copy)
        with pytest.raises(BackupError, match="symlink"):
            backup.restore("note.txt", to_local=str(target), overwrite=True)
        assert target.is_symlink()
        assert outside.read_text() == "keep"
    finally:
        backup.close()


def test_restore_to_phone_requires_overwrite_and_publishes_via_temp(fake_adb, tmp_path):
    exe, device = fake_adb
    source = device / "sdcard" / "Documents" / "note.txt"
    source.parent.mkdir()
    source.write_text("saved copy")
    destination = tmp_path / "backup"
    backup = run_backup(exe, destination)
    try:
        backup.run(create=True)
        source.write_text("phone current")
        with pytest.raises(BackupError, match="pass --overwrite"):
            backup.restore("Documents/note.txt", to_phone=True)
        backup.restore("Documents/note.txt", to_phone=True, overwrite=True)
        assert source.read_text() == "saved copy"
        assert not list(source.parent.glob(".phonebackup-restore-*.partial"))
        source.unlink()
        backup.restore("Documents/note.txt", to_phone=True)
        assert source.read_text() == "saved copy"
    finally:
        backup.close()


def test_failed_phone_restore_cleans_remote_partial_file(fake_adb, tmp_path, monkeypatch):
    exe, device = fake_adb
    source = device / "sdcard" / "note.txt"
    source.write_text("saved copy")
    backup = run_backup(exe, tmp_path / "backup")
    try:
        backup.run(create=True)
        original_run = __import__("subprocess").run
        def failed_push(command, **kwargs):
            if "push" in command:
                partial = device / command[-1].lstrip("/")
                partial.write_bytes(b"partial")
                return type("Result", (), {"returncode": 1, "stderr": b"connection lost"})()
            return original_run(command, **kwargs)
        monkeypatch.setattr("BestestADBSync.Backup.subprocess.run", failed_push)
        with pytest.raises(BackupError, match="Phone restore transfer failed"):
            backup.restore("note.txt", to_phone=True, overwrite=True)
        assert not list((device / "sdcard").glob(".phonebackup-restore-*.partial"))
        assert source.read_text() == "saved copy"
    finally:
        backup.close()


def test_phone_restore_race_with_directory_cannot_move_temp_inside_it(fake_adb, tmp_path, monkeypatch):
    exe, device = fake_adb
    source = device / "sdcard" / "note.txt"
    source.write_text("saved copy")
    backup = run_backup(exe, tmp_path / "backup")
    try:
        backup.run(create=True)
        source.unlink()
        original_run = __import__("subprocess").run
        def create_directory_during_push(command, **kwargs):
            result = original_run(command, **kwargs)
            if "push" in command:
                (device / "sdcard" / "note.txt").mkdir()
            return result
        monkeypatch.setattr("BestestADBSync.Backup.subprocess.run", create_directory_during_push)
        with pytest.raises(BackupError, match="non-file or symlink"):
            backup.restore("note.txt", to_phone=True)
        target = device / "sdcard" / "note.txt"
        assert target.is_dir()
        assert not list((device / "sdcard").glob(".phonebackup-restore-*.partial"))
        assert not list(target.glob(".phonebackup-restore-*.partial"))
    finally:
        backup.close()


def test_phone_overwrite_does_not_replace_symlink_created_during_push(fake_adb, tmp_path, monkeypatch):
    exe, device = fake_adb
    source = device / "sdcard" / "note.txt"
    source.write_text("saved copy")
    backup = run_backup(exe, tmp_path / "backup")
    try:
        backup.run(create=True)
        source.unlink()
        outside = tmp_path / "outside.txt"
        outside.write_text("keep")
        original_run = __import__("subprocess").run
        def create_symlink_after_push(command, **kwargs):
            result = original_run(command, **kwargs)
            if "push" in command:
                source.symlink_to(outside)
            return result
        monkeypatch.setattr("BestestADBSync.Backup.subprocess.run", create_symlink_after_push)
        with pytest.raises(BackupError, match="symlink"):
            backup.restore("note.txt", to_phone=True, overwrite=True)
        assert source.is_symlink()
        assert outside.read_text() == "keep"
        assert not list(source.parent.glob(".phonebackup-restore-*.partial"))
    finally:
        backup.close()


def test_phone_no_overwrite_publication_is_exclusive_against_racing_file(fake_adb, tmp_path, monkeypatch):
    import BestestADBSync.Backup as backup_module
    exe, device = fake_adb
    source = device / "sdcard" / "note.txt"
    source.write_text("saved copy")
    backup = run_backup(exe, tmp_path / "backup")
    try:
        backup.run(create=True)
        source.unlink()
        original_command = backup_module._run_android_command
        def create_file_at_publish(android, command):
            if command[0] == "ln":
                source.write_text("concurrent phone file")
            return original_command(android, command)
        monkeypatch.setattr(backup_module, "_run_android_command", create_file_at_publish)
        with pytest.raises(BrokenPipeError):
            backup.restore("note.txt", to_phone=True)
        assert source.read_text() == "concurrent phone file"
        assert not list(source.parent.glob(".phonebackup-restore-*.partial"))
    finally:
        backup.close()


def test_paths_cli_outputs_json_without_backup_destination(fake_adb, monkeypatch, capsys, tmp_path):
    exe, device = fake_adb
    (device / "sdcard" / "Documents").mkdir()
    (device / "sdcard" / "Documents" / "note.txt").write_text("note")
    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr("sys.argv", [
        "phonebackup", "paths", "--adb-bin", str(exe), "--device", "FAKE123", "--format", "json"
    ])
    assert backup_main() == 0
    result = json.loads(capsys.readouterr().out)
    assert result["remote_root"] == "/sdcard"
    assert {entry["path"] for entry in result["entries"]} == {"Documents", "Documents/note.txt"}
    assert not (tmp_path / ".phonebackup-manifest.json").exists()


def test_diff_selection_override_reports_preserved_without_mutating_backup(fake_adb, tmp_path, capsys):
    exe, device = fake_adb
    phone = device / "sdcard"
    (phone / "DCIM").mkdir()
    (phone / "Documents").mkdir()
    (phone / "DCIM" / "photo.jpg").write_text("photo")
    (phone / "Documents" / "notes.txt").write_text("notes")
    destination = tmp_path / "backup"
    backup = run_backup(exe, destination)
    try:
        backup.run(create=True)
        (phone / "DCIM" / "photo.jpg").write_text("changed photo")
        before = backup.manifest.data["selection"].copy()
        result = backup.diff(include=["Documents"])
        output = capsys.readouterr().out
        assert result["preserved"] == 1
        assert "UPDATE DCIM/photo.jpg" not in output
        assert "PRESERVED (outside current selection) DCIM/photo.jpg" in output
        assert backup.manifest.data["selection"] == before
        assert (destination / "DCIM" / "photo.jpg").read_text() == "photo"
    finally:
        backup.close()


def test_diff_refuses_unowned_pending_destination_like_update_dry_run(fake_adb, tmp_path):
    import hashlib

    exe, device = fake_adb
    source = device / "sdcard" / "pending.txt"
    destination = tmp_path / "backup"
    backup = run_backup(exe, destination)
    try:
        backup.run(create=True)
        source.write_text("phone data")
        target = destination / "pending.txt"
        target.write_text("unrelated local data")
        backup.manifest.begin_file("pending.txt", size=len("phone data"), mtime=source.stat().st_mtime)
        backup.manifest.set_pending_digest("pending.txt", hashlib.sha256(b"phone data").hexdigest())
        before = backup.manifest.data.copy()
        with pytest.raises(BackupError, match="untracked or incomplete destination"):
            backup.diff()
        with pytest.raises(BackupError, match="untracked or incomplete destination"):
            backup.run(dry_run=True)
        assert backup.manifest.data == before
        assert target.read_text() == "unrelated local data"
    finally:
        backup.close()


def test_all_resets_saved_selection_and_dry_run_does_not_save_override(fake_adb, tmp_path):
    exe, device = fake_adb
    phone = device / "sdcard"
    (phone / "DCIM").mkdir()
    (phone / "DCIM" / "Thumbnails").mkdir()
    (phone / "DCIM" / "photo.jpg").write_text("photo")
    (phone / "DCIM" / "Thumbnails" / "thumb.jpg").write_text("thumb")
    destination = tmp_path / "backup"
    backup = run_backup(exe, destination)
    try:
        backup.run(create=True, include=["DCIM"], exclude=["DCIM/Thumbnails/**"])
        assert (destination / "DCIM" / "photo.jpg").exists()
        assert not (destination / "DCIM" / "Thumbnails" / "thumb.jpg").exists()
        previous = {key: list(value) for key, value in backup.manifest.data["selection"].items()}
        backup.run(dry_run=True, include=["DCIM/Thumbnails"])
        assert backup.manifest.data["selection"] == previous
        backup.run(all_files=True)
        assert backup.manifest.data["selection"] == {"include": [], "exclude": []}
        assert (destination / "DCIM" / "Thumbnails" / "thumb.jpg").exists()
    finally:
        backup.close()


def test_include_path_cannot_traverse_symlink_ancestor(fake_adb, tmp_path):
    exe, device = fake_adb
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "secret.txt").write_text("secret")
    (device / "sdcard" / "link").symlink_to(outside, target_is_directory=True)
    backup = run_backup(exe, tmp_path / "backup")
    try:
        with pytest.raises(BackupError, match="traverses a symlink"):
            backup.run(create=True, include=["link/secret.txt"])
        assert not (tmp_path / "backup" / "link" / "secret.txt").exists()
    finally:
        backup.close()


def test_excluded_symlink_and_fully_excluded_include_are_ignored(fake_adb, tmp_path):
    exe, device = fake_adb
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "secret.txt").write_text("secret")
    (device / "sdcard" / "link").symlink_to(outside, target_is_directory=True)
    destination = tmp_path / "backup"
    backup = run_backup(exe, destination)
    try:
        backup.run(create=True, exclude=["link"])
        assert not (destination / "link").exists()
    finally:
        backup.close()


def test_excluded_permission_denied_find_diagnostic_does_not_fail(fake_adb, tmp_path, monkeypatch):
    exe, device = fake_adb
    (device / "sdcard" / "blocked").mkdir()
    (device / "sdcard" / "blocked" / "secret.txt").write_text("secret")
    monkeypatch.setenv("PHONEBACKUP_FAKE_DENIED", "blocked")
    backup = run_backup(exe, tmp_path / "backup")
    try:
        result = backup.run(create=True, exclude=["blocked"])
        assert result["transferred"] == 0
        assert backup.manifest.data["incomplete"] is False
    finally:
        backup.close()


def test_excluded_permission_error_does_not_hide_fatal_find_status(fake_adb, tmp_path, monkeypatch):
    exe, device = fake_adb
    (device / "sdcard" / "blocked").mkdir()
    monkeypatch.setenv("PHONEBACKUP_FAKE_DENIED", "blocked")
    monkeypatch.setenv("PHONEBACKUP_FAKE_FIND_FATAL", "7")
    backup = run_backup(exe, tmp_path / "backup")
    try:
        with pytest.raises(BackupError, match="unexpected status 7"):
            backup.run(create=True, exclude=["blocked"])
        assert backup.manifest.data["incomplete"] is True
    finally:
        backup.close()
    empty_destination = tmp_path / "empty-backup"
    backup = run_backup(exe, empty_destination)
    try:
        result = backup.run(create=True, include=["link"], exclude=["link"])
        assert result["transferred"] == 0
    finally:
        backup.close()


def test_missing_included_root_is_preserved_and_diff_explains_it(fake_adb, tmp_path, capsys):
    exe, device = fake_adb
    folder = device / "sdcard" / "Documents"
    folder.mkdir()
    (folder / "notes.txt").write_text("notes")
    destination = tmp_path / "backup"
    backup = run_backup(exe, destination)
    try:
        backup.run(create=True, include=["Documents"])
        (folder / "notes.txt").unlink()
        folder.rmdir()
        backup.run()
        assert (destination / "Documents" / "notes.txt").read_text() == "notes"
        backup.diff()
        assert "PRESERVED (not found on phone) Documents/notes.txt" in capsys.readouterr().out
    finally:
        backup.close()


def test_new_missing_include_is_reported_instead_of_succeeding_empty(fake_adb, tmp_path):
    exe, _ = fake_adb
    backup = run_backup(exe, tmp_path / "backup")
    try:
        with pytest.raises(BackupError, match="does not exist"):
            backup.run(create=True, include=["typoed-folder"])
        assert backup.manifest.data["incomplete"] is True
        with pytest.raises(BackupError, match="does not exist"):
            backup.run()
        assert backup.manifest.data["incomplete"] is True
    finally:
        backup.close()


def test_missing_ancestor_of_nested_include_preserves_prior_backup(fake_adb, tmp_path, capsys):
    exe, device = fake_adb
    source = device / "sdcard" / "Documents" / "sub" / "file.txt"
    source.parent.mkdir(parents=True)
    source.write_text("kept")
    destination = tmp_path / "backup"
    backup = run_backup(exe, destination)
    try:
        backup.run(create=True, include=["Documents/sub/file.txt"])
        import shutil
        shutil.rmtree(device / "sdcard" / "Documents")
        backup.run()
        assert (destination / "Documents" / "sub" / "file.txt").read_text() == "kept"
        backup.diff()
        assert "PRESERVED (not found on phone) Documents/sub/file.txt" in capsys.readouterr().out
    finally:
        backup.close()


def test_diff_reports_manifest_entries_missing_from_backup(fake_adb, tmp_path, capsys):
    exe, device = fake_adb
    source = device / "sdcard" / "deleted.txt"
    source.write_text("content")
    destination = tmp_path / "backup"
    backup = run_backup(exe, destination)
    try:
        backup.run(create=True)
        (destination / "deleted.txt").unlink()
        source.unlink()
        result = backup.diff()
        assert result["missing_backup"] == 1
        assert "MISSING BACKUP deleted.txt" in capsys.readouterr().out
    finally:
        backup.close()


def test_selection_and_attempt_start_are_committed_together(fake_adb, tmp_path, monkeypatch):
    exe, device = fake_adb
    (device / "sdcard" / "first.txt").write_text("first")
    destination = tmp_path / "backup"
    backup = run_backup(exe, destination)
    try:
        backup.run(create=True, include=["first.txt"])
    finally:
        backup.close()
    backup = run_backup(exe, destination)
    def interrupted_before_attempt():
        raise RuntimeError("simulated interruption")
    monkeypatch.setattr(backup.manifest, "begin_attempt", interrupted_before_attempt)
    try:
        with pytest.raises(RuntimeError, match="simulated interruption"):
            backup.run(include=["other.txt"])
    finally:
        backup.close()
    persisted = Backup(str(destination), [str(exe), "-s", "FAKE123"])
    try:
        persisted.manifest.load()
        assert persisted.manifest.data["selection"] == {"include": ["first.txt"], "exclude": []}
        assert persisted.manifest.data["incomplete"] is False
    finally:
        persisted.close()


def test_nested_single_file_include_uses_durable_directory_creation(fake_adb, tmp_path, monkeypatch):
    import BestestADBSync.Backup as backup_module
    exe, device = fake_adb
    source = device / "sdcard" / "Documents" / "a" / "b" / "note.txt"
    source.parent.mkdir(parents=True)
    source.write_text("note")
    destination = tmp_path / "backup"
    calls = []
    ensure = backup_module._ensure_directory
    def tracked_ensure(root, relpath):
        calls.append(relpath)
        return ensure(root, relpath)
    monkeypatch.setattr(backup_module, "_ensure_directory", tracked_ensure)
    backup = run_backup(exe, destination)
    try:
        backup.run(create=True, include=["Documents/a/b/note.txt"])
        assert (destination / "Documents" / "a" / "b" / "note.txt").read_text() == "note"
        assert "Documents/a/b" in calls
    finally:
        backup.close()


def test_failed_transfer_preserves_previous_file_and_marks_incomplete(fake_adb, tmp_path, monkeypatch):
    exe, device = fake_adb
    source = device / "sdcard" / "same.txt"
    source.write_text("old")
    destination = tmp_path / "backup"
    backup = run_backup(exe, destination)
    try:
        backup.run(create=True)
    finally:
        backup.close()
    source.write_text("new longer content")
    backup = run_backup(exe, destination)
    original_run = __import__("subprocess").run
    def interrupted(command, **kwargs):
        if "pull" in command:
            Path(command[-1]).write_bytes(b"cut")
            return type("Result", (), {"returncode": 1, "stderr": b"connection lost"})()
        return original_run(command, **kwargs)
    monkeypatch.setattr("BestestADBSync.Backup.subprocess.run", interrupted)
    try:
        with pytest.raises(BackupError, match="Transfer failed"):
            backup.run()
        assert (destination / "same.txt").read_text() == "old"
        assert not list(destination.glob("*.partial"))
        assert backup.manifest.data["incomplete"] is True
        assert backup.manifest.data["last_error"]
        assert "same.txt" in backup.manifest.data["pending"]
        assert backup.manifest.data.get("history", {}).get("same.txt", []) == []
    finally:
        backup.close()


def test_recovery_keeps_prior_target_ownership_when_phone_changes(fake_adb, tmp_path, monkeypatch):
    import hashlib

    exe, device = fake_adb
    source = device / "sdcard" / "new.txt"
    destination = tmp_path / "backup"
    backup = run_backup(exe, destination)
    try:
        backup.run(create=True)
        old_bytes = b"old phone bytes"
        source.write_bytes(old_bytes)
        target = destination / "new.txt"
        target.write_bytes(old_bytes)
        backup.manifest.begin_attempt()
        backup.manifest.begin_file("new.txt", len(old_bytes), source.stat().st_mtime)
        backup.manifest.set_pending_digest("new.txt", hashlib.sha256(old_bytes).hexdigest())
        backup.manifest.checkpoint()

        source.write_text("new phone content")
        original_record_file = backup.manifest.record_file

        def fail_after_publish(*args, **kwargs):
            raise BackupError("simulated interruption after publication")

        monkeypatch.setattr(backup.manifest, "record_file", fail_after_publish)
        with pytest.raises(BackupError, match="after publication"):
            backup.run()
        assert target.read_text() == "new phone content"
        pending = backup.manifest.data["pending"]["new.txt"]
        assert pending["target_sha256"] == hashlib.sha256(old_bytes).hexdigest()
        assert pending["sha256"] == hashlib.sha256(b"new phone content").hexdigest()

        monkeypatch.setattr(backup.manifest, "record_file", original_record_file)
        source.write_text("third phone version")
        backup.run()
        assert target.read_text() == "third phone version"
        assert "new.txt" not in backup.manifest.data["pending"]
        assert backup.verify()["failed"] == 0
    finally:
        backup.close()

def test_new_refuses_nonempty_unmanaged_destination(fake_adb, tmp_path):
    exe, _ = fake_adb
    destination = tmp_path / "existing"
    destination.mkdir()
    (destination / "keep.txt").write_text("do not replace")
    backup = run_backup(exe, destination)
    try:
        with pytest.raises(BackupError, match="refusing to use a non-empty"):
            backup.run(create=True)
        assert (destination / "keep.txt").read_text() == "do not replace"
    finally:
        backup.close()


def test_manifest_and_backup_file_are_not_confused(fake_adb, tmp_path):
    exe, device = fake_adb
    (device / "sdcard" / MANIFEST_FILENAME).write_text("phone data")
    backup = run_backup(exe, tmp_path / "backup")
    try:
        with pytest.raises(BackupError, match="reserved backup metadata"):
            backup.run(create=True)
    finally:
        backup.close()


def test_verify_is_local_and_does_not_start_adb(fake_adb, tmp_path):
    exe, device = fake_adb
    (device / "sdcard" / "local.txt").write_text("content")
    destination = tmp_path / "backup"
    backup = run_backup(exe, destination)
    try:
        backup.run(create=True)
    finally:
        backup.close()
    local_only = Backup(str(destination), [str(tmp_path / "missing-adb")])
    try:
        assert local_only.verify()["failed"] == 0
        assert local_only.android is None
    finally:
        local_only.close()


def test_update_refuses_to_overwrite_untracked_destination_file(fake_adb, tmp_path):
    exe, device = fake_adb
    destination = tmp_path / "backup"
    initial = run_backup(exe, destination)
    try:
        initial.run(create=True)
    finally:
        initial.close()
    (device / "sdcard" / "user-file.txt").write_text("phone")
    (destination / "user-file.txt").write_text("keep user data")
    backup = run_backup(exe, destination)
    try:
        with pytest.raises(BackupError, match="untracked or incomplete destination file"):
            backup.run()
        assert (destination / "user-file.txt").read_text() == "keep user data"
        assert backup.manifest.data["incomplete"] is True
        assert "untracked" in backup.manifest.data["last_error"]
    finally:
        backup.close()


def test_case_insensitive_host_collision_is_rejected_on_macos_like_filesystems():
    with pytest.raises(BackupError, match="collide"):
        _validate_host_path_collisions(["DCIM/Photo.jpg", "dcim/other.jpg"], case_insensitive=True)


def test_manifest_file_aliases_are_indexed_before_replacement(tmp_path):
    root = tmp_path / "backup"
    root.mkdir()
    (root / "A.txt").write_text("first")
    os.link(root / "A.txt", root / "a.txt")
    with pytest.raises(BackupError, match="alias on this filesystem"):
        _build_identity_index(root, ["A.txt", "a.txt"])


def test_new_target_created_during_pull_is_not_overwritten(fake_adb, tmp_path, monkeypatch):
    exe, device = fake_adb
    (device / "sdcard" / "new.txt").write_text("phone content")
    destination = tmp_path / "backup"
    backup = Backup(str(destination), [str(exe), "-s", "FAKE123"])
    original_run = __import__("subprocess").run

    def create_racing_file(command, **kwargs):
        if "pull" in command:
            (destination / "new.txt").write_text("unrelated local content")
        return original_run(command, **kwargs)

    monkeypatch.setattr("BestestADBSync.Backup.subprocess.run", create_racing_file)
    try:
        with pytest.raises(BackupError, match="created during transfer"):
            backup.run(create=True)
        assert (destination / "new.txt").read_text() == "unrelated local content"
        assert backup.manifest.data["incomplete"] is True
        with pytest.raises(BackupError, match="untracked or incomplete destination file"):
            backup.run()
        assert (destination / "new.txt").read_text() == "unrelated local content"
    finally:
        backup.close()


def test_no_hardlink_fallback_preserves_mtime(tmp_path, monkeypatch):
    temp = tmp_path / "source.partial"
    target = tmp_path / "target"
    temp.write_bytes(b"contents")
    os.utime(temp, (1_600_000_000, 1_600_000_000))
    digest = hashlib.sha256(b"contents").hexdigest()
    monkeypatch.setattr("BestestADBSync.Backup.os.link",
                        lambda *_args, **_kwargs: (_ for _ in ()).throw(OSError(errno.EPERM, "not supported")))
    _publish_new_file(temp, target, digest)
    assert target.read_bytes() == b"contents"
    assert int(target.stat().st_mtime) == 1_600_000_000


def test_incomplete_fallback_target_is_not_adopted_without_full_hash(tmp_path):
    temp = tmp_path / ".phonebackup-abc.partial"
    target = tmp_path / "target"
    temp.write_bytes(b"complete publication")
    target.write_bytes(b"complete")
    pending = {"sha256": hashlib.sha256(temp.read_bytes()).hexdigest(), "temp_path": temp.name}
    assert _pending_target_hash(pending, target) is None

    target.write_bytes(temp.read_bytes())
    assert _pending_target_hash(pending, target) == pending["sha256"]

    target.write_bytes(b"unrelated")
    assert _pending_target_hash(pending, target) is None


def test_default_sdcard_root_symlink_is_resolved(fake_adb, tmp_path):
    exe, device = fake_adb
    storage = device / "storage" / "emulated" / "0"
    storage.mkdir(parents=True)
    (storage / "photo.jpg").write_text("photo")
    (device / "sdcard").rmdir()
    (device / "sdcard").symlink_to(storage)
    backup = Backup(str(tmp_path / "backup"), [str(exe)], remote_root="/sdcard")
    try:
        result = backup.run(create=True)
        assert result["transferred"] == 1
        assert backup.source_root == "/storage/emulated/0"
        assert (tmp_path / "backup" / "photo.jpg").read_text() == "photo"
    finally:
        backup.close()


def test_backup_lock_rejects_a_concurrent_writer(tmp_path):
    root = tmp_path / "backup"
    root.mkdir()
    with _backup_lock(root):
        with pytest.raises(BackupError, match="Another phonebackup operation"):
            with _backup_lock(root):
                pass


def test_nonzero_find_exit_is_an_incomplete_scan(fake_adb, tmp_path, monkeypatch):
    exe, _ = fake_adb
    monkeypatch.setenv("PHONEBACKUP_FAKE_FIND_EXIT", "7")
    backup = run_backup(exe, tmp_path / "backup")
    try:
        with pytest.raises(BrokenPipeError, match="status 7"):
            backup.run(create=True)
        assert backup.manifest.data["incomplete"] is True
    finally:
        backup.close()


def test_diff_reports_timestamp_changes_without_mutating_backup(fake_adb, tmp_path, capsys):
    exe, device = fake_adb
    source = device / "sdcard" / "same-size.txt"
    source.write_text("alpha")
    destination = tmp_path / "backup"
    backup = run_backup(exe, destination)
    try:
        backup.run(create=True)
    finally:
        backup.close()

    old_time = source.stat().st_mtime
    source.write_text("bravo")
    os.utime(source, (old_time + 60, old_time + 60))
    backup = run_backup(exe, destination)
    try:
        result = backup.diff()
        assert result["changed"] == 1
        assert "UPDATE same-size.txt" in capsys.readouterr().out
        assert (destination / "same-size.txt").read_text() == "alpha"
    finally:
        backup.close()


def test_symlink_makes_scan_incomplete_instead_of_silent_success(fake_adb, tmp_path):
    exe, device = fake_adb
    phone = device / "sdcard"
    (phone / "actual.txt").write_text("data")
    (phone / "link.txt").symlink_to(phone / "actual.txt")
    backup = run_backup(exe, tmp_path / "backup")
    try:
        with pytest.raises(BackupError, match="Incomplete Android scan.*symlink"):
            backup.run(create=True)
        assert backup.manifest.data["incomplete"] is True
    finally:
        backup.close()


def test_multiple_devices_without_selection_is_a_failure(fake_adb, tmp_path, monkeypatch):
    exe, _ = fake_adb
    monkeypatch.setenv("PHONEBACKUP_FAKE_MULTI", "1")
    backup = Backup(str(tmp_path / "backup"), [str(exe)], remote_root="/sdcard")
    try:
        with pytest.raises(BackupError, match="Multiple ADB devices"):
            backup.run(create=True)
        assert backup.manifest.data["incomplete"] is True
    finally:
        backup.close()

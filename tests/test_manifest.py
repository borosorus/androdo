import json
import hashlib
import os

import pytest

from BestestADBSync.Manifest import (
    JOURNAL_FILENAME, MANIFEST_FILENAME, MANIFEST_VERSION, Manifest, ManifestError,
)


def test_manifest_round_trip_and_status_counts(tmp_path):
    manifest = Manifest.for_backup(tmp_path).load(create=True)
    manifest.begin_attempt()
    manifest.record_file("DCIM/photo.jpg", 123, 1700000000.5, "a" * 64)
    manifest.record_file(".hidden", 4, 1700000001)
    manifest.finish_success()

    loaded = Manifest(tmp_path / MANIFEST_FILENAME).load()
    summary = loaded.status_summary()
    assert summary["file_count"] == 2
    assert summary["total_size"] == 127
    assert summary["files_with_sha256"] == 1
    assert summary["incomplete"] is False
    assert summary["last_success"]


def test_failed_attempt_is_recorded_without_losing_last_success(tmp_path):
    manifest = Manifest.for_backup(tmp_path).load(create=True)
    manifest.begin_attempt()
    manifest.finish_success()
    old_success = manifest.data["last_success"]

    manifest.begin_attempt()
    manifest.record_file("already-copied", 10, 20)
    manifest.fail("adb pull failed")

    reloaded = Manifest.for_backup(tmp_path).load()
    assert reloaded.data["last_success"] == old_success
    assert reloaded.data["incomplete"] is True
    assert reloaded.data["last_error"] == "adb pull failed"
    assert reloaded.status_summary()["file_count"] == 1


@pytest.mark.parametrize("path", ["../escape", "/absolute", "a/../b", "a//b", "", "nul\x00name"])
def test_rejects_unsafe_manifest_paths(tmp_path, path):
    manifest = Manifest.for_backup(tmp_path).load(create=True)
    with pytest.raises(ManifestError):
        manifest.record_file(path, 0, 0)


def test_corrupt_manifest_is_reported_and_not_overwritten(tmp_path):
    path = tmp_path / MANIFEST_FILENAME
    path.write_text("{not json", encoding="utf-8")
    with pytest.raises(ManifestError, match="cannot read"):
        Manifest(path).load(create=True)
    assert path.read_text(encoding="utf-8") == "{not json"


def test_valid_json_with_invalid_record_is_reported(tmp_path):
    path = tmp_path / MANIFEST_FILENAME
    path.write_text(json.dumps({
        "version": 1,
        "remote_root": "/sdcard",
        "files": {"../escape": {"size": 1, "mtime": 2}},
    }), encoding="utf-8")
    with pytest.raises(ManifestError, match="unsafe"):
        Manifest(path).load()


def test_journal_replays_transfer_events_and_checkpoint_compacts(tmp_path):
    manifest = Manifest.for_backup(tmp_path).load(create=True)
    manifest.begin_attempt()
    manifest.begin_file("note.txt", 5, 1700000000)
    manifest.set_pending_temp("note.txt", ".phonebackup-note.partial")
    manifest.set_pending_digest("note.txt", "a" * 64)
    manifest.record_file("note.txt", 5, 1700000000, "a" * 64)

    journal = tmp_path / JOURNAL_FILENAME
    assert journal.stat().st_size > 0
    replayed = Manifest.for_backup(tmp_path).load()
    assert replayed.data["files"]["note.txt"]["sha256"] == "a" * 64
    assert replayed.data["pending"] == {}
    assert replayed._sequence == 5

    replayed.save()
    assert journal.read_bytes() == b""
    snapshot = json.loads((tmp_path / MANIFEST_FILENAME).read_text())
    assert snapshot["version"] == MANIFEST_VERSION
    assert snapshot["checkpoint_seq"] == 5
    assert Manifest.for_backup(tmp_path).load().data == replayed.data


def test_version_one_manifest_migrates_only_on_first_mutation(tmp_path):
    manifest = Manifest.for_backup(tmp_path).load(create=True)
    manifest.save()
    path = tmp_path / MANIFEST_FILENAME
    old = json.loads(path.read_text())
    old["version"] = 1
    old.pop("backup_id")
    old.pop("checkpoint_seq")
    path.write_text(json.dumps(old))
    (tmp_path / JOURNAL_FILENAME).unlink()

    read_only = Manifest.for_backup(tmp_path).load()
    assert read_only.data["version"] == 1
    assert not (tmp_path / JOURNAL_FILENAME).exists()
    read_only.begin_attempt()

    upgraded = json.loads(path.read_text())
    assert upgraded["version"] == MANIFEST_VERSION
    assert upgraded["checkpoint_seq"] == 0
    assert upgraded["backup_id"]
    assert Manifest.for_backup(tmp_path).load().data["last_attempt"] == read_only.data["last_attempt"]


def test_selection_is_not_persisted_before_migrated_attempt(tmp_path, monkeypatch):
    current = Manifest.for_backup(tmp_path).load(create=True)
    current.begin_attempt()
    current.finish_success()
    current.checkpoint()
    path = tmp_path / MANIFEST_FILENAME
    old = json.loads(path.read_text())
    old["version"] = 1
    old.pop("backup_id")
    old.pop("checkpoint_seq")
    path.write_text(json.dumps(old))
    (tmp_path / JOURNAL_FILENAME).unlink()

    legacy = Manifest.for_backup(tmp_path).load()
    legacy.set_selection(["DCIM"], [])

    def interrupt_before_attempt():
        raise OSError("simulated interruption after migration")

    monkeypatch.setattr(legacy, "_prepare_journal_append", interrupt_before_attempt)
    with pytest.raises(OSError, match="after migration"):
        legacy.begin_attempt()

    recovered = Manifest.for_backup(tmp_path).load()
    assert recovered.data["selection"] == old["selection"]
    assert recovered.data["incomplete"] is False
    assert recovered.data["last_success"] == old["last_success"]


def test_torn_final_journal_record_is_ignored_and_repaired_before_append(tmp_path):
    manifest = Manifest.for_backup(tmp_path).load(create=True)
    manifest.begin_attempt()
    journal = tmp_path / JOURNAL_FILENAME
    journal.write_bytes(journal.read_bytes() + b'{"partial":')

    replayed = Manifest.for_backup(tmp_path).load()
    assert replayed.data["last_attempt"] is not None
    replayed.record_file("note.txt", 1, 10, "b" * 64)
    assert journal.read_bytes().endswith(b"\n")
    recovered = Manifest.for_backup(tmp_path).load()
    assert recovered.data["files"]["note.txt"]["sha256"] == "b" * 64


def test_journal_checksum_corruption_is_rejected(tmp_path):
    manifest = Manifest.for_backup(tmp_path).load(create=True)
    manifest.begin_attempt()
    journal = tmp_path / JOURNAL_FILENAME
    envelope = json.loads(journal.read_text().splitlines()[0])
    envelope["sha256"] = "0" * 64
    journal.write_text(json.dumps(envelope) + "\n")
    with pytest.raises(ManifestError, match="checksum mismatch"):
        Manifest.for_backup(tmp_path).load()


def test_checkpoint_before_journal_clear_is_replay_safe(tmp_path, monkeypatch):
    manifest = Manifest.for_backup(tmp_path).load(create=True)
    manifest.begin_attempt()
    original_replace = manifest._replace_journal

    def fail_journal_clear(content):
        raise OSError("simulated journal clear failure")

    monkeypatch.setattr(manifest, "_replace_journal", fail_journal_clear)
    with pytest.raises(OSError, match="journal clear failure"):
        manifest.save()
    monkeypatch.setattr(manifest, "_replace_journal", original_replace)

    recovered = Manifest.for_backup(tmp_path).load()
    assert recovered.data["last_attempt"] == manifest.data["last_attempt"]
    assert recovered._sequence == 1
    recovered.record_file("after-restart", 1, 20, "c" * 64)
    assert Manifest.for_backup(tmp_path).load().data["files"]["after-restart"]["sha256"] == "c" * 64


def test_uncertain_append_poison_requires_reload(tmp_path, monkeypatch):
    manifest = Manifest.for_backup(tmp_path).load(create=True)

    def fail_append(descriptor, data):
        raise OSError("simulated append failure")

    monkeypatch.setattr("BestestADBSync.Manifest.os.write", fail_append)
    with pytest.raises(OSError, match="append failure"):
        manifest.begin_attempt()
    with pytest.raises(ManifestError, match="reload"):
        manifest.record_file("note.txt", 1, 2, "d" * 64)

    reloaded = Manifest.for_backup(tmp_path).load()
    assert reloaded.data["last_attempt"] is None


def test_append_detaches_hardlinked_journal_without_changing_alias(tmp_path):
    manifest = Manifest.for_backup(tmp_path).load(create=True)
    manifest.begin_attempt()
    journal = tmp_path / JOURNAL_FILENAME
    alias = tmp_path / "retained-payload.bin"
    before = journal.read_bytes()
    os.link(str(journal), str(alias))

    manifest.record_file("note.txt", 1, 2, "e" * 64)

    assert alias.read_bytes() == before
    assert journal.read_bytes() != before
    assert os.stat(str(journal)).st_ino != os.stat(str(alias)).st_ino


def test_journal_metadata_write_volume_grows_linearly(tmp_path, monkeypatch):
    def measure(count, backup_dir):
        import BestestADBSync.Manifest as manifest_module

        manifest = Manifest.for_backup(backup_dir).load(create=True)
        original_validate = manifest._validate
        validations = []
        written = [0]

        class CountingStream:
            def __init__(self, stream):
                self.stream = stream

            def __enter__(self):
                self.stream.__enter__()
                return self

            def __exit__(self, *args):
                return self.stream.__exit__(*args)

            def write(self, data):
                written[0] += len(data if isinstance(data, bytes) else data.encode("utf-8"))
                return self.stream.write(data)

            def __getattr__(self, name):
                return getattr(self.stream, name)

        def count_validation(value):
            validations.append(1)
            return original_validate(value)

        original_fdopen = os.fdopen
        original_write = os.write

        def counted_fdopen(*args, **kwargs):
            return CountingStream(original_fdopen(*args, **kwargs))

        def counted_write(descriptor, data):
            written[0] += len(data)
            return original_write(descriptor, data)

        manifest._validate = count_validation
        with monkeypatch.context() as patcher:
            patcher.setattr(manifest_module.os, "fdopen", counted_fdopen)
            patcher.setattr(manifest_module.os, "write", counted_write)
            for index in range(count):
                path = "files/{:05d}.bin".format(index)
                manifest.begin_file(path, 16, 1700000000,
                                    temp_path=".phonebackup-{:05d}.partial".format(index))
                digest = hashlib.sha256(path.encode()).hexdigest()
                manifest.set_pending_digest(path, digest)
                manifest.record_file(path, 16, 1700000000, digest)
            manifest.save()
        assert len(validations) == 2
        assert (backup_dir / JOURNAL_FILENAME).read_bytes() == b""
        return written[0]

    small = measure(80, tmp_path / "small")
    large = measure(160, tmp_path / "large")
    assert large <= small * 2.5


def test_save_uses_only_complete_json_sidecar(tmp_path):
    manifest = Manifest.for_backup(tmp_path).load(create=True)
    manifest.begin_attempt()
    loaded = json.loads((tmp_path / MANIFEST_FILENAME).read_text(encoding="utf-8"))
    assert loaded["incomplete"] is True
    assert not list(tmp_path.glob(MANIFEST_FILENAME + ".*.tmp"))


def test_pending_transfer_cannot_be_marked_successful(tmp_path):
    manifest = Manifest.for_backup(tmp_path).load(create=True)
    manifest.begin_attempt()
    manifest.begin_file("unfinished.bin", 20, 30)
    with pytest.raises(ManifestError, match="transfers remain pending"):
        manifest.finish_success()

# PhoneBackup goal and current state

## Product goal

Build a safe, understandable way to back up files from Android shared storage to an ordinary folder on a computer. The end product is intended to have a user interface. Development is currently focused on a scriptable command-line interface; the UI is a later milestone.

The backup is one-way and non-destructive. It should make incremental updates reliable, keep phone-side deletions in the backup, and make incomplete or failed operations clear. It uses standard ADB access and does not require root or an Android-side application.

## Implemented

- `phonebackup new`, `update`, `diff`, `verify`, and `status` commands.
- `phonebackup paths` lists readable source paths without creating a backup; text is the default output and `--format json` is available for scripts and a future UI.
- `phonebackup history` lists retained previous versions for a file or backup.
- `phonebackup prune-history` previews selected historical version IDs by default and removes them only with `--apply`; shared history blobs remain while referenced.
- `phonebackup restore` can export a current/historical version to a local file or explicitly restore it to the original Android path.
- By default, back up all files readable under `/sdcard`, including hidden files. The source root can be changed with `--remote-root`.
- Select specific relative paths with repeatable `--include PATH`. Including a directory includes its contents. Use repeatable `--exclude PATTERN` for relative glob exclusions; exclusions take precedence.
- Save the selection in `.phonebackup-manifest.json`. An update with no selection flags reuses the saved selection. Passing `--include` or `--exclude` replaces that category of saved rules. `--all` resets the rules and selects everything.
- `diff` previews changes and selection scope without changing the manifest or backup files. Existing manifest files that are missing from the phone or outside the current selection are reported as preserved.
- Incremental detection compares file size and modification time, then checks the local SHA-256 against the prior manifest hash when metadata says a file is unchanged. Content is hashed locally after each transfer. ADB does not provide a remote content hash comparison here.
- Atomic temporary transfers protect completed files from an interrupted replacement. The manifest tracks completed and pending transfers, and `verify` checks local content against stored hashes.
- A file deleted on the phone or moved outside the current selection is retained in the backup. Scope changes never prune backup files.
- When an update replaces different bytes for a tracked file, the prior local bytes are copied into `.phonebackup-history/` and indexed in the manifest. History is per-file and is never pruned automatically; current files stay at their ordinary relative paths.
- Restore verifies the local source hash when one is stored; older hashless entries warn that only the current local bytes can be checked. Local export is atomic and refuses to overwrite an existing file without `--overwrite`; no-overwrite export can fail safely if the host filesystem lacks hard-link support. Phone restore stages a remote temporary file, refuses an existing destination without `--overwrite`, and verifies the published size. Its atomic no-overwrite publication can fail safely if the phone filesystem lacks hard-link support.
- A per-backup lock prevents concurrent operations from racing. Paths, symlinks, host filename collisions, and untracked destination files are checked before writes.
- The existing `adbsync` program remains available for users who need direct synchronization.

## CLI examples

```sh
# Back up everything (the default)
phonebackup new /backups/my-phone

# Back up camera photos and documents, excluding thumbnails
phonebackup new /backups/my-phone \
  --include DCIM \
  --include Documents \
  --exclude 'DCIM/Thumbnails/**'

# Reuse the selection saved in the manifest
phonebackup update /backups/my-phone

# Preview a different scope without saving it
phonebackup diff /backups/my-phone --include Pictures

# Reset the saved selection to all files
phonebackup update /backups/my-phone --all
```

## Current limits

- ADB can only read files allowed by the connected Android device. Protected app-private data is outside the scope of this tool.
- Includes are explicit relative paths and must exist and be accessible when first requested. If a saved include later disappears from the phone, updates retain its old backup files and `diff` reports them as preserved. Exclusions use Python `fnmatch` glob rules against relative path prefixes.
- History is per-file, not a coherent point-in-time snapshot. Old versions use additional storage and remain until explicitly selected for removal with `prune-history --apply`; there is no automatic pruning.
- Transfers append small checksummed events to `.phonebackup-journal.jsonl`; the readable JSON manifest is checkpointed when a command completes. This keeps metadata writes linear in the number of changed files. A crash can leave events to replay on the next command; loading a large unfinished run still takes time proportional to its journal length.
- The journal avoids full-manifest rewrites per file, but each durable transfer transition still requires a journal sync. Metadata is loaded into memory, and a large interrupted operation takes time to replay.
- Existing version 1 backups are migrated on first write. Older PhoneBackup versions reject the upgraded manifest format instead of silently ignoring its journal.
- Phone restore is file-level and writes to shared storage only. It does not restore applications, settings, or protected app-private data. Phone restore checks the source hash locally and the published remote size; it does not yet verify a remote content digest.
- Update detection uses size and timestamps to decide whether a remote transfer is needed. A same-size edit with a preserved timestamp can evade remote change detection; `verify` only checks the local copy against the last stored hash.
- An interrupted transfer that leaves an unverified file at a final destination path is reported as a conflict. Move the unverified file aside before retrying.
- Automated tests use fake ADB. Physical Android and macOS validation is deferred; development is currently on Linux.

## Completed CLI milestones: selection and path discovery

Selection rules persist for updates, preview alternate scopes, and do not delete prior backup files. `paths` provides read-only source discovery in text or JSON for users and future UI code.

## Implemented milestone: per-file recovery

Previous contents are retained before replacement, exposed through `history`, and can be restored either to a local file or explicitly to the phone. `prune-history` requires exact version IDs, previews by default, and removes shared blobs only after their final history reference is removed.

## Later milestone: user interface

Build a UI on top of the same selection and manifest behavior. Users should be able to see available Android paths, choose folders or files, inspect the planned changes, run or resume a backup, and understand what was included or preserved. Keep the CLI usable for scripting and recovery. Do not add a GUI, service, or background daemon as part of the current CLI milestone.

## Engineering priorities

1. Data safety and correctness.
2. Clear feedback about selection, progress, failures, and incomplete state.
3. Reliable incremental updates without unnecessary transfers.
4. Simple operation and readable implementation.
5. Keep ordinary files directly accessible in Finder or a file manager.

Review changes for data-loss scenarios before considering a milestone complete. Do not claim physical-device compatibility until it has been exercised on Android and macOS.

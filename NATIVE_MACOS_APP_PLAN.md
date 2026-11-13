# Native macOS Android Backup App — Progress Journal

## Goal

Build a native SwiftUI macOS app with a new Swift engine for selective Android shared-file backups, complete restore points, restore to Mac or phone, and companion phone-to-Mac / Mac-to-phone file copy.

V1 is manual, unencrypted, USB/ADB based, and stores an app-managed repository under a folder the user chooses. It may include `Android/media`, `Android/data`, and `Android/obb` only when the connected device exposes them to ADB. Report unavailable paths; never claim app-private data, settings, or a whole-device restore.

The Python CLI remains as reference code. No Python runtime or backup-format compatibility is required. Preserve the untracked `PhoneBackupTrial/` user backup; do not use it as a fixture, package resource, or commit candidate.

## Working agreement

- Work on `feature/native-macos-app`, created from the current `main` at `70f7c27`.
- Keep each numbered step to one reviewable implementation slice and one commit. Run its stated checks, request a reviewer pass, address findings, then mark the step complete with its commit subject and review outcome; Git history is authoritative for the hash.
- Keep this file as the progress journal. Mark the step and record the commit subject and review outcome in the implementation commit; the commit hash is authoritative in Git history and must not be self-recorded in that commit.
- Do not commit user backup data, generated app bundles, credentials, or device-specific private logs.
- Prefer safe fake-device fixtures for routine development. Real-device tests use only a user-approved disposable folder.

## Progress

- [x] Step 0 — Create the feature branch and establish the Swift project shell. Commit: `chore(macOS): scaffold Swift app and engine`. Review: approved, no code blockers; follow-up notes addressed.
- [x] Step 1 — Define Swift engine models, protocols, and fake transport. Commit: `feat(engine): define backup and device contracts`. Review: approved; byte-exact path identity, explicit shared-storage scope, and safe conflict recovery covered.
- [x] Step 2 — Implement ADB discovery, path-safe transport, and lazy browsing. Commit: `feat(adb): add device transport and lazy browsing`. Review: approved after fixes for ADB shell argument quoting, `/sdcard` symlink traversal, process-output draining, and structured disconnect errors.
- [x] Step 3 — Implement the local backup repository and immutable restore points. Commit: `feat(repository): add durable snapshot storage`. Review: approved after fixes for stable per-open volume identity, copied repository IDs, and filesystem-compatible exclusive publication.
- [ ] Step 4 — Implement selective backup planning, execution, progress, and recovery.
- [ ] Step 5 — Implement verification and safe local/phone restore.
- [ ] Step 6 — Implement direct file copy in both directions.
- [ ] Step 7 — Build the backup-first SwiftUI experience and offline restore browser.
- [ ] Step 8 — Build the phone file browser, Activity, and accessibility polish.
- [ ] Step 9 — Complete packaging, CI, and end-to-end acceptance.

## Steps

### Step 0 — Branch and project shell

**Deliverable:** A clean `feature/native-macos-app` branch, a Swift package for the engine, and a minimal SwiftUI executable target. Keep the existing Python sources untouched. The development machine now selects Xcode 27.2, Swift 6.4.2, and macOS SDK 27.2.

**Commit:** `chore(macOS): scaffold Swift app and engine`

**Checks:** `swift test` passes (one XCTest); `swift run PhoneBackupApp` builds and starts, then is stopped with Ctrl-C; `git diff --check` passes. The app process staying alive confirms startup, but window visibility was not independently observed. `PhoneBackupTrial/` remains untracked and is excluded from the commit.

**Review:** Confirm branch base, target layout, minimum macOS version, no Python dependency, and no user-data inclusion.

**Complete:** The branch and scaffold are in place; the checklist and reviewer outcome are recorded in the implementation commit. Use Git history for the commit hash.

### Step 1 — Engine contracts and test transport

**Deliverable:** Define typed models for devices, remote entries, selections, repositories, restore points, conflicts, operation phases, warnings, errors, and recovery actions. Add protocols for device transport, remote file access, backup repository, and operation coordination. Provide a deterministic fake transport and repository for Swift tests.

**Commit:** `feat(engine): define backup and device contracts`

**Checks:** Model serialization, state-transition, fake-device, and fake-repository tests; Swift concurrency checks compile cleanly.

**Review:** Ensure UI-facing types are stable, errors have actionable recovery, and no view model needs direct process or database access.

### Step 2 — ADB transport and lazy device browsing

**Deliverable:** Resolve ADB from common install locations with a manual “Locate ADB” setting. Discover device states and bind every operation to an explicit serial. Add safe argument/process handling, timeouts, cancellation, output decoding, and an API that lists only immediate children of an opened directory. Probe access to selected Android roots, including `Android/media`, `Android/data`, and `Android/obb`.

**Commit:** `feat(adb): add device transport and lazy browsing`

**Checks:** Fake ADB tests for no device, unauthorized/offline devices, multiple devices, disconnection, paths with spaces/newlines, denied subtrees, and cancellation. A real-device smoke test lists only a user-opened folder.

**Review:** Confirm no recursive listing occurs on device discovery and no command string is built by interpolating user paths. Preserve valid UTF-8 names exactly; if a filename cannot be represented safely by the Swift/ADB transport, report it as an omission and prevent a complete restore point until the user explicitly finishes with that omission.

**Complete:** Implemented discovery, SDK/Homebrew/PATH resolution, serial-bound pull/push, safely quoted immediate-child listings, structured device/path errors, and bounded cancellable process execution. `swift test` passes (19 tests); `git diff --check` passes. No phone folders were read; the real-device smoke test remains for a user-selected path.

### Step 3 — Repository and immutable restore points

**Deliverable:** Store one app-managed repository per device beneath the user-selected local or external folder. Use SQLite for repository metadata and a content-addressed object directory for verified file bytes. A completed restore point records the full effective selected tree and references; retain prior restore points and deduplicate unchanged content. Include repository locking, device association, external-volume checks, and integrity verification.

**Commit:** `feat(repository): add durable snapshot storage`

**Checks:** Repository create/open, transaction interruption, object deduplication, corruption detection, restore-point browsing, disk-full/external-volume failure, and concurrent-writer tests.

**Review:** Confirm completed restore points are immutable, objects are published only after verification, and metadata recovery cannot expose a partial point as complete.

**Complete:** Added per-device SQLite repositories, private object/staging folders, streaming SHA-256 imports with exclusive atomic publication, deduplication, immutable complete-point metadata, UTF-8 BLOB path indexes, offline browsing, integrity verification, nonblocking repository locks, and volume/device checks. `swift test` passes (28 tests); `git diff --check` passes. Triggered SQLite rollback and `SQLITE_FULL` cases are covered. Abrupt process termination and FAT/exFAT or external-volume reconnect behavior were not exercised on hardware/filesystems; user-selected location bookmarks and missing-mount detection across app relaunch remain for UI integration.

### Step 4 — Selection, planning, backup execution, and recovery

**Deliverable:** Implement a lazy folder selection tree, explicit “All shared files” selection, read-only backup plan, scan/transfer/verify phases, incremental reuse, operation cancellation, and resumable incomplete attempts. Recheck source metadata before and after each transfer; retry an unstable file a bounded number of times, then keep the attempt incomplete. Record inaccessible paths; require an explicit choice to retry or finish with omissions before publishing a restore point.

**Commit:** `feat(backup): add scoped snapshot operations`

**Checks:** Selection include/exclude behavior; first and unchanged backups; add/change/delete behavior across restore points; inaccessible and missing selected roots; source changes during transfer; cancellation, disconnect, retry, and resume tests.

**Review:** Confirm no folder is selected implicitly, a denied path cannot silently yield a complete point, and the last completed point remains current until the next point commits.

### Step 5 — Restore and local verification

**Deliverable:** Browse a restore point offline, select files/folders, export to a chosen Mac directory, or restore to original phone paths or a chosen phone folder. Preflight conflicts, require explicit replacement, reject symlink/path traversal, verify restored bytes, and provide a clear recovery error when the phone filesystem rejects safe no-overwrite publication.

**Commit:** `feat(restore): add verified batch restore`

**Checks:** Local and phone restore tests for original/alternate destinations, missing targets, existing targets, replacement confirmation, collisions, partial failures, cancellation, and SHA-256 verification.

**Review:** Confirm unrelated destination files are never removed, no-overwrite never silently becomes overwrite, and partial batch outcomes are accurately shown.

### Step 6 — Direct file copy

**Deliverable:** Add selected file/folder copy from phone to Mac and Mac to phone without creating a backup restore point. Reuse staging, verification, conflict, cancellation, and path-safety services from restore.

**Commit:** `feat(transfer): add direct file copy`

**Checks:** Bidirectional single/multi-file copy, folder copy, duplicate names, replacement choice, unsafe paths, transfer interruption, retry, and content verification.

**Review:** Confirm copy does not mutate repository history and phone-side deletes/moves are not inferred from a copy.

### Step 7 — Backup-first native UI

**Deliverable:** Build the native sidebar and device overview with **Back Up Now** as the primary action. Add destination selection, saved selection, scope/size review, progress, cancellation, incomplete-path choices, and backup completion state. Add offline restore-point browsing and local export flow.

**Commit:** `feat(ui): add backup and local restore flows`

**Checks:** SwiftUI tests for onboarding, empty/disconnected states, first backup, incremental backup, inaccessible paths, cancellation/retry, and offline browsing; VoiceOver labels and keyboard navigation checks.

**Review:** Confirm native macOS patterns, clear status language, no misleading progress, and no phone scan until a user opens or selects a path.

### Step 8 — Phone browser, device restore, Activity, and polish

**Deliverable:** Add Finder-style remote browsing with breadcrumbs, sortable columns, multi-selection, drag/drop, and direct-copy actions. Add device restore destination and conflict flows. Add Activity records for complete, incomplete, failed, cancelled, and retried operations, plus system appearance and accessibility polish.

**Commit:** `feat(ui): add phone browser and operation activity`

**Checks:** UI fixtures for browsing, both copy directions, original/alternate phone restore, conflict decisions, permission-denied paths, and Activity recovery actions.

**Review:** Confirm directory browsing remains shallow, destructive actions are explicit, and path/serial details are not exposed in persistent diagnostics by default.

### Step 9 — Packaging and end-to-end acceptance

**Deliverable:** Add reproducible local `.app` build steps using the installed ADB, ADB location recovery, macOS CI for engine/app targets, and a short user guide. Keep initial release local/ad-hoc signed; defer notarization, universal binaries, App Store, and ADB redistribution pending licensing review.

**Commit:** `build(macOS): package app and add acceptance checks`

**Checks:** Clean build from documented steps; all Swift and existing Python tests; app startup without a phone; real-device acceptance using only an explicitly selected disposable folder and hash-checked copy/restore round trips.

**Review:** Confirm generated app artifacts and `PhoneBackupTrial/` are excluded, build prerequisites are clear, and completion claims distinguish shared-file backup from full-device backup.

## Platform and product constraints

- Android’s `Android/media` is shared storage. Android 11+ restricts `Android/data` and `Android/obb` through standard Android file APIs; ADB-shell availability varies by device. Probe actual access and explain denials rather than promising it.
- A restore point is a validated scan-based snapshot, not an atomic image of a changing phone filesystem.
- No automatic scheduling, wireless pairing, cloud storage, encryption, protected app-private data, apps/settings backup, or OS restore in v1.
- Build the initial app for this Apple Silicon Mac and keep platform-specific assumptions isolated so later support for other Macs is straightforward.

## Decision record

- Backup semantics: complete immutable restore points.
- Destination: user-chosen ordinary local/external directory.
- Repository layout: **app-managed repository**, browsed in the app, not a Finder mirror of latest files. This is the recommended default because it supports immutable snapshots and deduplication while preserving the user’s choice of storage location.
- Encryption: none in v1.
- Engine/UI: Swift engine and SwiftUI app; Python CLI remains reference-only, with no backup-format compatibility requirement.
- v1 operations: explicit/manual backup, direct copy companion, local and phone restore to original or alternate destination.

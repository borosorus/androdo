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
- [x] Step 4 — Implement selective backup planning, execution, progress, and recovery. Commit: `feat(backup): add scoped snapshot operations`. Review: approved after fixes; see completion notes below.
- [x] Step 5 — Implement verification and safe local/phone restore. Commit: `feat(restore): add verified batch restore`. Review: approved after fixes for source-base validation, descriptor cleanup, and failure-path coverage.
- [x] Step 6 — Implement direct file copy in both directions. Commit: `feat(transfer): add direct file copy`. Review: approved after fixes for destination parents, source ancestors, directory revalidation, cancellation, error reporting, repository containment, descriptor-relative traversal, and plan mapping consistency.
- [x] Step 7 — Build the backup-first SwiftUI experience and offline restore browser. Commit: `feat(ui): add backup and local restore flows`. Review: approved, no blockers; follow-up findings addressed.
- [x] Step 8 — Build the phone file browser, Activity, and accessibility polish. Commit: `feat(ui): add phone browser and operation activity`. Review: approved after fixes for device-bound restore browsing, Finder promise device binding, asynchronous safe-no-overwrite recovery, empty-folder drops, verified Activity counts, and preventing review dismissal during operation startup.
- [x] Step 8.1 — Refine native navigation, selection, and shared operation/review flows. Commit: `refactor(ui): unify native macOS navigation and flows`. Review: approved after fixes for reconnect navigation, restore replacement messaging, bounded global recovery, and accurate exclusion labels.
- [x] Step 8.2 — Give the app a distinct native identity, simplify the Overview and backup library, and reduce instructional copy. Commit: `feat(ui): add a distinctive native Mac identity`. Review: approved after fixes for text contrast and Settings error visibility.
- [ ] Step 9 — Complete packaging, CI, and end-to-end acceptance. Local packaging and CI committed as `build(macOS): package app and add acceptance checks`; reviewer approved. Phone acceptance remains pending an explicitly selected disposable folder.

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

**Complete:** Added per-device SQLite repositories, private object/staging folders, streaming SHA-256 imports with exclusive atomic publication, deduplication, immutable complete-point metadata, UTF-8 BLOB path indexes, offline browsing, integrity verification, nonblocking repository locks, and volume/device checks. `swift test` passed (28 tests); `git diff --check` passed. Triggered SQLite rollback and `SQLITE_FULL` cases are covered. Abrupt process termination and FAT/exFAT or external-volume reconnect behavior were not exercised on hardware/filesystems; user-selected location bookmarks and missing-mount detection across app relaunch remain for UI integration.

### Step 4 — Selection, planning, backup execution, and recovery

**Deliverable:** Implement a lazy folder selection tree, explicit “All shared files” selection, read-only backup plan, scan/transfer/verify phases, incremental reuse, operation cancellation, and resumable incomplete attempts. Recheck source metadata before and after each transfer; retry an unstable file a bounded number of times, then keep the attempt incomplete. Record inaccessible paths; require an explicit choice to retry or finish with omissions before publishing a restore point.

**Commit:** `feat(backup): add scoped snapshot operations`

**Checks:** Selection include/exclude behavior; first and unchanged backups; deletion behavior; inaccessible paths and stale omission approval; source mutation during transfer; durable checkpoint and interrupted-attempt recovery; ADB metadata parsing. Full `swift test` passed (35 tests); `git diff --check` passed.

**Review:** Confirmed selected roots are explicit, an inaccessible path cannot silently yield a complete point, a retry that discovers different omissions requires another decision, and the last completed point remains current until atomic publication. Review also led to bounded event replay, cancellable hashing/publication, and linear progress accounting.

**Complete:** Implemented scoped planning and backup execution, incremental object reuse after verification, durable attempts/checkpoints and resume, atomic restore-point publication, and explicit incomplete/omission decisions. The suite covers the checks above. Engine-level cancellation, disconnect, and execution-resume behavior still need dedicated tests; durable checkpoint survival across reopen is covered. Device hardware execution remains a later acceptance step.

### Step 5 — Restore and local verification

**Deliverable:** Browse a restore point offline, select files/folders, export to a chosen Mac directory, or restore to original phone paths or a chosen phone folder. Preflight conflicts, require explicit replacement, reject symlink/path traversal, verify restored bytes, and provide a clear recovery error when the phone filesystem rejects safe no-overwrite publication.

**Commit:** `feat(restore): add verified batch restore`

**Checks:** Local and phone restore tests cover alternate destinations, missing targets, explicit replacement and stale-identity rejection, path containment and aliases, staged/final SHA-256 verification, partial failures, cancellation, and published-but-unverified outcomes. Full `swift test` passed (53 tests); `git diff --check` passed.

**Review:** Approved. Review findings led to a source-base containment guard for phone mappings, closing intermediate directory descriptors on every exit, and deterministic tests for partial failure, cancellation, and publication whose final verification fails. Unrelated destination files are preserved and no-overwrite never silently becomes overwrite.

**Complete:** Added immutable-source restore plans, full-batch conflict preflight, safe local descriptor-relative publication, staged and verified ADB restore, explicit identity-checked replacement, per-item batch outcomes, cancellation, and bounded operation events. User-selected restore targets are checked against managed repository paths. The device-side ancestor check narrows but cannot eliminate races caused by concurrent external filesystem changes; this limitation is not described as race-proof behavior.

### Step 6 — Direct file copy

**Deliverable:** Add selected file/folder copy from phone to Mac and Mac to phone without creating a backup restore point. Reuse staging, verification, conflict, cancellation, and path-safety services from restore.

**Commit:** `feat(transfer): add direct file copy`

**Checks:** Fake-device tests cover both directions, folder and empty-directory copies, missing destination parents, duplicate targets, explicit and stale replacement approval, missing-target replacement recovery, unsafe source paths, source changes, directory removal after planning, cancellation during 256 MiB local staging, partial failures, and published-but-unverified output. Repository restore points and attempts remain unchanged. Full `swift test` passed (67 tests); `git diff --check` passed. Retrying starts from a fresh plan; retry UI remains part of the later UI steps.

**Review:** Approved. Copy is repository-independent apart from read-only managed-root protection. Local Mac sources are enumerated and opened through pinned directory descriptors; destination publication uses the verified restore publisher. Android source and destination ancestor checks reject symlink traversal except the intentional `/sdcard` alias. Phone-side deletes and moves are never inferred from a copy.

**Complete:** Added `CopyEngine` planning and operation results for phone-to-Mac and Mac-to-phone selected files/folders. Copy preserves selected root names, checks source and destination state before and during transfer, stages and hashes bytes in a private temporary directory, uses atomic verified destination publication, and records partial/cancelled/unverified outcomes. Existing backup history is read-only. Concurrent changes to Android ancestors can still race path-based ADB checks; they are not represented as race-proof.

### Step 7 — Backup-first native UI

**Deliverable:** Build the native sidebar and device overview with **Back Up Now** as the primary action. Add destination selection, saved selection, scope/size review, progress, cancellation, incomplete-path choices, and backup completion state. Add offline restore-point browsing and local export flow.

**Commit:** `feat(ui): add backup and local restore flows`

**Checks:** `swift build` succeeds as part of `swift test`; full suite passes (67 core tests and 4 UI-model tests). UI-model coverage checks per-device selection preferences, shared-path export mapping including one-file selection, and that device discovery does not list phone folders. `git diff --check` passes. On-device backup/restore and VoiceOver/keyboard navigation have not been exercised; real-device acceptance remains in Step 9.

**Review:** Approved with no remaining blockers. Review fixes covered single-file export mapping, persistent interrupted-attempt recovery, stale restore context, omission warnings, and serialized operation startup. Device discovery remains shallow; remote folder listing starts only after the user opens the selection sheet.

**Complete:** Added a SwiftUI device sidebar, destination chooser with a saved security-scoped bookmark, explicit shared-storage or folder selection with lazy listing, backup plan review, progress/cancellation, retry or confirmed omission handling, and an offline restore library with selected-file/folder export and explicit conflict replacement. Recovery attempts are reloaded from repositories after reopening. The app has not yet been visually inspected with VoiceOver or validated against a connected phone; those checks are deferred to Step 9.

### Step 8 — Phone browser, device restore, Activity, and polish

**Deliverable:** Add Finder-style remote browsing with breadcrumbs, sortable columns, multi-selection, drag/drop, and direct-copy actions. Add device restore destination and conflict flows. Add Activity records for complete, incomplete, failed, cancelled, and retried operations, plus system appearance and accessibility polish.

**Commit:** `feat(ui): add phone browser and operation activity`

**Checks:** UI fixtures for browsing, both copy directions, original/alternate phone restore, conflict decisions, permission-denied paths, and Activity recovery actions.

**Review:** Confirm directory browsing remains shallow, destructive actions are explicit, and path/serial details are not exposed in persistent diagnostics by default.

**Complete:** Added lazy, immediate-child phone browsing, sorting and multi-selection, direct copy in both directions with explicit conflict review, Finder drops and outbound file promises, same-device restore to original or chosen folders, and bounded session-only Activity summaries. Activity omits paths, serial numbers, and raw transport errors; durable backup recovery remains in the repository. `swift test` passed (67 core and 9 UI-model tests); `git diff --check` passed. Reviewer approved after the fixes recorded above. AppModel orchestration lacks focused regression fixtures for device binding and asynchronous replacement replanning; Finder promise, nested sheet presentation, VoiceOver/keyboard navigation, appearance, and real-device flows still require manual acceptance in Step 9. No phone storage was read or changed for this step; `PhoneBackupTrial/` remains untracked and excluded.

### Step 8.1 — Native macOS navigation and shared flows

**Deliverable:** Refine the native sidebar so device selection is separate from page navigation. Keep operation progress and recovery visible across pages, make backup folder choices transactional, and align review sheets and page layouts around consistent macOS headers, pinned actions, system colors, and resizable split views. Preserve the backup-first workflow, explicit replacement approvals, lazy device browsing, and offline restore browsing.

**Commit:** `refactor(ui): unify native macOS navigation and flows`

**Checks:** Swift tests cover selection draft apply/discard semantics and navigation remains shallow; build the SwiftUI app, run the full Swift suite, rebuild the local app bundle, and run `git diff --check`. Do not read or write phone folders for this refactor.

**Review:** Confirm page selection is clear, operation cancellation and recovery remain available on all pages, review actions stay visible with long conflict lists, Cancel discards uncommitted selection changes, and sheet presentation does not close when backup startup fails.

**Complete:** Added selectable native sidebar navigation separated from device choice, a bounded global progress/recovery area with centralized omission confirmation, shared page and sheet components, pinned cancel/confirm actions, transactional backup selection, correct selected-versus-excluded summaries, keyboard/context-menu folder opening, resizable backup columns, and collapsed restore-tree rows. `swift test` passed (69 core and 14 UI-model tests); `git diff --check` passed; the Apple Silicon app bundle rebuilt and its ad-hoc signature verified. Reviewer approved after the listed fixes. No phone folders were read or changed. Interactive sheet behavior, Return-key navigation, VoiceOver, and very large recovery lists still need manual visual acceptance in Step 9.

### Step 8.2 — Visual identity and approachable Mac presentation

**Design agreement:** Familiar and approachable; blue/teal identity with restrained copper accents. Planner reviewed the existing screens and proposed the device-first Overview, native navigation, simpler library, and concise copy. The user approved this direction before implementation.

**Actionable slice (one implementation commit):**
1. Add semantic, appearance-aware accent colors, an original phone/archive emblem, a neutral Android illustration, and reusable Overview rows. Render fictional-data light/dark previews without an AppModel or transport.
2. Recompose Overview around the phone and Back Up action. Keep the destination and selected scope visible. Add colored native sidebar glyphs and move routine ADB configuration into Settings, retaining missing-ADB recovery.
3. Replace the backup library's repository column with a picker; retain two resizable browsing panes. Align Files, Activity, review sheets, and compact operation progress. Preserve explicit conflict approvals and bounded recovery controls.
4. Generate a local app icon at exact pixel sizes, package it into the app, preserve the bundle permission correction, and show the packaged build revision in Settings.
5. Run Swift checks, render/inspect appearance previews, rebuild/verify the bundle, resolve reviewer findings, update this journal, and commit.

**Commit:** `feat(ui): add a distinctive native Mac identity`

**Complete:** Added the device-first Overview, original phone/archive identity and packaged Dock icon, blue/teal accents with copper backup-history details, appearance/contrast-aware control colors, concise copy, Settings with local ADB error presentation and build identity, a two-pane backup library, and compact progress with bounded recovery controls. Kept file browsing native and preserved selection drafts, replacement approvals, cancellation, and incomplete restore-point messaging. Swift tests passed (69 core + 14 UI-model); the final app bundle built with valid Info.plist, icon and ad-hoc signature, and traversable package permissions. `bash -n` and `git diff --check` passed. Fictional-data Overview previews were rendered and visually inspected in light/dark appearance; they are isolated compositions, not running-app screenshots. Reviewer approved after fixes for text contrast and Settings error visibility. Full-window sizing, interactive keyboard/VoiceOver, and selected-folder phone acceptance remain Step 9 work. No phone folders or user backup data were accessed. No latest-backup date is inferred from the library selection, which may belong to a different device.

### Step 9 — Packaging and end-to-end acceptance

**Deliverable:** Add reproducible local `.app` build steps using the installed ADB, ADB location recovery, macOS CI for engine/app targets, and a short user guide. Keep initial release local/ad-hoc signed; defer notarization, universal binaries, App Store, and ADB redistribution pending licensing review.

**Commit:** `build(macOS): package app and add acceptance checks`

**Checks:** Clean build from documented steps; all Swift and existing Python tests; app startup without a phone; real-device acceptance using only an explicitly selected disposable folder and hash-checked copy/restore round trips.

**Review:** Confirm generated app artifacts and `PhoneBackupTrial/` are excluded, build prerequisites are clear, and completion claims distinguish shared-file backup from full-device backup.

**Local implementation complete; Step 9 remains open:** Added an Apple Silicon `.app` builder with `Info.plist`, `PkgInfo`, and ad-hoc signature verification; always-available ADB recovery with executable-path validation and serialized refresh; a separate macOS Swift CI workflow; native app setup and acceptance guides; and an ignore rule protecting `PhoneBackupTrial/`. `swift test` passed (69 core and 11 UI-model tests), Python tests passed (128), the app bundle built and verified, `open dist/PhoneBackup.app` returned successfully, and `git diff --check` passed. Reviewer approved with no blockers. No phone folders were browsed or changed. The app window was not visually inspected, and the hash-checked phone backup/copy/restore acceptance still requires your explicit disposable-folder selection; do not mark this step complete until those checks are observed.

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

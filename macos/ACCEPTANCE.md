# Native app acceptance

This checklist separates automated checks from manually observed behavior.
Never use a personal photo or document folder as a test target. For phone
acceptance, first choose one disposable folder and keep all reads and writes
inside it. PhoneBackupTrial is user data and must not be used by automated
checks, copied into the app, or committed.

## Automated, no phone required

- [x] Swift core and UI-model tests use fake devices or local temporary files.
- [x] App bundle build verifies the Info.plist and ad-hoc signature.
- [x] CI runs Swift tests and builds the Apple Silicon app bundle on macOS.
- [x] Existing Python CLI tests continue to run in their current matrix.

## Manual Mac checks

- [ ] Launch `dist/PhoneBackup.app` without a connected phone; observe the main
      window and the ADB recovery control.
- [ ] Select an executable fake or installed ADB; use **Change ADB…** to switch
      paths; verify an invalid selection leaves the previous working path saved.
- [ ] Verify the app starts and opens the offline Backups view without ADB.
- [ ] Verify Activity contains only the current session and does not show paths,
      serial numbers, or raw transport error details.
- [ ] Check basic keyboard focus and VoiceOver names for the sidebar, folder
      navigation, review controls, and operation cancellation.
- [ ] Check light and dark macOS appearance.

## Manual phone checks — requires a user-selected disposable folder

Before starting, record the exact selected Android folder and create harmless
fixture files there. Do not browse or test outside that folder. Use a new local
repository and export directory, then compare SHA-256 hashes independently.

- [ ] Browse the selected folder and confirm that opening it lists only its
      immediate children.
- [ ] Back up the selected folder, make a fixture-only change, back up again,
      and confirm both restore points remain available.
- [ ] Export selected data to a new Mac folder and verify hashes.
- [ ] Copy one fixture in each direction and verify hashes.
- [ ] Restore a selected fixture to its original path and to a separate folder;
      confirm replacement requires a checked approval.
- [ ] Cancel a transfer and disconnect/reconnect during a disposable transfer;
      confirm incomplete operations are reported and recovery is clear.
- [ ] Test a folder Android denies, if one exists within the chosen test area;
      confirm denial is shown without scanning neighboring folders.
- [ ] Try Finder promises and drops with one fixture file and one empty folder.

Record the selected folder, app build, observed outcomes, and any skipped check
without recording fixture contents. Permission-denied behavior, external-volume
reconnects, Finder promise behavior, accessibility, and appearance are device
and Mac dependent; do not claim them tested until observed.

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

- [ ] Launch `dist/Androdo.app` without a connected phone; observe the main
      window and the ADB recovery control.
- [ ] Open Connection Setup and verify the existing ADB path is shown when
      found. Discovery checks only known SDK/Homebrew/managed paths and absolute
      `PATH` entries; it does not recursively search the Mac.
- [ ] In Connection Setup, review the numbered Developer options, USB debugging,
      USB cable, and trust steps. Follow the Google help links and confirm that
      device-specific settings paths are described as variable.
- [ ] Verify the guide explains why ADB needs debugging and that the Mac should
      be trusted, without implying Android restricts ADB itself to selected files.
- [ ] Check the guide’s status copy with no phone, an unauthorized phone, an
      offline phone, and an authorized phone. Opening the guide must not run
      device discovery or browse folders.
- [ ] With ADB installed, verify Connection Setup has distinct USB and Wi-Fi
      guides. Pairing uses the phone’s temporary pairing endpoint and code;
      connecting uses the separate Wireless debugging endpoint and works for an
      already-paired phone without a code.
- [ ] Verify the Wi-Fi guide explains same-network setup, persistent pairing
      and revocation, and that Androdo does not run its own network scan. Confirm
      the bundle declares Local Network access and the ADB mDNS service types.
- [ ] On macOS 15 or later, allow Androdo on a fresh Local Network prompt. Also try a denied
      permission and confirm the guide points to System Settings → Privacy &
      Security → Local Network without treating every timeout as a denial.
- [ ] Pair/connect without opening File Explorer. Confirm no folder listing or
      phone-content command runs during pairing or identity verification. Then
      open File Explorer and verify **Open Shared Storage** is explicit.
- [ ] If USB and Wi-Fi are both active for one phone, confirm Androdo shows one
      device and indicates USB is preferred; unplug USB and refresh to verify
      the wireless route remains selected.
- [ ] In File Explorer with no authorized phone, verify Connection Setup opens
      the same in-app guide and the direct Developer options link opens Google’s
      documentation.
- [ ] Verify **Install Platform Tools** stays disabled until the unchecked
      Google SDK terms agreement is selected, and that the managed destination
      is visible before starting.
- [ ] During a local install, observe download progress and confirm the progress
      window can be backgrounded and reopened. Cancel before publication and
      verify an existing configured ADB path remains selected.
- [ ] Complete an install and verify the old Android Studio/Homebrew/manual
      ADB file remains in place. Confirm Androdo waits for **Check Again**
      before enumerating connected devices.
- [ ] Simulate an unavailable network or failed install and verify the error is
      shown in progress details while the previous ADB setup still works.
- [ ] Select an executable fake or installed ADB; use **Locate Another ADB…** to switch
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

## ADB setup and control polish

- [ ] App menu, About, Finder bundle, alerts, and Settings use Androdo.
- [ ] App name/emblem appears in the native toolbar; no detached sidebar banner.
- [ ] Main actions, review sheets, Settings, and file actions use consistent larger native controls.
- [ ] With no ADB configured, Overview and the sidebar open the same guided setup.
- [ ] Setup links to Google's Platform Tools/USB-debugging documentation and can copy the Homebrew command.
- [ ] Setup, Overview’s contextual connection action, and disconnected File Explorer state give a direct route to the phone guide.
- [ ] Inspect the guide in light/dark appearance and compact sheet size; its numbered steps, external links, Escape dismissal, keyboard focus, and VoiceOver names remain clear.
- [ ] The app-owned Platform Tools copy is stored under `~/Library/Application Support/Androdo/Platform Tools`; custom locations work through Locate ADB.
- [ ] After installing outside the app, Check Again discovers ADB; after an in-app install it waits for the same explicit Check Again action.
- [ ] Discovery failure remains visible inside the guide, even without the main window.

## Phone-trial UX regression checks

- [ ] A successful backup shows **Backup complete**, never a generic attention heading.
- [ ] Warnings/failures expose a reason and bounded details; interrupted backups explain saved progress and Resume.
- [ ] Phone Files opens folders from a full-row double-click or Return; rapid navigation, Back/Forward, Refresh and Cancel preserve the displayed path/rows.
- [ ] Copy/drop cannot target stale rows while a folder is loading; folder failures remain visible after leaving/returning.
- [ ] Backup scope uses Include/Exclude with a visible scope list; Cancel discards and Done applies for the original phone only.
- [ ] Changing/disconnecting phones while the scope sheet is open cannot apply its draft to another phone.
- [ ] Saved Backups is clearly a saved copy; saved-file loading failures differ from an empty snapshot.
- [ ] Recent Operations is secondary in the toolbar, with session-only summaries and clear-finished behavior.

Automated fixture checks cover the state transitions, but actual USB latency,
Finder drops/promises and interactive keyboard/VoiceOver behavior still require
manual acceptance. Keep phone checks inside the user-selected test area.

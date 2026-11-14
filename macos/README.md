# Native macOS app

Androdo is a SwiftUI macOS app for selective Android shared-file backups,
verified restore, and direct file copy. It is a separate native app from the
Python command-line tools documented in the root README. It does not back up
Android app-private data, apps, settings, or the operating system.

## Requirements

- Apple Silicon Mac running macOS 14 or later.
- Full Xcode with its command-line tools selected (`xcode-select -p`).
- Android Platform Tools can be installed from Androdo after agreeing to
  Google’s Android SDK License Agreement. Androdo does not bundle ADB.

## Build and run from source

```sh
swift --version
swift test
swift run Androdo
```

To build a local, ad-hoc-signed app bundle for Apple Silicon:

```sh
macos/build-app.sh
open dist/Androdo.app
```

The script builds the SwiftPM executable for `arm64-apple-macosx14.0`, packages
only that executable and the app's `Info.plist`, and verifies its ad-hoc
signature. It compiles the shared folded-A vector geometry into an original app icon locally. It replaces only `dist/Androdo.app`. It does not copy ADB,
Python sources, backup repositories, or phone files into the bundle. The
generated `dist/` directory is ignored by Git.

This local build is not notarized or intended for distribution. If macOS blocks
launching a copied app, build it on the target Mac or use the source launch
command above. Notarization, installer packaging, and ADB redistribution are
outside v1.

## Set up ADB

Androdo checks a saved executable path, its own managed Platform Tools folder,
`ANDROID_HOME`/`ANDROID_SDK_ROOT`, the standard Android SDK folder, common
Homebrew locations and absolute entries in the current `PATH`. It does not
search the whole Mac. **Set Up Connection…** in Overview offers to install the
current macOS Platform Tools directly from Google after you review and agree to
Google’s Android SDK License Agreement. Android Studio is not required.

The app-owned copy is stored at `~/Library/Application Support/Androdo/Platform
Tools`. Existing Android Studio, Homebrew and manually selected copies remain
untouched. Androdo stages and verifies the downloaded archive and ADB executable
before activating the new copy. Cancel or a failed install leaves the previous
managed version in place. Installation does not enumerate devices or open
phone folders; after it finishes, choose **Check Again** when you want Androdo
to look for your phone.

You can also download Platform Tools for Mac from Google, unzip it into a
permanent folder, then choose **Locate ADB…** and select `platform-tools/adb`.
If you already use Homebrew, the guide can copy this command for you to run in
Terminal:

```sh
brew install --cask android-platform-tools
```

**Check Again** discovers an installation and enumerates connected devices
without restarting the app. For a custom location, use **Locate ADB…**. The
guide remains available under **Androdo → Settings… → Connection Setup…**. It
does not run Homebrew. The app remembers a selected executable's path.

Connection Setup includes a numbered USB guide and, with ADB available, a
separate Wi-Fi guide for Android 11 or later. For Wi-Fi, pair using the address,
port, and temporary code from Android’s **Pair new device** screen. Then use the
different address/port shown on the main **Wireless debugging** screen to
connect. A phone already paired with this Mac can connect without entering a
code again. Both devices must be on the same trusted network. Pairing remains
trusted until you remove this Mac from Android’s **Paired devices** list.

On macOS 15 or later, macOS may ask to allow local-network access. If you
denied it, enable Androdo under **System Settings → Privacy & Security → Local
Network**. Androdo’s Connect action uses the address you enter and does not run
its own network scan. ADB itself may automatically discover or reconnect phones
already paired with this Mac.
When USB and Wi-Fi are both active, Androdo recognizes one phone and prefers
USB for transfers; unplug USB to use Wi-Fi.

The USB guide links to Google’s [Developer options instructions](https://developer.android.com/studio/debug/dev-options#enable)
and [ADB authorization help](https://developer.android.com/tools/adb#Enabling).
USB debugging gives an authorized computer an ADB command connection to
Android. Device discovery reads only identity information; it does not browse
phone folders. Connecting never opens shared storage automatically. In File
Explorer, choose **Open Shared Storage** when you are ready to list that folder.
Saved backups remain accessible offline.

The stable bundle identifier and internal repository directory (`PhoneBackup`)
are retained so the display-name change preserves existing preferences and
backup locations. Source module names and Python CLI commands are unchanged.

## First use

Choose a local or external folder for the app-managed backup repository. The
repository contains immutable restore points and is not a Finder mirror of the
latest phone files. Select the phone folders you want, review the size and
scope, then confirm **Back Up…**. The app verifies copied bytes before it
marks files complete.

Use **File Explorer** for live browsing and direct copies. Back/Forward can reuse
visited folder listings; **Refresh** checks the phone again. Cached metadata is
kept only in memory and is invalidated on connection/transport changes and
phone-writing operations.

Use **Saved Backups** to browse local restore points independently of the
connected phone. Snapshot contents are explicitly labeled as a saved copy.

For direct copies, Mac-to-phone drops and button copies show a
destination review first. Phone-to-Mac copies can be sent to a chosen folder or
dragged to Finder; a Finder drop begins the transfer and completes after byte
verification. Restoring a restore point can target its original Android paths,
a chosen phone folder, or a chosen Mac folder. Each existing destination item
must be explicitly approved for replacement.

**Recent Operations** (the toolbar clock button) shows summaries for the current app session. They contain counts
and outcomes, not phone paths, serial numbers, or raw ADB errors. Backup
recovery attempts are stored in the repository so they remain available after
reopening the app.

## Checks

```sh
swift test
macos/build-app.sh
python3 -m pytest -q
```

See [ACCEPTANCE.md](ACCEPTANCE.md) for automated and phone checks. Automated
tests use fakes and temporary local folders; they do not require or enumerate a
connected phone.

## Visual design preview

A standalone Overview composition uses fictional device/folder names and never
creates an AppModel, opens a repository, or connects to a phone:

```sh
swiftc -parse-as-library Sources/PhoneBackupUI/AndrodoMarkGeometry.swift Sources/PhoneBackupUI/PhoneBackupIdentity.swift Sources/PhoneBackupUI/DeviceBackupHero.swift macos/RenderDesignPreview.swift -o /private/tmp/phonebackup-design-preview
/private/tmp/phonebackup-design-preview /private/tmp/phonebackup-overview-light.png
/private/tmp/phonebackup-design-preview /private/tmp/phonebackup-overview-dark.png --dark
```

These are composition previews, not screenshots or interactive acceptance of
the running app. Settings displays the packaged Git revision; a `-modified`
suffix means it was built with uncommitted source changes.

The implemented full native window can also be captured with isolated fictional
fixtures; see [the native fixture renderer](design/README.md#capture-the-implemented-native-window-with-fictional-data).
The folded-A glyph and Dock icon share `AndrodoMarkGeometry.swift`. Overview's
latest-complete-backup summary belongs to the displayed device, independently
of the repository selected in the backup library.

To choose future backup scope, open **Included files → Choose…**. Highlight rows
in the phone browser and use **Include Selected** or **Exclude Selected**; the
right-hand scope list shows what will be saved. **Done** applies that draft and
**Cancel** discards it. The editor is bound to the phone it was opened for.
The advanced **All shared files** mode retains custom roots and exclusions when
switching modes; removing a parent exclusion is always explicit.

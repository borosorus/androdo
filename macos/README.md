# Native macOS app

Androdo is a SwiftUI macOS app for selective Android shared-file backups,
verified restore, and direct file copy. It is a separate native app from the
Python command-line tools documented in the root README. It does not back up
Android app-private data, apps, settings, or the operating system.

## Requirements

- Apple Silicon Mac running macOS 14 or later.
- Full Xcode with its command-line tools selected (`xcode-select -p`).
- Android Platform Tools installed separately. On this Mac, `brew install --cask
  android-platform-tools` installs ADB. Androdo does not bundle ADB.

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

Androdo checks common Android SDK and Homebrew locations and the current
`PATH`. **Set Up Connection…** in Overview opens a guide explaining ADB,
Google’s [Platform Tools download](https://developer.android.com/tools/releases/platform-tools),
and USB debugging/authorization. Android Studio is not required.

Download Platform Tools for Mac from Google, unzip it into a permanent folder,
then choose **Locate ADB…** and select `platform-tools/adb`. If you already use
Homebrew, the guide can copy this command for you to run in Terminal:

```sh
brew install --cask android-platform-tools
```

**Check Again** searches for a new installation without restarting the app.
For a custom location, use **Locate ADB…**. The guide remains available under
**Androdo → Settings… → Connection Setup…**. It does not run installers or
Homebrew itself. The app remembers a selected executable's path.

Enable Developer options and USB debugging on the phone, connect it by USB,
and accept its authorization prompt for this Mac. Discovery and Check Again
only enumerate connected devices; folder contents are listed after you open
a folder. Saved backups remain accessible offline.

The stable bundle identifier and internal repository directory (`PhoneBackup`)
are retained so the display-name change preserves existing preferences and
backup locations. Source module names and Python CLI commands are unchanged.

## First use

Choose a local or external folder for the app-managed backup repository. The
repository contains immutable restore points and is not a Finder mirror of the
latest phone files. Select the phone folders you want, review the size and
scope, then confirm **Back Up…**. The app verifies copied bytes before it
marks files complete.

Use **Files** for direct copies. Mac-to-phone drops and button copies show a
destination review first. Phone-to-Mac copies can be sent to a chosen folder or
dragged to Finder; a Finder drop begins the transfer and completes after byte
verification. Restoring a restore point can target its original Android paths,
a chosen phone folder, or a chosen Mac folder. Each existing destination item
must be explicitly approved for replacement.

Activity summaries last only for the current app session. They contain counts
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

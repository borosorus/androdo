# Native macOS app

PhoneBackup is a SwiftUI macOS app for selective Android shared-file backups,
verified restore, and direct file copy. It is a separate native app from the
Python command-line tools documented in the root README. It does not back up
Android app-private data, apps, settings, or the operating system.

## Requirements

- Apple Silicon Mac running macOS 14 or later.
- Full Xcode with its command-line tools selected (`xcode-select -p`).
- Android Platform Tools installed separately. On this Mac, `brew install
  android-platform-tools` installs ADB. PhoneBackup does not bundle ADB.

## Build and run from source

```sh
swift --version
swift test
swift run PhoneBackupApp
```

To build a local, ad-hoc-signed app bundle for Apple Silicon:

```sh
macos/build-app.sh
open dist/PhoneBackup.app
```

The script builds the SwiftPM executable for `arm64-apple-macosx14.0`, packages
only that executable and the app's `Info.plist`, and verifies its ad-hoc
signature. It replaces only `dist/PhoneBackup.app`. It does not copy ADB,
Python sources, backup repositories, or phone files into the bundle. The
generated `dist/` directory is ignored by Git.

This local build is not notarized or intended for distribution. If macOS blocks
launching a copied app, build it on the target Mac or use the source launch
command above. Notarization, installer packaging, and ADB redistribution are
outside v1.

## Set up ADB

PhoneBackup checks common Android SDK and Homebrew locations and the current
`PATH`. If it cannot find ADB, select **Locate ADB…** in the app and choose the
`adb` executable, commonly:

```text
/opt/homebrew/bin/adb
```

The app remembers that path. If ADB moves or stops working, use **Change ADB…**
to choose its current location. To confirm the phone connection independently,
run `adb devices -l`, unlock the phone, and accept Android's USB debugging
prompt. Device discovery does not enumerate phone folders; folder contents are
listed only after you open a folder in the app.

## First use

Choose a local or external folder for the app-managed backup repository. The
repository contains immutable restore points and is not a Finder mirror of the
latest phone files. Select the phone folders you want, review the size and
scope, then confirm **Back Up Now**. The app verifies copied bytes before it
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

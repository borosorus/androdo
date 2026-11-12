# PhoneBackup / Bestest ADB Sync

[![tests](https://github.com/BuildWithDuke/bestest-adb-sync/actions/workflows/tests.yml/badge.svg)](https://github.com/BuildWithDuke/bestest-adb-sync/actions/workflows/tests.yml)

An Android backup CLI and an [rsync](https://wiki.archlinux.org/title/rsync)-like program to sync files between a computer and an Android device

> **This is a modified fork.**
> It is based on [jb2170/better-adb-sync](https://github.com/jb2170/better-adb-sync)
> (Apache License 2.0), which has been unmaintained since September 2023. The
> files in `src/BestestADBSync/` have been changed from the upstream versions;
> see [What this fork changes](#what-this-fork-changes) below.
> Upstream in turn is a rewrite of Google's [adb-sync](https://github.com/google/adb-sync).

## What this fork changes

**Sync compares file size, not just mtime.** Upstream decides a file is already
synced using `source_mtime > destination_mtime` alone, having parsed the size
from `ls` and then discarded it. This silently corrupts archives: an interrupted
transfer leaves a truncated file whose mtime is the moment it was written, which
is *newer* than the source, so it is never re-fetched and stays truncated
forever. Fixes upstream issues
[#23](https://github.com/jb2170/better-adb-sync/issues/23) and
[#32](https://github.com/jb2170/better-adb-sync/issues/32).

**File metadata is read with one device-side `find`** rather than a recursive
per-directory `ls -la` walk:

- `-printf %T@` yields a real epoch timestamp, so mtimes no longer depend on
  parsing the device's *rendering* of a date in the host's timezone, no longer
  truncate to the minute ([#48](https://github.com/jb2170/better-adb-sync/issues/48)),
  and no longer break on files older than six months
  ([#54](https://github.com/jb2170/better-adb-sync/issues/54))
- NUL-separated records keep filenames containing newlines intact
  ([#56](https://github.com/jb2170/better-adb-sync/issues/56))
- one round trip replaces one per directory

Devices whose `find` lacks `-printf` fall back to the previous `ls` parsing. A
per-filesystem `mtime_precision` feeds a comparison tolerance, so that path's
minute resolution does not make every file look perpetually stale.

Also fixed:

- device output is decoded with `surrogateescape`, so filenames that are not
  valid in the chosen encoding no longer raise `UnicodeDecodeError`
  ([#42](https://github.com/jb2170/better-adb-sync/issues/42),
  [#44](https://github.com/jb2170/better-adb-sync/issues/44),
  [#51](https://github.com/jb2170/better-adb-sync/issues/51))
- a failed constructor no longer masks its own error with `AttributeError`
  during teardown ([#43](https://github.com/jb2170/better-adb-sync/issues/43))
- one unparseable `ls` entry is skipped with a warning instead of aborting the
  entire sync ([#53](https://github.com/jb2170/better-adb-sync/issues/53))
- seconds are preserved when restoring mtimes on the device

There is a test suite; none of it requires a connected device:

```
$ pip install -e '.[dev]'
$ pytest
```

It runs in CI against Python 3.8 through 3.13 on Linux, and 3.12 on macOS.

## Installation

From source:

```
$ git clone https://github.com/BuildWithDuke/bestest-adb-sync
$ cd bestest-adb-sync
$ pip install .
```

Note that `pip install BetterADBSync` installs **upstream** from
[PyPI](https://pypi.org/project/BetterADBSync/), not this fork.

For a command-line install, `pipx install .` installs the `phonebackup` and
`adbsync` commands in isolated environments. The project also works with
`pip install .`. Install Android Platform Tools separately and make sure `adb`
is available on `PATH`; on macOS with Homebrew this is `brew install
android-platform-tools`.

### macOS development and device checks

From the repository directory, create an isolated development environment:

```sh
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -e '.[dev]'
python -m pytest -q
adbsync --version
phonebackup --help
adb version
```

The tests use a fake ADB executable and temporary local directories; they do
not need or access a phone. They cover backup updates, history, restore,
interrupted transfers, locking, and local integrity verification.

For a first device check, enable USB debugging on Android, connect a data-capable
USB cable, unlock the phone, and accept its debugging authorization prompt.
`adb devices -l` should list it with state `device`. Start by listing paths and
backing up one small, known folder (replace `Documents` below with that folder):

```sh
adb devices -l
phonebackup paths --format json
phonebackup new "$HOME/PhoneBackupTrial" --include Documents
phonebackup verify "$HOME/PhoneBackupTrial"
phonebackup diff "$HOME/PhoneBackupTrial"
phonebackup update "$HOME/PhoneBackupTrial"
phonebackup status "$HOME/PhoneBackupTrial"
```

Use a new or empty destination for `new`. An unchanged phone should produce
no planned transfers in `diff`, and `update` should skip unchanged files.
Then change a disposable test file on the phone and run `update`, `history`,
and `verify` to check version retention. These commands read from the phone;
restoring to the phone is a separate, explicit operation. With multiple devices,
add `--device SERIAL` to each `phonebackup` command.

Most Mac volumes are case-insensitive. Backup scans reject Android paths that
differ only in case or Unicode normalization rather than merge their contents.
The current macOS check is conservative even on case-sensitive volumes.
Test the actual destination volume too if you plan to use an external drive:
its filesystem can have different locking, hard-link, and durability behavior.

## Android backups with `phonebackup`

`phonebackup` creates a one-way, non-destructive backup of files that standard
ADB can read from shared storage. It does not need root or an Android-side app,
and it cannot back up protected app-private data. A new backup copies the
contents of `/sdcard/` into the destination directory. Hidden files and
directories are included. The destination may be on an external drive.

```sh
phonebackup new /Volumes/ExternalSSD/MyAndroid
phonebackup update /Volumes/ExternalSSD/MyAndroid
phonebackup diff /Volumes/ExternalSSD/MyAndroid
phonebackup paths --format json
phonebackup history /Volumes/ExternalSSD/MyAndroid
phonebackup prune-history /Volumes/ExternalSSD/MyAndroid --version VERSION_ID
phonebackup verify /Volumes/ExternalSSD/MyAndroid
phonebackup status /Volumes/ExternalSSD/MyAndroid
```

`new` refuses to reuse a non-empty destination as a backup. `update` adds new
files and replaces changed ones, while leaving files that have disappeared
from the phone in the backup. `diff` previews the planned transfers without
changing the backup. `verify` checks files on the computer against the backup
manifest; it is a local integrity check and does not compare file contents
against the live phone. `status` summarizes the last attempt, last completed
backup, file/byte totals, and any recorded failures or incomplete operation.

Backup transfers use temporary files in the destination and replace a prior
copy only after the transfer succeeds and its size is checked. If a run is
interrupted, run `phonebackup update` again to retry incomplete or stale files.
The hidden `.phonebackup-manifest.json` in the backup root records completed
files, hashes, and any transfer that was interrupted. The adjacent hidden
`.phonebackup-journal.jsonl` records small durable updates while a command is
running; together they are the authoritative metadata until the command
checkpoints the JSON manifest and clears the journal. A destination file that
is not tracked by that metadata is preserved and reported as a conflict.
Existing backups are upgraded to the journal-aware manifest format on their
first write; older PhoneBackup builds will reject that upgraded format rather
than read a stale checkpoint.
The journal avoids rewriting the full manifest for every file. It still syncs
each durable transfer step, and restarting a large interrupted run requires
replaying its journal.
If a crash leaves an unverified partial file at a destination path, move that
file aside before retrying; PhoneBackup reports the conflict instead of
guessing that the file belongs to the backup.
PhoneBackup also keeps a hidden `.phonebackup.lock` file so overlapping
operations cannot race on the same backup; leave it in place.
File size and modification time are used for efficient incremental decisions;
files with equal size and close timestamps can still differ in content. Use
`verify` for local SHA-256 checks where hashes are present. Standard ADB
permissions and Android's changing shared-storage behavior can make some
entries inaccessible; a partial scan or failed transfer must be treated as an
incomplete backup.

#### Selecting what to back up

By default, `new` backs up everything readable under `/sdcard`, including
hidden files. Pass one or more relative Android paths with `--include` to limit
the initial backup. Including a directory includes its contents. `--exclude`
accepts relative glob patterns; exclusions take precedence over includes.

```sh
phonebackup new /backups/my-phone \
  --include DCIM \
  --include Documents \
  --exclude 'DCIM/Thumbnails/**'
```

The manifest stores the selection. A plain `update` reuses it. Supplying
`--include` replaces the saved include list, and supplying `--exclude` replaces
the saved exclude list; a category you omit keeps its saved value. Use
`--all` to clear both lists and select everything again. Newly requested paths
must exist and be readable. If a path from the saved selection later
disappears, updates keep its previous backup files and `diff` reports them as
preserved.

`diff` accepts the same selection flags to preview a different scope without
saving that scope. It reports previously backed-up files as preserved when
they are missing from the phone or outside the current selection. Changing the
selection does not remove prior files from the backup.

`phonebackup paths` lists files and folders visible under the source root
without creating a backup or writing metadata. Text output is intended for
people; `--format json` returns the source root and sorted entries with path,
type, size, and modification time for scripts and future UI code. JSON includes
a `warnings` list when some entries could not be listed.

When an update replaces a tracked file with different content, PhoneBackup
copies the old local bytes into the hidden `.phonebackup-history/` area and
records a version ID in the manifest. The normal file remains at its usual
path, so the latest copy stays directly browsable. History is per-file rather
than a whole-backup snapshot, and versions are kept until the user removes
them. There is no automatic pruning. `verify` checks historical blobs as well
as current files.

`prune-history` removes only explicitly selected historical version IDs. It
prints a preview by default; add `--apply` after reviewing the selected IDs and
space estimate to change the manifest and delete unreferenced history files.
If another retained version uses the same stored content, that file stays in
place. Missing blobs can be removed from history metadata without counting as
reclaimed disk space. If a filesystem error interrupts blob deletion, repeat
the exact command shown by `phonebackup status` to finish the recorded cleanup.

```sh
phonebackup prune-history /Volumes/ExternalSSD/MyAndroid --version VERSION_ID
phonebackup prune-history /Volumes/ExternalSSD/MyAndroid \
  --version VERSION_ID --version ANOTHER_ID --apply
```

Use `history` to list older versions, then `restore` to export a selected
current or historical file to the Mac, or explicitly put it back at its
original Android path:

```sh
phonebackup history /Volumes/ExternalSSD/MyAndroid Pictures/photo.jpg
phonebackup restore /Volumes/ExternalSSD/MyAndroid Pictures/photo.jpg \
  --version VERSION_ID --to-local ~/Desktop/photo-recovered.jpg
phonebackup restore /Volumes/ExternalSSD/MyAndroid Pictures/photo.jpg \
  --version VERSION_ID --to-phone --dry-run
phonebackup restore /Volumes/ExternalSSD/MyAndroid Pictures/photo.jpg \
  --version VERSION_ID --to-phone --overwrite
```

Omit `--version` to use the current backed-up file. Local export requires an
existing parent directory, is atomic, and refuses an existing destination
unless `--overwrite` is supplied. A no-overwrite export needs hard-link support
on the destination filesystem; if unavailable, it fails without leaving a
partial destination. Older manifests without a stored hash produce a warning:
the restore can check its copy against the current local bytes but cannot verify
those bytes against a historical hash baseline.

Phone restore also refuses to overwrite by default. It stages the file on the
device, then publishes it with an exclusive no-overwrite operation or an
explicit atomic replacement when `--overwrite` is given. If the device
filesystem does not support the exclusive operation, restore fails safely.
After publishing, it checks the remote size. Phone restore covers shared
storage files only, not applications or settings.

The transfer decision uses size and modification time, and checks a local
SHA-256 against the manifest when those metadata match. The tool hashes each
successful local transfer. ADB does not provide remote content hashes here,
so edits that preserve both size and timestamp may not be detected until a
future scan strategy can inspect remote content.

When more than one device is attached, select the intended device explicitly
with `--device SERIAL` (the serial is shown by `adb devices`). `--help` shows
the options available for the installed version.

The command-line interface is the current implementation target. A future UI
is expected to build on these selection and manifest rules so users can browse
paths, choose data, preview changes, and run or resume a backup. No UI is part
of the current CLI milestone.

### Legacy `adbsync`

The existing `adbsync` command remains available for direct two-way file
synchronization. Its `--del` option can delete destination files, unlike
`phonebackup update`, which never propagates phone-side deletions.

## QRD

To push from your computer to your phone use
```
$ adbsync push LOCAL ANDROID
```

To pull from your phone to your computer use
```
$ adbsync pull ANDROID LOCAL
```

Full help is available with `$ adbsync --help`

## Intro

This is a (pretty much from scratch) rewrite of Google's [adbsync](https://github.com/google/adb-sync) repo.

The reason for the rewrite is to

1. Update the repo to Python 3 codestyle (strings are by default UTF-8, no more b"" and u"", classes don't need to inherit from object, 4 space indentation etc)
2. Add in support for `--exclude`, `--exclude-from`, `--del`, `--delete-excluded` like `rsync` has (this required a complete rewrite of the diffing algorithm)

## Additions

- `--del` will delete files and folders on the destination end that are not present on the source end. This does not include exluded files.
- `--delete-excluded` will delete excluded files and folders on the destination end.
- `--exclude` can be used many times. Each should be a `fnmatch` pattern relative to the source. These patterns will be ignored unless `--delete-excluded` is specified.
- `--exclude-from` can be used many times. Each should be a filename of a file containing `fnmatch` patterns relative to the source.

## Possible future TODOs

I am satisfied with my code so far, however a few things could be added if they are ever needed

- `--backup` and `--backup-dir-local` or `--backup-dir-android` to move outdated / to-delete files to another folder instead of deleting

---

---BEGIN ORIGINAL README.md---

adb-sync
========

adb-sync is a tool to synchronize files between a PC and an Android device
using the ADB (Android Debug Bridge).

Related Projects
================

Before getting used to this, please review this list of projects that are
somehow related to adb-sync and may fulfill your needs better:

* [rsync](http://rsync.samba.org/) is a file synchronization tool for local
  (including FUSE) file systems or SSH connections. This can be used even with
  Android devices if rooted or using an app like
  [SSHelper](https://play.google.com/store/apps/details?id=com.arachnoid.sshelper).
* [adbfs](http://collectskin.com/adbfs/) is a FUSE file system that uses adb to
  communicate to the device. Requires a rooted device, though.
* [adbfs-rootless](https://github.com/spion/adbfs-rootless) is a fork of adbfs
  that requires no root on the device. Does not play very well with rsync.
* [go-mtpfs](https://github.com/hanwen/go-mtpfs) is a FUSE file system to
  connect to Android devices via MTP. Due to MTP's restrictions, only a certain
  set of file extensions is supported. To store unsupported files, just add
  .txt! Requires no USB debugging mode.

Setup
=====

Android Side
------------

First you need to enable USB debugging mode. This allows authorized computers
(on Android before 4.4.3 all computers) to perform possibly dangerous
operations on your device. If you do not accept this risk, do not proceed and
try using [go-mtpfs](https://github.com/hanwen/go-mtpfs) instead!

On your Android device:

* Go to the Settings app.
* If there is no "Developer Options" menu:
  * Select "About".
  * Tap "Build Number" seven times.
  * Go back.
* Go to "Developer Options".
* Enable "USB Debugging".

PC Side
-------

* Install the [Android SDK](http://developer.android.com/sdk/index.html) (the
  stand-alone Android SDK "for an existing IDE" is sufficient). Alternatively,
  some Linux distributions come with a package named like "android-tools-adb"
  that contains the required tool.
* Make sure "adb" is in your PATH. If you use a package from your Linux
  distribution, this should already be the case; if you used the SDK, you
  probably will have to add an entry to PATH in your ~/.profile file, log out
  and log back in.
* `git clone https://github.com/google/adb-sync`
* `cd adb-sync`
* Copy or symlink the adb-sync script somewhere in your PATH. For example:
  `cp adb-sync /usr/local/bin/`

Usage
=====

To get a full help, type:

```
adb-sync --help
```

To synchronize your music files from ~/Music to your device, type one of:

```
adb-sync ~/Music /sdcard
adb-sync ~/Music/ /sdcard/Music
```

To synchronize your music files from ~/Music to your device, deleting files you
removed from your PC, type one of:

```
adb-sync --delete ~/Music /sdcard
adb-sync --delete ~/Music/ /sdcard/Music
```

To copy all downloads from your device to your PC, type:

```
adb-sync --reverse /sdcard/Download/ ~/Downloads
```

ADB Channel
===========

This package also contains a separate tool called adb-channel, which is a
convenience wrapper to connect a networking socket on the Android device to
file descriptors on the PC side. It can even launch and shut down the given
application automatically!

It is best used as a `ProxyCommand` for SSH (install
[SSHelper](https://play.google.com/store/apps/details?id=com.arachnoid.sshelper)
first) using a configuration like:

```
Host sshelper
Port 2222
ProxyCommand adb-channel tcp:%p com.arachnoid.sshelper/.SSHelperActivity 1
```

After adding this to `~/.ssh/config`, run `ssh-copy-id sshelper`.

Congratulations! You can now use `rsync`, `sshfs` etc. to the host name
`sshelper`.

Contributing
============

Patches to this project are very welcome.

Before sending a patch or pull request, we ask you to fill out one of the
Contributor License Agreements:

* [Google Individual Contributor License Agreement, v1.1](https://developers.google.com/open-source/cla/individual)
* [Google Software Grant and Corporate Contributor License Agreement, v1.1](https://developers.google.com/open-source/cla/corporate)

Disclaimer
==========

This is not an official Google product.


---END ORIGINAL README.md---

---

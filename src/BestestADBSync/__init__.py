#!/usr/bin/env python3

"""Sync files between a computer and an Android device"""

__version__ = "1.4.0"

from typing import List, Tuple, Union
import logging
import os
import stat
import fnmatch

from .argparsing import get_cli_args
from .SAOLogging import logging_fatal, log_tree, setup_root_logger, perror, FATAL

from .FileSystems.Base import FileSystem
from .FileSystems.Local import LocalFileSystem
from .FileSystems.Android import AndroidFileSystem

class FileSyncer():
    @staticmethod
    def needs_copy(source: tuple, destination: tuple, mtime_tolerance: int = 0) -> bool:
        """Whether a source file must be recopied over the destination file.

        Size is checked as well as mtime. Comparing mtime alone means an
        interrupted transfer is never repaired: the truncated destination file
        carries the mtime of the moment it was written, which is *newer* than
        the source, so it looks up to date forever (issues #23, #32).

        mtime_tolerance absorbs the resolution of the coarser of the two
        filesystems, so a backend that only reports whole minutes does not make
        every file look perpetually stale.
        """
        size_source = source[2] if len(source) > 2 else None
        size_destination = destination[2] if len(destination) > 2 else None
        if size_source is not None and size_destination is not None and size_source != size_destination:
            return True
        return source[1] - destination[1] > mtime_tolerance

    @classmethod
    def diff_trees(cls,
        source: Union[dict, Tuple[int, int], None],
        destination: Union[dict, Tuple[int, int], None],
        path_source: str,
        path_destination: str,
        destination_exclude_patterns: List[str],
        path_join_function_source,
        path_join_function_destination,
        folder_file_overwrite_error: bool = True,
        mtime_tolerance: int = 0,
        ) -> Tuple[
            Union[dict, Tuple[int, int], None], # delete
            Union[dict, Tuple[int, int], None], # copy
            Union[dict, Tuple[int, int], None], # excluded_source
            Union[dict, Tuple[int, int], None], # unaccounted_destination
            Union[dict, Tuple[int, int], None]  # excluded_destination
        ]:

        exclude = False
        for destination_exclude_pattern in destination_exclude_patterns:
            if fnmatch.fnmatch(path_destination, destination_exclude_pattern):
                exclude = True
                break

        if source is None:
            if destination is None:
                delete = None
                copy = None
                excluded_source = None
                unaccounted_destination = None
                excluded_destination = None
            elif isinstance(destination, tuple):
                if exclude:
                    delete = None
                    copy = None
                    excluded_source = None
                    unaccounted_destination = None
                    excluded_destination = destination
                else:
                    delete = None
                    copy = None
                    excluded_source = None
                    unaccounted_destination = destination
                    excluded_destination = None
            elif isinstance(destination, dict):
                if exclude:
                    delete = {".": None}
                    copy = None
                    excluded_source = None
                    unaccounted_destination = {".": None}
                    excluded_destination = destination
                else:
                    delete = {".": None}
                    copy = None
                    excluded_source = None
                    unaccounted_destination = {".": destination["."]}
                    excluded_destination = {".": None}
                    destination.pop(".")
                    for key, value in destination.items():
                        delete[key], _, _, unaccounted_destination[key], excluded_destination[key] = cls.diff_trees(
                            None,
                            value,
                            path_join_function_source(path_source, key),
                            path_join_function_destination(path_destination, key),
                            destination_exclude_patterns,
                            path_join_function_source,
                            path_join_function_destination,
                            folder_file_overwrite_error = folder_file_overwrite_error,
                            mtime_tolerance = mtime_tolerance
                        )
            else:
                raise NotImplementedError

        elif isinstance(source, tuple):
            if destination is None:
                if exclude:
                    delete = None
                    copy = None
                    excluded_source = source
                    unaccounted_destination = None
                    excluded_destination = None
                else:
                    delete = None
                    copy = source
                    excluded_source = None
                    unaccounted_destination = None
                    excluded_destination = None
            elif isinstance(destination, tuple):
                if exclude:
                    delete = None
                    copy = None
                    excluded_source = source
                    unaccounted_destination = None
                    excluded_destination = destination
                else:
                    if cls.needs_copy(source, destination, mtime_tolerance):
                        delete = destination
                        copy = source
                        excluded_source = None
                        unaccounted_destination = None
                        excluded_destination = None
                    else:
                        delete = None
                        copy = None
                        excluded_source = None
                        unaccounted_destination = None
                        excluded_destination = None
            elif isinstance(destination, dict):
                if exclude:
                    delete = {".": None}
                    copy = None
                    excluded_source = source
                    unaccounted_destination = {".": None}
                    excluded_destination = destination
                else:
                    delete = destination
                    copy = source
                    excluded_source = None
                    unaccounted_destination = {".": None}
                    excluded_destination = {".": None}
                    if folder_file_overwrite_error:
                        logging.critical(f"Refusing to overwrite directory {path_destination} with file {path_source}")
                        logging_fatal("Use --force if you are sure!")
                    else:
                        logging.warning(f"Overwriting directory {path_destination} with file {path_source}")
            else:
                raise NotImplementedError

        elif isinstance(source, dict):
            if destination is None:
                if exclude:
                    delete = None
                    copy = {".": None}
                    excluded_source = source
                    unaccounted_destination = None
                    excluded_destination = None
                else:
                    delete = None
                    copy = {".": source["."]}
                    excluded_source = {".": None}
                    unaccounted_destination = None
                    excluded_destination = None
                    source.pop(".")
                    for key, value in source.items():
                        _, copy[key], excluded_source[key], _, _ = cls.diff_trees(
                            value,
                            None,
                            path_join_function_source(path_source, key),
                            path_join_function_destination(path_destination, key),
                            destination_exclude_patterns,
                            path_join_function_source,
                            path_join_function_destination,
                            folder_file_overwrite_error = folder_file_overwrite_error,
                            mtime_tolerance = mtime_tolerance
                        )
            elif isinstance(destination, tuple):
                if exclude:
                    delete = None
                    copy = {".": None}
                    excluded_source = source
                    unaccounted_destination = None
                    excluded_destination = destination
                else:
                    delete = destination
                    copy = {".": source["."]}
                    excluded_source = {".": None}
                    unaccounted_destination = None
                    excluded_destination = None
                    source.pop(".")
                    for key, value in source.items():
                        _, copy[key], excluded_source[key], _, _ = cls.diff_trees(
                            value,
                            None,
                            path_join_function_source(path_source, key),
                            path_join_function_destination(path_destination, key),
                            destination_exclude_patterns,
                            path_join_function_source,
                            path_join_function_destination,
                            folder_file_overwrite_error = folder_file_overwrite_error,
                            mtime_tolerance = mtime_tolerance
                        )
                    if folder_file_overwrite_error:
                        logging.critical(f"Refusing to overwrite file {path_destination} with directory {path_source}")
                        logging_fatal("Use --force if you are sure!")
                    else:
                        logging.warning(f"Overwriting file {path_destination} with directory {path_source}")
                excluded_destination = None
            elif isinstance(destination, dict):
                if exclude:
                    delete = {".": None}
                    copy = {".": None}
                    excluded_source = source
                    unaccounted_destination = {".": None}
                    excluded_destination = destination
                else:
                    delete = {".": None}
                    copy = {".": None}
                    excluded_source = {".": None}
                    unaccounted_destination = {".": None}
                    excluded_destination = {".": None}
                    source.pop(".")
                    for key, value in source.items():
                        delete[key], copy[key], excluded_source[key], unaccounted_destination[key], excluded_destination[key] = cls.diff_trees(
                            value,
                            destination.pop(key, None),
                            path_join_function_source(path_source, key),
                            path_join_function_destination(path_destination, key),
                            destination_exclude_patterns,
                            path_join_function_source,
                            path_join_function_destination,
                            folder_file_overwrite_error = folder_file_overwrite_error,
                            mtime_tolerance = mtime_tolerance
                        )
                    destination.pop(".")
                    for key, value in destination.items():
                        delete[key], _, _, unaccounted_destination[key], excluded_destination[key] = cls.diff_trees(
                            None,
                            value,
                            path_join_function_source(path_source, key),
                            path_join_function_destination(path_destination, key),
                            destination_exclude_patterns,
                            path_join_function_source,
                            path_join_function_destination,
                            folder_file_overwrite_error = folder_file_overwrite_error,
                            mtime_tolerance = mtime_tolerance
                        )
            else:
                raise NotImplementedError

        else:
            raise NotImplementedError

        return delete, copy, excluded_source, unaccounted_destination, excluded_destination

    @classmethod
    def remove_excluded_folders_from_unaccounted_tree(cls, unaccounted: Union[dict, Tuple[int, int]], excluded: Union[dict, None]) -> dict:
        # For when we have --del but not --delete-excluded selected; we do not want to delete unaccounted folders that are the
        # parent of excluded items. At the point in the program that this function is called at either
        # 1) unaccounted is a tuple (file) and excluded is None
        # 2) unaccounted is a dict and excluded is a dict or None
        # trees passed to this function are already pruned; empty dictionary (sub)trees don't exist
        if excluded is None:
            return unaccounted
        else:
            unaccounted_non_excluded = {}
            for unaccounted_key, unaccounted_value in unaccounted.items():
                if unaccounted_key == ".":
                    continue
                unaccounted_non_excluded[unaccounted_key] = cls.remove_excluded_folders_from_unaccounted_tree(
                    unaccounted_value,
                    excluded.get(unaccounted_key, None)
                )
            return unaccounted_non_excluded

    @classmethod
    def prune_tree(cls, tree):
        """Remove all Nones from a tree. May return None if tree is None however."""
        if not isinstance(tree, dict):
            return tree
        else:
            return_dict = {}
            for key, value in tree.items():
                value_pruned = cls.prune_tree(value)
                if value_pruned is not None:
                    return_dict[key] = value_pruned
            return return_dict or None

    @classmethod
    def sort_tree(cls, tree):
        if not isinstance(tree, dict):
            return tree
        return {
            k: cls.sort_tree(v)
            for k, v in sorted(tree.items())
        }

    @classmethod
    def paths_to_fixed_destination_paths(cls,
        path_source: str,
        fs_source: FileSystem,
        path_destination: str,
        fs_destination: FileSystem
    ) -> Tuple[str, str]:
        """Modify sync paths according to how a trailing slash on the source path should be treated"""
        # TODO I'm not exactly sure if this covers source and destination being symlinks (lstat vs stat etc)
        # we only need to consider when the destination is a directory
        try:
            lstat_destination = fs_destination.lstat(path_destination)
        except FileNotFoundError:
            return path_source, path_destination
        except (NotADirectoryError, PermissionError) as e:
            perror(path_source, e, FATAL)

        if stat.S_ISLNK(lstat_destination.st_mode):
            logging_fatal("Destination is a symlink. Not sure what to do. See GitHub issue #8")

        if not stat.S_ISDIR(lstat_destination.st_mode):
            return path_source, path_destination

        # we know the destination is a directory at this point
        try:
            lstat_source = fs_source.lstat(path_source)
        except FileNotFoundError:
            return path_source, path_destination
        except (NotADirectoryError, PermissionError) as e:
            perror(path_source, e, FATAL)

        if stat.S_ISREG(lstat_source.st_mode) or (stat.S_ISDIR(lstat_source.st_mode) and path_source[-1] not in ["/", "\\"]):
            path_destination = fs_destination.join(
                path_destination,
                fs_destination.split(path_source)[1]
            )
        return path_source, path_destination

def main():
    args = get_cli_args(__doc__, __version__)

    setup_root_logger(
        no_color = args.logging_no_color,
        verbosity_level = args.logging_verbosity_verbose,
        quietness_level = args.logging_verbosity_quiet,
        messagefmt = "[%(levelname)s] %(message)s" if os.name == "nt" else "%(message)s"
    )

    for exclude_from_pathname in args.exclude_from:
        with exclude_from_pathname.open("r") as f:
            args.exclude.extend(line for line in f.read().splitlines() if line)

    adb_arguments = [args.adb_bin] + [f"-{arg}" for arg in args.adb_flags]
    for option, value in args.adb_options:
        adb_arguments.append(f"-{option}")
        adb_arguments.append(value)

    fs_android = AndroidFileSystem(adb_arguments, args.adb_encoding)
    fs_local = LocalFileSystem(adb_arguments)

    try:
        fs_android.test_connection()
    except BrokenPipeError:
        logging_fatal("Connection test failed")

    if args.direction == "push":
        path_source = args.direction_push_local
        fs_source = fs_local
        path_destination = args.direction_push_android
        fs_destination = fs_android
    else:
        path_source = args.direction_pull_android
        fs_source = fs_android
        path_destination = args.direction_pull_local
        fs_destination = fs_local

    path_source, path_destination = FileSyncer.paths_to_fixed_destination_paths(path_source, fs_source, path_destination, fs_destination)

    path_source = fs_source.normpath(path_source)
    path_destination = fs_destination.normpath(path_destination)

    try:
        files_tree_source = fs_source.get_files_tree(path_source, follow_links = args.copy_links)
    except (FileNotFoundError, NotADirectoryError, PermissionError) as e:
        perror(path_source, e, FATAL)

    try:
        files_tree_destination = fs_destination.get_files_tree(path_destination, follow_links = args.copy_links)
    except FileNotFoundError:
        files_tree_destination = None
    except (NotADirectoryError, PermissionError) as e:
        perror(path_destination, e, FATAL)

    logging.info("Source tree:")
    if files_tree_source is not None:
        log_tree(path_source, files_tree_source)
    logging.info("")

    logging.info("Destination tree:")
    if files_tree_destination is not None:
        log_tree(path_destination, files_tree_destination)
    logging.info("")

    if isinstance(files_tree_source, dict):
        excludePatterns = [fs_destination.normpath(
            fs_destination.join(path_destination, exclude)
        ) for exclude in args.exclude]
    else:
        excludePatterns = [fs_destination.normpath(
            path_destination + exclude
        ) for exclude in args.exclude]
    logging.debug("Exclude patterns:")
    logging.debug(excludePatterns)
    logging.debug("")

    tree_delete, tree_copy, tree_excluded_source, tree_unaccounted_destination, tree_excluded_destination = FileSyncer.diff_trees(
        files_tree_source,
        files_tree_destination,
        path_source,
        path_destination,
        excludePatterns,
        fs_source.join,
        fs_destination.join,
        folder_file_overwrite_error = not args.dry_run and not args.force,
        mtime_tolerance = max(fs_source.mtime_precision, fs_destination.mtime_precision)
    )

    tree_delete                  = FileSyncer.prune_tree(tree_delete)
    tree_copy                    = FileSyncer.prune_tree(tree_copy)
    tree_excluded_source         = FileSyncer.prune_tree(tree_excluded_source)
    tree_unaccounted_destination = FileSyncer.prune_tree(tree_unaccounted_destination)
    tree_excluded_destination    = FileSyncer.prune_tree(tree_excluded_destination)

    tree_delete                  = FileSyncer.sort_tree(tree_delete)
    tree_copy                    = FileSyncer.sort_tree(tree_copy)
    tree_excluded_source         = FileSyncer.sort_tree(tree_excluded_source)
    tree_unaccounted_destination = FileSyncer.sort_tree(tree_unaccounted_destination)
    tree_excluded_destination    = FileSyncer.sort_tree(tree_excluded_destination)

    logging.info("Delete tree:")
    if tree_delete is not None:
        log_tree(path_destination, tree_delete, log_leaves_types = False)
    logging.info("")

    logging.info("Copy tree:")
    if tree_copy is not None:
        log_tree(f"{path_source} --> {path_destination}", tree_copy, log_leaves_types = False)
    logging.info("")

    logging.info("Source excluded tree:")
    if tree_excluded_source is not None:
        log_tree(path_source, tree_excluded_source, log_leaves_types = False)
    logging.info("")

    logging.info("Destination unaccounted tree:")
    if tree_unaccounted_destination is not None:
        log_tree(path_destination, tree_unaccounted_destination, log_leaves_types = False)
    logging.info("")

    logging.info("Destination excluded tree:")
    if tree_excluded_destination is not None:
        log_tree(path_destination, tree_excluded_destination, log_leaves_types = False)
    logging.info("")


    tree_unaccounted_destination_non_excluded = None
    if tree_unaccounted_destination is not None:
        tree_unaccounted_destination_non_excluded = FileSyncer.prune_tree(
            FileSyncer.remove_excluded_folders_from_unaccounted_tree(
                tree_unaccounted_destination,
                tree_excluded_destination
            )
        )

    logging.info("Non-excluded-supporting destination unaccounted tree:")
    if tree_unaccounted_destination_non_excluded is not None:
        log_tree(path_destination, tree_unaccounted_destination_non_excluded, log_leaves_types = False)
    logging.info("")

    logging.info("SYNCING")
    logging.info("")

    if tree_delete is not None:
        logging.info("Deleting delete tree")
        fs_destination.remove_tree(path_destination, tree_delete, dry_run = args.dry_run)
    else:
        logging.info("Empty delete tree")
    logging.info("")

    if args.delete_excluded and args.delete:
        if tree_excluded_destination is not None:
            logging.info("Deleting destination excluded tree")
            fs_destination.remove_tree(path_destination, tree_excluded_destination, dry_run = args.dry_run)
        else:
            logging.info("Empty destination excluded tree")
        logging.info("")
        if tree_unaccounted_destination is not None:
            logging.info("Deleting destination unaccounted tree")
            fs_destination.remove_tree(path_destination, tree_unaccounted_destination, dry_run = args.dry_run)
        else:
            logging.info("Empty destination unaccounted tree")
        logging.info("")
    elif args.delete_excluded:
        if tree_excluded_destination is not None:
            logging.info("Deleting destination excluded tree")
            fs_destination.remove_tree(path_destination, tree_excluded_destination, dry_run = args.dry_run)
        else:
            logging.info("Empty destination excluded tree")
        logging.info("")
    elif args.delete:
        if tree_unaccounted_destination_non_excluded is not None:
            logging.info("Deleting non-excluded-supporting destination unaccounted tree")
            fs_destination.remove_tree(path_destination, tree_unaccounted_destination_non_excluded, dry_run = args.dry_run)
        else:
            logging.info("Empty non-excluded-supporting destination unaccounted tree")
        logging.info("")

    if tree_copy is not None:
        logging.info("Copying copy tree")
        fs_destination.push_tree_here(
            path_source,
            fs_destination.split(path_source)[1] if isinstance(tree_copy, tuple) else ".",
            tree_copy,
            path_destination,
            fs_source,
            dry_run = args.dry_run,
            show_progress = args.show_progress
        )
    else:
        logging.info("Empty copy tree")
    logging.info("")

def backup_main():
    """Entry point for the non-destructive phonebackup CLI."""
    import argparse
    import json
    import subprocess
    import sys
    from .Backup import Backup, BackupError, status
    from .Manifest import ManifestError

    parser = argparse.ArgumentParser(
        prog="phonebackup",
        description="Create and update a non-destructive backup of Android shared storage over ADB.",
    )
    parser.add_argument("--adb-bin", default="adb", help="ADB executable (default: adb)")
    parser.add_argument("--device", "-s", metavar="SERIAL", help="Select an ADB device by serial")
    parser.add_argument("--adb-encoding", default="UTF-8", help="ADB shell text encoding (default: UTF-8)")
    parser.add_argument("--remote-root", default="/sdcard", help="Android path to back up (default: /sdcard)")
    commands = parser.add_subparsers(dest="command", required=True)
    for command, help_text in (
        ("new", "Create a backup in a new or empty directory"),
        ("update", "Incrementally update an existing backup"),
        ("diff", "Preview files that would be transferred"),
        ("paths", "List files and folders visible on the Android device"),
        ("history", "Show retained prior versions of backed-up files"),
        ("prune-history", "Preview or remove selected historical versions"),
        ("restore", "Export a backed-up version or restore it to Android"),
        ("verify", "Verify local files against stored hashes"),
        ("status", "Show manifest and last operation status"),
    ):
        subparser = commands.add_parser(command, help=help_text)
        if command != "paths":
            subparser.add_argument("destination", help="Backup directory")
        # Accept common options on either side of the subcommand.
        subparser.add_argument("--adb-bin", default=argparse.SUPPRESS, help="ADB executable")
        subparser.add_argument("--device", "-s", metavar="SERIAL", default=argparse.SUPPRESS, help="Select an ADB device")
        subparser.add_argument("--adb-encoding", default=argparse.SUPPRESS, help="ADB shell text encoding")
        subparser.add_argument("--remote-root", default=argparse.SUPPRESS, help="Android source path")
        if command == "update":
            subparser.add_argument("--dry-run", action="store_true", help="Preview changes without writing files or metadata")
        if command in ("new", "update", "diff"):
            subparser.add_argument("--include", action="append", metavar="PATH",
                                   help="Include this Android path and its contents; repeatable")
            subparser.add_argument("--exclude", action="append", metavar="PATTERN",
                                   help="Exclude paths matching this relative glob; repeatable")
            subparser.add_argument("--all", action="store_true", dest="all_files",
                                   help="Select all files and clear saved include/exclude rules")
        if command == "paths":
            subparser.add_argument("--format", choices=("text", "json"), default="text",
                                   help="Output format (default: text)")
        if command == "history":
            subparser.add_argument("path", nargs="?", help="Show versions for one relative Android file path")
            subparser.add_argument("--format", choices=("text", "json"), default="text",
                                   help="Output format (default: text)")
        if command == "prune-history":
            subparser.add_argument("--version", action="append", required=True, metavar="ID",
                                   help="History version ID to remove; repeat to select multiple")
            subparser.add_argument("--path", help="Limit selection to this relative Android file path")
            subparser.add_argument("--apply", action="store_true",
                                   help="Delete selected history versions (default is preview only)")
        if command == "restore":
            subparser.add_argument("path", help="Relative Android file path")
            target = subparser.add_mutually_exclusive_group(required=True)
            target.add_argument("--to-local", metavar="FILE", help="Export to this local file path")
            target.add_argument("--to-phone", action="store_true", help="Restore to the original Android path")
            subparser.add_argument("--version", help="Historical version ID (default: current backup copy)")
            subparser.add_argument("--overwrite", action="store_true", help="Replace an existing regular-file destination")
            subparser.add_argument("--dry-run", action="store_true", help="Show the restore target without writing")

    args = parser.parse_args()
    if getattr(args, "all_files", False) and (args.include or args.exclude):
        parser.error("--all cannot be combined with --include or --exclude")
    if args.command == "status":
        try:
            status(args.destination)
            return 0
        except (BackupError, ManifestError, OSError) as exc:
            print("phonebackup: {}".format(exc), file=sys.stderr)
            return 1

    if args.command == "paths":
        adb_arguments = [args.adb_bin]
        if args.device:
            adb_arguments += ["-s", args.device]
        backup = Backup(".", adb_arguments, args.adb_encoding, args.remote_root)
        try:
            result = backup.paths()
            if args.format == "json":
                print(json.dumps(result, ensure_ascii=True, sort_keys=True, indent=2))
            else:
                print("Source: {}".format(result["remote_root"]))
                for entry in result["entries"]:
                    path = json.dumps(entry["path"], ensure_ascii=False)
                    if entry["type"] == "directory":
                        print("DIR   {}".format(path))
                    else:
                        print("FILE  {:>12} bytes  {}".format(entry["size"], path))
                for warning in result["warnings"]:
                    print("WARNING: {}".format(warning), file=sys.stderr)
            return 0
        except (BackupError, ManifestError, OSError, BrokenPipeError, subprocess.SubprocessError) as exc:
            print("phonebackup: {}".format(exc), file=sys.stderr)
            return 1
        finally:
            backup.close()

    if args.command == "history":
        try:
            result = Backup(args.destination, [], args.adb_encoding, args.remote_root).history(args.path)
            if args.format == "json":
                print(json.dumps(result, ensure_ascii=True, sort_keys=True, indent=2))
            elif args.path is not None:
                print("History: {}".format(result["path"]))
                for version in result["versions"]:
                    print("{}  {} bytes  {}  SHA-256 {}".format(
                        version["id"], version["size"], version["captured_at"], version["sha256"]
                    ))
            else:
                for path, versions in result["files"].items():
                    print(json.dumps(path, ensure_ascii=False))
                    for version in versions:
                        print("  {}  {} bytes  {}".format(version["id"], version["size"], version["captured_at"]))
            return 0
        except (BackupError, ManifestError, OSError) as exc:
            print("phonebackup: {}".format(exc), file=sys.stderr)
            return 1

    if args.command == "prune-history":
        try:
            Backup(args.destination, [], args.adb_encoding, args.remote_root).prune_history(
                args.version, relpath=args.path, apply=args.apply
            )
            return 0
        except (BackupError, ManifestError, OSError) as exc:
            print("phonebackup: {}".format(exc), file=sys.stderr)
            return 1

    if args.command == "restore":
        adb_arguments = [args.adb_bin]
        if args.device:
            adb_arguments += ["-s", args.device]
        backup = Backup(args.destination, adb_arguments, args.adb_encoding, args.remote_root)
        try:
            backup.restore(args.path, to_local=args.to_local, to_phone=args.to_phone,
                           version_id=args.version, overwrite=args.overwrite, dry_run=args.dry_run)
            return 0
        except (BackupError, ManifestError, OSError, BrokenPipeError, subprocess.SubprocessError) as exc:
            print("phonebackup: {}".format(exc), file=sys.stderr)
            return 1
        finally:
            backup.close()

    adb_arguments = [args.adb_bin]
    if args.device:
        adb_arguments += ["-s", args.device]
    backup = None
    try:
        backup = Backup(args.destination, adb_arguments, args.adb_encoding, args.remote_root)
        if args.command in ("new", "update"):
            backup.run(create=args.command == "new", dry_run=getattr(args, "dry_run", False),
                       include=getattr(args, "include", None), exclude=getattr(args, "exclude", None),
                       all_files=getattr(args, "all_files", False))
        elif args.command == "diff":
            backup.diff(include=args.include, exclude=args.exclude, all_files=args.all_files)
        elif args.command == "verify":
            result = backup.verify()
            return 1 if result["failed"] or result["no_hash"] else 0
        return 0
    except (BackupError, ManifestError, OSError, BrokenPipeError, subprocess.SubprocessError) as exc:
        print("phonebackup: {}".format(exc), file=sys.stderr)
        return 1
    finally:
        if backup is not None:
            backup.close()


if __name__ == "__main__":
    main()

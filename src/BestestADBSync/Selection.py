"""Path selection rules shared by backup scans and manifest validation."""

from __future__ import annotations

import fnmatch
from typing import Iterable, List

def validate_path(value: str, label: str) -> str:
    if not isinstance(value, str) or not value or "\0" in value or value.startswith("/"):
        raise ValueError("{} must be a non-empty path relative to the Android source".format(label))
    if any(part in ("", ".", "..") for part in value.split("/")):
        raise ValueError("{} cannot contain empty, '.' or '..' path components".format(label))
    return value


def validate_pattern(value: str) -> str:
    validate_path(value, "exclude pattern")
    return value


class Selection:
    """Include literal paths and exclude glob patterns relative to source root.

    Includes select a file or a directory and everything below that directory.
    Exclusions are checked against each path prefix, so excluding a directory
    also excludes its descendants. Exclusions always take precedence.
    """

    def __init__(self, include: Iterable[str] = (), exclude: Iterable[str] = ()):
        self.include: List[str] = list(dict.fromkeys(validate_path(item, "include path") for item in include))
        self.exclude: List[str] = list(dict.fromkeys(validate_pattern(item) for item in exclude))

    def _excluded(self, path: str) -> bool:
        components = path.split("/")
        prefixes = ["/".join(components[:index]) for index in range(1, len(components) + 1)]
        return any(fnmatch.fnmatchcase(prefix, pattern)
                   for prefix in prefixes for pattern in self.exclude)

    def excludes_path(self, path: str) -> bool:
        """Whether the path itself or an ancestor matches an exclusion."""
        return self._excluded(path)

    def selects_file(self, path: str) -> bool:
        if self._excluded(path):
            return False
        return not self.include or any(path == root or path.startswith(root + "/") for root in self.include)

    def selects_directory(self, path: str) -> bool:
        if self._excluded(path):
            return False
        return not self.include or any(
            path == root or path.startswith(root + "/") or root.startswith(path + "/")
            for root in self.include
        )

    def minimal_include_roots(self) -> List[str]:
        roots: List[str] = []
        for path in sorted(self.include, key=lambda item: (item.count("/"), item)):
            if not any(path == root or path.startswith(root + "/") for root in roots):
                roots.append(path)
        return roots


def manifest_selection(value):
    """Validate a manifest selection and return its canonical representation."""
    if not isinstance(value, dict):
        raise ValueError("selection must be an object")
    include = value.get("include", [])
    exclude = value.get("exclude", [])
    if not isinstance(include, list) or not isinstance(exclude, list):
        raise ValueError("selection include/exclude values must be arrays")
    try:
        selection = Selection(include, exclude)
    except (TypeError, ValueError) as exc:
        raise ValueError("invalid selection: {}".format(exc)) from exc
    return {"include": selection.include, "exclude": selection.exclude}

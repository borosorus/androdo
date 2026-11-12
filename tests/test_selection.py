import pytest

from BestestADBSync.Selection import Selection


def test_default_selects_everything_and_includes_hidden_paths():
    selection = Selection()
    assert selection.selects_file(".private/note.txt")


def test_include_subtree_and_exclude_globs():
    selection = Selection(["DCIM", "Documents/one.txt"], ["DCIM/Thumbnails/**"])
    assert selection.selects_file("DCIM/Camera/photo.jpg")
    assert selection.selects_file("Documents/one.txt")
    assert not selection.selects_file("Documents/two.txt")
    assert not selection.selects_file("DCIM/Thumbnails/thumb.jpg")


@pytest.mark.parametrize("path", ["/absolute", "../escape", "a/../b", "a//b", ""])
def test_rejects_unsafe_include_paths(path):
    with pytest.raises(ValueError):
        Selection([path])


def test_minimal_include_roots_prunes_nested_paths():
    assert Selection(["DCIM", "DCIM/Camera", "Documents"]).minimal_include_roots() == ["DCIM", "Documents"]

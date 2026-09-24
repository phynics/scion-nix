"""Unit tests for the pure parts of update.py (no network, no Nix)."""

import unittest

from update import extract_hash, parse_ls_remote, parse_version, pick_release

TAGS = {
    "0.1.0-dev": "a",
    "v0.3.0-preview.1": "b",
    "v0.3.0-preview.2": "c",
    "v0.3.0-preview.10": "d",
    "v0.3.0-rc.1": "e",
    "v0.3.0": "f",
    "v0.4.0-preview.1": "g",
    "nightly-20260923": "h",
}


class VersionTest(unittest.TestCase):
    def test_ordering(self):
        order = ["v0.3.0-preview.2", "v0.3.0-preview.10", "v0.3.0-rc.1", "v0.3.0", "v0.3.1", "v0.4.0-preview.1"]
        versions = [parse_version(tag) for tag in order]
        self.assertEqual(versions, sorted(versions))

    def test_rejects_other_tags(self):
        for tag in ("nightly-20260923", "0.1.0-dev", "v0.3", "v0.3.0-beta.1", "latest"):
            self.assertIsNone(parse_version(tag), tag)


class PickReleaseTest(unittest.TestCase):
    def test_preview_takes_newest_prerelease(self):
        self.assertEqual(pick_release(TAGS, "preview", "v0.3.0-preview.2"), "v0.4.0-preview.1")

    def test_stable_ignores_prereleases(self):
        self.assertEqual(pick_release(TAGS, "stable", "v0.3.0-preview.2"), "v0.3.0")

    def test_never_downgrades(self):
        self.assertIsNone(pick_release(TAGS, "preview", "v0.4.0-preview.1"))
        self.assertIsNone(pick_release(TAGS, "stable", "v0.4.0-preview.1"))

    def test_numeric_prerelease_order(self):
        tags = {"v0.3.0-preview.9": "x", "v0.3.0-preview.10": "y"}
        self.assertEqual(pick_release(tags, "preview", "v0.3.0-preview.3"), "v0.3.0-preview.10")

    def test_unknown_channel(self):
        with self.assertRaises(ValueError):
            pick_release(TAGS, "nightly", "v0.3.0")


class ParsingTest(unittest.TestCase):
    def test_ls_remote_peels_annotated_tags(self):
        output = (
            "1111\trefs/tags/v0.3.0-preview.3\n"
            "2222\trefs/tags/v0.3.0-preview.3^{}\n"
            "3333\trefs/tags/v0.3.0-preview.2\n"
        )
        self.assertEqual(parse_ls_remote(output), {"v0.3.0-preview.3": "2222", "v0.3.0-preview.2": "3333"})

    def test_extract_hash(self):
        stderr = (
            "error: hash mismatch in fixed-output derivation '/nix/store/x-go-modules.drv':\n"
            "         specified: sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n"
            "            got:    sha256-8FwhN7R4FSn/nIyxXmK8elqM1Ty72ws+pBDv0H/czXU=\n"
        )
        self.assertEqual(extract_hash(stderr), "sha256-8FwhN7R4FSn/nIyxXmK8elqM1Ty72ws+pBDv0H/czXU=")
        self.assertIsNone(extract_hash("error: builder failed"))


if __name__ == "__main__":
    unittest.main()

import hashlib
import os
import tempfile
import unittest
from pathlib import Path

from deploy import deploy_version_file


class DeployVersionFileTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name) / "repo"
        self.target = Path(self.tmp.name) / "target"
        self.repo.mkdir()
        self.target.mkdir()

    def test_writes_version_file_to_target(self):
        (self.repo / "version.txt").write_bytes(b"1.2.3\n")
        deploy_version_file(self.repo, self.target, {})
        self.assertEqual((self.target / "version.txt").read_bytes(), b"1.2.3\n")

    def test_returns_lf_normalized_hash(self):
        (self.repo / "version.txt").write_bytes(b"1.2.3\r\n")
        digest = deploy_version_file(self.repo, self.target, {})
        expected = hashlib.sha256(b"1.2.3\n").hexdigest()
        self.assertEqual(digest, expected)

    def test_updates_hashes_dict_in_place(self):
        (self.repo / "version.txt").write_bytes(b"1.2.3\n")
        hashes = {"startup.lua": "unrelated"}
        deploy_version_file(self.repo, self.target, hashes)
        self.assertIn("version.txt", hashes)
        self.assertEqual(hashes["startup.lua"], "unrelated")

    def test_overwrites_a_shorter_existing_file_cleanly(self):
        # Same reasoning as deploy()'s own unlink-first write: opening "wb" over
        # a network mount does not reliably truncate, so this proves the same
        # unlink-then-write path is used here too.
        (self.target / "version.txt").write_bytes(b"1.2.30-stale-and-longer\n")
        (self.repo / "version.txt").write_bytes(b"2.0.0\n")
        deploy_version_file(self.repo, self.target, {})
        self.assertEqual((self.target / "version.txt").read_bytes(), b"2.0.0\n")


if __name__ == "__main__":
    unittest.main()

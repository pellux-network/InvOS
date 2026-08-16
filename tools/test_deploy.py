import hashlib
import os
import tempfile
import unittest
from pathlib import Path

from deploy import deploy_recipe_pack, deploy_version_file


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


class DeployRecipePackTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.source = Path(self.tmp.name) / "source"
        self.target = Path(self.tmp.name) / "target"
        self.source.mkdir()
        self.target.mkdir()

    def test_skips_and_returns_empty_when_no_local_pack(self):
        hashes = deploy_recipe_pack(self.source, self.target, "controller")
        self.assertEqual(hashes, {})
        self.assertFalse((self.target / "storage" / "recipes").exists())

    def test_writes_lf_normalized_files_and_hashes_them(self):
        recipes = self.source / "storage" / "recipes"
        recipes.mkdir(parents=True)
        (recipes / "items.lua").write_bytes(b"return {}\r\n")
        hashes = deploy_recipe_pack(self.source, self.target, "controller")
        written = self.target / "storage" / "recipes" / "items.lua"
        self.assertEqual(written.read_bytes(), b"return {}\n")
        self.assertEqual(hashes["storage/recipes/items.lua"],
                         hashlib.sha256(b"return {}\n").hexdigest())

    def test_prunes_target_files_no_longer_present_in_source(self):
        recipes = self.source / "storage" / "recipes"
        recipes.mkdir(parents=True)
        (recipes / "index.lua").write_bytes(b"return {}\n")
        dst_recipes = self.target / "storage" / "recipes"
        dst_recipes.mkdir(parents=True)
        (dst_recipes / "pack_09.lua").write_bytes(b"return {recipes={}}\n")
        hashes = deploy_recipe_pack(self.source, self.target, "controller")
        self.assertFalse((dst_recipes / "pack_09.lua").exists())
        self.assertNotIn("storage/recipes/pack_09.lua", hashes)

    def test_only_touches_files_that_changed(self):
        recipes = self.source / "storage" / "recipes"
        recipes.mkdir(parents=True)
        (recipes / "tags.lua").write_bytes(b"return {}\n")
        deploy_recipe_pack(self.source, self.target, "controller")
        written = self.target / "storage" / "recipes" / "tags.lua"
        before = written.stat().st_mtime_ns
        deploy_recipe_pack(self.source, self.target, "controller")
        self.assertEqual(written.stat().st_mtime_ns, before)


if __name__ == "__main__":
    unittest.main()

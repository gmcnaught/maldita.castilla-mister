#!/usr/bin/env python3
# Tests for scripts/lib/resolve_rbf.py.
#
# No network and no gh: the run listing is injected. Real throwaway git repos
# are used rather than fake hashes, because the behaviour under test IS git's
# tree-hash semantics — a docs-only commit must not change fpga/'s tree, and an
# RTL change must. Faking that would test nothing.
#
# Stdlib unittest, no deps — same rule as test_wire_constants.py.
# Exit 0 = all pass; exit 1 = at least one failed.

import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "lib"))
import resolve_rbf  # noqa: E402


def git(repo, *a, check=True):
    return subprocess.run(["git", "-C", str(repo), *a], check=check,
                          text=True, capture_output=True)


class ResolveRbfTest(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.dir, ignore_errors=True)
        subprocess.run(["git", "init", "-q", str(self.dir)], check=True)
        git(self.dir, "config", "user.email", "t@t.t")
        git(self.dir, "config", "user.name", "t")
        (self.dir / "fpga").mkdir()
        (self.dir / "fpga" / "rtl.sv").write_text("module a; endmodule\n")
        git(self.dir, "add", "-A")
        git(self.dir, "commit", "-qm", "rtl v1")

    def head_sha(self):
        return git(self.dir, "rev-parse", "HEAD").stdout.strip()

    def commit_docs_only(self):
        (self.dir / "README.md").write_text("docs\n")
        git(self.dir, "add", "-A")
        git(self.dir, "commit", "-qm", "docs")

    def commit_rtl_change(self):
        (self.dir / "fpga" / "rtl.sv").write_text("module b; endmodule\n")
        git(self.dir, "add", "-A")
        git(self.dir, "commit", "-qm", "rtl v2")

    # --- fpga_tree ---------------------------------------------------------
    def test_fpga_tree_is_stable_across_a_docs_only_commit(self):
        before = resolve_rbf.fpga_tree(self.dir)
        self.commit_docs_only()
        self.assertEqual(resolve_rbf.fpga_tree(self.dir), before)

    def test_fpga_tree_changes_when_rtl_changes(self):
        before = resolve_rbf.fpga_tree(self.dir)
        self.commit_rtl_change()
        self.assertNotEqual(resolve_rbf.fpga_tree(self.dir), before)

    def test_fpga_tree_returns_none_for_a_non_repo(self):
        self.assertIsNone(resolve_rbf.fpga_tree(self.dir / "nope"))

    # --- find_run_for_tree -------------------------------------------------
    def test_matches_the_build_for_an_unchanged_fpga_tree(self):
        rtl_sha = self.head_sha()
        self.commit_docs_only()
        want = resolve_rbf.fpga_tree(self.dir)
        got = resolve_rbf.find_run_for_tree(
            self.dir, want, [{"databaseId": 42, "headSha": rtl_sha}])
        self.assertIsNotNone(got)
        self.assertEqual(got["databaseId"], 42)

    def test_rejects_a_build_from_different_rtl(self):
        stale_sha = self.head_sha()
        self.commit_rtl_change()
        want = resolve_rbf.fpga_tree(self.dir)
        self.assertIsNone(resolve_rbf.find_run_for_tree(
            self.dir, want, [{"databaseId": 42, "headSha": stale_sha}]))

    def test_takes_the_newest_of_several_matches(self):
        sha = self.head_sha()
        want = resolve_rbf.fpga_tree(self.dir)
        # gh lists newest-first; the first match must win.
        runs = [{"databaseId": 99, "headSha": sha},
                {"databaseId": 42, "headSha": sha}]
        self.assertEqual(
            resolve_rbf.find_run_for_tree(self.dir, want, runs)["databaseId"], 99)

    def test_returns_none_for_an_empty_run_list(self):
        want = resolve_rbf.fpga_tree(self.dir)
        self.assertIsNone(resolve_rbf.find_run_for_tree(self.dir, want, []))

    # --- resolve_run_id ----------------------------------------------------
    def test_raises_with_the_wanted_tree_in_the_message(self):
        want = resolve_rbf.fpga_tree(self.dir)
        with mock.patch.object(resolve_rbf, "list_successful_runs",
                               return_value=[]):
            with self.assertRaises(resolve_rbf.RbfResolutionError) as cm:
                resolve_rbf.resolve_run_id(self.dir)
        self.assertIn(want[:9], str(cm.exception))

    def test_error_message_names_the_expired_artifact_recovery(self):
        with mock.patch.object(resolve_rbf, "list_successful_runs",
                               return_value=[]):
            with self.assertRaises(resolve_rbf.RbfResolutionError) as cm:
                resolve_rbf.resolve_run_id(self.dir)
        self.assertIn("EXPIRED", str(cm.exception))

    def test_returns_run_sha_and_tree(self):
        sha = self.head_sha()
        with mock.patch.object(resolve_rbf, "list_successful_runs",
                               return_value=[{"databaseId": 7, "headSha": sha}]):
            run_id, built_sha, want_tree = resolve_rbf.resolve_run_id(self.dir)
        self.assertEqual(run_id, 7)
        self.assertEqual(built_sha, sha)
        self.assertEqual(want_tree, resolve_rbf.fpga_tree(self.dir))


if __name__ == "__main__":
    unittest.main(verbosity=2)

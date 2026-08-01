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

    def write_and_commit(self, relpath, contents, msg):
        p = self.dir / relpath
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(contents)
        git(self.dir, "add", "-A")
        git(self.dir, "commit", "-qm", msg)

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

    # --- fpga_tree: the fix/fpga-tree-narrow scope (EXCLUDED_PREFIXES) -----
    # These prove the actual bug fix: fpga/sim/** and fpga/docs/** must not
    # move the bitstream identity (they cannot trigger a build under
    # build-rbf.yml's push filter, so counting them toward the hash is the
    # exact trap that blocked milestone-a), while everything else under
    # fpga/ -- including files that merely LOOK like they're in those
    # directories -- still must.
    def test_editing_fpga_sim_does_not_change_the_tree_hash(self):
        self.write_and_commit("fpga/sim/README.md", "sim harness\n", "add sim readme")
        before = resolve_rbf.fpga_tree(self.dir)
        self.write_and_commit("fpga/sim/README.md", "sim harness v2\n", "edit sim readme")
        self.assertEqual(resolve_rbf.fpga_tree(self.dir), before)

    def test_editing_fpga_docs_does_not_change_the_tree_hash(self):
        self.write_and_commit("fpga/docs/notes.md", "notes\n", "add docs notes")
        before = resolve_rbf.fpga_tree(self.dir)
        self.write_and_commit("fpga/docs/notes.md", "notes v2\n", "edit docs notes")
        self.assertEqual(resolve_rbf.fpga_tree(self.dir), before)

    def test_adding_a_new_file_under_fpga_sim_does_not_change_the_tree_hash(self):
        before = resolve_rbf.fpga_tree(self.dir)
        self.write_and_commit("fpga/sim/new_tb.sv", "module tb; endmodule\n",
                              "add a new sim testbench")
        self.assertEqual(resolve_rbf.fpga_tree(self.dir), before)

    def test_editing_fpga_rtl_changes_the_tree_hash(self):
        before = resolve_rbf.fpga_tree(self.dir)
        self.commit_rtl_change()
        self.assertNotEqual(resolve_rbf.fpga_tree(self.dir), before)

    def test_adding_a_new_file_directly_under_fpga_changes_the_tree_hash(self):
        before = resolve_rbf.fpga_tree(self.dir)
        self.write_and_commit("fpga/new_module.sv", "module c; endmodule\n",
                              "add a new fpga module")
        self.assertNotEqual(resolve_rbf.fpga_tree(self.dir), before)

    def test_a_path_merely_starting_with_sim_or_docs_still_changes_the_hash(self):
        # Guards against a sloppy prefix match: fpga/simulation_notes.sv and
        # fpga/docs_helper.sv are siblings of fpga/sim and fpga/docs, not
        # members of them -- path.startswith("fpga/sim") would wrongly treat
        # them as excluded.
        before = resolve_rbf.fpga_tree(self.dir)
        self.write_and_commit("fpga/simulation_notes.sv", "// notes\n",
                              "add simulation_notes.sv (not fpga/sim/)")
        after_sim_lookalike = resolve_rbf.fpga_tree(self.dir)
        self.assertNotEqual(after_sim_lookalike, before)
        self.write_and_commit("fpga/docs_helper.sv", "// helper\n",
                              "add docs_helper.sv (not fpga/docs/)")
        after_docs_lookalike = resolve_rbf.fpga_tree(self.dir)
        self.assertNotEqual(after_docs_lookalike, after_sim_lookalike)

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
        # gh lists newest-first; the first match must win regardless of id
        # magnitude -- the smaller id sits first here on purpose, so a wrong
        # "largest id wins" implementation cannot pass this test by accident.
        runs = [{"databaseId": 42, "headSha": sha},
                {"databaseId": 99, "headSha": sha}]
        self.assertEqual(
            resolve_rbf.find_run_for_tree(self.dir, want, runs)["databaseId"], 42)

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
                               return_value=[{"databaseId": 7, "headSha": sha}]), \
             mock.patch.object(resolve_rbf, "run_artifact_names",
                               return_value=[resolve_rbf.RBF_ARTIFACT]):
            run_id, built_sha, want_tree = resolve_rbf.resolve_run_id(self.dir)
        self.assertEqual(run_id, 7)
        self.assertEqual(built_sha, sha)
        self.assertEqual(want_tree, resolve_rbf.fpga_tree(self.dir))

    # --- artifact-aware selection (the runner=linux dispatch trap) --------
    # A workflow_dispatch with runner=linux skips build-windows but still
    # concludes "success", uploading only maldita-rbf-linux. If that run is
    # newest and tree-matching, naive "first tree match wins" would pick a
    # run `gh run download -n maldita-rbf` can never satisfy.
    def test_selects_older_match_when_newest_lacks_the_artifact(self):
        old_sha = self.head_sha()
        self.commit_docs_only()
        new_sha = self.head_sha()
        want = resolve_rbf.fpga_tree(self.dir)
        self.assertEqual(want, resolve_rbf.fpga_tree(self.dir, old_sha))
        runs = [{"databaseId": 99, "headSha": new_sha},
                {"databaseId": 42, "headSha": old_sha}]

        def fake_artifacts(run_id):
            # 99 = the linux-only dispatch (newest, tree-matches, no windows
            # artifact); 42 = the older run that actually has it.
            return [] if run_id == 99 else [resolve_rbf.RBF_ARTIFACT]

        with mock.patch.object(resolve_rbf, "list_successful_runs",
                               return_value=runs), \
             mock.patch.object(resolve_rbf, "run_artifact_names",
                               side_effect=fake_artifacts):
            run_id, built_sha, want_tree = resolve_rbf.resolve_run_id(self.dir)
        self.assertEqual(run_id, 42)
        self.assertEqual(built_sha, old_sha)
        self.assertEqual(want_tree, want)

    def test_raises_naming_skipped_runs_when_none_carry_the_artifact(self):
        old_sha = self.head_sha()
        self.commit_docs_only()
        new_sha = self.head_sha()
        runs = [{"databaseId": 99, "headSha": new_sha},
                {"databaseId": 42, "headSha": old_sha}]
        with mock.patch.object(resolve_rbf, "list_successful_runs",
                               return_value=runs), \
             mock.patch.object(resolve_rbf, "run_artifact_names",
                               return_value=["maldita-rbf-linux"]):
            with self.assertRaises(resolve_rbf.RbfResolutionError) as cm:
                resolve_rbf.resolve_run_id(self.dir)
        msg = str(cm.exception)
        self.assertIn("99", msg)
        self.assertIn("42", msg)

    def test_artifact_query_failure_raises_rather_than_silently_skipping(self):
        sha = self.head_sha()
        runs = [{"databaseId": 7, "headSha": sha}]

        def boom(run_id):
            raise resolve_rbf.RbfResolutionError(
                "gh run view 7 --json artifacts failed -- boom")

        with mock.patch.object(resolve_rbf, "list_successful_runs",
                               return_value=runs), \
             mock.patch.object(resolve_rbf, "run_artifact_names",
                               side_effect=boom):
            with self.assertRaises(resolve_rbf.RbfResolutionError) as cm:
                resolve_rbf.resolve_run_id(self.dir)
        self.assertIn("boom", str(cm.exception))

    def test_run_artifact_names_raises_when_gh_query_fails(self):
        with mock.patch.object(
                resolve_rbf.subprocess, "run",
                return_value=subprocess.CompletedProcess(
                    args=[], returncode=1, stdout="", stderr="not authenticated")):
            with self.assertRaises(resolve_rbf.RbfResolutionError) as cm:
                resolve_rbf.run_artifact_names(1)
        self.assertIn("not authenticated", str(cm.exception))

    def test_run_artifact_names_parses_artifact_list(self):
        # Real `gh api repos/{owner}/{repo}/actions/runs/<id>/artifacts` shape
        # (confirmed against run 30675960267 on gmcnaught/maldita.castilla-mister):
        # a top-level "artifacts" array of objects each carrying (among other
        # fields) "name" and "expired". Using an invented shape here is exactly
        # how the original bug (a nonexistent `gh run view --json artifacts`
        # field) went undetected -- the mock must mirror the real API.
        payload = ('{"total_count": 2, "artifacts": ['
                   '{"name": "maldita-rbf", "expired": false}, '
                   '{"name": "quartus-reports", "expired": false}]}')
        with mock.patch.object(
                resolve_rbf.subprocess, "run",
                return_value=subprocess.CompletedProcess(
                    args=[], returncode=0, stdout=payload, stderr="")):
            names = resolve_rbf.run_artifact_names(1)
        self.assertEqual(names, ["maldita-rbf", "quartus-reports"])

    def test_run_artifact_names_treats_an_expired_artifact_as_absent(self):
        # A run whose maldita-rbf has expired cannot satisfy `gh run download
        # -n maldita-rbf` -- it must be filtered out here so resolve_run_id
        # skips the run exactly as it would for a run that never had the
        # artifact at all.
        payload = ('{"total_count": 2, "artifacts": ['
                   '{"name": "maldita-rbf", "expired": true}, '
                   '{"name": "quartus-reports", "expired": false}]}')
        with mock.patch.object(
                resolve_rbf.subprocess, "run",
                return_value=subprocess.CompletedProcess(
                    args=[], returncode=0, stdout=payload, stderr="")):
            names = resolve_rbf.run_artifact_names(1)
        self.assertEqual(names, ["quartus-reports"])
        self.assertNotIn(resolve_rbf.RBF_ARTIFACT, names)

    def test_run_artifact_names_invokes_gh_api_against_the_artifacts_endpoint(self):
        # Exercises the ACTUAL command construction, mocking only the
        # subprocess boundary -- not run_artifact_names itself -- so a future
        # edit back to an invalid `gh run view --json artifacts`-style field
        # or flag is caught here instead of at release time (this is exactly
        # the gap that let the original bug reach milestone-a: every other
        # test mocked run_artifact_names away).
        payload = '{"total_count": 0, "artifacts": []}'
        with mock.patch.object(
                resolve_rbf.subprocess, "run",
                return_value=subprocess.CompletedProcess(
                    args=[], returncode=0, stdout=payload, stderr="")) as m:
            resolve_rbf.run_artifact_names(30675960267)
        m.assert_called_once()
        argv = m.call_args.args[0]
        self.assertEqual(argv[0], "gh")
        self.assertEqual(argv[1], "api")
        self.assertNotIn("run", argv)  # not the broken `gh run view` form
        self.assertNotIn("--json", argv)  # not the broken `--json artifacts` flag
        endpoint = argv[2]
        self.assertTrue(endpoint.startswith("repos/"))
        self.assertIn("{owner}", endpoint)
        self.assertIn("{repo}", endpoint)
        self.assertIn("/actions/runs/30675960267/artifacts", endpoint)

    def test_selects_older_match_when_newest_artifact_has_expired(self):
        # End-to-end through resolve_run_id (not just run_artifact_names):
        # the newest tree-matching run's maldita-rbf has expired, so an older
        # tree-matching run with a live artifact must win -- the same
        # newest-first walk used for the runner=linux dispatch trap.
        old_sha = self.head_sha()
        self.commit_docs_only()
        new_sha = self.head_sha()
        want = resolve_rbf.fpga_tree(self.dir)
        runs = [{"databaseId": 99, "headSha": new_sha},
                {"databaseId": 42, "headSha": old_sha}]

        real_run = subprocess.run

        def fake_gh_api(argv, **kwargs):
            if argv[0] != "gh":
                return real_run(argv, **kwargs)
            run_id = int(argv[2].split("/actions/runs/")[1].split("/artifacts")[0])
            if run_id == 99:
                payload = ('{"artifacts": ['
                          '{"name": "maldita-rbf", "expired": true}]}')
            else:
                payload = ('{"artifacts": ['
                          '{"name": "maldita-rbf", "expired": false}]}')
            return subprocess.CompletedProcess(
                args=argv, returncode=0, stdout=payload, stderr="")

        with mock.patch.object(resolve_rbf, "list_successful_runs",
                               return_value=runs), \
             mock.patch.object(resolve_rbf.subprocess, "run",
                               side_effect=fake_gh_api):
            run_id, built_sha, want_tree = resolve_rbf.resolve_run_id(self.dir)
        self.assertEqual(run_id, 42)
        self.assertEqual(built_sha, old_sha)
        self.assertEqual(want_tree, want)


if __name__ == "__main__":
    unittest.main(verbosity=2)

#!/usr/bin/env python3
"""Resolve the CI RBF build that matches a given revision's fpga/ tree.

Shared by deploy.py (--fetch-rbf) and .github/workflows/release.yml so the two
cannot drift. This rule is the only thing standing between a release and a
stale bitstream, so it lives in one tested place rather than being restated in
YAML.

Resolving by fpga/ TREE hash rather than by commit sha is deliberate:
build-rbf.yml triggers only on fpga/**, so a docs- or CI-only commit
legitimately has no run of its own while the bitstream from the last RTL commit
is still exactly right. Gating on commit equality would refuse those builds
spuriously, which trains everyone to pass --force by reflex and kills the gate.
The tree hash changes if and only if fpga/ actually changed.
"""
import argparse
import json
import subprocess
import sys
from pathlib import Path

RBF_WORKFLOW = "build-rbf.yml"
RBF_ARTIFACT = "maldita-rbf"


class RbfResolutionError(Exception):
    """No CI build matches the requested fpga/ tree."""


def fpga_tree(repo, rev="HEAD"):
    """git tree hash of fpga/ at `rev`, or None if it cannot be resolved."""
    r = subprocess.run(["git", "-C", str(repo), "rev-parse", f"{rev}:fpga"],
                       text=True, capture_output=True)
    return r.stdout.strip() if r.returncode == 0 else None


def list_successful_runs(workflow=RBF_WORKFLOW, limit=60):
    """Completed, successful runs of `workflow`, newest first."""
    r = subprocess.run(
        ["gh", "run", "list", "--workflow", workflow, "--limit", str(limit),
         "--json", "databaseId,headSha,status,conclusion"],
        text=True, capture_output=True)
    if r.returncode != 0:
        raise RbfResolutionError(
            f"gh run list failed -- is gh installed and authenticated?\n{r.stderr}")
    return [x for x in json.loads(r.stdout or "[]")
            if x.get("status") == "completed" and x.get("conclusion") == "success"]


def find_all_runs_for_tree(repo, want_tree, runs):
    """All runs (newest-first order preserved) whose fpga/ tree matches."""
    return [run for run in runs if fpga_tree(repo, run["headSha"]) == want_tree]


def find_run_for_tree(repo, want_tree, runs):
    """First run (newest-first order preserved) whose fpga/ tree matches.

    Tree-match only -- does NOT check that the run actually carries
    RBF_ARTIFACT. Kept for callers/tests that only care about tree identity;
    resolve_run_id below does the artifact-aware selection.
    """
    matches = find_all_runs_for_tree(repo, want_tree, runs)
    return matches[0] if matches else None


def run_artifact_names(run_id):
    """Artifact names attached to `run_id`.

    Fails loudly: a `gh` query error is NOT the same as "no artifacts", and
    must never be silently treated as "skip this run" -- that would make a
    transient API failure look identical to the linux-only-dispatch failure
    mode this whole check exists to catch.
    """
    r = subprocess.run(
        ["gh", "run", "view", str(run_id), "--json", "artifacts"],
        text=True, capture_output=True)
    if r.returncode != 0:
        raise RbfResolutionError(
            f"gh run view {run_id} --json artifacts failed -- is gh installed "
            f"and authenticated?\n{r.stderr}")
    try:
        data = json.loads(r.stdout or "{}")
    except json.JSONDecodeError as e:
        raise RbfResolutionError(
            f"gh run view {run_id} --json artifacts returned unparseable "
            f"JSON: {e}")
    return [a.get("name") for a in data.get("artifacts", [])]


def resolve_run_id(repo, rev="HEAD", workflow=RBF_WORKFLOW):
    """(run_id, built_sha, want_tree) for the build matching `rev`'s fpga/ tree.

    Raises RbfResolutionError when nothing matches. Fails closed on purpose:
    falling back to a fresh build would ship a bitstream nobody validated, since
    Quartus fitting is seed-sensitive.

    A run's fpga/ tree matching is necessary but not sufficient: a
    workflow_dispatch with runner=linux skips build-windows entirely and still
    concludes "success", uploading only maldita-rbf-linux. If that run is the
    newest tree match, naively taking "first match" would pick a run that can
    never satisfy `gh run download -n maldita-rbf`. So every tree-matching run
    is walked, newest first, until one is found whose artifact list actually
    contains RBF_ARTIFACT.
    """
    want_tree = fpga_tree(repo, rev)
    if not want_tree:
        raise RbfResolutionError(
            f"cannot read the fpga/ tree of {rev} -- is {repo} a git checkout?")
    runs = list_successful_runs(workflow=workflow)
    matches = find_all_runs_for_tree(repo, want_tree, runs)
    if not matches:
        raise RbfResolutionError(
            f"no successful {workflow} run whose fpga/ tree matches {rev}'s "
            f"({want_tree[:9]}).\n"
            f"       If the matching run's artifacts have EXPIRED, re-run "
            f"{workflow} at that commit and re-validate on device.\n"
            f"       Do not bypass this gate: a fresh build is a bitstream "
            f"nobody validated.")
    skipped = []
    for run in matches:
        if RBF_ARTIFACT in run_artifact_names(run["databaseId"]):
            return run["databaseId"], run["headSha"], want_tree
        skipped.append(run["databaseId"])
    raise RbfResolutionError(
        f"{len(matches)} successful {workflow} run(s) matched {rev}'s fpga/ "
        f"tree ({want_tree[:9]}) but none carried the '{RBF_ARTIFACT}' "
        f"artifact -- skipped run id(s): {', '.join(str(i) for i in skipped)}.\n"
        f"       This is the runner=linux dispatch trap: that run builds "
        f"only maldita-rbf-linux and still concludes 'success'.\n"
        f"       Dispatch {workflow} with runner=windows (or both) at this "
        f"tree, or wait for a push build, then retry.")


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--repo", default=".", help="repo checkout to resolve against")
    p.add_argument("--rev", default="HEAD", help="revision whose fpga/ tree to match")
    p.add_argument("--json", action="store_true", help="emit JSON instead of text")
    a = p.parse_args(argv)
    try:
        run_id, built_sha, want_tree = resolve_run_id(Path(a.repo), a.rev)
    except RbfResolutionError as e:
        print(f"FATAL: {e}", file=sys.stderr)
        return 1
    if a.json:
        print(json.dumps({"run_id": run_id, "built_sha": built_sha,
                          "fpga_tree": want_tree, "artifact": RBF_ARTIFACT}))
    else:
        print(f"run_id={run_id} built_sha={built_sha} fpga_tree={want_tree}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

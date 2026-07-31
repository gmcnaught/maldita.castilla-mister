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


def find_run_for_tree(repo, want_tree, runs):
    """First run (newest-first order preserved) whose fpga/ tree matches."""
    for run in runs:
        if fpga_tree(repo, run["headSha"]) == want_tree:
            return run
    return None


def resolve_run_id(repo, rev="HEAD", workflow=RBF_WORKFLOW):
    """(run_id, built_sha, want_tree) for the build matching `rev`'s fpga/ tree.

    Raises RbfResolutionError when nothing matches. Fails closed on purpose:
    falling back to a fresh build would ship a bitstream nobody validated, since
    Quartus fitting is seed-sensitive.
    """
    want_tree = fpga_tree(repo, rev)
    if not want_tree:
        raise RbfResolutionError(
            f"cannot read the fpga/ tree of {rev} -- is {repo} a git checkout?")
    run = find_run_for_tree(repo, want_tree, list_successful_runs(workflow=workflow))
    if run is None:
        raise RbfResolutionError(
            f"no successful {workflow} run whose fpga/ tree matches {rev}'s "
            f"({want_tree[:9]}).\n"
            f"       If the matching run's artifacts have EXPIRED, re-run "
            f"{workflow} at that commit and re-validate on device.\n"
            f"       Do not bypass this gate: a fresh build is a bitstream "
            f"nobody validated.")
    return run["databaseId"], run["headSha"], want_tree


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

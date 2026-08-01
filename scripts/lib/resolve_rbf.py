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
import hashlib
import json
import subprocess
import sys
from pathlib import Path

RBF_WORKFLOW = "build-rbf.yml"
RBF_ARTIFACT = "maldita-rbf"

# Bitstream-affecting exclusions within fpga/, mirroring build-rbf.yml's push
# trigger ('!fpga/sim/**', '!fpga/docs/**'): those subtrees are a testbench
# harness and prose respectively, neither reaches the RBF, so a push touching
# only them fires no build. fpga_tree() below must exclude the same paths
# from the bitstream's identity hash, or a sim/docs-only edit moves the
# identity with no build to match it and resolution refuses spuriously (the
# fix/fpga-tree-narrow bug). These two lists MUST be changed together -- add
# an exclusion here without mirroring it in the workflow (or vice versa) and
# the trap comes straight back.
EXCLUDED_PREFIXES = ("fpga/sim", "fpga/docs")

# fpga_tree()'s hashing algorithm, recorded in provenance sidecars (see
# deploy.py's fetch_rbf_for_head) so an old sidecar written under a prior
# algorithm is never silently compared as if commensurable with a new one.
#   1 -- raw `git rev-parse <rev>:fpga` (the whole fpga/ tree, sim/ and docs/
#        included). This is the bug fix/fpga-tree-narrow closes.
#   2 -- git ls-tree -r <rev> -- fpga, with EXCLUDED_PREFIXES entries removed,
#        then hashed.
TREE_ALGO = 2


class RbfResolutionError(Exception):
    """No CI build matches the requested fpga/ tree."""


def _is_excluded(path):
    """True if `path` (an fpga/... path from `git ls-tree`) is under one of
    EXCLUDED_PREFIXES.

    Must match on a full path-segment boundary, not a bare string prefix:
    fpga/simulation_notes.sv and fpga/docs_helper.sv are siblings of
    fpga/sim and fpga/docs, not members of them, and must still count toward
    the bitstream identity. A plain path.startswith(prefix) would wrongly
    swallow both -- path == prefix or path.startswith(prefix + "/") is what
    enforces the boundary.
    """
    return any(path == prefix or path.startswith(prefix + "/")
               for prefix in EXCLUDED_PREFIXES)


def fpga_tree(repo, rev="HEAD"):
    """Deterministic hash of the bitstream-affecting entries of fpga/ at `rev`.

    "Bitstream-affecting" means exactly what build-rbf.yml's push filter
    treats as able to trigger a build: fpga/** minus EXCLUDED_PREFIXES.
    Hashing that set (rather than the whole fpga/ tree, algo 1's bug)
    guarantees the identity used for RBF resolution never moves except when
    the actual synthesis inputs do.

    `git ls-tree -r` output is already deterministically ordered and each
    line already carries the blob's content sha, so hashing the filtered
    listing's raw bytes is sufficient -- no need to read blob contents.

    Returns None if `rev` or `repo` cannot be resolved (same contract algo 1
    had -- existing callers treat None as "give up", not "empty tree").
    """
    r = subprocess.run(["git", "-C", str(repo), "ls-tree", "-r", str(rev), "--", "fpga"],
                       text=True, capture_output=True)
    if r.returncode != 0:
        return None
    lines = [ln for ln in r.stdout.splitlines() if ln]
    if not lines:
        # Either `rev` resolves but has no fpga/ tree at all, or something
        # unexpected happened -- either way there is nothing to identify a
        # bitstream by. Treat the same as unresolved rather than hashing an
        # empty listing.
        return None
    kept = []
    for ln in lines:
        # ls-tree -r line format: "<mode> <type> <sha>\t<path>"
        _, _, path = ln.partition("\t")
        if not _is_excluded(path):
            kept.append(ln)
    return hashlib.sha1("\n".join(kept).encode()).hexdigest()


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
    """Names of NON-EXPIRED artifacts attached to `run_id`.

    `gh run view --json artifacts` is not a real field -- there is no such
    JSON key on that command, and it always fails with "Unknown JSON field:
    \"artifacts\"". The REST API is the actual source: `gh api
    repos/{owner}/{repo}/actions/runs/<run_id>/artifacts`. The {owner}/{repo}
    placeholders are resolved by `gh` itself from the repository of the
    current directory (documented in `gh help api`), matching how
    list_successful_runs() above already relies on `gh run list` resolving
    the repo from cwd rather than passing -R explicitly.

    An expired artifact is treated as absent: GitHub keeps the artifact's
    metadata after expiry, but `gh run download` on it fails, so a run whose
    only maldita-rbf has expired is exactly as unusable as one that never had
    it and must be skipped the same way.

    Fails loudly: a `gh` query error is NOT the same as "no artifacts", and
    must never be silently treated as "skip this run" -- that would make a
    transient API failure look identical to the linux-only-dispatch failure
    mode this whole check exists to catch.
    """
    endpoint = f"repos/{{owner}}/{{repo}}/actions/runs/{run_id}/artifacts"
    r = subprocess.run(
        ["gh", "api", endpoint],
        text=True, capture_output=True)
    if r.returncode != 0:
        raise RbfResolutionError(
            f"gh api {endpoint} failed -- is gh installed and "
            f"authenticated?\n{r.stderr}")
    try:
        data = json.loads(r.stdout or "{}")
    except json.JSONDecodeError as e:
        raise RbfResolutionError(
            f"gh api {endpoint} returned unparseable JSON: {e}")
    return [a.get("name") for a in data.get("artifacts", [])
            if not a.get("expired")]


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

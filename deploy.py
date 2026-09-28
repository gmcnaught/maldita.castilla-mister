#!/usr/bin/env python3
"""
Deploy the Maldita Castilla MiSTer port (gmloader engine + FPGA fabric core) to a
running MiSTer over SSH.

Modeled on solarus-mister/deploy.py — plain ssh/scp (the device is SSH-key-authed,
so `ssh root@<HOST>` needs no password), sha1-verified transfers (FAT can leave a
TRUNCATED file on a partial scp; a truncated ELF segfaults before main with no
output, so every artifact is verified).

Pulls the "latest" of the THREE moving pieces from their sibling source repos and
lays them into the device gmloader tree:

  1. RBF        the FPGA core (this repo, _Other/MalditaCastilla_YYYYMMDD.rbf) —
                gitignored, produced by .github/workflows/build-rbf.yml; fetch the
                newest artifact with `gh run download -n maldita-rbf -D _Other`.
                The lexicographically-last name wins (dates sort chronologically).
  2. ENGINE     gmloader-next armhf binary + gmloader.json (the loader that turns
                Maldita's GLES draws into the fabric command ring).
  3. CONTENT    the game payload: the APK, the 49MB game.droid, options.ini —
                checked into this repo at release/gamedata/ (origin and licence:
                release/gamedata/SOURCE.txt), so no sibling checkout is needed.

  (GL runtime) mesa/ + libGLES_sw.so + lib/armeabi-v7a/libstdc++.so are the
                surfaceless-Mesa closure. They rarely change and are not tracked in
                any repo here, so they are OPT-IN (--with-runtime DIR); by default
                the script assumes a prior full deploy already put them on-device
                and only refreshes the three moving pieces above.

Device tree (see gmloader-next/CLAUDE.md "MiSTer Deploy"):
  /media/fat/games/gmloader/
    gmloader            engine binary (this deploy)             <- ENGINE
    gmloader.json       apk_path = "mygame.apk"                 <- ENGINE
    mygame.apk          PortMaster malditacastilla.apk          <- CONTENT
    saves/game.droid    49MB game data                          <- CONTENT
    saves/options.ini                                            <- CONTENT
    lib/armeabi-v7a/    libstdc++.so                             <- runtime (opt-in)
    mesa/               surfaceless Mesa closure                 <- runtime (opt-in)
    libGLES_sw.so       = mesa libGLESv2.so.2                    <- runtime (opt-in)
  /media/fat/_Other/MalditaCastilla_*.rbf                        <- RBF
  launch path, rendered from mister-port.toml by external/mister-hybrid-platform
  (every deploy):
    games/gmloader/launch.sh + platform/           launcher, launch_lib, mem_wc
    Scripts/MalditaCastilla.sh, _CoresMenu.sh      Scripts entry, main= toggle
    games/gmloader/platform/hybrid.d/Maldita Castilla.conf  registry entry (OSD Reset bit 19)
    games/gmloader/platform/MiSTer_hybrid          this port's main= hook <- HOOK
    _Other/Maldita Castilla.mgl

PLATFORM (2026-09-26): the launcher, Scripts entries, mem_wc and the main= binary
now come from mister-hybrid-platform. MiSTer.ini [Maldita Castilla]
main=/media/fat/games/gmloader/platform/MiSTer_hybrid replaces main=.../MiSTer_Maldita;
the old wrapper is deleted once no section names it. Platform v0.4.0 moved the hook
and its registry out of linux/ (the Downloader refuses that root folder for every
database but distribution_mister); deploy.py moves a v0.3.x main= off
/media/fat/linux/MiSTer_hybrid the same way the Scripts entry does. The history
below explains why each piece exists; the file names in it are the pre-platform ones.

AUTO-LAUNCH (changed 2026-08-05): the engine is started by
  /media/fat/games/Maldita Castilla/launch.sh
which sets up its environment (BLITTER/RASTER, LD_LIBRARY_PATH, the takeover)
and execs it. Stock MiSTer main stays running and keeps its FPGA-readiness
contract (scheduler_co_poll's `while (!is_fpga_ready(1)) fpga_wait_to_reset();`).

TWO ENTRY POINTS, both installed AND BOTH ARMED BY DEFAULT, neither using a
daemon:
  1. Cores browser + MiSTer.ini `main=` — MiSTer execs our MiSTer_Maldita
     build, which forks launch.sh after the readiness check. The only way to
     get a Cores-browser entry that also starts the engine, so it is the route
     that has to work without anyone being told about it. --no-main-wrapper
     opts out.
  2. Scripts menu (Scripts/MalditaCastilla.sh) — loads the core via
     /dev/MiSTer_cmd itself, then execs launch.sh.

WHAT CHANGED, AND THE COST. Until 2026-08-05 the default was a third route:
MiSTer Frontier's Master_Daemon watching /tmp/CORENAME and running
games/<CORENAME>/_handler.sh. That route cannot coexist with either of the two
above — the daemon's only discovery predicate is the FILE NAME _handler.sh, so
the same core load triggers both it and the entry point, and two gmloader
processes land on one fabric control block (measured .62 2026-08-05: Scripts
2/2 runs, main= 5/5, C_DONE running backwards). Master_Daemon is third-party
and we do not own it, so the deconflict is on our side: install as launch.sh,
and DELETE any _handler.sh found on the device.

Removing the daemon removed a launch route, and on 2026-08-06 shipping that
with `main=` still opt-in produced a device that looked broken: .81 had been
relying on the daemon, the deploy deleted its _handler.sh, and selecting the
core from the Cores browser then loaded the bitstream and started NO engine —
gmloader procs 0, no maldita.log written at all, C_SUBMIT stuck at 0, and the
reader's stale-frame watchdog blanking the screen. A black screen after a
successful deploy cannot be told apart from a broken build, so `main=` is now
ARMED BY DEFAULT and --no-main-wrapper is the opt-out.

Still true, and still deliberate: nothing tears the engine down on a core
change any more — that was the daemon's kill_child.

`main=` was disabled on 2026-07-25 because the wrapper then REPLACED MiSTer's
main() with a hand-rolled loop (the dead `#else` branch — USE_SCHEDULER is
unconditional) that never ran the scheduler's per-iteration
`while (!is_fpga_ready(1)) fpga_wait_to_reset();` guard, and spawned the engine
before its first readiness check: 3/5 frame-1 wedges vs stock main 0/5.

The 2026-08-04 overlay rework fixed the cause rather than the symptom — upstream
main() and scheduler are now built verbatim and the entire local change is one
call inserted AFTER scheduler_wait_fpga_ready() (vendor/Main_MiSTer/maldita_hook.cpp).
Device-measured 2026-08-05 on .62 (daemon stopped, one engine): 0/5 frame-1
wedges, ~59fps, rendering correct — the gate the 2026-07-25 revert set. That
gate being met is what makes arming it by default defensible; the black-screen
deploy above is what makes it necessary.

HPS TAKEOVER (2026-08-04): not carried onto the platform (it was default-off and
never armed on a device); deploy.py removes any takeover.env / mister_takeover.sh.

Usage:
  ./deploy.py                      RBF + engine + content (the moving pieces)
  ./deploy.py --no-rbf             engine + content only
  ./deploy.py --no-content         RBF + engine only (skip the 49MB game.droid)
  ./deploy.py --engine-only        just the gmloader binary + gmloader.json
  ./deploy.py --no-engine          launch path only (launch.sh, Scripts entries, MGL,
                                   MiSTer_hybrid, main=) — leaves the
                                   device's engine binary alone, and skips its
                                   staleness gate with it
  ./deploy.py --with-runtime DIR   also push mesa/ + libGLES_sw.so + lib/ from DIR
  ./deploy.py --host 1.2.3.4       override device IP

Provenance gate (the engine and RBF are a matched pair with NO runtime handshake):
  ./deploy.py --fetch-rbf          pull the CI RBF built from THIS repo's HEAD and
                                   ship that — resolves by COMMIT, so a stale RBF is
                                   impossible by construction. Writes a .provenance.json
                                   sidecar beside it.
  ./deploy.py --rbf FILE           ship an explicit RBF (still gated; add --force for
                                   an intentionally odd-one-out bitstream)
  ./deploy.py --force              ship artifacts that FAIL the gate (stale engine,
                                   unprovenanced/stale RBF). Use when you mean it —
                                   bisecting, or A/B-ing an old core.

The gate refuses to deploy an RBF it cannot prove came from HEAD, or an engine binary
older than gmloader-next's HEAD commit. Both refusals print the fix. NOTE: --host
defaults to the BENCH unit (.81) — pass it explicitly for any other device.
"""

import argparse
import glob
import hashlib
import json
import shlex
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "scripts" / "lib"))
import resolve_rbf

HOST = "192.168.20.81"
USER = "root"
REPO = Path(__file__).resolve().parent            # maldita.castilla-mister
SIBLINGS = REPO.parent                            # ~/MisterFPGA-Projects
GAMEDIR = "/media/fat/games/gmloader"

# ── Auto-launch (games/gmloader/launch.sh, rendered from mister-port.toml) ─────
# MiSTer_hybrid finds the launcher through platform/hybrid.d/<CORENAME>.conf, so
# CORENAME MUST match the RBF's CONF_STR setname exactly (fpga/Maldita.sv) —
# including the space. It is also the MiSTer.ini section name.
CORENAME    = "Maldita Castilla"

# ── Source paths (sibling repos). Override any with the matching CLI flag. ──────
# Prefer the submodule so a fresh clone is self-sufficient; fall back to a
# sibling checkout so the per-workstream worktree flow keeps working.
_SUBMODULE_GM = REPO / "external/gmloader-next"
_SIBLING_GM   = SIBLINGS / "gmloader-next"
GMNEXT = _SUBMODULE_GM if (_SUBMODULE_GM / "Makefile.gmloader").is_file() else _SIBLING_GM

ENGINE_DEFAULT  = GMNEXT / "build/arm-linux-gnueabihf/gmloader/gmloadernext.armhf"
PLATFORM = REPO / "external/mister-hybrid-platform"
HOOK_DEFAULT = PLATFORM / "build/main-hook/MiSTer_hybrid"
HOOK_PATH = f"{GAMEDIR}/platform/MiSTer_hybrid"
# Platform v0.3.x shared hook + registry; deploy.py migrates off them.
LEGACY_HOOK = "/media/fat/linux/MiSTer_hybrid"
LEGACY_REGISTRY = "/media/fat/linux/hybrid.d"
LEGACY_WRAPPER = f"{GAMEDIR}/MiSTer_Maldita"
JSON_DEFAULT    = GMNEXT / "games/gmloader/gmloader.json"
# The game data is checked in (release/gamedata/, see its SOURCE.txt), so a
# fresh clone can deploy without a PortMaster-New checkout beside it.
GAMEDATA        = REPO / "release/gamedata"
APK_DEFAULT     = GAMEDATA / "mygame.apk"
DROID_DEFAULT   = GAMEDATA / "game.droid"
OPTIONS_DEFAULT = GAMEDATA / "options.ini"
RBF_GLOB        = str(REPO / "_Other" / "MalditaCastilla_*.rbf")


# ── Provenance gate ────────────────────────────────────────────────────────────
# WHY THIS EXISTS: the engine and the RBF are a MATCHED PAIR with no runtime
# handshake between them. CONF_STR advertises only "Maldita Castilla" — identical
# across every variant (m10k / wdfix2 / prewedgefix / floortex) — so nothing on the
# device can tell you which bitstream is loaded, and the engine's GIT_HASH defsym
# (Makefile.gmloader:70) is set from GITHUB_SHA, which is EMPTY for local Docker
# builds and is a linker symbol that is never printed anyway. Neither half carries
# a usable identity and nothing compares them, so a mismatch is silent.
#
# This script used to pick artifacts by filesystem heuristics — sorted(glob)[-1] for
# the RBF and a fixed build path for the engine — which silently accepts stale files.
# On 2026-07-27 that produced three near-misses in one session: a stale same-named
# RBF that was only caught by a manual md5, an engine binary that predated the audio
# merge by three hours, and --host defaulting to the wrong device.
#
# So the rule is now FAIL-CLOSED: refuse to ship an artifact we cannot prove came
# from the current HEAD. --force overrides for deliberate odd-one-out deploys
# (bisecting, A/B-ing an old bitstream), which is exactly when you WANT it explicit.
#
# The artifact/workflow names now live in scripts/lib/resolve_rbf.py, same reason
# as fpga_tree below: aliased here so deploy.py and release.yml cannot drift.
RBF_ARTIFACT   = resolve_rbf.RBF_ARTIFACT        # CI artifact name (build-rbf.yml)
RBF_WORKFLOW   = resolve_rbf.RBF_WORKFLOW


def git_head(repo):
    """(short_sha, commit_unixtime) for repo's HEAD, or (None, None) if not a git tree."""
    def q(*a):
        r = subprocess.run(["git", "-C", str(repo), *a], text=True, capture_output=True)
        return r.stdout.strip() if r.returncode == 0 else None
    sha = q("rev-parse", "--short", "HEAD")
    ts  = q("log", "-1", "--format=%ct")
    return (sha, int(ts)) if sha and ts else (None, None)


def sidecar_for(rbf):
    """Provenance file written beside an RBF when --fetch-rbf pulls it from CI."""
    return Path(str(rbf) + ".provenance.json")


# The tree-hash rule now lives in scripts/lib/resolve_rbf.py so deploy.py and
# .github/workflows/release.yml cannot drift. Kept as an alias because
# check_rbf_provenance() and the sidecar writer both call it.
fpga_tree = resolve_rbf.fpga_tree


def last_code_commit_time(repo, exclude=("docs", "*.md")):
    """Commit time of the newest commit touching anything but docs/prose.

    Same reasoning as fpga_tree(): a README tweak in gmloader-next must not mark a
    perfectly good engine binary 'stale'.
    """
    spec = [".", *(f":(exclude){p}" for p in exclude)]
    r = subprocess.run(["git", "-C", str(repo), "log", "-1", "--format=%ct", "--", *spec],
                       text=True, capture_output=True)
    try:
        return int(r.stdout.strip())
    except ValueError:
        return None


def sha1_of(path):
    return hashlib.sha1(Path(path).read_bytes()).hexdigest()


def fetch_rbf_for_head():
    """Download the CI RBF built from THIS repo's HEAD and write its provenance sidecar.

    Resolving by commit (not by "newest artifact") is the whole point: it makes a stale
    RBF impossible by construction rather than by discipline.
    """
    sha_short, _ = git_head(REPO)
    full = subprocess.run(["git", "-C", str(REPO), "rev-parse", "HEAD"],
                          text=True, capture_output=True).stdout.strip()
    if not full:
        raise SystemExit("FATAL: --fetch-rbf needs a git checkout of this repo")
    try:
        run_id, built_sha, want_tree = resolve_rbf.resolve_run_id(REPO)
    except resolve_rbf.RbfResolutionError as e:
        raise SystemExit(f"FATAL: {e}")
    print(f"-- Resolving CI RBF for {REPO.name} HEAD {sha_short} (fpga/ tree {want_tree[:9]}) --")
    if built_sha != full:
        print(f"   (HEAD did not touch fpga/; using the build from {built_sha[:7]}, "
              "whose RTL is identical)")
    full = built_sha
    sha_short = built_sha[:7]
    dest = REPO / "_Other"
    dest.mkdir(parents=True, exist_ok=True)
    # gh refuses to overwrite, and a same-named STALE file is exactly the trap that bit
    # us — stage into a scratch dir, then move into place under a commit-stamped name.
    tmp = dest / f".fetch_{run_id}"
    subprocess.run(["rm", "-rf", str(tmp)], check=False)
    tmp.mkdir(parents=True, exist_ok=True)
    r = subprocess.run(["gh", "run", "download", str(run_id), "-n", RBF_ARTIFACT,
                        "-D", str(tmp)], text=True, capture_output=True)
    if r.returncode != 0:
        raise SystemExit(f"FATAL: gh run download failed\n{r.stderr}")
    got = sorted(tmp.glob("*.rbf"))
    if not got:
        raise SystemExit(f"FATAL: artifact {RBF_ARTIFACT} contained no .rbf")
    final = dest / f"MalditaCastilla_{sha_short}.rbf"
    Path(got[0]).replace(final)
    subprocess.run(["rm", "-rf", str(tmp)], check=False)
    sidecar_for(final).write_text(json.dumps({
        "commit": sha_short, "commit_full": full, "ci_run_id": run_id,
        "fpga_tree": fpga_tree(REPO, full),   # the real bitstream identity
        "tree_algo": resolve_rbf.TREE_ALGO,   # see check_rbf_provenance()
        "sha1": sha1_of(final), "fetched_at": int(time.time()),
        "workflow": RBF_WORKFLOW,
    }, indent=2) + "\n")
    print(f"   {final.name}  (run {run_id}, commit {sha_short})")
    print(f"   sidecar: {sidecar_for(final).name}")
    return final


def check_rbf_provenance(rbf, force):
    """Return a summary dict; refuse (unless force) if the RBF is not provably HEAD's."""
    head, _ = git_head(REPO)
    sc = sidecar_for(rbf)
    def bail(msg):
        if force:
            print(f"   !! {msg}  (--force: shipping anyway)")
            return
        raise SystemExit(
            f"FATAL: {msg}\n"
            f"       RBF: {rbf}\n"
            "       Fix: ./deploy.py --fetch-rbf   (pulls the CI build for HEAD)\n"
            "       Or:  re-run with --force to ship it deliberately.")
    if not sc.exists():
        bail("RBF has no provenance sidecar — cannot prove which commit built it")
        return {"commit": "unknown", "sha1": sha1_of(rbf)[:12], "note": "unverified"}
    meta = json.loads(sc.read_text())
    actual = sha1_of(rbf)
    if meta.get("sha1") != actual:
        bail("RBF contents do not match its provenance sidecar (file was replaced)")
    # The tree hash's algorithm changed under fix/fpga-tree-narrow (algo 1 = the
    # whole fpga/ tree; algo 2 = fpga/ minus fpga/sim, fpga/docs — see
    # resolve_rbf.TREE_ALGO). A sidecar written under an older algo is NOT
    # comparable to a hash computed under a newer one; the two numbering
    # schemes measure different things and an inequality between them proves
    # nothing about whether the RTL moved. Check the algo BEFORE comparing
    # trees so a stale-format sidecar bails with an honest "cannot compare"
    # message instead of the "STALE RBF" message below, which would be
    # actively wrong here.
    got_algo = meta.get("tree_algo")
    if got_algo is None or got_algo < resolve_rbf.TREE_ALGO:
        bail("RBF sidecar was written by an older provenance format "
             f"(tree_algo={got_algo!r}, current is {resolve_rbf.TREE_ALGO}) — "
             "the recorded fpga/ tree hash cannot be compared against HEAD's. "
             "This does NOT mean the RBF is stale.")
        return {"commit": meta.get("commit"), "sha1": actual[:12],
                "ci_run_id": meta.get("ci_run_id"), "note": "unverified (old provenance format)"}
    # Gate on the fpga/ TREE, not the commit — see fpga_tree(). An RBF built from an
    # older commit is still current so long as fpga/ has not moved since.
    want_tree, got_tree = fpga_tree(REPO), meta.get("fpga_tree")
    if want_tree and got_tree and got_tree != want_tree:
        bail(f"RBF was built from fpga/ tree {got_tree[:9]} but HEAD's is "
             f"{want_tree[:9]} — STALE RBF (the RTL moved since this bitstream)")
    elif want_tree and not got_tree:
        bail("RBF sidecar predates the fpga-tree check — cannot prove the RTL matches")
    note = "verified"
    if head and meta.get("commit") != head:
        # Not an error: fpga/ matches, so the bitstream is current even though other
        # (CI/docs/tooling) commits have landed on top of the one that built it.
        note = f"verified (built at {meta.get('commit')}, fpga/ unchanged since)"
    return {"commit": meta.get("commit"), "sha1": actual[:12],
            "ci_run_id": meta.get("ci_run_id"), "note": note}


def check_engine_freshness(engine, force):
    """Refuse (unless force) if the engine binary predates gmloader-next's HEAD commit.

    This is the exact 2026-07-27 failure: the local build/ artifact was three hours
    older than the merge that added native audio, so an --engine deploy would have
    silently shipped an engine WITHOUT the feature being tested.

    When the reference commit time cannot be determined at all (submodule absent
    AND sibling checkout absent/not-git), that is UNKNOWN, not fresh — refuse
    unless --force, the same fail-closed treatment check_rbf_provenance already
    gives an unprovable RBF. `stale = ctime is not None and mtime < ctime` used to
    evaluate False in this case, silently reporting "fresh" without ever having
    evaluated the condition.
    """
    src = GMNEXT
    sha, _ = git_head(src)
    ctime = last_code_commit_time(src)   # ignore docs-only commits — see the helper
    mtime = int(Path(engine).stat().st_mtime)
    if ctime is None:
        if not src.exists():
            reason = f"{src} does not exist (neither the submodule nor the sibling checkout is present)"
        elif sha is None:
            reason = f"{src} exists but is not a usable git checkout (git rev-parse HEAD failed)"
        else:
            reason = f"{src} is a git checkout but `git log` returned no commit time (shallow clone or empty history?)"
        msg = (f"cannot determine gmloader-next's HEAD commit time — staleness is "
               f"UNKNOWN, not fresh\n"
               f"       looked in: {src}\n"
               f"       reason:    {reason}")
        if force:
            print(f"   !! {msg}  (--force: shipping anyway)")
        else:
            raise SystemExit(
                f"FATAL: {msg}\n"
                "       Fix: populate external/gmloader-next (submodule) or the "
                "../gmloader-next sibling checkout, then re-run.\n"
                "       Or:  re-run with --force to ship it deliberately.")
        return {"commit": sha or "unknown",
                "built": time.strftime("%Y-%m-%d %H:%M", time.localtime(mtime)),
                "md5": hashlib.md5(Path(engine).read_bytes()).hexdigest()[:12],
                "note": "UNKNOWN (no reference commit time)"}
    stale = mtime < ctime
    if stale:
        msg = (f"engine binary is OLDER than gmloader-next HEAD ({sha}) — STALE BUILD\n"
               f"       binary mtime : {time.strftime('%Y-%m-%d %H:%M', time.localtime(mtime))}\n"
               f"       HEAD committed: {time.strftime('%Y-%m-%d %H:%M', time.localtime(ctime))}")
        if force:
            print(f"   !! {msg}  (--force: shipping anyway)")
        else:
            raise SystemExit(
                f"FATAL: {msg}\n"
                "       Fix: rebuild it (see gmloader-next/CLAUDE.md 'Build'), then re-run.\n"
                "       Or:  re-run with --force to ship it deliberately.")
    return {"commit": sha or "unknown",
            "built": time.strftime("%Y-%m-%d %H:%M", time.localtime(mtime)),
            "md5": hashlib.md5(Path(engine).read_bytes()).hexdigest()[:12],
            "note": "stale" if stale else "fresh"}


def sh(args, **kw):
    print("  $", " ".join(str(a) for a in args))
    return subprocess.run(args, **kw)


def ssh(host, cmd, check=False):
    return sh(["ssh", f"{USER}@{host}", cmd], check=check, text=True, capture_output=True)


def scp(host, src, dst):
    # Remote path stays RAW and unquoted: this scp speaks SFTP, which takes the path
    # literally rather than through a remote shell, so shell-quoting it would embed the
    # quote characters in the filename. Safe because subprocess passes it as one argv
    # element — the space in "Maldita Castilla" never gets word-split locally.
    return sh(["scp", "-q", str(src), f"{USER}@{host}:{dst}"], check=True)


def scp_verified(host, src, dst, retries=3):
    """scp + sha1 verify, retrying on mismatch (FAT truncation guard)."""
    want = hashlib.sha1(Path(src).read_bytes()).hexdigest()
    # ssh() runs its argument through a shell ON THE DEVICE, so paths bound for rm/sha1sum
    # MUST be shell-quoted — the handler lives under "Maldita Castilla" (CONF_STR setname,
    # space included), and unquoted it word-split into two bogus paths: sha1sum then
    # reported nothing, every retry "mismatched", and the deploy died BEFORE the RBF
    # upload — leaving a new engine beside a stale core, the exact mismatched pair the
    # no-handshake contract cannot detect.
    q = shlex.quote(dst)
    for attempt in range(1, retries + 1):
        ssh(host, f"rm -f {q}")
        scp(host, src, dst)
        got = ssh(host, f"sha1sum {q} 2>/dev/null").stdout.split()[:1]
        if got and got[0] == want:
            print(f"    sha1 ok ({want[:12]})  {dst}")
            return
        print(f"    sha1 mismatch (attempt {attempt}/{retries}) — retrying")
    raise SystemExit(f"FATAL: {dst} failed sha1 verification after {retries} tries")


def install_launch_path(host, hook, arm_main):
    """Render mister-port.toml with the platform and install the tree.

    One tar stream (no xattrs, no owner) instead of a scp per file: the tree has
    ~20 files, some with a space in their path. Then, on the device: remove what
    pre-platform deploys installed (dist/scripts-extra.sh, as the Scripts entry does), point (or un-point)
    MiSTer.ini [Maldita Castilla] main= at MiSTer_hybrid through the platform's
    section-scoped ini_main.sh, and delete MiSTer_Maldita once no section names it.
    """
    import os
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        sh([sys.executable, str(PLATFORM / "tools/mister_platform.py"), "render",
            str(REPO / "mister-port.toml"), "--out", tmp, "--hook-binary", str(hook)], check=True)
        print("\n-- Installing the platform launch path (mister-port.toml) --")
        tar = subprocess.Popen(["tar", "--no-xattrs", "-C", tmp, "-cf", "-", "."],
                               stdout=subprocess.PIPE, env={**os.environ, "COPYFILE_DISABLE": "1"})
        r = subprocess.run(["ssh", f"{USER}@{host}", "tar --no-same-owner -C /media/fat -xf -"],
                           stdin=tar.stdout)
        tar.stdout.close()
        if tar.wait() != 0 or r.returncode != 0:
            raise SystemExit("FATAL: launch-path install failed")
    gd = shlex.quote(GAMEDIR)
    cleanup = (REPO / "dist/scripts-extra.sh").read_text()
    ini_cmd = (f'mh_ini_set_main {HOOK_PATH} && echo "   main= -> {HOOK_PATH}"' if arm_main else
               f'for h in {HOOK_PATH} {LEGACY_HOOK}; do if [ "$(mh_ini_main)" = "$h" ]; then '
               'mh_ini_disable_main "$h" deploy.py && echo "   main= disarmed (--no-main-wrapper)"; fi; done')
    script = f"""
set -e
chmod 755 {gd}/launch.sh {HOOK_PATH} /media/fat/Scripts/MalditaCastilla.sh /media/fat/Scripts/MalditaCastilla_CoresMenu.sh
GAMEDIR={gd}
{cleanup}
test -e {gd}/_handler.sh && {{ echo "FATAL: _handler.sh survived"; exit 1; }}
MH_INI_FILE=/media/fat/MiSTer.ini MH_INI_SECTION={shlex.quote(CORENAME)}
. {gd}/platform/ini_main.sh
{ini_cmd}
if [ -f {LEGACY_WRAPPER} ] && ! grep -q '^main={LEGACY_WRAPPER}' /media/fat/MiSTer.ini; then
    rm -f {LEGACY_WRAPPER} && echo "   removed {LEGACY_WRAPPER}"
fi
if [ "$(mh_ini_main)" != {LEGACY_HOOK} ] && [ -f {shlex.quote(LEGACY_REGISTRY + "/" + CORENAME + ".conf")} ]; then
    rm -f {shlex.quote(LEGACY_REGISTRY + "/" + CORENAME + ".conf")} && echo "   removed {LEGACY_REGISTRY}/{CORENAME}.conf"
    rmdir {LEGACY_REGISTRY} 2>/dev/null || true
fi
if [ -f {LEGACY_HOOK} ] && ! grep -q '^main={LEGACY_HOOK}' /media/fat/MiSTer.ini; then
    rm -f {LEGACY_HOOK} && echo "   removed {LEGACY_HOOK}"
fi
"""
    r = ssh(host, script)
    print((r.stdout or "").rstrip())
    if r.returncode != 0:
        raise SystemExit(f"FATAL: launch-path setup failed: {(r.stderr or '').strip()}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default=HOST)
    ap.add_argument("--engine", type=Path, default=ENGINE_DEFAULT,
                    help="gmloader armhf binary (default: gmloader-next build)")
    ap.add_argument("--hook", "--wrapper", dest="wrapper", type=Path, default=HOOK_DEFAULT,
                    help="MiSTer_hybrid main= hook (default: external/mister-hybrid-platform/"
                         "build/main-hook, from its device/main-hook/build-hps.sh)")
    ap.add_argument("--no-rbf", action="store_true", help="skip the FPGA core RBF")
    ap.add_argument("--no-content", action="store_true",
                    help="skip the APK + 49MB game.droid + options.ini")
    ap.add_argument("--no-engine", action="store_true",
                    help="skip the gmloader binary (and its staleness gate). For "
                         "launch-path-only deploys — installing launch.sh, the Scripts "
                         "entry or --main-wrapper on a device whose engine is already "
                         "newer than the local build.")
    ap.add_argument("--engine-only", action="store_true",
                    help="just the gmloader binary + gmloader.json (implies --no-rbf --no-content)")
    ap.add_argument("--with-runtime", type=Path, metavar="DIR",
                    help="also push the GL runtime (mesa/, libGLES_sw.so, lib/) from DIR")
    ap.add_argument("--rbf", type=Path, default=None,
                    help="explicit RBF to ship (default: newest provenanced _Other/*.rbf)")
    ap.add_argument("--fetch-rbf", action="store_true",
                    help="download the CI RBF built from THIS repo's HEAD, then deploy it")
    ap.add_argument("--force", action="store_true",
                    help="ship artifacts that fail the provenance/staleness gate")
    # ON BY DEFAULT. With Master_Daemon out of the launch path, this is the only
    # thing that makes a Cores-browser core load start the engine, and a deploy
    # that leaves the core selectable but dead is a broken deploy -- see the
    # arming block for the .81 measurement that changed this. --main-wrapper is
    # kept as an accepted no-op so existing scripts and muscle memory still work.
    ap.add_argument("--main-wrapper", action="store_true",
                    help="(default, kept for compatibility) write the MiSTer.ini "
                         "[Maldita Castilla] main= line, so selecting the core from the "
                         "Cores browser starts the engine with no daemon")
    ap.add_argument("--no-main-wrapper", action="store_true",
                    help="OPT OUT: comment out the MiSTer.ini main= line, leaving the "
                         "Scripts entry as the only launch route. A Cores-browser load "
                         "will then start no engine and the screen stays black.")
    args = ap.parse_args()
    if args.no_engine and args.engine_only:
        ap.error("--no-engine and --engine-only are mutually exclusive")
    if args.main_wrapper and args.no_main_wrapper:
        ap.error("--main-wrapper and --no-main-wrapper are mutually exclusive")
    host = args.host
    if args.engine_only:
        args.no_rbf = args.no_content = True

    # ── Resolve + verify sources present ──────────────────────────────────────
    engine = args.engine
    wrapper = args.wrapper
    gmjson = JSON_DEFAULT
    need = [wrapper, gmjson] if args.no_engine else [engine, wrapper, gmjson]
    if not args.no_content:
        need += [APK_DEFAULT, DROID_DEFAULT, OPTIONS_DEFAULT]
    missing = [p for p in need if not p.exists()]
    if missing:
        for p in missing:
            print(f"MISSING: {p}", file=sys.stderr)
        print("\n(build the engine in gmloader-next, the hook via "
              "external/mister-hybrid-platform/device/main-hook/build-hps.sh, "
              "or pass --engine / --hook / --no-content)",
              file=sys.stderr)
        sys.exit(1)

    rbf = None
    rbf_info = engine_info = None
    if not args.no_rbf:
        if args.fetch_rbf:
            rbf = fetch_rbf_for_head()
        elif args.rbf:
            rbf = args.rbf
            if not rbf.exists():
                sys.exit(f"MISSING: --rbf {rbf}")
        else:
            # Prefer a PROVENANCED rbf over merely the lexicographically-last one:
            # sorted()[-1] is what let a stale same-named file win before.
            cands = [Path(p) for p in sorted(glob.glob(RBF_GLOB))]
            provenanced = [p for p in cands if sidecar_for(p).exists()]
            pick = provenanced or cands
            if pick:
                rbf = pick[-1]
            else:
                print("note: no local _Other/MalditaCastilla_*.rbf — skipping RBF.\n"
                      "      fetch the one matching HEAD with: ./deploy.py --fetch-rbf")
    if rbf is not None:
        rbf_info = check_rbf_provenance(rbf, args.force)
    engine_info = None if args.no_engine else check_engine_freshness(engine, args.force)

    runtime = None
    if args.with_runtime:
        runtime = args.with_runtime
        if not runtime.is_dir():
            print(f"MISSING: --with-runtime dir {runtime}", file=sys.stderr)
            sys.exit(1)

    # ── Pair summary — printed BEFORE anything touches the device ─────────────
    # The two halves have no runtime handshake, so this is the only place the
    # operator gets to see what is actually about to ship next to what.
    print(f"Deploying Maldita Castilla to {USER}@{host}\n")
    print("  ┌─ artifact pair " + "─" * 44)
    if rbf_info:
        print(f"  │ RBF    {rbf.name}")
        print(f"  │        commit {rbf_info['commit']}  sha1 {rbf_info['sha1']}  [{rbf_info['note']}]")
    else:
        print("  │ RBF    (not shipping — core on device stays as-is)")
    if engine_info:
        print(f"  │ ENGINE {Path(engine).name}")
        print(f"  │        gmloader-next {engine_info['commit']}  built {engine_info['built']}  "
              f"md5 {engine_info['md5']}  [{engine_info['note']}]")
    else:
        print("  │ ENGINE (not shipping — binary on device stays as-is)")
    print("  └" + "─" * 60)
    # A partial deploy is legitimate (bisecting, A/B) but it is ALSO how the halves
    # drift apart, so name the risk instead of letting it pass silently.
    if args.no_rbf or args.no_content or args.no_engine:
        skipped = [n for n, s in (("RBF", args.no_rbf), ("content", args.no_content),
                                  ("engine", args.no_engine)) if s]
        print(f"\n  !! PARTIAL DEPLOY — not shipping: {', '.join(skipped)}")
        print("     The engine and RBF are a matched pair with no runtime handshake;")
        print("     whatever is already on the device for the skipped half stays put.")
    print()

    # ── Stop the running engine so its binary can be replaced ─────────────────
    # No pkill on device busybox; match `gmloader -c` in ps ([g] keeps grep off
    # itself). Then remove the old binary (FAT can't overwrite a still-open exe).
    # Skipped with --no-engine: the binary is not being replaced, so there is no
    # reason to kill a running session or delete an executable we are keeping.
    #
    # SIGTERM first, -9 only as a backstop. -9 is uncatchable, so the engine runs
    # no fabric teardown (raster_backend_mfgpu.cpp, mf_fabric_teardown) and leaves
    # the blitter's DDR window at 0x3B000000 with a live doorbell over its own
    # command ring. Nothing clears that window between engines — not load_core,
    # which reconfigures the FPGA and not DDR — so the next engine inherits a
    # fabric already executing a batch nobody submitted. Its bring-up now digs
    # itself out of that, but a clean exit is free and a recovery is not.
    if not args.no_engine:
        print("-- Stopping running gmloader (SIGTERM, then SIGKILL) --")
        ssh(host, "gmpids() { ps -o pid,args 2>/dev/null | grep '[g]mloader -c' | awk '{print $1}'; }; "
                  "for p in $(gmpids); do kill -TERM \"$p\" 2>/dev/null; done; "
                  "n=0; while [ \"$n\" -lt 3 ] && [ -n \"$(gmpids)\" ]; do sleep 1; n=$((n+1)); done; "
                  "for p in $(gmpids); do echo \"gmloader $p ignored SIGTERM - SIGKILL\" >&2; "
                  "kill -9 \"$p\" 2>/dev/null; done; sleep 1; "
                  f"rm -f {GAMEDIR}/gmloader; true")

    print("\n-- Creating remote dirs --")
    ssh(host, f"mkdir -p {GAMEDIR}/saves {GAMEDIR}/lib/armeabi-v7a {GAMEDIR}/mesa "
              "/media/fat/_Other", check=True)

    if args.no_engine:
        print("\n-- Skipping engine binary (--no-engine); shipping gmloader.json only --")
        scp_verified(host, gmjson, f"{GAMEDIR}/gmloader.json")
    else:
        print("\n-- Uploading engine binary + gmloader.json (sha1-verified) --")
        scp_verified(host, engine, f"{GAMEDIR}/gmloader")
        scp_verified(host, gmjson, f"{GAMEDIR}/gmloader.json")

    install_launch_path(host, wrapper, not args.no_main_wrapper)

    if not args.no_content:
        print("\n-- Uploading content (APK + game.droid + options.ini, sha1-verified) --")
        scp_verified(host, APK_DEFAULT, f"{GAMEDIR}/mygame.apk")
        scp_verified(host, DROID_DEFAULT, f"{GAMEDIR}/saves/game.droid")     # 49MB
        scp_verified(host, OPTIONS_DEFAULT, f"{GAMEDIR}/saves/options.ini")

    if runtime:
        print(f"\n-- Uploading GL runtime from {runtime} --")
        libgles = runtime / "libGLES_sw.so"
        libstdcpp = runtime / "lib/armeabi-v7a/libstdc++.so"
        mesadir = runtime / "mesa"
        if libgles.exists():
            scp_verified(host, libgles, f"{GAMEDIR}/libGLES_sw.so")
        if libstdcpp.exists():
            scp_verified(host, libstdcpp, f"{GAMEDIR}/lib/armeabi-v7a/libstdc++.so")
        if mesadir.is_dir():
            for so in sorted(mesadir.glob("*.so*")):
                scp_verified(host, so, f"{GAMEDIR}/mesa/{so.name}")
    elif not (args.no_rbf and args.no_content):
        print("\n-- GL runtime: assuming mesa/ + libGLES_sw.so + lib/ already on-device --")
        r = ssh(host, f"ls {GAMEDIR}/libGLES_sw.so {GAMEDIR}/mesa/libEGL.so.1 2>/dev/null | wc -l")
        if (r.stdout or "0").strip() != "2":
            print("    WARN: GL runtime looks absent on-device (no libGLES_sw.so / mesa/libEGL.so.1).\n"
                  "          gmloader will fail to init GLES. Re-run with --with-runtime DIR.")

    if rbf:
        print(f"\n-- Uploading RBF {rbf.name} (sha1-verified) --")
        scp_verified(host, rbf, f"/media/fat/_Other/{rbf.name}")


    if not args.no_engine:
        print("\n-- Fixing exec bit on the engine --")
        ssh(host, f"chmod 755 {GAMEDIR}/gmloader", check=True)

    print("\n-- Deployed tree --")
    r = ssh(host, f"ls -la {GAMEDIR}/ {GAMEDIR}/saves/ 2>/dev/null | head -40; "
                  "ls -la /media/fat/_Other/MalditaCastilla_*.rbf 2>/dev/null")
    print(r.stdout)

    print("Done. Load the Maldita Castilla core from the MiSTer menu, then run the engine.\n"
          "IMPORTANT: the fabric path needs BOTH env vars — GMLOADER_BLITTER=2 turns the\n"
          "blitter/RasterBackend on (level 2 = blitter owns rendering), GMLOADER_RASTER=mfgpu\n"
          "selects the fabric backend. With BLITTER unset the engine paints the dead 0x3A DDR\n"
          "buffer this core no longer scans out (black). Verify with `busybox devmem 0x3B000000`\n"
          "climbing while it runs:\n"
          f"  ssh {USER}@{host} 'cd {GAMEDIR} && GMLOADER_BLITTER=2 GMLOADER_RASTER=mfgpu \\\n"
          f"    LD_LIBRARY_PATH={GAMEDIR}/mesa:{GAMEDIR} ./gmloader -c gmloader.json'")


if __name__ == "__main__":
    main()

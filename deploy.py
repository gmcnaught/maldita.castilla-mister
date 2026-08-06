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
  3. CONTENT    the PortMaster game payload: the APK, the 49MB game.droid, options.ini.

  (GL runtime) mesa/ + libGLES_sw.so + lib/armeabi-v7a/libstdc++.so are the
                surfaceless-Mesa closure. They rarely change and are not tracked in
                any repo here, so they are OPT-IN (--with-runtime DIR); by default
                the script assumes a prior full deploy already put them on-device
                and only refreshes the three moving pieces above.

Device tree (see gmloader-next/CLAUDE.md "MiSTer Deploy"):
  /media/fat/games/gmloader/
    gmloader            engine binary (this deploy)             <- ENGINE
    MiSTer_Maldita      HPS wrapper binary (this deploy)         <- WRAPPER
    gmloader.json       apk_path = "mygame.apk"                 <- ENGINE
    mygame.apk          PortMaster malditacastilla.apk          <- CONTENT
    saves/game.droid    49MB game data                          <- CONTENT
    saves/options.ini                                            <- CONTENT
    lib/armeabi-v7a/    libstdc++.so                             <- runtime (opt-in)
    mesa/               surfaceless Mesa closure                 <- runtime (opt-in)
    libGLES_sw.so       = mesa libGLESv2.so.2                    <- runtime (opt-in)
  /media/fat/_Other/MalditaCastilla_*.rbf                        <- RBF

AUTO-LAUNCH (changed 2026-08-05): the engine is started by
  /media/fat/games/Maldita Castilla/launch.sh
which sets up its environment (BLITTER/RASTER, LD_LIBRARY_PATH, the takeover)
and execs it. Stock MiSTer main stays running and keeps its FPGA-readiness
contract (scheduler_co_poll's `while (!is_fpga_ready(1)) fpga_wait_to_reset();`).

TWO ENTRY POINTS, both installed, NEITHER using a daemon:
  1. Scripts menu (Scripts/MalditaCastilla.sh) — loads the core via
     /dev/MiSTer_cmd itself, then execs launch.sh. This is the DEFAULT route.
  2. Cores browser + MiSTer.ini `main=` (--main-wrapper) — MiSTer execs our
     MiSTer_Maldita build, which forks launch.sh after the readiness check. The
     only way to get a Cores-browser entry that also starts the engine.

WHAT CHANGED, AND THE COST. Until 2026-08-05 the default was a third route:
MiSTer Frontier's Master_Daemon watching /tmp/CORENAME and running
games/<CORENAME>/_handler.sh. That route cannot coexist with either of the two
above — the daemon's only discovery predicate is the FILE NAME _handler.sh, so
the same core load triggers both it and the entry point, and two gmloader
processes land on one fabric control block (measured .62 2026-08-05: Scripts
2/2 runs, main= 5/5, C_DONE running backwards). Master_Daemon is third-party
and we do not own it, so the deconflict is on our side: install as launch.sh,
and DELETE any _handler.sh found on the device.

The cost is real and intended: WITHOUT --main-wrapper, selecting the core from
the Cores browser now loads the bitstream and starts NO engine. Use the Scripts
entry, or arm --main-wrapper. Nothing tears the engine down on a core change
any more either — that was the daemon's kill_child.

--main-wrapper / --no-main-wrapper are STICKY: neither flag leaves the device's
main= line exactly as it is, so a deploy for an unrelated reason cannot turn a
user's chosen entry point off under them.

`main=` was disabled on 2026-07-25 because the wrapper then REPLACED MiSTer's
main() with a hand-rolled loop (the dead `#else` branch — USE_SCHEDULER is
unconditional) that never ran the scheduler's per-iteration
`while (!is_fpga_ready(1)) fpga_wait_to_reset();` guard, and spawned the engine
before its first readiness check: 3/5 frame-1 wedges vs stock main 0/5.

The 2026-08-04 overlay rework fixed the cause rather than the symptom — upstream
main() and scheduler are now built verbatim and the entire local change is one
call inserted AFTER scheduler_wait_fpga_ready() (vendor/Main_MiSTer/maldita_hook.cpp).
Device-measured 2026-08-05 on .62 (daemon stopped, one engine): 0/5 frame-1
wedges, ~59fps, rendering correct — the gate the 2026-07-25 revert set. It stays
OPT-IN -- it is not armed unless you ask for it -- but once armed it STAYS
armed; use --no-main-wrapper to turn it off.

HPS TAKEOVER (2026-08-04, opt-in, default OFF): games/<CORENAME>/mister_takeover.sh
ships alongside launch.sh and is INERT unless a takeover.env sits next to it.
Armed, it lets stock MiSTer main load the core and satisfy its readiness contract,
waits for the engine to prove itself live on the fabric (C_DONE advancing), then
kills MiSTer and restarts it on every exit path — the DreamSTer model, taken late.
--takeover / --no-takeover manage that marker; neither flag leaves it untouched.
Design: docs/superpowers/specs/2026-08-04-hps-takeover-launcher-design.md.

Usage:
  ./deploy.py                      RBF + engine + content (the moving pieces)
  ./deploy.py --no-rbf             engine + content only
  ./deploy.py --no-content         RBF + engine only (skip the 49MB game.droid)
  ./deploy.py --engine-only        just the gmloader binary + gmloader.json
  ./deploy.py --no-engine          launch path only (launch.sh, Scripts entry, MGL,
                                   wrapper, main=/takeover markers) — leaves the
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

# ── Auto-launch (launch.sh, driven by the Scripts entry or the main= hook) ─────
# Both entry points hardcode /media/fat/games/<CORENAME>/launch.sh, and the
# `main=` hook additionally compares user_io_get_core_name() against this
# string, so it MUST match the RBF's CONF_STR setname exactly
# (fpga/Maldita.sv:270) — including the space.
CORENAME    = "Maldita Castilla"
HANDLER_DIR = f"/media/fat/games/{CORENAME}"

# ── Source paths (sibling repos). Override any with the matching CLI flag. ──────
# Prefer the submodule so a fresh clone is self-sufficient; fall back to a
# sibling checkout so the per-workstream worktree flow keeps working.
_SUBMODULE_GM = REPO / "external/gmloader-next"
_SIBLING_GM   = SIBLINGS / "gmloader-next"
GMNEXT = _SUBMODULE_GM if (_SUBMODULE_GM / "Makefile.gmloader").is_file() else _SIBLING_GM

ENGINE_DEFAULT  = GMNEXT / "build/arm-linux-gnueabihf/gmloader/gmloadernext.armhf"
WRAPPER_DEFAULT = REPO / "build/mister-wrapper-hps/MiSTer_Maldita"
JSON_DEFAULT    = GMNEXT / "games/gmloader/gmloader.json"
PORTMASTER      = SIBLINGS / "PortMaster-New/ports/maldita.castilla/maldita.castilla"
APK_DEFAULT     = PORTMASTER / "malditacastilla.apk"
DROID_DEFAULT   = PORTMASTER / "gamedata/game.droid"
OPTIONS_DEFAULT = PORTMASTER / "gamedata/options.ini"
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default=HOST)
    ap.add_argument("--engine", type=Path, default=ENGINE_DEFAULT,
                    help="gmloader armhf binary (default: gmloader-next build)")
    ap.add_argument("--wrapper", type=Path, default=WRAPPER_DEFAULT,
                    help="MiSTer_Maldita HPS wrapper binary (default: build/mister-wrapper-hps)")
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
    # ── HPS takeover (docs/superpowers/specs/2026-08-04-hps-takeover-launcher-design.md)
    # Default is NEITHER flag: the on-device takeover.env is left exactly as it
    # is, so a redeploy never silently arms or disarms a device.
    ap.add_argument("--takeover", action="store_true",
                    help="arm the HPS takeover: once the engine proves live on the "
                         "fabric, Main_MiSTer is killed and restarted on exit. NO "
                         "GAMEPAD until gmloader-next lands GMLOADER_JOY=sdl — keep "
                         "an SSH session open. Use .62, not production.")
    ap.add_argument("--takeover-dryrun", action="store_true",
                    help="with --takeover: run and log every takeover step but kill "
                         "nothing and change no cpufreq setting")
    ap.add_argument("--takeover-governor", action="store_true",
                    help="with --takeover: performance governor + 1 GHz while the "
                         "game runs, restored on exit")
    ap.add_argument("--no-takeover", action="store_true",
                    help="disarm the HPS takeover (removes the device's takeover.env)")
    # Sticky, like --takeover: neither flag leaves the device's main= line as it
    # is. It used to disarm on every deploy that did not ask for it, on the
    # grounds that the wrapper was not device-proven -- it now is (0/5 frame-1
    # wedges on .62, twice), and silent disarming meant any later deploy for an
    # unrelated reason turned the user's chosen entry point off under them.
    ap.add_argument("--main-wrapper", action="store_true",
                    help="write the MiSTer.ini [Maldita Castilla] main= line, so selecting "
                         "the core from the Cores browser starts the engine with no daemon. "
                         "Sticky: a later deploy without this flag leaves it armed.")
    ap.add_argument("--no-main-wrapper", action="store_true",
                    help="comment out the MiSTer.ini main= line (back to the Scripts entry "
                         "as the only launch route)")
    args = ap.parse_args()
    if args.takeover and args.no_takeover:
        ap.error("--takeover and --no-takeover are mutually exclusive")
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
        print("\n(build the engine in gmloader-next, the wrapper via "
              "tools/mister-wrapper/build-hps.sh, or pass --engine / --wrapper / --no-content)",
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
    if not args.no_engine:
        print("-- Stopping running gmloader --")
        ssh(host, "for p in $(ps -o pid,args 2>/dev/null | grep '[g]mloader -c' | awk '{print $1}'); do "
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

    print("\n-- Uploading HPS wrapper binary (sha1-verified; used only with --main-wrapper) --")
    scp_verified(host, wrapper, f"{GAMEDIR}/MiSTer_Maldita")

    # --- launcher install, and the Master_Daemon deconflict --------------------
    # The directory name MUST equal the CONF_STR setname exactly ("Maldita
    # Castilla") — the `main=` hook and the Scripts entry both hardcode that path.
    #
    # The FILE name must NOT be _handler.sh. That is Master_Daemon's entire
    # discovery predicate (Master_Daemon.sh: discover_cores() tests
    # `-f "$dir/_handler.sh"`, the dispatch loop tests `-x`), and there is no
    # config file to opt out of. Under that name the daemon spawns the launcher
    # on every /tmp/CORENAME change and respawns it whenever its child exits,
    # both of which collide with the two entry points that now own the launch.
    # We do not own Master_Daemon, so we deconflict from our side: install as
    # launch.sh, and delete any _handler.sh already on the device.
    handler_src = REPO / "games" / CORENAME / "launch.sh"
    if handler_src.exists():
        print(f"\n-- Installing engine launcher for '{CORENAME}' --")
        ssh(host, f"mkdir -p '{HANDLER_DIR}' /media/fat/logs/MalditaCastilla", check=True)
        scp_verified(host, handler_src, f"{HANDLER_DIR}/launch.sh")
        ssh(host, f"chmod 755 '{HANDLER_DIR}/launch.sh'", check=True)

        # Remove ourselves from the daemon's discovery. Not best-effort: a
        # survivor means the daemon still spawns a second engine onto the same
        # fabric control block on the next core load, which shows up as C_DONE
        # running backwards rather than as anything that looks like a deploy
        # failure. A daemon mid-flight needs no further handling — its dispatch
        # and respawn arms both re-test the path, so the deletion takes effect
        # on its next poll.
        # Demand a positive GONE rather than "not PRESENT": a dropped ssh returns
        # empty stdout, which would satisfy a not-PRESENT test while having
        # verified nothing at all. Fail closed.
        r = ssh(host, f"rm -f '{HANDLER_DIR}/_handler.sh'; "
                      f"test -e '{HANDLER_DIR}/_handler.sh' && echo PRESENT || echo GONE")
        if (r.stdout or "").strip().splitlines()[-1:] != ["GONE"]:
            sys.exit(f"FATAL: could not confirm {HANDLER_DIR}/_handler.sh is gone "
                     f"(got {(r.stdout or '')!r}) — Master_Daemon would spawn a "
                     "second engine on core load.")
        print("   Master_Daemon deconflict: no _handler.sh under "
              f"'{HANDLER_DIR}' (daemon left untouched)")

        # HPS takeover harness — always shipped, INERT unless takeover.env arms
        # it. The handler sources it from its own directory, so it has to land
        # here rather than in GAMEDIR.
        takeover_src = REPO / "games" / CORENAME / "mister_takeover.sh"
        if takeover_src.exists():
            scp_verified(host, takeover_src, f"{HANDLER_DIR}/mister_takeover.sh")
            ssh(host, f"chmod 644 '{HANDLER_DIR}/mister_takeover.sh'", check=True)
        # Daemon-free entry point. Appears in MiSTer's OSD under Scripts and
        # does the core load itself, so Master_Daemon is not in the loop at
        # all. Shipped unconditionally — installing it changes nothing until
        # the user selects it.
        launcher_src = REPO / "Scripts" / "MalditaCastilla.sh"
        if launcher_src.exists():
            print("   installing the daemon-free Scripts launcher")
            ssh(host, "mkdir -p /media/fat/Scripts", check=True)
            scp_verified(host, launcher_src, "/media/fat/Scripts/MalditaCastilla.sh")
            ssh(host, "chmod 755 /media/fat/Scripts/MalditaCastilla.sh", check=True)

        if args.takeover:
            # Written here, not baked into launch.sh, so arming survives a
            # handler redeploy and disarming is one file removal — including
            # from a rescue SSH session on a box whose OSD is gone.
            print("   ! arming the HPS takeover (MiSTer will be killed once the "
                  "engine proves live)")
            env = "MALDITA_TAKEOVER=1\n"
            if args.takeover_dryrun:
                env += "MALDITA_TAKEOVER_DRYRUN=1\n"
            if args.takeover_governor:
                env += "MALDITA_TAKEOVER_GOVERNOR=1\n"
            ssh(host, f"printf '%s' '{env}' > '{HANDLER_DIR}/takeover.env'", check=True)
        elif args.no_takeover:
            print("   disarming the HPS takeover (removing takeover.env)")
            ssh(host, f"rm -f '{HANDLER_DIR}/takeover.env'")
        # Stable Cores-browser entry. The RBF name changes on every build, so
        # without this the visible entry moves around.
        #
        # Installed HERE, with the launch path, and NOT under `if not no_rbf`:
        # the MGL is a launch-path artifact, not an RBF one. Gating it on the
        # RBF meant `--main-wrapper --no-rbf` armed the wrapper and shipped no
        # entry for it to be reached from.
        #
        # Shipped verbatim, with no path rewriting: MiSTer's <rbf> tag is a
        # PREFIX, not a filename. get_rbf() (support/arcade/mra_loader.cpp:1223)
        # scans _Other for .rbf files starting with it whose next character is
        # '.' or '_', and keeps the LEXICOGRAPHICALLY GREATEST match.
        #
        # CAUTION, and it is not what the original note here claimed: greatest
        # is only "newest" while the names sort chronologically. This project
        # now builds COMMIT-HASH names (MalditaCastilla_2509573,
        # MalditaCastilla_a723aa5, ...), and hashes do not sort by date —
        # _a723aa5 (Jul 30) sorts above _2509573 (Jul 31). So the MGL resolves
        # to an ARBITRARY installed build, and any hand-named one
        # (MalditaCastilla_issue15fix) outranks every hex name forever. Keep
        # one build in _Other/ if you care which one runs, or select the .rbf
        # directly instead of the MGL.
        mgl_src = REPO / "games" / CORENAME / f"{CORENAME}.mgl"
        if mgl_src.exists():
            print(f"   installing the Cores-browser entry '_Other/{CORENAME}.mgl'")
            ssh(host, "mkdir -p /media/fat/_Other", check=True)
            scp_verified(host, mgl_src, f"/media/fat/_Other/{CORENAME}.mgl")

        # --- MiSTer.ini `main=` handoff -------------------------------------
        # The absolute path matters: MiSTer's getFullPath() passes absolute
        # paths through unchanged (file_io.cpp:154-166) and getappname() reads
        # /proc/self/exe, so once the wrapper is running cfg.main and
        # /proc/self/exe compare equal and the exec does not loop.
        MAIN_LINE = "main=/media/fat/games/gmloader/MiSTer_Maldita"
        backup = "cp /media/fat/MiSTer.ini /media/fat/MiSTer.ini.bak.$(date +%s); "
        r = ssh(host, f"grep -q '^{MAIN_LINE}' /media/fat/MiSTer.ini "
                      "&& echo PRESENT || echo ABSENT")
        active = (r.stdout or "").strip() == "PRESENT"

        if args.main_wrapper:
            # Safe to re-enable only because of the 2026-08-04 overlay rework:
            # upstream main() and the scheduler now run verbatim and the whole
            # local change is one call inserted AFTER scheduler_wait_fpga_ready().
            # The readiness contract is honoured by the code that owns it. The
            # 2026-07-25 measurement that disabled this (wrapper 3/5 frame-1
            # wedges vs stock main 0/5) was against the old overlay, which
            # replaced main() with a hand-rolled loop that never ran that guard.
            # Still unproven on hardware — plan Task 4b.2 is the gate.
            if active:
                print("   main= wrapper handoff already active")
            else:
                print("   ! arming the main= wrapper handoff — the Cores-browser entry "
                      "now starts the engine, with no daemon")
                # Prefer un-commenting an existing line to appending, so repeated
                # deploys cannot accumulate duplicate [Maldita Castilla] sections.
                ssh(host, backup +
                    f"if grep -q '^;{MAIN_LINE}' /media/fat/MiSTer.ini; then "
                    f"  sed -i 's|^;{MAIN_LINE}.*|{MAIN_LINE}|' /media/fat/MiSTer.ini; "
                    "else "
                    f"  printf '\\n[{CORENAME}]\\n{MAIN_LINE}\\n' >> /media/fat/MiSTer.ini; "
                    "fi", check=True)
        elif args.no_main_wrapper and active:
            print("   disarming the main= wrapper handoff — commenting it out")
            ssh(host, backup +
                      f"sed -i 's|^{MAIN_LINE}|"
                      f";{MAIN_LINE}  ; disabled by deploy.py|' "
                      "/media/fat/MiSTer.ini", check=True)
        # No Master_Daemon handling here, deliberately. Earlier revisions killed
        # and restarted it so it would re-enumerate a newly installed
        # _handler.sh; with the deconflict above there is nothing of ours left
        # for it to enumerate, and it may well be serving OTHER hybrid cores on
        # this device (it auto-discovers every games/*/ with an _handler.sh).
        # It is a third-party script we do not own — leave it running and leave
        # it alone.
        #
        # An engine the daemon spawned BEFORE this deploy is not killed here.
        # It keeps the pre-deploy binaries it already mapped, and the daemon
        # will not respawn it once the file is gone, so it clears on the next
        # core change. Kill gmloader over SSH if a stale one is in the way.
    else:
        print(f"\n   WARN: {handler_src} missing — engine launcher NOT installed. "
              "Neither the Scripts entry nor the main= handoff can start the engine.")

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


    print("\n-- Fixing exec bit on the engine + wrapper --")
    targets = f"{GAMEDIR}/MiSTer_Maldita" if args.no_engine \
        else f"{GAMEDIR}/gmloader {GAMEDIR}/MiSTer_Maldita"
    ssh(host, f"chmod 755 {targets}", check=True)

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

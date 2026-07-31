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

AUTO-LAUNCH (changed 2026-07-25): the engine is started by MiSTer's Master_Daemon
(Frontier), which watches /tmp/CORENAME and runs
  /media/fat/games/Maldita Castilla/_handler.sh
when the core loads. This is the pattern the sibling Solarus core uses, and it
leaves STOCK MiSTer main running so it keeps its FPGA-readiness contract
(scheduler_co_poll's `while (!is_fpga_ready(1)) fpga_wait_to_reset();`).

The previous mechanism — MiSTer.ini `main=/media/fat/games/gmloader/MiSTer_Maldita`
— REPLACED MiSTer's main() and did not fully honour that contract (it spawns the
engine at maldita_wrapper.cpp:143 before its first readiness check at :157, and
hand-rolls main()'s `#else` branch, which is dead code since USE_SCHEDULER is
unconditional). If a [Maldita Castilla] main= line is present, this deploy
COMMENTS IT OUT. Reinstating the wrapper is deferred to a future plan.

The wrapper binary is still uploaded (harmless, unused by this path) so the
future plan can re-enable it without a redeploy.

Usage:
  ./deploy.py                      RBF + engine + content (the moving pieces)
  ./deploy.py --no-rbf             engine + content only
  ./deploy.py --no-content         RBF + engine only (skip the 49MB game.droid)
  ./deploy.py --engine-only        just the gmloader binary + gmloader.json
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

# ── Auto-launch (Master_Daemon handler path, replaces the main= wrapper) ───────
# The daemon watches /tmp/CORENAME and runs games/<CORENAME>/_handler.sh, so this
# MUST match the RBF's CONF_STR setname exactly (fpga/Maldita.sv:270) — including
# the space.
CORENAME    = "Maldita Castilla"
HANDLER_DIR = f"/media/fat/games/{CORENAME}"

# ── Source paths (sibling repos). Override any with the matching CLI flag. ──────
ENGINE_DEFAULT  = SIBLINGS / "gmloader-next/build/arm-linux-gnueabihf/gmloader/gmloadernext.armhf"
WRAPPER_DEFAULT = REPO / "build/mister-wrapper-hps/MiSTer_Maldita"
JSON_DEFAULT    = SIBLINGS / "gmloader-next/games/gmloader/gmloader.json"
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
RBF_ARTIFACT   = "maldita-rbf"          # CI artifact name (build-rbf.yml)
RBF_WORKFLOW   = "build-rbf.yml"


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
    want_tree = fpga_tree(REPO)
    print(f"-- Resolving CI RBF for {REPO.name} HEAD {sha_short} (fpga/ tree {want_tree[:9]}) --")
    try:
        run_id, built_sha, want_tree = resolve_rbf.resolve_run_id(REPO)
    except resolve_rbf.RbfResolutionError as e:
        raise SystemExit(f"FATAL: {e}")
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
    """
    src = SIBLINGS / "gmloader-next"
    sha, _ = git_head(src)
    ctime = last_code_commit_time(src)   # ignore docs-only commits — see the helper
    mtime = int(Path(engine).stat().st_mtime)
    stale = ctime is not None and mtime < ctime
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
    args = ap.parse_args()
    host = args.host
    if args.engine_only:
        args.no_rbf = args.no_content = True

    # ── Resolve + verify sources present ──────────────────────────────────────
    engine = args.engine
    wrapper = args.wrapper
    gmjson = JSON_DEFAULT
    need = [engine, wrapper, gmjson]
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
    engine_info = check_engine_freshness(engine, args.force)

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
    print(f"  │ ENGINE {Path(engine).name}")
    print(f"  │        gmloader-next {engine_info['commit']}  built {engine_info['built']}  "
          f"md5 {engine_info['md5']}  [{engine_info['note']}]")
    print("  └" + "─" * 60)
    # A partial deploy is legitimate (bisecting, A/B) but it is ALSO how the halves
    # drift apart, so name the risk instead of letting it pass silently.
    if args.no_rbf or args.no_content:
        skipped = [n for n, s in (("RBF", args.no_rbf), ("content", args.no_content)) if s]
        print(f"\n  !! PARTIAL DEPLOY — not shipping: {', '.join(skipped)}")
        print("     The engine and RBF are a matched pair with no runtime handshake;")
        print("     whatever is already on the device for the skipped half stays put.")
    print()

    # ── Stop the running engine so its binary can be replaced ─────────────────
    # No pkill on device busybox; match `gmloader -c` in ps ([g] keeps grep off
    # itself). Then remove the old binary (FAT can't overwrite a still-open exe).
    print("-- Stopping running gmloader --")
    ssh(host, "for p in $(ps -o pid,args 2>/dev/null | grep '[g]mloader -c' | awk '{print $1}'); do "
              "kill -9 \"$p\" 2>/dev/null; done; sleep 1; "
              f"rm -f {GAMEDIR}/gmloader; true")

    print("\n-- Creating remote dirs --")
    ssh(host, f"mkdir -p {GAMEDIR}/saves {GAMEDIR}/lib/armeabi-v7a {GAMEDIR}/mesa "
              "/media/fat/_Other", check=True)

    print("\n-- Uploading engine binary + gmloader.json (sha1-verified) --")
    scp_verified(host, engine, f"{GAMEDIR}/gmloader")
    scp_verified(host, gmjson, f"{GAMEDIR}/gmloader.json")

    print("\n-- Uploading HPS wrapper binary (sha1-verified; UNUSED by the handler path) --")
    scp_verified(host, wrapper, f"{GAMEDIR}/MiSTer_Maldita")

    # --- auto-launch: Master_Daemon handler (replaces the MiSTer.ini main= wrapper) ---
    # The daemon routes /tmp/CORENAME -> /media/fat/games/<CORENAME>/_handler.sh, so the
    # directory name MUST equal the CONF_STR setname exactly ("Maldita Castilla").
    handler_src = REPO / "games" / CORENAME / "_handler.sh"
    if handler_src.exists():
        print(f"\n-- Installing auto-launch handler for '{CORENAME}' --")
        ssh(host, f"mkdir -p '{HANDLER_DIR}' /media/fat/logs/MalditaCastilla", check=True)
        scp_verified(host, handler_src, f"{HANDLER_DIR}/_handler.sh")
        ssh(host, f"chmod 755 '{HANDLER_DIR}/_handler.sh'", check=True)
        # Disable a stale main= wrapper handoff: stock MiSTer main must stay resident so
        # it keeps its FPGA-readiness contract. Device-measured 2026-07-25: wrapper 3/5
        # frame-1 wedges vs stock main 0/5, same RBF and engine.
        r = ssh(host, "grep -q '^main=/media/fat/games/gmloader/MiSTer_Maldita' /media/fat/MiSTer.ini "
                      "&& echo PRESENT || echo ABSENT")
        if (r.stdout or "").strip() == "PRESENT":
            print("   ! MiSTer.ini has an active main= wrapper handoff — commenting it out")
            ssh(host, "cp /media/fat/MiSTer.ini /media/fat/MiSTer.ini.bak.$(date +%s); "
                      "sed -i 's|^main=/media/fat/games/gmloader/MiSTer_Maldita|"
                      ";main=/media/fat/games/gmloader/MiSTer_Maldita  ; disabled by deploy.py|' "
                      "/media/fat/MiSTer.ini", check=True)
        # The daemon enumerates handlers at startup, so a NEW handler needs a restart.
        #
        # The kill walks /proc rather than using pkill: MiSTer's busybox has NO pkill and
        # no pgrep (`pkill` exits 127, "command not found"), so the old
        # `pkill -f Master_Daemon.sh; ... nohup Master_Daemon.sh &` killed nothing and
        # simply ADDED a second daemon on every deploy. Each daemon then spawns its own
        # handler on core load, so the core came up with TWO gmloader processes writing one
        # fabric control block — which is both the documented dual-engine corruption and an
        # automatic abort for any bench run (mister_run.sh asserts exactly one engine).
        # Observed on .62 2026-07-29: deploys at 15:08 and 15:20 each left a stray daemon.
        # `killall` is not a substitute either — these run as `bash <path>/Master_Daemon.sh`,
        # so the process NAME is bash and killall would either miss it or kill every shell.
        print("   restarting Master_Daemon so it picks up the handler")
        # The ssh shell's own cmdline contains "Master_Daemon.sh" (this very
        # command text), so the loop MUST skip $$ — otherwise it kill -9s itself
        # mid-loop and the nohup restart below never runs, leaving the device
        # with NO daemon and therefore no auto-launch on core load (observed
        # .62 2026-07-29 16:49: daemon killed, restart never executed).
        kill_daemons = (
            'for p in /proc/[0-9]*; do '
            '  [ "$(basename "$p")" = "$$" ] && continue; '
            '  [ -r "$p/cmdline" ] || continue; '
            '  case "$(tr "\\0" " " < "$p/cmdline")" in '
            '    *Master_Daemon.sh*) kill -9 "$(basename "$p")" 2>/dev/null ;; '
            '  esac; '
            'done'
        )
        count_daemons = (
            'n=0; for p in /proc/[0-9]*; do '
            '  [ -r "$p/cmdline" ] || continue; '
            '  case "$(tr "\\0" " " < "$p/cmdline")" in '
            '    *Master_Daemon.sh*) n=$((n+1)) ;; '
            '  esac; '
            'done; echo "$n"'
        )
        ssh(host, f"{kill_daemons}; sleep 1; "
                  "nohup /media/fat/MiSTer_Frontier/Master_Daemon.sh >/tmp/master_daemon.log 2>&1 & "
                  "sleep 2; true")
        # Verify, because the failure is silent and only surfaces later as a wedged core.
        # The counting shell is itself matched by its own cmdline, hence the -1.
        live = (ssh(host, count_daemons).stdout or "").strip().splitlines()
        n_live = int(live[-1]) - 1 if live and live[-1].strip().isdigit() else -1
        if n_live == 1:
            print("   Master_Daemon: exactly 1 running")
        else:
            print(f"   WARN: {n_live} Master_Daemon instance(s) running — expected 1. "
                  "More than one spawns duplicate engines on core load.")
    else:
        print(f"\n   WARN: {handler_src} missing — auto-launch handler NOT installed.")

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
    ssh(host, f"chmod 755 {GAMEDIR}/gmloader {GAMEDIR}/MiSTer_Maldita", check=True)

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

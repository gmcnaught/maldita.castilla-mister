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
    gmloader.json       apk_path = "mygame.apk"                 <- ENGINE
    mygame.apk          PortMaster malditacastilla.apk          <- CONTENT
    saves/game.droid    49MB game data                          <- CONTENT
    saves/options.ini                                            <- CONTENT
    lib/armeabi-v7a/    libstdc++.so                             <- runtime (opt-in)
    mesa/               surfaceless Mesa closure                 <- runtime (opt-in)
    libGLES_sw.so       = mesa libGLESv2.so.2                    <- runtime (opt-in)
  /media/fat/_Other/MalditaCastilla_*.rbf                        <- RBF

Usage:
  ./deploy.py                      RBF + engine + content (the moving pieces)
  ./deploy.py --no-rbf             engine + content only
  ./deploy.py --no-content         RBF + engine only (skip the 49MB game.droid)
  ./deploy.py --engine-only        just the gmloader binary + gmloader.json
  ./deploy.py --with-runtime DIR   also push mesa/ + libGLES_sw.so + lib/ from DIR
  ./deploy.py --host 1.2.3.4       override device IP
"""

import argparse
import glob
import hashlib
import subprocess
import sys
from pathlib import Path

HOST = "192.168.20.81"
USER = "root"
REPO = Path(__file__).resolve().parent            # maldita.castilla-mister
SIBLINGS = REPO.parent                            # ~/MisterFPGA-Projects
GAMEDIR = "/media/fat/games/gmloader"

# ── Source paths (sibling repos). Override any with the matching CLI flag. ──────
ENGINE_DEFAULT  = SIBLINGS / "gmloader-next/build/arm-linux-gnueabihf/gmloader/gmloadernext.armhf"
JSON_DEFAULT    = SIBLINGS / "gmloader-next/games/gmloader/gmloader.json"
PORTMASTER      = SIBLINGS / "PortMaster-New/ports/maldita.castilla/maldita.castilla"
APK_DEFAULT     = PORTMASTER / "malditacastilla.apk"
DROID_DEFAULT   = PORTMASTER / "gamedata/game.droid"
OPTIONS_DEFAULT = PORTMASTER / "gamedata/options.ini"
RBF_GLOB        = str(REPO / "_Other" / "MalditaCastilla_*.rbf")


def sh(args, **kw):
    print("  $", " ".join(str(a) for a in args))
    return subprocess.run(args, **kw)


def ssh(host, cmd, check=False):
    return sh(["ssh", f"{USER}@{host}", cmd], check=check, text=True, capture_output=True)


def scp(host, src, dst):
    return sh(["scp", "-q", str(src), f"{USER}@{host}:{dst}"], check=True)


def scp_verified(host, src, dst, retries=3):
    """scp + sha1 verify, retrying on mismatch (FAT truncation guard)."""
    want = hashlib.sha1(Path(src).read_bytes()).hexdigest()
    for attempt in range(1, retries + 1):
        ssh(host, f"rm -f {dst}")
        scp(host, src, dst)
        got = ssh(host, f"sha1sum {dst} 2>/dev/null").stdout.split()[:1]
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
    ap.add_argument("--no-rbf", action="store_true", help="skip the FPGA core RBF")
    ap.add_argument("--no-content", action="store_true",
                    help="skip the APK + 49MB game.droid + options.ini")
    ap.add_argument("--engine-only", action="store_true",
                    help="just the gmloader binary + gmloader.json (implies --no-rbf --no-content)")
    ap.add_argument("--with-runtime", type=Path, metavar="DIR",
                    help="also push the GL runtime (mesa/, libGLES_sw.so, lib/) from DIR")
    args = ap.parse_args()
    host = args.host
    if args.engine_only:
        args.no_rbf = args.no_content = True

    # ── Resolve + verify sources present ──────────────────────────────────────
    engine = args.engine
    gmjson = JSON_DEFAULT
    need = [engine, gmjson]
    if not args.no_content:
        need += [APK_DEFAULT, DROID_DEFAULT, OPTIONS_DEFAULT]
    missing = [p for p in need if not p.exists()]
    if missing:
        for p in missing:
            print(f"MISSING: {p}", file=sys.stderr)
        print("\n(build the engine in gmloader-next, or pass --engine / --no-content)",
              file=sys.stderr)
        sys.exit(1)

    rbf = None
    if not args.no_rbf:
        rbfs = sorted(glob.glob(RBF_GLOB))
        if rbfs:
            rbf = Path(rbfs[-1])
        else:
            print("note: no local _Other/MalditaCastilla_*.rbf — skipping RBF.\n"
                  "      fetch the latest with: gh run download -n maldita-rbf -D _Other")

    runtime = None
    if args.with_runtime:
        runtime = args.with_runtime
        if not runtime.is_dir():
            print(f"MISSING: --with-runtime dir {runtime}", file=sys.stderr)
            sys.exit(1)

    print(f"Deploying Maldita Castilla to {USER}@{host}\n")

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

    print("\n-- Fixing exec bit on the engine --")
    ssh(host, f"chmod 755 {GAMEDIR}/gmloader", check=True)

    print("\n-- Deployed tree --")
    r = ssh(host, f"ls -la {GAMEDIR}/ {GAMEDIR}/saves/ 2>/dev/null | head -40; "
                  "ls -la /media/fat/_Other/MalditaCastilla_*.rbf 2>/dev/null")
    print(r.stdout)

    print("Done. Load the Maldita Castilla core from the MiSTer menu, then run the engine:\n"
          f"  ssh {USER}@{host} 'cd {GAMEDIR} && GMLOADER_RASTER=mfgpu \\\n"
          f"    LD_LIBRARY_PATH={GAMEDIR}/mesa:{GAMEDIR} ./gmloader -c gmloader.json'")


if __name__ == "__main__":
    main()

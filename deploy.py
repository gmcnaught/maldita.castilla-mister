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
"""

import argparse
import glob
import hashlib
import shlex
import subprocess
import sys
from pathlib import Path

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
        print("   restarting Master_Daemon so it picks up the handler")
        ssh(host, "pkill -f Master_Daemon.sh; sleep 1; "
                  "nohup /media/fat/MiSTer_Frontier/Master_Daemon.sh >/tmp/master_daemon.log 2>&1 & "
                  "sleep 1; true")
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

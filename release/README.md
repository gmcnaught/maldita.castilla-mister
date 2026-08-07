# Maldita Castilla for MiSTer

FPGA-accelerated port of Locomalito's Maldita Castilla to the MiSTer
(DE10-Nano): a GameMaker loader (gmloader) on the ARM HPS drives a custom
FPGA blitter core.

**The game is included.** Extract, launch, play.

## Install

1. Extract this zip over the root of your MiSTer SD card (`/media/fat/`).
   It adds:
   - `_Other/MalditaCastilla_YYYYMMDD.rbf` — the FPGA core
   - `Scripts/MalditaCastilla.sh` — **the launcher: this is how you start it**
   - `Scripts/MalditaCastilla_CoresMenu.sh` — optional one-off setup, so the
     Cores browser can start the game too (see below)
   - `games/Maldita Castilla/launch.sh` — engine launcher (run by the above)
   - `games/Maldita Castilla/mem_wc_load.sh` + `mem_wc-*.ko` — an optional
     kernel module that makes the engine's uploads to the FPGA ~10× faster
     (see below)
   - `games/gmloader/` — the game engine, GL runtime, and the game data
   - `games/gmloader/MiSTer_Maldita` — an alternative MiSTer binary, used only
     if you run the setup entry above; inert otherwise
2. Start it from the MiSTer OSD: **Scripts → MalditaCastilla**. That loads the
   core and starts the engine in one step.

There is no separate download step and no game data to supply yourself.

## Game data, licence and credits

*Maldita Castilla* © 2012 **Locomalito** — music by **Gryzor87**, cover art by
**Marek Barej** — is licensed under [Creative Commons
Attribution-NonCommercial-NoDerivatives 4.0 International (CC BY-NC-ND
4.0)](https://creativecommons.org/licenses/by-nc-nd/4.0/).

The game files in this bundle are redistributed **unmodified**, byte-for-byte
from the public PortMaster port
([`PortsMaster/PortMaster-New`](https://github.com/PortsMaster/PortMaster-New/tree/main/ports/maldita.castilla/maldita.castilla)):

| in this bundle | what it is |
|---|---|
| `games/gmloader/mygame.apk` | the port's `malditacastilla.apk`, renamed — `gmloader.json`'s `apk_path` expects exactly this name |
| `games/gmloader/saves/game.droid` | the 49 MB GameMaker data file (the game) |
| `games/gmloader/saves/options.ini` | the port's display-name config |
| `games/gmloader/LICENSE.malditacastilla.txt` | the CC BY-NC-ND 4.0 licence text, as shipped with the game |
| `games/gmloader/maldita-castilla-readme.txt` | Locomalito's own readme and credits |

The FPGA blitter changes how those files are *rendered* at run time; it does
not alter them, and no modified version of the game is distributed here.

This release is free. **NonCommercial**: if you mirror or repackage it, that
must stay non-commercial too. If you enjoy the game, support Locomalito at
<https://locomalito.com>.

`mygame.apk` additionally contains YoYo Games' GameMaker Android runner
(`lib/armeabi-v7a/libyoyo.so`) and `libopenal.so`, which the CC licence does
not cover — gmloader needs the runner to run the game, and it is included on
the same footing as the public PortMaster port it comes from.

The core, the engine and the blitter fabric are separate works under their own
licences; see the project repository.

## Updating an existing install

Extracting over an existing install overwrites `games/gmloader/saves/game.droid`
and `options.ini` with identical bytes. Your save files have different names and
are not touched.

## How to launch it

Use the **Scripts → MalditaCastilla** entry. It works as extracted and changes
nothing on your system.

Out of the box, selecting the core directly from the `_Other` Cores menu loads
the bitstream but starts no engine — you get a black screen. That is expected:
nothing watches for the core to load. The next section turns that on if you
want it.

No daemon or resident helper is needed, and none should be installed. Earlier
releases relied on Frontier's **Master_Daemon** watching the loaded core's name
and running `games/Maldita Castilla/_handler.sh`. That file is deliberately no
longer shipped: when a daemon and the Scripts entry both fire on the same core
load, two engine processes end up writing one FPGA control block and the
picture corrupts. **If you are upgrading from an older release, delete any
leftover `games/Maldita Castilla/_handler.sh`.**

Nothing tears the engine down when you switch cores — exit the game from its
own menu.

### Optional: starting the game from the Cores browser

Run **Scripts → MalditaCastilla_CoresMenu** once. After that, selecting
`MalditaCastilla_*.rbf` from **Cores → `_Other`** loads the core *and* starts
the game. Run the same entry again to undo it. It takes effect on the next core
load; no reboot.

It prints what it did. Nothing else about the install changes, and
**Scripts → MalditaCastilla** keeps working either way.

#### What it changes, and why it is a separate step

MiSTer's Cores browser lists only `.rbf`/`.mra`/`.mgl`, so a launcher script
cannot appear in it. The one per-core hook that can execute anything is
`MiSTer.ini`'s `main=`, and that file is yours — it holds your video mode, your
input config and every other core's settings. Nothing here edits it without you
asking, which is why this is an entry you select rather than something the
extract does.

The entry adds one section to `MiSTer.ini`, after backing the file up to
`MiSTer.ini.bak.<timestamp>`:

    [Maldita Castilla]
    main=/media/fat/games/gmloader/MiSTer_Maldita

**`main=` does not mean "also run this".** It names a **replacement for the
`MiSTer` binary itself** — whatever you put there runs *instead of* MiSTer for
this core, inheriting the job of loading cores, driving the OSD and serving
input. Pointing it at a shell script gives you a machine with no MiSTer running
at all; do not hand-write this line at anything but the binary above.

`MiSTer_Maldita` is that binary: a normal Main_MiSTer build — upstream `main()`
and scheduler verbatim — plus one call that forks `launch.sh` **after** the FPGA
readiness handshake. That ordering is the whole point: an earlier build that
started the engine before the readiness check wedged 3 launches in 5 on
hardware, and the current one measured 0 in 5. MiSTer only runs a `main=`
target that exists, so deleting `games/gmloader/MiSTer_Maldita` is also a way
to switch this off, and the line left behind does nothing.

Two notes if you armed it:

- Each release ships its core under a build-stamped name. When you update, an
  older `_Other/MalditaCastilla_*.rbf` is still listed and still launchable —
  delete the old ones so you cannot pick a stale core with a current engine.
- The OSD you get after the handoff is that build of MiSTer, not the one your
  SD card boots. If your MiSTer install is much newer or older, prefer
  **Scripts → MalditaCastilla**.

## The `mem_wc` module (optional, and safe to ignore)

`games/Maldita Castilla/` contains a small kernel module and a loader script
that `launch.sh` sources before starting the engine. All it does is let the
engine map the FPGA's command rings and texture heap **write-combining**
instead of strongly-ordered — measured on a DE10-Nano, `memcpy` into that
window goes from 80 MB/s to 814 MB/s.

Nothing about it is required. The module is built out-of-tree against one
MiSTer kernel, so it ships under that kernel's name (`mem_wc-5.15.1-MiSTer.ko`)
and the loader only uses it if it matches your `uname -r`. On any other kernel
nothing is loaded and the engine uses the ordinary mapping — you lose frame
rate, not the game. The loader also leaves a `mem_wc` module alone if another
core already loaded one. Which of those happened is the `mem_wc:` line in
`/media/fat/logs/MalditaCastilla/maldita.log`.

To opt out entirely, delete the two files, or set `GMLOADER_NO_WC=1`.

## Troubleshooting

Manual launch over SSH (for debugging only — never run two engine
instances at once):

    cd /media/fat/games/gmloader
    export LD_LIBRARY_PATH=/media/fat/games/gmloader/mesa:/media/fat/games/gmloader
    ./gmloader -c gmloader.json

Verify file integrity against `sha256sums.txt` from the GitHub Release —
FAT can truncate files on interrupted copies, and a truncated `game.droid` is
a black screen with no other symptom.

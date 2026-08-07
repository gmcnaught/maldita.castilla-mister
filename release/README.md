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
   - `games/Maldita Castilla/launch.sh` — engine launcher (run by the above)
   - `games/Maldita Castilla/mem_wc_load.sh` + `mem_wc-*.ko` — an optional
     kernel module that makes the engine's uploads to the FPGA ~10× faster
     (see below)
   - `games/gmloader/` — the game engine, GL runtime, and the game data
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

Use the **Scripts → MalditaCastilla** entry. Selecting the core directly from
the `_Other` Cores menu loads the bitstream but starts no engine — you get a
black screen. That is expected: nothing on the device watches for the core to
load.

No daemon or resident helper is needed, and none should be installed. Earlier
releases relied on Frontier's **Master_Daemon** watching the loaded core's name
and running `games/Maldita Castilla/_handler.sh`. That file is deliberately no
longer shipped: when a daemon and the Scripts entry both fire on the same core
load, two engine processes end up writing one FPGA control block and the
picture corrupts. **If you are upgrading from an older release, delete any
leftover `games/Maldita Castilla/_handler.sh`.**

Nothing tears the engine down when you switch cores — exit the game from its
own menu.

### Why the Cores entry cannot start the game, and what it would take

Selecting the core from **Cores → `_Other`** loads the bitstream and stops
there. MiSTer's Cores browser lists only `.rbf`/`.mra`/`.mgl`, so a launcher
script cannot appear in it, and the only per-core hook that can execute
anything is `MiSTer.ini`'s `main=`.

**`main=` does not mean "also run this".** It names a **replacement for the
`MiSTer` binary itself** — whatever you put there is what runs *instead of*
MiSTer, and it inherits the job of loading cores, driving the OSD and serving
input. Pointing it at `games/Maldita Castilla/launch.sh` therefore does not
give you a launcher; it gives you a machine with no MiSTer running at all. Do
not do it.

Making this work needs a `MiSTer_Maldita` binary: a normal Main_MiSTer build
with one hook that forks `launch.sh` after the FPGA readiness handshake. That
ordering is the whole point — an earlier version that started the engine before
the readiness check wedged 3 launches in 5 on hardware. The binary is not built
for releases, so there is nothing to point `main=` at from a bundle install.

If you want it, build it from the project repository (`tools/mister-wrapper/`)
and deploy with `deploy.py`, which installs the binary and writes the
`MiSTer.ini` section for you. Otherwise use **Scripts → MalditaCastilla**,
which needs none of this.

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

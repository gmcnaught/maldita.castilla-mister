# Maldita Castilla for MiSTer

FPGA-accelerated port of Locomalito's Maldita Castilla to the MiSTer
(DE10-Nano): a GameMaker loader (gmloader) on the ARM HPS drives a custom
FPGA blitter core.

## Install

1. Extract this zip over the root of your MiSTer SD card (`/media/fat/`).
   It adds:
   - `_Other/MalditaCastilla_YYYYMMDD.rbf` — the FPGA core
   - `Scripts/MalditaCastilla.sh` — **the launcher: this is how you start it**
   - `games/Maldita Castilla/launch.sh` — engine launcher (run by the above)
   - `games/gmloader/` — the game engine + GL runtime
2. Add the game data (NOT included — see below).
3. Start it from the MiSTer OSD: **Scripts → MalditaCastilla**. That loads the
   core and starts the engine in one step.

## Game data (required, not included)

Maldita Castilla is freeware (Locomalito / Gryzor87) and the PortMaster port
of it is public, so the data is free to obtain — it is just not shipped in
this bundle. Source:

  https://github.com/PortsMaster/PortMaster-New/tree/main/ports/maldita.castilla/maldita.castilla

Place:

- `malditacastilla.apk` at `games/gmloader/mygame.apk`
  (rename it — `gmloader.json`'s `apk_path` expects that exact name)
- `gamedata/game.droid` at `games/gmloader/saves/game.droid`
- `gamedata/options.ini` at `games/gmloader/saves/options.ini`
  (also created on first run if your APK contains it)

`games/gmloader/APKs/README.txt` repeats these steps.

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

## Troubleshooting

Manual launch over SSH (for debugging only — never run two engine
instances at once):

    cd /media/fat/games/gmloader
    export LD_LIBRARY_PATH=/media/fat/games/gmloader/mesa:/media/fat/games/gmloader
    ./gmloader -c gmloader.json

Verify file integrity against `sha256sums.txt` from the GitHub Release —
FAT can truncate files on interrupted copies.

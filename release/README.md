# Maldita Castilla for MiSTer

FPGA-accelerated port of Locomalito's Maldita Castilla to the MiSTer
(DE10-Nano): a GameMaker loader (gmloader) on the ARM HPS drives a custom
FPGA blitter core.

## Install

1. Extract this zip over the root of your MiSTer SD card (`/media/fat/`).
   It adds:
   - `_Other/MalditaCastilla_YYYYMMDD.rbf` — the FPGA core
   - `games/Maldita Castilla/_handler.sh` — auto-launch dispatcher
   - `games/gmloader/` — the game engine + GL runtime
2. Add the game data (NOT included — see below).
3. Load **MalditaCastilla** from the MiSTer OSD (`_Other` menu).

## Game data (required, not included)

Get the free PortMaster release of Maldita Castilla and place:

- the APK at `games/gmloader/mygame.apk`
  (rename `malditacastilla.apk` to `mygame.apk`)
- game data at `games/gmloader/saves/game.droid` and
  `games/gmloader/saves/options.ini` (created on first run if your APK
  contains them)

`games/gmloader/APKs/README.txt` repeats these steps.

## Auto-launch dependency

Auto-launch on core load requires Frontier's **Master_Daemon** on the
device (it watches the loaded core's name and runs
`games/Maldita Castilla/_handler.sh`). Without it, the core loads but the
game will not start automatically.

## Troubleshooting

Manual launch over SSH (for debugging only — never run two engine
instances at once):

    cd /media/fat/games/gmloader
    export LD_LIBRARY_PATH=/media/fat/games/gmloader/mesa:/media/fat/games/gmloader
    ./gmloader -c gmloader.json

Verify file integrity against `sha256sums.txt` from the GitHub Release —
FAT can truncate files on interrupted copies.

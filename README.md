# Maldita Castilla for MiSTer FPGA

A MiSTer FPGA port of *Maldita Castilla*, running the original GameMaker game
through a GameMaker loader with an FPGA-accelerated blitter doing the
rasterisation.

## What is in this repository

| path | what it is |
|---|---|
| `fpga/` | the MiSTer core — Quartus project, RTL, and the blitter fabric |
| `games/Maldita Castilla/` | the core's `launch.sh` engine launcher |
| `Scripts/MalditaCastilla.sh` | the Scripts-menu entry that starts the game |
| `external/gmloader-next` | submodule: the gmloader engine and its MiSTer port |
| `deploy.py` | deploy to a device, with provenance gates |
| `scripts/` | bench, diagnostic and release tooling |
| `docs/architecture/` | how the pieces fit together |

The engine — including all MiSTer-specific code (blitter host path, joystick
readers, native audio and video writers) — lives in
[gmloader-next](https://github.com/gmcnaught/gmloader-next), pinned here as a
submodule.

## Installing from a release

Releases are on the [Releases
page](https://github.com/gmcnaught/maldita.castilla-mister/releases). Each
tagged `v*` release publishes:

- `MalditaCastilla-MiSTer-<tag>.zip` — the SD-card bundle (core `.rbf`, engine,
  GL runtime closure, launcher, **and the game itself**)
- `MalditaCastilla_YYYYMMDD.rbf` — the core on its own, for updating in place
- `sha256sums.txt` — checksums for both

**Steps**

1. Download the `.zip` and extract it over the root of your MiSTer SD card
   (`/media/fat/`). It adds:
   - `_Other/MalditaCastilla_YYYYMMDD.rbf` — the FPGA core
   - `Scripts/MalditaCastilla.sh` — the Scripts-menu launcher
   - `games/Maldita Castilla/launch.sh` — the engine launcher it runs
   - `games/Maldita Castilla/mem_wc_load.sh` + `mem_wc-<kernel>.ko` — the
     optional write-combining DDR mapping; used only when the object matches
     the device's `uname -r`, and worth ~10× on uploads to the fabric
   - `games/gmloader/` — the engine, its GL runtime, and the game data
     (`mygame.apk`, `saves/game.droid`, `saves/options.ini`)
2. Verify the copy against `sha256sums.txt` — FAT filesystems can silently
   truncate files on an interrupted copy, and a truncated `game.droid` shows up
   as a black screen with no other symptom.
3. Start it from the MiSTer OSD: **Scripts → MalditaCastilla**.

There is no separate game-data download. Re-extracting over an existing install
rewrites `saves/game.droid` and `saves/options.ini` with identical bytes and
leaves your save files alone.

Launch from the **Scripts** menu, not the Cores menu: selecting the core alone
loads the bitstream and starts no engine. No daemon is involved, and a leftover
`games/Maldita Castilla/_handler.sh` from an older release must be deleted —
Frontier's **Master_Daemon** discovers cores by exactly that filename, and a
daemon firing alongside the Scripts entry on the same core load puts two engines
on one FPGA control block. The bundle's own `README.md` repeats these steps and
covers manual launch for troubleshooting.

The Cores-menu entry cannot be made to start the engine by editing `MiSTer.ini`
alone: `main=` names a **replacement for the `MiSTer` binary**, not an extra
program to run, so it needs the `MiSTer_Maldita` build (`tools/mister-wrapper/`)
that `deploy.py` installs and releases do not carry. Pointing `main=` at
`launch.sh` leaves the device with no MiSTer at all.

To update an existing install, copy just the release's `.rbf` into `_Other/`
(replacing the old one) if the engine has not changed; otherwise re-extract the
full zip.

The released bitstream is **not** rebuilt at tag time. It is the artifact from
the gated `build-rbf.yml` run whose `fpga/` tree matches the tag — the same
bitstream that was validated on hardware. Every release records that provenance
(source commits, `fpga/` tree hash, CI run id) in its notes.

## Building

```
git clone --recurse-submodules git@github.com:gmcnaught/maldita.castilla-mister.git
cd maldita.castilla-mister
make build-engine      # cross-build the engine (Docker)
make help              # all targets
```

The core `.rbf` is built by CI (`.github/workflows/build-rbf.yml`, Quartus Lite
17.0). There is deliberately no local RBF target — push a change under `fpga/`
and fetch the result with `make deploy-rbf`, which refuses any artifact that
does not match HEAD's `fpga/` tree.

## Deploying a development build

For running your own build on a device (not needed to play a release):

```
make deploy HOST=<your-mister-ip>        # RBF + engine + content
make deploy-rbf HOST=<your-mister-ip>    # CI RBF for HEAD only
make deploy-engine HOST=<your-mister-ip> # engine binary + gmloader.json
```

This needs passwordless SSH to `root@<host>`. Always deploy through
`deploy.py` (what the `make` targets call): it verifies artifact provenance,
checksums the transfer, and restarts the engine correctly. Hand-launching
`gmloader` afterwards leaves two engines contending for one control block.

## Licensing and credits

This repository — the FPGA core, the blitter fabric, and the tooling — is
GPL-3.0 (`LICENSE`). The game it runs is not, and is not covered by that
licence.

*Maldita Castilla* © 2012 **Locomalito** — music by **Gryzor87**, cover art by
**Marek Barej** — is licensed under [Creative Commons
Attribution-NonCommercial-NoDerivatives 4.0 International (CC BY-NC-ND
4.0)](https://creativecommons.org/licenses/by-nc-nd/4.0/). Under that licence
the release bundle ships the game **unmodified**, with attribution and the
licence text alongside it. The blitter changes how the game is rendered at run
time; it does not alter the distributed files.

The game data lives in `release/gamedata/`, checked in so that a release and a
`deploy.py` run need nothing but this checkout. It came from the public
PortMaster port
([`PortsMaster/PortMaster-New`](https://github.com/PortsMaster/PortMaster-New/tree/main/ports/maldita.castilla/maldita.castilla));
`release/gamedata/SOURCE.txt` records the exact upstream commit, the file
mapping and the sha256s. Releases are free, and the NonCommercial term applies
to anyone mirroring or repackaging them.

`mygame.apk` also contains YoYo Games' GameMaker Android runner (`libyoyo.so`)
and `libopenal.so`, which the CC licence does not cover; gmloader requires the
runner, and it is redistributed on the same footing as the public PortMaster
port it is taken from.

If you enjoy the game, support Locomalito at <https://locomalito.com>.

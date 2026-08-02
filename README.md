# Maldita Castilla for MiSTer FPGA

A MiSTer FPGA port of *Maldita Castilla*, running the original GameMaker game
through a GameMaker loader with an FPGA-accelerated blitter doing the
rasterisation.

## What is in this repository

| path | what it is |
|---|---|
| `fpga/` | the MiSTer core — Quartus project, RTL, and the blitter fabric |
| `games/Maldita Castilla/` | the core's `_handler.sh` launcher |
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
  GL runtime closure, launcher)
- `MalditaCastilla_YYYYMMDD.rbf` — the core on its own, for updating in place
- `sha256sums.txt` — checksums for both

**Steps**

1. Download the `.zip` and extract it over the root of your MiSTer SD card
   (`/media/fat/`). It adds:
   - `_Other/MalditaCastilla_YYYYMMDD.rbf` — the FPGA core
   - `games/Maldita Castilla/_handler.sh` — the auto-launch dispatcher
   - `games/gmloader/` — the engine and its GL runtime
2. Add the game data — it is **not** included here, but Maldita Castilla is
   freeware (Locomalito / Gryzor87) and the PortMaster port is public. Source:
   [`PortsMaster/PortMaster-New` →
   `ports/maldita.castilla/maldita.castilla/`](https://github.com/PortsMaster/PortMaster-New/tree/main/ports/maldita.castilla/maldita.castilla).
   Take from it:
   - `malditacastilla.apk` → `games/gmloader/mygame.apk` (rename it;
     `gmloader.json`'s `apk_path` expects that exact name)
   - `gamedata/game.droid` and `gamedata/options.ini` →
     `games/gmloader/saves/` (which also holds your save data)
3. Verify the copy against `sha256sums.txt` — FAT filesystems can silently
   truncate files on an interrupted copy.
4. Load **MalditaCastilla** from the MiSTer OSD (`_Other` menu).

Auto-launch on core load requires Frontier's **Master_Daemon** on the device:
it watches the loaded core's name and runs `games/Maldita Castilla/_handler.sh`.
Without it the core loads but the game does not start. The bundle's own
`README.md` repeats these steps and covers manual launch for troubleshooting.

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

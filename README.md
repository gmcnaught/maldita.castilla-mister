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

## Releases

Tagged `v*` releases publish an SD-card bundle containing the core `.rbf`, the
engine, and its GL runtime closure. Game data (`mygame.apk`) is user-provided;
see the bundle's own `README.md` for placement.

The released bitstream is **not** rebuilt at tag time. It is the artifact from
the gated `build-rbf.yml` run whose `fpga/` tree matches the tag — the same
bitstream that was validated on hardware.

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

## Deploying

`make deploy` targets `192.168.20.62` by default. `192.168.20.81` is the
production unit and requires an explicit `PROD=1`.

Always deploy through `deploy.py`. It verifies artifact provenance, checksums
the transfer, and restarts the engine correctly. Hand-launching `gmloader`
afterwards leaves two engines contending for one control block.

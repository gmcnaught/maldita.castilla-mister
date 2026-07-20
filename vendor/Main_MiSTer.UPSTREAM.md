# Main_MiSTer Vendor Metadata (Maldita Castilla wrapper)

- Source repository: `https://github.com/MiSTer-devel/Main_MiSTer.git`
- Pinned commit: `3380931329b8acb442bd3d35a24d89f88641b7cf`
- Import intent: `MiSTer_Maldita` HPS wrapper foundation (engine lifecycle supervisor)
- Local vendor path: `vendor/Main_MiSTer`

This snapshot is an OVERLAY, not a full vendored copy. The full pinned upstream tree is
fetched on demand by `tools/mister-wrapper/build-hps.sh`; the `vendor/Main_MiSTer` overlay
files are applied on top before compilation.

Overlay files (authoritative list): `tools/mister-wrapper/main-mister-overlay.files`.
- `maldita_main.cpp` replaces upstream `main.cpp` (filtered out in the Makefile).
- `maldita_wrapper.{cpp,h}` — the supervisor loop.
- `maldita_child.{cpp,h}` — process lifecycle + crash policy.
- `maldita_joy_shm.{cpp,h}` — joystick SHM publisher (stub here; filled by feat #2).
- `maldita_osd.{cpp,h}` — OSD trigger poll (stub here; filled by feat #4).
- `mister_joy_shm.h` — the host↔engine contract (feat #0).

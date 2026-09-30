# Remove what pre-platform releases installed (rendered into Scripts/MalditaCastilla.sh).
# The launcher used to live in games/Maldita Castilla; it is now games/gmloader/launch.sh
# + platform/. Only files our releases and deploy.py put there are deleted, by name
# (release bundles: launch.sh, mem_wc_load.sh, mem_wc-<kernel>.ko; deploy.py also
# mem_wc.ko, mister_takeover.sh, takeover.env, and once _handler.sh). The directory
# goes only if that leaves it empty (rmdir). Saves and game data were never there
# (games/gmloader/saves). _handler.sh is Master_Daemon's discovery name and would
# start a second engine on the fabric.
OLD="/media/fat/games/Maldita Castilla"
if [ -d "$OLD" ]; then
	for f in launch.sh _handler.sh mem_wc_load.sh mem_wc.ko mem_wc-5.15.1-MiSTer.ko mem_wc-6.18.38-MiSTer.ko \
		mister_takeover.sh takeover.env "Maldita Castilla.mgl"; do
		[ -f "$OLD/$f" ] && rm -f "$OLD/$f" && echo "launcher: removed $OLD/$f"
	done
	rmdir "$OLD" 2>/dev/null && echo "launcher: removed the empty dir $OLD"
	[ -d "$OLD" ] && echo "launcher: kept $OLD (it holds files this release did not install)"
fi
[ -f "$GAMEDIR/_handler.sh" ] && rm -f "$GAMEDIR/_handler.sh" && echo "launcher: removed $GAMEDIR/_handler.sh"
# The Downloader cannot edit MiSTer.ini, so a database install has no main= line
# until this entry runs (as for Solarus). Turn main= on for [Maldita Castilla]
# unless the section already has a main= line: active (the stand-in migration
# above handles older targets), or commented out by MalditaCastilla_CoresMenu.
sec_has_main() {
	awk -v sec="[$MH_INI_SECTION]" '{ sub(/\r$/, "") } /^\[/ { ins = ($0 == sec); next } ins && /^;?main=/ { f = 1 } END { exit !f }' \
		"$MH_INI_FILE" 2>/dev/null
}
if [ -x "$HOOK" ] && [ -f "$REGISTRY" ] && ! sec_has_main; then
	mh_ini_set_main "$HOOK" && echo "launcher: MiSTer.ini [$CORENAME] main=$HOOK (loading the core starts the game; Scripts -> MalditaCastilla_CoresMenu turns it off)"
fi

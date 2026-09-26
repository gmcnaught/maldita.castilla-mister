# Remove what pre-platform releases installed (rendered into Scripts/MalditaCastilla.sh).
# The launcher used to live in games/Maldita Castilla (with mem_wc and the HPS takeover
# harness); it is now games/gmloader/launch.sh + platform/. _Other/Maldita Castilla.mgl is
# kept (same name). _handler.sh is Master_Daemon's discovery name and would start a
# second engine on the fabric.
OLD="/media/fat/games/Maldita Castilla"
if [ -d "$OLD" ]; then
	rm -f "$OLD/launch.sh" "$OLD/_handler.sh" "$OLD/mem_wc_load.sh" "$OLD"/mem_wc-*.ko "$OLD/mem_wc.ko" \
		"$OLD/mister_takeover.sh" "$OLD/takeover.env"
	rm -rf "$OLD/platform"
	rmdir "$OLD" 2>/dev/null && echo "launcher: removed the old launcher dir $OLD"
fi
rm -f "$GAMEDIR/_handler.sh"

# Remove what pre-platform releases installed (rendered into Scripts/MalditaCastilla.sh).
# mem_wc moved to platform/mem_wc/; the HPS takeover harness is gone; _handler.sh is
# Master_Daemon's discovery name and would start a second engine on the fabric.
rm -f "$GAMEDIR/mem_wc_load.sh" "$GAMEDIR"/mem_wc-*.ko "$GAMEDIR/mem_wc.ko" \
	"$GAMEDIR/mister_takeover.sh" "$GAMEDIR/takeover.env" "$GAMEDIR/_handler.sh"

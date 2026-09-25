#!/bin/bash
# swap.sh orig|test — select the engine + launcher under test on the device.
#   orig  the pre-fps-dip pair, backed up once in games/gmloader/fpsdip-orig/
#   test  the pair staged in games/gmloader/fpsdip-test/
set -eu
HOST="${MISTER_HOST:-root@192.168.20.81}"
ssh "$HOST" "set -e; G=/media/fat/games/gmloader; L='/media/fat/games/Maldita Castilla/launch.sh'
  cp -p \$G/fpsdip-$1/gmloader \$G/gmloader; cp -p \$G/fpsdip-$1/launch.sh \"\$L\"
  md5sum \$G/gmloader \"\$L\""

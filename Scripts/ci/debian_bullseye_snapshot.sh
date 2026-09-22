#!/bin/sh
# Point a Debian bullseye container's apt at a fixed snapshot.debian.org date.
#
# bullseye has left the live mirrors: deb.debian.org/debian-security 404s on the
# very packages its own index still lists (libexpat1 2.2.10-2+deb11u7, perl
# 5.32.1-4+deb11u5, ...), which broke the ARM engine build. A snapshot is
# immutable, so the package set is also reproducible from run to run.
#
# Plain http: bullseye-slim ships without ca-certificates, and apt verifies the
# archive signatures regardless of transport. The snapshot's Release files are
# past their Valid-Until, so that check is turned off -- for this snapshot only,
# since it is the only source left configured.
#
# Run as root inside the container, before any apt-get:
#   sh scripts/ci/debian_bullseye_snapshot.sh [YYYYMMDDTHHMMSSZ]
set -eu
SNAP=${1:-20260801T000000Z}
cat > /etc/apt/sources.list <<SRC
deb http://snapshot.debian.org/archive/debian/$SNAP bullseye main
deb http://snapshot.debian.org/archive/debian/$SNAP bullseye-updates main
deb http://snapshot.debian.org/archive/debian-security/$SNAP bullseye-security main
SRC
rm -f /etc/apt/sources.list.d/debian.sources
cat > /etc/apt/apt.conf.d/99snapshot <<CONF
Acquire::Check-Valid-Until "false";
Acquire::Retries "5";
CONF
echo "apt: bullseye pinned to snapshot.debian.org $SNAP"

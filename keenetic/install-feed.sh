#!/bin/sh
# Add the le0nus HydraRoute feed to Entware opkg, install hrneo from it and hold it.
set -eu
BASE="https://le0nus.github.io/hydraroute-release/keenetic"
CONF=/opt/etc/opkg/customfeeds.conf
ARCH=$(opkg print-architecture | awk '/^arch/ && $2 !~ /_kn$/ && $2 ~ /-[0-9]+\.[0-9]+$/ {print $2; exit}')
case "$ARCH" in
    aarch64-3.10) DIR=aarch64-k3.10 ;;
    *) echo "Unsupported architecture: $ARCH (only aarch64-3.10 is built so far)" >&2; exit 1 ;;
esac
LINE="src/gz le0nus-hr $BASE/$DIR"
mkdir -p /opt/etc/opkg
grep -qxF "$LINE" "$CONF" 2>/dev/null || echo "$LINE" >> "$CONF"
opkg update
opkg install hrneo
opkg flag hold hrneo
opkg list-installed | grep '^hrneo '

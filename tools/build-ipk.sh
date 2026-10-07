#!/bin/sh
# Package hrneo the way upstream does: tar.gz of debian-binary, control.tar.gz, data.tar.gz.
# Usage (inside hrneo-build): build-ipk.sh <Neo/source dir> <binary> <version> <opkg arch> <out dir>
set -eu
SRC=$1 BIN=$2 VER=$3 ARCH=$4 OUT=$5
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/data" "$WORK/control"
cp -a "$SRC/ipk/rootfs/." "$WORK/data/"
install -D -m 0755 "$BIN" "$WORK/data/opt/bin/hrneo"
chmod 0755 "$WORK/data/opt/etc/init.d/S99hrneo" "$WORK"/data/opt/etc/ndm/*/015-hrneo.sh
SIZE=$(du -sb "$WORK/data" | cut -f1)
sed -e "s/@VERSION@/$VER/" -e "s/@ARCH@/$ARCH/" -e "s/@INSTALLED_SIZE@/$SIZE/" \
    -e "s/^Maintainer: .*/Maintainer: le0nus (fork of Ground_Zerro HydraRoute)/" \
    "$SRC/ipk/control/control.in" > "$WORK/control/control"
install -m 0755 "$SRC/ipk/control/postinst" "$WORK/control/postinst"
install -m 0644 "$SRC/ipk/control/conffiles" "$WORK/control/conffiles"
install -m 0644 "$SRC/ipk/debian-binary" "$WORK/debian-binary"
T="tar --owner=0 --group=0 --numeric-owner"
(cd "$WORK/control" && $T -czf ../control.tar.gz ./)
(cd "$WORK/data" && $T -czf ../data.tar.gz ./)
mkdir -p "$OUT"
rm -f "$OUT"/hrneo_*_"$ARCH".ipk
(cd "$WORK" && $T -czf "$OUT/hrneo_${VER}_${ARCH}.ipk" ./debian-binary ./control.tar.gz ./data.tar.gz)
echo "$OUT/hrneo_${VER}_${ARCH}.ipk"

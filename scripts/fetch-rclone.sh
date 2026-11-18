#!/bin/zsh
# Descarga rclone 1.76.0 (MIT) para macOS Intel, comprueba su suma SHA-256
# publicada por el proyecto y lo deja en vendor/rclone, donde lo busca build.sh.
set -euo pipefail
ROOT=${0:A:h:h}
VERSION=v1.76.0
ARCH=${NIMBO_RCLONE_ARCH:-osx-amd64}
NAME="rclone-$VERSION-$ARCH"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
curl -fsSL "https://downloads.rclone.org/$VERSION/$NAME.zip" -o "$TMP/$NAME.zip"
curl -fsSL "https://downloads.rclone.org/$VERSION/SHA256SUMS" -o "$TMP/SHA256SUMS"
expected=$(grep " $NAME.zip\$" "$TMP/SHA256SUMS" | awk '{print $1}')
actual=$(shasum -a 256 "$TMP/$NAME.zip" | awk '{print $1}')
[[ -n $expected && $expected == $actual ]] || { echo "La suma SHA-256 de rclone no coincide"; exit 1; }
unzip -q "$TMP/$NAME.zip" -d "$TMP"
mkdir -p "$ROOT/vendor"
install -m 755 "$TMP/$NAME/rclone" "$ROOT/vendor/rclone"
echo "rclone $VERSION listo en vendor/rclone"

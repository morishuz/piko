#!/bin/zsh

set -euo pipefail

SCRIPT_DIR=${0:A:h}
NATIVE_ROOT=${SCRIPT_DIR:h}
SOURCE="$NATIVE_ROOT/Resources/AppIconSource.png"
MASTER="$NATIVE_ROOT/Resources/AppIcon.png"
ICNS="$NATIVE_ROOT/Resources/AppIcon.icns"
TEMP_ROOT=$(mktemp -d /private/tmp/piko-app-icon.XXXXXX)
ICONSET="$TEMP_ROOT/AppIcon.iconset"
PREPARED_SOURCE="$TEMP_ROOT/AppIcon-prepared.png"

trap 'rm -rf "$TEMP_ROOT"' EXIT
mkdir -p "$ICONSET"

swift "$SCRIPT_DIR/prepare-app-icon.swift" "$SOURCE" "$PREPARED_SOURCE"

for size in 16 32 128 256 512; do
    sips -z $size $size "$PREPARED_SOURCE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    retina=$((size * 2))
    sips -z $retina $retina "$PREPARED_SOURCE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$TEMP_ROOT/AppIcon.icns"
iconutil -c iconset "$TEMP_ROOT/AppIcon.icns" -o "$TEMP_ROOT/Decoded.iconset"
swift "$SCRIPT_DIR/validate-app-icon.swift" "$PREPARED_SOURCE" "$TEMP_ROOT/Decoded.iconset"
cp "$PREPARED_SOURCE" "$MASTER"
cp "$TEMP_ROOT/AppIcon.icns" "$ICNS"
print "$ICNS"

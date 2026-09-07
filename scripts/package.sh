#!/bin/zsh
set -euo pipefail
SCRIPT_DIR=${0:A:h}
NATIVE_ROOT=${SCRIPT_DIR:h}
DIST_DIR="$NATIVE_ROOT/dist"
# Build and sign in a unique staging directory.
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/piko-apple-package.XXXXXX")
trap 'rm -rf -- "$STAGE"' EXIT
PACKAGE="$STAGE/Piko"
APP="$PACKAGE/Piko.app"
CONTENTS="$APP/Contents"
swift build --package-path "$NATIVE_ROOT" --configuration release
BIN_DIR=$(swift build --package-path "$NATIVE_ROOT" --configuration release --show-bin-path)
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$DIST_DIR"
cp "$BIN_DIR/Piko" "$CONTENTS/MacOS/Piko"
cp "$NATIVE_ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
REVISION=$(git -C "$NATIVE_ROOT" rev-parse HEAD)
DIRTY=false
if [[ -n "$(git -C "$NATIVE_ROOT" status --porcelain)" ]]; then DIRTY=true; fi
/usr/libexec/PlistBuddy -c "Set :PikoSourceRevision $REVISION" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :PikoSourceDirty $DIRTY" "$CONTENTS/Info.plist"
cp "$NATIVE_ROOT/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
cp "$NATIVE_ROOT/THIRD_PARTY_NOTICES.md" "$CONTENTS/Resources/Third Party Notices.md"
cp "$NATIVE_ROOT/LICENSE" "$CONTENTS/Resources/LICENSE"
for document in README.md CONTRIBUTING.md ROADMAP.md LICENSE THIRD_PARTY_NOTICES.md SECURITY.md; do
    cp "$NATIVE_ROOT/$document" "$PACKAGE/$document"
done
mkdir -p "$PACKAGE/images"
cp "$NATIVE_ROOT/images/piki-screenshot.png" "$PACKAGE/images/piki-screenshot.png"
mkdir -p "$PACKAGE/docs"
for document in TESTING.md DIAGNOSTICS.md DEVICE_BIN.md REMOTE_DRAG_DROP.md PHOTO_THUMBNAILS.md RELEASING.md; do
    cp "$NATIVE_ROOT/docs/$document" "$PACKAGE/docs/$document"
done
cp "$BIN_DIR/PikoTools" "$PACKAGE/PikoTools"
# Remove compiler debug paths before signing the distributed executables.
xcrun strip -S "$CONTENTS/MacOS/Piko" "$PACKAGE/PikoTools"
codesign --force --sign - "$CONTENTS/MacOS/Piko"
codesign --force --sign - "$APP"
codesign --force --sign - "$PACKAGE/PikoTools"
ZIP="$DIST_DIR/Piko.zip"
ditto -c -k --sequesterRsrc --keepParent "$PACKAGE" "$STAGE/package.zip"
mv -f -- "$STAGE/package.zip" "$ZIP"
print "$ZIP"

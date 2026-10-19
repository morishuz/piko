#!/bin/zsh
set -euo pipefail
SCRIPT_DIR=${0:A:h}
NATIVE_ROOT=${SCRIPT_DIR:h}
DIST_DIR="$NATIVE_ROOT/dist"
# Build and sign in a unique staging directory.
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/piko-apple-package.XXXXXX")
trap 'rm -rf -- "$STAGE"' EXIT
APP="$STAGE/Piko.app"
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
# Remove compiler debug paths before signing the distributed executables.
xcrun strip -S "$CONTENTS/MacOS/Piko"
SIGNING_IDENTITY=${PIKO_SIGNING_IDENTITY:--}
if [[ "$SIGNING_IDENTITY" == - ]]; then
    codesign --force --sign - "$APP"
else
    codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp "$APP"
    SIGNATURE=$(codesign --display --verbose=4 "$APP" 2>&1)
    [[ "$SIGNATURE" == *"Authority=Developer ID Application:"* ]] || {
        print -u2 'Distribution signing requires a Developer ID Application certificate.'
        exit 1
    }
fi
codesign --verify --deep --strict "$APP"
ZIP="$DIST_DIR/Piko.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$STAGE/package.zip"
mv -f -- "$STAGE/package.zip" "$ZIP"
print "$ZIP"

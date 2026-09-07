#!/bin/zsh
set -euo pipefail
SCRIPT_DIR=${0:A:h}
NATIVE_ROOT=${SCRIPT_DIR:h}
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/piko-apple-verify.XXXXXX")
trap 'rm -rf -- "$STAGE"' EXIT
ditto -x -k "$NATIVE_ROOT/dist/Piko.zip" "$STAGE"
APP="$STAGE/Piko.app"
cmp "$NATIVE_ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cmp "$NATIVE_ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"
cmp "$NATIVE_ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/Third Party Notices.md"
# The download contains only the app, including its required legal notices.
python3 - "$NATIVE_ROOT/dist/Piko.zip" <<'PYTHON'
import sys
from zipfile import ZipFile
with ZipFile(sys.argv[1]) as archive:
    files = {name for name in archive.namelist()
             if not name.endswith('/') and not name.startswith('__MACOSX/')}
    expected = {
        'Piko.app/Contents/Info.plist',
        'Piko.app/Contents/MacOS/Piko',
        'Piko.app/Contents/Resources/AppIcon.icns',
        'Piko.app/Contents/Resources/LICENSE',
        'Piko.app/Contents/Resources/Third Party Notices.md',
        'Piko.app/Contents/_CodeSignature/CodeResources',
    }
    assert files == expected, f'Unexpected package contents: {files ^ expected}'
PYTHON
for key in CFBundleName CFBundleDisplayName CFBundleExecutable; do
    [[ $(/usr/libexec/PlistBuddy -c "Print :$key" "$APP/Contents/Info.plist") == Piko ]]
done
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist") == com.piko.mac ]]
[[ ! -e "$APP/Contents/Frameworks" ]]
[[ -z "$(find "$APP" -name '*.dylib' -print)" ]]
[[ $(/usr/libexec/PlistBuddy -c 'Print :PikoSourceRevision' "$APP/Contents/Info.plist") == $(git -C "$NATIVE_ROOT" rev-parse HEAD) ]]
[[ $(/usr/libexec/PlistBuddy -c 'Print :UTExportedTypeDeclarations:0:UTTypeIdentifier' "$APP/Contents/Info.plist") == com.piko.mac.remote-item ]]
[[ $(/usr/libexec/PlistBuddy -c 'Print :UTExportedTypeDeclarations:0:UTTypeConformsTo:0' "$APP/Contents/Info.plist") == public.data ]]
for key in CFBundleVersion CFBundleShortVersionString; do
    [[ $(/usr/libexec/PlistBuddy -c "Print :$key" "$APP/Contents/Info.plist") == $(/usr/libexec/PlistBuddy -c "Print :$key" "$NATIVE_ROOT/Resources/Info.plist") ]]
done
for binary in "$APP/Contents/MacOS/Piko"; do
    [[ $(lipo -archs "$binary") == arm64 ]]
    [[ $(xcrun vtool -show-build "$binary" | awk '$1 == "minos" { print $2 }') == 14.0 ]]
    if strings "$binary" | awk -v source_root="$NATIVE_ROOT" '
        index($0, source_root) { found = 1 }
        END { exit found ? 0 : 1 }
    '; then
        print -u2 'Packaged executable contains local source paths.'
        exit 1
    fi
    # Dynamic dependencies must all be Apple system libraries/frameworks.
    otool -L "$binary" | tail -n +2 | awk '{print $1}' | while read dependency; do
        [[ "$dependency" == /System/Library/* || "$dependency" == /usr/lib/* ]]
    done
    # Runtime exclusion alone missed the statically compiled legacy C bridges.
    # Reject those symbols and dlopen. Compiler OS-availability support
    # legitimately uses dlsym for Apple CoreFoundation symbols.
    nm -a "$binary" | awk '
        $NF ~ /^_(omt_|lmt_|dlopen$)/ { found = 1 }
        $NF ~ /DemoBackend|DemoUploadFailure|SimulatedDeviceError|BackendSelection|BackendChoice/ { found = 1 }
        END { exit found ? 1 : 0 }
    '
    codesign --verify --strict "$binary"
done
codesign --verify --deep --strict "$APP"
print 'Verified Apple-only package: no third-party dylibs; no USB hardware accessed.'

#!/bin/zsh
set -euo pipefail
SCRIPT_DIR=${0:A:h}
NATIVE_ROOT=${SCRIPT_DIR:h}
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/piko-apple-verify.XXXXXX")
trap 'rm -rf -- "$STAGE"' EXIT
ditto -x -k "$NATIVE_ROOT/dist/Piko.zip" "$STAGE"
PACKAGE="$STAGE/Piko"
APP="$PACKAGE/Piko.app"
cmp "$NATIVE_ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cmp "$NATIVE_ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"
cmp "$NATIVE_ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/Third Party Notices.md"
for document in README.md CONTRIBUTING.md ROADMAP.md LICENSE THIRD_PARTY_NOTICES.md SECURITY.md; do
    cmp "$NATIVE_ROOT/$document" "$PACKAGE/$document"
done
for document in TESTING.md DIAGNOSTICS.md DEVICE_BIN.md REMOTE_DRAG_DROP.md PHOTO_THUMBNAILS.md RELEASING.md; do
    cmp "$NATIVE_ROOT/docs/$document" "$PACKAGE/docs/$document"
done
cmp "$NATIVE_ROOT/images/piki-screenshot.png" "$PACKAGE/images/piki-screenshot.png"
for key in CFBundleName CFBundleDisplayName CFBundleExecutable; do
    [[ $(/usr/libexec/PlistBuddy -c "Print :$key" "$APP/Contents/Info.plist") == Piko ]]
done
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist") == com.piko.mac ]]
[[ ! -e "$APP/Contents/Frameworks" ]]
[[ -z "$(find "$PACKAGE" -name '*.dylib' -print)" ]]
[[ $(/usr/libexec/PlistBuddy -c 'Print :PikoSourceRevision' "$APP/Contents/Info.plist") == $(git -C "$NATIVE_ROOT" rev-parse HEAD) ]]
[[ $(/usr/libexec/PlistBuddy -c 'Print :UTExportedTypeDeclarations:0:UTTypeIdentifier' "$APP/Contents/Info.plist") == com.piko.mac.remote-item ]]
[[ $(/usr/libexec/PlistBuddy -c 'Print :UTExportedTypeDeclarations:0:UTTypeConformsTo:0' "$APP/Contents/Info.plist") == public.data ]]
for key in CFBundleVersion CFBundleShortVersionString; do
    [[ $(/usr/libexec/PlistBuddy -c "Print :$key" "$APP/Contents/Info.plist") == $(/usr/libexec/PlistBuddy -c "Print :$key" "$NATIVE_ROOT/Resources/Info.plist") ]]
done
for binary in "$APP/Contents/MacOS/Piko" "$PACKAGE/PikoTools"; do
    [[ $(lipo -archs "$binary") == arm64 ]]
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
"$PACKAGE/PikoTools" --help
"$PACKAGE/PikoTools" generate "$STAGE/kit"
"$PACKAGE/PikoTools" verify "$STAGE/kit/MTP-Synthetic"
print 'Verified Apple-only package: no third-party dylibs; no USB hardware accessed.'

#!/bin/zsh
set -euo pipefail
SCRIPT_DIR=${0:A:h}
NATIVE_ROOT=${SCRIPT_DIR:h}
: ${PIKO_NOTARY_PROFILE:?Set PIKO_NOTARY_PROFILE to a notarytool Keychain profile name}
ZIP=${1:-"$NATIVE_ROOT/dist/Piko.zip"}
ZIP=${ZIP:A}
OUTPUT="${ZIP:r}-notarized.zip"
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/piko-notarize.XXXXXX")
trap 'rm -rf -- "$STAGE"' EXIT
# Work on one immutable copy throughout submission and stapling.
cp "$ZIP" "$STAGE/submission.zip"
PIKO_REQUIRE_DEVELOPER_ID=1 zsh "$SCRIPT_DIR/verify-package.sh" "$STAGE/submission.zip"
NOTARY_KEYCHAIN_ARGS=()
if [[ -n ${PIKO_NOTARY_KEYCHAIN:-} ]]; then
    NOTARY_KEYCHAIN_ARGS=(--keychain "$PIKO_NOTARY_KEYCHAIN")
fi
xcrun notarytool submit "$STAGE/submission.zip" --keychain-profile "$PIKO_NOTARY_PROFILE" \
    --wait --timeout 30m "${NOTARY_KEYCHAIN_ARGS[@]}" --output-format json > "$STAGE/result.json"
python3 - "$STAGE/result.json" <<'PYTHON'
import json, sys
result = json.load(open(sys.argv[1]))
print('Notarization:', result.get('status'), 'Submission:', result.get('id'))
if result.get('status') != 'Accepted':
    raise SystemExit('Not accepted. Retrieve details with: xcrun notarytool log <submission-id> --keychain-profile <profile>')
PYTHON
ditto -x -k "$STAGE/submission.zip" "$STAGE/unpacked"
xcrun stapler staple "$STAGE/unpacked/Piko.app"
ditto -c -k --sequesterRsrc --keepParent "$STAGE/unpacked/Piko.app" "$STAGE/notarized.zip"
PIKO_REQUIRE_NOTARIZATION=1 zsh "$SCRIPT_DIR/verify-package.sh" "$STAGE/notarized.zip"
mv -f -- "$STAGE/notarized.zip" "$OUTPUT"
print "$OUTPUT"

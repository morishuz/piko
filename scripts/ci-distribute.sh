#!/bin/zsh
# Runs only on a disposable GitHub-hosted release runner.
set -euo pipefail
[[ ${GITHUB_ACTIONS:-} == true && ${RUNNER_ENVIRONMENT:-} == github-hosted ]]
[[ ${GITHUB_REPOSITORY:-} == morishuz/piko ]]
[[ ${GITHUB_EVENT_NAME:-} == push || ${GITHUB_EVENT_NAME:-} == workflow_dispatch ]]
[[ ${GITHUB_REF:-} == refs/tags/v* || ${GITHUB_REF:-} == refs/heads/main ]]
: ${RUNNER_TEMP:?}
: ${PIKO_CERTIFICATE_BASE64:?Missing signing certificate secret}
: ${PIKO_CERTIFICATE_PASSWORD:?Missing certificate password secret}
: ${PIKO_APPLE_ID:?Missing Apple ID secret}
: ${PIKO_APPLE_PASSWORD:?Missing app-specific password secret}
: ${PIKO_EXPECTED_TEAM_ID:?Missing team ID secret}
SCRIPT_DIR=${0:A:h}
NATIVE_ROOT=${SCRIPT_DIR:h}
KEYCHAIN="$RUNNER_TEMP/piko-signing.keychain-db"
CERTIFICATE="$RUNNER_TEMP/piko-signing.p12"
cleanup() {
    security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
    rm -f -- "$CERTIFICATE"
}
trap cleanup EXIT
umask 077
KEYCHAIN_PASSWORD=$(openssl rand -hex 32)
print -r -- "::add-mask::$KEYCHAIN_PASSWORD"
print -rn -- "$PIKO_CERTIFICATE_BASE64" | base64 --decode > "$CERTIFICATE"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 3600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$CERTIFICATE" -P "$PIKO_CERTIFICATE_PASSWORD" -k "$KEYCHAIN" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
security list-keychains -d user -s "$KEYCHAIN"
rm -f -- "$CERTIFICATE"
IDENTITIES=$(security find-identity -v -p codesigning "$KEYCHAIN")
export PIKO_SIGNING_IDENTITY=$(print -r -- "$IDENTITIES" | awk '/Developer ID Application:/ {print $2}')
[[ "$PIKO_SIGNING_IDENTITY" =~ '^[0-9A-Fa-f]{40}$' ]] || {
    print -u2 'Expected exactly one valid Developer ID Application identity.'
    exit 1
}
export PIKO_NOTARY_KEYCHAIN="$KEYCHAIN"
export PIKO_NOTARY_PROFILE=piko-ci
xcrun notarytool store-credentials "$PIKO_NOTARY_PROFILE" --keychain "$KEYCHAIN" \
    --apple-id "$PIKO_APPLE_ID" --team-id "$PIKO_EXPECTED_TEAM_ID" --password "$PIKO_APPLE_PASSWORD" >/dev/null
unset PIKO_CERTIFICATE_BASE64 PIKO_CERTIFICATE_PASSWORD PIKO_APPLE_ID PIKO_APPLE_PASSWORD KEYCHAIN_PASSWORD IDENTITIES
zsh "$SCRIPT_DIR/package.sh"
PIKO_REQUIRE_DEVELOPER_ID=1 zsh "$SCRIPT_DIR/verify-package.sh"
zsh "$SCRIPT_DIR/notarize.sh"
# Only the stapled, verified ZIP reaches the artifact and release jobs.
mv -f -- "$NATIVE_ROOT/dist/Piko-notarized.zip" "$NATIVE_ROOT/dist/Piko.zip"
PIKO_REQUIRE_NOTARIZATION=1 zsh "$SCRIPT_DIR/verify-package.sh"

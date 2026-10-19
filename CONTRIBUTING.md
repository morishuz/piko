# Build from source

The app supports Apple Silicon Macs running macOS 14 or newer.
To match release builds, use Xcode 26.6 (17F113), macOS SDK 26.5,
and a Mac supported by that Xcode version.

```sh
swift run Piko       # Run the app
swift test          # Run tests without USB hardware
zsh scripts/package.sh
zsh scripts/verify-package.sh
```

Packaging produces `dist/Piko.zip` containing only Piko.app, with its version and
icon. `swift run Piko` uses development identity. CI also runs release-mode tests
and Address Sanitizer checks, then launches the packaged app on macOS 14.
Keep generated builds and diagnostic exports out of commits.

## Local Developer ID signing and notarization

The default local build and ordinary CI remain ad-hoc signed. Release workflows
require Developer ID signing and notarization. To make a local
distribution build, select a Developer ID Application identity from
`security find-identity -v -p codesigning`, then run:

```sh
PIKO_SIGNING_IDENTITY='<certificate SHA-1>' zsh scripts/package.sh
PIKO_REQUIRE_DEVELOPER_ID=1 zsh scripts/verify-package.sh
```

This enables hardened runtime and Apple's secure timestamp. No private key is
exported, and no sandbox or runtime exceptions are added. Test USB browsing and
transfers with the signed build before distribution.

Store notarization credentials in Keychain using the interactive command below.
Enter an Apple ID app-specific password at its secure prompt; never put passwords,
certificates, or API private keys in the repository.

```sh
xcrun notarytool store-credentials Piko-notary --apple-id '<Apple ID>' --team-id '<Team ID>'
PIKO_NOTARY_PROFILE=Piko-notary zsh scripts/notarize.sh
```

The script submits the signed ZIP to Apple, requires acceptance, staples the
ticket, and verifies Gatekeeper approval. It writes `dist/Piko-notarized.zip`,
leaving the signed input ZIP intact. An existing profile can be selected with
`PIKO_NOTARY_PROFILE`. Signing alone does not mean an app is notarized.
Release CI requires these GitHub Actions secrets: `PIKO_CERTIFICATE_BASE64`
(password-protected Developer ID Application `.p12`, base64 encoded),
`PIKO_CERTIFICATE_PASSWORD`, `PIKO_APPLE_ID`, `PIKO_APPLE_PASSWORD` (app-specific),
and `PIKO_TEAM_ID`. Keep them in GitHub Secrets, never workflow source or logs.
Only the Release workflow forwards them; pull-request and ordinary branch builds
receive none. Release jobs import the identity into a temporary Keychain and
remove it afterward. The final stapled ZIP is verified again on macOS 14 before
a draft can be created. Manual Release runs on main produce notarized artifacts
without creating a release. Do not replace CI assets with a local build to bypass
release checks.

## Test with disposable files

PikoTools is a source-only utility; it is not included in the app download.
These commands generate and verify a synthetic fixture locally, without USB:

```sh
swift run PikoTools generate "$TMPDIR/piko-test-kit"
swift run PikoTools verify "$TMPDIR/piko-test-kit/MTP-Synthetic"
```

The output folder must not already exist; choose a new name for another run.
Verification checks the known fixture's file sizes, SHA-256 hashes, and directory
tree. It is not a general-purpose verifier for personal files.

For a device test, upload the generated `MTP-Synthetic` folder with Piko to a
disposable test location, download it to a fresh local folder, then run
`swift run PikoTools verify` with the downloaded `MTP-Synthetic` path.
Also try cancellation and reconnection, moving a disposable folder to the Bin
and restoring it, and permanent deletion of test copies. Inspect the results
after each operation; verify the downloaded fixture again after restoration.
Keep the original local fixture. Never use irreplaceable files for these tests.

Record the app version, device model, macOS version, and outcome.
See the [user guide](docs/USER_GUIDE.md) for Bin behavior and diagnostic privacy.

## Publish a preview

1. Update the version and build in `Resources/Info.plist` and the PikoTools version
   in `Sources/MTPIntegrityKit/IntegrityKit.swift`. Commit, then push the matching
   `vX.Y.Z` tag. Keep the README pointing to the existing download for now.
2. Wait for that tag's **Release** workflow to succeed, including tests, Address
   Sanitizer, package verification, and the macOS 14 startup check. A failed run
   must not be bypassed with a manually uploaded local build; fix it and release
   a new version if source changes are needed.
3. Review the generated draft, its version, ZIP/checksum, and release notes.
   Describe the changes and known limitations, retain the preview and signing
   notice, then publish as a prerelease using the CI-produced assets.
4. Confirm the published ZIP and checksum links work, then update the README
   download links in a follow-up commit.

The workflow creates a draft only after all reusable build jobs succeed.
Publication remains a manual review step; a manual workflow run only builds
artifacts and does not create a release.

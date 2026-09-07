# Releasing Piko

## Repository handoff

Create the new repository only when ready. Transfer the prepared `main` branch
or import a source archive into a fresh repository. Do not mirror the development
repository or copy its `.git` directory: historical objects, refs, and local
configuration do not belong in the public source.

Confirm the new repository has the intended visibility, one initial commit, the
MIT license, and third-party notices. Enable Actions and private vulnerability
reporting when available. Configure branch protection to require passing CI.
The workflows use GitHub's built-in token; no personal access token is required.

## Preview builds

1. Update the numeric version and build in `Resources/Info.plist` and the matching
   tool version in `Sources/MTPIntegrityKit/IntegrityKit.swift`.
2. Run the checks in [CONTRIBUTING.md](../CONTRIBUTING.md). If the icon changes,
   regenerate its representations with `zsh scripts/generate-app-icon.sh`.
3. Push the reviewed commit and wait for CI to pass. Download its artifact,
   extract it, and verify the included checksum with `shasum -a 256 -c *.sha256`.
4. Test the downloaded app on the supported macOS version and physical devices.
   Record the tested configurations and remaining limitations.

CI builds Apple Silicon packages for macOS 14+. Each archive contains the app,
its icon, documentation, license notices, and the hardware-free integrity tool.
CI checks signatures, architecture, symbols, source metadata, and the integrity
recipe before uploading the ZIP and checksum. Artifacts expire after 30 days
and downloading them requires GitHub sign-in and repository read access.

## A downloadable release

Push a tag matching the app version, such as `v0.15.1`, only when ready to create
a release. The Release workflow builds and verifies the tagged source, then
creates a **draft prerelease** with `Piko-macOS-arm64.zip` and its checksum.
These fixed asset names make direct release links predictable. Review the files
and release notes before publishing the draft manually. A manual Release workflow run only
builds an artifact.

Published releases in a public repository provide downloads without requiring a
GitHub account. The README links directly to the current preview's ZIP and checksum.
Update the version in both links for each new published preview. Keep the previous
release assets available so existing links continue to work. GitHub's
`releases/latest` redirect excludes prereleases; use the versioned links for previews.

Current packages are ad-hoc signed, not Developer ID signed or notarized. Describe
that accurately in preview releases. Developer ID signing and notarization remain
a separate distribution step; never commit signing credentials or certificates.

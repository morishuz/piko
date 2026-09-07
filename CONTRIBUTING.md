# Contributing

Use an Apple Silicon Mac with macOS 14+ and Xcode/Swift 6+.
No submodule initialization or third-party USB runtime is required.

Before submitting changes, run the hardware-free checks:

```sh
swift test
swift test -c release
swift test --scratch-path .build-asan --sanitize address --filter robustness
swift test --scratch-path .build-upload-asan --sanitize address --filter 'UploadWireTests|SwiftUploadBackendTests|MTPUSBTests|UploadLocalSafetyTests|ActiveTransferCancellationTests|UploadTests|BinIntegrationTests|BinPreparationTests|MoveWireTests|DeleteWireTests|ShutdownTests|RangedDownloadTests|partialObject|RangedUploadTests|PartialUploadWireTests|PartialUploadTransportTests|finderPromiseCompletion|DeviceManagerTests|multipleDeviceDiagnostics|RemoteTransferTests|RemoteDropTableTests|PhotoThumbnail|ThumbnailWireTests|ThumbnailGenerationTests|RemoteFileGridTests|VideoThumbnailTests'
zsh scripts/package.sh
zsh scripts/verify-package.sh
```

Use `swift run Piko` for UI checks. The app always uses Apple USB and
discovers USB registry entries without opening sessions. Simulated devices live
only in the test target; there is no demo launch mode or backend selector. It claims a device only after its Connect action. Keep USB
operations off the main actor, preserve packet boundaries and close-only cleanup,
and keep UI/queue policy out of the protocol and transport layers.

Hardware changes must state which device, firmware, macOS, and build were tested.
Use [Apple USB testing](docs/TESTING.md) and distinguish simulated checks
from physical transfers. CI must not probe connected private devices.

Packaging produces `dist/Piko.zip`. Increment the numeric
version and build in `Resources/Info.plist` for a new tester build, and update the
probe version in `Sources/MTPIntegrityKit/IntegrityKit.swift`. Verification checks
versions, architecture, signature, system-only dynamic linkage, absence of compiler
source paths and unsupported runtime symbols, and the synthetic integrity recipe.

Do not commit generated build directories, distribution archives, signing
certificates, provisioning profiles, or local diagnostic exports.

## Reporting issues and proposing changes

Use this repository's Issues tab for bugs and feature requests. For a bug, include
Piko and macOS versions, device model, reproduction steps, and expected/actual
results. Use disposable test files. Review any diagnostic export before sharing;
see [security reporting](SECURITY.md) for sensitive reports.

Keep pull requests focused, explain the user-visible change, and state what was
tested. Distinguish automated tests from physical-device testing. Do not add
network access, automatic reporting, or default-on diagnostics.

See [releasing](docs/RELEASING.md) for distribution and repository handoff steps.

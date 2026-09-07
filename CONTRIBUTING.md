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

Packaging produces `dist/Piko.zip` containing only Piko.app. CI also runs release-mode tests and Address
Sanitizer checks, then launches the packaged app on macOS 14. Keep generated builds and diagnostic exports out of commits.

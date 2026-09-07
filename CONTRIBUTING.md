# Build from source

Requires an Apple Silicon Mac with macOS 14+ and Xcode/Swift 6+.

```sh
swift run Piko       # Run the app
swift test          # Run tests without USB hardware
zsh scripts/package.sh
zsh scripts/verify-package.sh
```

Packaging produces `dist/Piko.zip` containing only Piko.app. CI also runs release-mode tests and Address
Sanitizer checks. Keep generated builds and diagnostic exports out of commits.

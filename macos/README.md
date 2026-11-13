# Native macOS app development

The native app and Swift engine are managed by Swift Package Manager at the
repository root.

```sh
swift test
swift run PhoneBackupApp
```

These commands were verified with Xcode 27.2 selected. A Command Line Tools-only
setup has not been validated for this package. The project currently uses
SwiftPM; use full Xcode if we later add an Xcode project or rely on `xcodebuild`.
